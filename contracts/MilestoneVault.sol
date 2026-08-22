// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title MilestoneVault
 * @notice Escrows funds that are released only after a designated validator approves a milestone.
 *
 * @dev Lifecycle:
 *   1. Funder creates a vault and deposits ETH or ERC-20 tokens.
 *   2. A validator (separate address) is assigned per vault.
 *   3. Individual milestones are added with a target amount and description URI.
 *   4. The project team calls `submitMilestone()` when ready.
 *   5. The validator calls `approveMilestone()` to release funds to the recipient,
 *      or `rejectMilestone()` to send it back for rework.
 *   6. The funder may cancel an unclaimed vault and recover remaining funds.
 *
 * Milestones are sequential by default (must be completed in order).
 */
contract MilestoneVault is ReentrancyGuard, Pausable, AccessControl {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                ROLES
    //////////////////////////////////////////////////////////////*/

    bytes32 public constant VAULT_ADMIN_ROLE = keccak256("VAULT_ADMIN_ROLE");
    bytes32 public constant ARBITRATOR_ROLE = keccak256("ARBITRATOR_ROLE");

    /*//////////////////////////////////////////////////////////////
                            DISPUTE CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint48 public constant MIN_DISPUTE_WINDOW = 1 days;
    uint48 public constant MAX_DISPUTE_WINDOW = 90 days;

    /*//////////////////////////////////////////////////////////////
                                TYPES
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Status of an individual milestone.
     */
    enum MilestoneStatus {
        Pending,
        Submitted,
        Approved,
        Rejected,
        Cancelled,
        Disputed
    }

    /**
     * @notice Status of the overall vault.
     */
    enum VaultStatus {
        Active,
        Completed,
        Cancelled
    }

    /**
     * @notice A single milestone within a vault.
     * @param amount       Amount locked for this milestone.
     * @param status       Current lifecycle status.
     * @param submittedAt  Timestamp when submitted for review.
     * @param resolvedAt   Timestamp when approved or rejected.
     * @param descriptionURI  Off-chain URI (IPFS/Arweave) describing the milestone deliverables.
     */
    struct Milestone {
        uint256 amount;
        MilestoneStatus status;
        uint48 submittedAt;
        uint48 resolvedAt;
        string descriptionURI;
    }

    /**
     * @notice A funding vault containing multiple milestones.
     * @param funder                Address that created and funded the vault.
     * @param recipient             Address that receives milestone payouts.
     * @param validator             Address authorized to approve/reject milestones.
     * @param token                 ERC-20 address, or address(0) for ETH.
     * @param totalDeposited        Total amount deposited.
     * @param totalReleased         Total amount released to recipient.
     * @param status                Overall vault status.
     * @param sequential            When true, milestones must be completed in order.
     * @param createdAt             Timestamp of vault creation.
     * @param disputeWindowSeconds  Seconds after submission before recipient can escalate.
     */
    struct Vault {
        address funder;
        address recipient;
        address validator;
        address token;
        uint256 totalDeposited;
        uint256 totalReleased;
        VaultStatus status;
        bool sequential;
        uint48 createdAt;
        uint48 disputeWindowSeconds;
    }

    /*//////////////////////////////////////////////////////////////
                                STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Auto-incrementing vault counter
    uint256 public nextVaultId;

    /// @notice vaultId => Vault
    mapping(uint256 => Vault) private _vaults;

    /// @notice vaultId => milestoneIndex => Milestone
    mapping(uint256 => Milestone[]) private _milestones;

    /// @notice funder => list of vault IDs
    mapping(address => uint256[]) private _funderVaults;

    /// @notice recipient => list of vault IDs
    mapping(address => uint256[]) private _recipientVaults;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a new vault is created and funded.
    event VaultCreated(
        uint256 indexed vaultId,
        address indexed funder,
        address indexed recipient,
        address validator,
        address token,
        uint256 amount
    );
    /// @notice Emitted when additional funds are added to an existing vault.
    event VaultFunded(uint256 indexed vaultId, address indexed funder, uint256 amount);
    /// @notice Emitted when a milestone is added to a vault.
    event MilestoneAdded(uint256 indexed vaultId, uint256 indexed milestoneIndex, uint256 amount, string descriptionURI);
    /// @notice Emitted when the recipient submits a milestone for review.
    event MilestoneSubmitted(uint256 indexed vaultId, uint256 indexed milestoneIndex);
    /// @notice Emitted when the validator approves a milestone and its funds are released.
    event MilestoneApproved(uint256 indexed vaultId, uint256 indexed milestoneIndex, uint256 amount);
    /// @notice Emitted when the validator rejects a milestone and sends it back for rework.
    event MilestoneRejected(uint256 indexed vaultId, uint256 indexed milestoneIndex);
    /// @notice Emitted when a milestone is escalated to a dispute after the dispute window.
    event MilestoneEscalated(uint256 indexed vaultId, uint256 indexed milestoneIndex);
    /// @notice Emitted when an arbitrator resolves a disputed milestone.
    event DisputeResolved(uint256 indexed vaultId, uint256 indexed milestoneIndex, bool approved);
    /// @notice Emitted when a vault is cancelled and unreleased funds are refunded to the funder.
    event VaultCancelled(uint256 indexed vaultId, uint256 refundAmount);
    /// @notice Emitted when a vault's validator address is updated.
    event ValidatorUpdated(uint256 indexed vaultId, address newValidator);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error InvalidAddress();
    error InvalidAmount();
    error VaultNotActive(uint256 vaultId);
    error VaultNotFound(uint256 vaultId);
    error Unauthorized();
    error MilestoneNotFound(uint256 vaultId, uint256 milestoneIndex);
    error MilestoneNotPending(uint256 vaultId, uint256 milestoneIndex);
    error MilestoneNotSubmitted(uint256 vaultId, uint256 milestoneIndex);
    error MilestoneNotDisputed(uint256 vaultId, uint256 milestoneIndex);
    error InsufficientVaultBalance(uint256 required, uint256 available);
    error MilestoneTotalExceedsDeposit(uint256 total, uint256 deposited);
    error PreviousMilestoneNotApproved(uint256 milestoneIndex);
    error ETHTransferFailed();
    error TokenMismatch();
    error InvalidDisputeWindow(uint48 window);
    error DisputeWindowNotExpired(uint256 vaultId, uint256 milestoneIndex);

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address admin) {
        if (admin == address(0)) revert InvalidAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(VAULT_ADMIN_ROLE, admin);
        _grantRole(ARBITRATOR_ROLE, admin);
    }

    /*//////////////////////////////////////////////////////////////
                          VAULT CREATION & FUNDING
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Create a new vault funded with ETH.
     * @param recipient             Address to receive milestone payouts.
     * @param validator             Address authorized to approve/reject milestones.
     * @param sequential            When true, milestones must be submitted and approved in order.
     *                              When false, any Pending milestone may be submitted independently.
     * @param disputeWindowSeconds  Seconds after milestone submission before recipient can escalate.
     *                              Must be between MIN_DISPUTE_WINDOW and MAX_DISPUTE_WINDOW.
     * @return vaultId              The ID of the newly created vault.
     */
    function createETHVault(address recipient, address validator, bool sequential, uint48 disputeWindowSeconds)
        external
        payable
        whenNotPaused
        returns (uint256 vaultId)
    {
        if (recipient == address(0)) revert InvalidAddress();
        if (validator == address(0)) revert InvalidAddress();
        if (msg.value == 0) revert InvalidAmount();
        if (disputeWindowSeconds < MIN_DISPUTE_WINDOW || disputeWindowSeconds > MAX_DISPUTE_WINDOW) {
            revert InvalidDisputeWindow(disputeWindowSeconds);
        }

        vaultId = _createVault(recipient, validator, address(0), msg.value, sequential, disputeWindowSeconds);
    }

    /**
     * @notice Create a new vault funded with ERC-20 tokens.
     * @dev Caller must have approved this contract for at least `amount`.
     * @param recipient             Address to receive milestone payouts.
     * @param validator             Address authorized to approve/reject milestones.
     * @param token                 ERC-20 token address.
     * @param amount                Initial deposit amount.
     * @param sequential            When true, milestones must be submitted and approved in order.
     *                              When false, any Pending milestone may be submitted independently.
     * @param disputeWindowSeconds  Seconds after milestone submission before recipient can escalate.
     *                              Must be between MIN_DISPUTE_WINDOW and MAX_DISPUTE_WINDOW.
     * @return vaultId              The ID of the newly created vault.
     */
    function createERC20Vault(
        address recipient,
        address validator,
        address token,
        uint256 amount,
        bool sequential,
        uint48 disputeWindowSeconds
    ) external whenNotPaused returns (uint256 vaultId) {
        if (recipient == address(0)) revert InvalidAddress();
        if (validator == address(0)) revert InvalidAddress();
        if (token == address(0)) revert InvalidAddress();
        if (amount == 0) revert InvalidAmount();
        if (disputeWindowSeconds < MIN_DISPUTE_WINDOW || disputeWindowSeconds > MAX_DISPUTE_WINDOW) {
            revert InvalidDisputeWindow(disputeWindowSeconds);
        }

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        vaultId = _createVault(recipient, validator, token, amount, sequential, disputeWindowSeconds);
    }

    /**
     * @notice Deposit additional ETH into an existing vault.
     * @param vaultId ID of the vault to top-up.
     */
    function fundETHVault(uint256 vaultId) external payable whenNotPaused {
        Vault storage v = _vaults[vaultId];
        if (v.funder == address(0)) revert VaultNotFound(vaultId);
        if (v.status != VaultStatus.Active) revert VaultNotActive(vaultId);
        if (v.token != address(0)) revert TokenMismatch();
        if (msg.value == 0) revert InvalidAmount();

        v.totalDeposited += msg.value;
        emit VaultFunded(vaultId, msg.sender, msg.value);
    }

    /**
     * @notice Deposit additional ERC-20 tokens into an existing vault.
     * @param vaultId ID of the vault to top-up.
     * @param amount  Additional token amount.
     */
    function fundERC20Vault(uint256 vaultId, uint256 amount) external whenNotPaused {
        Vault storage v = _vaults[vaultId];
        if (v.funder == address(0)) revert VaultNotFound(vaultId);
        if (v.status != VaultStatus.Active) revert VaultNotActive(vaultId);
        if (v.token == address(0)) revert TokenMismatch();
        if (amount == 0) revert InvalidAmount();

        IERC20(v.token).safeTransferFrom(msg.sender, address(this), amount);
        v.totalDeposited += amount;
        emit VaultFunded(vaultId, msg.sender, amount);
    }

    /*//////////////////////////////////////////////////////////////
                          MILESTONE MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Add a milestone to a vault.
     * @dev Only the funder may add milestones. The cumulative milestone amounts must not
     *      exceed the vault's current deposit.
     * @param vaultId        Vault identifier.
     * @param amount         Token amount released upon approval.
     * @param descriptionURI Off-chain URI describing the deliverable.
     */
    function addMilestone(uint256 vaultId, uint256 amount, string calldata descriptionURI)
        external
        whenNotPaused
    {
        Vault storage v = _vaults[vaultId];
        if (v.funder == address(0)) revert VaultNotFound(vaultId);
        if (msg.sender != v.funder) revert Unauthorized();
        if (v.status != VaultStatus.Active) revert VaultNotActive(vaultId);
        if (amount == 0) revert InvalidAmount();

        // Ensure cumulative milestone amounts stay within deposit
        uint256 allocated = _totalAllocated(vaultId) + amount;
        if (allocated > v.totalDeposited) {
            revert MilestoneTotalExceedsDeposit(allocated, v.totalDeposited);
        }

        uint256 index = _milestones[vaultId].length;
        _milestones[vaultId].push(
            Milestone({
                amount: amount,
                status: MilestoneStatus.Pending,
                submittedAt: 0,
                resolvedAt: 0,
                descriptionURI: descriptionURI
            })
        );

        emit MilestoneAdded(vaultId, index, amount, descriptionURI);
    }

    /**
     * @notice Mark a milestone as submitted for validation.
     * @dev Only the recipient may submit. Milestones must be completed in order.
     * @param vaultId         Vault identifier.
     * @param milestoneIndex  Index of the milestone to submit.
     */
    function submitMilestone(uint256 vaultId, uint256 milestoneIndex)
        external
        whenNotPaused
    {
        Vault storage v = _vaults[vaultId];
        if (v.funder == address(0)) revert VaultNotFound(vaultId);
        if (msg.sender != v.recipient) revert Unauthorized();
        if (v.status != VaultStatus.Active) revert VaultNotActive(vaultId);

        Milestone[] storage milestones = _milestones[vaultId];
        if (milestoneIndex >= milestones.length) {
            revert MilestoneNotFound(vaultId, milestoneIndex);
        }
        if (milestones[milestoneIndex].status != MilestoneStatus.Pending) {
            revert MilestoneNotPending(vaultId, milestoneIndex);
        }

        // Enforce sequential ordering only when the vault requires it
        if (v.sequential && milestoneIndex > 0) {
            if (milestones[milestoneIndex - 1].status != MilestoneStatus.Approved) {
                revert PreviousMilestoneNotApproved(milestoneIndex - 1);
            }
        }

        milestones[milestoneIndex].status = MilestoneStatus.Submitted;
        milestones[milestoneIndex].submittedAt = uint48(block.timestamp);

        emit MilestoneSubmitted(vaultId, milestoneIndex);
    }

    /**
     * @notice Approve a submitted milestone and release funds to the recipient.
     * @dev Only the vault's validator may approve.
     * @param vaultId         Vault identifier.
     * @param milestoneIndex  Index of the milestone to approve.
     */
    function approveMilestone(uint256 vaultId, uint256 milestoneIndex)
        external
        nonReentrant
        whenNotPaused
    {
        Vault storage v = _vaults[vaultId];
        if (v.funder == address(0)) revert VaultNotFound(vaultId);
        if (msg.sender != v.validator) revert Unauthorized();
        if (v.status != VaultStatus.Active) revert VaultNotActive(vaultId);

        Milestone[] storage milestones = _milestones[vaultId];
        if (milestoneIndex >= milestones.length) {
            revert MilestoneNotFound(vaultId, milestoneIndex);
        }
        if (milestones[milestoneIndex].status != MilestoneStatus.Submitted) {
            revert MilestoneNotSubmitted(vaultId, milestoneIndex);
        }

        uint256 amount = milestones[milestoneIndex].amount;
        uint256 available = v.totalDeposited - v.totalReleased;
        if (amount > available) revert InsufficientVaultBalance(amount, available);

        milestones[milestoneIndex].status = MilestoneStatus.Approved;
        milestones[milestoneIndex].resolvedAt = uint48(block.timestamp);
        v.totalReleased += amount;

        // Mark vault completed if all milestones are approved
        if (_allApproved(vaultId)) {
            v.status = VaultStatus.Completed;
        }

        _transfer(v.token, v.recipient, amount);

        emit MilestoneApproved(vaultId, milestoneIndex, amount);
    }

    /**
     * @notice Reject a submitted milestone, sending it back to Pending status for rework.
     * @dev Only the vault's validator may reject.
     * @param vaultId         Vault identifier.
     * @param milestoneIndex  Index of the milestone to reject.
     */
    function rejectMilestone(uint256 vaultId, uint256 milestoneIndex)
        external
        whenNotPaused
    {
        Vault storage v = _vaults[vaultId];
        if (v.funder == address(0)) revert VaultNotFound(vaultId);
        if (msg.sender != v.validator) revert Unauthorized();
        if (v.status != VaultStatus.Active) revert VaultNotActive(vaultId);

        Milestone[] storage milestones = _milestones[vaultId];
        if (milestoneIndex >= milestones.length) {
            revert MilestoneNotFound(vaultId, milestoneIndex);
        }
        if (milestones[milestoneIndex].status != MilestoneStatus.Submitted) {
            revert MilestoneNotSubmitted(vaultId, milestoneIndex);
        }

        milestones[milestoneIndex].status = MilestoneStatus.Pending;
        milestones[milestoneIndex].resolvedAt = uint48(block.timestamp);

        emit MilestoneRejected(vaultId, milestoneIndex);
    }

    /**
     * @notice Escalate a submitted milestone to Disputed status after the dispute window expires.
     * @dev Only the recipient may call. The milestone must be in Submitted status and the
     *      dispute window must have elapsed since submission.
     * @param vaultId         Vault identifier.
     * @param milestoneIndex  Index of the milestone to escalate.
     */
    function escalate(uint256 vaultId, uint256 milestoneIndex) external whenNotPaused {
        Vault storage v = _vaults[vaultId];
        if (v.funder == address(0)) revert VaultNotFound(vaultId);
        if (msg.sender != v.recipient) revert Unauthorized();
        if (v.status != VaultStatus.Active) revert VaultNotActive(vaultId);

        Milestone[] storage milestones = _milestones[vaultId];
        if (milestoneIndex >= milestones.length) {
            revert MilestoneNotFound(vaultId, milestoneIndex);
        }

        Milestone storage m = milestones[milestoneIndex];
        if (m.status != MilestoneStatus.Submitted) {
            revert MilestoneNotSubmitted(vaultId, milestoneIndex);
        }
        if (block.timestamp <= uint256(m.submittedAt) + uint256(v.disputeWindowSeconds)) {
            revert DisputeWindowNotExpired(vaultId, milestoneIndex);
        }

        m.status = MilestoneStatus.Disputed;

        emit MilestoneEscalated(vaultId, milestoneIndex);
    }

    /**
     * @notice Resolve a disputed milestone as an arbitrator.
     * @dev Only an address with ARBITRATOR_ROLE may call. Approving releases funds to the
     *      recipient; rejecting resets the milestone to Pending for rework.
     * @param vaultId         Vault identifier.
     * @param milestoneIndex  Index of the disputed milestone.
     * @param approve         True to approve and release funds; false to reset to Pending.
     */
    function resolveDispute(uint256 vaultId, uint256 milestoneIndex, bool approve)
        external
        nonReentrant
        whenNotPaused
    {
        if (!hasRole(ARBITRATOR_ROLE, msg.sender)) revert Unauthorized();

        Vault storage v = _vaults[vaultId];
        if (v.funder == address(0)) revert VaultNotFound(vaultId);
        if (v.status != VaultStatus.Active) revert VaultNotActive(vaultId);

        Milestone[] storage milestones = _milestones[vaultId];
        if (milestoneIndex >= milestones.length) {
            revert MilestoneNotFound(vaultId, milestoneIndex);
        }

        Milestone storage m = milestones[milestoneIndex];
        if (m.status != MilestoneStatus.Disputed) {
            revert MilestoneNotDisputed(vaultId, milestoneIndex);
        }

        if (approve) {
            uint256 amount = m.amount;
            uint256 available = v.totalDeposited - v.totalReleased;
            if (amount > available) revert InsufficientVaultBalance(amount, available);

            m.status = MilestoneStatus.Approved;
            m.resolvedAt = uint48(block.timestamp);
            v.totalReleased += amount;

            if (_allApproved(vaultId)) {
                v.status = VaultStatus.Completed;
            }

            _transfer(v.token, v.recipient, amount);
        } else {
            m.status = MilestoneStatus.Pending;
            m.resolvedAt = uint48(block.timestamp);
        }

        emit DisputeResolved(vaultId, milestoneIndex, approve);
    }

    /**
     * @notice Cancel a vault and return all unreleased funds to the funder.
     * @dev Only the funder or a VAULT_ADMIN can cancel. Cannot cancel if any milestone
     *      is in Submitted or Disputed state (to prevent cancellation during review).
     * @param vaultId Vault identifier.
     */
    function cancelVault(uint256 vaultId) external nonReentrant whenNotPaused {
        Vault storage v = _vaults[vaultId];
        if (v.funder == address(0)) revert VaultNotFound(vaultId);
        if (msg.sender != v.funder && !hasRole(VAULT_ADMIN_ROLE, msg.sender)) {
            revert Unauthorized();
        }
        if (v.status != VaultStatus.Active) revert VaultNotActive(vaultId);

        // Block cancellation while a milestone is under review or in dispute
        Milestone[] storage milestones = _milestones[vaultId];
        for (uint256 i; i < milestones.length;) {
            MilestoneStatus s = milestones[i].status;
            if (s == MilestoneStatus.Submitted || s == MilestoneStatus.Disputed) {
                revert MilestoneNotPending(vaultId, i);
            }
            unchecked {
                ++i;
            }
        }

        uint256 refund = v.totalDeposited - v.totalReleased;
        v.status = VaultStatus.Cancelled;

        if (refund > 0) _transfer(v.token, v.funder, refund);

        emit VaultCancelled(vaultId, refund);
    }

    /**
     * @notice Replace the validator for a vault. Only the funder may do this.
     * @param vaultId      Vault identifier.
     * @param newValidator New validator address.
     */
    function updateValidator(uint256 vaultId, address newValidator) external whenNotPaused {
        Vault storage v = _vaults[vaultId];
        if (v.funder == address(0)) revert VaultNotFound(vaultId);
        if (msg.sender != v.funder) revert Unauthorized();
        if (newValidator == address(0)) revert InvalidAddress();
        v.validator = newValidator;
        emit ValidatorUpdated(vaultId, newValidator);
    }

    /*//////////////////////////////////////////////////////////////
                              ADMIN
    //////////////////////////////////////////////////////////////*/

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /*//////////////////////////////////////////////////////////////
                                VIEWS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Return a vault's full record.
     */
    function getVault(uint256 vaultId) external view returns (Vault memory) {
        return _vaults[vaultId];
    }

    /**
     * @notice Return all milestones for a vault.
     */
    function getMilestones(uint256 vaultId) external view returns (Milestone[] memory) {
        return _milestones[vaultId];
    }

    /**
     * @notice Return a single milestone.
     */
    function getMilestone(uint256 vaultId, uint256 milestoneIndex)
        external
        view
        returns (Milestone memory)
    {
        if (milestoneIndex >= _milestones[vaultId].length) {
            revert MilestoneNotFound(vaultId, milestoneIndex);
        }
        return _milestones[vaultId][milestoneIndex];
    }

    /**
     * @notice Return amount remaining in a vault (deposited minus released).
     */
    function remainingBalance(uint256 vaultId) external view returns (uint256) {
        Vault storage v = _vaults[vaultId];
        return v.totalDeposited - v.totalReleased;
    }

    /**
     * @notice Return all vault IDs for a funder.
     */
    function getFunderVaults(address funder) external view returns (uint256[] memory) {
        return _funderVaults[funder];
    }

    /**
     * @notice Return all vault IDs for a recipient.
     */
    function getRecipientVaults(address recipient) external view returns (uint256[] memory) {
        return _recipientVaults[recipient];
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    function _createVault(
        address recipient,
        address validator,
        address token,
        uint256 amount,
        bool sequential,
        uint48 disputeWindowSeconds
    ) internal returns (uint256 vaultId) {
        vaultId = nextVaultId++;
        _vaults[vaultId] = Vault({
            funder: msg.sender,
            recipient: recipient,
            validator: validator,
            token: token,
            totalDeposited: amount,
            totalReleased: 0,
            status: VaultStatus.Active,
            sequential: sequential,
            createdAt: uint48(block.timestamp),
            disputeWindowSeconds: disputeWindowSeconds
        });

        _funderVaults[msg.sender].push(vaultId);
        _recipientVaults[recipient].push(vaultId);

        emit VaultCreated(vaultId, msg.sender, recipient, validator, token, amount);
    }

    /**
     * @dev Sum all non-cancelled milestone amounts.
     */
    function _totalAllocated(uint256 vaultId) internal view returns (uint256 total) {
        Milestone[] storage milestones = _milestones[vaultId];
        for (uint256 i; i < milestones.length;) {
            if (milestones[i].status != MilestoneStatus.Cancelled) {
                total += milestones[i].amount;
            }
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @dev Returns true only if every milestone is in Approved status.
     */
    function _allApproved(uint256 vaultId) internal view returns (bool) {
        Milestone[] storage milestones = _milestones[vaultId];
        if (milestones.length == 0) return false;
        for (uint256 i; i < milestones.length;) {
            if (milestones[i].status != MilestoneStatus.Approved) return false;
            unchecked {
                ++i;
            }
        }
        return true;
    }

    /**
     * @dev Transfer ETH or ERC-20 out of this contract.
     */
    function _transfer(address token, address to, uint256 amount) internal {
        if (token == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert ETHTransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    receive() external payable {}
}
