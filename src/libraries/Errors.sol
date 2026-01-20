// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title Koru Escrow Errors
/// @author Koru Team
/// @notice Custom errors for gas-efficient reverts in KoruEscrow contract
/// @dev Using custom errors saves ~50 gas per revert vs require strings
library Errors {
    // ============ Authorization Errors ============

    /// @notice Thrown when caller is not authorized to perform action
    error Unauthorized();

    /// @notice Thrown when caller is not the contract owner
    error NotOwner();

    /// @notice Thrown when caller is not the escrow depositor
    error NotDepositor();

    /// @notice Thrown when caller is not the escrow recipient
    error NotRecipient();

    /// @notice Thrown when caller is neither depositor nor recipient
    error NotParticipant();

    /// @notice Thrown when caller is not the pending owner
    error NotPendingOwner();

    // ============ Escrow State Errors ============

    /// @notice Thrown when referenced escrow does not exist
    /// @param escrowId The invalid escrow ID
    error EscrowNotFound(uint256 escrowId);

    /// @notice Thrown when escrow is not in the required status
    /// @param escrowId The escrow ID
    /// @param currentStatus Current status of the escrow
    /// @param requiredStatus Required status for the operation
    error InvalidStatus(
        uint256 escrowId,
        uint8 currentStatus,
        uint8 requiredStatus
    );

    /// @notice Thrown when trying to withdraw but conditions not met
    /// @param escrowId The escrow ID
    error CannotWithdraw(uint256 escrowId);

    /// @notice Thrown when recipient tries to counter-dispute again
    /// @param escrowId The escrow ID
    error AlreadyCounterDisputed(uint256 escrowId);

    // ============ Timing Errors ============

    /// @notice Thrown when accept deadline has passed
    /// @param escrowId The escrow ID
    /// @param deadline The deadline timestamp
    /// @param current Current block timestamp
    error AcceptDeadlinePassed(
        uint256 escrowId,
        uint256 deadline,
        uint256 current
    );

    /// @notice Thrown when accept deadline hasn't passed yet (for depositor withdraw)
    /// @param escrowId The escrow ID
    /// @param deadline The deadline timestamp
    /// @param current Current block timestamp
    error AcceptDeadlineNotReached(
        uint256 escrowId,
        uint256 deadline,
        uint256 current
    );

    /// @notice Thrown when dispute window has passed
    /// @param escrowId The escrow ID
    /// @param deadline The deadline timestamp
    /// @param current Current block timestamp
    error DisputeDeadlinePassed(
        uint256 escrowId,
        uint256 deadline,
        uint256 current
    );

    /// @notice Thrown when dispute window hasn't passed yet (for recipient withdraw)
    /// @param escrowId The escrow ID
    /// @param deadline The deadline timestamp
    /// @param current Current block timestamp
    error DisputeDeadlineNotReached(
        uint256 escrowId,
        uint256 deadline,
        uint256 current
    );

    /// @notice Thrown when counter-dispute window has passed
    /// @param escrowId The escrow ID
    /// @param deadline The deadline timestamp
    /// @param current Current block timestamp
    error CounterDisputeWindowPassed(
        uint256 escrowId,
        uint256 deadline,
        uint256 current
    );

    // ============ Input Validation Errors ============

    /// @notice Thrown when deposit amount is zero
    error ZeroAmount();

    /// @notice Thrown when deposit amount is below minimum
    /// @param amount The provided amount
    /// @param minAmount The minimum required amount
    error AmountTooLow(uint256 amount, uint256 minAmount);

    /// @notice Thrown when deposit amount exceeds maximum
    /// @param amount The provided amount
    /// @param maxAmount The maximum allowed amount
    error AmountTooHigh(uint256 amount, uint256 maxAmount);

    /// @notice Thrown when address is zero
    error ZeroAddress();

    /// @notice Thrown when address is not a contract
    error NotAContract();

    /// @notice Thrown when address is not a valid ERC20 contract
    error InvalidERC20();

    /// @notice Thrown when depositor tries to create escrow with self as recipient
    error SelfEscrow();

    /// @notice Thrown when winner address in dispute resolution is invalid
    /// @param winner The invalid winner address
    error InvalidWinner(address winner);

    // ============ Transfer Errors ============

    /// @notice Thrown when USDC transfer fails
    error TransferFailed();

    /// @notice Thrown when USDC transferFrom fails
    error TransferFromFailed();

    // ============ Fee Errors ============

    /// @notice Thrown when fee exceeds maximum allowed
    /// @param fee The provided fee
    /// @param maxFee The maximum allowed fee
    error FeeTooHigh(uint256 fee, uint256 maxFee);

    // ============ Contract State Errors ============

    /// @notice Thrown when contract is paused
    error ContractPaused();

    /// @notice Thrown when contract is not paused (for unpause)
    error ContractNotPaused();

    /// @notice Thrown when reentrancy is detected
    error ReentrancyGuard();

    /// @notice Thrown when reentrancy attack is detected
    error ReentrancyGuardReentrantCall();

    /// @notice Thrown when ETH is sent to the contract
    error EthNotAccepted();
}
