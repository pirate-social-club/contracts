// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {ScrobbleV1} from "../src/ScrobbleV1.sol";

contract ScrobbleActor {
    function setOperator(ScrobbleV1 scrobble, address operator, bool active) external {
        scrobble.setOperator(operator, active);
    }

    function registerTrack(ScrobbleV1 scrobble, bytes32 trackId, bytes32 metadataHash) external {
        scrobble.registerTrack(trackId, metadataHash);
    }

    function scrobbleOne(
        ScrobbleV1 scrobble,
        address user,
        bytes32 trackId,
        bytes32 clubId,
        uint64 playbackStartedAt,
        uint32 creditedDurationMs,
        uint8 sourceType,
        uint8 submissionMode
    ) external {
        scrobble.scrobble(
            user, trackId, clubId, playbackStartedAt, creditedDurationMs, sourceType, submissionMode
        );
    }

    function scrobbleBatch(
        ScrobbleV1 scrobble,
        address user,
        bytes32[] calldata trackIds,
        bytes32[] calldata clubIds,
        uint64[] calldata playbackStartedAts,
        uint32[] calldata creditedDurationsMs,
        uint8[] calldata sourceTypes,
        uint8[] calldata submissionModes
    ) external {
        scrobble.scrobbleBatch(
            user, trackIds, clubIds, playbackStartedAts, creditedDurationsMs, sourceTypes, submissionModes
        );
    }
}

