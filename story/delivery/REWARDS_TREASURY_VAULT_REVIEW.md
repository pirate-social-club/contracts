# RewardsTreasuryVault reviewer brief

Status: engineering draft; not approved for deployment.

## Purpose

`RewardsTreasuryVault` separates reward custody from the Lit-controlled transaction signer.
Campaign funders send canonical Base USDC to the vault. The operator can request only bounded
payouts and refunds. A Base Safe owns policy, pause, operator rotation, ownership transfer, and
emergency recovery.

The contract is non-upgradeable, has no proxy, no delegatecall, no arbitrary-call surface, and
does not accept native currency.

## Trust boundaries

- `owner`: a deployed Base Safe. This role can change policy, pause either routine path, rotate
  the operator, recover foreign tokens, and withdraw USDC only while both routine paths are
  paused.
- `settlementOperator`: the Lit-controlled EVM signer. It can invoke only `pay` and `refund`.
- `usdc`: immutable canonical Base USDC supplied at deployment.
- Worker/Lit usage key: outside this contract. Compromise can consume the configured caps but
  cannot change them, rotate authority, recover tokens, or exceed the vault balance.

## State invariants

1. Every nonzero `operationId` can succeed at most once across both payout and refund paths.
2. A successful operation uses the exact current `policyVersion`.
3. A successful operation is not expired, is within its per-transfer limit, and does not exceed
   the relevant epoch cap.
4. Payout and refund epoch accounting are independent so refunds may continue while payouts are
   paused.
5. Failed token transfers roll back the operation-use bit and epoch spending.
6. Policy versions increase strictly, invalidating queued transactions created under old policy.
7. Operator rotation does not move custody or reset replay/cap state.
8. USDC cannot leave through the foreign-token recovery path.
9. Emergency USDC withdrawal requires both payout and refund paths to be paused.
10. Ownership transfer is two-step and must be accepted by the nominated owner.

## API and reconciliation contract

The API must derive `operationId` byte-for-byte from its existing canonical payout or refund
effect ID. The `RewardPaid` and `RewardRefunded` events index that value so reconciliation is a
pure join to the existing effect row.

The Lit action and Worker-side verifier must bind and compare:

- method (`pay` or `refund`);
- vault address;
- operation/effect ID;
- recipient;
- amount;
- deadline;
- policy version;
- signer, chain ID, nonce, transaction type, zero native value, and gas fields.

Funding receipt verification does not change: ERC-20 `Transfer` logs work for contract
recipients.

## Current policy model

The epoch is `block.timestamp / epochDuration`, where `epochDuration` is immutable. This is a
fixed UTC-aligned epoch, not a rolling window. Policy updates change limits prospectively but do
not clear spending already recorded for the current epoch.

Payout and refund limits are separately configurable:

- maximum amount per transfer;
- maximum aggregate amount per epoch.

The vault starts with both paths paused. Deployment is not armed until the Safe explicitly
unpauses the intended path.

## Focused test matrix

| Area | Covered |
|---|---|
| Starts fail-closed | Both paths begin paused |
| Authorization | Stranger rejected; old signer rejected after rotation |
| Replay | Same ID rejected on the same path and across payout/refund |
| Transfer cap | Over-limit transfer rejected |
| Aggregate cap | Third payout rejected after epoch capacity is consumed |
| Separate reserves | Refund capacity remains independent from payout capacity |
| Epoch behavior | Capacity becomes available in the next fixed epoch |
| Deadline | Expired operation rejected |
| Policy version | Wrong version rejected; version must strictly increase |
| Pausing | Refund can continue with payouts paused |
| Emergency recovery | USDC withdrawal requires full pause |
| Foreign assets | Canonical USDC blocked from foreign-token recovery |
| Token failure | False-return transfer rolls back replay and cap state |
| Ownership | Only pending owner can accept two-step transfer |

## Reviewer questions

1. Is a fixed epoch acceptable, or is a rolling-window limiter required despite added state and
   review complexity?
2. Should policy changes require full pause, a timelock, or a delayed activation epoch?
3. Should operator rotation require full pause or delayed activation?
4. Should emergency USDC withdrawal be timelocked in addition to Safe approval and full pause?
5. Should the contract enforce a maximum deadline horizon rather than only expiry?
6. Are separate refund and payout caps sufficient, or should there also be a shared global cap?
7. Is low-level ERC-20 transfer compatibility appropriate for canonical Base USDC, and should
   malformed nonempty return data have a dedicated error?
8. Should ownership cancellation be explicit, or is overwriting `pendingOwner` sufficient?

## Predeployment evidence

- Record compiler, optimizer, source commit, bytecode, constructor arguments, and CREATE2/deploy
  transaction.
- Verify `usdc` equals canonical Base USDC and `owner` equals the intended deployed Safe.
- Verify Safe owners, threshold, modules, guards, fallback handler, and nonce.
- Verify initial operator address against the Lit action/group/PKP evidence.
- Set conservative limits and keep both paths paused through source verification.
- Exercise the full Sepolia test-vault flow before Base mainnet deployment.
- Obtain independent review sign-off and disposition every finding before funding.
