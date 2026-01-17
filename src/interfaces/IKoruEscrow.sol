// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IKoruEscrow Interface
/// @author Koru Team
/// @notice Interface for the Koru Escrow contract
/// @dev Defines all external functions, events, and data structures
interface IKoruEscrow {
    // ============ Enums ============

    /// @notice Possible states of an escrow
    /// @dev State transitions: Pending -> Accepted -> Released/Completed/Disputed
    ///                        Pending -> Expired (after 24hrs, no accept)
    enum Status {
        Pending, // 0: Created, waiting for recipient to accept
        Accepted, // 1: Recipient accepted, 48hr dispute window active
        Released, // 2: Depositor released, recipient can withdraw
        Completed, // 3: Funds withdrawn (terminal state)
        Expired, // 4: Accept window passed, depositor withdrew (terminal state)
        Disputed // 5: Under dispute, admin resolution needed
    }

    // ============ Structs ============

    /// @notice Core escrow data structure
    /// @dev Packed for gas efficiency (addresses + uint256s)
    /// @dev Note: Each escrow is unique to a depositor-recipient pair.
    ///      Multiple escrows can exist between the same pair, but only one active at a time.
    struct Escrow {
        address depositor; // Address that deposited funds
        address recipient; // Address that will receive funds
        uint256 amount; // Amount of USDC (6 decimals)
        uint256 createdAt; // Timestamp when escrow was created
        uint256 acceptedAt; // Timestamp when recipient accepted (0 if not)
        uint256 disputedAt; // Timestamp when depositor disputed (0 if not)
        Status status; // Current escrow status
        uint256 feeBps; // Fee in basis points at time of creation (locked)
        address feeRecipient; // Fee recipient address at time of creation (locked)
    }

    /// @notice Deadline information for an escrow
    struct Deadlines {
        uint256 acceptDeadline; // createdAt + ACCEPT_WINDOW
        uint256 disputeDeadline; // acceptedAt + DISPUTE_WINDOW (0 if not accepted)
    }

    /// @notice User balance breakdown
    struct UserBalance {
        uint256 available; // Can withdraw now
        uint256 locked; // Locked in active escrows
        uint256 pending; // Pending acceptance (as recipient)
    }

    // ============ Events - Escrow Lifecycle ============

    /// @notice Emitted when a new escrow is created
    /// @param escrowId Unique identifier for the escrow
    /// @param depositor Address that deposited funds
    /// @param recipient Address that will receive funds
    /// @param amount Amount of USDC deposited
    /// @param acceptDeadline Timestamp by which recipient must accept
    event EscrowCreated(
        uint256 indexed escrowId,
        address indexed depositor,
        address indexed recipient,
        uint256 amount,
        uint256 acceptDeadline
    );

    /// @notice Emitted when recipient accepts an escrow
    /// @param escrowId The escrow that was accepted
    /// @param recipient Address that accepted
    /// @param acceptedAt Timestamp of acceptance
    /// @param disputeDeadline Timestamp by which depositor can dispute
    event EscrowAccepted(
        uint256 indexed escrowId,
        address indexed recipient,
        uint256 acceptedAt,
        uint256 disputeDeadline
    );

    /// @notice Emitted when depositor releases funds early
    /// @param escrowId The escrow that was released
    /// @param depositor Address that released
    /// @param releasedAt Timestamp of release
    event EscrowReleased(
        uint256 indexed escrowId,
        address indexed depositor,
        uint256 releasedAt
    );

    /// @notice Emitted when funds are withdrawn
    /// @param escrowId The escrow withdrawn from
    /// @param withdrawer Address that withdrew
    /// @param amount Gross amount before fees
    /// @param fee Platform fee deducted (0 for depositor withdrawals)
    /// @param netAmount Amount received after fees
    /// @param isDepositorWithdraw True if depositor reclaimed, false if recipient earned
    event EscrowWithdrawn(
        uint256 indexed escrowId,
        address indexed withdrawer,
        uint256 amount,
        uint256 fee,
        uint256 netAmount,
        bool isDepositorWithdraw
    );

    /// @notice Emitted when escrow is marked expired (depositor can reclaim)
    /// @param escrowId The escrow that expired
    /// @param expiredAt Timestamp of expiration
    event EscrowExpired(uint256 indexed escrowId, uint256 expiredAt);

