// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {PurchaseEntitlementToken} from "../src/PurchaseEntitlementToken.sol";

contract EntitlementActor {
    function setSettlementMinter(PurchaseEntitlementToken token, address minter, bool active) external {
        token.setSettlementMinter(minter, active);
    }

    function configureEntitlementClass(
        PurchaseEntitlementToken token,
        uint256 tokenId,
        bytes32 assetVersionId,
        uint32 vaultUuid,
        bool active
    ) external {
        token.configureEntitlementClass(tokenId, assetVersionId, vaultUuid, active);
    }

    function mintEntitlement(PurchaseEntitlementToken token, address to, uint256 tokenId, bytes32 purchaseRef)
        external
        returns (bool)
    {
        return token.mintEntitlement(to, tokenId, purchaseRef);
    }

    function mintEntitlementBatch(
        PurchaseEntitlementToken token,
        address[] calldata recipients,
        uint256[] calldata tokenIds,
        bytes32[] calldata purchaseRefs
    ) external {
        token.mintEntitlementBatch(recipients, tokenIds, purchaseRefs);
    }

    function revokeEntitlement(PurchaseEntitlementToken token, address from, uint256 tokenId, uint8 reasonCode)
        external
    {
        token.revokeEntitlement(from, tokenId, reasonCode);
    }

    function setApprovalForAll(PurchaseEntitlementToken token, address operator, bool approved) external pure {
        token.setApprovalForAll(operator, approved);
    }

    function safeTransferFrom(
        PurchaseEntitlementToken token,
        address from,
        address to,
        uint256 tokenId,
        uint256 amount,
        bytes calldata data
    ) external pure {
        token.safeTransferFrom(from, to, tokenId, amount, data);
    }
}

