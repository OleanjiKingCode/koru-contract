// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {KoruEscrow} from "../../src/KoruEscrow.sol";
import {IKoruEscrow} from "../../src/interfaces/IKoruEscrow.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title KoruEscrowHandler
/// @notice Handler contract for invariant testing
contract KoruEscrowHandler is Test {
    KoruEscrow public escrow;
    MockUSDC public usdc;

    address[] public actors;
    uint256[] public createdEscrowIds;
    uint256[] public acceptedEscrowIds;

    // Ghost variables for tracking
    uint256 public ghost_totalDeposited;
    uint256 public ghost_totalWithdrawn;
    uint256 public ghost_totalFees;

    constructor(KoruEscrow _escrow, MockUSDC _usdc) {
        escrow = _escrow;
        usdc = _usdc;

        // Create actors
        for (uint256 i = 0; i < 5; i++) {
            address actor = address(uint160(i + 100));
            actors.push(actor);
            usdc.mint(actor, 1_000_000e6);
            vm.prank(actor);
            usdc.approve(address(escrow), type(uint256).max);
        }
    }

    function createEscrow(
        uint256 depositorSeed,
        uint256 recipientSeed,
        uint256 amount
    ) external {
        address depositor_ = actors[depositorSeed % actors.length];
        address recipient_ = actors[recipientSeed % actors.length];

        if (depositor_ == recipient_) return;

        amount = bound(amount, 1e6, 10_000e6);

        vm.prank(depositor_);
        try escrow.createEscrow(recipient_, amount) returns (uint256 escrowId) {
            createdEscrowIds.push(escrowId);
            ghost_totalDeposited += amount;
        } catch {}
    }

    function acceptEscrow(uint256 escrowSeed) external {
        if (createdEscrowIds.length == 0) return;

        uint256 escrowId = createdEscrowIds[
            escrowSeed % createdEscrowIds.length
        ];
        IKoruEscrow.Escrow memory e = escrow.getEscrow(escrowId);

        if (e.status != IKoruEscrow.Status.Pending) return;

        vm.prank(e.recipient);
        try escrow.accept(escrowId) {
            acceptedEscrowIds.push(escrowId);
        } catch {}
    }

    function releaseEscrow(uint256 escrowSeed) external {
        if (acceptedEscrowIds.length == 0) return;

        uint256 escrowId = acceptedEscrowIds[
            escrowSeed % acceptedEscrowIds.length
        ];
        IKoruEscrow.Escrow memory e = escrow.getEscrow(escrowId);

        if (e.status != IKoruEscrow.Status.Accepted) return;

        vm.prank(e.depositor);
        try escrow.release(escrowId) {} catch {}
    }

    function withdrawRecipient(uint256 escrowSeed) external {
        if (acceptedEscrowIds.length == 0) return;

        uint256 escrowId = acceptedEscrowIds[
            escrowSeed % acceptedEscrowIds.length
        ];
        IKoruEscrow.Escrow memory e = escrow.getEscrow(escrowId);

        if (
            e.status != IKoruEscrow.Status.Released &&
            !(e.status == IKoruEscrow.Status.Accepted &&
                block.timestamp > e.acceptedAt + 48 hours)
        ) {
            return;
        }

        (uint256 fee, uint256 net) = escrow.calculateFee(e.amount);

        vm.prank(e.recipient);
        try escrow.withdraw(escrowId) {
            ghost_totalWithdrawn += net;
            ghost_totalFees += fee;
        } catch {}
    }

    function withdrawDepositor(uint256 escrowSeed) external {
        if (createdEscrowIds.length == 0) return;

        uint256 escrowId = createdEscrowIds[
            escrowSeed % createdEscrowIds.length
        ];
        IKoruEscrow.Escrow memory e = escrow.getEscrow(escrowId);

        if (e.status != IKoruEscrow.Status.Pending) return;
        if (block.timestamp <= e.createdAt + 24 hours) return;

        vm.prank(e.depositor);
        try escrow.withdraw(escrowId) {
            ghost_totalWithdrawn += e.amount;
        } catch {}
    }

    function warpTime(uint256 timeDelta) external {
        timeDelta = bound(timeDelta, 1 hours, 72 hours);
        vm.warp(block.timestamp + timeDelta);
    }

    function getCreatedEscrowCount() external view returns (uint256) {
        return createdEscrowIds.length;
    }
}

