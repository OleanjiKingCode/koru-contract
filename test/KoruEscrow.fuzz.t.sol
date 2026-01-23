// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./BaseTest.sol";
import {KoruEscrow} from "../src/KoruEscrow.sol";
import {IKoruEscrow} from "../src/interfaces/IKoruEscrow.sol";
import {Errors} from "../src/libraries/Errors.sol";

/// @title KoruEscrowFuzzTest
/// @notice Comprehensive fuzz tests for KoruEscrow contract
/// @dev Tests 254-258 from the test suite specification
contract KoruEscrowFuzzTest is BaseTest {
    // ============ Constants ============
    uint256 public constant MIN_ESCROW_AMOUNT = 1 * 1e6;
    uint256 public constant MAX_ESCROW_AMOUNT = 1_000_000_000 * 1e6;
    uint256 public constant MAX_FEE_BPS = 1000;
    uint256 public constant COUNTER_DISPUTE_WINDOW = 7 days;
    uint256 public constant EMERGENCY_UNLOCK_PERIOD = 90 days;

    // ============================================
    // ============ TEST 254: Fuzz CreateEscrow ==
    // ============================================

    /// @notice Fuzz test createEscrow with random amounts within valid range
    function testFuzz_CreateEscrow_ValidAmounts(uint256 amount) public {
        // Bound amount to valid range
        amount = bound(amount, MIN_ESCROW_AMOUNT, MAX_ESCROW_AMOUNT);

        // Fund and approve
        _fundUser(alice, amount);
        _approveEscrow(alice);

        uint256 aliceBalanceBefore = usdc.balanceOf(alice);
        uint256 contractBalanceBefore = usdc.balanceOf(address(escrow));

        vm.prank(alice);
        uint256 escrowId = escrow.createEscrow(bob, amount);

        // Verify escrow was created correctly
        IKoruEscrow.Escrow memory e = escrow.getEscrow(escrowId);
        assertEq(e.amount, amount, "Amount mismatch");
        assertEq(e.depositor, alice, "Depositor mismatch");
        assertEq(e.recipient, bob, "Recipient mismatch");
        assertEq(uint8(e.status), uint8(IKoruEscrow.Status.Pending), "Status mismatch");

        // Verify balances
        assertEq(usdc.balanceOf(alice), aliceBalanceBefore - amount, "Alice balance incorrect");
        assertEq(usdc.balanceOf(address(escrow)), contractBalanceBefore + amount, "Contract balance incorrect");
    }

    /// @notice Fuzz test createEscrow with random recipients
    function testFuzz_CreateEscrow_RandomRecipients(address recipient_) public {
        // Exclude invalid recipients
        vm.assume(recipient_ != address(0));
        vm.assume(recipient_ != alice);
        vm.assume(recipient_ != address(escrow));

        vm.prank(alice);
        uint256 escrowId = escrow.createEscrow(recipient_, HUNDRED_USDC);

        IKoruEscrow.Escrow memory e = escrow.getEscrow(escrowId);
        assertEq(e.recipient, recipient_, "Recipient mismatch");
    }

    /// @notice Fuzz test createEscrow should revert for amounts below minimum
    function testFuzz_CreateEscrow_RevertsForAmountBelowMin(uint256 amount) public {
        amount = bound(amount, 0, MIN_ESCROW_AMOUNT - 1);

        vm.expectRevert(
            abi.encodeWithSelector(Errors.AmountTooLow.selector, amount, MIN_ESCROW_AMOUNT)
        );
        vm.prank(alice);
        escrow.createEscrow(bob, amount);
    }

    /// @notice Fuzz test createEscrow should revert for amounts above maximum
    function testFuzz_CreateEscrow_RevertsForAmountAboveMax(uint256 amount) public {
        // Bound to amounts above max (but not so high it overflows)
        amount = bound(amount, MAX_ESCROW_AMOUNT + 1, type(uint96).max);

        // Fund user with enough
        _fundUser(alice, amount);
        _approveEscrow(alice);

        vm.expectRevert(
            abi.encodeWithSelector(Errors.AmountTooHigh.selector, amount, MAX_ESCROW_AMOUNT)
        );
        vm.prank(alice);
        escrow.createEscrow(bob, amount);
    }

    // ============================================
    // ============ TEST 255: Fuzz Fee Calculations
    // ============================================

    /// @notice Fuzz test fee calculation never exceeds amount
    function testFuzz_FeeCalculation_NeverExceedsAmount(uint256 amount) public view {
        // Bound amount to prevent overflow in fee calculation
        amount = bound(amount, 1, type(uint256).max / MAX_FEE_BPS);

        (uint256 fee, uint256 netAmount) = escrow.calculateFee(amount);

        assertTrue(fee <= amount, "Fee should never exceed amount");
        assertEq(fee + netAmount, amount, "Fee + net should equal amount");
    }

    /// @notice Fuzz test fee calculation is accurate for various fee rates
    function testFuzz_FeeCalculation_AccurateForVariousRates(uint256 amount, uint256 feeBps) public {
        amount = bound(amount, MIN_ESCROW_AMOUNT, 1_000_000 * ONE_USDC);
        feeBps = bound(feeBps, 0, MAX_FEE_BPS);

        // Set new fee
        vm.prank(owner);
        escrow.setFee(feeBps);

        (uint256 fee, uint256 netAmount) = escrow.calculateFee(amount);

        uint256 expectedFee = (amount * feeBps) / 10000;
        assertEq(fee, expectedFee, "Fee calculation incorrect");
        assertEq(netAmount, amount - expectedFee, "Net amount incorrect");
    }

    /// @notice Fuzz test that fee + netAmount always equals original amount
    function testFuzz_FeeCalculation_NoTokensLost(uint256 amount, uint256 feeBps) public {
        amount = bound(amount, MIN_ESCROW_AMOUNT, MAX_ESCROW_AMOUNT);
        feeBps = bound(feeBps, 0, MAX_FEE_BPS);

        vm.prank(owner);
        escrow.setFee(feeBps);

        (uint256 fee, uint256 netAmount) = escrow.calculateFee(amount);

        // Critical invariant: no tokens should be lost to rounding
        assertEq(fee + netAmount, amount, "Tokens lost to rounding");
    }

    /// @notice Fuzz test locked fee params are used for escrow
    function testFuzz_FeeCalculation_LockedFeeParams(uint256 initialFee, uint256 newFee, uint256 amount) public {
        initialFee = bound(initialFee, 0, MAX_FEE_BPS);
        newFee = bound(newFee, 0, MAX_FEE_BPS);
        vm.assume(initialFee != newFee);
        amount = bound(amount, MIN_ESCROW_AMOUNT, 100_000 * ONE_USDC);

        // Set initial fee
        vm.prank(owner);
        escrow.setFee(initialFee);

        // Create escrow with initial fee
        _fundUser(alice, amount);
        _approveEscrow(alice);
        vm.prank(alice);
        uint256 escrowId = escrow.createEscrow(bob, amount);

        // Change fee
        vm.prank(owner);
        escrow.setFee(newFee);

        // Accept and release
        vm.prank(bob);
        escrow.accept(escrowId);
        vm.prank(alice);
        escrow.release(escrowId);

        // Withdraw and verify locked fee was used
        uint256 expectedFee = (amount * initialFee) / 10000;
        uint256 expectedNet = amount - expectedFee;
        uint256 bobBalanceBefore = usdc.balanceOf(bob);

        vm.prank(bob);
        escrow.withdraw(escrowId);

        assertEq(usdc.balanceOf(bob), bobBalanceBefore + expectedNet, "Should use locked fee");
    }

    // ============================================
    // ============ TEST 256: Fuzz Timestamp Boundaries
    // ============================================

    /// @notice Fuzz test accept within accept window always succeeds
    function testFuzz_Accept_WithinWindow(uint256 timeElapsed) public {
        uint256 escrowId = _createDefaultEscrow();

        // Time elapsed should be within accept window (including exact deadline)
        timeElapsed = bound(timeElapsed, 0, ACCEPT_WINDOW);
        _fastForward(timeElapsed);

        _acceptEscrow(escrowId, recipient);
        _assertStatus(escrowId, IKoruEscrow.Status.Accepted);
    }

    /// @notice Fuzz test accept after window always fails
    function testFuzz_Accept_AfterWindow_Reverts(uint256 timeElapsed) public {
        uint256 escrowId = _createDefaultEscrow();

        // Time elapsed should be past accept window
        timeElapsed = bound(timeElapsed, ACCEPT_WINDOW + 1, ACCEPT_WINDOW + 365 days);
        _fastForward(timeElapsed);

        vm.expectRevert();
        _acceptEscrow(escrowId, recipient);
    }

    /// @notice Fuzz test dispute within dispute window always succeeds
    function testFuzz_Dispute_WithinWindow(uint256 timeElapsed) public {
        uint256 escrowId = _createDefaultEscrow();
        _acceptEscrow(escrowId, recipient);

        // Time elapsed should be within dispute window (including exact deadline)
        timeElapsed = bound(timeElapsed, 0, DISPUTE_WINDOW);
        _fastForward(timeElapsed);

        _disputeEscrow(escrowId, depositor);
        _assertStatus(escrowId, IKoruEscrow.Status.Disputed);
    }

    /// @notice Fuzz test dispute after window always fails
    function testFuzz_Dispute_AfterWindow_Reverts(uint256 timeElapsed) public {
        uint256 escrowId = _createDefaultEscrow();
        _acceptEscrow(escrowId, recipient);

        // Time elapsed should be past dispute window
        timeElapsed = bound(timeElapsed, DISPUTE_WINDOW + 1, DISPUTE_WINDOW + 365 days);
        _fastForward(timeElapsed);

        vm.expectRevert();
        _disputeEscrow(escrowId, depositor);
    }

    /// @notice Fuzz test recipient withdraw after dispute window
    function testFuzz_RecipientWithdraw_AfterDisputeWindow(uint256 timeElapsed) public {
        uint256 escrowId = _createDefaultEscrow();
        _acceptEscrow(escrowId, recipient);

        // Time elapsed should be past dispute window
        timeElapsed = bound(timeElapsed, DISPUTE_WINDOW + 1, DISPUTE_WINDOW + 365 days);
        _fastForward(timeElapsed);

        uint256 balanceBefore = usdc.balanceOf(recipient);

        _withdraw(escrowId, recipient);

        assertTrue(usdc.balanceOf(recipient) > balanceBefore, "Recipient should receive funds");
        _assertStatus(escrowId, IKoruEscrow.Status.Completed);
    }

    /// @notice Fuzz test depositor withdraw after accept window
    function testFuzz_DepositorWithdraw_AfterAcceptWindow(uint256 timeElapsed) public {
        uint256 escrowId = _createDefaultEscrow();

        // Time elapsed should be past accept window
        timeElapsed = bound(timeElapsed, ACCEPT_WINDOW + 1, ACCEPT_WINDOW + 365 days);
        _fastForward(timeElapsed);

        uint256 balanceBefore = usdc.balanceOf(depositor);

        _withdraw(escrowId, depositor);

        assertEq(usdc.balanceOf(depositor), balanceBefore + HUNDRED_USDC, "Depositor should receive full refund");
        _assertStatus(escrowId, IKoruEscrow.Status.Expired);
    }

    /// @notice Fuzz test counter-dispute within window
    function testFuzz_CounterDispute_WithinWindow(uint256 timeElapsed) public {
        uint256 escrowId = _createDefaultEscrow();
        _acceptEscrow(escrowId, recipient);
        _disputeEscrow(escrowId, depositor);

        // Time elapsed should be within counter-dispute window
        timeElapsed = bound(timeElapsed, 0, COUNTER_DISPUTE_WINDOW);
        _fastForward(timeElapsed);

        vm.prank(recipient);
        escrow.counterDispute(escrowId);

        assertTrue(escrow.hasCounterDisputed(escrowId));
    }

    /// @notice Fuzz test emergency withdraw requires 90 days
    function testFuzz_EmergencyWithdraw_Requires90Days(uint256 timeElapsed) public {
        uint256 escrowId = _createDefaultEscrow();
        _acceptEscrow(escrowId, recipient);
        _disputeEscrow(escrowId, depositor);

        // Less than 90 days should fail
        timeElapsed = bound(timeElapsed, 0, EMERGENCY_UNLOCK_PERIOD - 1);
        _fastForward(timeElapsed);

        vm.expectRevert();
        vm.prank(depositor);
        escrow.emergencyWithdrawDisputed(escrowId);
    }

    /// @notice Fuzz test emergency withdraw succeeds after 90 days
    function testFuzz_EmergencyWithdraw_SucceedsAfter90Days(uint256 timeElapsed) public {
        uint256 escrowId = _createDefaultEscrow();
        _acceptEscrow(escrowId, recipient);
        _disputeEscrow(escrowId, depositor);

        // 90 days or more should succeed
        timeElapsed = bound(timeElapsed, EMERGENCY_UNLOCK_PERIOD, EMERGENCY_UNLOCK_PERIOD + 365 days);
        _fastForward(timeElapsed);

        vm.prank(depositor);
        escrow.emergencyWithdrawDisputed(escrowId);

        _assertStatus(escrowId, IKoruEscrow.Status.Completed);
    }

    // ============================================
    // ============ TEST 257: Fuzz Multiple Escrow Sequences
    // ============================================

    /// @notice Fuzz test multiple escrows can be created and tracked
    function testFuzz_MultipleEscrows_TrackingCorrect(uint8 numEscrows) public {
        numEscrows = uint8(bound(numEscrows, 1, 20));

        // Fund alice enough
        _fundUser(alice, uint256(numEscrows) * HUNDRED_USDC);
        _approveEscrow(alice);

        for (uint8 i = 0; i < numEscrows; i++) {
            vm.prank(alice);
            escrow.createEscrow(bob, HUNDRED_USDC);
        }

        assertEq(escrow.getEscrowCount(), numEscrows, "Escrow count mismatch");
    }

    /// @notice Fuzz test multiple escrows with various amounts
    function testFuzz_MultipleEscrows_VariousAmounts(uint8 numEscrows, uint256 seed) public {
        numEscrows = uint8(bound(numEscrows, 1, 10));

        uint256 totalAmount = 0;

        for (uint8 i = 0; i < numEscrows; i++) {
            // Generate pseudo-random amount for each escrow
            uint256 amount = bound(
                uint256(keccak256(abi.encodePacked(seed, i))),
                MIN_ESCROW_AMOUNT,
                100 * ONE_USDC
            );
            totalAmount += amount;

            _fundUser(alice, amount);
            _approveEscrow(alice);

            vm.prank(alice);
            uint256 escrowId = escrow.createEscrow(bob, amount);

            IKoruEscrow.Escrow memory e = escrow.getEscrow(escrowId);
            assertEq(e.amount, amount, "Amount mismatch");
        }

        // Contract should hold total amount
        assertEq(usdc.balanceOf(address(escrow)), totalAmount, "Contract balance mismatch");
    }

    /// @notice Fuzz test escrow IDs are always sequential
    function testFuzz_EscrowIds_Sequential(uint8 numEscrows) public {
        numEscrows = uint8(bound(numEscrows, 1, 20));

        _fundUser(alice, uint256(numEscrows) * HUNDRED_USDC);
        _approveEscrow(alice);

        for (uint8 i = 0; i < numEscrows; i++) {
            vm.prank(alice);
            uint256 escrowId = escrow.createEscrow(bob, HUNDRED_USDC);
            assertEq(escrowId, i, "Escrow ID should be sequential");
        }
    }

    // ============================================
    // ============ TEST 258: Fuzz State Transitions
    // ============================================

    /// @notice Fuzz test state transitions are valid
    function testFuzz_StateTransitions_Valid(uint256 actionSeed) public {
        uint256 escrowId = _createDefaultEscrow();

        // Random action based on seed
        uint256 action = actionSeed % 3;

        if (action == 0) {
            // Cancel path
            vm.prank(depositor);
            escrow.cancel(escrowId);
            _assertStatus(escrowId, IKoruEscrow.Status.Cancelled);
        } else if (action == 1) {
            // Accept path
            _acceptEscrow(escrowId, recipient);
            _assertStatus(escrowId, IKoruEscrow.Status.Accepted);
        } else {
            // Expire path
            _fastForward(ACCEPT_WINDOW + 1);
            _withdraw(escrowId, depositor);
            _assertStatus(escrowId, IKoruEscrow.Status.Expired);
        }
    }

    /// @notice Fuzz test accepted escrow state transitions
    function testFuzz_AcceptedStateTransitions(uint256 actionSeed) public {
        uint256 escrowId = _createDefaultEscrow();
        _acceptEscrow(escrowId, recipient);

        uint256 action = actionSeed % 3;

        if (action == 0) {
            // Release path
            _releaseEscrow(escrowId, depositor);
            _assertStatus(escrowId, IKoruEscrow.Status.Released);
        } else if (action == 1) {
            // Dispute path
            _disputeEscrow(escrowId, depositor);
            _assertStatus(escrowId, IKoruEscrow.Status.Disputed);
        } else {
            // Auto-complete path (wait for dispute window)
            _fastForward(DISPUTE_WINDOW + 1);
            _withdraw(escrowId, recipient);
            _assertStatus(escrowId, IKoruEscrow.Status.Completed);
        }
    }

    /// @notice Fuzz test dispute resolution transitions
    function testFuzz_DisputeResolution(bool depositorWins) public {
        uint256 escrowId = _createDefaultEscrow();
        _acceptEscrow(escrowId, recipient);
        _disputeEscrow(escrowId, depositor);

        address winner = depositorWins ? depositor : recipient;

        vm.prank(owner);
        escrow.resolveDispute(escrowId, winner);

        _assertStatus(escrowId, IKoruEscrow.Status.Completed);
    }

    // ============================================
    // ============ Additional Fuzz Tests ========
    // ============================================

    /// @notice Fuzz test setFee with valid values
    function testFuzz_SetFee_ValidValues(uint256 feeBps) public {
        feeBps = bound(feeBps, 0, MAX_FEE_BPS);

        vm.prank(owner);
        escrow.setFee(feeBps);

        assertEq(escrow.feeBps(), feeBps);
    }

    /// @notice Fuzz test setFee reverts for invalid values
    function testFuzz_SetFee_RevertsForInvalid(uint256 feeBps) public {
        feeBps = bound(feeBps, MAX_FEE_BPS + 1, type(uint256).max);

        vm.expectRevert(
            abi.encodeWithSelector(Errors.FeeTooHigh.selector, feeBps, MAX_FEE_BPS)
        );
        vm.prank(owner);
        escrow.setFee(feeBps);
    }

    /// @notice Fuzz test setFeeRecipient with valid addresses
    function testFuzz_SetFeeRecipient_ValidAddresses(address newRecipient) public {
        vm.assume(newRecipient != address(0));

        vm.prank(owner);
        escrow.setFeeRecipient(newRecipient);

        assertEq(escrow.feeRecipient(), newRecipient);
    }

    /// @notice Fuzz test complete flow with random amounts and fees
    function testFuzz_CompleteFlow(uint256 amount, uint256 feeBps) public {
        amount = bound(amount, MIN_ESCROW_AMOUNT, 1_000_000 * ONE_USDC);
        feeBps = bound(feeBps, 0, MAX_FEE_BPS);

        vm.prank(owner);
        escrow.setFee(feeBps);

        _fundUser(alice, amount);
        _approveEscrow(alice);

        vm.prank(alice);
        uint256 escrowId = escrow.createEscrow(bob, amount);

        vm.prank(bob);
        escrow.accept(escrowId);

        vm.prank(alice);
        escrow.release(escrowId);

        uint256 bobBalanceBefore = usdc.balanceOf(bob);
        uint256 feeRecipientBalanceBefore = usdc.balanceOf(feeRecipient);

        vm.prank(bob);
        escrow.withdraw(escrowId);

        // Verify fee calculation
        uint256 expectedFee = (amount * feeBps) / 10000;
        uint256 expectedNet = amount - expectedFee;

        assertEq(usdc.balanceOf(bob), bobBalanceBefore + expectedNet, "Bob received wrong amount");
        assertEq(usdc.balanceOf(feeRecipient), feeRecipientBalanceBefore + expectedFee, "Fee recipient received wrong amount");
    }

    /// @notice Fuzz test emergency withdraw splits correctly
    function testFuzz_EmergencyWithdraw_SplitsCorrectly(uint256 amount) public {
        amount = bound(amount, MIN_ESCROW_AMOUNT, 1_000_000 * ONE_USDC);

        _fundUser(alice, amount);
        _approveEscrow(alice);

        vm.prank(alice);
        uint256 escrowId = escrow.createEscrow(bob, amount);

        vm.prank(bob);
        escrow.accept(escrowId);

        vm.prank(alice);
        escrow.dispute(escrowId);

        _fastForward(EMERGENCY_UNLOCK_PERIOD);

        uint256 aliceBalanceBefore = usdc.balanceOf(alice);
        uint256 bobBalanceBefore = usdc.balanceOf(bob);

        vm.prank(alice);
        escrow.emergencyWithdrawDisputed(escrowId);

        // Verify 50/50 split (with possible 1 wei difference for odd amounts)
        uint256 halfAmount = amount / 2;
        assertEq(usdc.balanceOf(alice), aliceBalanceBefore + halfAmount, "Alice didn't receive half");
        assertEq(usdc.balanceOf(bob), bobBalanceBefore + (amount - halfAmount), "Bob didn't receive half");
    }

    /// @notice Fuzz test ownership transfer
    function testFuzz_OwnershipTransfer(address newOwner) public {
        vm.assume(newOwner != address(0));
        vm.assume(newOwner != owner);

        vm.prank(owner);
        escrow.transferOwnership(newOwner);

        assertEq(escrow.pendingOwner(), newOwner);

        vm.prank(newOwner);
        escrow.acceptOwnership();

        assertEq(escrow.owner(), newOwner);
        assertEq(escrow.pendingOwner(), address(0));
    }

    /// @notice Fuzz test that random users cannot perform admin actions
    function testFuzz_NonOwner_CannotPerformAdminActions(address randomUser) public {
        vm.assume(randomUser != owner);
        vm.assume(randomUser != address(0));

        vm.startPrank(randomUser);

        vm.expectRevert(Errors.NotOwner.selector);
        escrow.setFee(500);

        vm.expectRevert(Errors.NotOwner.selector);
        escrow.setFeeRecipient(alice);

        vm.expectRevert(Errors.NotOwner.selector);
        escrow.pause();

        vm.expectRevert(Errors.NotOwner.selector);
        escrow.transferOwnership(alice);

        vm.stopPrank();
    }
}
