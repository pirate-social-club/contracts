// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {PirateSignerRegistry} from "../src/PirateSignerRegistry.sol";

contract RegistryActor {
    function setSigner(PirateSignerRegistry registry, address signer, bool active) external {
        registry.setSigner(signer, active);
    }

    function transferOwnership(PirateSignerRegistry registry, address newOwner) external {
        registry.transferOwnership(newOwner);
    }
}

contract PirateSignerRegistryTest {
    PirateSignerRegistry internal registry;
    RegistryActor internal ownerActor;
    RegistryActor internal stranger;

    function setUp() public {
        registry = new PirateSignerRegistry();
        ownerActor = new RegistryActor();
        stranger = new RegistryActor();
    }

    function testOwnerCanAddAndRemoveSigner() public {
        registry.setSigner(address(ownerActor), true);
        assert(registry.isActiveSigner(address(ownerActor)));

        registry.setSigner(address(ownerActor), false);
        assert(!registry.isActiveSigner(address(ownerActor)));
    }

    function testRejectsUnauthorizedSignerUpdate() public {
        (bool ok,) = address(stranger).call(
            abi.encodeWithSelector(
                RegistryActor.setSigner.selector, registry, address(stranger), true
            )
        );
        assert(!ok);
    }

    function testOwnershipTransferControlsSignerUpdates() public {
        RegistryActor newOwner = new RegistryActor();
        registry.transferOwnership(address(newOwner));

        (bool oldOwnerOk,) = address(this).call(
            abi.encodeWithSelector(PirateSignerRegistry.setSigner.selector, address(stranger), true)
        );
        assert(!oldOwnerOk);

        (bool newOwnerOk,) = address(newOwner).call(
            abi.encodeWithSelector(
                RegistryActor.setSigner.selector, registry, address(stranger), true
            )
        );
        assert(newOwnerOk);
        assert(registry.isActiveSigner(address(stranger)));
    }
}
