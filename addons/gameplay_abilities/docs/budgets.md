# Performance and Allocation Budgets

Task 11.6 (tasks.md section 11: Verification). Budgets for large-but-bounded
tag, attribute, effect, snapshot, protocol, pending-prediction, and ability
counts, backed by `native/tests/ga_test_budgets.cpp` (test names prefixed
`budget_`). This document is the human-readable companion to that file: what
each test measures, the declared limit, the actual value measured while
writing this document, the headroom, and what to do when a budget is
exceeded.

Cross-references, not duplicated here:
- [`verification.md`](verification.md) for how to run the full suite and
  what every *other* test category proves.
- [`protocol.md`](protocol.md) for the complete `ga_limits.h` constants
  table and the per-`MessageType` byte-limit table — this document only
  repeats the specific numbers each budget test exercises.

## Run it

```bash
scons ga_tests run_ga_tests=yes -j8
scons ga_tests run_ga_tests=yes sanitize=address,undefined -j8
```

Both commands build and run the full `gameplay_abilities_tests` binary,
which includes every `budget_*` test alongside every other suite. Filter to
just the budgets:

```bash
scons ga_tests -j8
addons/gameplay_abilities/native/.build/gameplay_abilities_tests --filter=budget_
```

Every `budget_*` test prints a `[budget] ...` line to stdout with its
measured numbers, independent of pass/fail, so a regression's *magnitude* is
visible in CI logs even when nothing fails outright.

## Why no wall-clock assertion (with one documented exception)

Core forbids a wall clock (`ga_fixed.h`/`ga_tick.h`), and wall-clock timing
assertions are non-deterministic and make CI flaky. Every budget below is
one of:

1. **Allocation count and peak bytes** — via a counting global
   `operator new`/`operator delete` pair installed by
   `ga_test_budgets.cpp` alone, active only inside a scoped `AllocScope`,
   and a transparent pass-through otherwise (see "Sanitizer builds" below
   for the one place this is NOT installed).
2. **Encoded byte size** against the documented `MAX_*_BYTES` constants.
3. **Operation count** (e.g. periodic executions per `advance_to` call, or
   "did an unrelated attribute's revision counter change").

**One exception**, clearly marked `advisory, non-failing` in both the test
name and its printed output:
`budget_attributes_advisory_recompute_scan_cost_vs_system_size` times
`AttributeSet::add_modifier`/`remove_modifier` cycles under two system
sizes and prints the ratio. It **never asserts on the timing** — see
"Findings" below for why this one measurement has no non-timing proxy.

## Sanitizer builds

**The counting allocator is not installed at all under ASan/UBSan.**
This was upgraded from the originally-planned "count but don't assert" plan
after empirical testing on this platform surfaced a worse problem: a
user-installed global `operator new`/`operator delete` is not reliably
given priority over ASan's own runtime allocator for *every* call site.
Some allocations were served by ASan's own `operator new` while this file's
`operator delete` still unconditionally subtracted its own bookkeeping
header, producing `AddressSanitizer: attempting free on address which was
not malloc()-ed` — a crash in an **unrelated** test
(`attr_max_modifiers_capacity_enforced`, not one of this file's own tests),
proving the interaction is a real hazard, not a hypothetical one.

Rather than fight that interaction, `ga_test_budgets.cpp` guards its
`operator new`/`operator delete` overrides (and everything only used by
them) behind `#if !GA_BUDGETS_SANITIZED`, detected via `__SANITIZE_ADDRESS__`
/ `__has_feature(...)`. Under a sanitizer build:
- The allocator is never installed; the binary runs entirely on ASan's own
  instrumented allocator, exactly like every other test file.
- Every `AllocScope`/`AllocStats` value therefore stays at its default (0).
- Every allocation-count/peak-byte **assertion** is compiled out (same
  `GA_BUDGETS_SANITIZED` guard), so nothing fails on a meaningless 0.
- Every **other** assertion in the file — status codes, encoded byte sizes
  against documented limits, record counts, and operation counts like
  periodic-execution counts — stays active unconditionally, since none of
  those depend on this file's allocator.

Verified: `scons ga_tests run_ga_tests=yes sanitize=address,undefined -j8`
builds with zero warnings and all 594 tests (including every `budget_*`
test) pass. The suite count is informational, not itself a budget.

## Caveat: allocation counts are toolchain- and STL-dependent

Every allocation-count number below was measured once, on this environment's
toolchain (Apple Clang, libc++, macOS/arm64), at `-O1`. A different
compiler, standard library, or optimization level can legitimately produce a
different exact count (e.g. `std::function`'s small-buffer-optimization
threshold, or `std::vector`'s growth factor, differ across STL
implementations). Every declared budget below therefore carries **generous
headroom** (often 3-10x the measured value) specifically so this file is a
**regression detector**, not a portability-breaking absolute guarantee. If a
budget assertion starts failing after a toolchain upgrade with no
corresponding code change, raise the constant and note the toolchain change
in the commit — that is the intended, expected maintenance path, not a bug.

## What to do when a budget is exceeded

- **If the measured value grew because of an unrelated code change** (e.g. a
  new modifier field, an extra map, a switch from a flat array to a tree):
  treat it as a **regression**. Investigate why the change needed more
  allocations/bytes/operations than before; most of the time this is an
  accidental complexity change (see "Findings" for two real examples this
  task surfaced) and should be fixed rather than budgeted around.
- **If the measured value grew because a declared limit
  (`ga_limits.h`/`ga_transaction.h`/etc.) was deliberately raised**: raise
  the corresponding budget assertion(s) in `ga_test_budgets.cpp` in the same
  change, with a comment explaining which limit changed and why. Changing a
  `ga_limits.h` constant changes the protocol version per the shared
  contract (section 5) **once the wire format has actually shipped** — that
  reviewer already has to sign off on the wire-contract implications, and
  the budget update should ride along. **Exception, applied by task 11.9**:
  while the protocol is pre-1.0 and has never shipped (see `protocol.md`'s
  "Versioning" / "Pre-1.0 API and Protocol Policy"), there is no
  interoperating peer whose compatibility window would break, so raising a
  `ga_limits.h` constant does not by itself require bumping
  `GA_PROTOCOL_VERSION` — state that reasoning explicitly in the commit
  rather than bumping (or not bumping) it by reflex either way.
- **If a budget is already failing at today's declared maximums** (this
  happened for the full-component snapshot — see Finding 1, now resolved):
  this is not something a test threshold bump alone can fix — it means the
  declared limits themselves are mutually inconsistent and need a real
  design decision (raise `MAX_SNAPSHOT_BYTES`, shrink a per-record encoding,
  or document a *combined* budget below the individual per-subsystem
  maximums). Whichever is chosen, measure the TRUE worst case empirically
  first (a generous, non-truncating `SnapshotWriter`/similar) rather than
  guessing a number, and leave real headroom (task 11.9 used a >= 50%
  minimum) for the sections that have not landed yet.

