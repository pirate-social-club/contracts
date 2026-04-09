// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

interface IEntitlementClassReader {
    function entitlementClasses(uint256 tokenId)
        external
        view
        returns (bytes32 assetVersionId, uint32 cdrVaultUuid, bool active, bool exists);
}

contract AssetPublishCoordinatorV1 {
    error Unauthorized();
    error ZeroAddress();
    error InvalidAssetVersionId();
    error InvalidVaultUuid();
    error InvalidNamespace();
    error InvalidContentHash();
    error InvalidStorageRefHash();
    error InvalidTokenId();
    error AssetVersionAlreadyPublished();
    error AssetVersionNotFound();
    error EntitlementClassNotConfigured();
    error EntitlementClassMismatch();

    event OwnerUpdated(address indexed newOwner);
    event PublishOperatorUpdated(address indexed operator, bool active);
    event AssetVersionPublished(
        bytes32 indexed assetVersionId,
        uint256 indexed entitlementTokenId,
        address indexed publisher,
        uint32 cdrVaultUuid,
        bytes32 namespace,
        bytes32 contentHash,
        bytes32 storageRefHash,
        address readCondition,
        address writeCondition
    );
    event AssetVersionActiveUpdated(bytes32 indexed assetVersionId, bool active);

    struct PublishedAssetVersion {
        address publisher;
        uint32 cdrVaultUuid;
        bytes32 namespace;
        bytes32 contentHash;
        bytes32 storageRefHash;
        uint256 entitlementTokenId;
        address readCondition;
        address writeCondition;
        bool active;
        bool exists;
    }

    address public owner;
    IEntitlementClassReader public immutable entitlementToken;

    mapping(address => bool) public isPublishOperator;
    mapping(bytes32 => PublishedAssetVersion) public publishedAssetVersions;

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    modifier onlyPublishOperator() {
        if (!isPublishOperator[msg.sender]) revert Unauthorized();
        _;
    }

    modifier onlyPublisherOrOperator(bytes32 assetVersionId) {
        PublishedAssetVersion storage published = publishedAssetVersions[assetVersionId];
        if (!published.exists) revert AssetVersionNotFound();
        if (msg.sender != published.publisher && !isPublishOperator[msg.sender]) revert Unauthorized();
        _;
    }

    constructor(address entitlementToken_) {
        if (entitlementToken_ == address(0)) revert ZeroAddress();
        owner = msg.sender;
        entitlementToken = IEntitlementClassReader(entitlementToken_);
        emit OwnerUpdated(msg.sender);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        owner = newOwner;
        emit OwnerUpdated(newOwner);
    }

    function setPublishOperator(address operator, bool active) external onlyOwner {
        if (operator == address(0)) revert ZeroAddress();
        isPublishOperator[operator] = active;
        emit PublishOperatorUpdated(operator, active);
    }

    function publishAssetVersion(
        address publisher,
        bytes32 assetVersionId,
        uint32 cdrVaultUuid,
        bytes32 namespace,
        bytes32 contentHash,
        bytes32 storageRefHash,
        uint256 entitlementTokenId,
        address readCondition,
        address writeCondition
    ) external onlyPublishOperator {
        if (publisher == address(0) || readCondition == address(0) || writeCondition == address(0)) {
            revert ZeroAddress();
        }
        if (assetVersionId == bytes32(0)) revert InvalidAssetVersionId();
        if (cdrVaultUuid == 0) revert InvalidVaultUuid();
        if (namespace == bytes32(0)) revert InvalidNamespace();
        if (contentHash == bytes32(0)) revert InvalidContentHash();
        if (storageRefHash == bytes32(0)) revert InvalidStorageRefHash();
        if (entitlementTokenId == 0) revert InvalidTokenId();
        if (publishedAssetVersions[assetVersionId].exists) revert AssetVersionAlreadyPublished();

        _requireMatchingEntitlementClass(entitlementTokenId, assetVersionId, cdrVaultUuid);

        publishedAssetVersions[assetVersionId] = PublishedAssetVersion({
            publisher: publisher,
            cdrVaultUuid: cdrVaultUuid,
            namespace: namespace,
            contentHash: contentHash,
            storageRefHash: storageRefHash,
            entitlementTokenId: entitlementTokenId,
            readCondition: readCondition,
            writeCondition: writeCondition,
            active: true,
            exists: true
        });

        emit AssetVersionPublished(
            assetVersionId,
            entitlementTokenId,
            publisher,
            cdrVaultUuid,
            namespace,
            contentHash,
            storageRefHash,
            readCondition,
            writeCondition
        );
    }

    function setAssetVersionActive(bytes32 assetVersionId, bool active) external onlyPublisherOrOperator(assetVersionId) {
        PublishedAssetVersion storage published = publishedAssetVersions[assetVersionId];
        published.active = active;
        emit AssetVersionActiveUpdated(assetVersionId, active);
    }

    function _requireMatchingEntitlementClass(uint256 entitlementTokenId, bytes32 assetVersionId, uint32 cdrVaultUuid)
        internal
        view
    {
        (bytes32 classAssetVersionId, uint32 classVaultUuid,, bool exists) =
            entitlementToken.entitlementClasses(entitlementTokenId);

        if (!exists) revert EntitlementClassNotConfigured();
        if (classAssetVersionId != assetVersionId || classVaultUuid != cdrVaultUuid) {
            revert EntitlementClassMismatch();
        }
    }
}
