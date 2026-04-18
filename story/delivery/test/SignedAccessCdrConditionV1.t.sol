// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {PirateSignerRegistry} from "../src/PirateSignerRegistry.sol";
import {SignedAccessCdrConditionV1} from "../src/SignedAccessCdrConditionV1.sol";

interface Vm {
    function addr(uint256 privateKey) external returns (address);
    function sign(uint256 privateKey, bytes32 digest) external returns (uint8 v, bytes32 r, bytes32 s);
    function warp(uint256 newTimestamp) external;
}

address constant VM_ADDRESS = address(uint160(uint256(keccak256("hevm cheat code"))));
Vm constant vm = Vm(VM_ADDRESS);

contract SignedAccessCdrConditionV1Test {
    bytes4 internal constant CHECK_READ_SELECTOR =
        bytes4(keccak256("checkReadCondition(address,bytes,bytes)"));

    PirateSignerRegistry internal registry;
    SignedAccessCdrConditionV1 internal condition;

    uint256 internal constant SIGNER_PK = 0xA11CE;
    uint256 internal constant OTHER_PK = 0xB0B;
    uint32 internal constant VAULT_UUID = 23;
    address internal constant WRITER = address(0xFACE);

    function setUp() public {
        registry = new PirateSignerRegistry();
        condition = new SignedAccessCdrConditionV1(address(registry));
        registry.setSigner(vm.addr(SIGNER_PK), true);
        vm.warp(1_000);
    }

    function testAllocateProbeAllowsWriterWithoutProof() public view {
        bool allowed = condition.checkReadCondition(
            WRITER,
            abi.encode(keccak256("namespace-1"), WRITER),
            hex""
        );
        assert(allowed);
    }

    function testAllocateProbeRejectsNonWriterWithoutProof() public view {
        bool allowed = condition.checkReadCondition(
            address(0xBEEF),
            abi.encode(keccak256("namespace-1"), WRITER),
            hex""
        );
        assert(!allowed);
    }

    function testValidProofPassesForOwnerScope() public {
        SignedAccessCdrConditionV1.AccessProof memory proof = _proof(
            address(0xBEEF),
            condition.SCOPE_ASSET_OWNER(),
            2_000,
            keccak256("namespace-1"),
            keccak256("purchase-1")
        );

        bytes memory accessAuxData = abi.encode(proof, _sign(SIGNER_PK, proof));
        bool allowed = condition.checkReadCondition(
            proof.caller,
            abi.encode(proof.namespace, WRITER),
            accessAuxData
        );

        assert(allowed);
    }

    function testRejectsNamespaceMismatch() public {
        SignedAccessCdrConditionV1.AccessProof memory proof = _proof(
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
                abi.encode(keccak256("other-namespace"), WRITER),
                abi.encode(proof, _sign(SIGNER_PK, proof))
            )
        );
        assert(!ok);
    }

    function testWriteConditionMatchesWriter() public view {
        bytes memory conditionData = abi.encode(WRITER);
        assert(condition.checkWriteCondition(WRITER, conditionData, "0x"));
        assert(!condition.checkWriteCondition(address(0xDCBA), conditionData, "0x"));
    }

    function _proof(address caller, bytes32 scope, uint64 expiry, bytes32 namespace, bytes32 accessRef)
        internal
        pure
        returns (SignedAccessCdrConditionV1.AccessProof memory)
    {
        return SignedAccessCdrConditionV1.AccessProof({
            vaultUuid: VAULT_UUID,
            caller: caller,
            accessRef: accessRef,
            scope: scope,
            expiry: expiry,
            namespace: namespace
        });
    }

    function _sign(uint256 privateKey, SignedAccessCdrConditionV1.AccessProof memory proof)
        internal
        returns (bytes memory)
    {
        bytes32 digest = condition.hashProof(proof);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }
}
