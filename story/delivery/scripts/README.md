# Delivery Scripts

These scripts deploy and configure the locked-asset delivery contract stack in dependency order.

## Contracts

The deploy script handles this DAG:

- `PurchaseEntitlementToken`
- `PirateSignerRegistry`
- `TokenGateCondition`
- `SignedAccessConditionV1` depends on `PirateSignerRegistry`
- `AssetPublishCoordinatorV1` depends on `PurchaseEntitlementToken`
- `MarketplaceSettlementV1` depends on `PurchaseEntitlementToken`

Then it grants:

- settlement contract as entitlement minter
- publish operator on publish coordinator
- settlement operator on settlement contract
- temporary-access proof signer in signer registry

## Required Env

```bash
RPC_URL=...
STORY_CONTRACT_OWNER_PRIVATE_KEY=...
PUBLISH_OPERATOR=0x...
SETTLEMENT_OPERATOR=0x...
ACCESS_PROOF_SIGNER=0x...
OWNER_ADDRESS=0x...   # optional but strongly recommended
DEPLOY_TAG=dev-aeneid
LEGACY=1              # optional; pass through to forge/cast txs for legacy chains
```

Optional resumability inputs:

```bash
PURCHASE_ENTITLEMENT_TOKEN=0x...
PIRATE_SIGNER_REGISTRY=0x...
TOKEN_GATE_CONDITION=0x...
SIGNED_ACCESS_CONDITION_V1=0x...
ASSET_PUBLISH_COORDINATOR_V1=0x...
MARKETPLACE_SETTLEMENT_V1=0x...
```

## Usage

From the `delivery` workspace:

```bash
rtk ./scripts/deploy.sh
```

The script prints a shell-style deployment manifest on success.
It also writes the same manifest to `deployments/<DEPLOY_TAG>.env`.
The checked-in repo source of truth for the active Story Aeneid dev addresses lives in [story-aeneid-delivery.json](/home/t42/Documents/pirate-v2/config/story-aeneid-delivery.json).

## Notes

- `TokenGateCondition` has no constructor dependencies and can deploy at any point.
- The script chooses a deterministic order that keeps constructor dependencies obvious.
- `PUBLISH_OPERATOR` should correspond to the Story operator family entry that includes `publishAssetVersion(...)` in `config/lit-families.json`.
- The script is resumable. If a partial manifest already exists for `DEPLOY_TAG`, re-running will source it and continue unless the manifest is already marked complete.
- You can also resume manually by exporting any already-deployed contract address env vars shown above.
- If `forge create` broadcasts successfully but fails to print `Deployed to:`, the script falls back to deployer nonce advancement plus `cast compute-address` and verifies code onchain before continuing.
- `LEGACY=1` passes `--legacy` to both `forge create` and `cast send`.
- `https://rpc.ankr.com/story_aeneid_testnet` worked reliably for the 2026-04-09 dev deployment. The official Aeneid RPC broadcasted txs but returned responses that broke Foundry/alloy receipt parsing.
- If `OWNER_ADDRESS` is unset, the deployer key keeps ownership of `PurchaseEntitlementToken`, `PirateSignerRegistry`, `AssetPublishCoordinatorV1`, and `MarketplaceSettlementV1`.
- If `OWNER_ADDRESS` equals the deployer address, ownership transfers are skipped as no-ops.
- `STORY_CONTRACT_OWNER_PRIVATE_KEY` is intentionally specific: use the funded Story contract-owner key, not a PKP-derived key and not any legacy fallback such as `MUSIC_PURCHASE_STORY_SETTLEMENT_PRIVATE_KEY`.