/// @title KoruEscrowInvariantTest
/// @notice Invariant tests for KoruEscrow contract
contract KoruEscrowInvariantTest is Test {
    KoruEscrow public escrow;
    MockUSDC public usdc;
    KoruEscrowHandler public handler;

    address public owner = address(1);
    address public feeRecipient = address(2);

    function setUp() public {
        vm.startPrank(owner);
        usdc = new MockUSDC();
        
        // Deploy via proxy for proper upgradeable pattern
        KoruEscrow implementation = new KoruEscrow();
        bytes memory initData = abi.encodeWithSelector(
            KoruEscrow.initialize.selector,
            address(usdc),
            250,
            feeRecipient
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        escrow = KoruEscrow(payable(address(proxy)));
        
        vm.stopPrank();

        handler = new KoruEscrowHandler(escrow, usdc);

        // Target the handler for invariant testing
        targetContract(address(handler));

        // Exclude specific functions if needed
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.createEscrow.selector;
        selectors[1] = handler.acceptEscrow.selector;
        selectors[2] = handler.releaseEscrow.selector;
        selectors[3] = handler.withdrawRecipient.selector;
        selectors[4] = handler.withdrawDepositor.selector;
        selectors[5] = handler.warpTime.selector;
        targetSelector(
            FuzzSelector({addr: address(handler), selectors: selectors})
        );
    }

    /// @notice Contract balance should equal total deposited minus total withdrawn minus fees
    function invariant_ContractBalanceConsistent() public view {
        uint256 contractBalance = usdc.balanceOf(address(escrow));
        uint256 expectedBalance = handler.ghost_totalDeposited() -
            handler.ghost_totalWithdrawn() -
            handler.ghost_totalFees();

        assertEq(
            contractBalance,
            expectedBalance,
            "Contract balance inconsistent"
        );
    }

    /// @notice Escrow count should always match next ID
    function invariant_EscrowCountMatchesNextId() public view {
        assertEq(
            escrow.getEscrowCount(),
            handler.getCreatedEscrowCount(),
            "Escrow count mismatch"
        );
    }

    /// @notice Fee recipient should receive all fees
    function invariant_FeeRecipientReceivesFees() public view {
        assertEq(
            usdc.balanceOf(feeRecipient),
            handler.ghost_totalFees(),
            "Fee recipient balance mismatch"
        );
    }

    /// @notice No escrow should have invalid status transitions
    function invariant_ValidStatusTransitions() public view {
        uint256 count = escrow.getEscrowCount();

        for (uint256 i = 0; i < count; i++) {
            IKoruEscrow.Escrow memory e = escrow.getEscrow(i);

            // Accepted escrow must have acceptedAt set
            if (
                e.status == IKoruEscrow.Status.Accepted ||
                e.status == IKoruEscrow.Status.Released ||
                e.status == IKoruEscrow.Status.Completed ||
                e.status == IKoruEscrow.Status.Disputed
            ) {
                assertTrue(
                    e.acceptedAt > 0,
                    "Accepted escrow must have acceptedAt"
                );
            }

            // Pending/Expired escrow should not have acceptedAt
            if (
                e.status == IKoruEscrow.Status.Pending ||
                e.status == IKoruEscrow.Status.Expired
            ) {
                assertEq(
                    e.acceptedAt,
                    0,
                    "Pending/Expired escrow should not have acceptedAt"
                );
            }
        }
    }
}
