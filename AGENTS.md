# Pirate Contracts — Agent Notes

This file is for agents working inside the `contracts` repo.

## Layout

- `story/delivery/` — locked-asset purchase entitlements, token-gated access, settlement, publish coordination
- `rewards/` — Megapot ticket-pool purchase escrow, commitment publication registry, and Safe claim module

The repo has two independent Foundry workspaces. Run validation and deployment
from the owning workspace; Story delivery scripts must not glob or deploy the
contracts under `rewards/`.

## Validation

```bash
cd story/delivery
rtk forge build
rtk forge test

cd ../../rewards
rtk forge build
rtk forge test
```

## Deployment

Delivery uses `scripts/deploy.sh` with required env vars documented in `story/delivery/scripts/README.md`.

The active Story Aeneid dev deployment addresses are recorded in `core/config/story-aeneid-delivery.json`.

## Non-Goals

This repo is the active contract surface only. Archived upstream references (`majeur`, `multisig`) live under `core/references/upstream/` and are not part of this workspace.
