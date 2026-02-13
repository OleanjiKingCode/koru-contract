// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./BaseTest.sol";
import {IKoruEscrow} from "../src/interfaces/IKoruEscrow.sol";
import {Errors} from "../src/libraries/Errors.sol";

/// @title KoruEscrowSessionTest
/// @notice Tests for session-date-aware escrow timelines (V2)
/// @dev Covers createEscrowWithSession, accept/dispute/withdraw deadlines anchored to sessionDate
contract KoruEscrowSessionTest is BaseTest {
    // ============ Events ============
    event EscrowCreated(
        uint256 indexed escrowId,
        address indexed depositor,
        address indexed recipient,
        uint256 amount,
        uint256 acceptDeadline
    );

    event EscrowAccepted(
        uint256 indexed escrowId,
        address indexed recipient,
        uint256 acceptedAt,
        uint256 disputeDeadline
    );

    event EscrowExpired(uint256 indexed escrowId, uint256 expiredAt);

    event EscrowWithdrawn(
        uint256 indexed escrowId,
        address indexed withdrawer,
        uint256 amount,
        uint256 fee,
        uint256 netAmount,
        bool isDepositorWithdraw
    );

    // ============ Helpers ============

    /// @notice Create a session escrow 30 days in the future
    function _createFutureSessionEscrow() internal returns (uint256 escrowId, uint48 sessionDate) {
        sessionDate = uint48(block.timestamp + 30 days);
        escrowId = _createEscrowWithSession(depositor, recipient, HUNDRED_USDC, sessionDate);
    }

    /// @notice Create a session escrow with a custom offset from now
    function _createSessionEscrow(uint256 offset) internal returns (uint256 escrowId, uint48 sessionDate) {
        sessionDate = uint48(block.timestamp + offset);
        escrowId = _createEscrowWithSession(depositor, recipient, HUNDRED_USDC, sessionDate);
    }

    // ============================================
    // 1. CREATE ESCROW WITH SESSION DATE
    // ============================================

    /// @notice Should create escrow with session date stored correctly
    function test_CreateWithSession_StoresSessionDate() public {
        (uint256 escrowId, uint48 sessionDate) = _createFutureSessionEscrow();
        IKoruEscrow.Escrow memory e = escrow.getEscrow(escrowId);
        assertEq(e.sessionDate, sessionDate, "Session date not stored");
    }

    /// @notice Should create escrow with Pending status
    function test_CreateWithSession_PendingStatus() public {
        (uint256 escrowId,) = _createFutureSessionEscrow();
        _assertStatus(escrowId, IKoruEscrow.Status.Pending);
    }

    /// @notice Should transfer USDC from depositor to contract
    function test_CreateWithSession_TransfersUSDC() public {
        uint256 balBefore = usdc.balanceOf(depositor);
        _createFutureSessionEscrow();
        uint256 balAfter = usdc.balanceOf(depositor);
        assertEq(balBefore - balAfter, HUNDRED_USDC, "USDC not transferred");
    }

    /// @notice Should emit EscrowCreated with accept deadline = sessionDate + 24h
    function test_CreateWithSession_EmitsCorrectAcceptDeadline() public {
        uint48 sessionDate = uint48(block.timestamp + 30 days);

        vm.expectEmit(true, true, true, true);
        emit EscrowCreated(
            0,
            depositor,
            recipient,
            HUNDRED_USDC,
            uint256(sessionDate) + ACCEPT_WINDOW
        );

        _createEscrowWithSession(depositor, recipient, HUNDRED_USDC, sessionDate);
    }

    /// @notice Should revert if session date is in the past
    function test_CreateWithSession_RevertsOnPastDate() public {
        // Warp to a realistic timestamp so block.timestamp - 1 doesn't underflow
        vm.warp(1_700_000_000);
        uint48 pastDate = uint48(block.timestamp - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.InvalidSessionDate.selector,
                pastDate,
                block.timestamp
            )
        );
        _createEscrowWithSession(depositor, recipient, HUNDRED_USDC, pastDate);
    }

    /// @notice Should revert if session date equals current timestamp
    function test_CreateWithSession_RevertsOnCurrentTimestamp() public {
        uint48 nowDate = uint48(block.timestamp);
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.InvalidSessionDate.selector,
                nowDate,
                block.timestamp
            )
        );
        _createEscrowWithSession(depositor, recipient, HUNDRED_USDC, nowDate);
    }

    /// @notice Session date of 0 should fall back to V1 (createEscrow) behavior via createEscrowWithSession
    function test_CreateWithSession_ZeroSessionDateIsV1() public {
        vm.prank(depositor);
        uint256 escrowId = escrow.createEscrowWithSession(recipient, HUNDRED_USDC, 0);

        IKoruEscrow.Escrow memory e = escrow.getEscrow(escrowId);
        assertEq(e.sessionDate, 0, "Session date should be 0");

        // Accept deadline should be createdAt + 24h (V1 behavior)
        IKoruEscrow.Deadlines memory d = escrow.getDeadlines(escrowId);
        assertEq(d.acceptDeadline, uint256(e.createdAt) + ACCEPT_WINDOW, "V1 accept deadline mismatch");
    }

    /// @notice V1 createEscrow should store sessionDate = 0
    function test_CreateV1_SessionDateIsZero() public {
        uint256 escrowId = _createDefaultEscrow();
        IKoruEscrow.Escrow memory e = escrow.getEscrow(escrowId);
        assertEq(e.sessionDate, 0, "V1 escrow should have sessionDate = 0");
    }

    // ============================================
    // 2. ACCEPT DEADLINE (sessionDate + 24h)
    // ============================================

    /// @notice getDeadlines should return sessionDate + ACCEPT_WINDOW for session escrows
    function test_AcceptDeadline_AnchorsToSessionDate() public {
        (uint256 escrowId, uint48 sessionDate) = _createFutureSessionEscrow();

        IKoruEscrow.Deadlines memory d = escrow.getDeadlines(escrowId);
        assertEq(
            d.acceptDeadline,
            uint256(sessionDate) + ACCEPT_WINDOW,
            "Accept deadline should be sessionDate + 24h"
        );
    }

    /// @notice Recipient should be able to accept right before sessionDate + 24h
    function test_Accept_SucceedsBeforeSessionDeadline() public {
        (uint256 escrowId, uint48 sessionDate) = _createFutureSessionEscrow();

        // Warp to 1 second before accept deadline
        vm.warp(uint256(sessionDate) + ACCEPT_WINDOW - 1);

        _acceptEscrow(escrowId, recipient);
        _assertStatus(escrowId, IKoruEscrow.Status.Accepted);
    }

    /// @notice Recipient should be able to accept exactly at sessionDate + 24h
    function test_Accept_SucceedsAtExactDeadline() public {
        (uint256 escrowId, uint48 sessionDate) = _createFutureSessionEscrow();

        // Warp to exactly the accept deadline
        vm.warp(uint256(sessionDate) + ACCEPT_WINDOW);

        _acceptEscrow(escrowId, recipient);
        _assertStatus(escrowId, IKoruEscrow.Status.Accepted);
    }

    /// @notice Recipient should NOT be able to accept after sessionDate + 24h
    function test_Accept_RevertsAfterSessionDeadline() public {
        (uint256 escrowId, uint48 sessionDate) = _createFutureSessionEscrow();

        uint256 deadline = uint256(sessionDate) + ACCEPT_WINDOW;
        // Warp to 1 second past accept deadline
        vm.warp(deadline + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.AcceptDeadlinePassed.selector,
                escrowId,
                deadline,
                block.timestamp
            )
        );
        vm.prank(recipient);
        escrow.accept(escrowId);
    }

    /// @notice Recipient can accept long before the session date (e.g., months ahead)
    function test_Accept_SucceedsWellBeforeSessionDate() public {
        // Book a session 90 days out
        (uint256 escrowId,) = _createSessionEscrow(90 days);

        // Accept immediately (same block as creation)
        _acceptEscrow(escrowId, recipient);
        _assertStatus(escrowId, IKoruEscrow.Status.Accepted);
    }

    /// @notice canAccept returns true before sessionDate + 24h
    function test_CanAccept_TrueBeforeDeadline() public {
        (uint256 escrowId, uint48 sessionDate) = _createFutureSessionEscrow();

        // Warp to just before deadline
        vm.warp(uint256(sessionDate) + ACCEPT_WINDOW - 1);
        assertTrue(escrow.canAccept(escrowId), "canAccept should be true before deadline");
    }

    /// @notice canAccept returns false after sessionDate + 24h
    function test_CanAccept_FalseAfterDeadline() public {
        (uint256 escrowId, uint48 sessionDate) = _createFutureSessionEscrow();

        vm.warp(uint256(sessionDate) + ACCEPT_WINDOW + 1);
        assertFalse(escrow.canAccept(escrowId), "canAccept should be false after deadline");
    }

    /// @notice getEffectiveStatus returns Expired after accept deadline passes
    function test_EffectiveStatus_ExpiredAfterSessionDeadline() public {
        (uint256 escrowId, uint48 sessionDate) = _createFutureSessionEscrow();

        vm.warp(uint256(sessionDate) + ACCEPT_WINDOW + 1);
        assertEq(
            uint8(escrow.getEffectiveStatus(escrowId)),
            uint8(IKoruEscrow.Status.Expired),
            "Should be effectively Expired"
        );
    }

    /// @notice getEffectiveStatus returns Pending before accept deadline
    function test_EffectiveStatus_PendingBeforeSessionDeadline() public {
        (uint256 escrowId, uint48 sessionDate) = _createFutureSessionEscrow();

        // Even 29 days later (1 day before session), still Pending
        vm.warp(uint256(sessionDate) - 1 days);
        assertEq(
            uint8(escrow.getEffectiveStatus(escrowId)),
            uint8(IKoruEscrow.Status.Pending),
            "Should still be Pending before session deadline"
        );
    }

    // ============================================
    // 3. DEPOSITOR WITHDRAW (RECLAIM) WITH SESSION
    // ============================================

    /// @notice Depositor can reclaim after sessionDate + 24h if not accepted
    function test_DepositorWithdraw_SucceedsAfterSessionDeadline() public {
        (uint256 escrowId, uint48 sessionDate) = _createFutureSessionEscrow();

        vm.warp(uint256(sessionDate) + ACCEPT_WINDOW + 1);

        uint256 balBefore = usdc.balanceOf(depositor);
        _withdraw(escrowId, depositor);
        uint256 balAfter = usdc.balanceOf(depositor);

        assertEq(balAfter - balBefore, HUNDRED_USDC, "Depositor should get full refund");
        _assertStatus(escrowId, IKoruEscrow.Status.Expired);
    }

    /// @notice Depositor CANNOT reclaim before sessionDate + 24h
    function test_DepositorWithdraw_RevertsBeforeSessionDeadline() public {
        (uint256 escrowId, uint48 sessionDate) = _createFutureSessionEscrow();

        uint256 deadline = uint256(sessionDate) + ACCEPT_WINDOW;
        // Warp to just before session date (still within accept window)
        vm.warp(uint256(sessionDate) - 1 hours);

        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.AcceptDeadlineNotReached.selector,
                escrowId,
                deadline,
                block.timestamp
            )
        );
        vm.prank(depositor);
        escrow.withdraw(escrowId);
    }

    /// @notice Depositor CANNOT reclaim at createdAt + 24h for session escrows (must wait for sessionDate + 24h)
    function test_DepositorWithdraw_CannotReclaimAtCreatedAtPlus24h() public {
        // Create escrow for session 60 days from now
        (uint256 escrowId, uint48 sessionDate) = _createSessionEscrow(60 days);

        uint256 deadline = uint256(sessionDate) + ACCEPT_WINDOW;
        // Warp to createdAt + 24h — this would be the V1 deadline, but should NOT work for session escrows
        _fastForward(ACCEPT_WINDOW + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.AcceptDeadlineNotReached.selector,
                escrowId,
                deadline,
                block.timestamp
            )
        );
        vm.prank(depositor);
        escrow.withdraw(escrowId);
    }

    /// @notice canDepositorWithdraw returns true only after sessionDate + 24h
    function test_CanDepositorWithdraw_SessionAware() public {
        (uint256 escrowId, uint48 sessionDate) = _createFutureSessionEscrow();

        // Before session date
        vm.warp(uint256(sessionDate) - 1);
        assertFalse(escrow.canDepositorWithdraw(escrowId), "Should not be withdrawable before session");

        // After session date but within 24h window
        vm.warp(uint256(sessionDate) + 12 hours);
        assertFalse(escrow.canDepositorWithdraw(escrowId), "Should not be withdrawable within accept window");

        // After sessionDate + 24h
        vm.warp(uint256(sessionDate) + ACCEPT_WINDOW + 1);
        assertTrue(escrow.canDepositorWithdraw(escrowId), "Should be withdrawable after accept deadline");
    }

    // ============================================
    // 4. DISPUTE DEADLINE (sessionDate + 48h)
    // ============================================

    /// @notice After accepting a session escrow, dispute deadline = sessionDate + 48h
    function test_DisputeDeadline_AnchorsToSessionDate() public {
        (uint256 escrowId, uint48 sessionDate) = _createFutureSessionEscrow();

        // Accept immediately
        _acceptEscrow(escrowId, recipient);

        IKoruEscrow.Deadlines memory d = escrow.getDeadlines(escrowId);
        assertEq(
            d.disputeDeadline,
            uint256(sessionDate) + DISPUTE_WINDOW,
            "Dispute deadline should be sessionDate + 48h"
        );
    }

    /// @notice Dispute deadline for V1 (no session) should be acceptedAt + 48h
    function test_DisputeDeadline_V1_AnchorsToAcceptedAt() public {
        uint256 escrowId = _createDefaultEscrow();

        // Fast forward 6h then accept
        _fastForward(6 hours);
        _acceptEscrow(escrowId, recipient);

        IKoruEscrow.Escrow memory e = escrow.getEscrow(escrowId);
        IKoruEscrow.Deadlines memory d = escrow.getDeadlines(escrowId);
        assertEq(
            d.disputeDeadline,
            uint256(e.acceptedAt) + DISPUTE_WINDOW,
            "V1 dispute deadline should be acceptedAt + 48h"
        );
    }

    /// @notice Depositor can dispute within sessionDate + 48h
    function test_Dispute_SucceedsBeforeSessionDisputeDeadline() public {
        (uint256 escrowId, uint48 sessionDate) = _createFutureSessionEscrow();

        // Accept immediately
        _acceptEscrow(escrowId, recipient);

        // Warp to 1 second before dispute deadline
        vm.warp(uint256(sessionDate) + DISPUTE_WINDOW - 1);

        _disputeEscrow(escrowId, depositor);
        _assertStatus(escrowId, IKoruEscrow.Status.Disputed);
    }

    /// @notice Depositor CANNOT dispute after sessionDate + 48h
    function test_Dispute_RevertsAfterSessionDisputeDeadline() public {
        (uint256 escrowId, uint48 sessionDate) = _createFutureSessionEscrow();

        _acceptEscrow(escrowId, recipient);

        uint256 disputeDeadline = uint256(sessionDate) + DISPUTE_WINDOW;
        vm.warp(disputeDeadline + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.DisputeDeadlinePassed.selector,
                escrowId,
                disputeDeadline,
                block.timestamp
            )
        );
        vm.prank(depositor);
        escrow.dispute(escrowId);
    }

    /// @notice canDispute returns correct values around sessionDate + 48h
    function test_CanDispute_SessionAware() public {
        (uint256 escrowId, uint48 sessionDate) = _createFutureSessionEscrow();
        _acceptEscrow(escrowId, recipient);

        // Before session + 48h
        vm.warp(uint256(sessionDate) + DISPUTE_WINDOW - 1);
        assertTrue(escrow.canDispute(escrowId), "Should be disputable before deadline");

        // After session + 48h
        vm.warp(uint256(sessionDate) + DISPUTE_WINDOW + 1);
        assertFalse(escrow.canDispute(escrowId), "Should not be disputable after deadline");
    }

    // ============================================
    // 5. RECIPIENT WITHDRAW WITH SESSION
    // ============================================

    /// @notice Recipient can withdraw after sessionDate + 48h (dispute window passed)
    function test_RecipientWithdraw_SucceedsAfterSessionDisputeWindow() public {
        (uint256 escrowId, uint48 sessionDate) = _createFutureSessionEscrow();

        _acceptEscrow(escrowId, recipient);

        // Warp past dispute deadline
        vm.warp(uint256(sessionDate) + DISPUTE_WINDOW + 1);

        uint256 balBefore = usdc.balanceOf(recipient);
        _withdraw(escrowId, recipient);
        uint256 balAfter = usdc.balanceOf(recipient);

        // Recipient gets amount minus fee
        (, uint256 expectedNet) = _calculateExpectedFee(HUNDRED_USDC);
        assertEq(balAfter - balBefore, expectedNet, "Recipient should receive net amount");
        _assertStatus(escrowId, IKoruEscrow.Status.Completed);
    }

    /// @notice Recipient CANNOT withdraw before sessionDate + 48h even if accepted long ago
    function test_RecipientWithdraw_RevertsBeforeSessionDisputeWindow() public {
        (uint256 escrowId, uint48 sessionDate) = _createFutureSessionEscrow();

        // Accept immediately
        _acceptEscrow(escrowId, recipient);

        // Warp to acceptedAt + 48h (which would be the V1 deadline)
        // but session is 30 days away so dispute window hasn't passed
        _fastForward(DISPUTE_WINDOW + 1);

        uint256 disputeDeadline = uint256(sessionDate) + DISPUTE_WINDOW;

        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.DisputeDeadlineNotReached.selector,
                escrowId,
                disputeDeadline,
                block.timestamp
            )
        );
        vm.prank(recipient);
        escrow.withdraw(escrowId);
    }

    /// @notice canRecipientWithdraw respects sessionDate-based dispute window
    function test_CanRecipientWithdraw_SessionAware() public {
        (uint256 escrowId, uint48 sessionDate) = _createFutureSessionEscrow();
        _acceptEscrow(escrowId, recipient);

        // Before session + 48h
        vm.warp(uint256(sessionDate) + DISPUTE_WINDOW - 1);
        assertFalse(escrow.canRecipientWithdraw(escrowId), "Should not be withdrawable before dispute deadline");

        // After session + 48h
        vm.warp(uint256(sessionDate) + DISPUTE_WINDOW + 1);
        assertTrue(escrow.canRecipientWithdraw(escrowId), "Should be withdrawable after dispute deadline");
    }

    /// @notice Recipient can still withdraw immediately if depositor releases early
    function test_RecipientWithdraw_ReleasedIgnoresSessionDate() public {
        (uint256 escrowId,) = _createFutureSessionEscrow();

        _acceptEscrow(escrowId, recipient);
        _releaseEscrow(escrowId, depositor);

        // Withdraw immediately — no need to wait for session + 48h
        uint256 balBefore = usdc.balanceOf(recipient);
        _withdraw(escrowId, recipient);
        uint256 balAfter = usdc.balanceOf(recipient);

        (, uint256 expectedNet) = _calculateExpectedFee(HUNDRED_USDC);
        assertEq(balAfter - balBefore, expectedNet, "Should withdraw immediately after release");
        _assertStatus(escrowId, IKoruEscrow.Status.Completed);
    }

    // ============================================
    // 6. FULL LIFECYCLE WITH SESSION DATE
    // ============================================

    /// @notice Full happy path: create with session -> accept -> wait -> recipient withdraws
    function test_FullLifecycle_SessionEscrow_HappyPath() public {
        uint48 sessionDate = uint48(block.timestamp + 7 days);
        uint256 escrowId = _createEscrowWithSession(depositor, recipient, HUNDRED_USDC, sessionDate);

        // Verify deadlines
        IKoruEscrow.Deadlines memory d = escrow.getDeadlines(escrowId);
        assertEq(d.acceptDeadline, uint256(sessionDate) + ACCEPT_WINDOW);
        assertEq(d.disputeDeadline, 0, "No dispute deadline before accept");

        // Accept 3 days later
        vm.warp(block.timestamp + 3 days);
        _acceptEscrow(escrowId, recipient);

        // Verify dispute deadline now set
        d = escrow.getDeadlines(escrowId);
        assertEq(d.disputeDeadline, uint256(sessionDate) + DISPUTE_WINDOW);

        // Warp past dispute window
        vm.warp(uint256(sessionDate) + DISPUTE_WINDOW + 1);

        // Recipient withdraws
        _withdraw(escrowId, recipient);
        _assertStatus(escrowId, IKoruEscrow.Status.Completed);
    }

    /// @notice Full path: create with session -> no accept -> depositor reclaims
    function test_FullLifecycle_SessionEscrow_Expired() public {
        uint48 sessionDate = uint48(block.timestamp + 14 days);
        uint256 escrowId = _createEscrowWithSession(depositor, recipient, HUNDRED_USDC, sessionDate);

        // Warp past accept deadline
        vm.warp(uint256(sessionDate) + ACCEPT_WINDOW + 1);

        // Depositor reclaims
        uint256 balBefore = usdc.balanceOf(depositor);
        _withdraw(escrowId, depositor);
        uint256 balAfter = usdc.balanceOf(depositor);

        assertEq(balAfter - balBefore, HUNDRED_USDC, "Full refund on expiry");
        _assertStatus(escrowId, IKoruEscrow.Status.Expired);
    }

    /// @notice Full path: create with session -> accept -> dispute within window
    function test_FullLifecycle_SessionEscrow_Disputed() public {
        uint48 sessionDate = uint48(block.timestamp + 5 days);
        uint256 escrowId = _createEscrowWithSession(depositor, recipient, HUNDRED_USDC, sessionDate);

        // Accept
        _acceptEscrow(escrowId, recipient);

        // Dispute within sessionDate + 48h
        vm.warp(uint256(sessionDate) + 1 hours);
        _disputeEscrow(escrowId, depositor);
        _assertStatus(escrowId, IKoruEscrow.Status.Disputed);
    }

    /// @notice Cancel a session escrow before acceptance
    function test_Cancel_SessionEscrow() public {
        (uint256 escrowId,) = _createFutureSessionEscrow();

        uint256 balBefore = usdc.balanceOf(depositor);
        vm.prank(depositor);
        escrow.cancel(escrowId);
        uint256 balAfter = usdc.balanceOf(depositor);

        assertEq(balAfter - balBefore, HUNDRED_USDC, "Full refund on cancel");
        _assertStatus(escrowId, IKoruEscrow.Status.Cancelled);
    }

    // ============================================
    // 7. EDGE CASES
    // ============================================

    /// @notice Session date 1 second in the future should work
    function test_CreateWithSession_MinimalFutureDate() public {
        uint48 sessionDate = uint48(block.timestamp + 1);
        uint256 escrowId = _createEscrowWithSession(depositor, recipient, HUNDRED_USDC, sessionDate);

        IKoruEscrow.Escrow memory e = escrow.getEscrow(escrowId);
        assertEq(e.sessionDate, sessionDate);
    }

    /// @notice Session date far in the future (1 year) should work
    function test_CreateWithSession_FarFutureDate() public {
        uint48 sessionDate = uint48(block.timestamp + 365 days);
        uint256 escrowId = _createEscrowWithSession(depositor, recipient, HUNDRED_USDC, sessionDate);

        IKoruEscrow.Deadlines memory d = escrow.getDeadlines(escrowId);
        assertEq(d.acceptDeadline, uint256(sessionDate) + ACCEPT_WINDOW);
    }

    /// @notice Multiple session escrows between same parties should each have independent deadlines
    function test_MultipleSessionEscrows_IndependentDeadlines() public {
        uint48 session1 = uint48(block.timestamp + 7 days);
        uint48 session2 = uint48(block.timestamp + 30 days);

        _fundUser(depositor, THOUSAND_USDC); // ensure enough funds
        uint256 id1 = _createEscrowWithSession(depositor, recipient, HUNDRED_USDC, session1);
        uint256 id2 = _createEscrowWithSession(depositor, recipient, HUNDRED_USDC, session2);

        IKoruEscrow.Deadlines memory d1 = escrow.getDeadlines(id1);
        IKoruEscrow.Deadlines memory d2 = escrow.getDeadlines(id2);

        assertEq(d1.acceptDeadline, uint256(session1) + ACCEPT_WINDOW);
        assertEq(d2.acceptDeadline, uint256(session2) + ACCEPT_WINDOW);
        assertTrue(d2.acceptDeadline > d1.acceptDeadline, "Later session should have later deadline");
    }

    /// @notice Dispute deadline should be 0 before acceptance for session escrows
    function test_DisputeDeadline_ZeroBeforeAcceptance() public {
        (uint256 escrowId,) = _createFutureSessionEscrow();

        IKoruEscrow.Deadlines memory d = escrow.getDeadlines(escrowId);
        assertEq(d.disputeDeadline, 0, "Dispute deadline should be 0 before acceptance");
    }

    /// @notice V1 and V2 escrows should coexist with correct independent deadlines
    function test_V1AndV2_Coexist() public {
        // Create V1 escrow (immediate)
        uint256 v1Id = _createEscrow(depositor, recipient, HUNDRED_USDC);

        // Create V2 escrow (session in 30 days)
        uint48 sessionDate = uint48(block.timestamp + 30 days);
        _fundUser(depositor, THOUSAND_USDC);
        uint256 v2Id = _createEscrowWithSession(depositor, recipient, HUNDRED_USDC, sessionDate);

        IKoruEscrow.Deadlines memory d1 = escrow.getDeadlines(v1Id);
        IKoruEscrow.Deadlines memory d2 = escrow.getDeadlines(v2Id);

        // V1: createdAt + 24h
        IKoruEscrow.Escrow memory e1 = escrow.getEscrow(v1Id);
        assertEq(d1.acceptDeadline, uint256(e1.createdAt) + ACCEPT_WINDOW, "V1 deadline mismatch");

        // V2: sessionDate + 24h
        assertEq(d2.acceptDeadline, uint256(sessionDate) + ACCEPT_WINDOW, "V2 deadline mismatch");

        // V2 deadline is much later than V1
        assertTrue(d2.acceptDeadline > d1.acceptDeadline + 29 days, "V2 should be ~30 days later");
    }
}
