// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./BaseTest.sol";
import {KoruEscrow} from "../src/KoruEscrow.sol";
import {IKoruEscrow} from "../src/interfaces/IKoruEscrow.sol";
import {Errors} from "../src/libraries/Errors.sol";

/// @title KoruEscrowSecurityTest
/// @notice Additional security, access control, and edge case tests
/// @dev Complements KoruEscrow.t.sol with missing test coverage
contract KoruEscrowSecurityTest is BaseTest {
    uint256 public constant COUNTER_DISPUTE_WINDOW = 7 days;
    uint256 public constant EMERGENCY_UNLOCK_PERIOD = 90 days;

    // ============================================
    // ========= ACCESS CONTROL - WRONG PARTY ====
    // ============================================

    /// @notice Recipient should NOT be able to call dispute
    function test_Dispute_RevertsIfCalledByRecipient() public {
        uint256 escrowId = _createDefaultEscrow();
        _acceptEscrow(escrowId, recipient);

        vm.expectRevert(Errors.NotDepositor.selector);
        vm.prank(recipient);
        escrow.dispute(escrowId);
    }

    /// @notice Depositor should NOT be able to call counterDispute
    function test_CounterDispute_RevertsIfCalledByDepositor() public {
        uint256 escrowId = _createDefaultEscrow();
        _acceptEscrow(escrowId, recipient);
        _disputeEscrow(escrowId, depositor);

        vm.expectRevert(Errors.NotRecipient.selector);
        vm.prank(depositor);
        escrow.counterDispute(escrowId);
    }

    /// @notice Recipient should NOT be able to call release
    function test_Release_RevertsIfCalledByRecipient() public {
        uint256 escrowId = _createDefaultEscrow();
        _acceptEscrow(escrowId, recipient);

        vm.expectRevert(Errors.NotDepositor.selector);
        vm.prank(recipient);
        escrow.release(escrowId);
    }

    /// @notice Recipient should NOT be able to call cancel
    function test_Cancel_RevertsIfCalledByRecipient() public {
        uint256 escrowId = _createDefaultEscrow();

        vm.expectRevert(Errors.NotDepositor.selector);
        vm.prank(recipient);
        escrow.cancel(escrowId);
    }

    /// @notice Depositor should NOT be able to call accept
    function test_Accept_RevertsIfCalledByDepositor() public {
        uint256 escrowId = _createDefaultEscrow();

        vm.expectRevert(Errors.NotRecipient.selector);
        vm.prank(depositor);
        escrow.accept(escrowId);
    }

    /// @notice Third party should NOT be able to call counterDispute
    function test_CounterDispute_RevertsIfCalledByThirdParty() public {
        uint256 escrowId = _createDefaultEscrow();
        _acceptEscrow(escrowId, recipient);
        _disputeEscrow(escrowId, depositor);

        vm.expectRevert(Errors.NotRecipient.selector);
        vm.prank(alice);
        escrow.counterDispute(escrowId);
    }

    // ============================================
    // ========= FRONT-RUNNING SCENARIOS =========
    // ============================================

    /// @notice Depositor can front-run recipient's accept with cancel
    function test_FrontRun_DepositorCancelsBeforeAccept() public {
        uint256 escrowId = _createDefaultEscrow();

        // Depositor cancels before recipient can accept
        vm.prank(depositor);
        escrow.cancel(escrowId);

        // Recipient's accept should fail
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.InvalidStatus.selector,
                escrowId,
                uint8(IKoruEscrow.Status.Cancelled),
                uint8(IKoruEscrow.Status.Pending)
            )
        );
        _acceptEscrow(escrowId, recipient);
    }

    /// @notice Depositor can front-run recipient's withdraw with dispute
    function test_FrontRun_DepositorDisputesBeforeWithdraw() public {
        uint256 escrowId = _createDefaultEscrow();
        _acceptEscrow(escrowId, recipient);

        // Depositor disputes within window
        _disputeEscrow(escrowId, depositor);

        // Fast forward past dispute window
        _fastForward(DISPUTE_WINDOW + 1);

        // Recipient cannot withdraw because it's now Disputed
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.InvalidStatus.selector,
                escrowId,
                uint8(IKoruEscrow.Status.Disputed),
                uint8(IKoruEscrow.Status.Accepted)
            )
        );
        _withdraw(escrowId, recipient);
    }

    /// @notice Owner can front-run emergency withdraw with resolveDispute
    function test_FrontRun_OwnerResolvesBeforeEmergencyWithdraw() public {
        uint256 escrowId = _createDefaultEscrow();
        _acceptEscrow(escrowId, recipient);
        _disputeEscrow(escrowId, depositor);

        // Wait for emergency period
        _fastForward(EMERGENCY_UNLOCK_PERIOD);

        // Owner resolves before users can emergency withdraw
        vm.prank(owner);
        escrow.resolveDispute(escrowId, depositor);

        // Emergency withdraw should now fail
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.InvalidStatus.selector,
                escrowId,
                uint8(IKoruEscrow.Status.Completed),
                uint8(IKoruEscrow.Status.Disputed)
            )
        );
        vm.prank(depositor);
        escrow.emergencyWithdrawDisputed(escrowId);
    }

    // ============================================
    // ========= INVALID STATE TRANSITIONS =======
    // ============================================

    /// @notice Cannot release after dispute
    function test_Release_RevertsIfDisputed() public {
        uint256 escrowId = _createDefaultEscrow();
        _acceptEscrow(escrowId, recipient);
        _disputeEscrow(escrowId, depositor);

        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.InvalidStatus.selector,
                escrowId,
                uint8(IKoruEscrow.Status.Disputed),
                uint8(IKoruEscrow.Status.Accepted)
            )
        );
        _releaseEscrow(escrowId, depositor);
    }

    /// @notice Cannot dispute after release
    function test_Dispute_RevertsIfReleased() public {
        uint256 escrowId = _createDefaultEscrow();
        _acceptEscrow(escrowId, recipient);
        _releaseEscrow(escrowId, depositor);

        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.InvalidStatus.selector,
                escrowId,
                uint8(IKoruEscrow.Status.Released),
                uint8(IKoruEscrow.Status.Accepted)
            )
        );
        _disputeEscrow(escrowId, depositor);
    }

    /// @notice Cannot accept cancelled escrow
    function test_Accept_RevertsIfCancelled() public {
        uint256 escrowId = _createDefaultEscrow();

        vm.prank(depositor);
        escrow.cancel(escrowId);

        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.InvalidStatus.selector,
                escrowId,
                uint8(IKoruEscrow.Status.Cancelled),
                uint8(IKoruEscrow.Status.Pending)
            )
        );
        _acceptEscrow(escrowId, recipient);
    }

    /// @notice Cannot cancel after acceptance
    function test_Cancel_RevertsIfAccepted() public {
        uint256 escrowId = _createDefaultEscrow();
        _acceptEscrow(escrowId, recipient);

        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.InvalidStatus.selector,
                escrowId,
                uint8(IKoruEscrow.Status.Accepted),
                uint8(IKoruEscrow.Status.Pending)
            )
        );
        vm.prank(depositor);
        escrow.cancel(escrowId);
    }

    /// @notice Cannot counter-dispute after resolution
    function test_CounterDispute_RevertsIfCompleted() public {
        uint256 escrowId = _createDefaultEscrow();
        _acceptEscrow(escrowId, recipient);
        _disputeEscrow(escrowId, depositor);

        // Owner resolves
        vm.prank(owner);
        escrow.resolveDispute(escrowId, recipient);

        // Counter-dispute should fail
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.InvalidStatus.selector,
                escrowId,
                uint8(IKoruEscrow.Status.Completed),
                uint8(IKoruEscrow.Status.Disputed)
            )
        );
        vm.prank(recipient);
        escrow.counterDispute(escrowId);
    }

    /// @notice Cannot cancel expired escrow
    function test_Cancel_RevertsIfExpired() public {
        uint256 escrowId = _createDefaultEscrow();
        _fastForward(ACCEPT_WINDOW + 1);

        // Depositor withdraws (marks as Expired)
        _withdraw(escrowId, depositor);

        // Cancel should fail
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.InvalidStatus.selector,
                escrowId,
                uint8(IKoruEscrow.Status.Expired),
                uint8(IKoruEscrow.Status.Pending)
            )
        );
        vm.prank(depositor);
        escrow.cancel(escrowId);
    }

    // ============================================
    // ========= DOUBLE OPERATION TESTS ==========
    // ============================================

    /// @notice Cannot release twice
    function test_Release_RevertsOnDoubleRelease() public {
        uint256 escrowId = _createDefaultEscrow();
        _acceptEscrow(escrowId, recipient);
        _releaseEscrow(escrowId, depositor);

        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.InvalidStatus.selector,
                escrowId,
                uint8(IKoruEscrow.Status.Released),
                uint8(IKoruEscrow.Status.Accepted)
            )
        );
        _releaseEscrow(escrowId, depositor);
    }

    /// @notice Cannot dispute twice
    function test_Dispute_RevertsOnDoubleDispute() public {
        uint256 escrowId = _createDefaultEscrow();
        _acceptEscrow(escrowId, recipient);
        _disputeEscrow(escrowId, depositor);

        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.InvalidStatus.selector,
                escrowId,
                uint8(IKoruEscrow.Status.Disputed),
                uint8(IKoruEscrow.Status.Accepted)
            )
        );
        _disputeEscrow(escrowId, depositor);
    }

    /// @notice Cannot withdraw twice (depositor)
    function test_Withdraw_RevertsOnDoubleWithdrawDepositor() public {
        uint256 escrowId = _createDefaultEscrow();
        _fastForward(ACCEPT_WINDOW + 1);

        _withdraw(escrowId, depositor);

        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.InvalidStatus.selector,
                escrowId,
                uint8(IKoruEscrow.Status.Expired),
                uint8(IKoruEscrow.Status.Pending)
            )
        );
        _withdraw(escrowId, depositor);
    }

    /// @notice Cannot withdraw twice (recipient)
    function test_Withdraw_RevertsOnDoubleWithdrawRecipient() public {
        uint256 escrowId = _createDefaultEscrow();
        _acceptEscrow(escrowId, recipient);
        _releaseEscrow(escrowId, depositor);

        _withdraw(escrowId, recipient);

        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.InvalidStatus.selector,
                escrowId,
                uint8(IKoruEscrow.Status.Completed),
                uint8(IKoruEscrow.Status.Accepted)
            )
        );
        _withdraw(escrowId, recipient);
    }

    /// @notice Cannot accept twice
    function test_Accept_RevertsOnDoubleAccept() public {
        uint256 escrowId = _createDefaultEscrow();
        _acceptEscrow(escrowId, recipient);

        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.InvalidStatus.selector,
                escrowId,
                uint8(IKoruEscrow.Status.Accepted),
                uint8(IKoruEscrow.Status.Pending)
            )
        );
        _acceptEscrow(escrowId, recipient);
    }

    // ============================================
    // ========= COUNTER-DISPUTE EDGE CASES ======
    // ============================================

    /// @notice Owner can resolve dispute within counter-dispute window
    function test_ResolveDispute_WorksWithinCounterDisputeWindow() public {
        uint256 escrowId = _createDefaultEscrow();
        _acceptEscrow(escrowId, recipient);
        _disputeEscrow(escrowId, depositor);

        // Immediately resolve (within counter-dispute window)
        vm.prank(owner);
        escrow.resolveDispute(escrowId, depositor);

        _assertStatus(escrowId, IKoruEscrow.Status.Completed);
    }

    /// @notice Owner can resolve dispute after counter-dispute window
    function test_ResolveDispute_WorksAfterCounterDisputeWindow() public {
        uint256 escrowId = _createDefaultEscrow();
        _acceptEscrow(escrowId, recipient);
        _disputeEscrow(escrowId, depositor);

        _fastForward(COUNTER_DISPUTE_WINDOW + 1);

        vm.prank(owner);
        escrow.resolveDispute(escrowId, depositor);

        _assertStatus(escrowId, IKoruEscrow.Status.Completed);
    }

    /// @notice Counter-dispute flag doesn't affect resolution outcome
    function test_ResolveDispute_WorksWithOrWithoutCounterDispute() public {
        // Test 1: Without counter-dispute
        uint256 escrowId1 = _createDefaultEscrow();
        _acceptEscrow(escrowId1, recipient);
        _disputeEscrow(escrowId1, depositor);

        assertFalse(escrow.hasCounterDisputed(escrowId1));

        vm.prank(owner);
        escrow.resolveDispute(escrowId1, recipient);

        // Test 2: With counter-dispute
        _fundUser(depositor, HUNDRED_USDC);
        uint256 escrowId2 = _createEscrow(depositor, recipient, HUNDRED_USDC);
        _acceptEscrow(escrowId2, recipient);
        _disputeEscrow(escrowId2, depositor);

        vm.prank(recipient);
        escrow.counterDispute(escrowId2);

        assertTrue(escrow.hasCounterDisputed(escrowId2));

        vm.prank(owner);
        escrow.resolveDispute(escrowId2, recipient);

        // Both should be Completed
        _assertStatus(escrowId1, IKoruEscrow.Status.Completed);
        _assertStatus(escrowId2, IKoruEscrow.Status.Completed);
    }

    /// @notice Counter-dispute at 1 second after window should fail
    function test_CounterDispute_FailsOneSecondAfterWindow() public {
        uint256 escrowId = _createDefaultEscrow();
        _acceptEscrow(escrowId, recipient);
        _disputeEscrow(escrowId, depositor);

        _fastForward(COUNTER_DISPUTE_WINDOW + 1);

        vm.expectRevert();
        vm.prank(recipient);
        escrow.counterDispute(escrowId);
    }

    // ============================================
    // ========= VIEW FUNCTION EDGE CASES ========
    // ============================================

    /// @notice canDispute returns false for Released status
    function test_CanDispute_ReturnsFalseForReleased() public {
        uint256 escrowId = _createDefaultEscrow();
        _acceptEscrow(escrowId, recipient);
        _releaseEscrow(escrowId, depositor);

        assertFalse(escrow.canDispute(escrowId));
    }

    /// @notice canDispute returns false for Disputed status
    function test_CanDispute_ReturnsFalseForDisputed() public {
        uint256 escrowId = _createDefaultEscrow();
        _acceptEscrow(escrowId, recipient);
        _disputeEscrow(escrowId, depositor);

        assertFalse(escrow.canDispute(escrowId));
    }

    /// @notice canRecipientWithdraw returns false for Disputed status
    function test_CanRecipientWithdraw_ReturnsFalseForDisputed() public {
        uint256 escrowId = _createDefaultEscrow();
        _acceptEscrow(escrowId, recipient);
        _disputeEscrow(escrowId, depositor);

        _fastForward(DISPUTE_WINDOW + 1);

        assertFalse(escrow.canRecipientWithdraw(escrowId));
    }

    /// @notice getDeadlines returns 0 for disputeDeadline if not accepted
    function test_GetDeadlines_ReturnsZeroDisputeDeadlineIfNotAccepted()
        public
    {
        uint256 escrowId = _createDefaultEscrow();

        IKoruEscrow.Deadlines memory deadlines = escrow.getDeadlines(escrowId);

        assertGt(deadlines.acceptDeadline, 0);
        assertEq(deadlines.disputeDeadline, 0);
    }

    /// @notice canAccept returns false for Cancelled status
    function test_CanAccept_ReturnsFalseForCancelled() public {
        uint256 escrowId = _createDefaultEscrow();

        vm.prank(depositor);
        escrow.cancel(escrowId);

        assertFalse(escrow.canAccept(escrowId));
    }

    /// @notice canDepositorWithdraw returns false for Accepted status
    function test_CanDepositorWithdraw_ReturnsFalseForAccepted() public {
        uint256 escrowId = _createDefaultEscrow();
        _acceptEscrow(escrowId, recipient);

        _fastForward(ACCEPT_WINDOW + 1);

        assertFalse(escrow.canDepositorWithdraw(escrowId));
    }

    // ============================================
    // ========= GRIEFING SCENARIOS ==============
    // ============================================

    /// @notice Recipient never accepting forces depositor to wait
    function test_Griefing_RecipientNeverAccepts() public {
        uint256 depositorBalanceBefore = usdc.balanceOf(depositor);
        uint256 escrowId = _createDefaultEscrow();

        // Recipient never accepts - depositor must wait full ACCEPT_WINDOW
        _fastForward(ACCEPT_WINDOW + 1);

        // Depositor can get refund (no fee)
        _withdraw(escrowId, depositor);

        assertEq(usdc.balanceOf(depositor), depositorBalanceBefore);
        _assertStatus(escrowId, IKoruEscrow.Status.Expired);
    }

    /// @notice Depositor can cancel immediately to grief recipient
    function test_Griefing_DepositorCancelsImmediately() public {
        uint256 escrowId = _createDefaultEscrow();

        // Depositor cancels immediately
        vm.prank(depositor);
        escrow.cancel(escrowId);

        // Recipient cannot accept
        vm.expectRevert();
        _acceptEscrow(escrowId, recipient);

        _assertStatus(escrowId, IKoruEscrow.Status.Cancelled);
    }

    /// @notice Depositor disputes just before window ends
    function test_Griefing_DepositorDisputesLastSecond() public {
        uint256 escrowId = _createDefaultEscrow();
        _acceptEscrow(escrowId, recipient);

        // Depositor waits until last second of dispute window
        _fastForward(DISPUTE_WINDOW);

        // Dispute at exactly the deadline
        _disputeEscrow(escrowId, depositor);

        _assertStatus(escrowId, IKoruEscrow.Status.Disputed);

        // Recipient now has to wait for resolution
        vm.expectRevert();
        _withdraw(escrowId, recipient);
    }

    // ============================================
    // ========= OWNERSHIP EDGE CASES ============
    // ============================================

    /// @notice Pending owner cannot do owner actions before accepting
    function test_PendingOwner_CannotActBeforeAccepting() public {
        vm.prank(owner);
        escrow.transferOwnership(alice);

        // Alice is pending but not yet owner
        vm.expectRevert(Errors.NotOwner.selector);
        vm.prank(alice);
        escrow.setFee(500);

        vm.expectRevert(Errors.NotOwner.selector);
        vm.prank(alice);
        escrow.pause();
    }

    /// @notice Old owner can still act while transfer is pending
    function test_OwnershipTransfer_OldOwnerCanActWhilePending() public {
        vm.prank(owner);
        escrow.transferOwnership(alice);

        // Original owner can still act
        vm.prank(owner);
        escrow.setFee(500);

        assertEq(escrow.feeBps(), 500);
    }

    /// @notice Old owner can override pending transfer
    function test_OwnershipTransfer_CanOverridePending() public {
        vm.prank(owner);
        escrow.transferOwnership(alice);

        // Owner changes mind, transfers to bob instead
        vm.prank(owner);
        escrow.transferOwnership(bob);

        assertEq(escrow.pendingOwner(), bob);

        // Alice cannot accept anymore
        vm.expectRevert(Errors.NotPendingOwner.selector);
        vm.prank(alice);
        escrow.acceptOwnership();

        // Bob can accept
        vm.prank(bob);
        escrow.acceptOwnership();

        assertEq(escrow.owner(), bob);
    }

    /// @notice Cannot transfer ownership to current owner
    function test_OwnershipTransfer_ToSelfAllowed() public {
        // This is allowed but pointless
        vm.prank(owner);
        escrow.transferOwnership(owner);

        assertEq(escrow.pendingOwner(), owner);

        vm.prank(owner);
        escrow.acceptOwnership();

        assertEq(escrow.owner(), owner);
    }

    // ============================================
    // ========= INTEGRATION: DISPUTE PATHS ======
    // ============================================

    /// @notice Full dispute flow - depositor wins, no counter-dispute
    function test_Integration_DisputeDepositorWinsNoCounterDispute() public {
        uint256 depositorBalanceBefore = usdc.balanceOf(depositor);

        uint256 escrowId = _createDefaultEscrow();
        _acceptEscrow(escrowId, recipient);
        _disputeEscrow(escrowId, depositor);

        // No counter-dispute
        assertFalse(escrow.hasCounterDisputed(escrowId));

        // Owner resolves in favor of depositor
        vm.prank(owner);
        escrow.resolveDispute(escrowId, depositor);

        // Depositor gets full refund (no fee)
        assertEq(usdc.balanceOf(depositor), depositorBalanceBefore);
        _assertStatus(escrowId, IKoruEscrow.Status.Completed);
    }

    /// @notice Full dispute flow - recipient wins with counter-dispute
    function test_Integration_DisputeRecipientWinsWithCounterDispute() public {
        uint256 recipientBalanceBefore = usdc.balanceOf(recipient);

        uint256 escrowId = _createDefaultEscrow();
        _acceptEscrow(escrowId, recipient);
        _disputeEscrow(escrowId, depositor);

        // Recipient counter-disputes
        vm.prank(recipient);
        escrow.counterDispute(escrowId);

        assertTrue(escrow.hasCounterDisputed(escrowId));

        // Owner resolves in favor of recipient
        (, uint256 expectedNet) = _calculateExpectedFee(HUNDRED_USDC);

        vm.prank(owner);
        escrow.resolveDispute(escrowId, recipient);

        assertEq(
            usdc.balanceOf(recipient),
            recipientBalanceBefore + expectedNet
        );
        _assertStatus(escrowId, IKoruEscrow.Status.Completed);
    }

    /// @notice Dispute then emergency withdraw after 90 days
    function test_Integration_DisputeThenEmergencyWithdraw() public {
        uint256 depositorBalanceBefore = usdc.balanceOf(depositor);
        uint256 recipientBalanceBefore = usdc.balanceOf(recipient);

        uint256 escrowId = _createDefaultEscrow();
        _acceptEscrow(escrowId, recipient);
        _disputeEscrow(escrowId, depositor);

        // Wait 90 days with no resolution
        _fastForward(EMERGENCY_UNLOCK_PERIOD);

        // Either party can trigger emergency withdraw
        vm.prank(recipient);
        escrow.emergencyWithdrawDisputed(escrowId);

        // 50/50 split
        uint256 halfAmount = HUNDRED_USDC / 2;
        assertEq(
            usdc.balanceOf(depositor),
            depositorBalanceBefore - HUNDRED_USDC + halfAmount
        );
        assertEq(
            usdc.balanceOf(recipient),
            recipientBalanceBefore + (HUNDRED_USDC - halfAmount)
        );
        _assertStatus(escrowId, IKoruEscrow.Status.Completed);
    }
}
