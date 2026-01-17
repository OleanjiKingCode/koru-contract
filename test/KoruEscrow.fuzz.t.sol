// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./BaseTest.sol";
import {IKoruEscrow} from "../src/interfaces/IKoruEscrow.sol";
import {Errors} from "../src/libraries/Errors.sol";

/// @title KoruEscrowFuzzTest
/// @notice Fuzz tests for KoruEscrow contract
contract KoruEscrowFuzzTest is BaseTest {
    // ============ CreateEscrow Fuzz Tests ============

    function testFuzz_CreateEscrow_VariousAmounts(uint256 amount) public {
        // Bound amount to reasonable values (1 USDC to 1M USDC)
        amount = bound(amount, ONE_USDC, 1_000_000 * ONE_USDC);

        // Fund and approve
        _fundUser(alice, amount);
        _approveEscrow(alice);

        uint256 aliceBalanceBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        uint256 escrowId = escrow.createEscrow(bob, amount);

        IKoruEscrow.Escrow memory e = escrow.getEscrow(escrowId);
        assertEq(e.amount, amount);
        assertEq(usdc.balanceOf(alice), aliceBalanceBefore - amount);
        assertEq(usdc.balanceOf(address(escrow)), amount);
    }

    function testFuzz_CreateEscrow_VariousRecipients(address recipient_) public {
        // Exclude zero address and self
        vm.assume(recipient_ != address(0));
        vm.assume(recipient_ != alice);

        vm.prank(alice);
        uint256 escrowId = escrow.createEscrow(recipient_, HUNDRED_USDC);

        IKoruEscrow.Escrow memory e = escrow.getEscrow(escrowId);
        assertEq(e.recipient, recipient_);
    }

    // ============ Timing Fuzz Tests ============

    function testFuzz_Accept_BeforeDeadline(uint256 timeElapsed) public {
        uint256 escrowId = _createDefaultEscrow();

        // Time elapsed should be within accept window
        timeElapsed = bound(timeElapsed, 0, ACCEPT_WINDOW);
        _fastForward(timeElapsed);

        _acceptEscrow(escrowId, recipient);
        _assertStatus(escrowId, IKoruEscrow.Status.Accepted);
    }

    function testFuzz_Accept_AfterDeadline_Reverts(uint256 timeElapsed) public {
        uint256 escrowId = _createDefaultEscrow();

        // Time elapsed should be past accept window
        timeElapsed = bound(timeElapsed, ACCEPT_WINDOW + 1, ACCEPT_WINDOW + 365 days);
        _fastForward(timeElapsed);

        vm.expectRevert();
        _acceptEscrow(escrowId, recipient);
    }

    function testFuzz_Dispute_BeforeDeadline(uint256 timeElapsed) public {
        uint256 escrowId = _createDefaultEscrow();
        _acceptEscrow(escrowId, recipient);

        // Time elapsed should be within dispute window
        timeElapsed = bound(timeElapsed, 0, DISPUTE_WINDOW);
        _fastForward(timeElapsed);

        _disputeEscrow(escrowId, depositor);
        _assertStatus(escrowId, IKoruEscrow.Status.Disputed);
    }

    function testFuzz_Dispute_AfterDeadline_Reverts(uint256 timeElapsed) public {
        uint256 escrowId = _createDefaultEscrow();
        _acceptEscrow(escrowId, recipient);

        // Time elapsed should be past dispute window
        timeElapsed = bound(timeElapsed, DISPUTE_WINDOW + 1, DISPUTE_WINDOW + 365 days);
        _fastForward(timeElapsed);

        vm.expectRevert();
        _disputeEscrow(escrowId, depositor);
    }

    function testFuzz_RecipientWithdraw_AfterDisputeWindow(uint256 timeElapsed) public {
        uint256 escrowId = _createDefaultEscrow();
        _acceptEscrow(escrowId, recipient);

        // Time elapsed should be past dispute window
        timeElapsed = bound(timeElapsed, DISPUTE_WINDOW + 1, DISPUTE_WINDOW + 365 days);
        _fastForward(timeElapsed);

        uint256 balanceBefore = usdc.balanceOf(recipient);

        _withdraw(escrowId, recipient);

        assertTrue(usdc.balanceOf(recipient) > balanceBefore);
    }

    // ============ Fee Calculation Fuzz Tests ============

    function testFuzz_FeeCalculation_NeverExceedsAmount(uint256 amount) public view {
        amount = bound(amount, 1, type(uint256).max / 10000); // Prevent overflow

        (uint256 fee, uint256 netAmount) = escrow.calculateFee(amount);

        assertTrue(fee <= amount, "Fee should never exceed amount");
        assertEq(fee + netAmount, amount, "Fee + net should equal amount");
    }

    function testFuzz_FeeCalculation_Accurate(uint256 amount, uint256 feeBps) public {
        amount = bound(amount, 1, 1_000_000 * ONE_USDC);
        feeBps = bound(feeBps, 0, 1000); // Max 10%

        // Set new fee
        vm.prank(owner);
        escrow.setFee(feeBps);

        (uint256 fee, uint256 netAmount) = escrow.calculateFee(amount);

        uint256 expectedFee = (amount * feeBps) / 10000;
        assertEq(fee, expectedFee, "Fee calculation incorrect");
        assertEq(netAmount, amount - expectedFee, "Net amount incorrect");
    }

    // ============ Multiple Escrows Fuzz Tests ============

    function testFuzz_MultipleEscrows_TrackingCorrect(uint8 numEscrows) public {
        numEscrows = uint8(bound(numEscrows, 1, 20));

        // Fund alice enough
        _fundUser(alice, uint256(numEscrows) * HUNDRED_USDC);
        _approveEscrow(alice);

        for (uint8 i = 0; i < numEscrows; i++) {
            vm.prank(alice);
            escrow.createEscrow(bob, HUNDRED_USDC);
        }

        uint256[] memory aliceEscrows = escrow.getEscrowsAsDepositor(alice);
        uint256[] memory bobEscrows = escrow.getEscrowsAsRecipient(bob);

        assertEq(aliceEscrows.length, numEscrows);
        assertEq(bobEscrows.length, numEscrows);
        assertEq(escrow.getEscrowCount(), numEscrows);
    }
}
