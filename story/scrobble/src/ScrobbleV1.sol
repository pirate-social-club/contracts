// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

contract ScrobbleV1 {
    error Unauthorized();
    error ZeroAddress();
    error InvalidTrackId();
    error InvalidMetadataHash();
    error InvalidTimestamp();
    error InvalidSourceType();
    error InvalidSubmissionMode();
    error LengthMismatch();
    error BatchTooLarge();
    error TrackAlreadyRegistered();
    error TrackNotRegistered();

    event OwnerUpdated(address indexed newOwner);
    event OperatorUpdated(address indexed operator, bool active);

    /// @notice Minimal onchain track registry keyed by Pirate's canonical track id.
    event TrackRegistered(bytes32 indexed trackId, bytes32 indexed metadataHash, uint64 registeredAt);

    /// @notice Canonical listen event. `clubId = bytes32(0)` means no club context.
    event Scrobbled(
        address indexed user,
        bytes32 indexed trackId,
        bytes32 indexed clubId,
        uint64 playbackStartedAt,
        uint32 creditedDurationMs,
        uint8 sourceType,
        uint8 submissionMode
    );

    struct Track {
        bytes32 metadataHash;
        uint64 registeredAt;
        bool exists;
    }

    address public owner;
    mapping(address => bool) public isOperator;
    mapping(bytes32 => Track) public tracks;

    uint256 public constant MAX_BATCH = 200;

    uint8 public constant SOURCE_WEB = 1;
    uint8 public constant SOURCE_DESKTOP = 2;
    uint8 public constant SOURCE_MOBILE = 3;
    uint8 public constant SOURCE_OPERATOR = 4;

    uint8 public constant MODE_DIRECT = 1;
    uint8 public constant MODE_DELEGATED = 2;

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    modifier onlyOperator() {
        if (!isOperator[msg.sender]) revert Unauthorized();
        _;
    }

    modifier onlyUserOrOperator(address user) {
        if (user == address(0)) revert ZeroAddress();
        if (msg.sender != user && !isOperator[msg.sender]) revert Unauthorized();
        _;
    }

    constructor() {
        owner = msg.sender;
        emit OwnerUpdated(msg.sender);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        owner = newOwner;
        emit OwnerUpdated(newOwner);
    }

    function setOperator(address operator, bool active) external onlyOwner {
        if (operator == address(0)) revert ZeroAddress();
        isOperator[operator] = active;
        emit OperatorUpdated(operator, active);
    }

    function registerTrack(bytes32 trackId, bytes32 metadataHash) external onlyOperator {
        _registerTrack(trackId, metadataHash);
    }

    function registerTracks(bytes32[] calldata trackIds, bytes32[] calldata metadataHashes) external onlyOperator {
        uint256 len = trackIds.length;
        if (len != metadataHashes.length) revert LengthMismatch();
        if (len > MAX_BATCH) revert BatchTooLarge();

        for (uint256 i; i < len; ) {
            _registerTrack(trackIds[i], metadataHashes[i]);
            unchecked {
                ++i;
            }
        }
    }

    function scrobble(
        address user,
        bytes32 trackId,
        bytes32 clubId,
        uint64 playbackStartedAt,
        uint32 creditedDurationMs,
        uint8 sourceType,
        uint8 submissionMode
    ) external onlyUserOrOperator(user) {
        _scrobble(user, trackId, clubId, playbackStartedAt, creditedDurationMs, sourceType, submissionMode);
    }

    function scrobbleBatch(
        address user,
        bytes32[] calldata trackIds,
        bytes32[] calldata clubIds,
        uint64[] calldata playbackStartedAts,
        uint32[] calldata creditedDurationsMs,
        uint8[] calldata sourceTypes,
        uint8[] calldata submissionModes
    ) external onlyUserOrOperator(user) {
        uint256 len = trackIds.length;
        if (
            len != clubIds.length || len != playbackStartedAts.length || len != creditedDurationsMs.length
                || len != sourceTypes.length || len != submissionModes.length
        ) revert LengthMismatch();
        if (len > MAX_BATCH) revert BatchTooLarge();

        for (uint256 i; i < len; ) {
            _scrobble(
                user,
                trackIds[i],
                clubIds[i],
                playbackStartedAts[i],
                creditedDurationsMs[i],
                sourceTypes[i],
                submissionModes[i]
            );
            unchecked {
                ++i;
            }
        }
    }

    function _registerTrack(bytes32 trackId, bytes32 metadataHash) internal {
        if (trackId == bytes32(0)) revert InvalidTrackId();
        if (metadataHash == bytes32(0)) revert InvalidMetadataHash();
        if (tracks[trackId].exists) revert TrackAlreadyRegistered();

        tracks[trackId] = Track({metadataHash: metadataHash, registeredAt: uint64(block.timestamp), exists: true});
        emit TrackRegistered(trackId, metadataHash, uint64(block.timestamp));
    }

    function _scrobble(
        address user,
        bytes32 trackId,
        bytes32 clubId,
        uint64 playbackStartedAt,
        uint32 creditedDurationMs,
        uint8 sourceType,
        uint8 submissionMode
    ) internal {
        if (trackId == bytes32(0)) revert InvalidTrackId();
        if (!tracks[trackId].exists) revert TrackNotRegistered();
        if (playbackStartedAt == 0) revert InvalidTimestamp();
        if (!_isValidSourceType(sourceType)) revert InvalidSourceType();
        if (!_isValidSubmissionMode(submissionMode)) revert InvalidSubmissionMode();

        emit Scrobbled(
            user,
            trackId,
            clubId,
            playbackStartedAt,
            creditedDurationMs,
            sourceType,
            submissionMode
        );
    }

    function _isValidSourceType(uint8 sourceType) internal pure returns (bool) {
        return sourceType >= SOURCE_WEB && sourceType <= SOURCE_OPERATOR;
    }

    function _isValidSubmissionMode(uint8 submissionMode) internal pure returns (bool) {
        return submissionMode >= MODE_DIRECT && submissionMode <= MODE_DELEGATED;
    }
}
