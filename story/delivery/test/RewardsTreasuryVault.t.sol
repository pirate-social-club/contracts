// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {RewardsTreasuryVault} from "../src/RewardsTreasuryVault.sol";

interface Vm {
    struct Log {
        bytes32[] topics;
        bytes data;
        address emitter;
    }

    function expectRevert(bytes4) external;
    function warp(uint256) external;
    function expectEmit(bool, bool, bool, bool, address) external;
    function recordLogs() external;
    function getRecordedLogs() external returns (Log[] memory);
}

contract MockUsdc {
    mapping(address => uint256) public balanceOf;
    bool public returnFalse;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function setReturnFalse(bool value) external {
        returnFalse = value;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (returnFalse) return false;
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract VaultActor {
    function pay(
        RewardsTreasuryVault vault,
        bytes32 operationId,
        address recipient,
        uint256 amount,
        uint64 deadline,
        uint64 policyVersion
    ) external {
        vault.pay(operationId, recipient, amount, deadline, policyVersion);
    }

    function refund(
        RewardsTreasuryVault vault,
        bytes32 operationId,
        address recipient,
        uint256 amount,
        uint64 deadline,
        uint64 policyVersion
    ) external {
        vault.refund(operationId, recipient, amount, deadline, policyVersion);
    }

    function acceptOwnership(RewardsTreasuryVault vault) external {
        vault.acceptOwnership();
    }
}

contract RewardsTreasuryVaultTest {
    event OperationCapacityDeferred(
        bytes32 indexed operationId,
        RewardsTreasuryVault.OperationKind indexed kind,
        uint256 indexed epoch
    );

    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint64 private constant EPOCH_DURATION = 1 days;
    uint64 private constant POLICY_VERSION = 1;
    uint256 private constant MAX_PAYOUT = 100e6;
    uint256 private constant PAYOUT_CAP = 250e6;
    uint256 private constant MAX_REFUND = 200e6;
    uint256 private constant REFUND_CAP = 400e6;

    MockUsdc private usdc;
    RewardsTreasuryVault private vault;
    VaultActor private operator;
    VaultActor private nextOperator;
    VaultActor private recipient;
    VaultActor private stranger;

    function setUp() public {
        usdc = new MockUsdc();
        operator = new VaultActor();
        nextOperator = new VaultActor();
        recipient = new VaultActor();
        stranger = new VaultActor();
        vault = new RewardsTreasuryVault(
            address(usdc),
            address(this),
            address(operator),
            EPOCH_DURATION,
            POLICY_VERSION,
            MAX_PAYOUT,
            PAYOUT_CAP,
            MAX_REFUND,
            REFUND_CAP
        );
        usdc.mint(address(vault), 1_000e6);
    }

    function testStartsFullyPausedAndPaysOnlyAfterOwnerUnpauses() public {
        bytes32 operationId = keccak256("reward-effect-1");
        assert(!_callPay(operator, operationId, 10e6, _deadline(), POLICY_VERSION));

        vault.setPauseState(false, true);
        operator.pay(vault, operationId, address(recipient), 10e6, _deadline(), POLICY_VERSION);

        assert(usdc.balanceOf(address(recipient)) == 10e6);
        assert(vault.usedOperations(operationId));
    }

    function testRejectsUnauthorizedOperatorAndRotatesWithoutMovingFunds() public {
        vault.setPauseState(false, false);
        assert(!_callPay(stranger, keccak256("unauthorized"), 10e6, _deadline(), POLICY_VERSION));

        uint256 balanceBefore = usdc.balanceOf(address(vault));
        vault.setSettlementOperator(address(nextOperator));

        assert(!_callPay(operator, keccak256("old-operator"), 10e6, _deadline(), POLICY_VERSION));
        nextOperator.pay(
            vault, keccak256("new-operator"), address(recipient), 10e6, _deadline(), POLICY_VERSION
        );
        assert(usdc.balanceOf(address(vault)) == balanceBefore - 10e6);
    }

    function testOperationIdCannotReplayAcrossPayoutAndRefund() public {
        vault.setPauseState(false, false);
        bytes32 operationId = keccak256("shared-effect-id");
        operator.pay(vault, operationId, address(recipient), 10e6, _deadline(), POLICY_VERSION);
        assert(!_callRefund(operator, operationId, 10e6, _deadline(), POLICY_VERSION));
    }

    function testPayoutAndRefundHaveIndependentEpochCaps() public {
        vault.setPauseState(false, false);
        operator.pay(
            vault, keccak256("payout-1"), address(recipient), 100e6, _deadline(), POLICY_VERSION
        );
        operator.pay(
            vault, keccak256("payout-2"), address(recipient), 100e6, _deadline(), POLICY_VERSION
        );
        // Capacity exhaustion is now a successful no-op, not a revert.
        uint256 balanceBefore = usdc.balanceOf(address(recipient));
        assert(_callPay(operator, keccak256("payout-3"), 100e6, _deadline(), POLICY_VERSION));
        assert(usdc.balanceOf(address(recipient)) == balanceBefore);

        operator.refund(
            vault, keccak256("refund-1"), address(recipient), 200e6, _deadline(), POLICY_VERSION
        );
        operator.refund(
            vault, keccak256("refund-2"), address(recipient), 200e6, _deadline(), POLICY_VERSION
        );
    }

    function testNewEpochRestoresCapacity() public {
        vault.setPauseState(false, true);
        operator.pay(
            vault, keccak256("epoch-a-1"), address(recipient), 100e6, _deadline(), POLICY_VERSION
        );
        operator.pay(
            vault, keccak256("epoch-a-2"), address(recipient), 100e6, _deadline(), POLICY_VERSION
        );
        vm.warp(block.timestamp + EPOCH_DURATION);
        operator.pay(
            vault, keccak256("epoch-b-1"), address(recipient), 100e6, _deadline(), POLICY_VERSION
        );
    }

    function testRejectsTransferLimitExpiredDeadlineAndStalePolicy() public {
        vault.setPauseState(false, true);
        assert(
            !_callPay(
                operator, keccak256("over-limit"), MAX_PAYOUT + 1, _deadline(), POLICY_VERSION
            )
        );
        assert(
            !_callPay(
                operator, keccak256("expired"), 1e6, uint64(block.timestamp - 1), POLICY_VERSION
            )
        );
        assert(!_callPay(operator, keccak256("stale"), 1e6, _deadline(), POLICY_VERSION + 1));
    }

    function testPolicyVersionMustIncreaseAndInvalidatesQueuedTransactions() public {
        vault.setPolicy(2, MAX_PAYOUT, PAYOUT_CAP, MAX_REFUND, REFUND_CAP);
        vault.setPauseState(false, true);
        assert(!_callPay(operator, keccak256("old-policy"), 1e6, _deadline(), POLICY_VERSION));
        operator.pay(vault, keccak256("new-policy"), address(recipient), 1e6, _deadline(), 2);

        (bool staleUpdateOk,) = address(vault)
            .call(
                abi.encodeCall(
                    RewardsTreasuryVault.setPolicy,
                    (uint64(2), MAX_PAYOUT, PAYOUT_CAP, MAX_REFUND, REFUND_CAP)
                )
            );
        assert(!staleUpdateOk);
    }

    function testRefundsCanContinueWhilePayoutsArePaused() public {
        vault.setPauseState(true, false);
        assert(!_callPay(operator, keccak256("paused-payout"), 1e6, _deadline(), POLICY_VERSION));
        operator.refund(
            vault, keccak256("live-refund"), address(recipient), 1e6, _deadline(), POLICY_VERSION
        );
    }

    function testEmergencyWithdrawalRequiresFullPause() public {
        vault.setPauseState(true, false);
        (bool unpausedOk,) = address(vault)
            .call(
                abi.encodeCall(RewardsTreasuryVault.emergencyWithdraw, (address(recipient), 10e6))
            );
        assert(!unpausedOk);

        vault.setPauseState(true, true);
        vault.emergencyWithdraw(address(recipient), 10e6);
        assert(usdc.balanceOf(address(recipient)) == 10e6);
    }

    function testUsdcCannotBeRecoveredThroughForeignTokenPath() public {
        vm.expectRevert(RewardsTreasuryVault.CannotRecoverUsdcAsForeignToken.selector);
        vault.recoverForeignToken(address(usdc), address(recipient), 10e6);
    }

    function testTokenTransferFailureRollsBackOperationAndCapUsage() public {
        vault.setPauseState(false, true);
        bytes32 operationId = keccak256("failed-transfer");
        uint256 epoch = vault.currentEpoch();
        usdc.setReturnFalse(true);

        assert(!_callPay(operator, operationId, 10e6, _deadline(), POLICY_VERSION));
        assert(!vault.usedOperations(operationId));
        assert(vault.payoutSpentByEpoch(epoch) == 0);
    }

    function testOwnershipTransferRequiresPendingOwnerAcceptance() public {
        vault.beginOwnershipTransfer(address(stranger));
        assert(!_callAcceptOwnership(nextOperator));
        stranger.acceptOwnership(vault);
        assert(vault.owner() == address(stranger));
        assert(vault.pendingOwner() == address(0));
    }

    function _deadline() private view returns (uint64) {
        return uint64(block.timestamp + 1 hours);
    }

    function _callPay(
        VaultActor actor,
        bytes32 operationId,
        uint256 amount,
        uint64 deadline,
        uint64 version
    ) private returns (bool ok) {
        (ok,) = address(actor)
            .call(
                abi.encodeCall(
                    VaultActor.pay,
                    (vault, operationId, address(recipient), amount, deadline, version)
                )
            );
    }

    function _callRefund(
        VaultActor actor,
        bytes32 operationId,
        uint256 amount,
        uint64 deadline,
        uint64 version
    ) private returns (bool ok) {
        (ok,) = address(actor)
            .call(
                abi.encodeCall(
                    VaultActor.refund,
                    (vault, operationId, address(recipient), amount, deadline, version)
                )
            );
    }

    function _callAcceptOwnership(VaultActor actor) private returns (bool ok) {
        (ok,) = address(actor).call(abi.encodeCall(VaultActor.acceptOwnership, (vault)));
    }

    /// The pay/refund signatures must not change: the Lit action's pinned
    /// source embeds this calldata shape, so a selector change would silently
    /// invalidate the registered action CID.
    function testPayAndRefundSelectorsAreStable() public pure {
        assert(RewardsTreasuryVault.pay.selector == bytes4(0x82cb3a1e));
        assert(RewardsTreasuryVault.refund.selector == bytes4(0xfc1af099));
    }

    function testCapacityDeferralMovesNoFundsAndConsumesNothing() public {
        vault.setPauseState(false, true);
        operator.pay(
            vault, keccak256("cap-1"), address(recipient), 100e6, _deadline(), POLICY_VERSION
        );
        operator.pay(
            vault, keccak256("cap-2"), address(recipient), 100e6, _deadline(), POLICY_VERSION
        );

        uint256 epoch = vault.currentEpoch();
        uint256 spentBefore = vault.payoutSpentByEpoch(epoch);
        uint256 balanceBefore = usdc.balanceOf(address(recipient));
        bytes32 deferred = keccak256("cap-deferred");

        assert(_callPay(operator, deferred, 100e6, _deadline(), POLICY_VERSION));

        assert(usdc.balanceOf(address(recipient)) == balanceBefore);
        assert(vault.payoutSpentByEpoch(epoch) == spentBefore);
        // The operation id stays unconsumed so the identical operation retries.
        assert(!vault.usedOperations(deferred));
    }

    function testDeferredOperationSucceedsUnchangedNextEpoch() public {
        vault.setPauseState(false, true);
        operator.pay(
            vault, keccak256("roll-1"), address(recipient), 100e6, _deadline(), POLICY_VERSION
        );
        operator.pay(
            vault, keccak256("roll-2"), address(recipient), 100e6, _deadline(), POLICY_VERSION
        );

        bytes32 deferred = keccak256("roll-deferred");
        assert(_callPay(operator, deferred, 100e6, _deadline(), POLICY_VERSION));
        assert(!vault.usedOperations(deferred));

        vm.warp(block.timestamp + EPOCH_DURATION);

        uint256 balanceBefore = usdc.balanceOf(address(recipient));
        // Operation id, recipient, amount and policy version are unchanged.
        // Only the deadline is regenerated, as it is minted per signing attempt.
        operator.pay(vault, deferred, address(recipient), 100e6, _deadline(), POLICY_VERSION);
        assert(usdc.balanceOf(address(recipient)) == balanceBefore + 100e6);
        assert(vault.usedOperations(deferred));
    }

    function testPermanentFailuresStillRevertWhenCapacityIsAlsoExhausted() public {
        vault.setPauseState(false, true);
        operator.pay(
            vault, keccak256("perm-1"), address(recipient), 100e6, _deadline(), POLICY_VERSION
        );
        operator.pay(
            vault, keccak256("perm-2"), address(recipient), 100e6, _deadline(), POLICY_VERSION
        );

        // Capacity is exhausted. Each of these must STILL revert rather than
        // being silently deferred, or a permanent fault would retry forever.
        assert(!_callPay(operator, keccak256("perm-3"), 100e6, _deadline(), POLICY_VERSION + 1));
        assert(!_callPay(operator, keccak256("perm-4"), 100e6, uint64(block.timestamp - 1), POLICY_VERSION));
        assert(!_callPay(operator, keccak256("perm-1"), 100e6, _deadline(), POLICY_VERSION));
        assert(!_callPay(operator, keccak256("perm-5"), 1_000_000e6, _deadline(), POLICY_VERSION));
        assert(!_callPay(operator, bytes32(0), 100e6, _deadline(), POLICY_VERSION));
        assert(!_callPay(operator, keccak256("perm-6"), 0, _deadline(), POLICY_VERSION));
    }

    function testPausedVaultRevertsEvenWithCapacityExhausted() public {
        vault.setPauseState(false, true);
        operator.pay(
            vault, keccak256("pause-1"), address(recipient), 100e6, _deadline(), POLICY_VERSION
        );
        operator.pay(
            vault, keccak256("pause-2"), address(recipient), 100e6, _deadline(), POLICY_VERSION
        );
        vault.setPauseState(true, true);
        // A pause must remain visible, never collapse into a deferral.
        assert(!_callPay(operator, keccak256("pause-3"), 100e6, _deadline(), POLICY_VERSION));
    }

    function testRefundCapacityDefersIndependentlyOfPayouts() public {
        vault.setPauseState(false, false);
        operator.refund(
            vault, keccak256("rcap-1"), address(recipient), 200e6, _deadline(), POLICY_VERSION
        );
        operator.refund(
            vault, keccak256("rcap-2"), address(recipient), 200e6, _deadline(), POLICY_VERSION
        );

        bytes32 deferred = keccak256("rcap-deferred");
        uint256 balanceBefore = usdc.balanceOf(address(recipient));
        assert(_callRefund(operator, deferred, 200e6, _deadline(), POLICY_VERSION));
        assert(usdc.balanceOf(address(recipient)) == balanceBefore);
        assert(!vault.usedOperations(deferred));

        // Payout capacity is untouched by refund deferral.
        operator.pay(
            vault, keccak256("rcap-payout"), address(recipient), 100e6, _deadline(), POLICY_VERSION
        );
    }

    function testPayoutDeferralEmitsTheExactEventTheApiParses() public {
        vault.setPauseState(false, true);
        operator.pay(
            vault, keccak256("evt-1"), address(recipient), 100e6, _deadline(), POLICY_VERSION
        );
        operator.pay(
            vault, keccak256("evt-2"), address(recipient), 100e6, _deadline(), POLICY_VERSION
        );

        bytes32 deferred = keccak256("evt-deferred");
        uint256 epoch = vault.currentEpoch();

        vm.expectEmit(true, true, true, true, address(vault));
        emit OperationCapacityDeferred(deferred, RewardsTreasuryVault.OperationKind.Payout, epoch);
        operator.pay(vault, deferred, address(recipient), 100e6, _deadline(), POLICY_VERSION);
    }

    function testRefundDeferralEmitsTheExactEventTheApiParses() public {
        vault.setPauseState(true, false);
        operator.refund(
            vault, keccak256("revt-1"), address(recipient), 200e6, _deadline(), POLICY_VERSION
        );
        operator.refund(
            vault, keccak256("revt-2"), address(recipient), 200e6, _deadline(), POLICY_VERSION
        );

        bytes32 deferred = keccak256("revt-deferred");
        uint256 epoch = vault.currentEpoch();

        vm.expectEmit(true, true, true, true, address(vault));
        emit OperationCapacityDeferred(deferred, RewardsTreasuryVault.OperationKind.Refund, epoch);
        operator.refund(vault, deferred, address(recipient), 200e6, _deadline(), POLICY_VERSION);
    }

    function testRepeatedSameEpochDeferralStaysUnconsumedAndConsistent() public {
        vault.setPauseState(false, true);
        operator.pay(
            vault, keccak256("rep-1"), address(recipient), 100e6, _deadline(), POLICY_VERSION
        );
        operator.pay(
            vault, keccak256("rep-2"), address(recipient), 100e6, _deadline(), POLICY_VERSION
        );

        bytes32 deferred = keccak256("rep-deferred");
        uint256 epoch = vault.currentEpoch();
        uint256 balanceBefore = usdc.balanceOf(address(recipient));
        uint256 spentBefore = vault.payoutSpentByEpoch(epoch);

        for (uint256 i = 0; i < 3; i++) {
            vm.expectEmit(true, true, true, true, address(vault));
            emit OperationCapacityDeferred(
                deferred, RewardsTreasuryVault.OperationKind.Payout, epoch
            );
            operator.pay(vault, deferred, address(recipient), 100e6, _deadline(), POLICY_VERSION);
            // Retrying inside the same epoch never consumes the id, never moves
            // funds, and never charges capacity.
            assert(!vault.usedOperations(deferred));
            assert(usdc.balanceOf(address(recipient)) == balanceBefore);
            assert(vault.payoutSpentByEpoch(epoch) == spentBefore);
        }
    }
}

/// Standalone so the Vm.Log[] decode compiles: doing it inside the main suite
/// exceeds the legacy pipeline's stack, and enabling via_ir would change the
/// compiled bytecode of a contract awaiting independent review.
contract VaultDeferralLogShapeTest {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    MockUsdc private usdc;
    RewardsTreasuryVault private vault;
    VaultActor private operator;
    VaultActor private recipient;

    function setUp() public {
        usdc = new MockUsdc();
        operator = new VaultActor();
        recipient = new VaultActor();
        vault = new RewardsTreasuryVault(
            address(usdc), address(this), address(operator), 1 days, 1, 100e6, 200e6, 100e6, 200e6
        );
        usdc.mint(address(vault), 1_000e6);
        vault.setPauseState(false, false);
    }

    function testDeferralLogShapeAndAbsenceOfSettlementEvents() public {
        uint64 deadline = uint64(block.timestamp + 1 hours);
        operator.pay(vault, keccak256("a"), address(recipient), 100e6, deadline, 1);
        operator.pay(vault, keccak256("b"), address(recipient), 100e6, deadline, 1);

        vm.recordLogs();
        operator.pay(vault, keccak256("deferred"), address(recipient), 100e6, deadline, 1);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assert(logs.length == 1);
        assert(logs[0].emitter == address(vault));
        assert(logs[0].topics.length == 4);
        assert(logs[0].topics[0] == keccak256("OperationCapacityDeferred(bytes32,uint8,uint256)"));
        assert(logs[0].topics[1] == keccak256("deferred"));
        assert(uint256(logs[0].topics[2]) == 0);
        assert(uint256(logs[0].topics[3]) == vault.currentEpoch());
    }

    function testRefundDeferralLogShape() public {
        uint64 deadline = uint64(block.timestamp + 1 hours);
        operator.refund(vault, keccak256("ra"), address(recipient), 100e6, deadline, 1);
        operator.refund(vault, keccak256("rb"), address(recipient), 100e6, deadline, 1);

        vm.recordLogs();
        operator.refund(vault, keccak256("rdeferred"), address(recipient), 100e6, deadline, 1);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assert(logs.length == 1);
        assert(logs[0].emitter == address(vault));
        assert(uint256(logs[0].topics[2]) == 1);
    }

    function testSettlementStillEmitsItsOwnEventWithCapacityAvailable() public {
        vm.recordLogs();
        operator.pay(
            vault, keccak256("paid"), address(recipient), 100e6, uint64(block.timestamp + 1 hours), 1
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // A settled payout emits RewardPaid and never the deferral event.
        assert(logs.length == 1);
        assert(
            logs[0].topics[0] == keccak256("RewardPaid(bytes32,address,uint256,uint64,uint256)")
        );
        assert(
            logs[0].topics[0] != keccak256("OperationCapacityDeferred(bytes32,uint8,uint256)")
        );
    }
}

/// Standalone: these deploy their own vaults with deliberately bad arguments.
contract RewardsTreasuryVaultConstructorGuardTest {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function _deploy(address token) private returns (RewardsTreasuryVault) {
        return new RewardsTreasuryVault(token, address(this), address(this), 1 days, 1, 1, 1, 1, 1);
    }

    function testRejectsATokenAddressWithNoCode() public {
        // A low-level call to a codeless address returns success with empty
        // returndata, so _safeTransfer would accept it: every payout would emit
        // RewardPaid having moved nothing, and settlement classification would
        // durably confirm payments that never happened.
        //
        // Asserting the SELECTOR, not merely that something reverted: a test
        // that only checks "it failed" cannot tell this guard from the
        // pre-existing zero-address check.
        vm.expectRevert(RewardsTreasuryVault.TokenNotAContract.selector);
        _deploy(address(0xdead));
    }

    function testRejectsAnEoaStyleAddressThatMerelyLooksValid() public {
        vm.expectRevert(RewardsTreasuryVault.TokenNotAContract.selector);
        _deploy(0x1111111111111111111111111111111111111111);
    }

    function testStillReportsZeroAddressForTheZeroToken() public {
        // The two guards must stay distinguishable: zero is a different
        // operator error from "non-zero but not a contract".
        vm.expectRevert(RewardsTreasuryVault.ZeroAddress.selector);
        _deploy(address(0));
    }

    function testAcceptsARealTokenContract() public {
        MockUsdc token = new MockUsdc();
        RewardsTreasuryVault vault = _deploy(address(token));
        assert(address(vault.usdc()) == address(token));
    }
}
