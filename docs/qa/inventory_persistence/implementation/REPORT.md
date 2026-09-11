# Task 4.12 — inventory persistence and authority replacement evidence

Status: implementation complete; integration review pending.

Task: `4.12` from `add-zerkov-playable-raid-2026-09-09`.
Implementation baseline: `39dcf3bba9aad7675b0cdf2f9d6925f06aa0d751`.
Engine: Godot `4.7.2.stable.official.ed1daf0bf`.

## Outcome

The implementation adds a fail-closed persistence boundary around the pinned
inventory add-on's public persistence API. Captured records are sealed with
explicit schema, owner, generation, catalogue, native digest, canonical SHA-256
and envelope digest metadata. Restore first runs against a disposable authority,
then uses out-of-band owner-generation and live-state compare-and-swap guards
before replacing a live authority. A successful replacement is accepted only
when the resulting record is byte-identical to the preflighted canonical record.

Same-ID generation replacement invalidates stale intent ledgers, presentation
controllers/models and equipped-item, reload and ability adapters. Deferred and
re-entrant work cannot mutate the replacement generation. Existing inventory UI
and catalogue sources are unchanged.

## Automated results

| Contract group | Programs | Checks | Failures |
| --- | ---: | ---: | ---: |
| persistence/authority/catalogue | 3 | 689 | 0 |
| intent/projection/controller bindings | 4 | 422 | 0 |
| equipped/reload/ability reconciliation | 3 | 844 | 0 |
| mutation/replay/session/identity/clock | 5 | 18,742 | 0 |
| retained inventory and screen UI regressions | 3 | 272 | 0 |
| **Godot total** | **18** | **20,969** | **0** |

All 18 Godot processes exited `0`. Accepted output was scanned for `ERROR:`,
`SCRIPT ERROR:`, `WARNING:`, assertion failures, and ObjectDB/RID/resource leak
diagnostics; there were no matches. The focused final rerun reported:

- persistence replacement: `73` checks, `0` failures, `4` exact round trips;
- ability reconciliation: `562` checks, `0` failures;
- authority replay: `81` checks, `0` failures.

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
| accepted same-ID replacement | exact bytes/digests restored; old-generation bindings invalidate once |
| queued/deferred UI work | stale model/controller callbacks become inert; replacement state is unchanged |
| active re-entrant intent callback | outer submission unwinds stale; deferred cleanup leaves no request/command ledger |
| owner replacement with colliding numeric IDs | old model and persistence boundary retire; they cannot follow the new owner |
| ability contribution before replacement | effects, executions and attributes revoke synchronously before new generation use |
| raid terminalization | explicit pre-terminal release proves no active ability sources; retained late callbacks are no-ops |

## Scope and remaining integration risks

- The production changes are confined to a new persistence boundary plus small
  lifecycle hooks in the intent adapter, presentation controller and ability
  adapter. There are no `RaidAuthority`, weapon-instance, vendored add-on, UI,
  catalogue, truth-spec, Forge or task-ledger changes.
- Task 4.12a's accepted catalogue metadata commit is newer than this isolated
  branch. The boundary derives catalogue metadata dynamically, but the focused
  suite must be rerun after cherry-pick onto that commit.
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