## Budget table

Every row without a specific declared-limit column asserts a *generous,
this-file-declared* threshold (not a `ga_limits.h` constant) chosen from the
measured value with headroom, per the caveat above.

| Subsystem | Metric | Limit | Measured | Headroom |
|---|---|---|---|---|
| Tags | Mutation batch allocations (512-op batch — task 11.10 raised `MAX_TRANSACTION_UNDO_OPS` to 512, so this is now a single batch from an EMPTY container to MAX_TAG_SOURCES=512, not two 256-op batches) | ≤ 6,000 (declared here) | 1,632 | 3.7x |
| Tags | Mutation batch peak bytes (same batch) | ≤ 2,097,152 (2 MiB, declared here) | 148,112 | 14.2x |
| Tags | Single-transaction batch reaches MAX_TAG_SOURCES (task 11.10 direct proof) | must succeed in ONE `apply_mutations` call/transaction | succeeds; `source_record_count() == 512` | n/a (mechanism proof) |
| Tags | Parent-aware query allocations (2,000 evaluations at MAX_TAG_SOURCES=512) | ≤ 8,000 (declared here; ~4/call) | 2,000 (1.00/call) | 4x |
| Tags | Snapshot bytes at MAX_TAG_SOURCES=512, hierarchy depth 8 | ≤ 131,072 (`MAX_SNAPSHOT_BYTES`) | 6,159 | 124,913 bytes (95.3%) |
| Attributes | Full build allocations (MAX_ATTRIBUTES=128 init + MAX_MODIFIERS=256 add) | ≤ 6,000 (declared here) | 2,968 | 2.0x |
| Attributes | Full build peak bytes (same build) | ≤ 4,194,304 (4 MiB, declared here) | 41,200 | 101.8x |
| Attributes | Snapshot bytes at MAX_ATTRIBUTES/MAX_MODIFIERS | ≤ 131,072 (`MAX_SNAPSHOT_BYTES`) | 14,985 | 116,087 bytes (88.6%) |
| Attributes | Snapshot allocations (same snapshot) | ≤ 4,000 (declared here) | 2,594 | 1.5x |
| Attributes | Single `add_modifier` allocations at MAX_MODIFIERS-1 system total (locality proof) | ≤ 32 (declared here) | 10 | 3.2x |
| Attributes | `add_modifier` per-attribute scan-visit count at MAX_MODIFIERS-1 system total, target has 3 modifiers (task 4.7 direct proof) | **exactly** `3 * target's own modifier count` = 9 (normative, not a headroom budget) | 9 | n/a (exact; independent of system size — see Findings) |
| Effects | `advance_to` periodic-execution count across MAX_ACTIVE_EFFECTS=128 simultaneously-due periodic effects, huge tick jump | **exactly** `MAX_PERIODIC_CATCHUP` = 64 (normative, not a headroom budget) | 64 | n/a (exact) |
| Effects | `advance_to` allocations (same call) | ≤ 6,000 (declared here) | 858 | 7x |
| Effects | Snapshot bytes at MAX_ACTIVE_EFFECTS=128 | ≤ 131,072 (`MAX_SNAPSHOT_BYTES`) | 12,935 | 118,137 bytes (90.1%) |
| Snapshot | Full legacy component fixture (tags+attributes+effects, no tasks) vs `MAX_SNAPSHOT_BYTES` | 131,072 | 34,079 | **under by 96,993 bytes (74.0%)** — see Findings |
| Snapshot | Full component fixture WITH ability grants/executions, no tasks/retained contexts | 131,072 | 39,281 | **under by 91,791 bytes (70.0%)** |
| Snapshot | One retained `TargetEffectContext` (HIT_SET `validated_result` at `MAX_TARGET_HITS`=32, the largest-encoding retained-context shape) — isolated cost, not itself asserted against `MAX_SNAPSHOT_BYTES` | n/a | 2,315 | n/a |
| Snapshot | Full component fixture + `MAX_ACTIVE_ABILITY_TASKS`=32 WAIT_TAG_QUERY tasks, NO retained target contexts (every active effect's own `target_context` absent) | 131,072 | 48,497 | **under by 82,575 bytes (63.0%)** — the non-context baseline `MAX_RETAINED_TARGET_CONTEXT_BYTES` (ga_limits.h) is derived from; see Finding 5 |
| Snapshot | SAME fixture, achievable worst case under the RESOLVED bound: 5 of the 128 active effects retain the 2,315-byte context above (`floor(MAX_RETAINED_TARGET_CONTEXT_BYTES / 2,315)`), the other 123 do not | 131,072 | 60,067 | **under by 71,005 bytes (54.2%)** — see Finding 5 (RESOLVED); the old 128-of-128-retaining, 344,689-byte, 163.0%-over combination is no longer a LEGAL application (rejected at the application-time preflight before ever reaching `write_snapshot`) |
| Snapshot | Target coordinator (`ga::GameplayAbilityWorldCoordinator::write_snapshot`, not the component) at `MAX_ACTIVE_TARGET_SESSIONS`=16, each session holding a submitted 32-hit HIT_SET intent | 131,072 (shared with `MAX_SNAPSHOT_BYTES` via the `TARGET_STATE` message type) | 31,376 | **under by 99,696 bytes (76.1%)** |
| Snapshot | Over-limit workload (`byte_limit=64`) fails generation, not truncation | must fail closed | fails closed; restore of partial bytes also fails | n/a (mechanism proof) |
| Public state | `GameplayAbilityNetworkBridge::encode_public_state` worst case (reconstructed -- see below): `MAX_ATTRIBUTES`=128/`MAX_TAG_SOURCES`=512/`MAX_ABILITY_GRANTS`=64 names each at `MAX_STRING_BYTES`=128, plus `MAX_ACTIVE_ABILITY_TASKS`=32 observable tasks (5,250 of the total) | 131,072 (`MAX_SNAPSHOT_BYTES`) | 97,816 | **under by 33,256 bytes (25.4%)** |
| Targeting | Retained-context application at `MAX_RETAINED_TARGET_CONTEXT_BYTES`: filling to the limit succeeds, one more application fails closed (`CAPACITY_EXCEEDED`/`BYTE_LIMIT_EXCEEDED`) with NO mutation, removing one frees budget for the SAME application to then succeed | must fail closed with structured status; existing state unchanged on rejection | 5 max-size (2,315 B) contexts fill `MAX_RETAINED_TARGET_CONTEXT_BYTES`=12,288; the 6th is rejected; removal + retry succeeds | n/a (mechanism proof) |
| Targeting | Cross-component prepared-batch preflight (`GameplayAbilityWorldCoordinator::prepare_batch`) surfaces the SAME capacity rejection as a per-target outcome under `REQUIRE_ANY` (one target already at its limit is rejected; a second, fresh target still commits) | rejected target: `EFFECT_REJECTED`/`CAPACITY_EXCEEDED`; batch still commits the accepted target | both observed as expected | n/a (mechanism proof) |
| Targeting | `EffectRuntime::restore_snapshot` re-derives the retained-context byte counter from decoded state and rejects a hand-crafted/corrupted snapshot whose retained contexts, summed, exceed `MAX_RETAINED_TARGET_CONTEXT_BYTES` | must fail closed; prior state untouched | fails closed (`CAPACITY_EXCEEDED`/`BYTE_LIMIT_EXCEEDED`); untouched | n/a (mechanism proof) |
| Protocol | Per-`MessageType` encode/decode round-trip at exact byte limit (14 types) | functional pass/fail (no numeric threshold) | bounded allocations per type (see per-type table below) | n/a |
| Protocol | Hostile collection count (60000), raw `ByteReader::read_count` | = 0 allocations | 0 | exact |
| Protocol | Hostile collection count (65535), `TagContainer::restore_snapshot` | ≤ baseline (valid, tiny-count decode) | 1 (baseline = 20) | 20x under baseline |
| Pending predictions | Fill to `MAX_PENDING_PREDICTIONS`=16 with max-shaped entries (cost+cooldown+`MAX_ABILITY_COMMIT_EFFECTS`=8 commit effects each = 11 ops/entry), allocations | ≤ 6,000 (declared here) | 3,744 | 1.6x |
| Pending predictions | Same fill, peak bytes | ≤ 4,194,304 (4 MiB, declared here) | 17,240 | 243x |
| Pending predictions | Same fill, total journaled ops vs `MAX_PREDICTION_JOURNAL_OPS` | ≤ 256 | 176 | 80 ops (31.3%) |
| Pending predictions | `(MAX_PENDING_PREDICTIONS + 1)`th `begin()` at the limit | = 0 allocations (rejected before any mutation) | 0 | exact |
| Pending predictions | `MAX_PREDICTION_AGE_TICKS`=300 sweep expires every still-pending entry | all `MAX_PENDING_PREDICTIONS` expired, journal accepts a fresh `begin()` afterward | 16/16 expired; recovered | n/a (mechanism proof) |
| Abilities | Grant MAX_ABILITY_GRANTS=64 abilities + activate MAX_ACTIVE_EXECUTIONS=32 concurrently, allocations | ≤ 6,000 (declared here) | 1,891 | 3.2x |
| Abilities | Same build, peak bytes | ≤ 4,194,304 (4 MiB, declared here) | 15,856 | 264x |
| Abilities | `AbilityComponent::write_snapshot` bytes at that scale (trivial tag/attribute/effect world — see caveat below) | ≤ 131,072 (`MAX_SNAPSHOT_BYTES`) | 5,233 | 125,839 bytes (96.0%) |

**The 60,067-byte achievable worst case above (row 165) is far over
`MAX_EVENT_BATCH_BYTES` (4,096).** `GameplayAbilityNetworkBridge::
send_owner_event_batch` (`gameplay_ability_network_bridge.cpp`) encodes this
SAME full canonical snapshot as its `EVENT_BATCH` payload every
authoritative tick, so this is exactly the payload size the owner
event-batch path must not attempt to force through the 4,096-byte stream.
It consults `ga::proto::event_batch_fits_stream` (`gap_event_stream.h/.cpp`)
BEFORE calling `AuthoritativeEventStream::append_batch` at all and falls
back to an unconditional full `SNAPSHOT` message (`MAX_SNAPSHOT_BYTES` =
131,072, always enough headroom for this worst case) when the payload
cannot ride the stream — see protocol.md's "Owner event-batch byte budget
and the SNAPSHOT fallback" for the two byte bounds involved and why a naive
unconditional `append_batch` call used to either stall this owner's
replication silently or desync its sequence numbering.

**The "Public state" row (add-observer-task-state-replication-2026-07-27)
is reconstructed, not measured through `encode_public_state` directly** --
that method lives in `native/godot/` (a Godot adapter), outside the
engine-independent `ga_tests` binary's link scope (see that file's own
"Deliberate v1 scope reductions" comment on why gameplay-content adapters
live there). `budget_public_state_worst_case_with_observable_tasks_within_snapshot_bound`
(`ga_test_budgets.cpp`) reproduces `encode_public_state`'s EXACT flat wire
layout -- entity id, tick, then count-prefixed attribute name/value pairs,
tag names, and granted-ability identifiers, every name padded to
`MAX_STRING_BYTES` (the true worst case, not an arbitrary shorter stand-in)
-- with the same primitives (`ga::ByteWriter`/`write_string`/`fixed_write`) a
Godot dependency would otherwise be needed for, then appends the REAL
`ga::proto::encode_observer_task_section` (this addon's actual native
codec -- no stand-in needed for that part) at its own worst case:
`MAX_ACTIVE_ABILITY_TASKS`=32 records, each naming a `MAX_STRING_BYTES`-length
`ability_identifier`. The observable-task section itself costs 5,250 of the
measured 97,816 bytes. Padding every name field to its longest legal length
(not just the task section's) means this fixture's real headroom (25.4%) is
smaller than the full-canonical-snapshot fixtures above (54.2%-96.0%) --
the task 11.9 ">= 50%" convention (see `MAX_SNAPSHOT_BYTES`'s own comment,
`ga_limits.h`) was derived for a different combination and does not apply
here; the declared-here regression-detector threshold (110,000 bytes) is a
generous margin over the measured value instead.

### Per-`MessageType` allocations at exact byte limit

| `MessageType` | Byte limit | Allocations (encode+decode round trip) |
|---|---|---|
| `HANDSHAKE_REQUEST` | 8,192 | 16 |
| `HANDSHAKE_RESPONSE` | 8,192 | 16 |
| `ACTIVATION_COMMAND` | 1,024 | 13 |
| `COMMAND_ACK` | 256 | 11 |
| `COMMAND_REJECT` | 256 | 11 |
| `EVENT_BATCH` | 4,096 | 15 |
| `SNAPSHOT` | 131,072 | 20 |
| `RESYNC_REQUEST` | 256 | 11 |
| `PRESENTATION_EVENT` | 1,024 | 13 |
| `TASK_INPUT_COMMAND` | 1,024 | 13 |
| `TASK_STATE` | 1,024 | 13 |
| `TARGET_COMMAND` | 1,024 | 13 |
| `TARGET_OUTCOME` | 1,024 | 13 |
| `TARGET_STATE` | 131,072 | 20 |

No numeric threshold is asserted on these; they scale trivially with the
frame's own byte count. The test's real assertion is functional:
encode/decode succeeds at exactly the limit and fails one byte over it.

### Delta replication (add-granular-delta-replication-2026-07-27, task 6.4)

Every number below is measured through the REAL `ga::proto::encode_delta_batch`
entry point (`native/tests/ga_test_budgets.cpp`, tests prefixed
`budget_delta_`/`budget_heartbeat_`) — never a hand-estimated byte count —
against the SAME `MAX_EVENT_BATCH_BYTES` (4,096) and `MAX_SNAPSHOT_BYTES`
(131,072) bounds `protocol.md` documents for the owner event-batch stream.

| Composition | Sections touched | Bytes | vs. `MAX_EVENT_BATCH_BYTES`=4,096 |
|---|---|---|---|
| Typical tick: attribute-only (1 of 10 attributes changed, RECORD_OPS) | ATTRIBUTE | 62 | 1.5% |
| Typical tick: effect add+remove (2 of 5 active effects changed, RECORD_OPS) | ACTIVE_EFFECT | 132 | 3.2% |
| Typical tick: ability commit with cost+cooldown (one activation) | ABILITY_GRANT, ACTIVE_EXECUTION, ACTIVE_EFFECT | 239 | 5.8% |
| **Worst case: all 6 `AbilityComponent`-owned sections at documented maxima, single batch, empty baseline (100% churn -> `FULL_REENCODE`)** | ATTRIBUTE, TAG_SOURCE, ABILITY_GRANT, ACTIVE_EXECUTION, ACTIVE_EFFECT, ABILITY_TASK | **48,527** | **11.8x OVER (by design)** |
| Heartbeat, framed (`encode_heartbeat` + `encode_message`) | n/a (no section) | 28 (16 payload + 12 header) | 0.7% |

`budget_delta_worst_case_single_tick_all_sections_at_documented_maxima`
reuses the SAME maximal fixture shape as
`budget_snapshot_full_component_with_abilities_at_declared_maximums`/`..._with_tasks_and_retained_target_contexts_within_byte_budget`
above (tags at `MAX_TAG_SOURCES`=512, attributes at
`MAX_ATTRIBUTES`/`MAX_MODIFIERS`=128/256, effects at
`MAX_ACTIVE_EFFECTS`=128, ability grants at `MAX_ABILITY_GRANTS`=64, active
executions at `MAX_ACTIVE_EXECUTIONS`=32, ability tasks at
`MAX_ACTIVE_ABILITY_TASKS`=32 worst-case `WAIT_TAG_QUERY` requests), then
marks EVERY identity in EVERY one of those six sections dirty in one
assembled batch against an empty `DeltaBaseline` — the honest worst case,
not a synthetic best case: with nothing previously confirmed, every live
record is simultaneously "new," so `choose_delta_section_mode` picks
`FULL_REENCODE` for all six sections automatically (its body is
byte-identical to that section's own snapshot bytes — see `ga_delta.h`'s own
comment), which is exactly what "worst case" means for this codec.
`TARGET_SESSION` (the seventh `ChangeSection`) and
`MAX_RETAINED_TARGET_CONTEXT_BYTES` are deliberately excluded — both are
already independently measured above (the target-coordinator snapshot row
and the retained-context rows) and would only double-measure an
already-documented number, not add a new one.

**The measured 48,527-byte worst case is 11.8x over `MAX_EVENT_BATCH_BYTES`,
by design, not by mistake.** This is exactly the scenario spec's "Worst-case
churn falls back to snapshot" describes: `budget_delta_worst_case_single_tick_all_sections_at_documented_maxima`
also re-attempts the SAME batch against the REAL `MAX_EVENT_BATCH_BYTES`
limit and asserts it fails closed with `StatusCode::PAYLOAD_TOO_LARGE` and an
empty output — mirroring
`budget_snapshot_over_limit_workload_fails_generation_not_truncated`'s proof
for the snapshot path. `GameplayAbilityNetworkBridge::send_owner_event_batch`
consults `event_batch_fits_stream` before ever appending a delta batch and
falls back to a fresh `SNAPSHOT` under `ResyncTrigger::DELTA_OVERFLOW` when it
does not fit — see protocol.md's "Delta payloads" section. The worst case
still stays bounded by the snapshot-fallback path: 48,527 bytes is 37.0% of
`MAX_SNAPSHOT_BYTES`, comfortably inside it, so a `DELTA_OVERFLOW` fallback
snapshot for even this pathological single-tick churn costs no more than any
other full-snapshot resync already budgeted above.

**Design.md's open question — "whether cooldown state warrants its own
section delta or stays folded into grants/effects records" — is resolved by
this data: it stays folded in.** The 239-byte cost+cooldown typical-tick
composition already spans ABILITY_GRANT (the grant's `cooldown_handle`
field), ACTIVE_EXECUTION (the new execution), and ACTIVE_EFFECT (the cost
AND cooldown effects, both newly applied) — three sections this ledger
already tracks, at a small, ordinary RECORD_OPS cost (5.8% of the event-batch
bound). A dedicated COOLDOWN section would not shrink this: cooldown state is
never redundantly encoded today (`ga_change_tracking.h`'s own `ChangeSection`
comment: "a cooldown change is never a fact this ledger could miss by not
having a section of its own for it"), so splitting it out would only add a
seventh section's own framing overhead (an eighth, since `TARGET_SESSION` is
already the seventh) for no byte savings. No restructuring — see Finding 6
below for the ONE real gap this measurement did surface, and its fix.

### Advisory-only (never asserted)

`budget_attributes_advisory_recompute_scan_cost_vs_system_size`: 300
add+remove cycles on one attribute, empty system vs. a system holding
`MAX_MODIFIERS - 2` other modifiers:

| Scenario | Measured before task 4.7 | Measured after task 4.7 (this run) |
|---|---|---|
| Empty system | 120 µs | 127 µs |
| Populated system (254 other modifiers) | 1,170 µs | 161 µs |
| Ratio | 9.75x | 1.27x |

This ratio will vary run to run (wall clock — several runs during task 4.7
verification measured 1.15x-1.27x) — see "Findings" for what the *before*
column demonstrated and why this measurement is never asserted on. The hard,
non-advisory replacement for this property is
`budget_attributes_add_modifier_scan_visits_bounded_by_target_not_system_size`
(see the budget table above): it asserts an EXACT scan-visit count (9) that
is independent of system size, using the new `modifier_scan_visit_count()`
diagnostic instrumentation (`ga_attribute_state.h`) instead of wall-clock
timing. This advisory test is kept anyway as a live sanity check that the
*practical* cost also dropped, not just the theoretical operation count.

## Findings

Three real, present-day characteristics this exercise originally surfaced —
not hypothetical future risks — and how each was resolved by tasks
11.9/11.10/4.7. Each subsection keeps the original measurement (what was
found) followed by the fix and the post-fix measurement (what is true now),
so this remains a legible history rather than silently rewriting the record.

### 1. RESOLVED (task 11.9) — the full canonical component snapshot exceeded `MAX_SNAPSHOT_BYTES` before abilities or predictions added anything

**Original finding:** measured independently (each subsystem against a
generous, non-truncating limit so the number is the true cost, not whatever
a capped writer happened to accumulate before refusing further bytes):

| Subsystem | Bytes at its documented maximum |
|---|---|
| Tags (`MAX_TAG_SOURCES` = 512, hierarchy depth 8) | 6,159 |
| Attributes (`MAX_ATTRIBUTES` = 128, `MAX_MODIFIERS` = 256) | 14,985 |
| Effects (`MAX_ACTIVE_EFFECTS` = 128, periodic) | 12,935 |
| **Total** | **34,079** |
| `MAX_SNAPSHOT_BYTES` (original) | 32,768 |
| **Overage** | **1,311 bytes (4.0%)** |

The "Canonical Full Component Snapshots" requirement
(`specs/gameplay-ability-networking/spec.md`) describes ONE component
snapshot containing attributes, tag sources, granted abilities, active
executions, active effects, and prediction-baseline metadata, all under
`MAX_SNAPSHOT_BYTES`, and its "Snapshot is too large" scenario requires
generation to **fail rather than truncate**. Section 6 (ability
grants/executions) had not landed yet when this was first measured, and task
8.2 (the prediction journal) still has not — so the subsystems that existed
at the time already exceeded the budget on their own, before either of those
sections contributed anything.

`budget_snapshot_full_component_at_declared_maximums_fits_budget` (named
`..._exceeds_budget` before this fix) proved the mechanism correctly failed
closed (returned `PAYLOAD_TOO_LARGE`, never emitted a truncated snapshot)
when this combination was attempted through a real, then-32,768-byte-limited
`SnapshotWriter` — so the *failure mode* was always correct ("refuses"
rather than "silently corrupts"), but it meant the documented per-subsystem
maximums could not simultaneously coexist in one component at all.

**Resolution:** once `native/core/ga_ability_component.h`/`.cpp` (section 6)
existed, task 11.9 measured the TRUE worst case — tags + attributes +
effects + ability grants (`MAX_ABILITY_GRANTS` = 64) + active executions
(`MAX_ACTIVE_EXECUTIONS` = 32), all in ONE `AbilityComponent`, through its
own composed `write_snapshot`
(`budget_snapshot_full_component_with_abilities_at_declared_maximums`):

| Subsystem combination | Bytes |
|---|---|
| Tags + attributes + effects (Finding 1's original combination) | 34,079 |
| Tags + attributes + effects + ability grants/executions (true worst case) | **39,281** |

`MAX_SNAPSHOT_BYTES` was first raised from 32,768 to 65,536 for this
foundation fixture and is **131,072** in protocol 2. The additional room is
for bounded Ability Task and targeting-session snapshot sections, not an
unbounded allocation allowance. The earlier headroom was described as reserved
for "section 8's prediction-baseline metadata (task 8.2, not yet
implemented)" -- now that task 8.2 is fully implemented
(`ga::PredictionJournal`/`ga::PredictingComponent`, `native/core/ga_prediction.h`),
that expectation turns out to have been based on a premise that was never
actually true: the prediction journal is purely CLIENT-SIDE, in-memory,
ephemeral bookkeeping, and is never serialized into
`AbilityComponent::write_snapshot` at all -- confirmed directly by reading
the current implementation (`ga_ability_component.cpp`'s `write_snapshot`
writes only the attribute, tag, effect, grant, and execution sections; no
`PredictionJournal`/pending-prediction section exists or is planned). The
"confirmed baseline" a client reconciles against is just the ordinary
canonical component snapshot; `PredictingComponent`'s journal is rebuilt
locally by re-predicting against that baseline (see
`PredictingComponent::repredict`/`ga_reconciliation.*`), never restored from
bytes. So this headroom was never actually going to be consumed by
prediction-journal metadata -- it remains available in full for other future
fields. Both the abilities-inclusive
fixture and the original tags+attributes+effects-only fixture now fit with
74.0% and 70.0% headroom respectively. Task and target codecs separately
enforce their count, payload, deadline, session, provider-work, and
participant limits. Protocol 2 is the explicit wire compatibility boundary.

### 2. RESOLVED (task 11.10) — `MAX_TRANSACTION_UNDO_OPS` (256, `ga_transaction.h`) silently capped a single `TagContainer::apply_mutations` batch below `MAX_TAG_SOURCES` (512, `ga_limits.h`)

**Original finding:** `TagContainer::apply_mutations` registers exactly one
undo closure per op via the caller-supplied `ga::Transaction`.
`Transaction::add_undo` failed with `StatusCode::CAPACITY_EXCEEDED` past
`MAX_TRANSACTION_UNDO_OPS` = 256 — an addon-internal bound, not part of the
wire contract. A naive single 512-op batch (attempting to fill a container
to its documented per-container maximum in one call) therefore failed
**before ever reaching 512** — it hit the transaction-internal cap at 256
first. 512 was still reachable across two (or more) batches of ≤256 ops
each, but nothing on `TagContainer::apply_mutations` documented that a
*single call* could only ever reach half of `MAX_TAG_SOURCES`.

**Resolution:** of the two options task 11.10 posed (raise the cap, or keep
it and document/diagnose the multi-batch requirement), raising the cap was
the more honest choice: `MAX_TAG_SOURCES` reads as "the largest a container
can hold," and the API's own doc comment on `apply_mutations` already
describes "one atomic batch" without qualifying that a single call could
only reach half the documented maximum — so making the naive expectation
actually true was preferable to formalizing a surprising multi-call
requirement around it. `MAX_TRANSACTION_UNDO_OPS` **and**
`MAX_TRANSACTION_NOTIFICATIONS` (`apply_mutations` also registers one
notification per *changed* op, on the same `Transaction`) were both raised
from 256 to **512**, matching `MAX_TAG_SOURCES` (`ga_transaction.h`). Both
remain addon-internal bounds, not part of the wire contract, so this is not
a protocol-version-affecting change.

`budget_tags_single_transaction_batch_reaches_max_tag_sources` is the direct
proof: a single `apply_mutations` batch of exactly `MAX_TAG_SOURCES` (512)
ops, on an empty container, in ONE transaction, now succeeds and reaches
`source_record_count() == 512`. The existing
`budget_tags_max_sources_deep_hierarchy_mutation_query_and_snapshot_cost`
fixture also changed shape as a side effect: its "largest single mutation
batch" is now a 512-op batch filling an *empty* container (not a 256-op
batch completing an already-256-filled one) — see the updated measured
allocations/peak-bytes in the budget table above.

