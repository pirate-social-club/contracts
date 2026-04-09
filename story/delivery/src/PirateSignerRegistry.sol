// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

contract PirateSignerRegistry {
    error Unauthorized();
    error ZeroAddress();

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event SignerUpdated(address indexed signer, bool active);

    address public owner;
    mapping(address => bool) public signers;

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    constructor() {
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function setSigner(address signer, bool active) external onlyOwner {
        if (signer == address(0)) revert ZeroAddress();
        signers[signer] = active;
        emit SignerUpdated(signer, active);
    }

    function isActiveSigner(address signer) external view returns (bool) {
        return signers[signer];
    }
}
