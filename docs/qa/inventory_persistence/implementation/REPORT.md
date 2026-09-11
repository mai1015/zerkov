# Task 4.12 — inventory persistence and authority replacement evidence

Status: implementation and acceptance repairs complete; root integration review pending.

Task: `4.12` from `add-zerkov-playable-raid-2026-09-09`.
Implementation baseline: `39dcf3bba9aad7675b0cdf2f9d6925f06aa0d751`.
Engine: Godot `4.7.2.stable.official.ed1daf0bf`.

## Outcome

The implementation adds a fail-closed persistence boundary around the pinned
inventory add-on's public persistence API. Captured records are sealed with
explicit schema, owner, generation, catalogue, native digest, canonical SHA-256
and envelope digest metadata. Restore first proves the supplied record and its
canonical digest byte-exact on a disposable authority. A second disposable pass
then establishes the current live authority's shared item/container/reference
allocator floors and predicts the exact canonical bytes that the public native
restore API will produce. Out-of-band owner-generation and live-state
compare-and-swap guards still run before any live replacement.

A native commit returns a truthful committed receipt: its convergence-aware
canonical bytes and SHA-256 must match preflight exactly to be marked verified;
an impossible post-commit discrepancy is reported as committed/unverified with
recovery required, never as a false atomic rejection after mutation. The saved
record bytes and saved canonical digest remain independently exact even when
current shared allocator floors must converge upward.

Same-ID generation replacement invalidates stale intent ledgers, presentation
controllers/models and equipped-item, reload and ability adapters. Reload
request receipts are retired before an invalidated adapter can replay them.
Projection result journals are scope-generation local, and transaction callbacks
carry their originating generation so a retained old callback cannot poison a
new journal when native command IDs recur after restore. Deferred and re-entrant
work cannot mutate or misreport the replacement generation. Existing inventory
UI and catalogue sources are unchanged.

## Automated results

| Contract group | Programs | Checks | Failures |
| --- | ---: | ---: | ---: |
| persistence/authority/catalogue | 3 | 713 | 0 |
| intent/projection/controller bindings | 4 | 422 | 0 |
| equipped/reload/ability reconciliation | 3 | 861 | 0 |
| mutation/replay/session/identity/clock | 5 | 18,742 | 0 |
| retained inventory and screen UI regressions | 3 | 272 | 0 |
| **Godot total** | **18** | **21,010** | **0** |

All 18 Godot processes exited `0`. Accepted output was scanned for `ERROR:`,
`SCRIPT ERROR:`, `WARNING:`, assertion failures, and ObjectDB/RID/resource leak
diagnostics; there were no matches. The focused final rerun reported:

- persistence replacement: `97` checks, `0` failures, `4` exact round trips;
- projection bridge: `99` checks, `0` failures;
- active reload and replacement: `176` checks, `0` failures;
- ability reconciliation: `562` checks, `0` failures;
- authority replay: `81` checks, `0` failures.

A clean compatibility worktree based on current main `d947b40` (including the
accepted 4.12a source commit `2d50b06`) imported with exit `0` and no diagnostic
matches. The combined catalogue, persistence, reload, authority and projection
contracts reported `994` checks and `0` failures: respectively `543`, `97`,
`176`, `79` and `99` checks. This proves the boundary derives and validates the
new catalogue fingerprint/profile metadata without owning those catalogue files.

The vendored-add-on guard ran through the repository's supported isolated Python
environment: `uv run --with pytest python -m pytest -q
tests/addons/test_vendor_addons.py` produced `4 passed`. Direct system-Python
invocation was unavailable because that interpreter does not contain `pytest`;
this was an environment/tooling miss, not a failed test. Strict change-spec
validation returned `Valid`, and `git diff --check` returned no findings.

## Failure and recovery cases

| Case | Proven result |
| --- | --- |
| duplicate canonical record | idempotent no-op; generation and bindings retained |
| empty, malformed or truncated native bytes | disposable preflight rejects; live authority untouched |
| wrong native schema or sealed catalogue | public add-on status rejects; live authority untouched |
| wrong scope/ID, extra envelope field, bad digest | envelope validation rejects before live mutation |
| forged or stale source generation | cannot authorize replacement; out-of-band generation is required |
| stale live-state digest | compare-and-swap rejects; pending work and bindings remain intact |
| saved allocators below current shared floors | disposable convergence predicts exact live bytes; saved digest stays exact; visible state restores exactly |
| accepted allocator-drift replacement | one verified success receipt; retry is an exact no-op that preserves new bindings |
| post-commit verification discrepancy | receipt remains truthfully committed/unverified with recovery required; boundary retires instead of reporting an atomic failure |
| accepted same-ID replacement | exact predicted bytes/digests restored; old-generation bindings invalidate once |
| queued/deferred UI work | stale model/controller callbacks become inert; replacement state is unchanged |
| active re-entrant intent callback | outer submission unwinds stale; deferred cleanup leaves no request/command ledger |
| active reload during player replacement | native hold and pending reload cancel; request receipts clear; exact old begin intent is rejected without replay |
| retained projection callback | bound old scope generation is ignored and cannot poison the replacement journal |
| restored command ID recurrence | native accepts it as non-replay; projection reaches exact authority revision `5` and canonical bytes |
| owner replacement with colliding numeric IDs | old model and persistence boundary retire; they cannot follow the new owner |
| ability contribution before replacement | effects, executions and attributes revoke synchronously before new generation use |
| raid terminalization | explicit pre-terminal release proves no active ability sources; retained late callbacks are no-ops |

## Scope and remaining integration risks

- The production changes are confined to a new persistence boundary plus small
  lifecycle hooks in the intent, projection, presentation-controller, reload and
  ability adapters. There are no `RaidAuthority`, weapon-instance, vendored
  add-on, UI, catalogue, truth-spec, Forge or task-ledger changes.
- Task 4.12a compatibility is proven on the accepted source commit `2d50b06`;
  the catalogue-owned files remain untouched by this change.
- The unaccepted task 5.2 candidate `4082c51` overlaps
  `game/inventory/equipment/inventory_weapon_adapter.gd`. This repair only
  tightens reload replay validity and clears reload request receipts on
  invalidation; it does not add, delete or bypass weapon registration,
  generation-scoped `unregister_weapon` replay, or weapon-instance cleanup.
  Integration must preserve both changes and rerun the owner-first active-reload
  teardown choreography.
- Task 7.1 composition must call
  `prepare_for_raid_terminalization(...)`, or tear down the owning component,
  before every RaidAuthority terminal transition/failure. This change does not
  claim a new generic RaidAuthority ordering hook; that file is deliberately
  left for the concurrent 5.2 lifecycle work.
- Task 4.11 must wire the already-designed inventory UI to controller
  invalidation/rebinding and expose disconnected/resync presentation states.
  No UI hookup or visual acceptance is claimed here.
- The contracts cover in-memory canonical records. Durable file I/O, crash
  recovery, multiplayer replication, human playtesting and final release
  readiness remain outside task 4.12.

`frozen_sources.sha256` seals the implementation and contract sources reviewed
by this packet. `packet.sha256` seals this report and that source manifest.
