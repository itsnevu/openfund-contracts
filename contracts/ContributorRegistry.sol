// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title ContributorRegistry
 * @notice Central registry for contributors in the OpenFund Protocol. Tracks contributor
 *         metadata, roles, and weights used by the SplitManager and other protocol contracts.
 * @dev Role hierarchy: DEFAULT_ADMIN_ROLE > REGISTRAR_ROLE. Registrars can register and
 *      update contributors; only admins can grant/revoke roles.
 */
contract ContributorRegistry is AccessControl, Pausable {
    /*//////////////////////////////////////////////////////////////
                                ROLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Can register new contributors and update existing ones.
    bytes32 public constant REGISTRAR_ROLE = keccak256("REGISTRAR_ROLE");

    /*//////////////////////////////////////////////////////////////
                                TYPES
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Role assigned to a contributor within a project.
     * @param NONE  Uninitialized / not a contributor.
     * @param CONTRIBUTOR Standard contributor (developer, designer, etc.).
     * @param MAINTAINER  Long-term project steward with higher trust.
     * @param ADMIN       Project-level administrator.
     */
    enum Role {
        NONE,
        CONTRIBUTOR,
        MAINTAINER,
        ADMIN
    }

    /**
     * @notice Input record for batch registration.
     */
    struct ContributorInput {
        address contributor;
        bytes32 projectId;
        Role role;
        uint96 weight;
        string metadata;
    }

    /**
     * @notice Full contributor record.
     * @param contributor  Wallet address of the contributor.
     * @param projectId    Identifier of the project they belong to.
     * @param role         Their role within the project.
     * @param weight       Relative weight used for revenue splitting (basis points, sum <= 10_000 per project).
     * @param active       Whether the contributor is currently active.
     * @param registeredAt Block timestamp of initial registration.
     * @param updatedAt    Block timestamp of last update.
     * @param metadata     Optional off-chain URI (IPFS / Arweave) for extended profile data.
     */
    struct Contributor {
        address contributor;
        bytes32 projectId;
        Role role;
        uint96 weight;
        bool active;
        uint48 registeredAt;
        uint48 updatedAt;
        string metadata;
    }

    /*//////////////////////////////////////////////////////////////
                                STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice contributor address => projectId => Contributor record
    mapping(address => mapping(bytes32 => Contributor)) private _contributors;

    /// @notice projectId => list of contributor addresses
    mapping(bytes32 => address[]) private _projectContributors;

    /// @notice Tracks whether an address has ever been registered for a project (prevents duplicates in array)
    mapping(address => mapping(bytes32 => bool)) private _registered;
    /// @notice Tracks which projectIds have been seen, so ProjectCreated is emitted only once per project
    mapping(bytes32 => bool) private _projectExists;

    /// @notice Total number of unique contributors across all projects
    uint256 public totalContributors;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted once, the first time any contributor is registered for a given project.
    event ProjectCreated(bytes32 indexed projectId, address indexed registrar, uint48 timestamp);
    event ContributorRegistered(
        address indexed contributor, bytes32 indexed projectId, Role role, uint96 weight
    );
    event ContributorUpdated(
        address indexed contributor, bytes32 indexed projectId, Role role, uint96 weight
    );
    event ContributorDeactivated(address indexed contributor, bytes32 indexed projectId);
    event ContributorReactivated(address indexed contributor, bytes32 indexed projectId);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error AlreadyRegistered(address contributor, bytes32 projectId);
    error NotRegistered(address contributor, bytes32 projectId);
    error InvalidWeight(uint96 weight);
    error InvalidAddress();
    error InvalidProjectId();
    error BatchTooLarge(uint256 count);

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @param admin Address that receives DEFAULT_ADMIN_ROLE and REGISTRAR_ROLE.
     */
    constructor(address admin) {
        if (admin == address(0)) revert InvalidAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(REGISTRAR_ROLE, admin);
    }

    /*//////////////////////////////////////////////////////////////
                          REGISTRATION LOGIC
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Register a new contributor for a project.
     * @dev Weight is in basis points. No enforcement of per-project sum here; the
     *      SplitManager validates totals when defining splits.
     * @param contributor  Address of the contributor.
     * @param projectId    Project identifier (e.g. keccak256 of project name).
     * @param role         Initial role.
     * @param weight       Weight in basis points (1–10_000).
     * @param metadata     Optional URI for off-chain profile.
     */
    function register(
        address contributor,
        bytes32 projectId,
        Role role,
        uint96 weight,
        string calldata metadata
    ) external onlyRole(REGISTRAR_ROLE) whenNotPaused {
        _register(contributor, projectId, role, weight, metadata);
    }

    /**
     * @notice Register multiple contributors in a single transaction.
     * @dev Atomic: if any entry is invalid the entire batch reverts. Capped at 50 entries.
     * @param contributors  Array of contributor inputs to register.
     */
    function batchRegister(ContributorInput[] calldata contributors)
        external
        onlyRole(REGISTRAR_ROLE)
        whenNotPaused
    {
        if (contributors.length > 50) revert BatchTooLarge(contributors.length);
        for (uint256 i; i < contributors.length;) {
            ContributorInput calldata c = contributors[i];
            _register(c.contributor, c.projectId, c.role, c.weight, c.metadata);
            unchecked {
                ++i;
            }
        }
    }

    function _register(
        address contributor,
        bytes32 projectId,
        Role role,
        uint96 weight,
        string calldata metadata
    ) internal {
        if (contributor == address(0)) revert InvalidAddress();
        if (projectId == bytes32(0)) revert InvalidProjectId();

        // The first registration for a project emits ProjectCreated so off-chain
        // indexers can track project lifecycle from inception. Subsequent
        // registrations for the same project only emit ContributorRegistered.
        if (!_projectExists[projectId]) {
            _projectExists[projectId] = true;
            emit ProjectCreated(projectId, msg.sender, uint48(block.timestamp));
        }
        if (_registered[contributor][projectId]) revert AlreadyRegistered(contributor, projectId);
        if (weight == 0 || weight > 10_000) revert InvalidWeight(weight);

        _contributors[contributor][projectId] = Contributor({
            contributor: contributor,
            projectId: projectId,
            role: role,
            weight: weight,
            active: true,
            registeredAt: uint48(block.timestamp),
            updatedAt: uint48(block.timestamp),
            metadata: metadata
        });

        _registered[contributor][projectId] = true;
        _projectContributors[projectId].push(contributor);
        unchecked {
            ++totalContributors;
        }

        emit ContributorRegistered(contributor, projectId, role, weight);
    }

    /**
     * @notice Update role, weight, and/or metadata for an existing contributor.
     * @param contributor Address of the contributor.
     * @param projectId   Project identifier.
     * @param role        New role.
     * @param weight      New weight in basis points.
     * @param metadata    New metadata URI (pass empty string to keep existing).
     */
    function update(
        address contributor,
        bytes32 projectId,
        Role role,
        uint96 weight,
        string calldata metadata
    ) external onlyRole(REGISTRAR_ROLE) whenNotPaused {
        if (!_registered[contributor][projectId]) revert NotRegistered(contributor, projectId);
        if (weight == 0 || weight > 10_000) revert InvalidWeight(weight);

        Contributor storage c = _contributors[contributor][projectId];
        c.role = role;
        c.weight = weight;
        c.updatedAt = uint48(block.timestamp);
        if (bytes(metadata).length > 0) {
            c.metadata = metadata;
        }

        emit ContributorUpdated(contributor, projectId, role, weight);
    }

    /**
     * @notice Mark a contributor as inactive. Does not remove their record.
     */
    function deactivate(address contributor, bytes32 projectId)
        external
        onlyRole(REGISTRAR_ROLE)
        whenNotPaused
    {
        if (!_registered[contributor][projectId]) revert NotRegistered(contributor, projectId);
        _contributors[contributor][projectId].active = false;
        _contributors[contributor][projectId].updatedAt = uint48(block.timestamp);
        emit ContributorDeactivated(contributor, projectId);
    }

    /**
     * @notice Reactivate a previously deactivated contributor.
     */
    function reactivate(address contributor, bytes32 projectId)
        external
        onlyRole(REGISTRAR_ROLE)
        whenNotPaused
    {
        if (!_registered[contributor][projectId]) revert NotRegistered(contributor, projectId);
        _contributors[contributor][projectId].active = true;
        _contributors[contributor][projectId].updatedAt = uint48(block.timestamp);
        emit ContributorReactivated(contributor, projectId);
    }

    /*//////////////////////////////////////////////////////////////
                              ADMIN LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Pause all state-changing operations (emergency use).
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /// @notice Resume normal operations.
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /*//////////////////////////////////////////////////////////////
                                VIEWS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Fetch a contributor's full record.
     */
    function getContributor(address contributor, bytes32 projectId)
        external
        view
        returns (Contributor memory)
    {
        return _contributors[contributor][projectId];
    }

    /**
     * @notice Returns true if the address is a registered and active contributor for the project.
     */
    function isActive(address contributor, bytes32 projectId) external view returns (bool) {
        return _registered[contributor][projectId] && _contributors[contributor][projectId].active;
    }

    /**
     * @notice Returns true if the address has ever been registered for the project (regardless of active state).
     */
    function isRegistered(address contributor, bytes32 projectId) external view returns (bool) {
        return _registered[contributor][projectId];
    }

    /**
     * @notice Return all contributor addresses for a project (active and inactive).
     */
    function getProjectContributors(bytes32 projectId)
        external
        view
        returns (address[] memory)
    {
        return _projectContributors[projectId];
    }

    /**
     * @notice Return the weight of a contributor for a given project.
     */
    function getWeight(address contributor, bytes32 projectId) external view returns (uint96) {
        return _contributors[contributor][projectId].weight;
    }
}