### 3. RESOLVED (task 4.7) — `AttributeSet::recompute_value`'s internal scan cost was O(total system modifiers), not O(modifiers on the changed attribute)

**Original finding:** `AttributeSet::add_modifier`/`remove_modifier`/`set_base`
each trigger **exactly one** recompute of **exactly one** attribute — this
locality was, and remains, real (verified by
`budget_attributes_add_modifier_recompute_is_localized_not_global`: adding
one modifier never changes any other attribute's revision/current value,
regardless of how many other attributes/modifiers coexist in the same
`AttributeSet`). However, `AttributeSet::recompute_value` called a private
helper, `ordered_modifiers_for`, up to three times per recompute (once per
phase: ADD, MULTIPLY, OVERRIDE), and **each call did a full linear scan of
the entire `modifiers` map** — every modifier on every attribute in the
whole `AttributeSet` — filtering by target attribute as it iterated. There
was no per-attribute index. The scan did not allocate proportionally to map
size (`std::map` iteration touches existing nodes, it does not allocate),
so no allocation-count or operation-count proxy could observe the extra
iteration cost at the time — only wall-clock timing could, measuring
roughly **9-10x** longer for 300 add+remove cycles on one attribute when
the `AttributeSet` also held `MAX_MODIFIERS - 2` (254) other modifiers than
when it was otherwise empty (see the "Advisory-only" table's *before*
column above), even though the target attribute's own modifier count was
identical in both cases — i.e. a shape closer to **O(N × MAX_MODIFIERS)**
than the O(N) "each change only touches its own attribute" locality would
suggest.

