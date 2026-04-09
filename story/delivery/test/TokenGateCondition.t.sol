// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {PurchaseEntitlementToken} from "../src/PurchaseEntitlementToken.sol";
import {TokenGateCondition} from "../src/TokenGateCondition.sol";

contract TokenGateActor {
    function mintEntitlement(PurchaseEntitlementToken token, address to, uint256 tokenId, bytes32 purchaseRef)
        external
    {
        token.mintEntitlement(to, tokenId, purchaseRef);
    }

    function checkReadCondition(TokenGateCondition condition, address caller, bytes calldata conditionData)
        external
        view
        returns (bool)
    {
        return condition.checkReadCondition(caller, conditionData, "0x");
    }
}

contract TokenGateConditionTest {
    PurchaseEntitlementToken internal token;
    TokenGateCondition internal condition;
    TokenGateActor internal settlementMinter;
    TokenGateActor internal buyer;
    TokenGateActor internal stranger;

    uint256 internal constant TOKEN_ID = uint256(keccak256("asset-version-1"));
    bytes32 internal constant ASSET_VERSION_ID = keccak256("asset-version-1");
    bytes32 internal constant PURCHASE_REF = keccak256("purchase-1");
    uint32 internal constant VAULT_UUID = 11;

    function setUp() public {
        token = new PurchaseEntitlementToken();
        condition = new TokenGateCondition();
        settlementMinter = new TokenGateActor();
        buyer = new TokenGateActor();
        stranger = new TokenGateActor();

        token.setSettlementMinter(address(settlementMinter), true);
        token.configureEntitlementClass(TOKEN_ID, ASSET_VERSION_ID, VAULT_UUID, true);
    }

    function testReturnsFalseWithoutEntitlement() public view {
        bytes memory conditionData = abi.encode(address(token), TOKEN_ID, uint256(1));

        bool allowed = condition.checkReadCondition(address(buyer), conditionData, "0x");
        assert(!allowed);
    }

    function testReturnsTrueForHolder() public {
        settlementMinter.mintEntitlement(token, address(buyer), TOKEN_ID, PURCHASE_REF);

        bytes memory conditionData = abi.encode(address(token), TOKEN_ID, uint256(1));
        bool allowed = condition.checkReadCondition(address(buyer), conditionData, "0x");

        assert(allowed);
    }

    function testReturnsFalseForDifferentCaller() public {
        settlementMinter.mintEntitlement(token, address(buyer), TOKEN_ID, PURCHASE_REF);

        bytes memory conditionData = abi.encode(address(token), TOKEN_ID, uint256(1));
        bool allowed = condition.checkReadCondition(address(stranger), conditionData, "0x");

        assert(!allowed);
    }

    function testRejectsZeroTokenAddressAndZeroMinBalance() public {
        (bool zeroTokenOk,) = address(condition).call(
            abi.encodeWithSelector(
                TokenGateCondition.checkReadCondition.selector,
                address(buyer),
                abi.encode(address(0), TOKEN_ID, uint256(1)),
                "0x"
            )
        );
        assert(!zeroTokenOk);

        (bool zeroMinBalanceOk,) = address(condition).call(
            abi.encodeWithSelector(
                TokenGateCondition.checkReadCondition.selector,
                address(buyer),
                abi.encode(address(token), TOKEN_ID, uint256(0)),
                "0x"
            )
        );
        assert(!zeroMinBalanceOk);
    }
}
