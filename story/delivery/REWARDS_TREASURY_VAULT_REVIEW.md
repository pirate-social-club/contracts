# RewardsTreasuryVault reviewer brief

Status: owner approval pending. Engineering review is complete for a bounded-float EOA launch;
the owner parameters and approval record below must be completed before Base mainnet deployment.

## Purpose

`RewardsTreasuryVault` separates reward custody from a purpose-built EOA transaction signer.
Campaign funders send canonical Base USDC to the vault. The operator can request only bounded
payouts and refunds. A Base Safe owns policy, pause, operator rotation, ownership transfer, and
emergency recovery.

The contract is non-upgradeable, has no proxy, no delegatecall, no arbitrary-call surface, and
does not accept native currency.

## Trust boundaries

- `owner`: a deployed Base Safe. This role can change policy, pause either routine path, rotate
  the operator, recover foreign tokens, and withdraw USDC only while both routine paths are
  paused.
- `settlementOperator`: a purpose-built EOA with gas only and no other role. It can invoke only
  `pay` and `refund`.
- `usdc`: immutable canonical Base USDC supplied at deployment.
- Worker runtime secret: outside this contract. Compromise can consume the configured caps but
  cannot change them, rotate authority, recover tokens, or exceed the vault balance. Gas
  overpayment is not contract-capped; it is bounded by the deliberately small ETH balance held
  by the settlement EOA.

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
normalization, while retaining the exact source effect ID as the database join key. The
Worker-side EOA builder and reconciliation path must share fixed test vectors. The
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
monitoring must account for deferred no-op gas — a compromised runtime key can spam valid no-op
transactions even though it cannot move vault funds.

The EOA builder and backend-aware preflight must bind and compare:

- method (`pay` or `refund`);
- vault address;
- operation ID digest and exact source effect ID;
- recipient;
- amount;
- deadline;
- policy version;
- signer, chain ID, nonce, transaction type, zero native value, and gas fields.

The Durable Object is the nonce-serialization point. It constructs and signs the exact vault
transaction only after backend-aware preflight confirms that the configured signer equals the
on-chain `settlementOperator`. Chain observation, nonce allocation, fee replacement, broadcast,
and finality remain in the Worker coordinator. Vault address, operator identity, policy version,
deadline, amount limits, replay protection, and chain selection are contract- or
destination-enforced. The former Lit gas ceilings have no on-chain counterpart; that residual
risk is accepted only while the EOA gas float remains deliberately small and depletion and
pending-transaction age are alerted.

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

## Reviewer-question disposition for bounded-float launch

These are explicitly deferred, not unanswered, for a launch whose USDC custody and signer-gas
balances are bounded by the owner-approved ceilings below. Revisit them before either ceiling is
raised past the recorded tripwire.

1. Accept the fixed UTC-aligned epoch; defer a rolling-window limiter.
2. Accept immediate Safe policy changes; use the launch runbook's pause ceremony and defer an
   on-chain timelock or delayed activation.
3. Accept immediate Safe operator rotation; production cutover remains
   pause → rotate → deploy/configure → preflight → unpause.
4. Accept Safe approval plus full pause for emergency USDC withdrawal; defer an additional
   timelock.
5. Accept expiry-only deadline enforcement; defer a maximum deadline horizon.
6. Accept separate payout and refund caps; defer a shared global cap.
7. Accept the existing low-level transfer compatibility for canonical Base USDC and the current
   malformed-return behavior.
8. Accept replacement of `pendingOwner` as cancellation; defer a separate cancellation method.

## Owner decisions required before deployment

1. `epochDuration`. It is immutable, so changing epoch granularity requires a new vault and
   funding address. One day is the proposed value for daily-accrual rewards, but the owner must
   accept fixed UTC-aligned epochs and their boundary behavior.
2. `maxPayout` and `payoutEpochCap`.
3. `maxRefund` and `refundEpochCap`, with `maxRefund` intentionally above plausible accidental
   deposits rather than merely above the campaign budget ceiling.
4. Safe signers, threshold, modules/guards, and emergency ceremony.
5. Initial purpose-built EOA operator address and policy version. The private key must be
   generated without logs or shell history, stored in Infisical as source and a Cloudflare
   secret at runtime, and never recorded in deployment evidence.
6. Maximum USDC vault float and maximum EOA gas float.
7. The balance or weekly-volume tripwire that requires a fresh review of stronger signing,
   timelocks, guardians, and the eight deferred questions above.

## Owner approval record

Complete this block before deployment:

- `epochDuration`: `86400` (one fixed UTC-aligned day)
- `maxPayout`: `25_000_000` (25 USDC)
- `payoutEpochCap`: `30_000_000` (30 USDC/day)
- `maxRefund`: `25_000_000` (25 USDC); the automated refund recipient is
  operator-supplied, so larger mistakes require the fully paused Safe recovery path
- `refundEpochCap`: `25_000_000` (25 USDC/day)
- Safe owners and threshold: 1-of-1 for the bounded launch
- initial policy version: `1`
- maximum vault float: `10_000_000` (10 USDC); refill manually after daily review
- maximum EOA gas float: `0.002 ETH`; alert at `0.0005 ETH`
- hardening/TEE revisit tripwire: any of vault float above 500 USDC, weekly payouts above
  500 USDC, or more than 100 distinct payout recipients in a week
- approver and approval timestamp: **TBD**

Cashout admission currently creates one payout effect for the user's full requested amount; it
does not split a large cashout into multiple capped operations. The 25 USDC `maxPayout` is
therefore the largest cashout that can settle without a policy change.

The 10 USDC float is intentionally smaller than `maxPayout`. A cashout above the available
vault balance will fail on-chain, after which the coordinator marks the payout failed and
releases its allocation; the user's earned balance is not permanently stranded and can be
retried after a manual refill. This failed attempt consumes a small amount of EOA gas. The
bounded launch accepts that behavior instead of adding a vault-liquidity admission check.

Approval statement:

> Approved for Base mainnet deployment only within the vault and gas-float ceilings recorded
> above. The fixed-epoch model and reviewer-question deferrals are accepted for that bounded
> launch. Raising either ceiling past the recorded tripwire requires a new review.

## Predeployment evidence

- Record compiler, optimizer, source commit, bytecode, constructor arguments, and CREATE2/deploy
  transaction.
- Verify `usdc` equals canonical Base USDC and `owner` equals the intended deployed Safe.
- Verify Safe owners, threshold, modules, guards, fallback handler, and nonce.
- Verify the recorded EOA address equals the configured signer and the on-chain
  `settlementOperator`; record only the address in topology evidence.
- Set conservative limits and keep both paths paused through source verification.
- **Satisfied 2026-07-30:** Base Sepolia transaction
  `0x269914970c62c6dee23d8779af33f9b84396260d98f7074fb911ab1309671418`
  settled exactly 5,000,000 atomic USDC through `pay`, emitted `RewardPaid`, used policy version
  2, and consumed 108,550 gas. The transaction sender was the purpose-built EOA
  `0xf536b0DAfD04AE1E5ADB8C170880c7996Fa26c5C`, proving the EOA backend signed an
  accepted vault transaction.
- Obtain independent review sign-off and disposition every finding before funding.
