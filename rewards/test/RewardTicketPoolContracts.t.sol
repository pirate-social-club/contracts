// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {RewardTicketCommitmentRegistryV1} from "../src/RewardTicketCommitmentRegistryV1.sol";
import {RewardTicketPurchaseEscrowV1} from "../src/RewardTicketPurchaseEscrowV1.sol";
import {RewardTicketSafeClaimModuleV1} from "../src/RewardTicketSafeClaimModuleV1.sol";

interface Vm {
    function warp(uint256 timestamp) external;
}

contract MockRewardUsdc {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address recipient, uint256 amount) external {
        balanceOf[recipient] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address recipient, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[recipient] += amount;
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount)
        external
        returns (bool)
    {
        require(balanceOf[sender] >= amount, "balance");
        require(allowance[sender][msg.sender] >= amount, "allowance");
        allowance[sender][msg.sender] -= amount;
        balanceOf[sender] -= amount;
        balanceOf[recipient] += amount;
        return true;
    }
}

contract MockRewardJackpot {
    bool public allowTicketPurchases = true;
    uint256 public currentDrawingId = 7;
    uint256 public ticketPrice = 1e6;
    uint256 public drawingTime = type(uint256).max;
    bool public jackpotLock;

    function setState(
        bool allowPurchases,
        uint256 drawingId,
        uint256 price,
        uint256 drawingTime_,
        bool locked
    ) external {
        allowTicketPurchases = allowPurchases;
        currentDrawingId = drawingId;
        ticketPrice = price;
        drawingTime = drawingTime_;
        jackpotLock = locked;
    }

    function getDrawingState(uint256)
        external
        view
        returns (
            uint256 prizePool,
            uint256 ticketPrice_,
            uint256 edgePerTicket,
            uint256 referralWinShare,
            uint256 referralFee,
            uint256 globalTicketsBought,
            uint256 lpEarnings,
            uint256 drawingTime_,
            uint256 winningTicket,
            uint8 ballMax,
            uint8 bonusballMax,
            address payoutCalculator,
            bool jackpotLock_
        )
    {
        return (0, ticketPrice, 0, 0, 0, 0, 0, drawingTime, 0, 0, 0, address(0), jackpotLock);
    }
}

contract MockRewardBuyer {
    MockRewardUsdc public immutable usdc;
    MockRewardJackpot public immutable jackpot;
    address public lastRecipient;
    address public lastReferrer;
    uint256 public lastWeight;
    bytes32 public lastSource;
    uint256 public received;
    uint256 private _nextTicket = 100;

    constructor(MockRewardUsdc usdc_, MockRewardJackpot jackpot_) {
        usdc = usdc_;
        jackpot = jackpot_;
    }

    function buyTickets(
        uint256 count,
        address recipient,
        address[] calldata referrers,
        uint256[] calldata referralSplitWeights,
        bytes32 source
    ) external returns (uint256[] memory ticketIds) {
        require(referrers.length == 1 && referralSplitWeights.length == 1, "referrals");
        lastRecipient = recipient;
        lastReferrer = referrers[0];
        lastWeight = referralSplitWeights[0];
        lastSource = source;
        uint256 cost = count * jackpot.ticketPrice();
        usdc.transferFrom(msg.sender, address(this), cost);
        received += cost;
        ticketIds = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            ticketIds[i] = _nextTicket++;
        }
    }
}

contract MockRewardSafe {
    address public allowedModule;

    function setAllowedModule(address module) external {
        allowedModule = module;
    }

    function callTarget(address target, bytes calldata data) external {
        (bool ok,) = target.call(data);
        require(ok, "safe-call");
    }

    function execTransactionFromModule(address to, uint256 value, bytes calldata data, uint8)
        external
        returns (bool success)
    {
        require(msg.sender == allowedModule, "module");
        (success,) = to.call{value: value}(data);
    }
}

