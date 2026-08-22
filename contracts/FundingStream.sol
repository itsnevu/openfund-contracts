// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title FundingStream
 * @notice Manages continuous funding streams for open-source projects. Funders deposit
 *         tokens that vest linearly to the recipient over a defined duration.
 *
 * @dev Streams are identified by a uint256 ID that increments per creation.
 *      A stream holds ETH (address(0) token) or any ERC-20.
 *      The recipient can withdraw accrued amounts at any time.
 *      Funders can top-up an active stream; the rate adjusts proportionally.
 */
contract FundingStream is ReentrancyGuard, Pausable, AccessControl {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                ROLES
    //////////////////////////////////////////////////////////////*/

    bytes32 public constant STREAM_MANAGER_ROLE = keccak256("STREAM_MANAGER_ROLE");

    /*//////////////////////////////////////////////////////////////
                                TYPES
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Status of a funding stream.
     */
    enum StreamStatus {
        Active,
        Paused,
        Cancelled,
        Completed
    }

    /**
     * @notice A single funding stream.
     * @param sender        Address that created and funds the stream.
     * @param recipient     Address entitled to withdraw accrued funds.
     * @param token         ERC-20 token address, or address(0) for native ETH.
     * @param totalDeposited  Cumulative amount deposited including top-ups.
     * @param withdrawn     Amount already withdrawn by the recipient.
     * @param startTime     Unix timestamp when the stream started.
     * @param endTime       Unix timestamp when the stream fully vests.
     * @param cliffDuration Seconds after startTime before any vesting begins (0 = no cliff).
     * @param lastUpdated   Timestamp of the last interaction (for rate recalculation).
     * @param status        Current lifecycle status.
     */
    struct Stream {
        address sender;
        address recipient;
        address token;
        uint256 totalDeposited;
        uint256 withdrawn;
        uint48 startTime;
        uint48 endTime;
        uint48 cliffDuration;
        uint48 lastUpdated;
        StreamStatus status;
    }

    /*//////////////////////////////////////////////////////////////
                                STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Auto-incrementing stream counter
    uint256 public nextStreamId;

    /// @notice streamId => Stream
    mapping(uint256 => Stream) private _streams;

    /// @notice recipient address => list of stream IDs where they are recipient
    mapping(address => uint256[]) private _recipientStreams;

    /// @notice sender address => list of stream IDs they created
    mapping(address => uint256[]) private _senderStreams;

    /// @notice Minimum stream duration (prevents zero-duration streams)
    uint48 public constant MIN_DURATION = 1 hours;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a new vesting stream is created.
    event StreamCreated(
        uint256 indexed streamId,
        address indexed sender,
        address indexed recipient,
        address token,
        uint256 amount,
        uint48 startTime,
        uint48 endTime
    );
    /// @notice Emitted when additional funds are added to an existing stream.
    event StreamFunded(uint256 indexed streamId, address indexed funder, uint256 amount);
    /// @notice Emitted when a recipient withdraws vested funds from a stream.
    event StreamWithdrawn(uint256 indexed streamId, address indexed recipient, uint256 amount);
    /// @notice Emitted when a stream is cancelled, splitting funds between sender and recipient.
    event StreamCancelled(
        uint256 indexed streamId, uint256 returnedToSender, uint256 releasedToRecipient
    );
    /// @notice Emitted when a stream is paused by a stream manager.
    event StreamPaused(uint256 indexed streamId);
    /// @notice Emitted when a paused stream is resumed.
    event StreamResumed(uint256 indexed streamId);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error InvalidRecipient();
    error InvalidAmount();
    error InvalidDuration();
    error InvalidCliffDuration();
    error StreamNotActive(uint256 streamId);
    error StreamNotPaused(uint256 streamId);
    error NotStreamSender(uint256 streamId);
    error NotStreamRecipient(uint256 streamId);
    error NothingToWithdraw();
    error ETHTransferFailed();
    error TokenMismatch();
    error StartTimeInPast();

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address admin) {
        if (admin == address(0)) revert InvalidRecipient();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(STREAM_MANAGER_ROLE, admin);
    }

    /*//////////////////////////////////////////////////////////////
                          STREAM CREATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Create a new ETH funding stream.
     * @param recipient      Address of the stream beneficiary.
     * @param startTime      Unix timestamp for stream start (must be >= block.timestamp).
     * @param endTime        Unix timestamp for stream end (must be > startTime + MIN_DURATION).
     * @param cliffDuration  Seconds after startTime before vesting begins (0 = no cliff,
     *                       must be strictly less than endTime - startTime).
     * @return streamId      The ID of the newly created stream.
     */
    function createETHStream(address recipient, uint48 startTime, uint48 endTime, uint48 cliffDuration)
        external
        payable
        whenNotPaused
        returns (uint256 streamId)
    {
        if (recipient == address(0) || recipient == msg.sender) revert InvalidRecipient();
        if (msg.value == 0) revert InvalidAmount();
        if (startTime < block.timestamp) revert StartTimeInPast();
        if (endTime <= startTime + MIN_DURATION) revert InvalidDuration();
        if (cliffDuration >= endTime - startTime) revert InvalidCliffDuration();

        streamId = nextStreamId++;
        _streams[streamId] = Stream({
            sender: msg.sender,
            recipient: recipient,
            token: address(0),
            totalDeposited: msg.value,
            withdrawn: 0,
            startTime: startTime,
            endTime: endTime,
            cliffDuration: cliffDuration,
            lastUpdated: uint48(block.timestamp),
            status: StreamStatus.Active
        });

        _recipientStreams[recipient].push(streamId);
        _senderStreams[msg.sender].push(streamId);

        emit StreamCreated(streamId, msg.sender, recipient, address(0), msg.value, startTime, endTime);
    }

    /**
     * @notice Create a new ERC-20 funding stream.
     * @dev Caller must have approved this contract for at least `amount` of `token`.
     * @param recipient      Address of the stream beneficiary.
     * @param token          ERC-20 token address.
     * @param amount         Amount of tokens to deposit.
     * @param startTime      Unix timestamp for stream start.
     * @param endTime        Unix timestamp for stream end.
     * @param cliffDuration  Seconds after startTime before vesting begins (0 = no cliff,
     *                       must be strictly less than endTime - startTime).
     * @return streamId      The ID of the newly created stream.
     */
    function createERC20Stream(
        address recipient,
        address token,
        uint256 amount,
        uint48 startTime,
        uint48 endTime,
        uint48 cliffDuration
    ) external whenNotPaused returns (uint256 streamId) {
        if (recipient == address(0) || recipient == msg.sender) revert InvalidRecipient();
        if (token == address(0)) revert InvalidRecipient();
        if (amount == 0) revert InvalidAmount();
        if (startTime < block.timestamp) revert StartTimeInPast();
        if (endTime <= startTime + MIN_DURATION) revert InvalidDuration();
        if (cliffDuration >= endTime - startTime) revert InvalidCliffDuration();

        streamId = nextStreamId++;
        _streams[streamId] = Stream({
            sender: msg.sender,
            recipient: recipient,
            token: token,
            totalDeposited: amount,
            withdrawn: 0,
            startTime: startTime,
            endTime: endTime,
            cliffDuration: cliffDuration,
            lastUpdated: uint48(block.timestamp),
            status: StreamStatus.Active
        });

        _recipientStreams[recipient].push(streamId);
        _senderStreams[msg.sender].push(streamId);

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        emit StreamCreated(streamId, msg.sender, recipient, token, amount, startTime, endTime);
    }

    /*//////////////////////////////////////////////////////////////
                              TOP-UP
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Add more ETH to an existing active ETH stream.
     * @dev Extends effective rate — the stream end time remains fixed; the rate increases.
     * @param streamId ID of the stream to top-up.
     */
    function fundETHStream(uint256 streamId) external payable whenNotPaused {
        Stream storage s = _streams[streamId];
        if (s.status != StreamStatus.Active) revert StreamNotActive(streamId);
        if (s.token != address(0)) revert TokenMismatch();
        if (msg.value == 0) revert InvalidAmount();

        s.totalDeposited += msg.value;

        emit StreamFunded(streamId, msg.sender, msg.value);
    }

    /**
     * @notice Add more ERC-20 tokens to an existing active ERC-20 stream.
     * @param streamId ID of the stream to top-up.
     * @param amount   Additional token amount.
     */
    function fundERC20Stream(uint256 streamId, uint256 amount) external whenNotPaused {
        Stream storage s = _streams[streamId];
        if (s.status != StreamStatus.Active) revert StreamNotActive(streamId);
        if (s.token == address(0)) revert TokenMismatch();
        if (amount == 0) revert InvalidAmount();

        s.totalDeposited += amount;
        IERC20(s.token).safeTransferFrom(msg.sender, address(this), amount);

        emit StreamFunded(streamId, msg.sender, amount);
    }

    /*//////////////////////////////////////////////////////////////
                             WITHDRAWAL
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Withdraw all currently vested funds from a stream.
     * @dev Only the recipient may call. Marks stream Completed if fully drained after end.
     * @param streamId ID of the stream to withdraw from.
     */
    function withdraw(uint256 streamId) external nonReentrant whenNotPaused {
        Stream storage s = _streams[streamId];
        if (msg.sender != s.recipient) revert NotStreamRecipient(streamId);
        if (s.status != StreamStatus.Active) revert StreamNotActive(streamId);

        uint256 available = _vestedAmount(s) - s.withdrawn;
        if (available == 0) revert NothingToWithdraw();

        s.withdrawn += available;
        s.lastUpdated = uint48(block.timestamp);

        if (block.timestamp >= s.endTime && s.withdrawn == s.totalDeposited) {
            s.status = StreamStatus.Completed;
        }

        _transfer(s.token, s.recipient, available);

        emit StreamWithdrawn(streamId, s.recipient, available);
    }

    /*//////////////////////////////////////////////////////////////
                          STREAM MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Cancel a stream. Accrued amount is released to recipient; remainder returns to sender.
     * @dev Only the stream sender may cancel.
     * @param streamId ID of the stream to cancel.
     */
    function cancel(uint256 streamId) external nonReentrant whenNotPaused {
        Stream storage s = _streams[streamId];
        if (msg.sender != s.sender) revert NotStreamSender(streamId);
        if (s.status != StreamStatus.Active) revert StreamNotActive(streamId);

        uint256 vested = _vestedAmount(s);
        uint256 recipientAmount = vested - s.withdrawn;
        uint256 senderReturn = s.totalDeposited - vested;

        s.status = StreamStatus.Cancelled;
        s.lastUpdated = uint48(block.timestamp);

        if (recipientAmount > 0) _transfer(s.token, s.recipient, recipientAmount);
        if (senderReturn > 0) _transfer(s.token, s.sender, senderReturn);

        emit StreamCancelled(streamId, senderReturn, recipientAmount);
    }

    /**
     * @notice Pause a stream (stream manager only). Stops vesting accrual while paused.
     * @param streamId ID of the stream to pause.
     */
    function pauseStream(uint256 streamId) external onlyRole(STREAM_MANAGER_ROLE) {
        Stream storage s = _streams[streamId];
        if (s.status != StreamStatus.Active) revert StreamNotActive(streamId);
        s.status = StreamStatus.Paused;
        emit StreamPaused(streamId);
    }

    /**
     * @notice Resume a paused stream.
     * @param streamId ID of the stream to resume.
     */
    function resumeStream(uint256 streamId) external onlyRole(STREAM_MANAGER_ROLE) {
        Stream storage s = _streams[streamId];
        if (s.status != StreamStatus.Paused) revert StreamNotPaused(streamId);
        s.status = StreamStatus.Active;
        emit StreamResumed(streamId);
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
     * @notice Return the full Stream record.
     */
    function getStream(uint256 streamId) external view returns (Stream memory) {
        return _streams[streamId];
    }

    /**
     * @notice Return the total amount vested so far (regardless of withdrawals).
     */
    function vestedAmount(uint256 streamId) external view returns (uint256) {
        return _vestedAmount(_streams[streamId]);
    }

    /**
     * @notice Return the amount currently available for the recipient to withdraw.
     */
    function withdrawableAmount(uint256 streamId) external view returns (uint256) {
        Stream storage s = _streams[streamId];
        if (s.status != StreamStatus.Active) return 0;
        return _vestedAmount(s) - s.withdrawn;
    }

    /**
     * @notice Return all stream IDs for a given recipient.
     */
    function getRecipientStreams(address recipient) external view returns (uint256[] memory) {
        return _recipientStreams[recipient];
    }

    /**
     * @notice Return all stream IDs created by a given sender.
     */
    function getSenderStreams(address sender) external view returns (uint256[] memory) {
        return _senderStreams[sender];
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Compute the total amount vested at the current timestamp using linear interpolation.
     *      Returns 0 before start or before the cliff elapses, totalDeposited after end.
     *      After the cliff, vesting is linear over the full startTime→endTime duration.
     */
    function _vestedAmount(Stream storage s) internal view returns (uint256) {
        if (block.timestamp < s.startTime) return 0;
        if (block.timestamp < s.startTime + s.cliffDuration) return 0;
        if (block.timestamp >= s.endTime) return s.totalDeposited;
        uint256 elapsed = block.timestamp - s.startTime;
        uint256 duration = s.endTime - s.startTime;
        return (s.totalDeposited * elapsed) / duration;
    }

    /**
     * @dev Transfer ETH or ERC-20 tokens.
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
