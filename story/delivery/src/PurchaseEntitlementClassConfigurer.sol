// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

interface IPurchaseEntitlementTokenForClassConfigurer {
    function configureEntitlementClass(uint256 tokenId, bytes32 assetVersionId, uint32 cdrVaultUuid, bool active)
        external;

    function setSettlementMinter(address minter, bool active) external;

    function transferOwnership(address newOwner) external;
}

contract PurchaseEntitlementClassConfigurer {
    error Unauthorized();
    error ZeroAddress();

    event OwnerUpdated(address indexed newOwner);
    event ClassConfigurerUpdated(address indexed configurer, bool active);

    IPurchaseEntitlementTokenForClassConfigurer public immutable entitlementToken;
    address public owner;
    mapping(address => bool) public isClassConfigurer;

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    modifier onlyClassConfigurer() {
        if (!isClassConfigurer[msg.sender]) revert Unauthorized();
        _;
    }

    constructor(address entitlementToken_) {
        if (entitlementToken_ == address(0)) revert ZeroAddress();
        entitlementToken = IPurchaseEntitlementTokenForClassConfigurer(entitlementToken_);
        owner = msg.sender;
        emit OwnerUpdated(msg.sender);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        owner = newOwner;
        emit OwnerUpdated(newOwner);
    }

    function setClassConfigurer(address configurer, bool active) external onlyOwner {
        if (configurer == address(0)) revert ZeroAddress();
        isClassConfigurer[configurer] = active;
        emit ClassConfigurerUpdated(configurer, active);
    }

    function configureEntitlementClass(uint256 tokenId, bytes32 assetVersionId, uint32 cdrVaultUuid, bool active)
        external
        onlyClassConfigurer
    {
        entitlementToken.configureEntitlementClass(tokenId, assetVersionId, cdrVaultUuid, active);
    }

    function setSettlementMinter(address minter, bool active) external onlyOwner {
        entitlementToken.setSettlementMinter(minter, active);
    }

    function transferEntitlementTokenOwnership(address newOwner) external onlyOwner {
        entitlementToken.transferOwnership(newOwner);
    }
}
