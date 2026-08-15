// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {RewardTicketCommitmentRegistryV1} from "../src/RewardTicketCommitmentRegistryV1.sol";
import {RewardTicketPurchaseEscrowV1} from "../src/RewardTicketPurchaseEscrowV1.sol";
import {RewardTicketSafeClaimModuleV1} from "../src/RewardTicketSafeClaimModuleV1.sol";

interface Vm {
    function envAddress(string calldata name) external returns (address);
    function envUint(string calldata name) external returns (uint256);
    function startBroadcast() external;
    function stopBroadcast() external;
}

/// @notice Deploys the three Megapot controls with their initial paused state intact.
/// @dev No Safe transactions are attempted here. The Safe must separately review and
///      execute unpause/module-enable calls after bytecode and constructor verification.
contract DeployRewardTicketPoolControls {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    struct Deployment {
        address escrow;
        address registry;
        address claimModule;
    }

    function run() external returns (Deployment memory deployment) {
        address usdc = vm.envAddress("REWARD_TICKET_USDC_ADDRESS");
        address jackpot = vm.envAddress("REWARD_TICKET_JACKPOT_ADDRESS");
        address randomTicketBuyer = vm.envAddress("REWARD_TICKET_RANDOM_BUYER_ADDRESS");
        address custodySafe = vm.envAddress("REWARD_TICKET_CUSTODY_SAFE_ADDRESS");
        address platformRevenue = vm.envAddress("REWARD_TICKET_PLATFORM_REVENUE_ADDRESS");
        address purchaseOperator = vm.envAddress("REWARD_TICKET_PURCHASE_OPERATOR_ADDRESS");

        uint256 maxTicketPriceAtomic = vm.envUint("REWARD_TICKET_MAX_PRICE_ATOMIC");
        uint256 maxPurchaseCostAtomic = vm.envUint("REWARD_TICKET_MAX_PURCHASE_COST_ATOMIC");
        uint256 dailyPurchaseCapAtomic = vm.envUint("REWARD_TICKET_DAILY_CAP_ATOMIC");
        uint256 safetyMarginSeconds = vm.envUint("REWARD_TICKET_CUTOFF_MARGIN_SECONDS");
        uint256 maxTicketsPerPurchase = vm.envUint("REWARD_TICKET_MAX_TICKETS_PER_PURCHASE");
        uint256 maxTicketsPerClaim = vm.envUint("REWARD_TICKET_MAX_TICKETS_PER_CLAIM");

        vm.startBroadcast();
        RewardTicketPurchaseEscrowV1 escrow = new RewardTicketPurchaseEscrowV1(
            usdc,
            jackpot,
            randomTicketBuyer,
            custodySafe,
            platformRevenue,
            custodySafe,
            purchaseOperator,
            maxTicketPriceAtomic,
            maxPurchaseCostAtomic,
            dailyPurchaseCapAtomic,
            safetyMarginSeconds,
            maxTicketsPerPurchase
        );
        RewardTicketCommitmentRegistryV1 registry =
            new RewardTicketCommitmentRegistryV1(custodySafe, purchaseOperator);
        RewardTicketSafeClaimModuleV1 claimModule = new RewardTicketSafeClaimModuleV1(
            custodySafe, jackpot, purchaseOperator, maxTicketsPerClaim
        );
        vm.stopBroadcast();

        deployment = Deployment({
            escrow: address(escrow), registry: address(registry), claimModule: address(claimModule)
        });
    }
}
