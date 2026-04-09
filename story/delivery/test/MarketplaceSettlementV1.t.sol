// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {MarketplaceSettlementV1} from "../src/MarketplaceSettlementV1.sol";
import {PurchaseEntitlementToken} from "../src/PurchaseEntitlementToken.sol";

contract SettlementActor {
    receive() external payable {}

    function setSettlementOperator(MarketplaceSettlementV1 settlement, address operator, bool active) external {
        settlement.setSettlementOperator(operator, active);
    }

    function settlePurchase(
        MarketplaceSettlementV1 settlement,
        bytes32 purchaseRef,
        address buyer,
        uint256 tokenId,
        address payoutRecipient
    ) external payable {
        settlement.settlePurchase{value: msg.value}(purchaseRef, buyer, tokenId, payoutRecipient);
    }
}

contract MarketplaceSettlementV1Test {
    PurchaseEntitlementToken internal token;
    MarketplaceSettlementV1 internal settlement;
    SettlementActor internal operator;
    SettlementActor internal buyer;
    SettlementActor internal recipient;
    SettlementActor internal stranger;

    uint256 internal constant TOKEN_ID = uint256(keccak256("asset-version-1"));
    bytes32 internal constant ASSET_VERSION_ID = keccak256("asset-version-1");
    bytes32 internal constant PURCHASE_REF = keccak256("purchase-1");
    uint32 internal constant VAULT_UUID = 42;
    uint256 internal constant AMOUNT = 1 ether;

    function setUp() public {
        token = new PurchaseEntitlementToken();
        settlement = new MarketplaceSettlementV1(address(token));
        operator = new SettlementActor();
        buyer = new SettlementActor();
        recipient = new SettlementActor();
        stranger = new SettlementActor();

        token.configureEntitlementClass(TOKEN_ID, ASSET_VERSION_ID, VAULT_UUID, true);
        token.setSettlementMinter(address(settlement), true);
        settlement.setSettlementOperator(address(operator), true);
    }

    function testOperatorCanSettlePurchaseAndMintEntitlement() public {
        uint256 recipientBalanceBefore = address(recipient).balance;

        operator.settlePurchase{value: AMOUNT}(
            settlement, PURCHASE_REF, address(buyer), TOKEN_ID, address(recipient)
        );

        assert(token.balanceOf(address(buyer), TOKEN_ID) == 1);
        assert(settlement.settledPurchases(PURCHASE_REF));
        assert(address(recipient).balance == recipientBalanceBefore + AMOUNT);
    }

    function testRejectsUnauthorizedSettlement() public {
        (bool ok,) = address(stranger).call{value: AMOUNT}(
            abi.encodeWithSelector(
                SettlementActor.settlePurchase.selector,
                settlement,
                PURCHASE_REF,
                address(buyer),
                TOKEN_ID,
                address(recipient)
            )
        );
        assert(!ok);
    }

    function testRejectsDuplicatePurchaseRef() public {
        operator.settlePurchase{value: AMOUNT}(
            settlement, PURCHASE_REF, address(buyer), TOKEN_ID, address(recipient)
        );

        (bool ok,) = address(operator).call{value: AMOUNT}(
            abi.encodeWithSelector(
                SettlementActor.settlePurchase.selector,
                settlement,
                PURCHASE_REF,
                address(buyer),
                TOKEN_ID,
                address(recipient)
            )
        );
        assert(!ok);
    }

    function testRejectsSettlementWhenBuyerAlreadyHoldsEntitlement() public {
        operator.settlePurchase{value: AMOUNT}(
            settlement, PURCHASE_REF, address(buyer), TOKEN_ID, address(recipient)
        );

        (bool ok,) = address(operator).call{value: AMOUNT}(
            abi.encodeWithSelector(
                SettlementActor.settlePurchase.selector,
                settlement,
                keccak256("purchase-2"),
                address(buyer),
                TOKEN_ID,
                address(recipient)
            )
        );
        assert(!ok);
    }

    function testRejectsZeroAmountOrZeroAddresses() public {
        (bool zeroAmountOk,) = address(operator).call(
            abi.encodeWithSelector(
                SettlementActor.settlePurchase.selector,
                settlement,
                PURCHASE_REF,
                address(buyer),
                TOKEN_ID,
                address(recipient)
            )
        );
        assert(!zeroAmountOk);

        (bool zeroBuyerOk,) = address(operator).call{value: AMOUNT}(
            abi.encodeWithSelector(
                SettlementActor.settlePurchase.selector,
                settlement,
                PURCHASE_REF,
                address(0),
                TOKEN_ID,
                address(recipient)
            )
        );
        assert(!zeroBuyerOk);

        (bool zeroRecipientOk,) = address(operator).call{value: AMOUNT}(
            abi.encodeWithSelector(
                SettlementActor.settlePurchase.selector,
                settlement,
                PURCHASE_REF,
                address(buyer),
                TOKEN_ID,
                address(0)
            )
        );
        assert(!zeroRecipientOk);
    }

    function testRejectsUnknownEntitlementClass() public {
        (bool ok,) = address(operator).call{value: AMOUNT}(
            abi.encodeWithSelector(
                SettlementActor.settlePurchase.selector,
                settlement,
                PURCHASE_REF,
                address(buyer),
                TOKEN_ID + 1,
                address(recipient)
            )
        );
        assert(!ok);
    }
}
