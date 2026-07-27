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

Existing API payout/refund effect IDs are variable-length strings (for example
`rpe_<32 hex>`), while the vault ABI accepts `bytes32`. The API must therefore derive
`operationId = keccak256(UTF8(exactEffectId))` without case, Unicode, prefix, or whitespace
normalization, while retaining the exact source effect ID as the database join key. The Worker,
Lit Action, and reconciliation path must share fixed cross-language test vectors. The
`RewardPaid`, `RewardRefunded` and `OperationCapacityDeferred` events index that digest so
reconciliation remains a deterministic pure join to the existing effect row.

### Epoch capacity is a deferral, not a failure

An operation that passes every authorization and permanent-failure check but does not fit in the
epoch's remaining capacity **succeeds as an explicit no-op** rather than reverting. It emits
`OperationCapacityDeferred(operationId, kind, epoch)`, moves no funds, leaves
`usedOperations[operationId] == false`, and leaves epoch spending unchanged, so the identical
operation ID succeeds unchanged once the epoch rolls.

This is deliberate and load-bearing. Distinguishing "capacity exhausted" from "permanently
failed" by inspecting a reverted transaction requires `debug_traceTransaction`, which is a
paid, vendor-gated capability. Making settlement correctness depend on it would mean a trace
outage silently reclassifies every capacity deferral as a reconciliation case — under exactly
the load where capacity deferrals occur. Emitting an event moves the classification onto
standard log reads available from any RPC.

Misclassifying a capacity deferral as a permanent failure is a **double-pay hazard**: a
replacement cashout mints a fresh effect ID and therefore a fresh operation ID, which the
vault's replay protection does not block.

Reconciliation therefore recognises exactly three outcomes:

| Receipt | Disposition |
|---|---|
| `RewardPaid` / `RewardRefunded` | confirmed |
| `OperationCapacityDeferred` | non-terminal capacity deferral; retry at the next epoch boundary preserving effect ID and operation ID |
| Reverted, or successful with no matching event | `reconciliation_required` |

Capacity is evaluated **after** every reverting condition, so a paused, stale-policy, replayed,
over-limit, expired or malformed operation still reverts and stays visible even when the epoch
is also exhausted. Only capacity defers.

Operational consequence: a deferred no-op still consumes gas. The coordinator must schedule
retries against the next on-chain epoch boundary rather than a generic timer, and signer-ETH
monitoring must account for deferred no-op gas — a compromised usage key can spam valid no-op
transactions even though it cannot move vault funds.

The Lit action and Worker-side verifier must bind and compare:

- method (`pay` or `refund`);
- vault address;
- operation ID digest and exact source effect ID;
- recipient;
- amount;
- deadline;
- policy version;
- signer, chain ID, nonce, transaction type, zero native value, and gas fields.

The action deliberately makes no RPC or other network calls. It constructs and signs the exact
vault transaction from coordinator-supplied nonce and gas fields after enforcing source-pinned
chain, vault, signer, policy-version, deadline, and gas ceilings. This removes an external RPC
trust anchor from the TEE policy entirely; chain observation, nonce allocation, broadcast, and
finality remain in the Worker coordinator and its independently verified transaction path.

Funding receipt verification does not change: ERC-20 `Transfer` logs work for contract
recipients.

## Current policy model

The epoch is `block.timestamp / epochDuration`, where `epochDuration` is immutable. This is a
fixed UTC-aligned epoch, not a rolling window. Policy updates change limits prospectively but do
not clear spending already recorded for the current epoch.

Payout and refund limits are separately configurable:

- maximum amount per transfer;
- maximum aggregate amount per epoch.

`maxRefund` is not the campaign maximum. Refunds are atomic-exact: a wrong-amount deposit must be
returned in full, including accidental overpayments. Production `maxRefund` must therefore sit
comfortably above any plausible single incoming deposit. An oversize deposit that exceeds it
cannot use the automated path.