    /// @notice Emitted when escrow is disputed
    /// @param escrowId The escrow under dispute
    /// @param depositor Address that raised dispute
    /// @param disputedAt Timestamp of dispute
    event EscrowDisputed(
        uint256 indexed escrowId,
        address indexed depositor,
        uint256 disputedAt
    );

    /// @notice Emitted when recipient counter-disputes
    /// @param escrowId The escrow under counter-dispute
    /// @param recipient Address that raised counter-dispute
    /// @param counterDisputedAt Timestamp of counter-dispute
    event EscrowCounterDisputed(
        uint256 indexed escrowId,
        address indexed recipient,
        uint256 counterDisputedAt
    );

    /// @notice Emitted when dispute is resolved
    /// @param escrowId The disputed escrow
    /// @param winner Address that received funds
    /// @param resolver Admin address that resolved
    /// @param amount Amount transferred to winner
    /// @param fee Fee deducted (if winner is recipient)
    event DisputeResolved(
        uint256 indexed escrowId,
        address indexed winner,
        address indexed resolver,
        uint256 amount,
        uint256 fee
    );

    // ============ Events - User Statistics (for Subgraph) ============

    /// @notice Emitted on any balance change for tracking user stats
    /// @param user Address whose balance changed
    /// @param escrowId Related escrow ID
    /// @param balanceType Type: "deposited", "received", "refunded", "fee"
    /// @param amount Amount involved in the change
    event BalanceChanged(
        address indexed user,
        uint256 indexed escrowId,
        string balanceType,
        uint256 amount
    );

    // ============ Events - Admin ============

    /// @notice Emitted when platform fee is updated
    /// @param oldFeeBps Previous fee in basis points
    /// @param newFeeBps New fee in basis points
    event FeeUpdated(uint256 oldFeeBps, uint256 newFeeBps);

    /// @notice Emitted when fee recipient is updated
    /// @param oldRecipient Previous fee recipient
    /// @param newRecipient New fee recipient
    event FeeRecipientUpdated(address oldRecipient, address newRecipient);

    /// @notice Emitted when ownership transfer is initiated
    /// @param currentOwner Current owner address
    /// @param pendingOwner Pending owner address
    event OwnershipTransferInitiated(
        address indexed currentOwner,
        address indexed pendingOwner
    );

    /// @notice Emitted when contract ownership is transferred
    /// @param previousOwner Previous owner address
    /// @param newOwner New owner address
    event OwnershipTransferred(
        address indexed previousOwner,
        address indexed newOwner
    );

    /// @notice Emitted when contract is paused
    /// @param by Address that paused
    event Paused(address by);

    /// @notice Emitted when contract is unpaused
    /// @param by Address that unpaused
    event Unpaused(address by);

    // ============ Core Functions ============

    /// @notice Create a new escrow by depositing USDC
    /// @dev Requires prior USDC approval. Emits EscrowCreated.
    /// @param recipient Address of the person providing the service
    /// @param amount Amount of USDC to deposit (6 decimals)
    /// @return escrowId The ID of the newly created escrow
    function createEscrow(
        address recipient,
        uint256 amount
    ) external returns (uint256 escrowId);

    /// @notice Accept an escrow (called by recipient on first chat reply)
    /// @dev Must be called within ACCEPT_WINDOW of creation. Emits EscrowAccepted.
    /// @param escrowId The escrow to accept
    function accept(uint256 escrowId) external;

    /// @notice Release funds to recipient immediately (called by depositor)
    /// @dev Allows recipient to withdraw without waiting for dispute window.
    /// @param escrowId The escrow to release
    function release(uint256 escrowId) external;

    /// @notice Dispute an escrow (called by depositor)
    /// @dev Freezes funds for admin resolution. Must be within DISPUTE_WINDOW.
    /// @param escrowId The escrow to dispute
    function dispute(uint256 escrowId) external;

    /// @notice Counter-dispute an escrow (called by recipient)
    /// @dev Recipient can counter-dispute when depositor has disputed against them.
    /// @param escrowId The escrow to counter-dispute
    function counterDispute(uint256 escrowId) external;

    /// @notice Withdraw funds from escrow
    /// @dev Depositor: Pending + ACCEPT_WINDOW passed. Recipient: Released OR Accepted + DISPUTE_WINDOW passed.
    /// @dev Can be called even when contract is paused to ensure funds are never trapped.
    /// @param escrowId The escrow to withdraw from
    function withdraw(uint256 escrowId) external;

    // ============ Admin Functions ============