contract PurchaseEntitlementTokenTest {
    PurchaseEntitlementToken internal token;
    EntitlementActor internal ownerActor;
    EntitlementActor internal settlementMinter;
    EntitlementActor internal buyer;
    EntitlementActor internal stranger;

    uint256 internal constant TOKEN_ID = uint256(keccak256("asset-version-1"));
    bytes32 internal constant ASSET_VERSION_ID = keccak256("asset-version-1");
    bytes32 internal constant PURCHASE_REF = keccak256("purchase-1");
    uint32 internal constant VAULT_UUID = 7;

    function setUp() public {
        token = new PurchaseEntitlementToken();
        ownerActor = new EntitlementActor();
        settlementMinter = new EntitlementActor();
        buyer = new EntitlementActor();
        stranger = new EntitlementActor();
    }

    function testOwnerCanConfigureClassAndSetMinter() public {
        token.setSettlementMinter(address(settlementMinter), true);
        token.configureEntitlementClass(TOKEN_ID, ASSET_VERSION_ID, VAULT_UUID, true);

        assert(token.isSettlementMinter(address(settlementMinter)));

        (bytes32 assetVersionId, uint32 vaultUuid, bool active, bool exists) = token.entitlementClasses(TOKEN_ID);
        assert(assetVersionId == ASSET_VERSION_ID);
        assert(vaultUuid == VAULT_UUID);
        assert(active);
        assert(exists);
    }

    function testSettlementMinterCanMintIdempotently() public {
        token.setSettlementMinter(address(settlementMinter), true);
        token.configureEntitlementClass(TOKEN_ID, ASSET_VERSION_ID, VAULT_UUID, true);

        bool minted = settlementMinter.mintEntitlement(token, address(buyer), TOKEN_ID, PURCHASE_REF);
        bool mintedAgain = settlementMinter.mintEntitlement(token, address(buyer), TOKEN_ID, PURCHASE_REF);

        assert(minted);
        assert(!mintedAgain);
        assert(token.balanceOf(address(buyer), TOKEN_ID) == 1);
    }

    function testSettlementMinterCanBatchMint() public {
        token.setSettlementMinter(address(settlementMinter), true);
        token.configureEntitlementClass(TOKEN_ID, ASSET_VERSION_ID, VAULT_UUID, true);
        token.configureEntitlementClass(TOKEN_ID + 1, keccak256("asset-version-2"), VAULT_UUID + 1, true);

        address[] memory recipients = new address[](2);
        uint256[] memory tokenIds = new uint256[](2);
        bytes32[] memory purchaseRefs = new bytes32[](2);

        recipients[0] = address(buyer);
        recipients[1] = address(stranger);
        tokenIds[0] = TOKEN_ID;
        tokenIds[1] = TOKEN_ID + 1;
        purchaseRefs[0] = PURCHASE_REF;
        purchaseRefs[1] = keccak256("purchase-2");

        settlementMinter.mintEntitlementBatch(token, recipients, tokenIds, purchaseRefs);

        assert(token.balanceOf(address(buyer), TOKEN_ID) == 1);
        assert(token.balanceOf(address(stranger), TOKEN_ID + 1) == 1);
    }

    function testUnauthorizedActorsCannotConfigureOrMint() public {
        (bool configureOk,) = address(stranger).call(
            abi.encodeWithSelector(
                EntitlementActor.configureEntitlementClass.selector,
                token,
                TOKEN_ID,
                ASSET_VERSION_ID,
                VAULT_UUID,
                true
            )
        );
        assert(!configureOk);

        token.configureEntitlementClass(TOKEN_ID, ASSET_VERSION_ID, VAULT_UUID, true);

        (bool mintOk,) = address(stranger).call(
            abi.encodeWithSelector(
                EntitlementActor.mintEntitlement.selector, token, address(buyer), TOKEN_ID, PURCHASE_REF
            )
        );
        assert(!mintOk);
    }

    function testRejectsMintForInactiveOrUnknownClass() public {
        token.setSettlementMinter(address(settlementMinter), true);

        (bool unknownOk,) = address(settlementMinter).call(
            abi.encodeWithSelector(
                EntitlementActor.mintEntitlement.selector, token, address(buyer), TOKEN_ID, PURCHASE_REF
            )
        );
        assert(!unknownOk);

        token.configureEntitlementClass(TOKEN_ID, ASSET_VERSION_ID, VAULT_UUID, false);

        (bool inactiveOk,) = address(settlementMinter).call(
            abi.encodeWithSelector(
                EntitlementActor.mintEntitlement.selector, token, address(buyer), TOKEN_ID, PURCHASE_REF
            )
        );
        assert(!inactiveOk);
    }

    function testOwnerAndSettlementMinterCanRevoke() public {
        token.setSettlementMinter(address(settlementMinter), true);
        token.configureEntitlementClass(TOKEN_ID, ASSET_VERSION_ID, VAULT_UUID, true);
        settlementMinter.mintEntitlement(token, address(buyer), TOKEN_ID, PURCHASE_REF);

        settlementMinter.revokeEntitlement(token, address(buyer), TOKEN_ID, 1);
        assert(token.balanceOf(address(buyer), TOKEN_ID) == 0);

        settlementMinter.mintEntitlement(token, address(buyer), TOKEN_ID, PURCHASE_REF);
        token.revokeEntitlement(address(buyer), TOKEN_ID, 2);
        assert(token.balanceOf(address(buyer), TOKEN_ID) == 0);
    }

    function testRejectsTransfersAndApprovals() public {
        (bool approvalOk,) = address(buyer).call(
            abi.encodeWithSelector(
                EntitlementActor.setApprovalForAll.selector, token, address(stranger), true
            )
        );
        assert(!approvalOk);

        (bool transferOk,) = address(buyer).call(
            abi.encodeWithSelector(
                EntitlementActor.safeTransferFrom.selector,
                token,
                address(buyer),
                address(stranger),
                TOKEN_ID,
                1,
                bytes("")
            )
        );
        assert(!transferOk);
    }

    function testClassConfigurationIsImmutableExceptForActiveFlag() public {
        token.configureEntitlementClass(TOKEN_ID, ASSET_VERSION_ID, VAULT_UUID, true);
        token.configureEntitlementClass(TOKEN_ID, ASSET_VERSION_ID, VAULT_UUID, false);

        (, , bool active,) = token.entitlementClasses(TOKEN_ID);
        assert(!active);

        (bool ok,) = address(this).call(
            abi.encodeWithSelector(
                PurchaseEntitlementToken.configureEntitlementClass.selector,
                TOKEN_ID,
                keccak256("different-asset-version"),
                VAULT_UUID,
                true
            )
        );
        assert(!ok);
    }
}
