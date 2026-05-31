# Pirate Contracts

Solidity workspaces for Pirate.

This repository keeps the active contract code under a single root, with chain-first grouping underneath it.

## Current Layout

- `story/delivery/`
  - locked-asset purchase entitlement, settlement, and access-control contracts

## Why Separate Workspaces

The active contract area targets Story through its own Foundry workspace today.
If v2 grows into a larger shared Story workspace later, that can happen intentionally
instead of accumulating loose root folders.

## Non-Goals

This repository is the active Pirate contract surface.

Archived upstream references such as `majeur` and `multisig` live under `references/upstream/` and are not part of this active workspace layout.
