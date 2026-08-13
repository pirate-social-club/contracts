// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

interface IRewardTicketSafeModule {
    function execTransactionFromModule(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation
    ) external returns (bool success);
}

interface IRewardTicketJackpotClaim {
    function claimWinnings(uint256[] calldata ticketIds) external;
}

/// @notice Least-privilege automation module for a Safe that owns Megapot tickets.
/// @dev The Safe remains the caller of Jackpot.claimWinnings. The operator can
///      submit claims only; Safe owners control module enablement and rotation.
contract RewardTicketSafeClaimModuleV1 {
    error Unauthorized();
    error ZeroAddress();
    error InvalidPolicy();
    error ClaimPaused();
    error InvalidOperation();
    error OperationAlreadyUsed();
    error InvalidTicketBatch();
    error DuplicateTicketId();
    error SafeExecutionFailed();
    error NotAContract();

    event ClaimOperatorUpdated(address indexed previousOperator, address indexed newOperator);
    event PauseStateUpdated(bool paused);
    event ClaimSubmitted(
        bytes32 indexed operationId,
        bytes32 indexed ticketIdsHash,
        uint256 ticketCount,
        address indexed operator
    );

    address public immutable safe;
    address public immutable jackpot;
    uint256 public immutable maxTicketsPerClaim;
    address public claimOperator;
    bool public paused = true;
    mapping(bytes32 => bool) public usedOperations;

    modifier onlySafe() {
        if (msg.sender != safe) revert Unauthorized();
        _;
    }

    modifier onlyOperator() {
        if (msg.sender != claimOperator) revert Unauthorized();
        _;
    }

    constructor(address safe_, address jackpot_, address claimOperator_, uint256 maxTicketsPerClaim_) {
        if (safe_ == address(0) || jackpot_ == address(0) || claimOperator_ == address(0)) {
            revert ZeroAddress();
        }
        if (safe_.code.length == 0 || jackpot_.code.length == 0) revert NotAContract();
        if (claimOperator_ == safe_ || maxTicketsPerClaim_ == 0) revert InvalidPolicy();
        safe = safe_;
        jackpot = jackpot_;
        claimOperator = claimOperator_;
        maxTicketsPerClaim = maxTicketsPerClaim_;
        emit ClaimOperatorUpdated(address(0), claimOperator_);
    }

    function setPaused(bool paused_) external onlySafe {
        paused = paused_;
        emit PauseStateUpdated(paused_);
    }

    function setClaimOperator(address newOperator) external onlySafe {
        if (newOperator == address(0) || newOperator == safe) revert InvalidPolicy();
        address previous = claimOperator;
        claimOperator = newOperator;
        emit ClaimOperatorUpdated(previous, newOperator);
    }

    function claim(bytes32 operationId, uint256[] calldata ticketIds)
        external
        onlyOperator
        returns (bool)
    {
        if (paused) revert ClaimPaused();
        if (operationId == bytes32(0)) revert InvalidOperation();
        if (usedOperations[operationId]) revert OperationAlreadyUsed();
        if (ticketIds.length == 0 || ticketIds.length > maxTicketsPerClaim) revert InvalidTicketBatch();
        _assertUnique(ticketIds);

        usedOperations[operationId] = true;
        bytes memory data = abi.encodeCall(IRewardTicketJackpotClaim.claimWinnings, (ticketIds));
        bool success = IRewardTicketSafeModule(safe).execTransactionFromModule(jackpot, 0, data, 0);
        if (!success) revert SafeExecutionFailed();
        emit ClaimSubmitted(operationId, keccak256(abi.encode(ticketIds)), ticketIds.length, msg.sender);
        return true;
    }

    function _assertUnique(uint256[] calldata ticketIds) private pure {
        for (uint256 i = 0; i < ticketIds.length; i++) {
            for (uint256 j = i + 1; j < ticketIds.length; j++) {
                if (ticketIds[i] == ticketIds[j]) revert DuplicateTicketId();
            }
        }
    }
}
