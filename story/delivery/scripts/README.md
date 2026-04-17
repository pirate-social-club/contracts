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

## Modes

The deploy script supports two modes controlled by the `MODE` env var:

### Hot mode (default)

Signs and broadcasts transactions immediately using `STORY_CONTRACT_OWNER_PRIVATE_KEY`. This is the local convenience path, suitable for disposable dev/test deployments.

### Unsigned mode (`MODE=unsigned`)

Produces a step-by-step manifest of unsigned transactions for cold-wallet signing (e.g., Keystone). No private key required. The deployer address is supplied explicitly via `DEPLOYER_ADDRESS`.

In unsigned mode, the script:

1. Builds contracts with `forge build`
2. For each step in the deployment DAG, writes a JSON file under `deployments/$DEPLOY_TAG/steps/`
3. Each step JSON contains the unsigned raw tx, predicted contract address, fee fields, and a postcondition check

You then sign each step on your hardware wallet and broadcast with `publish-signed.sh`.
`publish-signed.sh` verifies the signed tx still matches the step manifest before it publishes.
`render-step-qr.sh` can render single-QR-capable steps for scanning, but larger create steps still need file/microSD handoff until a multipart QR flow exists.
`render-step-keystone-ur.mjs` wraps a step in Keystone's `eth-sign-request` UR format and renders an animated QR bundle for airgapped signing.
`decode-keystone-signature.mjs` decodes the signed `eth-signature` UR response back into a signed raw transaction hex file.

Steps must be signed and broadcast in order. Nonce values are assigned sequentially at prepare time.

## Required Env

### Hot mode

```bash
MODE=hot                          # default
RPC_URL=...
STORY_CONTRACT_OWNER_PRIVATE_KEY=...
PUBLISH_OPERATOR=0x...
SETTLEMENT_OPERATOR=0x...
ACCESS_PROOF_SIGNER=0x...
OWNER_ADDRESS=0x...               # optional but strongly recommended
DEPLOY_TAG=dev-aeneid
LEGACY=1                          # optional; pass through to forge/cast txs for legacy chains
```

### Unsigned mode

```bash
MODE=unsigned
RPC_URL=...
DEPLOYER_ADDRESS=0x...            # your cold-wallet address
PUBLISH_OPERATOR=0x...
SETTLEMENT_OPERATOR=0x...
ACCESS_PROOF_SIGNER=0x...
OWNER_ADDRESS=0x...               # optional but strongly recommended
DEPLOY_TAG=prod-aeneid
LEGACY=1                          # optional
GAS_LIMIT=...                     # optional override
GAS_PRICE=...                     # optional override
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

### Hot mode

From the `delivery` workspace:

```bash
rtk ./scripts/deploy.sh
```

### Unsigned mode

From the `delivery` workspace:

```bash
MODE=unsigned DEPLOYER_ADDRESS=0x... RPC_URL=... \
  PUBLISH_OPERATOR=0x... SETTLEMENT_OPERATOR=0x... ACCESS_PROOF_SIGNER=0x... \
  DEPLOY_TAG=prod-aeneid \
  rtk ./scripts/deploy.sh
```

This writes step JSON files to `deployments/prod-aeneid/steps/`. For each step:

1. Sign the `unsignedRawTx` on your hardware wallet
2. Save the signed raw tx to a file
3. Broadcast and verify:

```bash
RPC_URL=... rtk ./scripts/publish-signed.sh \
  --step deployments/prod-aeneid/steps/001-purchase-entitlement-token.create.json \
  --signed-tx-file /path/to/signed-tx.hex
```

4. Repeat for the next step

### Render a step as a QR

For steps small enough to fit in one static QR:

```bash
rtk ./scripts/render-step-qr.sh \
  --step deployments/prod-aeneid/steps/003-pirate-signer-registry-set-signer.call.json \
  --output /tmp/story-step-003.svg
```

Or render directly in the terminal:

```bash
rtk ./scripts/render-step-qr.sh \
  --step deployments/prod-aeneid/steps/003-pirate-signer-registry-set-signer.call.json \
  --type utf8 \
  --small
```

If the helper says the step is too large, that step does not fit in a single static QR. The current scripts do not yet implement multipart/animated QR transport for large create transactions.

### Render a Keystone animated QR bundle

For a real airgapped Keystone flow, use the UR helper instead of the static QR helper:

```bash
rtk bun ./scripts/render-step-keystone-ur.mjs \
  --step deployments/prod-aeneid/steps/001-purchase-entitlement-token.create.json \
  --xfp F23F9FD2 \
  --path "m/44'/60'/0'/0/0"
