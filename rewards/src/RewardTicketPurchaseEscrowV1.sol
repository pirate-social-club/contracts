// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

interface IRewardTicketUsdc {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IRewardTicketJackpot {
    function allowTicketPurchases() external view returns (bool);
    function currentDrawingId() external view returns (uint256);
    function ticketPrice() external view returns (uint256);
    function getDrawingState(uint256 drawingId)
        external
        view
        returns (
            uint256 prizePool,
            uint256 ticketPrice,
            uint256 edgePerTicket,
            uint256 referralWinShare,
            uint256 referralFee,
            uint256 globalTicketsBought,
            uint256 lpEarnings,
            uint256 drawingTime,
            uint256 winningTicket,
            uint8 ballMax,
            uint8 bonusballMax,
            address payoutCalculator,
            bool jackpotLock
        );
}

interface IRewardTicketRandomBuyer {
    function buyTickets(
        uint256 count,
        address recipient,
        address[] calldata referrers,
        uint256[] calldata referralSplitWeights,
        bytes32 source
    ) external returns (uint256[] memory ticketIds);
}

/// @notice Restricted USDC escrow for Megapot ticket purchases.
/// @dev The policy is intentionally fixed to immutable protocol and recipient
/// addresses. The Safe owner can pause and rotate the automation operator, but
/// cannot turn this contract into an arbitrary token or call router.
contract RewardTicketPurchaseEscrowV1 {
    error Unauthorized();
    error ZeroAddress();
    error ZeroAmount();
    error InvalidPolicy();
    error InvalidTicketCount();
    error InvalidOperation();
    error OperationAlreadyUsed();
    error PurchasePaused();
    error DrawingMismatch();
    error PurchasingDisabled();
    error JackpotLocked();
    error TicketPriceMismatch();
    error TicketPriceAboveCeiling();
    error DrawingCutoffSafetyMargin();
    error CostAbovePerPurchaseCap();
    error DailyCapExceeded();
    error TokenCallFailed();
    error BuyerCallFailed();
    error TicketCountMismatch();
    error EscrowMustBePaused();

    event PurchaseOperatorUpdated(address indexed previousOperator, address indexed newOperator);
    event PauseStateUpdated(bool paused);
    event TicketsPurchased(
        bytes32 indexed operationId,
        uint256 indexed drawingId,
        uint256 count,
        uint256 ticketPrice,
        uint256 cost,
        bytes32 source,
        uint256 day
    );
    event UsdcWithdrawn(address indexed recipient, uint256 amount);

    uint256 public constant REFERRAL_WEIGHT_SCALE = 1e18;
    uint256 public constant MAX_PROTOCOL_TICKETS_PER_TRANSACTION = 10;

    address public immutable usdc;
    address public immutable jackpot;
    address public immutable randomTicketBuyer;
    address public immutable custodySafe;
    address public immutable platformRevenue;
    address public immutable policyOwner;
    uint256 public immutable maxTicketPriceAtomic;
    uint256 public immutable maxPurchaseCostAtomic;
    uint256 public immutable dailyPurchaseCapAtomic;
    uint256 public immutable purchaseSafetyMarginSeconds;
    uint256 public immutable maxTicketsPerPurchase;

    address public purchaseOperator;
    bool public paused = true;
    mapping(bytes32 => bool) public usedOperations;
    mapping(uint256 => uint256) public spentByDay;

    uint256 private _unlocked = 1;

    modifier onlyOwner() {
        if (msg.sender != policyOwner) revert Unauthorized();
        _;
    }

    modifier onlyOperator() {
        if (msg.sender != purchaseOperator) revert Unauthorized();
        _;
    }

    modifier nonReentrant() {
        if (_unlocked != 1) revert TokenCallFailed();
        _unlocked = 2;
        _;
        _unlocked = 1;
    }

    constructor(
        address usdc_,
        address jackpot_,
        address randomTicketBuyer_,
        address custodySafe_,
        address platformRevenue_,
        address policyOwner_,
        address purchaseOperator_,
        uint256 maxTicketPriceAtomic_,
        uint256 maxPurchaseCostAtomic_,
        uint256 dailyPurchaseCapAtomic_,
        uint256 purchaseSafetyMarginSeconds_,
        uint256 maxTicketsPerPurchase_
    ) {
        if (
            usdc_ == address(0) || jackpot_ == address(0) || randomTicketBuyer_ == address(0)
                || custodySafe_ == address(0) || platformRevenue_ == address(0)
                || policyOwner_ == address(0) || purchaseOperator_ == address(0)
        ) revert ZeroAddress();
        if (
            custodySafe_ == platformRevenue_ || custodySafe_ == purchaseOperator_
                || platformRevenue_ == purchaseOperator_ || policyOwner_ == purchaseOperator_
                || policyOwner_ != custodySafe_
        ) revert InvalidPolicy();
        if (
            usdc_.code.length == 0 || jackpot_.code.length == 0
                || randomTicketBuyer_.code.length == 0 || custodySafe_.code.length == 0
        ) revert InvalidPolicy();
        if (
            maxTicketPriceAtomic_ == 0 || maxPurchaseCostAtomic_ == 0
                || dailyPurchaseCapAtomic_ < maxPurchaseCostAtomic_
                || purchaseSafetyMarginSeconds_ == 0 || maxTicketsPerPurchase_ == 0
                || maxTicketsPerPurchase_ > MAX_PROTOCOL_TICKETS_PER_TRANSACTION
                || maxTicketPriceAtomic_ * maxTicketsPerPurchase_ < maxPurchaseCostAtomic_
        ) revert InvalidPolicy();

        usdc = usdc_;
        jackpot = jackpot_;
        randomTicketBuyer = randomTicketBuyer_;
        custodySafe = custodySafe_;
        platformRevenue = platformRevenue_;
        policyOwner = policyOwner_;
        purchaseOperator = purchaseOperator_;
        maxTicketPriceAtomic = maxTicketPriceAtomic_;
        maxPurchaseCostAtomic = maxPurchaseCostAtomic_;
        dailyPurchaseCapAtomic = dailyPurchaseCapAtomic_;
        purchaseSafetyMarginSeconds = purchaseSafetyMarginSeconds_;
        maxTicketsPerPurchase = maxTicketsPerPurchase_;

        emit PurchaseOperatorUpdated(address(0), purchaseOperator_);
    }

    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
        emit PauseStateUpdated(paused_);
    }

