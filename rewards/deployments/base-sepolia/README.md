# Base Sepolia deployment

`2026-08-14.json` is the canonical public deployment manifest for the active
Megapot ticket-pool controls on chain ID `84532`.

The deployment transaction inputs were checked against the creation bytecode
built from contracts commit `6f812a870662530ba3a974135baab7cbd56a9c34`.
All three creation-bytecode prefixes matched. The runtime hashes in the manifest
were read independently from Base Sepolia after activation.

Public addresses, limits, transaction hashes, and compiler settings belong in
version control. The scheduled API workflow receives the same runtime settings
through its staging configuration, while signer material remains only in
Infisical at `/services/megapot-automation`. Never write or export the signer to
a persistent file.

The manifest records an existing deployment; it does not authorize mainnet use.
Any mainnet deployment requires a separate manifest and explicit approval.
