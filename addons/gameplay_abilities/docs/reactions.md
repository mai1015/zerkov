# Tag Reactions

Everything about *when* a declarative `GameplayTagReactionDefinition`
fires, in what order relative to everything else a committed tag
transaction can trigger, who is allowed to run it, and what happens when
it fails — the runtime semantics `authoring.md`'s "Defining a tag
reaction" section deliberately left out. Precision here matters more than
brevity; every claim below is backed by a native test
(`native/tests/ga_test_tag_reaction_runtime.cpp`,
`native/tests/ga_test_tag_reactions.cpp`) and, where the Godot adapter
adds its own behavior, a GDScript integration test
(`tests/gameplay_abilities/integration/test_tag_reactions_runtime.gd`,
`tests/gameplay_abilities/integration/test_catalog.gd`).

Source of truth this document mirrors:
`docs/spec/changes/add-global-tag-catalog-and-reactions-2026-07-25/design.md`
(decisions 3–6) and that same change's
`specs/gameplay-tags/spec.md`, `specs/gameplay-effects/spec.md`, and
`specs/gameplay-ability-networking/spec.md` delta requirements.

## What a reaction is, and is not

A `GameplayTagReactionDefinition` is an immutable, registered definition —
identical in spirit to a `GameplayTagDefinition` or
`GameplayEffectDefinition` — not a live gameplay object. It only exists
inside a `GameplayDefinitionCatalog`'s `tag_reactions` collection (there
is no legacy per-component reaction array). It has four fields:

- a stable namespaced `identifier`;
- an `operand` (`GameplayTagOperand`: one tag identifier plus
  `MATCH_EXACT` or `MATCH_PARENT_AWARE`);
- a `mode`: `MODE_ON_ADDED`, `MODE_ON_REMOVED`, or `MODE_WHILE_PRESENT`;
- an `effect_identifier`, resolved against the same catalog's
  `effect_definitions`.

**V1 reactions always apply their effect from the owning component to
itself.** There is no target selector, no context payload, no
set-by-caller value, and no level — `ga::TagReactionCanonicalDesc`
(`native/core/ga_tag_reactions.h`) has no field for any of them, so there
is nothing to validate or author. A reaction cannot affect any entity
other than the one whose tag changed.

## Predicate edges: the trigger is truth, not a source-count change

A reaction never observes a raw tag-container mutation directly. It
observes its **operand's effective truth value** — `has_exact(tag)` for
`MATCH_EXACT`, `has_parent_aware(tag)` for `MATCH_PARENT_AWARE` — and
only reacts when a committed transaction changes that truth value:

| Mode | Fires when the operand's truth transitions |
|---|---|
| `MODE_ON_ADDED` | false → true |
| `MODE_ON_REMOVED` | true → false |
| `MODE_WHILE_PRESENT` | false → true (apply + bind) **and** true → false (release) — both edges belong to this one mode |

Consequences that follow directly from "truth, not count":

- **First/last source rule.** A tag held by two sources produces exactly
  one false-to-true edge when the *first* source grants it, and exactly
  one true-to-false edge when the *final* source leaves. A second source
  granting an already-true exact tag produces no edge; removing one of
  two remaining sources produces no edge either.
- **Parent-aware descendants follow the same rule.** If a `MATCH_PARENT_AWARE`
  operand is already satisfied by one owned descendant, a second matching
  descendant being added or removed produces no edge — only the
  transition from "no matching descendant" to "one" (added) or "one" to
  "none" (removed) does.
- Every diffed operand's truth **baseline is updated unconditionally**,
  even when a chain bound (below) ends up dropping the resulting edge —
  the underlying tag transaction is always committed regardless of
  whether dispatch was cut short, so truth tracking never falls behind
  reality.

Only reactions whose operand is actually implicated by a transaction's
changed exact tags (the tag itself, for `MATCH_EXACT`; the tag or any of
its ancestors, for `MATCH_PARENT_AWARE`) are even evaluated — this is an
indexed, bounded lookup (`TagReactionRegistry::affected_reactions`), not a
scan of every registered reaction.

## Canonical dispatch ordering

Tag changes commit **before** any reaction runs — reactions are queued
work, never a reentrant callback from inside the tag transaction that
triggered them (the same deferred-queue mechanism blocking-tag ability
cancellation already uses). Within one committed source transaction, every
resulting edge is sorted by, in order:

1. **canonical operand tag identity** (ascending, by the tag's own dense
   registry id — which is assigned in ascending identifier byte order, so
   this is effectively alphabetical by tag identifier);
2. **match mode** — `EXACT` before `PARENT_AWARE`;
3. **reaction mode** — `ON_REMOVED`, then `ON_ADDED`, then
   `WHILE_PRESENT`. A `WHILE_PRESENT` edge keeps this third position
   whether the edge is an apply (false-to-true) or a release
   (true-to-false) — direction never changes where it sorts;
