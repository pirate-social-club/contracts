# Pirate Contracts

Solidity workspaces for Pirate.

This repository keeps the active contract code under a single root, with chain-first grouping underneath it.

## Current Layout

- `story/delivery/`
  - locked-asset purchase entitlement, settlement, and access-control contracts
- `rewards/`
  - Megapot ticket-pool escrow, commitment registry, and Safe claim controls

## Why Separate Workspaces

Story delivery and Megapot rewards are independent Foundry workspaces. Keep
their build and deployment commands scoped to the owning directory so a Story
delivery script cannot accidentally discover or deploy rewards controls.

## Non-Goals

This repository is the active Pirate contract surface.

Archived upstream references such as `majeur` and `multisig` live under `references/upstream/` and are not part of this active workspace layout.