**Resolution:** `AttributeSet` (`ga_attribute_state.h`/`.cpp`) now maintains
`modifiers_by_attribute`, a `std::map<DefinitionId, std::vector<ModifierHandle>>`
index from target attribute to exactly the handles of modifiers targeting
it, kept in ascending `ModifierHandle` order (`index_insert`/`index_erase`,
maintained through `add_modifier`, `remove_modifier`, every rollback path,
and rebuilt wholesale in `restore_snapshot` via `rebuild_modifier_index`).
`ordered_modifiers_for` now visits only the target attribute's own bucket,
not the whole component's modifier map — turning the per-recompute scan
into O(modifiers on that attribute), independent of how many other
attributes/modifiers coexist. Aggregation order, phase logic, and
tie-breaking (`priority`, `source`, `effect`, `declaration_index`) are
completely unchanged: the index preserves the exact same ascending-handle
pre-sort order the old whole-map scan produced, so even the documented "tie
across all four keys" edge case behaves identically. **Canonical snapshot
bytes and digests are unaffected** — `write_snapshot`/`canonical_modifier_order`
were not touched, and every existing snapshot test (including the ones in
this file) passes unchanged with byte-identical output.

A new diagnostic-only instrumentation counter,
`AttributeSet::modifier_scan_visit_count()`, now gives a HARD (non-advisory)
proxy for this cost:
`budget_attributes_add_modifier_scan_visits_bounded_by_target_not_system_size`
seeds a target attribute with a small, fixed modifier count, fills every
OTHER attribute up to `MAX_MODIFIERS - 1` system-wide, then asserts the
scan-visit delta for adding one more modifier to the target is **exactly**
`3 * (target's own modifier count)` — 9 in the fixture's case — regardless
of the ~255 other modifiers coexisting in the component. The advisory
wall-clock test's ratio also dropped from ~9.75x to ~1.15x-1.27x post-fix
(see "Advisory-only" above), confirming the practical cost dropped along
with the theoretical operation count. This is a pure internal accelerator,
not an observable state change — `determinism.md`'s guarantees are
unaffected (see that file; nothing it promises depended on
`ordered_modifiers_for`'s scan cost, only on its *output*, which is
unchanged).

