// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IKoruEscrow} from "./interfaces/IKoruEscrow.sol";
import {Errors} from "./libraries/Errors.sol";

/// @title KoruEscrow
/// @author Oleanji
/// @notice Escrow contract for Koru platform - handles USDC deposits for paid chat sessions
/// @dev Implements time-locked escrow with dispute resolution. Upgradeable via UUPS pattern.
/// @custom:security-contact security@koru.app
contract KoruEscrow is IKoruEscrow, Initializable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    // ============ Constants ============

    /// @inheritdoc IKoruEscrow
    uint256 public constant ACCEPT_WINDOW = 24 hours;

    /// @inheritdoc IKoruEscrow
    uint256 public constant DISPUTE_WINDOW = 48 hours;

    /// @notice Counter-dispute window (7 days after dispute)
    uint256 public constant COUNTER_DISPUTE_WINDOW = 7 days;

    /// @notice Emergency unlock period for disputed escrows (90 days)
    uint256 public constant EMERGENCY_UNLOCK_PERIOD = 90 days;

    /// @inheritdoc IKoruEscrow
    uint256 public constant MAX_FEE_BPS = 1000; // 10%

    /// @inheritdoc IKoruEscrow
    uint256 public constant BPS_DENOMINATOR = 10000;

    /// @notice Minimum escrow amount (1 USDC with 6 decimals) - prevents dust attacks
    uint256 public constant MIN_ESCROW_AMOUNT = 1 * 1e6;

    /// @notice Maximum escrow amount (1 billion USDC with 6 decimals)
    uint256 public constant MAX_ESCROW_AMOUNT = 1_000_000_000 * 1e6;

    // ============ State Variables ============
    // STORAGE LAYOUT OPTIMIZED - DO NOT REORDER AFTER DEPLOYMENT
    // Each comment shows storage slot packing

    /// @notice USDC token contract (20 bytes)
    /// @notice Emergency pause state (1 byte)
    /// @dev Slot 0: usdc (20 bytes) + paused (1 byte) + 11 bytes free
    IERC20 public usdc;
    bool public paused;

    /// @notice Address receiving platform fees (20 bytes)
    /// @notice Platform fee in basis points (12 bytes, max 10000, stored as uint96)
    /// @dev Slot 1: feeRecipient (20 bytes) + feeBps (12 bytes) = FULL
    address public feeRecipient;
    uint96 public feeBps;

    /// @notice Contract owner (can update fees, resolve disputes)
    /// @dev Slot 2: owner (20 bytes) + 12 bytes free for future small types
    address public owner;

    /// @notice Pending owner for two-step ownership transfer
    /// @dev Slot 3: pendingOwner (20 bytes) + 12 bytes free
    address public pendingOwner;

    /// @notice Auto-incrementing escrow ID counter
    /// @dev Slot 4: _nextEscrowId (32 bytes)
    uint256 private _nextEscrowId;

    /// @notice Escrow ID => Escrow data
    mapping(uint256 => Escrow) private _escrows;

    /// @notice Escrow ID => whether recipient has counter-disputed
    mapping(uint256 => bool) private _counterDisputed;

    /// @notice Reentrancy guard status
    /// @dev Slot 5: _reentrancyStatus (1 byte) + 31 bytes free
    /// Uses values 1 (NOT_ENTERED) and 2 (ENTERED) for gas efficiency
    uint8 private _reentrancyStatus;

    /**
     * @dev Storage gap for future upgrades
     * This reserves storage slots that can be used in future contract upgrades
     * without affecting the storage layout of child contracts.
     *
     * Current storage slots used:
     *   Slot 0: usdc (20) + paused (1) = 21 bytes
     *   Slot 1: feeRecipient (20) + feeBps (12) = 32 bytes (FULL)
     *   Slot 2: owner (20) = 20 bytes
     *   Slot 3: pendingOwner (20) = 20 bytes
     *   Slot 4: _nextEscrowId (32) = 32 bytes (FULL)
     *   Slot 5: _escrows mapping (32) = 32 bytes (FULL)
     *   Slot 6: _counterDisputed mapping (32) = 32 bytes (FULL)
     *   Slot 7: _reentrancyStatus (1) = 1 byte
     * Total used: 8 slots
     * Reserved for future: 42 slots
     * Total: 50 slots reserved for contract state
     *
     * Note: Inherited contracts (Initializable, UUPSUpgradeable) use separate namespace storage
     */
    uint256[42] private __gap;

    // ============ Modifiers ============

    /// @notice Ensures contract is not paused
    modifier whenNotPaused() {
        if (paused) revert Errors.ContractPaused();
        _;
    }

    /// @notice Ensures contract is paused
    modifier whenPaused() {
        if (!paused) revert Errors.ContractNotPaused();
        _;
    }

    /// @notice Ensures caller is contract owner
    modifier onlyOwner() {
        if (msg.sender != owner) revert Errors.NotOwner();
        _;
    }

    /// @notice Ensures escrow exists
    modifier escrowExists(uint256 escrowId) {
        if (escrowId >= _nextEscrowId) revert Errors.EscrowNotFound(escrowId);
        _;
    }

    /// @notice Ensures caller is the depositor
    modifier onlyDepositor(uint256 escrowId) {
        if (msg.sender != _escrows[escrowId].depositor)
            revert Errors.NotDepositor();
        _;
    }

    /// @notice Ensures caller is the recipient
    modifier onlyRecipient(uint256 escrowId) {
        if (msg.sender != _escrows[escrowId].recipient)
            revert Errors.NotRecipient();
        _;
    }

    /// @notice Ensures escrow is in expected status
    modifier inStatus(uint256 escrowId, Status expected) {
        Status current = _escrows[escrowId].status;
        if (current != expected) {
            revert Errors.InvalidStatus(
                escrowId,
                uint8(current),
                uint8(expected)
            );
        }
        _;
    }

    /// @notice Prevents reentrancy attacks
    /// @dev Custom implementation for upgradeable contracts
    /// Uses storage values: 0 (uninitialized), 1 (NOT_ENTERED), 2 (ENTERED)
    /// Checks for != 1 to catch both uninitialized (0) and reentrancy (2)
    modifier nonReentrant() {
        if (_reentrancyStatus != 1)
            revert Errors.ReentrancyGuardReentrantCall();
        _reentrancyStatus = 2;
        _;
        _reentrancyStatus = 1;
    }

    // ============ Constructor & Initializer ============

    /// @notice Constructor disables initializers on implementation contract
    /// @dev CRITICAL: Prevents implementation contract from being hijacked
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the escrow contract
    /// @param _usdc USDC token address
    /// @param _feeBps Initial platform fee in basis points
    /// @param _feeRecipient Address to receive platform fees
    function initialize(
        address _usdc,
        uint256 _feeBps,
        address _feeRecipient
    ) external initializer {
        // Validate inputs
        if (_usdc == address(0)) revert Errors.ZeroAddress();
        if (_feeRecipient == address(0)) revert Errors.ZeroAddress();
        if (_feeBps > MAX_FEE_BPS)
            revert Errors.FeeTooHigh(_feeBps, MAX_FEE_BPS);

        // Validate USDC is a valid contract (H-03 fix)
        if (_usdc.code.length == 0) revert Errors.NotAContract();

        // Try to verify ERC20 interface
        try IERC20(_usdc).totalSupply() returns (uint256) {
            // Valid ERC20 contract
        } catch {
            revert Errors.InvalidERC20();
        }

        // Initialize reentrancy guard (C-01 fix)
        _reentrancyStatus = 1; // NOT_ENTERED

        // Note: UUPSUpgradeable doesn't have an init function

        usdc = IERC20(_usdc);
        feeBps = uint96(_feeBps); // Safe: validated <= MAX_FEE_BPS (1000)
        feeRecipient = _feeRecipient;
        owner = msg.sender;

        // Emit initialization events
        emit OwnershipTransferred(address(0), msg.sender);
        emit FeeUpdated(0, _feeBps);
        emit FeeRecipientUpdated(address(0), _feeRecipient);
    }

    /// @notice Authorize contract upgrades (UUPS requirement)
    /// @dev Only owner can upgrade the contract
    /// @param newImplementation Address of the new implementation contract
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {
        // Validate new implementation is a contract (L-08 fix)
        if (newImplementation.code.length == 0) revert Errors.NotAContract();

        // Emit upgrade event for transparency
        emit UpgradeAuthorized(address(this), newImplementation, msg.sender);
    }

    // ============ Core Functions ============

    /// @inheritdoc IKoruEscrow
    /// @dev Legacy V1 — creates an immediate-session escrow (sessionDate = 0).
    function createEscrow(
        address recipient,
        uint256 amount
    ) external whenNotPaused nonReentrant returns (uint256 escrowId) {
        return _createEscrow(recipient, amount, 0);
    }

    /// @inheritdoc IKoruEscrow
    /// @dev V2 — creates an escrow whose timelines anchor to the session date.
    function createEscrowWithSession(
        address recipient,
        uint256 amount,
        uint48 sessionDate
    ) external whenNotPaused nonReentrant returns (uint256 escrowId) {
        // If a session date is provided, it must be in the future
        if (sessionDate != 0 && sessionDate <= block.timestamp) {
            revert Errors.InvalidSessionDate(sessionDate, block.timestamp);
        }
        return _createEscrow(recipient, amount, sessionDate);
    }

    /// @notice Internal shared logic for creating an escrow
    /// @param recipient Address of the person providing the service
    /// @param amount USDC amount to lock
    /// @param sessionDate Unix timestamp of the session (0 = immediate / V1 behavior)
    /// @return escrowId The ID of the newly created escrow
    function _createEscrow(
        address recipient,
        uint256 amount,
        uint48 sessionDate
    ) private returns (uint256 escrowId) {
        // Validation
        if (recipient == address(0)) revert Errors.ZeroAddress();
        if (amount < MIN_ESCROW_AMOUNT)
            revert Errors.AmountTooLow(amount, MIN_ESCROW_AMOUNT);
        if (amount > MAX_ESCROW_AMOUNT)
            revert Errors.AmountTooHigh(amount, MAX_ESCROW_AMOUNT);
        if (recipient == msg.sender) revert Errors.SelfEscrow();

        // Generate escrow ID
        escrowId = _nextEscrowId++;

        // Create escrow with locked fee parameters
        // Safe casts: amount checked <= MAX_ESCROW_AMOUNT (fits uint96)
        //             feeBps checked <= MAX_FEE_BPS (1000, fits uint16)
        //             timestamps fit uint48 (good until year 8.9M)
        _escrows[escrowId] = Escrow({
            depositor: msg.sender,
            createdAt: uint48(block.timestamp),
            acceptedAt: 0,
            recipient: recipient,
            disputedAt: 0,
            status: Status.Pending,
            feeBps: uint16(feeBps), // Lock fee at creation
            feeRecipient: feeRecipient,
            amount: uint96(amount), // Lock amount at creation
            sessionDate: sessionDate
        });

        // Transfer USDC from depositor to contract
        usdc.safeTransferFrom(msg.sender, address(this), amount);

        // Accept deadline depends on whether session date is set
        uint256 acceptDeadline = _getAcceptDeadline(_escrows[escrowId]);

        // Emit events
        emit EscrowCreated(
            escrowId,
            msg.sender,
            recipient,
            amount,
            acceptDeadline
        );

        emit BalanceChanged(msg.sender, escrowId, "deposited", amount);
    }

    /// @inheritdoc IKoruEscrow
    function accept(
        uint256 escrowId
    )
        external
        whenNotPaused
        nonReentrant
        escrowExists(escrowId)
        onlyRecipient(escrowId)
        inStatus(escrowId, Status.Pending)
    {
        Escrow storage escrow = _escrows[escrowId];

        // Check accept window (session-date-aware)
        uint256 acceptDeadline = _getAcceptDeadline(escrow);
        if (block.timestamp > acceptDeadline) {
            revert Errors.AcceptDeadlinePassed(
                escrowId,
                acceptDeadline,
                block.timestamp
            );
        }

        // Update state
        escrow.status = Status.Accepted;
        escrow.acceptedAt = uint48(block.timestamp);

        // Dispute deadline is session-date-aware
        uint256 disputeDeadline = _getDisputeDeadline(escrow);

        // Emit events
        emit EscrowAccepted(
            escrowId,
            msg.sender,
            block.timestamp,
            disputeDeadline
        );
    }

    /// @notice Cancel a pending escrow (M-02 fix - improved UX)
    /// @dev Allows depositor to cancel before acceptance
    /// @param escrowId The escrow ID to cancel
    function cancel(
        uint256 escrowId
    )
        external
        whenNotPaused
        nonReentrant
        escrowExists(escrowId)
        onlyDepositor(escrowId)
        inStatus(escrowId, Status.Pending)
    {
        Escrow storage escrow = _escrows[escrowId];

        // Update state
        escrow.status = Status.Cancelled;
        uint256 amount = escrow.amount;

        // Refund depositor (no fee on cancellation)
        usdc.safeTransfer(escrow.depositor, amount);

        // Emit events
        emit EscrowCancelled(escrowId, msg.sender, amount);
        emit BalanceChanged(
            escrow.depositor,
            escrowId,
            "cancelled_refund",
            amount
        );
    }

    /// @inheritdoc IKoruEscrow
    function release(
        uint256 escrowId
    )
        external
        whenNotPaused
        nonReentrant
        escrowExists(escrowId)
        onlyDepositor(escrowId)
        inStatus(escrowId, Status.Accepted)
    {
        Escrow storage escrow = _escrows[escrowId];

        // Update state
        escrow.status = Status.Released;

        // Emit event
        emit EscrowReleased(escrowId, msg.sender, block.timestamp);
    }

    /// @inheritdoc IKoruEscrow
    function dispute(
        uint256 escrowId
    )
        external
        whenNotPaused
        nonReentrant
        escrowExists(escrowId)
        onlyDepositor(escrowId)
        inStatus(escrowId, Status.Accepted)
    {
        Escrow storage escrow = _escrows[escrowId];

        // Check dispute window (session-date-aware)
        uint256 disputeDeadline = _getDisputeDeadline(escrow);
        if (block.timestamp > disputeDeadline) {
            revert Errors.DisputeDeadlinePassed(
                escrowId,
                disputeDeadline,
                block.timestamp
            );
        }

        // Update state
        escrow.status = Status.Disputed;
        escrow.disputedAt = uint48(block.timestamp);

        // Emit event
        emit EscrowDisputed(escrowId, msg.sender, block.timestamp);
    }

    /// @inheritdoc IKoruEscrow
    function counterDispute(
        uint256 escrowId
    )
        external
        whenNotPaused
        nonReentrant
        escrowExists(escrowId)
        onlyRecipient(escrowId)
        inStatus(escrowId, Status.Disputed)
    {
        Escrow storage escrow = _escrows[escrowId];

        // Prevent double counter-dispute
        if (_counterDisputed[escrowId])
            revert Errors.AlreadyCounterDisputed(escrowId);

        // Check counter-dispute window
        uint256 counterDisputeDeadline = escrow.disputedAt +
            COUNTER_DISPUTE_WINDOW;
        if (block.timestamp > counterDisputeDeadline) {
            revert Errors.CounterDisputeWindowPassed(
                escrowId,
                counterDisputeDeadline,
                block.timestamp
            );
        }

        // Mark as counter-disputed
        _counterDisputed[escrowId] = true;

        // Recipient can counter-dispute when there is a dispute against them
        // This puts both parties on equal footing for admin resolution
        // Emit event to track counter-dispute
        emit EscrowCounterDisputed(escrowId, msg.sender, block.timestamp);
    }

    /// @inheritdoc IKoruEscrow
    function withdraw(
        uint256 escrowId
    ) external nonReentrant escrowExists(escrowId) {
        Escrow storage escrow = _escrows[escrowId];

        if (msg.sender == escrow.depositor) {
            _withdrawAsDepositor(escrowId, escrow);
        } else if (msg.sender == escrow.recipient) {
            _withdrawAsRecipient(escrowId, escrow);
        } else {
            revert Errors.NotParticipant();
        }
    }

    /// @notice Internal: Handle depositor withdrawal (reclaim)
    /// @param escrowId The escrow ID
    /// @param escrow Storage pointer to escrow
    function _withdrawAsDepositor(
        uint256 escrowId,
        Escrow storage escrow
    ) private {
        // Must be Pending status
        if (escrow.status != Status.Pending) {
            revert Errors.InvalidStatus(
                escrowId,
                uint8(escrow.status),
                uint8(Status.Pending)
            );
        }

        // Must be past accept window (session-date-aware)
        uint256 acceptDeadline = _getAcceptDeadline(escrow);
        if (block.timestamp <= acceptDeadline) {
            revert Errors.AcceptDeadlineNotReached(
                escrowId,
                acceptDeadline,
                block.timestamp
            );
        }

        // Update state
        escrow.status = Status.Expired;
        uint256 amount = escrow.amount;

        // Transfer USDC back to depositor (no fee)
        usdc.safeTransfer(escrow.depositor, amount);

        // Emit events
        emit EscrowExpired(escrowId, block.timestamp);
        emit EscrowWithdrawn(
            escrowId,
            escrow.depositor,
            amount,
            0,
            amount,
            true
        );
        emit BalanceChanged(escrow.depositor, escrowId, "refunded", amount);
    }

    /// @notice Internal: Handle recipient withdrawal (earn)
    /// @param escrowId The escrow ID
    /// @param escrow Storage pointer to escrow
    function _withdrawAsRecipient(
        uint256 escrowId,
        Escrow storage escrow
    ) private {
        bool canWithdrawNow = false;

        if (escrow.status == Status.Released) {
            // Depositor explicitly released
            canWithdrawNow = true;
        } else if (escrow.status == Status.Accepted) {
            // Check if dispute window has passed (session-date-aware)
            uint256 disputeDeadline = _getDisputeDeadline(escrow);
            if (block.timestamp > disputeDeadline) {
                canWithdrawNow = true;
            } else {
                revert Errors.DisputeDeadlineNotReached(
                    escrowId,
                    disputeDeadline,
                    block.timestamp
                );
            }
        } else {
            revert Errors.InvalidStatus(
                escrowId,
                uint8(escrow.status),
                uint8(Status.Accepted)
            );
        }

        if (!canWithdrawNow) {
            revert Errors.CannotWithdraw(escrowId);
        }

        // Update state
        escrow.status = Status.Completed;
        uint256 amount = escrow.amount;

        // Calculate fee using locked parameters
        (uint256 fee, uint256 netAmount) = _calculateFeeForEscrow(
            escrow,
            amount
        );

        // Transfer USDC using locked fee recipient
        if (fee > 0) {
            usdc.safeTransfer(escrow.feeRecipient, fee);
        }
        usdc.safeTransfer(escrow.recipient, netAmount);

        // Emit events
        emit EscrowWithdrawn(
            escrowId,
            escrow.recipient,
            amount,
            fee,
            netAmount,
            false
        );
        emit BalanceChanged(escrow.recipient, escrowId, "received", netAmount);
        if (fee > 0) {
            emit BalanceChanged(escrow.recipient, escrowId, "fee", fee);
        }
    }

    // ============ Admin Functions ============

    /// @inheritdoc IKoruEscrow
    function resolveDispute(
        uint256 escrowId,
        address winner
    )
        external
        onlyOwner
        nonReentrant
        escrowExists(escrowId)
        inStatus(escrowId, Status.Disputed)
    {
        Escrow storage escrow = _escrows[escrowId];

        // Validate winner
        if (winner == address(0)) revert Errors.ZeroAddress();
        if (winner != escrow.depositor && winner != escrow.recipient) {
            revert Errors.InvalidWinner(winner);
        }

        // Update state
        escrow.status = Status.Completed;
        uint256 amount = escrow.amount;
        uint256 fee = 0;
        uint256 netAmount = amount;

        // If recipient wins, deduct fee using locked parameters
        if (winner == escrow.recipient) {
            (fee, netAmount) = _calculateFeeForEscrow(escrow, amount);
            if (fee > 0) {
                usdc.safeTransfer(escrow.feeRecipient, fee);
            }
            emit BalanceChanged(
                escrow.recipient,
                escrowId,
                "received",
                netAmount
            );
            if (fee > 0) {
                emit BalanceChanged(escrow.recipient, escrowId, "fee", fee);
            }
        } else {
            // Depositor wins - refund without fee
            emit BalanceChanged(escrow.depositor, escrowId, "refunded", amount);
        }

        // Transfer to winner
        usdc.safeTransfer(winner, netAmount);

        // Emit event
        emit DisputeResolved(escrowId, winner, msg.sender, netAmount, fee);
    }

    /// @notice Emergency unlock for long-disputed escrows (H-01 fix)
    /// @dev After 90 days of dispute, either party can trigger a 50/50 split
    /// @param escrowId The escrow ID to emergency unlock
    function emergencyWithdrawDisputed(
        uint256 escrowId
    ) external nonReentrant escrowExists(escrowId) {
        Escrow storage escrow = _escrows[escrowId];

        // Can only emergency withdraw disputed escrows
        if (escrow.status != Status.Disputed) {
            revert Errors.InvalidStatus(
                escrowId,
                uint8(escrow.status),
                uint8(Status.Disputed)
            );
        }

        // Must wait 90 days after dispute
        uint256 unlockTime = escrow.disputedAt + EMERGENCY_UNLOCK_PERIOD;
        if (block.timestamp < unlockTime) {
            revert Errors.DisputeDeadlineNotReached(
                escrowId,
                unlockTime,
                block.timestamp
            );
        }

        // Only depositor or recipient can trigger
        if (msg.sender != escrow.depositor && msg.sender != escrow.recipient) {
            revert Errors.NotParticipant();
        }

        // Update state
        escrow.status = Status.Completed;
        uint256 amount = escrow.amount;

        // Split 50/50 between depositor and recipient
        uint256 halfAmount = amount / 2;
        uint256 depositorAmount = halfAmount;
        uint256 recipientAmount = amount - halfAmount; // Handle odd amounts

        // Transfer to both parties
        usdc.safeTransfer(escrow.depositor, depositorAmount);
        usdc.safeTransfer(escrow.recipient, recipientAmount);

        // Emit events
        emit EmergencyWithdrawal(
            escrowId,
            escrow.depositor,
            escrow.recipient,
            depositorAmount,
            recipientAmount
        );
        emit BalanceChanged(
            escrow.depositor,
            escrowId,
            "emergency_refund",
            depositorAmount
        );
        emit BalanceChanged(
            escrow.recipient,
            escrowId,
            "emergency_payment",
            recipientAmount
        );
    }

    /// @inheritdoc IKoruEscrow
    function setFee(uint256 newFeeBps) external onlyOwner {
        if (newFeeBps > MAX_FEE_BPS)
            revert Errors.FeeTooHigh(newFeeBps, MAX_FEE_BPS);

        uint96 oldFeeBps = feeBps;
        feeBps = uint96(newFeeBps); // Safe: checked <= MAX_FEE_BPS (1000)

        emit FeeUpdated(oldFeeBps, newFeeBps);
    }

    /// @inheritdoc IKoruEscrow
    function setFeeRecipient(address newFeeRecipient) external onlyOwner {
        if (newFeeRecipient == address(0)) revert Errors.ZeroAddress();

        address oldRecipient = feeRecipient;
        feeRecipient = newFeeRecipient;

        emit FeeRecipientUpdated(oldRecipient, newFeeRecipient);
    }

    /// @inheritdoc IKoruEscrow
    function pause() external onlyOwner whenNotPaused {
        paused = true;
        emit Paused(msg.sender);
    }

    /// @inheritdoc IKoruEscrow
    function unpause() external onlyOwner whenPaused {
        paused = false;
        emit Unpaused(msg.sender);
    }

    /// @inheritdoc IKoruEscrow
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert Errors.ZeroAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferInitiated(owner, newOwner);
    }

    /// @inheritdoc IKoruEscrow
    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert Errors.NotPendingOwner();

        address oldOwner = owner;
        owner = pendingOwner;
        pendingOwner = address(0);

        emit OwnershipTransferred(oldOwner, owner);
    }

    // ============ View Functions ============

    /// @inheritdoc IKoruEscrow
    function getEscrow(
        uint256 escrowId
    ) external view escrowExists(escrowId) returns (Escrow memory) {
        return _escrows[escrowId];
    }

    /// @inheritdoc IKoruEscrow
    function getStatus(
        uint256 escrowId
    ) external view escrowExists(escrowId) returns (Status) {
        return _escrows[escrowId].status;
    }

    /// @inheritdoc IKoruEscrow
    function canAccept(
        uint256 escrowId
    ) external view escrowExists(escrowId) returns (bool) {
        Escrow storage escrow = _escrows[escrowId];
        return
            escrow.status == Status.Pending &&
            block.timestamp <= _getAcceptDeadline(escrow);
    }

    /// @inheritdoc IKoruEscrow
    function canDepositorWithdraw(
        uint256 escrowId
    ) external view escrowExists(escrowId) returns (bool) {
        Escrow storage escrow = _escrows[escrowId];
        return
            escrow.status == Status.Pending &&
            block.timestamp > _getAcceptDeadline(escrow);
    }

    /// @inheritdoc IKoruEscrow
    function canRecipientWithdraw(
        uint256 escrowId
    ) external view escrowExists(escrowId) returns (bool) {
        Escrow storage escrow = _escrows[escrowId];

        if (escrow.status == Status.Released) {
            return true;
        }

        if (escrow.status == Status.Accepted) {
            return block.timestamp > _getDisputeDeadline(escrow);
        }

        return false;
    }

    /// @inheritdoc IKoruEscrow
    function canDispute(
        uint256 escrowId
    ) external view escrowExists(escrowId) returns (bool) {
        Escrow storage escrow = _escrows[escrowId];
        return
            escrow.status == Status.Accepted &&
            block.timestamp <= _getDisputeDeadline(escrow);
    }

    /// @inheritdoc IKoruEscrow
    function getDeadlines(
        uint256 escrowId
    )
        external
        view
        escrowExists(escrowId)
        returns (Deadlines memory deadlines)
    {
        Escrow storage escrow = _escrows[escrowId];

        deadlines.acceptDeadline = _getAcceptDeadline(escrow);
        deadlines.disputeDeadline = _getDisputeDeadline(escrow);
    }

    /// @inheritdoc IKoruEscrow
    function calculateFee(
        uint256 amount
    ) external view returns (uint256 fee, uint256 netAmount) {
        return _calculateFee(amount);
    }

    /// @inheritdoc IKoruEscrow
    function getEscrowCount() external view returns (uint256) {
        return _nextEscrowId;
    }

    /// @inheritdoc IKoruEscrow
    function getEffectiveStatus(
        uint256 escrowId
    ) external view escrowExists(escrowId) returns (Status) {
        Escrow storage escrow = _escrows[escrowId];
        Status currentStatus = escrow.status;

        // If Pending and accept window passed, it's effectively Expired
        if (currentStatus == Status.Pending) {
            if (block.timestamp > _getAcceptDeadline(escrow)) {
                return Status.Expired;
            }
        }

        // If Accepted and dispute window passed, it's effectively ready for completion
        // (but we keep the status as Accepted until withdrawal)

        return currentStatus;
    }

    /// @inheritdoc IKoruEscrow
    function hasCounterDisputed(
        uint256 escrowId
    ) external view escrowExists(escrowId) returns (bool) {
        return _counterDisputed[escrowId];
    }

    // ============ Internal Functions ============

    // ── Timeline helpers (V2: session-date-aware) ──────────────────────────

    /// @notice Get the accept deadline for an escrow
    /// @dev If sessionDate > 0 → sessionDate + ACCEPT_WINDOW (host can accept until after session).
    ///      If sessionDate == 0 → createdAt + ACCEPT_WINDOW (legacy V1 behavior).
    function _getAcceptDeadline(
        Escrow storage escrow
    ) private view returns (uint256) {
        if (escrow.sessionDate > 0) {
            return uint256(escrow.sessionDate) + ACCEPT_WINDOW;
        }
        return uint256(escrow.createdAt) + ACCEPT_WINDOW;
    }

    /// @notice Get the dispute deadline for an escrow
    /// @dev If sessionDate > 0 → sessionDate + DISPUTE_WINDOW (dispute window covers the session).
    ///      If sessionDate == 0 → acceptedAt + DISPUTE_WINDOW (legacy V1 behavior).
    ///      Returns 0 if not accepted yet (no dispute window).
    function _getDisputeDeadline(
        Escrow storage escrow
    ) private view returns (uint256) {
        if (escrow.acceptedAt == 0) return 0;
        if (escrow.sessionDate > 0) {
            return uint256(escrow.sessionDate) + DISPUTE_WINDOW;
        }
        return uint256(escrow.acceptedAt) + DISPUTE_WINDOW;
    }

    // ── Fee calculation ────────────────────────────────────────────────────

    /// @notice Internal fee calculation using global fee parameters
    /// @param amount Gross amount
    /// @return fee Platform fee
    /// @return netAmount Amount after fee
    function _calculateFee(
        uint256 amount
    ) private view returns (uint256 fee, uint256 netAmount) {
        fee = (amount * feeBps) / BPS_DENOMINATOR;
        netAmount = amount - fee;
    }

    /// @notice Internal fee calculation using per-escrow locked fee parameters
    /// @param escrow The escrow struct with locked fee parameters
    /// @param amount Gross amount
    /// @return fee Platform fee
    /// @return netAmount Amount after fee
    function _calculateFeeForEscrow(
        Escrow storage escrow,
        uint256 amount
    ) private view returns (uint256 fee, uint256 netAmount) {
        fee = (amount * escrow.feeBps) / BPS_DENOMINATOR;
        netAmount = amount - fee;
    }

    // ============ Fallback ============

    /// @notice Reject any ETH sent to this contract
    /// @dev Contract only accepts USDC, not ETH
    receive() external payable {
        revert Errors.EthNotAccepted();
    }
}
