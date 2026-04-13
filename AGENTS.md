# Pirate Contracts — Agent Notes

This file is for agents working inside `pirate-contracts/`.

## Layout

- `story/delivery/` — locked-asset purchase entitlements, token-gated access, settlement, publish coordination
- `story/scrobble/` — canonical track registration, direct and delegated scrobbles

Both are separate Foundry workspaces. No shared `lib/` or root deploy tooling yet.

## Validation

```bash
cd story/delivery
rtk forge build
rtk forge test

cd story/scrobble
forge build
forge test
```

## Deployment

Delivery uses `scripts/deploy.sh` with required env vars documented in `story/delivery/scripts/README.md`.

The active Story Aeneid dev deployment addresses are recorded in `core/config/story-aeneid-delivery.json`.

## Non-Goals

This repo is the active contract surface only. Archived upstream references (`majeur`, `multisig`) live under `core/references/upstream/` and are not part of this workspace.