### 4. A user-installed global allocator is not safe under this toolchain's ASan

See "Sanitizer builds" above — recorded here too since it is a real,
reproducible finding (not merely a workaround) that anyone else writing a
counting allocator against this test binary should know about: on this
platform, a custom global `operator new`/`operator delete` can silently
lose the allocation/deallocation race against ASan's own runtime allocator
for some call sites while winning it for others, producing a "bad free" in
completely unrelated code. The fix taken here — do not install the override
at all under a sanitizer build — is the safe, simple answer; attempting to
reconcile bookkeeping between two competing allocators is not worth the
complexity for a test-only instrumentation tool.

### 5. RESOLVED — retained `TargetEffectContext` at `MAX_ACTIVE_EFFECTS` scale, combined with `MAX_ACTIVE_ABILITY_TASKS`, did NOT fit `MAX_SNAPSHOT_BYTES`

**Original finding:** Finding 1's "the additional room is for bounded
Ability Task and targeting-session snapshot sections" was asserted, not
measured, until a dedicated fixture (native/tests/ga_test_budgets.cpp)
measured it directly. Folding `MAX_ACTIVE_ABILITY_TASKS` (32) WAIT_TAG_QUERY
tasks (the largest-encoding task kind — every other kind's kind-specific
fields are fixed-size; only a tag query's payload is variable, bounded by
`MAX_TASK_PAYLOAD_BYTES`) into
`budget_snapshot_full_component_with_abilities_at_declared_maximums`'s
39,281-byte world costs only ~9,200 bytes more (48,497 bytes total, exactly
measured — see the budget table's non-context-baseline row — well under
budget) — tasks alone were never the risk. Retained `TargetEffectContext`
values were the problem: turning ON `retain_target_context` for EVERY one of
that SAME fixture's `MAX_ACTIVE_EFFECTS`=128 active effects, each holding
the worst case a retained context can encode (a HIT_SET `validated_result`
at `MAX_TARGET_HITS`=32, independently measured at **2,315 bytes** — see the
budget table), drove the SAME component's TRUE snapshot size to **344,689
bytes** — **163.0% OVER** `MAX_SNAPSHOT_BYTES` (131,072), not under it.