contract MockRewardClaimJackpot {
    address public lastCaller;
    uint256[] public lastTicketIds;

    function claimWinnings(uint256[] calldata ticketIds) external {
        lastCaller = msg.sender;
        delete lastTicketIds;
        for (uint256 i = 0; i < ticketIds.length; i++) {
            lastTicketIds.push(ticketIds[i]);
        }
    }
}

contract RewardTicketOperatorActor {
    function purchase(
        RewardTicketPurchaseEscrowV1 escrow,
        bytes32 operationId,
        uint256 count,
        uint256 drawingId,
        uint256 ticketPrice,
        bytes32 source
    ) external {
        escrow.purchase(operationId, count, drawingId, ticketPrice, source);
    }

    function publish(
        RewardTicketCommitmentRegistryV1 registry,
        address jackpot,
        uint256 drawingId,
        bytes32 rootHash,
        uint32 leafCount,
        bytes32 termsVersionHash
    ) external {
        registry.publish(jackpot, drawingId, rootHash, leafCount, termsVersionHash);
    }

    function claim(
        RewardTicketSafeClaimModuleV1 module,
        bytes32 operationId,
        uint256[] calldata ticketIds
    ) external {
        module.claim(operationId, ticketIds);
    }
}

contract RewardTicketPoolContractsTest {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    MockRewardUsdc private usdc;
    MockRewardJackpot private jackpot;
    MockRewardBuyer private buyer;
    MockRewardSafe private safe;
    RewardTicketOperatorActor private operator;
    RewardTicketOperatorActor private revenue;
    RewardTicketPurchaseEscrowV1 private escrow;

    function setUp() public {
        usdc = new MockRewardUsdc();
        jackpot = new MockRewardJackpot();
        buyer = new MockRewardBuyer(usdc, jackpot);
        safe = new MockRewardSafe();
        operator = new RewardTicketOperatorActor();
        revenue = new RewardTicketOperatorActor();
        escrow = new RewardTicketPurchaseEscrowV1(
            address(usdc),
            address(jackpot),
            address(buyer),
            address(safe),
            address(revenue),
            address(safe),
            address(operator),
            2e6,
            10e6,
            20e6,
            60,
            10
        );
        usdc.mint(address(escrow), 100e6);
        safe.callTarget(address(escrow), abi.encodeCall(escrow.setPaused, (false)));
        jackpot.setState(true, 7, 1e6, block.timestamp + 1 days, false);
    }

    function testEscrowBuysOnlyIntoSafeAndUsesFixedReferral() public {
        bytes32 operationId = keccak256("purchase-1");
        bytes32 source = keccak256("source-1");
        operator.purchase(escrow, operationId, 3, 7, 1e6, source);

        assert(buyer.lastRecipient() == address(safe));
        assert(buyer.lastReferrer() == address(revenue));
        assert(buyer.lastWeight() == 1e18);
        assert(buyer.lastSource() == source);
        assert(buyer.received() == 3e6);
        assert(usdc.allowance(address(escrow), address(buyer)) == 0);
        assert(escrow.spentByDay(block.timestamp / 1 days) == 3e6);
    }

    function testEscrowRejectsReplayAndDrawingBoundary() public {
        bytes32 operationId = keccak256("purchase-2");
        bytes32 source = keccak256("source-2");
        operator.purchase(escrow, operationId, 1, 7, 1e6, source);

        (bool replayOk,) = address(operator)
            .call(
                abi.encodeWithSelector(
                    RewardTicketOperatorActor.purchase.selector,
                    escrow,
                    operationId,
                    1,
                    7,
                    1e6,
                    source
                )
            );
        assert(!replayOk);

        jackpot.setState(true, 8, 1e6, block.timestamp + 1 days, false);
        (bool mismatchOk,) = address(operator)
            .call(
                abi.encodeWithSelector(
                    RewardTicketOperatorActor.purchase.selector,
                    escrow,
                    keccak256("purchase-3"),
                    1,
                    7,
                    1e6,
                    keccak256("source-3")
                )
            );
        assert(!mismatchOk);
    }

    function testEscrowRejectsPriceAndCutoffViolations() public {
        jackpot.setState(true, 7, 3e6, block.timestamp + 1 days, false);
        (bool expensiveOk,) = address(operator)
            .call(
                abi.encodeWithSelector(
                    RewardTicketOperatorActor.purchase.selector,
                    escrow,
                    keccak256("purchase-4"),
                    1,
                    7,
                    3e6,
                    keccak256("source-4")
                )
            );
        assert(!expensiveOk);

        jackpot.setState(true, 7, 1e6, block.timestamp + 30, false);
        (bool cutoffOk,) = address(operator)
            .call(
                abi.encodeWithSelector(
                    RewardTicketOperatorActor.purchase.selector,
                    escrow,
                    keccak256("purchase-5"),
                    1,
                    7,
                    1e6,
                    keccak256("source-5")
                )
            );
        assert(!cutoffOk);
    }

    function testRegistryPublishesOneImmutableRoot() public {
        RewardTicketCommitmentRegistryV1 registry =
            new RewardTicketCommitmentRegistryV1(address(safe), address(operator));
        safe.callTarget(address(registry), abi.encodeCall(registry.setPaused, (false)));
        bytes32 root = keccak256("root-1");
        bytes32 terms = keccak256("terms-1");
        operator.publish(registry, address(jackpot), 7, root, 3, terms);

        RewardTicketCommitmentRegistryV1.Commitment memory stored =
            registry.getCommitment(address(jackpot), 7);
        assert(stored.rootHash == root);
        assert(stored.termsVersionHash == terms);
        assert(stored.leafCount == 3);
        assert(stored.publishedAt != 0);
        assert(stored.publisher == address(operator));
        assert(registry.isPublished(address(jackpot), 7));

        (bool duplicateOk,) = address(operator)
            .call(
                abi.encodeWithSelector(
                    RewardTicketOperatorActor.publish.selector,
                    registry,
                    address(jackpot),
                    7,
                    root,
                    3,
                    terms
                )
            );
        assert(!duplicateOk);
    }

    function testSafeClaimModuleMakesSafeTheMegapotCaller() public {
        MockRewardClaimJackpot claimJackpot = new MockRewardClaimJackpot();
        RewardTicketSafeClaimModuleV1 module = new RewardTicketSafeClaimModuleV1(
            address(safe), address(claimJackpot), address(operator), 10
        );
        safe.setAllowedModule(address(module));
        safe.callTarget(address(module), abi.encodeCall(module.setPaused, (false)));

        uint256[] memory ticketIds = new uint256[](2);
        ticketIds[0] = 41;
        ticketIds[1] = 42;
        operator.claim(module, keccak256("claim-1"), ticketIds);

        assert(claimJackpot.lastCaller() == address(safe));
        assert(claimJackpot.lastTicketIds(0) == 41);
        assert(claimJackpot.lastTicketIds(1) == 42);
        assert(module.usedOperations(keccak256("claim-1")));
    }

    function testSafeClaimModuleRejectsDuplicateTicketIds() public {
        MockRewardClaimJackpot claimJackpot = new MockRewardClaimJackpot();
        RewardTicketSafeClaimModuleV1 module = new RewardTicketSafeClaimModuleV1(
            address(safe), address(claimJackpot), address(operator), 10
        );
        safe.setAllowedModule(address(module));
        safe.callTarget(address(module), abi.encodeCall(module.setPaused, (false)));
        uint256[] memory ticketIds = new uint256[](2);
        ticketIds[0] = 41;
        ticketIds[1] = 41;
        (bool ok,) = address(operator)
            .call(
                abi.encodeWithSelector(
                    RewardTicketOperatorActor.claim.selector,
                    module,
                    keccak256("claim-2"),
                    ticketIds
                )
            );
        assert(!ok);
    }
}
