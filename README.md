# Pirate Social Club Contracts

Solidity workspaces for Pirate Social Club.

This repository keeps the active contract code under a single root, with chain-first grouping underneath it.

## Current Layout

- `story/delivery/`
  - locked-asset purchase entitlement, settlement, and access-control contracts
- `story/scrobble/`
  - track registration and Story-side scrobble contracts

## Why Separate Workspaces

Both active contract areas target Story, but they are still separate Foundry workspaces today:

- different contract surfaces
- different tests and deployment concerns
- no shared `lib/` or root deploy tooling yet

If v2 grows into a larger shared Story workspace later, these can be merged intentionally instead of staying as loose root folders.

## Non-Goals

This repository is the active Pirate Social Club contract surface.

Archived upstream references such as `majeur` and `multisig` live under `references/upstream/` and are not part of this active workspace layout.