| Combination | Bytes |
|---|---|
| Tags + attributes + effects + ability grants/executions (Finding 1's resolution) | 39,281 |
| + `MAX_ACTIVE_ABILITY_TASKS`=32 WAIT_TAG_QUERY tasks (no retained contexts yet) | 48,497 (exact) |
| + `MAX_ACTIVE_EFFECTS`=128 active effects EACH retaining a 2,315-byte context (the now-ILLEGAL combination) | **344,689** |
| `MAX_SNAPSHOT_BYTES` | 131,072 |
| **Overage (no longer reachable — see Resolution)** | **213,617 bytes (163.0%)** |

The mechanism failed closed exactly as designed even before this was fixed: a
REAL, default-limited `SnapshotWriter` attempting this exact combination
failed with `PAYLOAD_TOO_LARGE` rather than emitting a truncated snapshot,
so no peer could ever have silently received a corrupt canonical snapshot
from this combination. But `retain_target_context` reads as intended for
SPARSE, deliberate use (a handful of gameplay-relevant effects whose
originating aim/hit data needs to survive a resync — e.g. a
damage-over-time effect whose tooltip shows what applied it), not for
"every active effect on a component retains one" — a content author who
enabled it on most/all of a component's concurrent effects, at the largest
schema shape (`HIT_SET` at `MAX_TARGET_HITS`), could genuinely produce a
component whose canonical snapshot could not be generated at all.

**Resolution.** Of the options this document's own "What to do when a
budget is exceeded" guidance posed — raising `MAX_SNAPSHOT_BYTES` further,
capping how many active effects may simultaneously retain a context,
shrinking `MAX_TARGET_HITS` specifically for retained contexts, or
documenting a lower *effective* `retain_target_context` guideline for
content authors — the spec's "Bounded Targeting Work" requirement (bytes
bounds with structured exhaustion results, no silent truncation/partial
mutation) pointed at a fifth: bound the RESOURCE directly (retained-context
bytes), the same way `MAX_ACTIVE_EFFECTS` already bounds effect count,
rather than reshaping an unrelated wire-format constant or narrowing an
unrelated per-value limit. `MAX_RETAINED_TARGET_CONTEXT_BYTES` (12,288,
ga_limits.h) bounds the SUM of every currently-retained
`TargetEffectContext`'s encoded bytes on one component, enforced by
`EffectRuntime` (native/core/ga_effect_runtime.h/.cpp) at
effect-application preflight — BEFORE any mutation, exactly like the
existing `MAX_ACTIVE_EFFECTS` capacity check it sits beside — rather than at
snapshot-encode time. An application that would push the running total past
the limit fails closed with `StatusCode::CAPACITY_EXCEEDED` /
`DiagnosticId::BYTE_LIMIT_EXCEEDED` and changes nothing; removing a retained
effect frees its bytes back for later applications. The counter is
maintained incrementally (updated alongside the SAME `Transaction` undo
closures that already restore `active_effects` on rollback) and re-derived
from scratch (not trusted from the wire) on `restore_snapshot`, which also
rejects a hand-crafted or corrupted snapshot whose retained contexts, summed,
exceed the limit. The cross-component prepared-batch preflight
(`GameplayAbilityWorldCoordinator::prepare_batch`) shares the exact same
check (via `EffectRuntime::prepare_apply`), so a REQUIRE_ANY batch correctly
surfaces the rejection as a per-target outcome rather than failing the whole
batch.