```

Or, after pairing once:

```bash
rtk bun ./scripts/render-step-keystone-ur.mjs \
  --step deployments/prod-aeneid/steps/001-purchase-entitlement-token.create.json \
  --account keystone-prod
```

This writes:

- `request.json`
- `parts.txt`
- `frame-0001.svg`, `frame-0002.svg`, ...
- `index.html` autoplaying the QR sequence

Open the generated `index.html` locally and scan it with Keystone.

Notes:

- `--xfp` is the 8-hex source/master fingerprint for the signing account.
- `--path` defaults to `m/44'/60'/0'/0/0`, but pass the actual derivation path if your Keystone account differs.
- `--account` loads both values from `accounts/<alias>.json`, which you can create with `pair-keystone-account.mjs`.
- This generates the outbound `eth-sign-request` only. The current `publish-signed.sh` still expects a signed raw transaction hex, not a scanned `eth-signature` UR response.

### Pair a Keystone account once

Scan or export Keystone's account pairing QR, save the UR fragments to a text file, then import them:

```bash
rtk bun ./scripts/pair-keystone-account.mjs \
  --alias keystone-prod \
  --ur-file /path/to/keystone-account.txt
```

This writes:

- `accounts/keystone-prod.json`

The stored account metadata includes:

- `address`
- `xfp`
- `derivationPath`

After that, use `--account keystone-prod` instead of raw `--xfp` and `--path`.

### Decode Keystone's signed QR response

After signing on Keystone, collect the returned `ur:eth-signature/...` frames into a text file with one fragment per line, then decode them:

```bash
rtk bun ./scripts/decode-keystone-signature.mjs \
  --request deployments/prod-aeneid/keystone/001-purchase-entitlement-token.create/request.json \
  --signature-ur-file /path/to/keystone-signature.txt
```

By default this writes:

- `signed.hex`
- `signed.hex.json`

in the same request bundle directory.

Then broadcast with:

```bash
RPC_URL=... rtk ./scripts/publish-signed.sh \
  --step deployments/prod-aeneid/steps/001-purchase-entitlement-token.create.json \
  --signed-tx-file deployments/prod-aeneid/keystone/001-purchase-entitlement-token.create/signed.hex
```

The script prints a shell-style deployment manifest on success.
It also writes the same manifest to `deployments/<DEPLOY_TAG>.env`.
The checked-in repo source of truth for the active Story Aeneid dev addresses lives in [story-aeneid-delivery.json](/home/t42/Documents/pirate-v2/config/story-aeneid-delivery.json).

## Step JSON Fields

Each step JSON in unsigned mode contains:

| Field | Description |
|---|---|
| `stepIndex` | Sequential step number |
| `stepName` | Human-readable step name |
| `kind` | `create` or `call` |
| `contract` | Solidity contract identifier (for create) |
| `from` | Deployer address |
| `nonce` | Assigned nonce at prepare time |
| `chainId` | Chain ID from RPC |
| `feeModel` | `legacy` or `eip1559` |
| `gasLimit` | Gas limit |
| `gasPrice` | Gas price at prepare time |
| `to` | Target address (`null` for creates) |
| `value` | ETH value |
| `data` | Calldata or creation bytecode |
| `unsignedRawTx` | RLP-encoded unsigned transaction hex |
| `expectedContractAddress` | Predicted CREATE address (for creates) |
| `postCheck` | Postcondition verification rule |
| `dependsOn` | Step dependencies |
| `humanSummary` | Human-readable description |
| `createdAt` | ISO timestamp |

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
- `STORY_CONTRACT_OWNER_PRIVATE_KEY` is only required in hot mode. Treat it as a local-only disposable deploy key, not part of Infisical, not part of Chipotle, and not appropriate for real-funds or real-authority production signing.
- Unsigned mode uses `cast mktx --raw-unsigned` to produce unsigned transactions. Creation bytecode is assembled from compiled artifacts plus ABI-encoded constructor args, then emitted as a proper `CREATE` transaction.
- `render-step-qr.sh` renders the `unsignedRawTx` field directly. It intentionally refuses oversized steps instead of generating a static QR that is unlikely to scan reliably.
