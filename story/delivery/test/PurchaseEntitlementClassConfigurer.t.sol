// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {PurchaseEntitlementClassConfigurer} from "../src/PurchaseEntitlementClassConfigurer.sol";
import {PurchaseEntitlementToken} from "../src/PurchaseEntitlementToken.sol";

contract ClassConfigurerActor {
    function setClassConfigurer(PurchaseEntitlementClassConfigurer configurer, address account, bool active) external {
        configurer.setClassConfigurer(account, active);
    }

    function configureEntitlementClass(
        PurchaseEntitlementClassConfigurer configurer,
        uint256 tokenId,
        bytes32 assetVersionId,
        uint32 vaultUuid,
        bool active
    ) external {
        configurer.configureEntitlementClass(tokenId, assetVersionId, vaultUuid, active);
    }

    function transferEntitlementTokenOwnership(PurchaseEntitlementClassConfigurer configurer, address newOwner)
        external
    {
        configurer.transferEntitlementTokenOwnership(newOwner);
    }

    function transferOwnership(PurchaseEntitlementClassConfigurer configurer, address newOwner) external {
        configurer.transferOwnership(newOwner);
    }
}

contract PurchaseEntitlementClassConfigurerTest {
    PurchaseEntitlementToken internal token;
    PurchaseEntitlementClassConfigurer internal configurer;
    ClassConfigurerActor internal runtimeConfigurer;
    ClassConfigurerActor internal stranger;
    ClassConfigurerActor internal newTokenOwner;

    uint256 internal constant TOKEN_ID = uint256(keccak256("asset-version-1"));
    bytes32 internal constant ASSET_VERSION_ID = keccak256("asset-version-1");
    uint32 internal constant VAULT_UUID = 7;

    function setUp() public {
        token = new PurchaseEntitlementToken();
        configurer = new PurchaseEntitlementClassConfigurer(address(token));
        runtimeConfigurer = new ClassConfigurerActor();
        stranger = new ClassConfigurerActor();
        newTokenOwner = new ClassConfigurerActor();

        token.transferOwnership(address(configurer));
    }

    function testClassConfigurerCanConfigureEntitlementClass() public {
        configurer.setClassConfigurer(address(runtimeConfigurer), true);

        runtimeConfigurer.configureEntitlementClass(configurer, TOKEN_ID, ASSET_VERSION_ID, VAULT_UUID, true);

        (bytes32 assetVersionId, uint32 vaultUuid, bool active, bool exists) = token.entitlementClasses(TOKEN_ID);
        assert(assetVersionId == ASSET_VERSION_ID);
        assert(vaultUuid == VAULT_UUID);
        assert(active);
        assert(exists);
    }

    function testStrangerCannotConfigureEntitlementClass() public {
        (bool ok,) = address(stranger).call(
            abi.encodeWithSelector(
                ClassConfigurerActor.configureEntitlementClass.selector,
                configurer,
                TOKEN_ID,
                ASSET_VERSION_ID,
                VAULT_UUID,
                true
            )
        );

        assert(!ok);
    }

    function testOwnerCanRecoverEntitlementTokenOwnership() public {
        configurer.transferEntitlementTokenOwnership(address(newTokenOwner));

        assert(token.owner() == address(newTokenOwner));
    }

    function testStrangerCannotRecoverEntitlementTokenOwnership() public {
        (bool ok,) = address(stranger).call(
            abi.encodeWithSelector(
                ClassConfigurerActor.transferEntitlementTokenOwnership.selector,
                configurer,
                address(newTokenOwner)
            )
        );

        assert(!ok);
        assert(token.owner() == address(configurer));
    }

    function testManagedRuntimeFlow() public {
        PurchaseEntitlementToken managedToken = new PurchaseEntitlementToken();
        PurchaseEntitlementClassConfigurer managedConfigurer =
            new PurchaseEntitlementClassConfigurer(address(managedToken));
        ClassConfigurerActor apiSigner = new ClassConfigurerActor();
        ClassConfigurerActor coldOwner = new ClassConfigurerActor();
        ClassConfigurerActor unknown = new ClassConfigurerActor();

        managedConfigurer.setClassConfigurer(address(apiSigner), true);
        managedToken.transferOwnership(address(managedConfigurer));
        managedConfigurer.transferOwnership(address(coldOwner));

        assert(managedToken.owner() == address(managedConfigurer));
        assert(managedConfigurer.owner() == address(coldOwner));
        assert(managedConfigurer.isClassConfigurer(address(apiSigner)));

        apiSigner.configureEntitlementClass(managedConfigurer, TOKEN_ID, ASSET_VERSION_ID, VAULT_UUID, true);
        (bytes32 assetVersionId, uint32 vaultUuid, bool active, bool exists) =
            managedToken.entitlementClasses(TOKEN_ID);
        assert(assetVersionId == ASSET_VERSION_ID);
        assert(vaultUuid == VAULT_UUID);
        assert(active);
        assert(exists);

        (bool ok,) = address(unknown).call(
            abi.encodeWithSelector(
                ClassConfigurerActor.configureEntitlementClass.selector,
                managedConfigurer,
                uint256(keccak256("asset-version-2")),
                keccak256("asset-version-2"),
                uint32(8),
                true
            )
        );
        assert(!ok);
    }
}
