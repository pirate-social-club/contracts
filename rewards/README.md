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
