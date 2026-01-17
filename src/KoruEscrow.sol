// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IKoruEscrow} from "./interfaces/IKoruEscrow.sol";
import {Errors} from "./libraries/Errors.sol";

/// @title KoruEscrow
/// @author Oleanji
/// @notice Escrow contract for Koru platform - handles USDC deposits for paid chat sessions
/// @dev Implements time-locked escrow with dispute resolution. Upgradeable via UUPS pattern.
/// @custom:security-contact security@koru.app
contract KoruEscrow is
    IKoruEscrow,
    Initializable,
    UUPSUpgradeable,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;

    // ============ Constants ============

    /// @inheritdoc IKoruEscrow
    uint256 public constant ACCEPT_WINDOW = 24 hours;

    /// @inheritdoc IKoruEscrow
    uint256 public constant DISPUTE_WINDOW = 48 hours;

    /// @notice Counter-dispute window (7 days after dispute)
    uint256 public constant COUNTER_DISPUTE_WINDOW = 7 days;

    /// @inheritdoc IKoruEscrow
    uint256 public constant MAX_FEE_BPS = 1000; // 10%

    /// @inheritdoc IKoruEscrow
    uint256 public constant BPS_DENOMINATOR = 10000;

    /// @notice Minimum escrow amount (1 USDC with 6 decimals) - prevents dust attacks
    uint256 public constant MIN_ESCROW_AMOUNT = 1 * 1e6;

    /// @notice Maximum escrow amount (1 billion USDC with 6 decimals)
    uint256 public constant MAX_ESCROW_AMOUNT = 1_000_000_000 * 1e6;

    // ============ Immutables ============

    /// @notice USDC token contract
    IERC20 public immutable usdc;

    // ============ State Variables ============

    /// @notice Platform fee in basis points (e.g., 250 = 2.5%)
    uint256 public feeBps;

    /// @notice Address receiving platform fees
    address public feeRecipient;

    /// @notice Contract owner (can update fees, resolve disputes)
    address public owner;

    /// @notice Pending owner for two-step ownership transfer
    address public pendingOwner;

    /// @notice Emergency pause state
    bool public paused;

    /// @notice Auto-incrementing escrow ID counter
    uint256 private _nextEscrowId;

    /// @notice Escrow ID => Escrow data
    mapping(uint256 => Escrow) private _escrows;

    /// @notice Escrow ID => whether recipient has counter-disputed
    mapping(uint256 => bool) private _counterDisputed;

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

    // ============ Constructor & Initializer ============

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
        if (_usdc == address(0)) revert Errors.ZeroAddress();
        if (_feeRecipient == address(0)) revert Errors.ZeroAddress();
        if (_feeBps > MAX_FEE_BPS)
            revert Errors.FeeTooHigh(_feeBps, MAX_FEE_BPS);

        usdc = IERC20(_usdc);
        feeBps = _feeBps;
        feeRecipient = _feeRecipient;
        owner = msg.sender;

        emit OwnershipTransferred(address(0), msg.sender);
        emit FeeUpdated(0, _feeBps);
        emit FeeRecipientUpdated(address(0), _feeRecipient);
    }

    /// @notice Authorize contract upgrades (UUPS requirement)
    /// @dev Only owner can upgrade the contract
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {
        // Owner authorization check is sufficient
    }

    // ============ Core Functions ============

    /// @inheritdoc IKoruEscrow
    function createEscrow(
        address recipient,
        uint256 amount
    ) external whenNotPaused nonReentrant returns (uint256 escrowId) {
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
        _escrows[escrowId] = Escrow({
            depositor: msg.sender,
            recipient: recipient,
            amount: amount,
            createdAt: block.timestamp,
            acceptedAt: 0,
            disputedAt: 0,
            status: Status.Pending,
            feeBps: feeBps, // Lock fee at creation
            feeRecipient: feeRecipient // Lock fee recipient at creation
        });

        // Transfer USDC from depositor to contract
        usdc.safeTransferFrom(msg.sender, address(this), amount);

        // Emit events
        emit EscrowCreated(
            escrowId,
            msg.sender,
            recipient,
            amount,
            block.timestamp + ACCEPT_WINDOW
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

        // Check accept window
        uint256 acceptDeadline = escrow.createdAt + ACCEPT_WINDOW;
        if (block.timestamp > acceptDeadline) {
            revert Errors.AcceptDeadlinePassed(
                escrowId,
                acceptDeadline,
                block.timestamp
            );
        }

        // Update state
        escrow.status = Status.Accepted;
        escrow.acceptedAt = block.timestamp;

        // Emit events
        emit EscrowAccepted(
            escrowId,
            msg.sender,
            block.timestamp,
            block.timestamp + DISPUTE_WINDOW
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

        // Check dispute window
        uint256 disputeDeadline = escrow.acceptedAt + DISPUTE_WINDOW;
        if (block.timestamp > disputeDeadline) {
            revert Errors.DisputeDeadlinePassed(
                escrowId,
                disputeDeadline,
                block.timestamp
            );
        }

        // Update state
        escrow.status = Status.Disputed;
        escrow.disputedAt = block.timestamp;

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

        // Must be past accept window
        uint256 acceptDeadline = escrow.createdAt + ACCEPT_WINDOW;
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
            // Check if dispute window has passed
            uint256 disputeDeadline = escrow.acceptedAt + DISPUTE_WINDOW;
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

    /// @inheritdoc IKoruEscrow
    function setFee(uint256 newFeeBps) external onlyOwner {
        if (newFeeBps > MAX_FEE_BPS)
            revert Errors.FeeTooHigh(newFeeBps, MAX_FEE_BPS);

        uint256 oldFeeBps = feeBps;
        feeBps = newFeeBps;

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
            block.timestamp <= escrow.createdAt + ACCEPT_WINDOW;
    }

    /// @inheritdoc IKoruEscrow
    function canDepositorWithdraw(
        uint256 escrowId
    ) external view escrowExists(escrowId) returns (bool) {
        Escrow storage escrow = _escrows[escrowId];
        return
            escrow.status == Status.Pending &&
            block.timestamp > escrow.createdAt + ACCEPT_WINDOW;
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
            return block.timestamp > escrow.acceptedAt + DISPUTE_WINDOW;
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
            block.timestamp <= escrow.acceptedAt + DISPUTE_WINDOW;
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

        deadlines.acceptDeadline = escrow.createdAt + ACCEPT_WINDOW;

        if (escrow.acceptedAt > 0) {
            deadlines.disputeDeadline = escrow.acceptedAt + DISPUTE_WINDOW;
        }
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
            uint256 acceptDeadline = escrow.createdAt + ACCEPT_WINDOW;
            if (block.timestamp > acceptDeadline) {
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
