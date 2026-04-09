// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

interface IERC1155BalanceReader {
    function balanceOf(address account, uint256 id) external view returns (uint256);
}

contract TokenGateCondition {
    error ZeroTokenAddress();
    error InvalidMinBalance();

    function checkReadCondition(address caller, bytes calldata conditionData, bytes calldata)
        external
        view
        returns (bool)
    {
        (address entitlementToken, uint256 tokenId, uint256 minBalance) =
            abi.decode(conditionData, (address, uint256, uint256));

        if (entitlementToken == address(0)) revert ZeroTokenAddress();
        if (minBalance == 0) revert InvalidMinBalance();

        return IERC1155BalanceReader(entitlementToken).balanceOf(caller, tokenId) >= minBalance;
    }
}
