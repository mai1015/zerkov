# Determinism Conformance Suite

Task 11.1 (coverage audit) and 11.4 (determinism conformance) for the
`add-gameplay-ability-foundation-2026-07-24` change. Companion to
[`determinism.md`](determinism.md) (the ordering rule, transaction model, and
snapshot digest scheme this suite exercises at scale) and
[`verification.md`](verification.md) (how/where this suite is run in CI).
Sourced from `native/tests/ga_test_conformance.cpp` (the only file this
document describes) and the eleven existing `native/tests/ga_test_*.cpp`
files it audits but does not modify.

## 1. Task 11.1 — coverage audit

Task 11.1 requires engine-independent unit and property tests for eleven
areas. Each row below names the test file(s) that already cover it, whether
that coverage is example-based or property-style (a deterministic input table
driving many cases), and an honest gap assessment.

| # | Area | Covered by | Property-style evidence | Gap found |
|---|---|---|---|---|
| 1 | Tags | `ga_test_tags.cpp` (`tags_registry_*` x7, `tags_container_*` x14) | `tags_registry_ids_and_manifest_independent_of_insertion_order` proves id/fingerprint invariance across interning order | None. Registration, auto-ancestor upgrade, namespace-boundary non-matching, atomic batch replace, reentrant deferral, capacity, canonical change-record order, and snapshot order-independence are each individually proven. |
| 2 | Queries | `ga_test_tags.cpp` (`tags_query_*` x12) | `tags_query_normalization_operand_order_independent` / `_dedupes_duplicate_operands` prove normal-form invariance; depth/operand-count boundaries are table-adjacent (exact limit, limit+1) | None. Every clause kind (ALL/ANY/NONE), both match modes, compound nesting, decode validation (oversized node count, over-depth chains), and evaluate-during-notification are each covered. Breadth here is boundary-condition style rather than a combinatorial sweep, but no documented behavior lacks a test. |
| 3 | Fixed-point values | `ga_test_primitives.cpp` (`fixed_*` x12) | `fixed_mul_div_round_property_table` and `fixed_round_floor_ceil_to_int_property_table` are explicit `Case[]` tables covering rounding ties (both signs), zero, div-by-zero, and both overflow boundaries (`INT64_MIN`/`INT64_MAX`) | None. This is the strongest property-style coverage in the suite. |
| 4 | Aggregation | `ga_test_attributes.cpp` (`attr_*` x25) | `attr_modifier_insertion_order_permutations_identical_result_and_snapshot` runs **all 24 permutations** (`std::next_permutation`) of 4 modifiers (2 ADD + 2 MULTIPLY, chosen specifically because MULTIPLY rounding is order-sensitive) and asserts identical current value, bytes, and digest every time | None. ADD/MULTIPLY/OVERRIDE phase order, tie-breakers, clamping (both directions, reporting requested-vs-effective), overflow-preserves-prior-state, and multi-attribute atomic cost batches are each covered. |
| 5 | Stacking | `ga_test_effects.cpp` (`effect_stacking_*` x8) | Example-based, not a combinatorial table | None as a *correctness* gap: REJECT/REFRESH/REPLACE/APPLY_OVERFLOW_EFFECT are each individually proven at the max-stack boundary, plus below-max add, source-scoped group independence, and both removal rules. Property-style breadth is thinner than areas 3/4 (no table sweeping many `max_stacks` values at once), but every documented policy has a directly-named test — padding a table that re-proves the same four policies would not add information. |
| 6 | Ticks | `ga_test_primitives.cpp` (`tick_*` x6) | `tick_seconds_and_ticks_round_trip` is an explicit `Case[]` table across 3 tick rates (10/60/240) and ~15 tick counts including each rate's own boundary | None. Rate validation boundaries, half-away-from-zero rounding (both from seconds and milliseconds), advance overflow, and duration/period validation are each covered. |
| 7 | Transactions | `ga_test_primitives.cpp` (`txn_*` x10, plus every subsystem's own reentrancy tests) | N/A (transaction semantics are not a numeric sweep) | None. Commit visibility/dispatch order, rollback LIFO undo, deferred (never reentrant) mutation during dispatch, revision-counter-once-per-commit, and all four capacity bounds are each proven, matching `determinism.md`'s own description of this subsystem line-for-line. |
| 8 | Abilities | `ga_test_abilities.cpp` (29 tests) | Example-based; `ability_two_activations_same_tick_ordered_by_sequence_then_spec` is a small ordering property | None. Grant/revoke policies, full activation phase sequence, blocking/required tags, cost/cooldown race and atomic commit, exact-tick cooldown boundary, tag-triggered cancellation, idempotent duplicate cancellation, owner teardown, gameplay-event chains bounded by `MAX_EVENT_RECURSION`, passive-on-grant, authority/prediction-safe hooks, reentrant-listener deferral, role enforcement, and a **pre-existing** small-scale repeated-run snapshot-byte test (`ability_repeated_runs_produce_identical_final_snapshot_bytes`) are each covered. |
| 9 | Snapshots | Every file above (`ga_test_primitives.cpp` core writer/reader, plus each subsystem's own `*_snapshot_*` tests) and `ga_test_budgets.cpp` (size-at-maximum) | `tags_container_snapshot_bytes_and_digest_independent_of_insertion_order`, `attr_snapshot_equivalent_state_via_different_histories_identical_bytes_and_digest` | None at the per-subsystem level: framing, fail-closed decode (unbalanced section, mismatched kind, inflated/deflated length, depth bound), and round-trip-restores-state are each proven per subsystem. The genuine gap this audit *did* find — a repeatable, cross-subsystem, checkpointed, run-twice harness with a recorded hash fixture — is exactly what task 11.4 (section 2 below) exists to fill; it is additive, not a duplicate of any existing test. |
| 10 | Protocol | `ga_test_protocol.cpp` (45 tests) | 3 `fuzz_*` tests use `DeterministicRng` with a **fixed seed** (`0x1234ABCDu`) — a reproducible pseudo-random mutation sweep over malformed byte buffers, not a non-deterministic entropy source, so it does not conflict with the addon's "no RNG in authoritative state" rule | None. Envelope round-trip for every message type, every decode rejection path, handshake compatibility mismatches (10 dedicated tests), identity/session-scope validation (9 tests), hostile-count allocation bounds, and decode-never-partially-fills-output are each covered. |
| 11 | Prediction replay | `ga_test_prediction.cpp` (24 tests) | Example-based; one **pre-existing** small-scale determinism test already exists (`predict_determinism_same_command_ack_sequence_identical_snapshot_bytes`) | None. Eligibility (7 rejection variants), full predict→ack→reconcile flow, stale-baseline correction, two-pending-one-corrected-one-replayed, component-local reconciliation scope, restore-failure reporting, journal/op-budget bounds, despawn permanence, reordered/duplicate acks via `FakeTransport`, and tick-estimator drift/snap are each covered. The gap this audit found — a *larger*, multi-checkpoint, run-twice version of the existing determinism test, reusing the exact same proven API — is filled by task 11.4's scenario 4 below. |

**Conclusion: no genuine coverage gap was found in any of the eleven areas.**
Every documented behavior has a directly-named test, and four of the eleven
areas already have real property-style coverage (fixed-point, ticks,
aggregation, and — narrowly — tag/query normalization). Per this task's own
instruction ("a smaller, honest report is far more valuable than padding"),
**`native/tests/ga_test_coverage_gaps.cpp` was not created.** The one
genuinely new thing this audit motivated — a cross-subsystem, checkpointed,
run-twice determinism harness with a recorded hash fixture, at a scale no
existing test attempts — is task 11.4's actual deliverable, described below,
and lives entirely in `ga_test_conformance.cpp`.

## 2. Task 11.4 — the conformance suite

### 2.1 Scripted scenario format

A scenario is a `std::vector<ScenarioOp>` — plain data, no closures, no RNG,
no wall clock. `ScenarioOp::kind` is one of:

| Kind | Effect |
|---|---|
| `GRANT` | `AbilityComponent::grant_ability` |
| `REQUEST` | `AbilityComponent::request_activation` (result recorded even if rejected — a scripted rejection, e.g. a cooldown retry, is a valid deterministic outcome, not a test failure) |
| `COMMIT` | `AbilityComponent::commit_activation` (explicit-commit abilities only) |
| `END` | `AbilityComponent::end_execution` |
| `CANCEL` | `AbilityComponent::cancel_execution` (result not asserted — a scripted duplicate cancellation is expected to report `ABILITY_ALREADY_ENDED`) |
| `APPLY_EFFECT` | `EffectRuntime::apply` directly against the component's own `attributes()`/`tags()`, self-targeted (`source == whatever the op names`, `target == component.entity()`) |
| `REMOVE_EFFECT` | `EffectRuntime::remove_effect` |
| `ADVANCE_TO` | `AbilityComponent::advance_to` (expiration/periodic scheduling, and draining any tag-watcher-deferred cancellation) |
| `EVENT` | `AbilityComponent::handle_gameplay_event` (self-instigated, self-targeted) |
| `CHECKPOINT` | records the current `write_snapshot` digest under a label, without mutating anything |

`ScenarioBuilder` is a fluent, label-based front end (`.grant("dash", ...)`,
`.request("dash1", "dash", ...)`, `.commit("channel1", ...)`, ...) that
resolves symbolic labels to positional indices once, at construction time, so
the resulting `std::vector<ScenarioOp>` a scenario function returns is pure
data reused, unmodified, by every run.

### 2.2 The runner

`run_scenario(AbilityComponent&, const std::vector<ScenarioOp>&)` interprets
the op list against one already-constructed, already attribute-initialized
component, returning the final snapshot bytes, final digest, and every
checkpoint digest (with its label). `run_twice_and_compare` builds **two**
independently constructed `World`+`AbilityComponent` pairs, runs the identical
op list against each, and asserts:

- final bytes are `==`
- final digest is `==`
- every checkpoint digest is `==`, at the **same index** — a mismatch reports
  `checkpoint '<label>' (index N) digest diverged`, so a regression is
  localized to the specific operation range between two checkpoints instead
  of only surfacing as "the final bytes differ somewhere."

The prediction-replay scenario (2.3.4) cannot go through this same generic
runner — `PredictingComponent`/`PredictionReconciler` compose a separate
client-only layer over `AbilityComponent`, not a peer of its own op kinds —
so it is implemented as its own function following the identical "run twice,
compare bytes/digest/checkpoints" shape by hand.

### 2.3 The five scenarios

1. **`conformance_scenario_stacking_heavy_repeated_runs_identical_snapshot`**
   — two effects (`effect.weak_poison`, `effect.strong_poison`) sharing one
   explicit stack key (`combat.poison_dot`) compete for the same 3 stack
   slots from one source; a second, independent source builds its own
   parallel group; a `TARGET_SCOPED` regen effect stacks from two *different*
   sources into the same group; an overflow triggers
   `StackOverflowPolicy::APPLY_OVERFLOW_EFFECT`; one stack is explicitly
   removed (`REMOVE_SINGLE_STACK`); everything is then run to natural
   expiry. Proves: stacking (both scope kinds, shared keys across different
   definitions, overflow-triggered secondary application, partial removal)
   converges byte-identically across two independent runs, with 7
   checkpoints localizing any divergence.
2. **`conformance_scenario_periodic_expiration_large_tick_jumps_repeated_runs_identical_snapshot`**
   — a period-1/duration-250 effect (`effect.long_dot`) alone can produce up
   to 250 due periodic executions, far past `MAX_PERIODIC_CATCHUP` (64); a
   single `advance_to(100)` call is guaranteed to hit the catch-up cap and
   leave due work for the *next* call. Proves: the documented bounded
   catch-up behavior (a capped call leaves a periodic effect's
   `next_period_tick` unchanged so it resumes on the next `advance_to`) is
   itself deterministic across two runs, at 4 checkpoints spanning three
   large tick jumps (0→100, 100→300, 300→1000).
3. **`conformance_scenario_ability_lifecycle_cooldowns_and_cancellations_repeated_runs_identical_snapshot`**
   — Dash's cooldown is checked at tick 11 (still active, rejected) and
   exactly at its exclusive boundary tick 12 (clears); Channel (an
   explicit-commit, `ends_on_commit == false` ability) is committed, then
   cancelled via a `cancel_tags` watcher reacting to a directly-applied Stun
   effect (drained by the next `advance_to`, matching
   `ability_stun_cancels_active_channel_tag_cancel_reason`'s own pattern);
   Channel is granted a second execution and explicitly cancelled, then
   cancelled again to exercise idempotency. Proves: cooldown boundary
   semantics, tag-triggered cancellation, and explicit/idempotent
   cancellation are each deterministic, at 8 checkpoints. **This is also the
   suite's recorded cross-run hash fixture** (2.4).
4. **`conformance_scenario_prediction_replay_repeated_runs_identical_snapshot`**
   — a `NETWORK_CLIENT` component predicts three commands (Dash, then two
   Quick Strikes) via `PredictingComponent::request`; the authority accepts
   Dash (mapping its predicted cooldown handle to a fixed authority handle),
   rejects the first Quick Strike, and never acknowledges the second before
   `PredictionReconciler::reconcile` runs against a baseline captured before
   any prediction — which replays exactly the still-pending second Quick
   Strike, matching the pattern `predict_two_pending_first_corrected_second_replayed_in_order`
   already proves at a smaller scale. Proves: the full predict → ack
   (accept + reject) → reconcile → replay pipeline is deterministic, at 4
   checkpoints.
5. **`conformance_scenario_mixed_all_subsystems_repeated_runs_identical_snapshot`**
   — combines all of the above in one component history: five abilities
   granted (including a `PASSIVE_ON_GRANT` ability whose commit effect and a
   later direct `APPLY_EFFECT` extend the *same* `TARGET_SCOPED` stack group
   from two different origins), a 3-stack shared-key poison group with an
   overflow trigger, an explicit-commit ability cancelled by a directly
   applied Stun effect, a gameplay event triggering a `GAMEPLAY_EVENT`
   ability, a cooldown-and-stun-gated retry, a partial stack removal, and a
   large settling tick jump. Proves: every mechanism above still converges
   byte-identically when they all interact within one component's history,
   at 12 checkpoints.

### 2.4 Cross-run hash fixture

`conformance_ability_lifecycle_scenario_cross_run_hash_fixture` records
scenario 3's final digest as a literal constant:

```cpp
constexpr std::uint64_t kAbilityLifecycleScenarioExpectedDigest = 0x7C63FC6AC342688ULL;
```

A future change that silently alters canonical encoding (field order, a
missing byte, a changed tie-breaker) fails this test loudly with the actual
vs. expected digest, rather than only failing the *other* run-twice tests
(which would still pass as long as both runs of a *changed* encoding still
agreed with each other). **This is the closest thing to the spec's
cross-architecture fixture ("Snapshot fixture runs across platforms",
platform-support spec) that can run inside one process.** A genuine
cross-architecture comparison needs a CI job (task 12.2's declared
desktop/mobile/iOS/Web artifact matrix) that runs this exact scenario on a
second architecture and asserts its digest also equals
`0x7C63FC6AC342688ULL`; this fixture is what such a job would compare against.

### 2.5 Order-independence: verifying the `EffectHandle` limitation is real

`ga_effect_runtime.h`'s own file comment states: "this runtime's own
canonical order — see class file comment on why cross-component,
different-external-call-order byte identity is not claimed for fresh
`apply()` histories, only for `restore_snapshot` round trips." This is now
the approved, amended guarantee (`amendment-insertion-order-snapshots.md`,
resolving tasks.md 11.11) rather than a documented gap against the original
delta-spec wording. Four tests verify it precisely rather than assume it:

- **`conformance_effect_apply_order_changes_snapshot_bytes_but_not_gameplay_state`**
  applies the same two independent effects in opposite live order on two
  components. Both reach the same *gameplay*-observable state (2 active
  effects, identical tag ownership) — but their snapshot bytes genuinely
  **differ** (`GA_EXPECT(bytes_a != bytes_b)`), because each effect's
  `EffectHandle` and its granted tag's `SourceToken` are assigned by
  `HandleAllocator` call order, and `TagContainer::write_snapshot` literally
  serializes the raw `SourceToken` value (`ga_tag_container.cpp`, `write_u64(source.value)`)
  as content — this is not limited to `EffectHandle` alone.
- **`conformance_ability_grant_order_changes_snapshot_bytes_but_not_gameplay_state`**
  proves the identical pattern one layer up: granting the same two abilities
  in opposite order reaches the same granted-ability set, but `AbilitySpecId`
  (also `HandleAllocator`-assigned) makes the two components' snapshot bytes
  differ, since `AbilityComponent::grants` is keyed by `AbilitySpecId` and
  serialized in that (allocation-order-derived) ascending order.
- **`conformance_restore_from_snapshot_is_deterministic_regardless_of_which_order_produced_the_bytes`**
  proves the positive half: given **one already-produced** snapshot byte
  blob, restoring it into two independently-constructed components (matching
  role, different starting entity id — entity id is restored from the
  snapshot; role is deliberately not, per
  `ability_late_join_snapshot_restores_active_execution_without_replay`)
  reproduces bytes identical to each other **and** to the original. This is
  the guarantee real replication actually depends on: every peer restores
  the *same* bytes the authority sent; it never independently re-derives
  equivalent state through a different live history of its own.
- **`conformance_mixed_all_subsystems_snapshot_round_trips_byte_identical_into_fresh_component`**
  proves the same round-trip property against this file's richest fixture —
  the mixed-all-subsystems scenario 2.4 also uses (many stacked/refreshed/
  replaced effects from several sources, granted tags, several abilities
  including a channel cancelled by a blocking tag and a gameplay-event-
  triggered ability, and periodic/expiration catch-up) — rather than only the
  simpler ad hoc construction the previous test uses. Dedicated round-trip
  byte-identity coverage already existed per subsystem too:
  `tags_container_snapshot_round_trip_restores_state_without_notifications`
  (`ga_test_tags.cpp`),
  `attr_restore_snapshot_reproduces_base_current_modifiers_revisions_ordering`
  (`ga_test_attributes.cpp`), and
  `effect_snapshot_restore_round_trip_byte_identical` (`ga_test_effects.cpp`).

## 3. What determinism is — and is not — guaranteed

Stated as precisely as `determinism.md`'s own "Two known limitations"
section, because "reasoned about" and "proven by an executed test" are
different claims:

**Guaranteed, and proven by this suite:**

- Identical authoritative command/tick sequences, replayed into two
  independently-constructed components, produce byte-identical
  `AbilityComponent::write_snapshot` output and FNV-1a64 digest — including
  at every intermediate checkpoint, not only at the end (scenarios 1–5).
- This holds across stacking (both scope kinds, shared stack keys across
  different definitions, all four overflow policies, both removal rules),
  periodic scheduling under `MAX_PERIODIC_CATCHUP`-exceeding tick jumps,
  ability lifecycle (grant/request/commit/cancel, exact cooldown boundaries,
  tag-triggered and explicit cancellation, idempotent duplicate
  cancellation), gameplay events, and the full client prediction/ack/reconcile
  pipeline.
- A specific scenario's digest is pinned to a literal constant (2.4), so a
  silent canonical-encoding change fails loudly instead of only being
  detectable by comparing two runs of the *same*, already-changed build.
- Restoring one already-produced snapshot's bytes into independently
  constructed components is itself deterministic (2.5, third bullet) —
  entity identity round-trips; role does not (by design) and must already
  match for a byte comparison to be meaningful. This is "round-trip
  stability", property 2 of the narrowed guarantee below, and also holds for
  this suite's richest fixture (2.5, fourth bullet).

**The narrowed guarantee (resolves tasks.md 11.11; see
`docs/spec/changes/add-gameplay-ability-foundation-2026-07-24/
amendment-insertion-order-snapshots.md` for the full rationale), proven by
this suite (2.5):**

- Byte-identical snapshots across two components that reached **gameplay-
  equivalent** state via **different live insertion orders** is *not* part of
  the guarantee, and structurally cannot be: `EffectHandle`, `AbilitySpecId`,
  `ExecutionId`, and the tag-granting `SourceToken` are
  `HandleAllocator`-assigned by call order, and each is serialized as literal
  snapshot content (not excluded from it the way `ModifierHandle` deliberately
  is — see `ga_attribute_state.h`'s file comment). Two components that
  granted the same two abilities, or applied the same two effects, in
  opposite live order will disagree on which numeric handle refers to which
  content, and therefore on snapshot bytes, even though every
  gameplay-observable value (attribute current values, tag ownership,
  active-effect count, granted-ability set) agrees — proven, not assumed, by
  2.5's first two tests.
- What the (amended) `specs/gameplay-effects/spec.md`,
  `specs/gameplay-attributes/spec.md`, and `specs/gameplay-tags/spec.md`
  guarantee instead, in place of the original unsatisfiable "byte-identical
  across different insertion orders" wording: (1) same-history byte-
  determinism (the bullets above), (2) restoring a snapshot and
  re-serializing it reproduces byte-identical output regardless of which
  insertion order produced the bytes (2.5's third and fourth tests, plus the
  per-subsystem round-trip tests in `ga_test_tags.cpp`/
  `ga_test_attributes.cpp`/`ga_test_effects.cpp`), and (3) different
  insertion orders reaching equivalent state still restore to
  gameplay-equivalent state, even though the raw bytes MAY differ (2.5's
  first two tests' own gameplay-state assertions).
- This is a real, structural consequence of the addon's own handle-allocation
  design, not a defect. The original delta-spec scenarios required
  byte-identical snapshots across different insertion orders outright, which
  was unsatisfiable as written — `determinism.md` itself already scoped its
  own guarantee to "Sections 2–4... Sections 5 (effects), 6 (abilities), 8
  (prediction)... are not implemented yet" as of when it was written, and
  this document was the place that first disclosed, once those subsystems
  existed, exactly how far the guarantee actually reached for them (before
  any spec text changed). The approved amendment resolves the mismatch by
  narrowing the three scenarios to what this addon actually implements and
  every real snapshot consumer (late join, reconnect, resync, reconciliation
  restore) actually needs — content-derived handles were considered and
  rejected as the alternative fix (see the amendment's "Why not
  content-derived handles instead"). Nothing in `ga_effect_runtime.h`,
  `ga_ability_component.h`, or their tests needed to change: they already
  proved this exact behavior before the amendment existed.
- Practical impact: this narrower guarantee is exactly sufficient for
  replication as actually built. A client never independently re-derives
  equivalent state through its own diverging history; it always restores the
  *specific* bytes the authoritative peer sent (`restore_snapshot`), which
  2.5's third and fourth tests prove is itself perfectly deterministic. The
  different-live-order byte-divergence this suite proves is not a scenario
  the networking protocol ever actually relies on.

## 4. What this suite could not do, and why

- A genuine two-architecture byte comparison (the platform-support spec's
  literal "same fixture runs on two supported architectures" scenario)
  cannot run inside a single process on a single machine. Section 2.4's
  fixture is the artifact such a CI job (task 12.2) would compare; running
  it on a second architecture is out of this task's scope.
- The `__int128`-fallback fixed-point path and the FNV-1a64 hash-collision
  path remain the two limitations `determinism.md` already discloses for
  primitives; this suite does not re-litigate them; nothing here changes
  their status.
- No existing source file was modified to make any test pass — every
  finding above (the handle-order limitation, its exact scope) was verified
  against the current implementation as-is, per this task's rule that a
  real determinism violation is a finding to report, not a test to weaken.
  No genuine *violation* (i.e., a case the addon claims determinism for but
  does not deliver) was found; the one gap between the broad contract
  sentence and the narrower implemented guarantee is a documentation-scope
  finding, not a bug.