The old 128-of-128-retaining, 344,689-byte combination above is therefore no
longer a LEGAL application at all: the 6th application (of this addon's
2,315-byte worst-case shape) attempting to retain a context on the SAME
component now fails at application time, long before a snapshot is ever
attempted — see
`budget_retained_target_context_application_at_byte_limit_fails_and_removal_frees_budget`
(ga_test_budgets.cpp) for the direct proof. The achievable worst case under
the new bound — 5 of `MAX_ACTIVE_EFFECTS`=128 active effects retaining the
2,315-byte context, the other 123 not (a legitimate sparse-use authoring
pattern) — measures **60,067 bytes**, comfortably within `MAX_SNAPSHOT_BYTES`
with **54.2% headroom** (see
`budget_snapshot_full_component_with_tasks_and_retained_target_contexts_within_byte_budget`,
ga_test_budgets.cpp, and the budget table above).

### 6. RESOLVED (task 6.4) — `grant.cooldown_handle`/`grant.last_command_sequence` mutations never marked `ABILITY_GRANT` dirty

**Original finding:** while building the cost+cooldown typical-tick
composition above, `note_ability_lifecycle_dirty` (`ga_ability_component.cpp`)
turned out to mark only `ACTIVE_EXECUTION` dirty for `PHASE_CHANGED` and
`COMMITTED` lifecycle events — never `ABILITY_GRANT` — even though TWO
mutation sites change the SAME grant record's own fields at exactly those
events: `request_activation` sets `grant.last_command_sequence` at BEGIN
(a `PHASE_CHANGED` event), and `commit_execution_body` sets
`grant.cooldown_handle` at COMMITTED whenever the ability declares a
cooldown effect. Both fields ride `ABILITY_GRANT`'s own delta/snapshot record
(`write_grant_delta_record`/`write_grants_section`) — a peer that already
confirmed a grant's baseline would never learn either mutation through
deltas alone; only a fresh full snapshot happened to carry the correct
value. No existing test exercised this: the pre-existing owner-audience
parity test's own `activate()` helper never set a real `command_sequence`,
and no delta test exercised an ability with a cooldown effect.

