// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {KoruEscrow} from "../src/KoruEscrow.sol";
import {IKoruEscrow} from "../src/interfaces/IKoruEscrow.sol";
import {Errors} from "../src/libraries/Errors.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @title BaseTest
/// @notice Base test contract with common setup and utilities
abstract contract BaseTest is Test {
    // ============ Contracts ============
    KoruEscrow public escrow;
    MockUSDC public usdc;

    // ============ Users ============
    address public owner;
    address public feeRecipient;
    address public depositor;
    address public recipient;
    address public alice;
    address public bob;
    address public charlie;

    // ============ Constants ============
    uint256 public constant INITIAL_FEE_BPS = 250; // 2.5%
    uint256 public constant USDC_DECIMALS = 6;
    uint256 public constant ONE_USDC = 10 ** USDC_DECIMALS;
    uint256 public constant HUNDRED_USDC = 100 * ONE_USDC;
    uint256 public constant THOUSAND_USDC = 1000 * ONE_USDC;

    // ============ Time Constants ============
    uint256 public constant ACCEPT_WINDOW = 24 hours;
    uint256 public constant DISPUTE_WINDOW = 48 hours;

    // ============ Setup ============

    function setUp() public virtual {
        // Create users
        owner = makeAddr("owner");
        feeRecipient = makeAddr("feeRecipient");
        depositor = makeAddr("depositor");
        recipient = makeAddr("recipient");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");

        // Deploy contracts as owner
        vm.startPrank(owner);

        usdc = new MockUSDC();
        escrow = new KoruEscrow(address(usdc), INITIAL_FEE_BPS, feeRecipient);

        vm.stopPrank();

        // Fund users with USDC
        _fundUser(depositor, THOUSAND_USDC);
        _fundUser(alice, THOUSAND_USDC);
        _fundUser(bob, THOUSAND_USDC);
        _fundUser(charlie, THOUSAND_USDC);

        // Approve escrow contract
        _approveEscrow(depositor);
        _approveEscrow(alice);
        _approveEscrow(bob);
        _approveEscrow(charlie);
    }

    // ============ Helpers ============

    /// @notice Fund a user with USDC
    function _fundUser(address user, uint256 amount) internal {
        usdc.mint(user, amount);
    }

    /// @notice Approve escrow contract to spend user's USDC
    function _approveEscrow(address user) internal {
        vm.prank(user);
        usdc.approve(address(escrow), type(uint256).max);
    }

    /// @notice Create an escrow as depositor
    function _createEscrow(
        address _depositor,
        address _recipient,
        uint256 _amount
    ) internal returns (uint256 escrowId) {
        vm.prank(_depositor);
        escrowId = escrow.createEscrow(_recipient, _amount);
    }

    /// @notice Create a default escrow (depositor -> recipient, 100 USDC)
    function _createDefaultEscrow() internal returns (uint256 escrowId) {
        return _createEscrow(depositor, recipient, HUNDRED_USDC);
    }

    /// @notice Accept an escrow as recipient
    function _acceptEscrow(uint256 escrowId, address _recipient) internal {
        vm.prank(_recipient);
        escrow.accept(escrowId);
    }

    /// @notice Release an escrow as depositor
    function _releaseEscrow(uint256 escrowId, address _depositor) internal {
        vm.prank(_depositor);
        escrow.release(escrowId);
    }

    /// @notice Dispute an escrow as depositor
    function _disputeEscrow(uint256 escrowId, address _depositor) internal {
        vm.prank(_depositor);
        escrow.dispute(escrowId);
    }

    /// @notice Withdraw from escrow
    function _withdraw(uint256 escrowId, address user) internal {
        vm.prank(user);
        escrow.withdraw(escrowId);
    }

    /// @notice Fast forward time
    function _fastForward(uint256 duration) internal {
        vm.warp(block.timestamp + duration);
    }

    /// @notice Calculate expected fee and net amount
    function _calculateExpectedFee(uint256 amount) internal pure returns (uint256 fee, uint256 netAmount) {
        fee = (amount * INITIAL_FEE_BPS) / 10000;
        netAmount = amount - fee;
    }

    /// @notice Assert escrow status
    function _assertStatus(uint256 escrowId, IKoruEscrow.Status expected) internal view {
        assertEq(uint8(escrow.getStatus(escrowId)), uint8(expected), "Unexpected escrow status");
    }
}
