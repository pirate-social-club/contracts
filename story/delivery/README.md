# Delivery

Minimal Story-side locked-asset delivery contract workspace for Pirate.

## Scope

- durable purchase entitlements as non-transferable ERC-1155-style balances
- token-gated Story CDR read checks
- signed temporary-access conditions and signer registry
- settlement-side entitlement minting and payout forwarding
- publish-time asset-version bindings for CDR vault + entitlement coordination
- no pricing or CDR vault allocation logic inside this workspace

## Current Dev Deployment

The active Story Aeneid dev deployment is recorded in `core/config/story-aeneid-delivery.json`.

## Commands

```bash
cd /home/t42/Documents/pirate-workspace/contracts/story/delivery
rtk forge build
rtk forge test
rtk ./scripts/deploy.sh
```