4. **reaction identifier** (ascending), as the final tiebreaker.

This order is entirely content-derived (registry ids, identifiers) —
never hash-table iteration order — so it is byte-identical on every
authority replaying the same transaction, which is exactly what
multiplayer determinism requires.

**Blocking-tag ability cancellation queued by the same committed
transaction always processes before that transaction's reaction
effects.** Both are deferred through the identical queue, but cancellation
work is queued during the notification `dispatch()` call itself, strictly
before `flush_tag_reactions` even runs — so it is already ahead of any
reaction batch in the pending-request list by construction, not by a
priority field.

Every reaction effect application/removal is itself an ordinary effect
transaction — so it can commit its own tag changes, which can trigger
further reactions. Those enter a **later queue batch** (never reentrantly
inside the effect application that caused them) carrying the same bounded
chain context — see "Dynamic chain bound" below.

## Authority-only execution

Only `OFFLINE_AUTHORITY`, `SERVER_AUTHORITY` (listen-server), and
dedicated-server authority evaluate and execute tag reactions. A
`NETWORK_CLIENT`-role component never registers the tag-change observer
reactions need at all (`reactions_enabled` is decided once, at
construction, from `role` and whether a sealed reaction registry was
supplied) — a client cannot independently apply, remove, or predict a
reaction effect from a replicated tag delta in v1. Clients observe only
the ordinary authoritative effect/tag event stream and canonical
snapshots the authority already produces; the reaction itself is never
re-derived client-side.

## `WHILE_PRESENT` binding lifecycle

A `MODE_WHILE_PRESENT` reaction's target effect must validate as
**infinite** (`duration_policy == DURATION_INFINITE`) — an instant or
duration effect cannot be guaranteed to span the complete predicate
interval, so authoring one is a validation failure at `configure()` time
(not at `validate_catalog()` — see `authoring.md`'s "Validation failure
catalog"). A periodic infinite effect is fully supported; `has_period` is
orthogonal to `duration_policy` and follows its own ordinary
authority-owned periodic schedule for as long as the binding stays bound.

- **Apply.** On the false-to-true edge, authority applies the effect
  exactly once (self-target, like every reaction) and binds the returned
  `EffectHandle` against the reaction's own stable identity.
- **Release.** On the matching true-to-false edge, authority removes
  **exactly that bound handle**, once, and clears the binding
  unconditionally (whether or not the removal itself succeeded — there is
  no "later edge" for a true-to-false transition to retry from; only a
  future false-to-true edge starts a new predicate interval).
- **Failed application.** If the apply fails a requirement, immunity, or
  other preflight check, **no binding and no partial effect state is
  created**, and the runtime does not retry continuously while the
  predicate stays true — only a later false-to-true edge tries again. A
  `TagReactionDiagnosticEvent{kind = APPLICATION_FAILED}` is emitted (see
  "Observing reactions from GDScript" below for how far that currently
  reaches).
- **Externally removed handle.** If something other than this reaction's
  own true-to-false edge removes the bound effect first (e.g. a stacking
  policy replacing it, or explicit game-layer removal), the eventual
  true-to-false edge finds `effect_runtime.has_effect(handle) == false`.
  It does **not** attempt removal and does **not** recreate the effect —
  it clears the stale binding and emits
  `TagReactionDiagnosticEvent{kind = STALE_HANDLE_CLEARED, status = ok_status()}`.
  Unrelated tags, attributes, and effects are untouched.
- A false-to-true edge defensively refuses to double-apply if a binding
  somehow already exists for that reaction id (unreachable in normal
  operation — a false-to-true edge only ever fires when the baseline was
  false, and the paired true-to-false edge always erases its own binding
  first).

## Validation and cycle safety

Two independent layers guard against a reaction chain that could
retrigger itself forever — one static (authoring-time), one dynamic
(runtime, for what static analysis cannot see):

### Static cycle rejection

At `configure()` time (see `authoring.md`), `TagReactionRegistry::seal`
builds a conservative directed graph: an edge exists from reaction A to
reaction B when A's target effect's `granted_tags` contains a tag that
satisfies B's operand (match-mode-aware — an `EXACT` operand needs the
identical tag; a `PARENT_AWARE` operand accepts the operand tag or any
descendant). A deterministic depth-first walk, in ascending reaction-id
order, rejects the **first** cycle reachable — including a **length-one
self-loop**: a reaction whose own target effect grants a tag matching its
own operand. (This is exactly why a `WHILE_PRESENT` reaction can never
latch its own predicate permanently true — the authoring shape that would
do that is rejected before any component runtime exists.) The resulting
`reaction_cycle` finding names the whole involved reaction/effect path,
e.g. `reaction.a (effect.a) -> reaction.b (effect.b) -> reaction.a` — the
repeated closing entry makes the loop visible even for a self-loop
(`{ identifier, identifier }`).

