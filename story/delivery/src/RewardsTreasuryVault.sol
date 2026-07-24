// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

interface IERC20Minimal {
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @notice Bounded USDC custody for automated Pirate reward payouts and refunds.
/// @dev The owner is expected to be a Safe. The operator is expected to be the
///      Lit-controlled signer. This contract is deliberately non-upgradeable.
contract RewardsTreasuryVault {
    error Unauthorized();
    error ZeroAddress();
    error ZeroAmount();
    error InvalidPolicy();
    error StalePolicy();
    error DeadlineExpired();
    error OperationAlreadyUsed();
    error TransferLimitExceeded();
    error EpochLimitExceeded();
    error PayoutsPaused();
    error RefundsPaused();
    error VaultMustBeFullyPaused();
    error CannotRecoverUsdcAsForeignToken();
    error OwnershipTransferNotPending();
    error TokenTransferFailed();
    error Reentrancy();

    event OwnershipTransferStarted(address indexed currentOwner, address indexed pendingOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event SettlementOperatorUpdated(address indexed previousOperator, address indexed newOperator);
    event PolicyUpdated(
        uint64 indexed policyVersion,
        uint256 maxPayout,
        uint256 payoutEpochCap,
        uint256 maxRefund,
        uint256 refundEpochCap
    );
    event PauseStateUpdated(bool payoutsPaused, bool refundsPaused);
    event RewardPaid(
        bytes32 indexed operationId,
        address indexed recipient,
        uint256 amount,
        uint64 indexed policyVersion,
        uint256 epoch
    );
    event RewardRefunded(
        bytes32 indexed operationId,
        address indexed recipient,
        uint256 amount,
        uint64 indexed policyVersion,
        uint256 epoch
    );
    event EmergencyWithdrawal(address indexed recipient, uint256 amount);
    event ForeignTokenRecovered(address indexed token, address indexed recipient, uint256 amount);

    IERC20Minimal public immutable usdc;
    uint64 public immutable epochDuration;

    address public owner;
    address public pendingOwner;
    address public settlementOperator;

    uint64 public policyVersion;
    uint256 public maxPayout;
    uint256 public payoutEpochCap;
    uint256 public maxRefund;
    uint256 public refundEpochCap;
    bool public payoutsPaused = true;
    bool public refundsPaused = true;

    mapping(bytes32 => bool) public usedOperations;
    mapping(uint256 => uint256) public payoutSpentByEpoch;
    mapping(uint256 => uint256) public refundSpentByEpoch;

    uint256 private _unlocked = 1;

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    modifier onlyOperator() {
        if (msg.sender != settlementOperator) revert Unauthorized();
        _;
    }

    modifier nonReentrant() {
        if (_unlocked != 1) revert Reentrancy();
        _unlocked = 2;
        _;
        _unlocked = 1;
    }

    constructor(
        address usdc_,
        address owner_,
        address settlementOperator_,
        uint64 epochDuration_,
        uint64 policyVersion_,
        uint256 maxPayout_,
        uint256 payoutEpochCap_,
        uint256 maxRefund_,
        uint256 refundEpochCap_
    ) {
        if (usdc_ == address(0) || owner_ == address(0) || settlementOperator_ == address(0)) {
            revert ZeroAddress();
        }
        if (epochDuration_ == 0) revert InvalidPolicy();
        usdc = IERC20Minimal(usdc_);
        owner = owner_;
        settlementOperator = settlementOperator_;
        epochDuration = epochDuration_;
        _setPolicy(policyVersion_, maxPayout_, payoutEpochCap_, maxRefund_, refundEpochCap_);
        emit OwnershipTransferred(address(0), owner_);
        emit SettlementOperatorUpdated(address(0), settlementOperator_);
    }

    function currentEpoch() public view returns (uint256) {
        return block.timestamp / epochDuration;
    }

    function pay(
        bytes32 operationId,
        address recipient,
        uint256 amount,
        uint64 deadline,
        uint64 expectedPolicyVersion
    ) external onlyOperator nonReentrant {
        if (payoutsPaused) revert PayoutsPaused();
        uint256 epoch = _authorizeOperation(
            operationId,
            recipient,
            amount,
            deadline,
            expectedPolicyVersion,
            maxPayout,
            payoutEpochCap,
            payoutSpentByEpoch[currentEpoch()]
        );
        payoutSpentByEpoch[epoch] += amount;
        _safeTransfer(usdc, recipient, amount);
        emit RewardPaid(operationId, recipient, amount, policyVersion, epoch);
    }

    function refund(
        bytes32 operationId,
        address recipient,
        uint256 amount,
        uint64 deadline,
        uint64 expectedPolicyVersion
    ) external onlyOperator nonReentrant {
        if (refundsPaused) revert RefundsPaused();
        uint256 epoch = _authorizeOperation(
            operationId,
            recipient,
            amount,
            deadline,
            expectedPolicyVersion,
            maxRefund,
            refundEpochCap,
            refundSpentByEpoch[currentEpoch()]
        );
        refundSpentByEpoch[epoch] += amount;
        _safeTransfer(usdc, recipient, amount);
        emit RewardRefunded(operationId, recipient, amount, policyVersion, epoch);
    }

    function setPauseState(bool payoutsPaused_, bool refundsPaused_) external onlyOwner {
        payoutsPaused = payoutsPaused_;
        refundsPaused = refundsPaused_;
        emit PauseStateUpdated(payoutsPaused_, refundsPaused_);
    }

    function setSettlementOperator(address newOperator) external onlyOwner {
        if (newOperator == address(0)) revert ZeroAddress();
        address previous = settlementOperator;
        settlementOperator = newOperator;
        emit SettlementOperatorUpdated(previous, newOperator);
    }

    function setPolicy(
        uint64 newPolicyVersion,
        uint256 newMaxPayout,
        uint256 newPayoutEpochCap,
        uint256 newMaxRefund,
        uint256 newRefundEpochCap
    ) external onlyOwner {
        if (newPolicyVersion <= policyVersion) revert StalePolicy();
        _setPolicy(
            newPolicyVersion, newMaxPayout, newPayoutEpochCap, newMaxRefund, newRefundEpochCap
        );
    }

    function beginOwnershipTransfer(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert OwnershipTransferNotPending();
        address previous = owner;
        owner = msg.sender;
        pendingOwner = address(0);
        emit OwnershipTransferred(previous, msg.sender);
    }

    function emergencyWithdraw(address recipient, uint256 amount) external onlyOwner nonReentrant {
        if (!payoutsPaused || !refundsPaused) revert VaultMustBeFullyPaused();
        if (recipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        _safeTransfer(usdc, recipient, amount);
        emit EmergencyWithdrawal(recipient, amount);
    }

    function recoverForeignToken(address token, address recipient, uint256 amount)
        external
        onlyOwner
        nonReentrant
    {
        if (token == address(0) || recipient == address(0)) revert ZeroAddress();
        if (token == address(usdc)) revert CannotRecoverUsdcAsForeignToken();
        if (amount == 0) revert ZeroAmount();
        _safeTransfer(IERC20Minimal(token), recipient, amount);
        emit ForeignTokenRecovered(token, recipient, amount);
    }

    function _authorizeOperation(
        bytes32 operationId,
        address recipient,
        uint256 amount,
        uint64 deadline,
        uint64 expectedPolicyVersion,
        uint256 transferLimit,
        uint256 epochCap,
        uint256 alreadySpent
    ) private returns (uint256 epoch) {
        if (operationId == bytes32(0) || recipient == address(0)) {
            revert ZeroAddress();
        }
        if (amount == 0) revert ZeroAmount();
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (expectedPolicyVersion != policyVersion) revert StalePolicy();
        if (usedOperations[operationId]) revert OperationAlreadyUsed();
        if (amount > transferLimit) revert TransferLimitExceeded();
        if (alreadySpent > epochCap || amount > epochCap - alreadySpent) {
            revert EpochLimitExceeded();
        }
        usedOperations[operationId] = true;
        return currentEpoch();
    }

    function _setPolicy(
        uint64 newPolicyVersion,
        uint256 newMaxPayout,
        uint256 newPayoutEpochCap,
        uint256 newMaxRefund,
        uint256 newRefundEpochCap
    ) private {
        if (
            newPolicyVersion == 0 || newMaxPayout == 0 || newPayoutEpochCap < newMaxPayout
                || newMaxRefund == 0 || newRefundEpochCap < newMaxRefund
        ) revert InvalidPolicy();
        policyVersion = newPolicyVersion;
        maxPayout = newMaxPayout;
        payoutEpochCap = newPayoutEpochCap;
        maxRefund = newMaxRefund;
        refundEpochCap = newRefundEpochCap;
        emit PolicyUpdated(
            newPolicyVersion, newMaxPayout, newPayoutEpochCap, newMaxRefund, newRefundEpochCap
        );
    }

    function _safeTransfer(IERC20Minimal token, address recipient, uint256 amount) private {
        (bool ok, bytes memory result) =
            address(token).call(abi.encodeCall(IERC20Minimal.transfer, (recipient, amount)));
        if (!ok || (result.length != 0 && !abi.decode(result, (bool)))) {
            revert TokenTransferFailed();
        }
    }
}