The vault starts with both paths paused. Deployment is not armed until the Safe explicitly
unpauses the intended path.

## Oversize-deposit recovery

If an atomic-exact refund exceeds `maxRefund`:

1. freeze new campaign funding and identify the canonical refund effect/operation ID;
2. verify the original transfer, sender, vault recipient, token, chain, and exact amount;
3. prefer a Safe policy transaction that raises `maxRefund` and `refundEpochCap` under a new
   policy version, then let the normal operation-ID-bound refund path execute;
4. if policy expansion is inappropriate, pause both paths, use the Safe emergency withdrawal,
   send the exact manual refund, and record its transaction against the existing refund effect;
5. restore the prior policy under another strictly higher version, recheck solvency/cap state,
   then unpause deliberately.

The manual path needs a two-person decoded-transaction review and must never create a second
operation ID. Reconciliation must mark the existing effect complete only after finality.

## Focused test matrix

74 Foundry tests pass, including 12 vault-specific adversarial tests, 12 covering capacity
deferral and its event payload, and 4 covering the constructor token guard by exact revert
selector. This supersedes the earlier 58-test artifact, which predates the capacity-deferral
change and must not be treated as the reviewed candidate.

| Area | Covered |
|---|---|
| Starts fail-closed | Both paths begin paused |
| Authorization | Stranger rejected; old signer rejected after rotation |
| Replay | Same ID rejected on the same path and across payout/refund |
| Transfer cap | Over-limit transfer rejected |
| Aggregate cap | Third payout deferred as a no-op after epoch capacity is consumed; no funds move |
| Capacity deferral | Operation ID stays unconsumed and epoch spending unchanged |
| Deferral retry | The identical operation ID succeeds unchanged in the next epoch |
| Deferral precedence | Stale policy, expired deadline, replay, over-limit, zero-value and paused operations still revert while capacity is exhausted |
| Refund deferral | Refund capacity defers independently and leaves payout capacity intact |
| Deferral event payload | `expectEmit` asserts emitter, operation ID, operation kind and epoch for both payout and refund |
| Deferral log shape | Exactly one log, emitted by the vault, topic0 = `OperationCapacityDeferred(bytes32,uint8,uint256)`, and no settlement event alongside it |
| Settlement log shape | A settled payout emits `RewardPaid` and never the deferral event |
| Repeated deferral | Retrying in the same epoch emits consistently and never consumes the id, moves funds, or charges capacity |
| Token identity | Constructor rejects a `usdc_` address with no code, so a codeless address cannot silently satisfy `_safeTransfer` |
| ABI stability | `pay`/`refund` selectors unchanged (`0x82cb3a1e`, `0xfc1af099`) so the pinned action CID stays valid |
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

## Owner decisions required before deployment

1. `epochDuration`. It is immutable, so changing epoch granularity requires a new vault and
   funding address. One day is the proposed value for daily-accrual rewards, but the owner must
   accept fixed UTC-aligned epochs and their boundary behavior.
2. `maxPayout` and `payoutEpochCap`.
3. `maxRefund` and `refundEpochCap`, with `maxRefund` intentionally above plausible accidental
   deposits rather than merely above the campaign budget ceiling.
4. Safe signers, threshold, modules/guards, and emergency ceremony.
5. Initial Lit operator and policy version.

## Predeployment evidence

- Record compiler, optimizer, source commit, bytecode, constructor arguments, and CREATE2/deploy
  transaction.
- Verify `usdc` equals canonical Base USDC and `owner` equals the intended deployed Safe.
- Verify Safe owners, threshold, modules, guards, fallback handler, and nonce.
- Verify initial operator address against the Lit action/group/PKP evidence.
- Set conservative limits and keep both paths paused through source verification.
- Exercise the full Sepolia test-vault flow before Base mainnet deployment.
- Obtain independent review sign-off and disposition every finding before funding.