    /// @notice Resolve a disputed escrow
    /// @dev Only owner. Winner must be depositor or recipient.
    /// @dev Can be called even when contract is paused to ensure funds are never trapped.
    /// @param escrowId The disputed escrow
    /// @param winner Address to receive the funds
    function resolveDispute(uint256 escrowId, address winner) external;

    /// @notice Update platform fee
    /// @dev Only owner. Cannot exceed MAX_FEE_BPS.
    /// @param newFeeBps New fee in basis points
    function setFee(uint256 newFeeBps) external;

    /// @notice Update fee recipient address
    /// @dev Only owner.
    /// @param newFeeRecipient New fee recipient address
    function setFeeRecipient(address newFeeRecipient) external;

    /// @notice Pause contract in case of emergency
    /// @dev Only owner.
    function pause() external;

    /// @notice Unpause contract
    /// @dev Only owner.
    function unpause() external;

    /// @notice Initiate contract ownership transfer (step 1 of 2)
    /// @dev Only owner. New owner must call acceptOwnership() to complete transfer.
    /// @param newOwner New owner address
    function transferOwnership(address newOwner) external;

    /// @notice Accept contract ownership (step 2 of 2)
    /// @dev Only pending owner can call this to complete the transfer.
    function acceptOwnership() external;

    // ============ View Functions ============

    /// @notice Get full escrow data
    /// @param escrowId The escrow ID
    /// @return escrow The escrow struct
    function getEscrow(
        uint256 escrowId
    ) external view returns (Escrow memory escrow);

    /// @notice Get escrow status
    /// @param escrowId The escrow ID
    /// @return status Current status
    function getStatus(uint256 escrowId) external view returns (Status status);

    /// @notice Check if recipient can accept this escrow
    /// @param escrowId The escrow ID
    /// @return canAccept True if accept is possible
    function canAccept(uint256 escrowId) external view returns (bool canAccept);

    /// @notice Check if depositor can withdraw (reclaim)
    /// @param escrowId The escrow ID
    /// @return canWithdraw True if depositor can withdraw
    function canDepositorWithdraw(
        uint256 escrowId
    ) external view returns (bool canWithdraw);

    /// @notice Check if recipient can withdraw
    /// @param escrowId The escrow ID
    /// @return canWithdraw True if recipient can withdraw
    function canRecipientWithdraw(
        uint256 escrowId
    ) external view returns (bool canWithdraw);

    /// @notice Check if depositor can dispute
    /// @param escrowId The escrow ID
    /// @return canDispute True if dispute is possible
    function canDispute(
        uint256 escrowId
    ) external view returns (bool canDispute);

    /// @notice Get all deadlines for an escrow
    /// @param escrowId The escrow ID
    /// @return deadlines Struct containing all deadline timestamps
    function getDeadlines(
        uint256 escrowId
    ) external view returns (Deadlines memory deadlines);


    /// @notice Calculate fee and net amount for a given gross amount
    /// @param amount Gross amount
    /// @return fee Platform fee
    /// @return netAmount Amount after fee deduction
    function calculateFee(
        uint256 amount
    ) external view returns (uint256 fee, uint256 netAmount);

    /// @notice Get total number of escrows created
    /// @return count Total escrow count
    function getEscrowCount() external view returns (uint256 count);

    /// @notice Get the effective status of an escrow (accounting for time-based transitions)
    /// @dev Returns Expired if Pending and accept window passed, otherwise returns actual status
    /// @param escrowId The escrow ID
    /// @return status The effective status
    function getEffectiveStatus(
        uint256 escrowId
    ) external view returns (Status status);

    /// @notice Check if recipient has counter-disputed an escrow
    /// @param escrowId The escrow ID
    /// @return hasCounterDisputed True if recipient has counter-disputed
    function hasCounterDisputed(
        uint256 escrowId
    ) external view returns (bool hasCounterDisputed);

    // ============ Constants ============

    /// @notice Time window for recipient to accept (24 hours)
    function ACCEPT_WINDOW() external view returns (uint256);

    /// @notice Time window before recipient can withdraw after acceptance (48 hours)
    function DISPUTE_WINDOW() external view returns (uint256);

    /// @notice Maximum platform fee in basis points (10%)
    function MAX_FEE_BPS() external view returns (uint256);

    /// @notice Basis points denominator (10000)
    function BPS_DENOMINATOR() external view returns (uint256);
}
