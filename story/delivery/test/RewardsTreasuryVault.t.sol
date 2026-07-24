// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {RewardsTreasuryVault} from "../src/RewardsTreasuryVault.sol";

interface Vm {
    function warp(uint256) external;
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
        assert(!_callPay(operator, keccak256("payout-3"), 100e6, _deadline(), POLICY_VERSION));

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
        (bool ok,) = address(vault)
            .call(
                abi.encodeCall(
                    RewardsTreasuryVault.recoverForeignToken,
                    (address(usdc), address(recipient), 10e6)
                )
            );
        assert(!ok);
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
}
