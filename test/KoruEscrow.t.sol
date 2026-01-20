// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./BaseTest.sol";
import {KoruEscrow} from "../src/KoruEscrow.sol";
import {IKoruEscrow} from "../src/interfaces/IKoruEscrow.sol";
import {Errors} from "../src/libraries/Errors.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title KoruEscrowTest
/// @notice Comprehensive unit tests for KoruEscrow contract
contract KoruEscrowTest is BaseTest {
    // ============ Events for testing ============
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

    event EscrowReleased(
        uint256 indexed escrowId,
        address indexed depositor,
        uint256 releasedAt
    );

    event EscrowWithdrawn(
        uint256 indexed escrowId,
        address indexed withdrawer,
        uint256 amount,
        uint256 fee,
        uint256 netAmount,
        bool isDepositorWithdraw
    );

    event EscrowDisputed(
        uint256 indexed escrowId,
        address indexed depositor,
        uint256 disputedAt
    );

    event DisputeResolved(
        uint256 indexed escrowId,
        address indexed winner,
        address indexed resolver,
        uint256 amount,
        uint256 fee
    );

    // ============ Constructor Tests ============

    function test_Constructor_SetsInitialValues() public view {
        assertEq(address(escrow.usdc()), address(usdc));
        assertEq(escrow.feeBps(), INITIAL_FEE_BPS);
        assertEq(escrow.feeRecipient(), feeRecipient);
        assertEq(escrow.owner(), owner);
        assertEq(escrow.paused(), false);
    }

    function test_Initialize_RevertsOnZeroUsdc() public {
        vm.prank(owner);
        KoruEscrow implementation = new KoruEscrow();
        
        bytes memory initData = abi.encodeWithSelector(
            KoruEscrow.initialize.selector,
            address(0),
            INITIAL_FEE_BPS,
            feeRecipient
        );
        
        vm.expectRevert(Errors.ZeroAddress.selector);
        new ERC1967Proxy(address(implementation), initData);
    }

    function test_Initialize_RevertsOnZeroFeeRecipient() public {
        vm.prank(owner);
        KoruEscrow implementation = new KoruEscrow();
        
        bytes memory initData = abi.encodeWithSelector(
            KoruEscrow.initialize.selector,
            address(usdc),
            INITIAL_FEE_BPS,
            address(0)
        );
        
        vm.expectRevert(Errors.ZeroAddress.selector);
        new ERC1967Proxy(address(implementation), initData);
    }

    function test_Initialize_RevertsOnFeeTooHigh() public {
        vm.prank(owner);
        KoruEscrow implementation = new KoruEscrow();
        
        bytes memory initData = abi.encodeWithSelector(
            KoruEscrow.initialize.selector,
            address(usdc),
            1001,
            feeRecipient
        );
        
        vm.expectRevert(
            abi.encodeWithSelector(Errors.FeeTooHigh.selector, 1001, 1000)
        );
        new ERC1967Proxy(address(implementation), initData);
    }

    // ============ CreateEscrow Tests ============

    function test_CreateEscrow_Success() public {
        uint256 amount = HUNDRED_USDC;

        uint256 depositorBalanceBefore = usdc.balanceOf(depositor);
        uint256 contractBalanceBefore = usdc.balanceOf(address(escrow));

        vm.expectEmit(true, true, true, true);
        emit EscrowCreated(
            0,
            depositor,
            recipient,
            amount,
            block.timestamp + ACCEPT_WINDOW
        );

        uint256 escrowId = _createEscrow(depositor, recipient, amount);

        // Check escrow data
        IKoruEscrow.Escrow memory e = escrow.getEscrow(escrowId);
        assertEq(e.depositor, depositor);
        assertEq(e.recipient, recipient);
        assertEq(e.amount, amount);
        assertEq(e.createdAt, block.timestamp);
        assertEq(e.acceptedAt, 0);
        assertEq(uint8(e.status), uint8(IKoruEscrow.Status.Pending));

        // Check balances
        assertEq(usdc.balanceOf(depositor), depositorBalanceBefore - amount);
        assertEq(
            usdc.balanceOf(address(escrow)),
            contractBalanceBefore + amount
        );

        // Check escrow ID increments
        assertEq(escrow.getEscrowCount(), 1);
    }

    function test_CreateEscrow_RevertsOnZeroRecipient() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        _createEscrow(depositor, address(0), HUNDRED_USDC);
    }

    function test_CreateEscrow_RevertsOnZeroAmount() public {
        // Now reverts with AmountTooLow due to MIN_ESCROW_AMOUNT (1 USDC)
        vm.expectRevert(
            abi.encodeWithSelector(Errors.AmountTooLow.selector, 0, 1_000_000)
        );
        _createEscrow(depositor, recipient, 0);
    }

    function test_CreateEscrow_RevertsOnSelfEscrow() public {
        vm.expectRevert(Errors.SelfEscrow.selector);
        _createEscrow(depositor, depositor, HUNDRED_USDC);
    }

    function test_CreateEscrow_RevertsWhenPaused() public {
        vm.prank(owner);
        escrow.pause();

        vm.expectRevert(Errors.ContractPaused.selector);
        _createEscrow(depositor, recipient, HUNDRED_USDC);
    }

    // NOTE: test_CreateEscrow_TracksUserEscrows removed per audit (M-06)
    // getEscrowsAsDepositor/getEscrowsAsRecipient functions removed to save gas
    // Use off-chain event indexing instead (see SECURITY_ANALYSIS.md)

    // ============ Accept Tests ============

    function test_Accept_Success() public {
        uint256 escrowId = _createDefaultEscrow();

        vm.expectEmit(true, true, true, true);
        emit EscrowAccepted(
            escrowId,
            recipient,
            block.timestamp,
            block.timestamp + DISPUTE_WINDOW
        );

        _acceptEscrow(escrowId, recipient);

        IKoruEscrow.Escrow memory e = escrow.getEscrow(escrowId);
        assertEq(uint8(e.status), uint8(IKoruEscrow.Status.Accepted));
        assertEq(e.acceptedAt, block.timestamp);
    }

    function test_Accept_RevertsIfNotRecipient() public {
        uint256 escrowId = _createDefaultEscrow();

        vm.expectRevert(Errors.NotRecipient.selector);
        _acceptEscrow(escrowId, alice);
    }

    function test_Accept_RevertsIfAlreadyAccepted() public {
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

    function test_Accept_RevertsIfDeadlinePassed() public {
        uint256 escrowId = _createDefaultEscrow();

        _fastForward(ACCEPT_WINDOW + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.AcceptDeadlinePassed.selector,
                escrowId,
                block.timestamp - 1,
                block.timestamp
            )
        );
        _acceptEscrow(escrowId, recipient);
    }

    function test_Accept_SucceedsAtExactDeadline() public {
        uint256 escrowId = _createDefaultEscrow();

        _fastForward(ACCEPT_WINDOW);

        _acceptEscrow(escrowId, recipient);
        _assertStatus(escrowId, IKoruEscrow.Status.Accepted);
    }

    // ============ Release Tests ============

    function test_Release_Success() public {
        uint256 escrowId = _createDefaultEscrow();
        _acceptEscrow(escrowId, recipient);

        vm.expectEmit(true, true, true, true);
        emit EscrowReleased(escrowId, depositor, block.timestamp);

        _releaseEscrow(escrowId, depositor);

        _assertStatus(escrowId, IKoruEscrow.Status.Released);
    }

    function test_Release_RevertsIfNotDepositor() public {
        uint256 escrowId = _createDefaultEscrow();
        _acceptEscrow(escrowId, recipient);

        vm.expectRevert(Errors.NotDepositor.selector);
        _releaseEscrow(escrowId, alice);
    }

    function test_Release_RevertsIfNotAccepted() public {
        uint256 escrowId = _createDefaultEscrow();

        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.InvalidStatus.selector,
                escrowId,
                uint8(IKoruEscrow.Status.Pending),
                uint8(IKoruEscrow.Status.Accepted)
            )
        );
        _releaseEscrow(escrowId, depositor);
    }

    // ============ Dispute Tests ============

    function test_Dispute_Success() public {
        uint256 escrowId = _createDefaultEscrow();
        _acceptEscrow(escrowId, recipient);

        vm.expectEmit(true, true, true, true);
        emit EscrowDisputed(escrowId, depositor, block.timestamp);

        _disputeEscrow(escrowId, depositor);

        _assertStatus(escrowId, IKoruEscrow.Status.Disputed);
    }

    function test_Dispute_RevertsIfNotDepositor() public {
        uint256 escrowId = _createDefaultEscrow();
        _acceptEscrow(escrowId, recipient);

        vm.expectRevert(Errors.NotDepositor.selector);
        _disputeEscrow(escrowId, alice);
    }

    function test_Dispute_RevertsIfDeadlinePassed() public {
        uint256 escrowId = _createDefaultEscrow();
        _acceptEscrow(escrowId, recipient);

        _fastForward(DISPUTE_WINDOW + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.DisputeDeadlinePassed.selector,
                escrowId,
                block.timestamp - 1,
                block.timestamp
            )
        );
        _disputeEscrow(escrowId, depositor);
    }

    function test_Dispute_SucceedsAtExactDeadline() public {
        uint256 escrowId = _createDefaultEscrow();
        _acceptEscrow(escrowId, recipient);

        _fastForward(DISPUTE_WINDOW);

        _disputeEscrow(escrowId, depositor);
        _assertStatus(escrowId, IKoruEscrow.Status.Disputed);
    }

    // ============ Withdraw Tests - Depositor ============

    function test_WithdrawDepositor_Success() public {
        uint256 escrowId = _createDefaultEscrow();
        uint256 depositorBalanceBefore = usdc.balanceOf(depositor);

        // Fast forward past accept window
        _fastForward(ACCEPT_WINDOW + 1);

        vm.expectEmit(true, true, true, true);
        emit EscrowWithdrawn(
            escrowId,
            depositor,
            HUNDRED_USDC,
            0,
            HUNDRED_USDC,
            true
        );

        _withdraw(escrowId, depositor);

        _assertStatus(escrowId, IKoruEscrow.Status.Expired);
        assertEq(
            usdc.balanceOf(depositor),
            depositorBalanceBefore + HUNDRED_USDC
        );
    }

    function test_WithdrawDepositor_RevertsIfDeadlineNotReached() public {
        uint256 escrowId = _createDefaultEscrow();

        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.AcceptDeadlineNotReached.selector,
                escrowId,
                block.timestamp + ACCEPT_WINDOW,
                block.timestamp
            )
        );
        _withdraw(escrowId, depositor);
    }

    function test_WithdrawDepositor_RevertsIfAccepted() public {
        uint256 escrowId = _createDefaultEscrow();
        _acceptEscrow(escrowId, recipient);

        _fastForward(ACCEPT_WINDOW + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.InvalidStatus.selector,
                escrowId,
                uint8(IKoruEscrow.Status.Accepted),
                uint8(IKoruEscrow.Status.Pending)
            )
        );
        _withdraw(escrowId, depositor);
    }

    // ============ Withdraw Tests - Recipient ============

    function test_WithdrawRecipient_SuccessAfterRelease() public {
        uint256 escrowId = _createDefaultEscrow();
        _acceptEscrow(escrowId, recipient);
        _releaseEscrow(escrowId, depositor);

        uint256 recipientBalanceBefore = usdc.balanceOf(recipient);
        (uint256 expectedFee, uint256 expectedNet) = _calculateExpectedFee(
            HUNDRED_USDC
        );

        vm.expectEmit(true, true, true, true);
        emit EscrowWithdrawn(
            escrowId,
            recipient,
            HUNDRED_USDC,
            expectedFee,
            expectedNet,
            false
        );

        _withdraw(escrowId, recipient);

        _assertStatus(escrowId, IKoruEscrow.Status.Completed);
        assertEq(
            usdc.balanceOf(recipient),
            recipientBalanceBefore + expectedNet
        );
        assertEq(usdc.balanceOf(feeRecipient), expectedFee);
    }

    function test_WithdrawRecipient_SuccessAfterDisputeWindow() public {
        uint256 escrowId = _createDefaultEscrow();
        _acceptEscrow(escrowId, recipient);

        _fastForward(DISPUTE_WINDOW + 1);

        uint256 recipientBalanceBefore = usdc.balanceOf(recipient);
        (uint256 expectedFee, uint256 expectedNet) = _calculateExpectedFee(
            HUNDRED_USDC
        );

        _withdraw(escrowId, recipient);

        _assertStatus(escrowId, IKoruEscrow.Status.Completed);
        assertEq(
            usdc.balanceOf(recipient),
            recipientBalanceBefore + expectedNet
        );
        assertEq(usdc.balanceOf(feeRecipient), expectedFee);
    }

    function test_WithdrawRecipient_RevertsIfDisputeWindowNotPassed() public {
        uint256 escrowId = _createDefaultEscrow();
        _acceptEscrow(escrowId, recipient);

        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.DisputeDeadlineNotReached.selector,
                escrowId,
                block.timestamp + DISPUTE_WINDOW,
                block.timestamp
            )
        );
        _withdraw(escrowId, recipient);
    }

    function test_WithdrawRecipient_RevertsIfDisputed() public {
        uint256 escrowId = _createDefaultEscrow();
        _acceptEscrow(escrowId, recipient);
        _disputeEscrow(escrowId, depositor);

        _fastForward(DISPUTE_WINDOW + 1);

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

    // ============ Resolve Dispute Tests ============

    function test_ResolveDispute_RecipientWins() public {
        uint256 escrowId = _createDefaultEscrow();
        _acceptEscrow(escrowId, recipient);
        _disputeEscrow(escrowId, depositor);

        uint256 recipientBalanceBefore = usdc.balanceOf(recipient);
        (uint256 expectedFee, uint256 expectedNet) = _calculateExpectedFee(
            HUNDRED_USDC
        );

        vm.expectEmit(true, true, true, true);
        emit DisputeResolved(
            escrowId,
            recipient,
            owner,
            expectedNet,
            expectedFee
        );

        vm.prank(owner);
        escrow.resolveDispute(escrowId, recipient);

        _assertStatus(escrowId, IKoruEscrow.Status.Completed);
        assertEq(
            usdc.balanceOf(recipient),
            recipientBalanceBefore + expectedNet
        );
        assertEq(usdc.balanceOf(feeRecipient), expectedFee);
    }

    function test_ResolveDispute_DepositorWins() public {
        uint256 escrowId = _createDefaultEscrow();
        _acceptEscrow(escrowId, recipient);
        _disputeEscrow(escrowId, depositor);

        uint256 depositorBalanceBefore = usdc.balanceOf(depositor);

        vm.expectEmit(true, true, true, true);
        emit DisputeResolved(escrowId, depositor, owner, HUNDRED_USDC, 0);

        vm.prank(owner);
        escrow.resolveDispute(escrowId, depositor);

        _assertStatus(escrowId, IKoruEscrow.Status.Completed);
        assertEq(
            usdc.balanceOf(depositor),
            depositorBalanceBefore + HUNDRED_USDC
        );
    }

    function test_ResolveDispute_RevertsIfNotOwner() public {
        uint256 escrowId = _createDefaultEscrow();
        _acceptEscrow(escrowId, recipient);
        _disputeEscrow(escrowId, depositor);

        vm.expectRevert(Errors.NotOwner.selector);
        vm.prank(alice);
        escrow.resolveDispute(escrowId, recipient);
    }

    function test_ResolveDispute_RevertsIfInvalidWinner() public {
        uint256 escrowId = _createDefaultEscrow();
        _acceptEscrow(escrowId, recipient);
        _disputeEscrow(escrowId, depositor);

        vm.expectRevert(
            abi.encodeWithSelector(Errors.InvalidWinner.selector, alice)
        );
        vm.prank(owner);
        escrow.resolveDispute(escrowId, alice);
    }

    // ============ Admin Function Tests ============

    function test_SetFee_Success() public {
        vm.prank(owner);
        escrow.setFee(500);

        assertEq(escrow.feeBps(), 500);
    }

    function test_SetFee_RevertsIfTooHigh() public {
        vm.expectRevert(
            abi.encodeWithSelector(Errors.FeeTooHigh.selector, 1001, 1000)
        );
        vm.prank(owner);
        escrow.setFee(1001);
    }

    function test_SetFeeRecipient_Success() public {
        vm.prank(owner);
        escrow.setFeeRecipient(alice);

        assertEq(escrow.feeRecipient(), alice);
    }

    function test_Pause_Success() public {
        vm.prank(owner);
        escrow.pause();

        assertTrue(escrow.paused());
    }

    function test_Unpause_Success() public {
        vm.prank(owner);
        escrow.pause();

        vm.prank(owner);
        escrow.unpause();

        assertFalse(escrow.paused());
    }

    function test_TransferOwnership_Success() public {
        // Step 1: Initiate transfer
        vm.prank(owner);
        escrow.transferOwnership(alice);

        assertEq(escrow.owner(), owner); // Owner hasn't changed yet
        assertEq(escrow.pendingOwner(), alice);

        // Step 2: Accept ownership
        vm.prank(alice);
        escrow.acceptOwnership();

        assertEq(escrow.owner(), alice);
        assertEq(escrow.pendingOwner(), address(0));
    }

    // ============ View Function Tests ============

    function test_CanAccept_ReturnsTrueWhenValid() public {
        uint256 escrowId = _createDefaultEscrow();
        assertTrue(escrow.canAccept(escrowId));
    }

    function test_CanAccept_ReturnsFalseAfterDeadline() public {
        uint256 escrowId = _createDefaultEscrow();
        _fastForward(ACCEPT_WINDOW + 1);
        assertFalse(escrow.canAccept(escrowId));
    }

    function test_CanDepositorWithdraw_ReturnsTrueAfterDeadline() public {
        uint256 escrowId = _createDefaultEscrow();
        _fastForward(ACCEPT_WINDOW + 1);
        assertTrue(escrow.canDepositorWithdraw(escrowId));
    }

    function test_CanRecipientWithdraw_ReturnsTrueWhenReleased() public {
        uint256 escrowId = _createDefaultEscrow();
        _acceptEscrow(escrowId, recipient);
        _releaseEscrow(escrowId, depositor);
        assertTrue(escrow.canRecipientWithdraw(escrowId));
    }

    function test_CanRecipientWithdraw_ReturnsTrueAfterDisputeWindow() public {
        uint256 escrowId = _createDefaultEscrow();
        _acceptEscrow(escrowId, recipient);
        _fastForward(DISPUTE_WINDOW + 1);
        assertTrue(escrow.canRecipientWithdraw(escrowId));
    }

    function test_GetDeadlines_ReturnsCorrectValues() public {
        uint256 escrowId = _createDefaultEscrow();
        uint256 createdAt = block.timestamp;

        IKoruEscrow.Deadlines memory deadlines = escrow.getDeadlines(escrowId);
        assertEq(deadlines.acceptDeadline, createdAt + ACCEPT_WINDOW);
        assertEq(deadlines.disputeDeadline, 0); // Not accepted yet

        _acceptEscrow(escrowId, recipient);
        uint256 acceptedAt = block.timestamp;

        deadlines = escrow.getDeadlines(escrowId);
        assertEq(deadlines.disputeDeadline, acceptedAt + DISPUTE_WINDOW);
    }

    function test_CalculateFee_ReturnsCorrectValues() public view {
        (uint256 fee, uint256 netAmount) = escrow.calculateFee(HUNDRED_USDC);

        uint256 expectedFee = (HUNDRED_USDC * INITIAL_FEE_BPS) / 10000;
        assertEq(fee, expectedFee);
        assertEq(netAmount, HUNDRED_USDC - expectedFee);
    }
}
