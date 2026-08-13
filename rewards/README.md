# Megapot ticket-pool controls

This is an independent Foundry workspace for the Megapot ticket-pool control
plane. It is deliberately separate from the Story delivery contracts and from
the rewards treasury vault.

## Scope

- `RewardTicketPurchaseEscrowV1` holds purchase USDC and calls only the pinned
  Megapot random-ticket buyer with a fixed Safe recipient, referral address,
  per-purchase and daily ceilings, a cutoff margin, and an operation replay
  guard.
- `RewardTicketCommitmentRegistryV1` is an append-only root publication rail.
  A root for a `(Jackpot, drawing)` can be published once and cannot be replaced.
- `RewardTicketSafeClaimModuleV1` lets one automation operator ask the Safe to
  call only `claimWinnings`; the Safe remains the NFT owner and can always claim
  directly through its normal threshold path.

These contracts have no upgrade or arbitrary-call path. Deployments must be
pinned by address and runtime bytecode hash before the API worker is enabled.
Record the chain ID, deployment transaction and block, constructor parameters,
runtime `eth_getCode`, and `keccak256(eth_getCode)` in the rollout runbook.

## Validation

```bash
cd /home/t42/Documents/pirate-workspace/contracts/rewards
rtk forge build
rtk forge test
```

Sepolia validation must include both the happy path and negative paths for
recipient/drawing binding, cutoff margin, price ceiling, per-purchase and daily
caps, operation replay, and the claim module's refusal of NFT transfers and
arbitrary calls. Never print private keys in the runbook.

## Deployment

`script/DeployRewardTicketPoolControls.s.sol` deploys the escrow, registry, and
claim module with all three contracts paused. It does not enable the claim
module or execute any Safe transaction. Use a reviewed signer or hardware-wallet
flow; do not place private keys in this repository or in chat.

For the first Base Sepolia rehearsal, re-read the Megapot getters immediately
before choosing the ceiling. A conservative observed policy was:

```text
REWARD_TICKET_MAX_PRICE_ATOMIC=10000
REWARD_TICKET_MAX_PURCHASE_COST_ATOMIC=100000
REWARD_TICKET_DAILY_CAP_ATOMIC=200000
REWARD_TICKET_CUTOFF_MARGIN_SECONDS=300
REWARD_TICKET_MAX_TICKETS_PER_PURCHASE=10
REWARD_TICKET_MAX_TICKETS_PER_CLAIM=10
```

Example environment names:

```text
REWARD_TICKET_USDC_ADDRESS=0x...
REWARD_TICKET_JACKPOT_ADDRESS=0x...
REWARD_TICKET_RANDOM_BUYER_ADDRESS=0x...
REWARD_TICKET_CUSTODY_SAFE_ADDRESS=0x...
REWARD_TICKET_PLATFORM_REVENUE_ADDRESS=0x...
REWARD_TICKET_PURCHASE_OPERATOR_ADDRESS=0x...
```

Run only after reviewing the constructor values and signer mode:

```bash
rtk forge script script/DeployRewardTicketPoolControls.s.sol:DeployRewardTicketPoolControls \
  --rpc-url "$RPC_URL" --private-key "$DEPLOYER_PRIVATE_KEY" --broadcast
```

Record each deployment transaction, block, address, constructor arguments,
runtime code, and runtime-code hash. Keep the contracts paused until those
checks pass and the Safe separately approves its control calls.