### Dynamic chain bound

Static analysis cannot see authority hooks or other dynamic effect
behavior, so the runtime separately tracks a **reaction-chain depth and
path** across generated tag transactions. The first reaction batch
triggered by a non-reaction-caused transaction runs at depth 1; each
edge's own effect application runs one hop deeper than the batch it came
from (siblings within one batch each start their own subtree at the same
depth, they do not accumulate across each other). The bound is checked
**at schedule time**, before a batch already at or past the limit is even
enqueued — so the diagnostic fires exactly once for the whole stopped
batch, naming the chain that led there, and nothing in that batch runs.

The default bound is `ga::MAX_REACTION_CHAIN_DEPTH = 8`
(`native/core/ga_ability_component.h`). `ga::AbilityComponent`'s
constructor accepts an override, but the Godot adapter
(`native/godot/gameplay_ability_component.cpp`) always constructs with
the default — **every Godot-configured component uses 8**; there is no
exposed `GameplayAbilityComponent` property to change it (see
`authoring.md`'s "Known gaps").

Exceeding the bound stops only the remaining chain (already-committed tag
and effect transactions from earlier in the chain stay committed) and
emits one `TagReactionDiagnosticEvent{kind = CHAIN_LIMIT_REACHED}`
carrying the stable reaction-identifier path from the chain's root.
Reentrant callbacks cannot bypass the bound: every reaction batch, at
every depth, enters the same deferred queue.

## Isolated failure semantics

Each triggered effect application or removal uses the existing atomic
effect-transaction contract. A failure:

- creates no partial effect/tag state (the failed apply/remove's own
  transaction is rolled back via the normal `TransactionScope` contract);
- **never rolls back the original triggering tag transaction** — that
  transaction was already committed before any reaction ran;
- **never suppresses the rest of the same canonically-ordered batch** —
  if two `ON_ADDED` reactions are queued together and the first fails
  immunity, the second still executes in its canonical position; and
- always produces exactly one bounded `TagReactionDiagnosticEvent`
  (`APPLICATION_FAILED`, carrying the underlying `Status`).

## Teardown

A torn-down component's teardown-induced tag edges (e.g. effect-granted
tag sources removed as part of tearing down) never dispatch reaction
work — `flush_tag_reactions` checks `torn_down` before even accumulating
pending tags. Any reaction batch already queued when teardown begins is
**discarded without applying any effect**, checked both before the batch
starts and again between each edge within it (teardown can begin partway
through a batch, e.g. from a sibling edge's own effect commit).

## Snapshot and restore: no replay

Canonical component snapshots (`GameplayAbilityComponent.write_snapshot`)
include every currently active `WHILE_PRESENT` binding as
`{reaction identity, bound authority EffectHandle}` pairs, restored
alongside active effects. Restoring:

- **validates every binding** before any partial restoration — an unknown
  reaction identity, a reaction whose registered mode is not
  `WHILE_PRESENT`, an effect handle the restored `EffectRuntime` does not
  recognize as active, or an active handle whose definition does not
  match that reaction's own registered target effect are all rejected
  (`DiagnosticId::INVALID_REACTION_BINDING`, paired with
  `UNKNOWN_DEFINITION`/`UNKNOWN_EFFECT_HANDLE`/`INVALID_REFERENCE`
  depending on which check failed) — the existing
  resynchronization/incompatibility policy then applies, exactly like any
  other snapshot rejection;
- **never emits a historical tag predicate edge and never replays
  `ON_ADDED`/`ON_REMOVED`** — restoring a snapshot in which a reaction
  operand was already true does not retroactively fire that reaction's
  `ON_ADDED` effect a second time, and restoring an active
  `WHILE_PRESENT` binding does not re-apply a duplicate effect instance;
  it reattaches the binding to the already-restored effect handle;
- **reinitializes every reaction operand's truth baseline from the
  restored tag state**, exactly once, immediately after binding restore
  (`AbilityComponent::reinitialize_tag_reaction_baselines`) — so the
  *first* transaction committed after restore diffs against the restored
  values, not a stale pre-restore baseline. A transaction that changes
  nothing produces no edge; a transaction that removes the final matching
  source of an already-true operand produces exactly one true-to-false
  edge, same as normal operation.

This is what makes late join, reconnect, resync, and prediction rollback
safe: a late-joining client's snapshot restore produces one matching
mirror of an already-active effect, never a duplicate; an authority
resynchronizing from a snapshot ends up with a genuinely live binding
whose *next* true-to-false edge removes the exact restored handle exactly
once.

`reinitialize_tag_reaction_baselines()` is also called once, unconditionally,
right after a fresh (non-restored) `configure()` — at that point the tag
container is genuinely empty, so this is a cheap no-op that exists purely
as defense-in-depth so initial state can never itself produce a spurious
edge.

## Manifest fingerprinting

Every reaction's canonical fields — `identifier`, `operand.tag`,
`operand.match_mode`, `mode`, `effect_identifier` — contribute to the
content-manifest fingerprint under `ManifestEntryKind::REACTION` (value
6), keyed by `identifier` exactly like every other manifest contribution
(`ga::contribute_tag_reaction_manifest`,
`native/core/ga_tag_reactions.h`). Two catalogs with the same reactions in
a different authored array order still produce an identical fingerprint;
any one canonical field differing (a different trigger tag, match mode,
reaction mode, or target effect for the same reaction identity) changes
it. A legacy component with no catalog contributes no `REACTION` manifest
entries at all — its fingerprint is unaffected by this change.

**Why this matters for multiplayer**: the existing manifest handshake
(`protocol.md`'s "Handshake compatibility matrix") already fails a
session outright on any fingerprint mismatch. A client whose catalog
declares `ON_ADDED` for a reaction identity the server declares
`WHILE_PRESENT` for the same identity — or any other reaction field
mismatch — is rejected at the handshake, before any component gameplay
begins; it can never observe a divergent reaction outcome mid-session.

## Observing reactions from GDScript

`ga::AbilityComponent::add_tag_reaction_diagnostic_listener` (native, C++)
is the only place `TagReactionDiagnosticEvent` (application failures,
stale-handle clears, chain-limit hits) is currently observable —
`native/godot/gameplay_ability_component.cpp`'s `register_core_listeners()`
does not wire it to any `GameplayAbilityComponent` signal, and there is no
bound method exposing `active_tag_reaction_bindings()` to script either.
This is a real, currently-open gap between the native runtime (fully
tested — see `native/tests/ga_test_tag_reaction_runtime.cpp`) and the
Godot-facing API, not a design decision; see `authoring.md`'s "Known
gaps".

Until that wiring lands, a game observes a reaction firing the exact same
way `tests/gameplay_abilities/integration/test_tag_reactions_runtime.gd`
does: because a reaction's effect applies/removes through the identical
`EffectRuntime` path any other effect uses, the ordinary
`effect_lifecycle_changed` signal (effect applied/removed, carrying
`definition_identifier`) and `tag_changed` signal (the operand's own tag
transitioning) are sufficient to detect that a reaction ran, which effect
it applied, and when it released — there is just no direct signal naming
the *reaction* identity itself yet.

## Failure semantics — summary table

| Situation | Result |
|---|---|
| Unknown operand tag or target effect reference | `configure()` fails (`reaction_registration_failed`); no component runtime is created |
| Catalog and legacy arrays both configured | `configure()` fails; neither source is partially registered (see `authoring.md`) |
| `ON_ADDED`/`ON_REMOVED`/`WHILE_PRESENT`-apply effect fails requirements/immunity/preflight | diagnostic emitted; no handle created; no retry until a later matching edge |
| Bound `WHILE_PRESENT` handle missing at removal | stale binding cleared with a diagnostic; unrelated state unchanged; not recreated until the next false-to-true edge |
| Static reaction cycle (including a length-one self-loop) | `configure()` fails with the full involved reaction/effect path |
| Dynamic chain limit reached | remaining chain stopped; one bounded diagnostic; already-committed transactions stay committed |
| Component teardown | teardown-induced edges never dispatch; pending queued reaction work is discarded, no effects applied |
| Client receives a reaction effect not known to its manifest | ordinary manifest/protocol-mismatch handling — resync or fail per existing policy |
| Snapshot references an unknown reaction/handle/incompatible effect | bounded snapshot validation rejects it before partial restoration |

## See also

- [`authoring.md`](authoring.md) — how to author a
  `GameplayTagReactionDefinition`, the catalog it lives in, and the exact
  validation-finding codes.
- [`determinism.md`](determinism.md) — the general transaction/queue
  model reactions build on (deferred post-commit notification, non-reentrant
  mutation queueing, canonical ordering).
- [`editor_workflows.md`](editor_workflows.md) — Inspector/dashboard
  walkthroughs, including picking a reaction's operand tag and target
  effect.
- `docs/spec/changes/add-global-tag-catalog-and-reactions-2026-07-25/design.md`
  and its `specs/gameplay-tags/spec.md`/`specs/gameplay-effects/spec.md`/
  `specs/gameplay-ability-networking/spec.md` deltas — the normative
  requirements this document explains.
