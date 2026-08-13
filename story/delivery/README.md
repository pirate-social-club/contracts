# Delivery

Minimal Story-side locked-asset delivery contract workspace for Pirate.

## Scope

- durable purchase entitlements as non-transferable ERC-1155-style balances
- token-gated Story CDR read checks
- signed temporary-access conditions and signer registry
- settlement-side entitlement minting and payout forwarding
- publish-time asset-version bindings for CDR vault + entitlement coordination
- no pricing or CDR vault allocation logic inside this workspace

## Megapot ticket-pool controls

The ticket-pool control contracts are deliberately separate from the rewards
treasury vault:

- `RewardTicketPurchaseEscrowV1` holds purchase USDC and can call only the pinned
  Megapot random-ticket buyer with a fixed Safe recipient, referral address,
  per-purchase/daily ceilings, a cutoff margin, and exact-operation replay guard.
- `RewardTicketCommitmentRegistryV1` is an append-only root publication rail. A
  root for a `(Jackpot, drawing)` can be published once and cannot be replaced.
- `RewardTicketSafeClaimModuleV1` lets one automation operator ask the Safe to call
  only `claimWinnings`; the Safe remains the NFT owner and can always claim directly
  through its normal threshold path.

These contracts have no upgrade or arbitrary-call path. Deployments must be pinned
by address and runtime bytecode hash before the API worker is enabled.

## Current Dev Deployment

The active Story Aeneid dev deployment is recorded in `core/config/story-aeneid-delivery.json`.

## Commands

```bash
cd /home/t42/Documents/pirate-workspace/contracts/story/delivery
rtk forge build
rtk forge test
rtk ./scripts/deploy.sh
```
