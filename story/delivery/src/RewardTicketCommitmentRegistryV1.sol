// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/// @notice Append-only on-chain publication rail for reward-ticket beneficiary roots.
/// @dev The chain ID is implicit in block.chainid. A root is immutable once published.
contract RewardTicketCommitmentRegistryV1 {
    error Unauthorized();
    error ZeroAddress();
    error InvalidRoot();
    error InvalidLeafCount();
    error InvalidTermsVersion();
    error AlreadyPublished();
    error RegistryPaused();
    error NotAContract();

    bytes32 public constant ROOT_DOMAIN = keccak256("pirate.reward-ticket-root.v1");

    struct Commitment {
        bytes32 rootHash;
        bytes32 termsVersionHash;
        uint32 leafCount;
        uint64 publishedAt;
        address publisher;
    }

    address public immutable owner;
    address public publisher;
    bool public paused = true;
    mapping(address jackpot => mapping(uint256 drawingId => Commitment)) private _commitments;

    event PublisherUpdated(address indexed previousPublisher, address indexed newPublisher);
    event PauseStateUpdated(bool paused);
    event CommitmentPublished(
        address indexed jackpot,
        uint256 indexed drawingId,
        bytes32 indexed rootHash,
        uint32 leafCount,
        bytes32 termsVersionHash,
        uint64 publishedAt,
        uint256 chainId,
        address publisher
    );

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    modifier onlyPublisher() {
        if (msg.sender != publisher) revert Unauthorized();
        _;
    }

    constructor(address owner_, address publisher_) {
        if (owner_ == address(0) || publisher_ == address(0)) revert ZeroAddress();
        if (owner_ == publisher_) revert Unauthorized();
        owner = owner_;
        publisher = publisher_;
        emit PublisherUpdated(address(0), publisher_);
    }

    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
        emit PauseStateUpdated(paused_);
    }

    function setPublisher(address newPublisher) external onlyOwner {
        if (newPublisher == address(0) || newPublisher == owner) revert ZeroAddress();
        address previous = publisher;
        publisher = newPublisher;
        emit PublisherUpdated(previous, newPublisher);
    }

    function publish(
        address jackpot,
        uint256 drawingId,
        bytes32 rootHash,
        uint32 leafCount,
        bytes32 termsVersionHash
    ) external onlyPublisher {
        if (paused) revert RegistryPaused();
        if (jackpot == address(0)) revert ZeroAddress();
        if (jackpot.code.length == 0) revert NotAContract();
        if (rootHash == bytes32(0)) revert InvalidRoot();
        if (leafCount == 0) revert InvalidLeafCount();
        if (termsVersionHash == bytes32(0)) revert InvalidTermsVersion();
        if (_commitments[jackpot][drawingId].publishedAt != 0) revert AlreadyPublished();

        uint64 publishedAt = uint64(block.timestamp);
        _commitments[jackpot][drawingId] = Commitment({
            rootHash: rootHash,
            termsVersionHash: termsVersionHash,
            leafCount: leafCount,
            publishedAt: publishedAt,
            publisher: msg.sender
        });
        emit CommitmentPublished(
            jackpot, drawingId, rootHash, leafCount, termsVersionHash, publishedAt, block.chainid, msg.sender
        );
    }

    function getCommitment(address jackpot, uint256 drawingId)
        external
        view
        returns (Commitment memory)
    {
        return _commitments[jackpot][drawingId];
    }

    function isPublished(address jackpot, uint256 drawingId) external view returns (bool) {
        return _commitments[jackpot][drawingId].publishedAt != 0;
    }
}
