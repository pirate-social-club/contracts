// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

interface IPirateSignerRegistry {
    function isActiveSigner(address signer) external view returns (bool);
}

library SimpleECDSA {
    error InvalidSignatureLength();
    error InvalidSignatureS();
    error InvalidSignatureV();

    uint256 internal constant SECP256K1_N_DIV_2 =
        0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

    function recover(bytes32 digest, bytes memory signature) internal pure returns (address) {
        if (signature.length != 65) revert InvalidSignatureLength();

        bytes32 r;
        bytes32 s;
        uint8 v;

        assembly {
            r := mload(add(signature, 0x20))
            s := mload(add(signature, 0x40))
            v := byte(0, mload(add(signature, 0x60)))
        }

        if (uint256(s) > SECP256K1_N_DIV_2) revert InvalidSignatureS();
        if (v != 27 && v != 28) revert InvalidSignatureV();

        return ecrecover(digest, v, r, s);
    }
}

contract SignedAccessConditionV1 {
    using SimpleECDSA for bytes32;

    error InvalidSignerRegistry();
    error CallerMismatch();
    error NamespaceMismatch();
    error ProofExpired();
    error UnknownScope();
    error InvalidSignature();

    bytes32 public constant ACCESS_PROOF_TYPEHASH = keccak256(
        "AccessProof("
            "uint32 vaultUuid,"
            "address caller,"
            "bytes32 accessRef,"
            "bytes32 scope,"
            "uint64 expiry,"
            "bytes32 namespace"
        ")"
    );

    bytes32 public constant SCOPE_ASSET_OWNER = keccak256("asset.owner");
    bytes32 public constant SCOPE_ASSET_SHARE = keccak256("asset.share");

    bytes32 public immutable DOMAIN_SEPARATOR;
    IPirateSignerRegistry public immutable signerRegistry;

    struct AccessProof {
        uint32 vaultUuid;
        address caller;
        bytes32 accessRef;
        bytes32 scope;
        uint64 expiry;
        bytes32 namespace;
    }

    constructor(address signerRegistry_) {
        if (signerRegistry_ == address(0)) revert InvalidSignerRegistry();
        signerRegistry = IPirateSignerRegistry(signerRegistry_);
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256("PirateSignedAccess"),
                keccak256("1"),
                block.chainid,
                address(this)
            )
        );
    }

    function checkReadCondition(address caller, bytes calldata conditionData, bytes calldata accessAuxData)
        external
        view
        returns (bool)
    {
        bytes32 namespace = abi.decode(conditionData, (bytes32));
        (AccessProof memory proof, bytes memory signature) = abi.decode(accessAuxData, (AccessProof, bytes));

        if (proof.caller != caller) revert CallerMismatch();
        if (proof.namespace != namespace) revert NamespaceMismatch();
        if (proof.expiry < block.timestamp) revert ProofExpired();
        if (proof.scope != SCOPE_ASSET_OWNER && proof.scope != SCOPE_ASSET_SHARE) revert UnknownScope();

        address signer = _hashProof(proof).recover(signature);
        if (!signerRegistry.isActiveSigner(signer)) revert InvalidSignature();
        return true;
    }

    function checkWriteCondition(address caller, bytes calldata conditionData, bytes calldata)
        external
        pure
        returns (bool)
    {
        address publisherOperator = abi.decode(conditionData, (address));
        return caller == publisherOperator;
    }

    function hashProof(AccessProof memory proof) external view returns (bytes32) {
        return _hashProof(proof);
    }

    function _hashProof(AccessProof memory proof) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                ACCESS_PROOF_TYPEHASH,
                proof.vaultUuid,
                proof.caller,
                proof.accessRef,
                proof.scope,
                proof.expiry,
                proof.namespace
            )
        );

        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
    }
}
