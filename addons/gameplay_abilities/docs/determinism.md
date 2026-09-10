# Determinism Contract

How this addon guarantees that two peers — or two runs on the same peer —
that processed an equivalent history converge to byte-identical state. This
covers the canonical ordering rule, the transaction model, why hash-table
iteration order may never reach output, the snapshot section/digest scheme,
and what the "equivalent state via different histories" guarantee actually
means in practice, with the two honest limitations this addon currently has.

Companion to [`protocol.md`](protocol.md) (wire format, versions, handshake)
and [`verification.md`](verification.md) (how/where this is tested and
CI'd). [`conformance.md`](conformance.md) is the primary evidence for the
guarantee/limitation split this document states in "What is — and is not —
guaranteed" below; that document's cross-subsystem suite is what actually
proves it at scale, and this document does not repeat its scenario-by-
scenario detail. Sourced from `native/core/ga_transaction.h/.cpp`,
`native/core/ga_snapshot.h/.cpp`, `native/core/ga_ids.h/.cpp`,
`native/core/ga_manifest.h/.cpp`, `native/core/ga_fixed.h/.cpp`,
`native/core/ga_tag_container.h/.cpp`, `native/core/ga_attribute_state.h/.cpp`,
`native/core/ga_effect_runtime.h/.cpp`, `native/core/ga_ability_component.h/.cpp`,
`native/tests/ga_test_conformance.cpp`, and the other tests that exercise
them.

## Scope: what this covers today

Every section of tasks.md this document's ordering rule and transaction
model apply to is now implemented: primitives (fixed-point, ticks,
identifiers, runtime handles, transactions, snapshots), gameplay tags,
gameplay attributes, gameplay effects, abilities, the network/protocol
layer's replication (event streams, snapshots, resync), and client
prediction/reconciliation. This document's guarantees are proven by
`native/tests/ga_test_primitives.cpp`, `ga_test_tags.cpp`,
`ga_test_attributes.cpp`, `ga_test_effects.cpp`, `ga_test_abilities.cpp`,
`ga_test_prediction.cpp`, and — at cross-subsystem scale, with intermediate
checkpoints and a pinned cross-run digest fixture — `ga_test_conformance.cpp`.

**The guarantee is not uniformly as broad as the sentence above might
suggest**, though: it holds fully at the primitives/tags/attributes layer
(byte-identical output regardless of live insertion order), but narrows once
effects/abilities/prediction are involved, because those layers serialize
call-order-allocated handles as canonical content. See "What is — and is not
— guaranteed" below for the precise, tested boundary — this is the most
important thing in this document to read accurately rather than skim.

## Canonical ordering rule

Every mutation and every replicated/snapshotted collection is ordered by:

```
(tick, transaction sequence, definition id, runtime handle, declaration index)
```

Two components that reached equivalent state by different histories MUST
produce byte-identical snapshots. This is not a suggestion to sort output
before sending it — it is enforced structurally, at the container level, so
there is no code path that *could* emit unsorted output:

- `IdentifierTable` (definition identity) assigns dense ids at `seal()` time
  by iterating a `std::map<std::string, DefinitionId>` — already in
  ascending byte order regardless of intern order — never at intern time
  when order would depend on content-load order. See `protocol.md`'s
  "Manifest algorithm" section for the full mechanism.
- `ManifestBuilder` stores entries in a `std::map<(ManifestEntryKind, std::string), bytes>`,
  so hashing them for the content-manifest fingerprint already visits
  entries in canonical `(kind, identifier)` order.
- Runtime handles (`EntityId`, `AbilitySpecId`, `EffectHandle`,
  `ExecutionId`, ...) come from `HandleAllocator<T>`, a simple monotonic
  counter starting at 1 (0 reserved for `INVALID_*`) — ordering by handle
  value is ordering by allocation sequence, which is itself deterministic
  per-session because allocation only ever happens inside a transaction.
  **This is also the source of this document's one real limitation** — see
  "What is — and is not — guaranteed" below: a handle's own numeric value is
  allocation-order-dependent, and at the effect/ability layer that value is
  serialized as canonical content, not excluded from it.

`AttributeSet` additionally keeps a `modifiers_by_attribute` index (task
4.7) so a recompute visits only the modifiers targeting the attribute being
recomputed, instead of scanning every modifier in the component. This is a
lookup accelerant only: it does not change aggregation order, phase logic,
tie-breaking, or serialized bytes in any observable way (see
`ga_attribute_state.h`'s own file comment) — it is a budgets/performance
fact, not a determinism one, and is noted here only so it is not mistaken
for a change to the ordering rule.

## Why `unordered_map` iteration order may never reach output

`unordered_map`'s iteration order depends on hash-table internals (bucket
count, insertion history, and — for pointer/address-derived hashes —
process-specific allocator behavior). None of that is guaranteed identical
across two peers, or even across two runs on the same peer, so iterating one
directly to produce wire bytes or a hash digest would silently break the
"different histories, identical bytes" guarantee the instant internal bucket
layout differed. The addon's rule (from the shared implementation contract):
**never iterate an `unordered_map` to produce output — sort into canonical
order first, or use `std::map`/a sorted `std::vector`.**

This is not just a stated rule; it is what the actual state containers do.
`ga_tag_container.h` keeps `exact_owners` as
`std::map<DefinitionId, std::set<SourceToken>>` and `parent_aware_counts` as
`std::map<DefinitionId, std::uint32_t>` — "both levels sorted
(`std::map`/`std::set`), never an `unordered_map`," per that file's own
comment. `ga_attribute_state.h` keeps `attributes` as
`std::map<DefinitionId, AttributeValue>` and `modifiers` as
`std::map<ModifierHandle, AttributeModifier>` for the identical reason.
`gap_identity.h`'s `SessionScope` is the one place this addon *does* use
`unordered_set` (for entity/ability-spec/effect/execution liveness), but
notice what it is used for: pure membership testing (`validate_entity`,
etc.), never iterated to produce ordered output — the rule is about
**iteration order reaching output**, not about hash-table use in general.

## The transaction model

Every mutation goes through `ga::Transaction`
(`ga_transaction.h`/`.cpp`). The model:

1. **Optimistic apply + undo.** Subsystems apply their state changes as they
   go and register an undo closure via `Transaction::add_undo()` for each
   one. If anything later in the same transaction fails,
   `Transaction::rollback()` unwinds every registered undo in **reverse
   (LIFO) registration order**, restoring exactly the pre-transaction state
   — proved by `txn_direct_rollback_runs_undo_in_lifo_order` and
   `txn_rollback_restores_prior_state`.
2. **Post-commit notification.** Change-record dispatch closures are
   registered via `Transaction::add_notification()` but are never invoked
   synchronously by `commit()` — they are handed to a `NotificationQueue`,
   which runs them later via `dispatch()`, strictly *after* the transaction
   that produced them has already committed. Observers therefore never see
   a mutation mid-flight; they only ever see fully-committed state
   (`txn_commit_visibility_and_dispatch_order` proves the ordering).
3. **Reentrant mutations are deferred to a later transaction, never applied
   reentrantly.** `NotificationQueue::is_dispatching()` is true for the
   duration of `dispatch()`. Subsystem code invoked from inside a
   notification callback must check this and, if true, defer any further
   mutation request through `NotificationQueue::request_mutation()` instead
   of mutating state inline. A driver (owned by later sections, not yet
   implemented) periodically drains `take_pending_requests()` and processes
   each as its own new transaction. `txn_mutation_during_dispatch_is_deferred_not_reentrant`
   proves a mutation requested from inside `dispatch()` does not run until a
   later, separate drain — never inside the same `dispatch()` call.
   `NotificationQueue::dispatch()` also defensively no-ops on a reentrant
   call to itself, even though nothing in this addon currently calls it
   that way.

`Transaction::commit()` behaves as `rollback()` whenever the transaction was
marked failed (via `fail()`) before commit — there is no partial-commit
state. `TransactionScope` is the RAII helper that makes "commit unless
failed" the default outcome of leaving a scope, so a caller cannot forget to
finish a transaction one way or the other
(`txn_scope_commits_on_success`, `txn_scope_rolls_back_on_fail`).

`RevisionCounter` bumps exactly once per commit that changes the state it is
attached to (`txn_revision_counter_bumps_once_per_commit`) — tags,
attributes, and effects each keep one so readers can detect "did this
change since I last looked" without diffing full state.

### Every subsystem composes over one caller-supplied `Transaction`

`TagContainer::apply_mutations`, `AttributeSet::add_modifier`/`set_base`,
`EffectRuntime::apply`/`advance_to`, and `AbilityComponent`'s own mutating
entry points all follow the identical shape: a primary API that takes
`(..., Transaction &p_txn, NotificationQueue &p_queue, ...)`, mutates
optimistically, and registers its own undo/notification closures onto the
**caller's** transaction. This means one activation's cost, cooldown,
owned-tag grant, and commit-effect application — spanning `AttributeSet`,
`TagContainer`, and `EffectRuntime` all at once — commit or roll back
*together*, atomically, as a single unit: a failure anywhere in that chain
unwinds every step already applied, including a tag mutation, exactly like
it unwinds an attribute modifier.

This replaces an earlier, narrower discipline (tag batches committing their
own internal transaction eagerly, which required calling code to order tag
mutations *last* so an earlier tag grant could not survive a later step's
failure). `TagContainer` still exposes a standalone convenience overload
—`(..., Tick p_tick, TransactionId p_transaction_id, NotificationQueue
&p_queue, ...)` — that builds and commits its own single-use `Transaction`,
but it is documented as being for a genuinely standalone caller (a test
driving a bare `TagContainer`) only; using it from inside code that is
already composing a larger transaction reintroduces the old bug (that
mutation can never be rolled back by the outer transaction once it returns
`ok()`). `EffectRuntime::advance_to` relies on the same composition: several
due effects processed by one call share one transaction, so an effect
processed earlier in that call is rolled back too if a later one in the
same call fails — not just its attribute/bookkeeping side, its tag removal
as well.

Both the undo list and the notification list are bounded
(`MAX_TRANSACTION_UNDO_OPS` / `MAX_TRANSACTION_NOTIFICATIONS`, **512 each** —
raised from an original 256 by task 11.10, deliberately set to match
`MAX_TAG_SOURCES` rather than some smaller "typical batch" guess: before the
change, a single batch filling a `TagContainer` from empty to its own
documented per-container maximum (`MAX_TAG_SOURCES`, 512) failed closed with
`CAPACITY_EXCEEDED` at the halfway point, which meant reaching the
documented maximum silently required splitting into multiple calls — an
undocumented multi-call choreography `TagContainer::apply_mutations`'s own
API never described. Raising both caps to 512 makes the largest
per-container maximum this addon defines today reachable in exactly the
"one atomic batch" shape the API already promises; see
`budget_tags_single_transaction_batch_reaches_max_tag_sources` in
`ga_test_budgets.cpp`. The queue's own pending-record and
pending-mutation-request lists are bounded at `MAX_QUEUED_NOTIFICATIONS` =
512 and `MAX_PENDING_MUTATION_REQUESTS` = 64) — these are all addon-internal
soft bounds, not part of the wire contract in `ga_limits.h`, but they exist
for the identical reason: one transaction can never accumulate unbounded
memory (`txn_undo_capacity_exceeded`, `txn_notification_capacity_exceeded`,
`txn_notification_queue_enqueue_capacity_exceeded`,
`txn_notification_queue_request_mutation_capacity_exceeded`).

## Snapshot section framing and digest scheme

`SnapshotWriter`/`SnapshotReader` (`ga_snapshot.h`/`.cpp`) are the shared
plumbing every subsystem's own snapshot encoding is built on top of.

- **Section framing**: `begin_section(kind)`/`end_section()` nest up to
  `MAX_SNAPSHOT_SECTION_DEPTH` (8, an addon-internal guard against unbounded
  recursion — not itself part of the wire format, since depth is implicit in
  matched begin/end pairs and never encoded). Every write between a
  `begin_section`/`end_section` pair is buffered so `end_section` can prefix
  it with a self-describing `(kind: u8, length: u32)` header once the length
  is known — a payload cannot be framed before its size exists.
- **The digest is computed identically on write and read, in the exact order
  fields are written/read.** Every `SnapshotWriter::write_*` call folds the
  same bytes into both the output buffer and a running `Hasher`
  simultaneously — a caller can never hash a byte the writer did not also
  serialize, or vice versa. `SnapshotReader::read_*` folds the identical
  sequence into its own `Hasher` as it decodes, so a caller can compare
  `SnapshotReader::digest()` against an expected fingerprint without a
  separate re-hash pass over the raw bytes. A section's `(kind, length)`
  header is hashed at the same two points on both sides: `kind` is hashed
  immediately when a section opens (`SnapshotWriter::begin_section` hashes
  it before any payload write; `SnapshotReader::begin_section` hashes it
  right after reading and validating it, before reading `length`), and
  `length` is hashed when the section closes (`end_section` on both sides) —
  the writer cannot hash `length` any earlier than that because it is not
  known until the payload has already been written and folded into the
  digest.
- **Fails closed on any structural mismatch.** `SnapshotReader::begin_section`
  rejects a decoded kind that does not match the caller's expected kind, and
  rejects a declared length exceeding bytes actually remaining. `end_section`
  rejects if the reader did not consume *exactly* the bytes the matching
  `begin_section` declared — not more, not fewer; a partially-read or
  over-read section is treated as a schema mismatch, never silently skipped
  or reinterpreted.
- **Collections are bounded the same way as the wire codec** (see
  `protocol.md`'s "Canonical codec" section): `write_count`/`read_count`
  validate against both a caller-supplied limit and `MAX_COLLECTION_COUNT`
  before any growth.

## What is — and is not — guaranteed

### The `IdentifierTable`/manifest/tag/attribute layer: order-independent, unconditionally

This is proved, concretely, at every layer below the effect/ability runtime:

- **Identifier assignment**: `ids_canonical_order_independent_of_insertion_order`
  interns `"charlie.one"`/`"alpha.one"`/`"bravo.one"` in one order on one
  table and the reverse order on another, seals both, and shows every
  assigned id, the full `canonical_order()` vector, and the `fingerprint()`
  are identical. `proto_identity_definition_ids_agree_across_independently_built_tables`
  proves the same thing one layer up, through `SessionScope` validation.
- **Content manifest**: `manifest_same_entries_different_order_same_fingerprint`
  proves the same content added in a different order still produces the
  same `ContentManifest::fingerprint`.
- **Tag containers**: `tags_container_snapshot_bytes_and_digest_independent_of_insertion_order`
  (labeled against the networking spec's "Equivalent containers were built
  in different orders" scenario) proves two containers built by applying
  the same ownership grants in different orders serialize to identical
  bytes and hash to an identical digest.
- **Attribute aggregation**: `attr_snapshot_equivalent_state_via_different_histories_identical_bytes_and_digest`
  applies two additive modifiers to the same attribute in opposite
  insertion order across two separate transactions, then shows the
  resulting current value, the full snapshot byte buffer, and the digest
  are all identical between the two runs. `attr_modifier_insertion_order_permutations_identical_result_and_snapshot`
  extends this across every permutation of a larger modifier set, not just
  the two-element reverse case.

At this layer, if two peers (or two runs on one peer) apply an equivalent
*set* of committed mutations to a component — regardless of the wall-clock
order those mutations were requested in, the order concurrent sources
happened to be processed in, or incidental container insertion order — the
resulting canonical snapshot bytes and FNV-1a64 digest are bit-for-bit
identical. This does **not** cover a genuinely different tick sequence, a
different set of commands, or a definition-content difference the content
manifest would have caught first — those are expected to diverge, and
divergence there is exactly what the manifest/handshake compatibility checks
in `protocol.md` exist to catch before gameplay state is even exchanged.

### Guaranteed at cross-subsystem scale (effects, abilities, prediction)

`native/tests/ga_test_conformance.cpp` (see [`conformance.md`](conformance.md)
for the full scenario-by-scenario writeup) proves, across five scenarios
covering stacking, periodic scheduling past `MAX_PERIODIC_CATCHUP`, ability
lifecycle/cooldowns/cancellation, client prediction/ack/reconcile, and all of
those mixed in one component's history:

- **Identical authoritative command/tick sequences produce byte-identical
  `AbilityComponent::write_snapshot` output and FNV-1a64 digests**, verified
  at every intermediate checkpoint (not only the final state) across all
  five scenarios, on two independently-constructed components replaying the
  identical op list.
- **A pinned cross-run digest fixture**:
  `conformance_ability_lifecycle_scenario_cross_run_hash_fixture` asserts
  scenario 3's final digest equals the literal constant
  `kAbilityLifecycleScenarioExpectedDigest = 0x7C63FC6AC342688ULL`, so a
  future change that silently alters canonical encoding fails loudly against
  a fixed baseline, not just against another run of the same (already
  changed) build.
- **Restore-from-snapshot is deterministic**: `conformance_restore_from_snapshot_is_deterministic_regardless_of_which_order_produced_the_bytes`
  proves that once one specific snapshot byte blob exists, restoring it into
  independently-constructed components reproduces bytes identical to each
  other and to the original — this is the guarantee real replication
  actually relies on (every peer restores the *same* bytes the authority
  sent).

### Where the guarantee narrows: call-order-allocated handles as content

**Not guaranteed, and structurally cannot be**: byte-identity for two
components that reached **gameplay-equivalent** state via **different live
insertion orders**, once `EffectRuntime`/`AbilityComponent` are involved.
`EffectHandle`, `AbilitySpecId`, `ExecutionId`, and the tag-granting
`SourceToken` are `HandleAllocator`-assigned by call order (see the
ordering-rule section above) and are serialized directly as canonical
snapshot content — unlike `ModifierHandle`, which `ga_attribute_state.h`
deliberately excludes from both ordering and snapshot content for exactly
this reason.

- `conformance_effect_apply_order_changes_snapshot_bytes_but_not_gameplay_state`
  applies the same two independent effects in opposite live order on two
  components. Both reach the same *gameplay*-observable state (same active
  effect count, same tag ownership) — but their snapshot bytes genuinely
  **differ**, because each effect's `EffectHandle` and its granted tag's
  `SourceToken` are allocation-order-dependent.
- `conformance_ability_grant_order_changes_snapshot_bytes_but_not_gameplay_state`
  proves the identical pattern one layer up: granting the same two abilities
  in opposite order reaches the same granted-ability set, but `AbilitySpecId`
  (also allocation-order-assigned, and serialized in that order inside
  `AbilityComponent::grants`) makes the two components' snapshot bytes
  differ.

**Three delta-spec scenarios were narrowed to match this** (resolves
tasks.md 11.11; see
`docs/spec/changes/add-gameplay-ability-foundation-2026-07-24/
amendment-insertion-order-snapshots.md` for the full rationale and the exact
approved wording) — the original wording required outright byte-identical
snapshots for equivalent state reached by different insertion orders, which
was unsatisfiable once `EffectRuntime`/`AbilityComponent` were involved:

- `gameplay-effects`: "Active effects were inserted in different orders" —
  now requires each component's snapshot to restore to gameplay-equivalent
  state (stack counts, remaining durations, next-period ticks, evaluated
  attributes), **and** a component replaying the identical authoritative
  command/tick sequence to produce byte-identical snapshot bytes and hashes.
- `gameplay-attributes`: "Equivalent state is snapshotted" — now requires
  each component's snapshot to restore to equivalent attribute state (base
  values, evaluated current values, active modifier effects), **and** a
  component replaying the identical authoritative command/tick sequence to
  produce byte-identical snapshot bytes and hashes.
- `gameplay-tags`: "Equivalent containers were built in different orders" —
  now requires each container's snapshot to restore to a container whose
  exact counts and parent-aware query results match the original, **and** a
  container replaying the identical authoritative mutation sequence to
  produce byte-identical snapshot bytes and hashes.

The attribute/tag scenarios above still hold **at the `TagContainer`/
`AttributeSet` layer alone** — their own tests supply the same
`SourceToken`/`ModifierHandle`-equivalent identities externally and vary
only the mutation batch order (see the previous section) — but that
guarantee does not extend through `EffectRuntime`/`AbilityComponent`, which
is where a real game's effects and abilities actually live and where
`SourceToken`/`EffectHandle` identities are assigned internally by call
order rather than supplied externally. That is exactly the gap the amended
wording above accounts for.

**This is a resolved task, per an approved delta-spec amendment — not a
settled-by-fiat or silently-dropped gap.** From `tasks.md`:

> 11.11 Resolve the insertion-order snapshot conformance gap:
> `gameplay-effects` ("Active effects were inserted in different orders"),
> `gameplay-attributes` ("Equivalent state is snapshotted"), and
> `gameplay-tags` ("Equivalent containers were built in different orders")
> each required byte-identical snapshots for equivalent state reached by
> different insertion orders, but `EffectHandle`, `AbilitySpecId`,
> `ExecutionId`, and `SourceToken` are call-order-allocated and serialized
> directly (found by 11.4; proven by
> `conformance_effect_apply_order_changes_snapshot_bytes_but_not_gameplay_state`).
> Resolved by the approved delta-spec amendment
> `amendment-insertion-order-snapshots.md` (2026-07-25): content-derived
> handles were rejected because content-identical stacks still need
> ordinals and handles are cross-message wire references (event-stream
> removals, prediction temp→authority zipping) that renumbering would
> break; the three scenarios now guarantee same-history byte-determinism,
> restore round-trip stability, and gameplay-state equivalence across
> insertion orders, which is what every real snapshot flow (late join,
> reconnect, resync, reconciliation) actually consumes.

Task 11.11 is **resolved**: the amendment was reviewed against the two
options the task originally named — content-derived handles (rejected; see
the amendment's "Why not content-derived handles instead") and a delta-spec
amendment narrowing the guarantee to same-command-sequence replay,
restore-from-snapshot round trips, and gameplay-state equivalence (approved
— this is what the quoted, updated task entry and the scenario wording
above now state). Neither this document nor `conformance.md` made that call
unilaterally; the amendment document records the approved decision, and the
three delta specs named above have already been edited to the wording
quoted above.

**Practical impact**: this narrower guarantee is exactly sufficient for
replication as actually built. A client never independently re-derives
equivalent state through its own diverging history; it always restores the
*specific* bytes the authoritative peer sent (`restore_snapshot`), which is
proven deterministic above. The different-live-order case that does not
hold byte-for-byte is not a scenario the networking protocol ever actually
relies on, and is no longer a gap against the (now-amended) delta specs —
it is exactly what they require.

## Two known limitations

Stated plainly rather than glossed over, per this document's own standard:

1. **The non-`__int128` fixed-point fallback path is compile-only-verified
   on this toolchain.** `fixed_mul_div_round` (`ga_fixed.cpp`) has two
   implementations: an `__int128`-based path, and a portable manual
   128-bit long-multiply/long-divide fallback (`Wide128`/`umul128`/`udiv128`),
   selected at compile time via `#if !defined(__SIZEOF_INT128__)`. Every
   toolchain this addon currently targets — GCC/Clang desktop, Android NDK,
   iOS, and wasm32/Emscripten (per `ga_fixed.cpp`'s own comment) — defines
   `__SIZEOF_INT128__`, so in practice **the fallback path is not compiled
   by any of this addon's currently building configurations**, including
   the macOS toolchain this documentation was written against. It has been
   written and reviewed to produce results bit-for-bit identical to the
   `__int128` path for every input, but no test in `native/tests/` currently
   exercises it, and no CI job forces it to compile by undefining the macro.
   Closing this gap would need either a toolchain that genuinely lacks
   `__int128`, or a build-time override that forces the fallback path to
   compile (and run through the existing `fixed_mul_div_round_property_table`-style
   tests) even where `__int128` is available — neither exists today.
2. **A genuine FNV-1a hash collision path is implemented but not
   unit-testable.** `IdentifierTable::intern()` (`ga_ids.cpp`) checks a new
   identifier's content hash against `hash_index`; if a *different* already-interned
   identifier string happens to share the same 64-bit FNV-1a hash, `intern()`
   fails closed with `StatusCode::DUPLICATE_DEFINITION` and `detail` set to
   the colliding hash, rather than silently favoring one identifier over the
   other. This path exists and is straightforward to read, but constructing
   an actual test for it would require finding two distinct valid identifier
   strings (matching the namespaced-dotted grammar, ≤ 128 bytes, ≤ 8
   segments) that collide under 64-bit FNV-1a — a computationally
   infeasible search to do honestly inside a unit test, and there is no
   dependency-injection seam on `IdentifierTable` to fake a collision
   without also faking the very code path under test. The existing test
   (`ids_intern_duplicate_rejected`) only proves the same-string-twice case;
   the cross-string-collision branch is reviewed by inspection, not proven
   by an executed test.

Neither limitation is a correctness concern found in review — both are
disclosed here because "implemented and reasoned about" is a materially
weaker claim than "covered by a passing test," and this document's mandate
is to say so plainly rather than let the distinction go unstated.
