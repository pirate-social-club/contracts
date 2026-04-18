// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {PirateSignerRegistry} from "../src/PirateSignerRegistry.sol";
import {SignedAccessConditionV1} from "../src/SignedAccessConditionV1.sol";

interface Vm {
    function addr(uint256 privateKey) external returns (address);
    function sign(uint256 privateKey, bytes32 digest) external returns (uint8 v, bytes32 r, bytes32 s);
    function warp(uint256 newTimestamp) external;
}

address constant VM_ADDRESS = address(uint160(uint256(keccak256("hevm cheat code"))));
Vm constant vm = Vm(VM_ADDRESS);

contract SignedAccessConditionV1Test {
    bytes4 internal constant CHECK_READ_SELECTOR =
        bytes4(keccak256("checkReadCondition(address,bytes,bytes)"));

    PirateSignerRegistry internal registry;
    SignedAccessConditionV1 internal condition;

    uint256 internal constant SIGNER_PK = 0xA11CE;
    uint256 internal constant OTHER_PK = 0xB0B;
    uint32 internal constant VAULT_UUID = 23;

    function setUp() public {
        registry = new PirateSignerRegistry();
        condition = new SignedAccessConditionV1(address(registry));
        registry.setSigner(vm.addr(SIGNER_PK), true);
        vm.warp(1_000);
    }

    function testValidProofPassesForOwnerScope() public {
        SignedAccessConditionV1.AccessProof memory proof = _proof(
            address(0xBEEF),
            condition.SCOPE_ASSET_OWNER(),
            2_000,
            keccak256("namespace-1"),
            keccak256("purchase-1")
        );

        bytes memory accessAuxData = abi.encode(proof, _sign(SIGNER_PK, proof));
        bool allowed = condition.checkReadCondition(proof.caller, abi.encode(proof.namespace), accessAuxData);

        assert(allowed);
    }

    function testValidProofPassesForShareScope() public {
        SignedAccessConditionV1.AccessProof memory proof = _proof(
            address(0xCAFE),
            condition.SCOPE_ASSET_SHARE(),
            2_000,
            keccak256("namespace-2"),
            keccak256("share-1")
        );

        bytes memory accessAuxData = abi.encode(proof, _sign(SIGNER_PK, proof));
        bool allowed = condition.checkReadCondition(proof.caller, abi.encode(proof.namespace), accessAuxData);

        assert(allowed);
    }

    function testRejectsCallerMismatch() public {
        SignedAccessConditionV1.AccessProof memory proof = _proof(
            address(0xBEEF),
            condition.SCOPE_ASSET_OWNER(),
            2_000,
            keccak256("namespace-1"),
            keccak256("purchase-1")
        );

        (bool ok,) = address(condition).call(
            abi.encodeWithSelector(
                CHECK_READ_SELECTOR,
                address(0xDEAD),
                abi.encode(proof.namespace),
                abi.encode(proof, _sign(SIGNER_PK, proof))
            )
        );
        assert(!ok);
    }

    function testRejectsNamespaceMismatch() public {
        SignedAccessConditionV1.AccessProof memory proof = _proof(
            address(0xBEEF),
            condition.SCOPE_ASSET_OWNER(),
            2_000,
            keccak256("namespace-1"),
            keccak256("purchase-1")
        );

        (bool ok,) = address(condition).call(
            abi.encodeWithSelector(
                CHECK_READ_SELECTOR,
                proof.caller,
                abi.encode(keccak256("other-namespace")),
                abi.encode(proof, _sign(SIGNER_PK, proof))
            )
        );
        assert(!ok);
    }

    function testRejectsExpiredProof() public {
        SignedAccessConditionV1.AccessProof memory proof = _proof(
            address(0xBEEF),
            condition.SCOPE_ASSET_OWNER(),
            999,
            keccak256("namespace-1"),
            keccak256("purchase-1")
        );

        (bool ok,) = address(condition).call(
            abi.encodeWithSelector(
                CHECK_READ_SELECTOR,
                proof.caller,
                abi.encode(proof.namespace),
                abi.encode(proof, _sign(SIGNER_PK, proof))
            )
        );
        assert(!ok);
    }

    function testRejectsUnknownScope() public {
        SignedAccessConditionV1.AccessProof memory proof = _proof(
            address(0xBEEF),
            bytes32(uint256(123)),
            2_000,
            keccak256("namespace-1"),
            keccak256("purchase-1")
        );

        (bool ok,) = address(condition).call(
            abi.encodeWithSelector(
                CHECK_READ_SELECTOR,
                proof.caller,
                abi.encode(proof.namespace),
                abi.encode(proof, _sign(SIGNER_PK, proof))
            )
        );
        assert(!ok);
    }

    function testRejectsSignerNotInRegistry() public {
        SignedAccessConditionV1.AccessProof memory proof = _proof(
            address(0xBEEF),
            condition.SCOPE_ASSET_OWNER(),
            2_000,
            keccak256("namespace-1"),
            keccak256("purchase-1")
        );

        (bool ok,) = address(condition).call(
            abi.encodeWithSelector(
                CHECK_READ_SELECTOR,
                proof.caller,
                abi.encode(proof.namespace),
                abi.encode(proof, _sign(OTHER_PK, proof))
            )
        );
        assert(!ok);
    }

    function testRejectsRemovedSigner() public {
        address signer = vm.addr(SIGNER_PK);
        registry.setSigner(signer, false);

        SignedAccessConditionV1.AccessProof memory proof = _proof(
            address(0xBEEF),
            condition.SCOPE_ASSET_OWNER(),
            2_000,
            keccak256("namespace-1"),
            keccak256("purchase-1")
        );

        (bool ok,) = address(condition).call(
            abi.encodeWithSelector(
                CHECK_READ_SELECTOR,
                proof.caller,
                abi.encode(proof.namespace),
                abi.encode(proof, _sign(SIGNER_PK, proof))
            )
        );
        assert(!ok);
    }

    function testWriteConditionMatchesPublisherOperator() public view {
        bytes memory conditionData = abi.encode(address(0xABCD));
        assert(condition.checkWriteCondition(address(0xABCD), conditionData, "0x"));
        assert(!condition.checkWriteCondition(address(0xDCBA), conditionData, "0x"));
    }

    function _proof(address caller, bytes32 scope, uint64 expiry, bytes32 namespace, bytes32 accessRef)
        internal
        pure
        returns (SignedAccessConditionV1.AccessProof memory)
    {
        return SignedAccessConditionV1.AccessProof({
            vaultUuid: VAULT_UUID,
            caller: caller,
            accessRef: accessRef,
            scope: scope,
            expiry: expiry,
            namespace: namespace
        });
    }

    function _sign(uint256 privateKey, SignedAccessConditionV1.AccessProof memory proof) internal returns (bytes memory) {
        bytes32 digest = condition.hashProof(proof);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }
}
