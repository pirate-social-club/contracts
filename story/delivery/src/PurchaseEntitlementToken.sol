// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

contract PurchaseEntitlementToken {
    error Unauthorized();
    error ZeroAddress();
    error InvalidTokenId();
    error InvalidAssetVersionId();
    error InvalidVaultUuid();
    error LengthMismatch();
    error EntitlementClassNotConfigured();
    error EntitlementClassInactive();
    error EntitlementClassMismatch();
    error NonTransferable();

    event OwnerUpdated(address indexed newOwner);
    event SettlementMinterUpdated(address indexed minter, bool active);
    event EntitlementClassConfigured(
        uint256 indexed tokenId, bytes32 indexed assetVersionId, uint32 indexed cdrVaultUuid, bool active
    );
    event EntitlementMinted(address indexed to, uint256 indexed tokenId, bytes32 indexed purchaseRef);
    event EntitlementRevoked(address indexed from, uint256 indexed tokenId, uint8 reasonCode);

    struct EntitlementClass {
        bytes32 assetVersionId;
        uint32 cdrVaultUuid;
        bool active;
        bool exists;
    }

    address public owner;

    mapping(address => bool) public isSettlementMinter;
    mapping(uint256 => EntitlementClass) public entitlementClasses;
    mapping(uint256 => mapping(address => uint256)) private _balances;

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    modifier onlySettlementMinter() {
        if (!isSettlementMinter[msg.sender]) revert Unauthorized();
        _;
    }

    modifier onlyOwnerOrSettlementMinter() {
        if (msg.sender != owner && !isSettlementMinter[msg.sender]) revert Unauthorized();
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

    function setSettlementMinter(address minter, bool active) external onlyOwner {
        if (minter == address(0)) revert ZeroAddress();
        isSettlementMinter[minter] = active;
        emit SettlementMinterUpdated(minter, active);
    }

    function configureEntitlementClass(uint256 tokenId, bytes32 assetVersionId, uint32 cdrVaultUuid, bool active)
        external
        onlyOwner
    {
        if (tokenId == 0) revert InvalidTokenId();
        if (assetVersionId == bytes32(0)) revert InvalidAssetVersionId();
        if (cdrVaultUuid == 0) revert InvalidVaultUuid();

        EntitlementClass storage entitlementClass = entitlementClasses[tokenId];
        if (entitlementClass.exists) {
            if (
                entitlementClass.assetVersionId != assetVersionId || entitlementClass.cdrVaultUuid != cdrVaultUuid
            ) {
                revert EntitlementClassMismatch();
            }
        } else {
            entitlementClass.assetVersionId = assetVersionId;
            entitlementClass.cdrVaultUuid = cdrVaultUuid;
            entitlementClass.exists = true;
        }

        entitlementClass.active = active;
        emit EntitlementClassConfigured(tokenId, assetVersionId, cdrVaultUuid, active);
    }

    function balanceOf(address account, uint256 tokenId) external view returns (uint256) {
        if (account == address(0)) revert ZeroAddress();
        return _balances[tokenId][account];
    }

    function mintEntitlement(address to, uint256 tokenId, bytes32 purchaseRef) external onlySettlementMinter returns (bool) {
        return _mintEntitlement(to, tokenId, purchaseRef);
    }

    function mintEntitlementBatch(address[] calldata recipients, uint256[] calldata tokenIds, bytes32[] calldata purchaseRefs)
        external
        onlySettlementMinter
    {
        uint256 len = recipients.length;
        if (len != tokenIds.length || len != purchaseRefs.length) revert LengthMismatch();

        for (uint256 i; i < len; ) {
            _mintEntitlement(recipients[i], tokenIds[i], purchaseRefs[i]);
            unchecked {
                ++i;
            }
        }
    }

    function revokeEntitlement(address from, uint256 tokenId, uint8 reasonCode) external onlyOwnerOrSettlementMinter {
        if (from == address(0)) revert ZeroAddress();
        if (_balances[tokenId][from] == 0) return;

        _balances[tokenId][from] = 0;
        emit EntitlementRevoked(from, tokenId, reasonCode);
    }

    function setApprovalForAll(address, bool) external pure {
        revert NonTransferable();
    }

    function safeTransferFrom(address, address, uint256, uint256, bytes calldata) external pure {
        revert NonTransferable();
    }

    function safeBatchTransferFrom(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
    {
        revert NonTransferable();
    }

    function _mintEntitlement(address to, uint256 tokenId, bytes32 purchaseRef) internal returns (bool) {
        if (to == address(0)) revert ZeroAddress();
        _requireMintableClass(tokenId);

        if (_balances[tokenId][to] >= 1) {
            return false;
        }

        _balances[tokenId][to] = 1;
        emit EntitlementMinted(to, tokenId, purchaseRef);
        return true;
    }

    function _requireMintableClass(uint256 tokenId) internal view {
        EntitlementClass storage entitlementClass = entitlementClasses[tokenId];
        if (!entitlementClass.exists) revert EntitlementClassNotConfigured();
        if (!entitlementClass.active) revert EntitlementClassInactive();
    }
}
