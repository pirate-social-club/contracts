// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

interface IPurchaseEntitlementToken {
    function mintEntitlement(address to, uint256 tokenId, bytes32 purchaseRef) external returns (bool);
}

contract MarketplaceSettlementV1 {
    error Unauthorized();
    error ZeroAddress();
    error ZeroAmount();
    error AmountMismatch();
    error PurchaseAlreadySettled();
    error EntitlementAlreadyHeld();
    error PayoutTransferFailed();
    error Reentrancy();

    event OwnerUpdated(address indexed newOwner);
    event SettlementOperatorUpdated(address indexed operator, bool active);
    event PurchaseSettled(
        bytes32 indexed purchaseRef,
        address indexed buyer,
        uint256 indexed tokenId,
        address payoutRecipient,
        uint256 amount
    );

    address public owner;
    IPurchaseEntitlementToken public immutable entitlementToken;
    mapping(address => bool) public isSettlementOperator;
    mapping(bytes32 => bool) public settledPurchases;

    uint256 private _unlocked = 1;

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    modifier onlySettlementOperator() {
        if (!isSettlementOperator[msg.sender]) revert Unauthorized();
        _;
    }

    modifier nonReentrant() {
        if (_unlocked != 1) revert Reentrancy();
        _unlocked = 2;
        _;
        _unlocked = 1;
    }

    constructor(address entitlementToken_) {
        if (entitlementToken_ == address(0)) revert ZeroAddress();
        owner = msg.sender;
        entitlementToken = IPurchaseEntitlementToken(entitlementToken_);
        emit OwnerUpdated(msg.sender);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        owner = newOwner;
        emit OwnerUpdated(newOwner);
    }

    function setSettlementOperator(address operator, bool active) external onlyOwner {
        if (operator == address(0)) revert ZeroAddress();
        isSettlementOperator[operator] = active;
        emit SettlementOperatorUpdated(operator, active);
    }

    function settlePurchase(bytes32 purchaseRef, address buyer, uint256 tokenId, address payoutRecipient)
        external
        payable
        onlySettlementOperator
        nonReentrant
    {
        if (purchaseRef == bytes32(0)) revert ZeroAddress();
        if (buyer == address(0) || payoutRecipient == address(0)) revert ZeroAddress();
        if (msg.value == 0) revert ZeroAmount();
        if (settledPurchases[purchaseRef]) revert PurchaseAlreadySettled();

        bool minted = entitlementToken.mintEntitlement(buyer, tokenId, purchaseRef);
        if (!minted) revert EntitlementAlreadyHeld();

        settledPurchases[purchaseRef] = true;

        (bool ok,) = payoutRecipient.call{value: msg.value}("");
        if (!ok) revert PayoutTransferFailed();

        emit PurchaseSettled(purchaseRef, buyer, tokenId, payoutRecipient, msg.value);
    }
}