**Resolution:** `note_ability_lifecycle_dirty`'s `PHASE_CHANGED` and
`COMMITTED` cases now ALSO mark `ABILITY_GRANT` dirty (via the event's own
`spec`), in addition to `ACTIVE_EXECUTION` — matching every OTHER
over-marking convention this ledger already relies on (`ChangeTracker::
commit_change`'s own "a duplicate identity is harmless, just slightly
wasteful"): every OTHER `PHASE_CHANGED`/`COMMITTED` transition that leaves
the grant untouched pays one harmless extra dirty mark, not a precisely-
conditioned one. `ENDED`/`CANCELLED` stay `ACTIVE_EXECUTION`-only — neither
mutates a grant field. Two regression tests prove the fix: `ga_test_delta_parity.cpp`'s
`delta_parity_owner_audience_grant_cooldown_and_command_sequence_ride_delta`
(digest parity plus a direct field check) and this task's own
`budget_delta_typical_tick_ability_commit_cost_and_cooldown_composition`
(the same composition, verified against a fresh snapshot digest before its
byte count is trusted as a budget number). Reverting the fix and re-running
either test fails it deterministically (`last_command_sequence` decodes as
0, `cooldown_handle` decodes falsy) — confirmed directly during this task,
not merely inferred.

## Pending budgets

- **Pending predictions (`MAX_PENDING_PREDICTIONS` = 16,
  `MAX_PREDICTION_JOURNAL_OPS` = 256), task 8.2 — RESOLVED.** The prediction
  journal (section 8: "per-component command sequences, prediction keys,
  temporary handles, confirmed baselines, and bounded prediction journals")
  is implemented — `ga::PredictionJournal`/`ga::PredictingComponent`
  (`native/core/ga_prediction.h`) have their own dedicated test coverage in
  `ga_test_prediction.cpp`. The dedicated allocation/peak-byte budget test
  was upgraded from the pinned-limits placeholder
  (`budget_pending_predictions_declared_limits_pending_task_8_2`) to a real
  fixture: `budget_pending_predictions_max_shaped_journal_fill_and_overflow`
  drives `MAX_PENDING_PREDICTIONS` real `ga::PredictingComponent::request(...)`
  calls for an ability declaring a prediction-safe self cost, a
  prediction-safe self cooldown, and `MAX_ABILITY_COMMIT_EFFECTS` (8)
  prediction-safe commit effects each — the true structural per-command op
  ceiling (11 ops/entry, 176 total against the 256 bound) — then proves the
  `(MAX_PENDING_PREDICTIONS + 1)`th request fails closed with
  `PREDICTION_JOURNAL_FULL` at exactly 0 additional allocations, and that a
  `MAX_PREDICTION_AGE_TICKS` sweep expires every still-pending entry and
  leaves the journal able to accept a fresh `begin()` again (see the budget
  table above for the measured numbers). Unlike the abilities fixture below,
  this one does NOT fold into
  `budget_snapshot_full_component_with_abilities_at_declared_maximums`'s
  snapshot-byte budget — see "RESOLVED" Finding 1 above: the journal is
  never serialized into a component snapshot at all, so it has no snapshot
  contribution to measure.
- **Abilities (`MAX_ABILITY_GRANTS` = 64, `MAX_ACTIVE_EXECUTIONS` = 32),
  task 6 — RESOLVED mid-session.** `native/core/ga_ability_component.h`
  appeared first (added by the concurrently-working agent implementing
  section 6); `ga_ability_component.cpp` appeared shortly after, making
  `AbilityComponent` linkable. `ga_test_budgets.cpp` checks both files
  independently via `__has_include` (never creating, modifying, or waiting
  on either) and, once both existed, was upgraded from the pinned-limits
  placeholder to a real fixture:
  `budget_abilities_max_grants_and_executions_build_and_snapshot_cost`
  grants `MAX_ABILITY_GRANTS` distinct abilities and drives
  `MAX_ACTIVE_EXECUTIONS` of them concurrently ACTIVE (via
  `ends_on_commit = false`), then budgets the allocation cost of that and
  the byte cost of `AbilityComponent::write_snapshot` at that scale (see
  the budget table above). The fallback pinned-limits-plus-`TODO(task 6)`
  test (`budget_abilities_declared_limits_pending_task_6`) that used to sit
  in the `#else` branch of the same `__has_include` guard, for the
  contingency that either file was ever reverted or replaced, has since been
  removed as stale: `AbilityComponent` has been linkable and load-bearing
  for the rest of this suite (including this very file's other fixtures)
  for a long time, so that branch was unreachable dead code, not a live
  contingency. The `#if GA_BUDGETS_HAVE_ABILITY_COMPONENT` guard itself
  stays (now wrapping four fixtures instead of two), in case a future
  refactor genuinely needs the "is this linkable yet" check again.
  **Caveat**: this fixture's tag/attribute/effect registries are trivial
  (nothing registered) — `AbilityComponent::write_snapshot` also nests
  `attributes().write_snapshot`/`tags().write_snapshot`/
  `effects().write_snapshot`, so the measured 5,233 bytes is the
  grants+executions sections' cost at max scale PLUS near-zero
  tags/attributes/effects, not a combined-with-Finding-1 number. **Update
  (task 11.9)**: the natural next step described here — folding a MAXED-OUT
  tag/attribute/effect world into the SAME `AbilityComponent` instance — is
  now done, in
  `budget_snapshot_full_component_with_abilities_at_declared_maximums`
  (see Finding 1 and the budget table above): 39,281 bytes, comfortably
  under `MAX_SNAPSHOT_BYTES` (131,072).
- **Ability Tasks and retained per-effect `TargetEffectContext` values in the
  canonical component snapshot, and targeting sessions in the coordinator's
  own snapshot — RESOLVED (measured, then bounded).** Finding 1's "the
  additional room is for bounded Ability Task and targeting-session
  snapshot sections" was asserted, not measured, when `MAX_SNAPSHOT_BYTES`
  was raised to 131,072. Two new fixtures closed that gap:
  `budget_snapshot_full_component_with_tasks_and_retained_target_contexts_within_byte_budget`
  folds `MAX_ACTIVE_ABILITY_TASKS`=32 WAIT_TAG_QUERY tasks and, of that SAME
  fixture's `MAX_ACTIVE_EFFECTS`=128 active effects, as many as fit inside
  `MAX_RETAINED_TARGET_CONTEXT_BYTES` retaining a worst-case
  `TargetEffectContext` (the rest not) into the SAME component (see Finding
  5 — tasks alone fit comfortably; retained contexts at
  `MAX_ACTIVE_EFFECTS` scale did not, until `MAX_RETAINED_TARGET_CONTEXT_BYTES`
  bounded them directly), and
  `budget_snapshot_target_coordinator_max_active_sessions_at_declared_maximum`
  measures `ga::GameplayAbilityWorldCoordinator::write_snapshot` — a
  SEPARATE snapshot from the component's own, sharing the same
  `MAX_SNAPSHOT_BYTES` bound via the `TARGET_STATE` protocol message type —
  at `MAX_ACTIVE_TARGET_SESSIONS`=16 sessions, each holding a submitted
  32-hit HIT_SET intent (31,376 bytes, 76.1% headroom; see the budget table
  above).

## Files

- `native/tests/ga_test_budgets.cpp` — the budget tests themselves.
- `addons/gameplay_abilities/docs/budgets.md` — this file.