    function setPurchaseOperator(address newOperator) external onlyOwner {
        if (
            newOperator == address(0) || newOperator == custodySafe
                || newOperator == platformRevenue || newOperator == policyOwner
        ) revert InvalidPolicy();
        address previous = purchaseOperator;
        purchaseOperator = newOperator;
        emit PurchaseOperatorUpdated(previous, newOperator);
    }

    /// @dev The owner can only recover USDC to itself, and only while paused.
    function withdrawUsdc(uint256 amount) external onlyOwner nonReentrant {
        if (!paused) revert EscrowMustBePaused();
        if (amount == 0) revert ZeroAmount();
        _safeTransfer(usdc, policyOwner, amount);
        emit UsdcWithdrawn(policyOwner, amount);
    }

    function purchase(
        bytes32 operationId,
        uint256 count,
        uint256 intendedDrawingId,
        uint256 expectedTicketPriceAtomic,
        bytes32 source
    ) external onlyOperator nonReentrant returns (uint256[] memory ticketIds) {
        if (paused) revert PurchasePaused();
        if (operationId == bytes32(0) || source == bytes32(0)) revert InvalidOperation();
        if (usedOperations[operationId]) revert OperationAlreadyUsed();
        if (intendedDrawingId != IRewardTicketJackpot(jackpot).currentDrawingId()) {
            revert DrawingMismatch();
        }
        if (!IRewardTicketJackpot(jackpot).allowTicketPurchases()) revert PurchasingDisabled();
        (
            uint256 ignoredPrizePool,
            uint256 drawingPrice,
            uint256 ignoredEdgePerTicket,
            uint256 ignoredReferralWinShare,
            uint256 ignoredReferralFee,
            uint256 ignoredGlobalTicketsBought,
            uint256 ignoredLpEarnings,
            uint256 drawingTime,
            uint256 ignoredWinningTicket,
            uint8 ignoredBallMax,
            uint8 ignoredBonusballMax,
            address ignoredPayoutCalculator,
            bool jackpotLock
        ) = IRewardTicketJackpot(jackpot).getDrawingState(intendedDrawingId);
        ignoredPrizePool;
        ignoredEdgePerTicket;
        ignoredReferralWinShare;
        ignoredReferralFee;
        ignoredGlobalTicketsBought;
        ignoredLpEarnings;
        ignoredWinningTicket;
        ignoredBallMax;
        ignoredBonusballMax;
        ignoredPayoutCalculator;
        if (jackpotLock) revert JackpotLocked();
        uint256 livePrice = IRewardTicketJackpot(jackpot).ticketPrice();
        if (livePrice == 0 || livePrice != drawingPrice || livePrice != expectedTicketPriceAtomic) {
            revert TicketPriceMismatch();
        }
        if (livePrice > maxTicketPriceAtomic) revert TicketPriceAboveCeiling();
        if (
            drawingTime <= block.timestamp
                || block.timestamp + purchaseSafetyMarginSeconds >= drawingTime
        ) {
            revert DrawingCutoffSafetyMargin();
        }

        if (count == 0 || count > maxTicketsPerPurchase) revert InvalidTicketCount();
        uint256 cost = livePrice * count;
        if (cost > maxPurchaseCostAtomic) revert CostAbovePerPurchaseCap();
        uint256 day = block.timestamp / 1 days;
        if (
            spentByDay[day] > dailyPurchaseCapAtomic
                || cost > dailyPurchaseCapAtomic - spentByDay[day]
        ) {
            revert DailyCapExceeded();
        }

        usedOperations[operationId] = true;
        _safeApprove(usdc, randomTicketBuyer, 0);
        _safeApprove(usdc, randomTicketBuyer, cost);
        address[] memory referrers = new address[](1);
        referrers[0] = platformRevenue;
        uint256[] memory referralSplitWeights = new uint256[](1);
        referralSplitWeights[0] = REFERRAL_WEIGHT_SCALE;
        try IRewardTicketRandomBuyer(randomTicketBuyer)
            .buyTickets(count, custodySafe, referrers, referralSplitWeights, source) returns (
            uint256[] memory returnedTicketIds
        ) {
            ticketIds = returnedTicketIds;
        } catch {
            revert BuyerCallFailed();
        }
        if (ticketIds.length != count) revert TicketCountMismatch();
        _safeApprove(usdc, randomTicketBuyer, 0);
        spentByDay[day] += cost;
        emit TicketsPurchased(operationId, intendedDrawingId, count, livePrice, cost, source, day);
    }

    function _safeApprove(address token, address spender, uint256 amount) private {
        (bool ok, bytes memory result) =
            token.call(abi.encodeWithSignature("approve(address,uint256)", spender, amount));
        if (!ok || (result.length != 0 && !abi.decode(result, (bool)))) revert TokenCallFailed();
    }

    function _safeTransfer(address token, address recipient, uint256 amount) private {
        (bool ok, bytes memory result) =
            token.call(abi.encodeWithSignature("transfer(address,uint256)", recipient, amount));
        if (!ok || (result.length != 0 && !abi.decode(result, (bool)))) revert TokenCallFailed();
    }
}