contract ScrobbleV1Test {
    ScrobbleV1 internal scrobble;
    ScrobbleActor internal operator;
    ScrobbleActor internal user;
    ScrobbleActor internal stranger;

    bytes32 internal constant TRACK_ID = keccak256("track");
    bytes32 internal constant META_HASH = keccak256("meta");
    bytes32 internal constant CLUB_ID = keccak256("club");

    function setUp() public {
        scrobble = new ScrobbleV1();
        operator = new ScrobbleActor();
        user = new ScrobbleActor();
        stranger = new ScrobbleActor();

        scrobble.setOperator(address(operator), true);
    }

    function testOwnerCanSetOperator() public view {
        assert(scrobble.isOperator(address(operator)));
    }

    function testOperatorCanRegisterTrack() public {
        operator.registerTrack(scrobble, TRACK_ID, META_HASH);

        (bytes32 metadataHash, uint64 registeredAt, bool exists) = scrobble.tracks(TRACK_ID);
        assert(metadataHash == META_HASH);
        assert(registeredAt != 0);
        assert(exists);
    }

    function testRegisteredUserCanScrobbleDirectly() public {
        operator.registerTrack(scrobble, TRACK_ID, META_HASH);

        user.scrobbleOne(
            scrobble,
            address(user),
            TRACK_ID,
            CLUB_ID,
            1,
            30_000,
            scrobble.SOURCE_WEB(),
            scrobble.MODE_DIRECT()
        );
    }

    function testOperatorCanScrobbleForUser() public {
        operator.registerTrack(scrobble, TRACK_ID, META_HASH);

        operator.scrobbleOne(
            scrobble,
            address(user),
            TRACK_ID,
            bytes32(0),
            2,
            45_000,
            scrobble.SOURCE_OPERATOR(),
            scrobble.MODE_DELEGATED()
        );
    }

    function testScrobbleBatchWorks() public {
        bytes32[] memory trackIds = new bytes32[](2);
        bytes32[] memory clubIds = new bytes32[](2);
        uint64[] memory started = new uint64[](2);
        uint32[] memory durations = new uint32[](2);
        uint8[] memory sources = new uint8[](2);
        uint8[] memory modes = new uint8[](2);

        trackIds[0] = TRACK_ID;
        trackIds[1] = keccak256("track-2");
        clubIds[0] = CLUB_ID;
        clubIds[1] = bytes32(0);
        started[0] = 10;
        started[1] = 20;
        durations[0] = 30_000;
        durations[1] = 60_000;
        sources[0] = scrobble.SOURCE_WEB();
        sources[1] = scrobble.SOURCE_DESKTOP();
        modes[0] = scrobble.MODE_DIRECT();
        modes[1] = scrobble.MODE_DELEGATED();

        operator.registerTrack(scrobble, trackIds[0], META_HASH);
        operator.registerTrack(scrobble, trackIds[1], keccak256("meta-2"));

        operator.scrobbleBatch(
            scrobble, address(user), trackIds, clubIds, started, durations, sources, modes
        );
    }

    function testRejectsUnregisteredTrack() public {
        (bool ok,) = address(user).call(
            abi.encodeWithSelector(
                ScrobbleActor.scrobbleOne.selector,
                scrobble,
                address(user),
                TRACK_ID,
                CLUB_ID,
                1,
                30_000,
                scrobble.SOURCE_WEB(),
                scrobble.MODE_DIRECT()
            )
        );

        assert(!ok);
    }

    function testRejectsUnauthorizedRegistration() public {
        (bool ok,) = address(stranger).call(
            abi.encodeWithSelector(ScrobbleActor.registerTrack.selector, scrobble, TRACK_ID, META_HASH)
        );

        assert(!ok);
    }

    function testRejectsUnauthorizedScrobble() public {
        operator.registerTrack(scrobble, TRACK_ID, META_HASH);

        (bool ok,) = address(stranger).call(
            abi.encodeWithSelector(
                ScrobbleActor.scrobbleOne.selector,
                scrobble,
                address(user),
                TRACK_ID,
                CLUB_ID,
                1,
                30_000,
                scrobble.SOURCE_WEB(),
                scrobble.MODE_DIRECT()
            )
        );

        assert(!ok);
    }

    function testRejectsInvalidEnums() public {
        operator.registerTrack(scrobble, TRACK_ID, META_HASH);

        (bool okSource,) = address(user).call(
            abi.encodeWithSelector(
                ScrobbleActor.scrobbleOne.selector,
                scrobble,
                address(user),
                TRACK_ID,
                CLUB_ID,
                1,
                30_000,
                99,
                scrobble.MODE_DIRECT()
            )
        );
        assert(!okSource);

        (bool okMode,) = address(user).call(
            abi.encodeWithSelector(
                ScrobbleActor.scrobbleOne.selector,
                scrobble,
                address(user),
                TRACK_ID,
                CLUB_ID,
                1,
                30_000,
                scrobble.SOURCE_WEB(),
                99
            )
        );
        assert(!okMode);
    }

    function testRejectsDuplicateTrackRegistration() public {
        operator.registerTrack(scrobble, TRACK_ID, META_HASH);

        (bool ok,) = address(operator).call(
            abi.encodeWithSelector(ScrobbleActor.registerTrack.selector, scrobble, TRACK_ID, META_HASH)
        );

        assert(!ok);
    }

    function testRejectsZeroTrackIdRegistration() public {
        (bool ok,) = address(operator).call(
            abi.encodeWithSelector(ScrobbleActor.registerTrack.selector, scrobble, bytes32(0), META_HASH)
        );

        assert(!ok);
    }

    function testRejectsZeroMetadataHashRegistration() public {
        (bool ok,) = address(operator).call(
            abi.encodeWithSelector(ScrobbleActor.registerTrack.selector, scrobble, TRACK_ID, bytes32(0))
        );

        assert(!ok);
    }

    function testRejectsZeroTimestampScrobble() public {
        operator.registerTrack(scrobble, TRACK_ID, META_HASH);

        (bool ok,) = address(user).call(
            abi.encodeWithSelector(
                ScrobbleActor.scrobbleOne.selector,
                scrobble,
                address(user),
                TRACK_ID,
                CLUB_ID,
                0,
                30_000,
                scrobble.SOURCE_WEB(),
                scrobble.MODE_DIRECT()
            )
        );

        assert(!ok);
    }

    function testOwnerTransferControlsOperatorManagement() public {
        ScrobbleActor newOwner = new ScrobbleActor();
        scrobble.transferOwnership(address(newOwner));

        (bool oldOwnerCanSet,) = address(this).call(
            abi.encodeWithSelector(ScrobbleV1.setOperator.selector, address(stranger), true)
        );
        assert(!oldOwnerCanSet);

        (bool newOwnerCanSet,) = address(newOwner).call(
            abi.encodeWithSelector(ScrobbleActor.setOperator.selector, scrobble, address(stranger), true)
        );
        assert(newOwnerCanSet);
        assert(scrobble.isOperator(address(stranger)));
    }

    function testRevokedOperatorCannotRegisterOrScrobble() public {
        scrobble.setOperator(address(operator), false);

        (bool registerOk,) = address(operator).call(
            abi.encodeWithSelector(ScrobbleActor.registerTrack.selector, scrobble, TRACK_ID, META_HASH)
        );
        assert(!registerOk);

        scrobble.setOperator(address(operator), true);
        operator.registerTrack(scrobble, TRACK_ID, META_HASH);
        scrobble.setOperator(address(operator), false);

        (bool scrobbleOk,) = address(operator).call(
            abi.encodeWithSelector(
                ScrobbleActor.scrobbleOne.selector,
                scrobble,
                address(user),
                TRACK_ID,
                CLUB_ID,
                1,
                30_000,
                scrobble.SOURCE_OPERATOR(),
                scrobble.MODE_DELEGATED()
            )
        );
        assert(!scrobbleOk);
    }
}
