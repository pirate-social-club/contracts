// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {AssetPublishCoordinatorV1} from "../src/AssetPublishCoordinatorV1.sol";
import {PurchaseEntitlementToken} from "../src/PurchaseEntitlementToken.sol";

contract PublishActor {
    function setPublishOperator(AssetPublishCoordinatorV1 coordinator, address operator, bool active) external {
        coordinator.setPublishOperator(operator, active);
    }

    function publishAssetVersion(
        AssetPublishCoordinatorV1 coordinator,
        address publisher,
        bytes32 assetVersionId,
        uint32 cdrVaultUuid,
        bytes32 namespace,
        bytes32 contentHash,
        bytes32 storageRefHash,
        uint256 entitlementTokenId,
        address readCondition,
        address writeCondition
    ) external {
        coordinator.publishAssetVersion(
            publisher,
            assetVersionId,
            cdrVaultUuid,
            namespace,
            contentHash,
            storageRefHash,
            entitlementTokenId,
            readCondition,
            writeCondition
        );
    }

    function setAssetVersionActive(AssetPublishCoordinatorV1 coordinator, bytes32 assetVersionId, bool active)
        external
    {
        coordinator.setAssetVersionActive(assetVersionId, active);
    }
}

contract AssetPublishCoordinatorV1Test {
    PurchaseEntitlementToken internal token;
    AssetPublishCoordinatorV1 internal coordinator;
    PublishActor internal operator;
    PublishActor internal publisher;
    PublishActor internal stranger;

    bytes32 internal constant ASSET_VERSION_ID = keccak256("asset-version-1");
    bytes32 internal constant NAMESPACE = keccak256("namespace-1");
    bytes32 internal constant CONTENT_HASH = keccak256("content-1");
    bytes32 internal constant STORAGE_REF_HASH = keccak256("storage-ref-1");
    uint32 internal constant VAULT_UUID = 77;
    uint256 internal constant TOKEN_ID = uint256(keccak256("asset-version-1"));
    address internal constant READ_CONDITION = address(0x1001);
    address internal constant WRITE_CONDITION = address(0x1002);

    function setUp() public {
        token = new PurchaseEntitlementToken();
        coordinator = new AssetPublishCoordinatorV1(address(token));
        operator = new PublishActor();
        publisher = new PublishActor();
        stranger = new PublishActor();

        token.configureEntitlementClass(TOKEN_ID, ASSET_VERSION_ID, VAULT_UUID, true);
        coordinator.setPublishOperator(address(operator), true);
    }

    function testOperatorCanPublishAssetVersion() public {
        operator.publishAssetVersion(
            coordinator,
            address(publisher),
            ASSET_VERSION_ID,
            VAULT_UUID,
            NAMESPACE,
            CONTENT_HASH,
            STORAGE_REF_HASH,
            TOKEN_ID,
            READ_CONDITION,
            WRITE_CONDITION
        );

        (
            address recordedPublisher,
            uint32 recordedVaultUuid,
            bytes32 recordedNamespace,
            bytes32 recordedContentHash,
            bytes32 recordedStorageRefHash,
            uint256 recordedTokenId,
            address recordedReadCondition,
            address recordedWriteCondition,
            bool active,
            bool exists
        ) = coordinator.publishedAssetVersions(ASSET_VERSION_ID);

        assert(recordedPublisher == address(publisher));
        assert(recordedVaultUuid == VAULT_UUID);
        assert(recordedNamespace == NAMESPACE);
        assert(recordedContentHash == CONTENT_HASH);
        assert(recordedStorageRefHash == STORAGE_REF_HASH);
        assert(recordedTokenId == TOKEN_ID);
        assert(recordedReadCondition == READ_CONDITION);
        assert(recordedWriteCondition == WRITE_CONDITION);
        assert(active);
        assert(exists);
    }

    function testRejectsUnauthorizedPublish() public {
        (bool ok,) = address(stranger).call(
            abi.encodeWithSelector(
                PublishActor.publishAssetVersion.selector,
                coordinator,
                address(publisher),
                ASSET_VERSION_ID,
                VAULT_UUID,
                NAMESPACE,
                CONTENT_HASH,
                STORAGE_REF_HASH,
                TOKEN_ID,
                READ_CONDITION,
                WRITE_CONDITION
            )
        );
        assert(!ok);
    }

    function testRejectsDuplicatePublish() public {
        operator.publishAssetVersion(
            coordinator,
            address(publisher),
            ASSET_VERSION_ID,
            VAULT_UUID,
            NAMESPACE,
            CONTENT_HASH,
            STORAGE_REF_HASH,
            TOKEN_ID,
            READ_CONDITION,
            WRITE_CONDITION
        );

        (bool ok,) = address(operator).call(
            abi.encodeWithSelector(
                PublishActor.publishAssetVersion.selector,
                coordinator,
                address(publisher),
                ASSET_VERSION_ID,
                VAULT_UUID,
                NAMESPACE,
                CONTENT_HASH,
                STORAGE_REF_HASH,
                TOKEN_ID,
                READ_CONDITION,
                WRITE_CONDITION
            )
        );
        assert(!ok);
    }

    function testRejectsMissingOrMismatchedEntitlementClass() public {
        (bool unknownClassOk,) = address(operator).call(
            abi.encodeWithSelector(
                PublishActor.publishAssetVersion.selector,
                coordinator,
                address(publisher),
                ASSET_VERSION_ID,
                VAULT_UUID,
                NAMESPACE,
                CONTENT_HASH,
                STORAGE_REF_HASH,
                TOKEN_ID + 1,
                READ_CONDITION,
                WRITE_CONDITION
            )
        );
        assert(!unknownClassOk);

        token.configureEntitlementClass(TOKEN_ID + 1, keccak256("other-asset-version"), VAULT_UUID, true);

        (bool mismatchOk,) = address(operator).call(
            abi.encodeWithSelector(
                PublishActor.publishAssetVersion.selector,
                coordinator,
                address(publisher),
                ASSET_VERSION_ID,
                VAULT_UUID,
                NAMESPACE,
                CONTENT_HASH,
                STORAGE_REF_HASH,
                TOKEN_ID + 1,
                READ_CONDITION,
                WRITE_CONDITION
            )
        );
        assert(!mismatchOk);
    }

    function testPublisherOrOperatorCanToggleActive() public {
        operator.publishAssetVersion(
            coordinator,
            address(publisher),
            ASSET_VERSION_ID,
            VAULT_UUID,
            NAMESPACE,
            CONTENT_HASH,
            STORAGE_REF_HASH,
            TOKEN_ID,
            READ_CONDITION,
            WRITE_CONDITION
        );

        publisher.setAssetVersionActive(coordinator, ASSET_VERSION_ID, false);
        (, , , , , , , , bool activeAfterPublisher,) = coordinator.publishedAssetVersions(ASSET_VERSION_ID);
        assert(!activeAfterPublisher);

        operator.setAssetVersionActive(coordinator, ASSET_VERSION_ID, true);
        (, , , , , , , , bool activeAfterOperator,) = coordinator.publishedAssetVersions(ASSET_VERSION_ID);
        assert(activeAfterOperator);
    }

    function testRejectsUnauthorizedActiveToggleAndZeroFields() public {
        operator.publishAssetVersion(
            coordinator,
            address(publisher),
            ASSET_VERSION_ID,
            VAULT_UUID,
            NAMESPACE,
            CONTENT_HASH,
            STORAGE_REF_HASH,
            TOKEN_ID,
            READ_CONDITION,
            WRITE_CONDITION
        );

        (bool toggleOk,) = address(stranger).call(
            abi.encodeWithSelector(
                PublishActor.setAssetVersionActive.selector, coordinator, ASSET_VERSION_ID, false
            )
        );
        assert(!toggleOk);

        (bool zeroFieldOk,) = address(operator).call(
            abi.encodeWithSelector(
                PublishActor.publishAssetVersion.selector,
                coordinator,
                address(publisher),
                bytes32(0),
                VAULT_UUID,
                NAMESPACE,
                CONTENT_HASH,
                STORAGE_REF_HASH,
                TOKEN_ID,
                READ_CONDITION,
                WRITE_CONDITION
            )
        );
        assert(!zeroFieldOk);
    }
}
