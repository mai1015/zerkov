# How GameplayAbilities Works

This is the first document to read when integrating the addon. It explains
the runtime model and follows one ability from authored data to a committed
state change. The other documents in this directory are detailed references;
you should not need to inspect the native implementation to understand the
normal integration path.

The native GDExtension is required; there is no GDScript gameplay fallback.
Enabling the editor plugin adds authoring tools, but it does not create an
autoload or any gameplay state. Your scenes create the nodes described below
explicitly, and the complete `addons/gameplay_abilities/` directory—including
its matching `bin/` artifact—must be present.

GameplayAbilities is a deterministic gameplay-state runtime. It owns ability
grants and executions, tags, numeric attributes, effects, tasks, targeting
sessions, and their replication. It deliberately does **not** own player
input, AI decisions, transforms, physics queries, animation, VFX, audio,
entity spawning, or the network peer. Your game supplies those edges.

## The mental model

```text
                           authored once
                    GameplayDefinitionCatalog
          tags / attributes / effects / abilities / cues /
                  target schemas / tag reactions
                                  |
                     configure + seal + fingerprint
                                  v
 input / AI / replay ----> GameplayAbilityComponent ----> committed signals
     (game-owned)             one per entity              (game-owned UI/VFX)
                                  |
                       typed cross-entity work
                                  v
                  GameplayAbilityWorldCoordinator
                                  |
                    authority-validated effect batch

 multiplayer adds a GameplayAbilityNetworkBridge beside each component:

 client intent -> optional local prediction -> server validation/commit
       ^                                            |
       +------ ack/reject + delta/snapshot ----------+
```

Three distinctions make the rest of the addon easier to understand:

1. **Definitions are not state.** A catalog defines what
   `attribute.vitals.health` and `ability.combat.strike` mean. Each component
   owns its own health value, tags, active effects, grants, and executions.
2. **An ability is a validated transaction, not a script callback.** The
   definition declares eligibility, cost, cooldown, effects, tags, lifetime,
   targeting, and prediction policy. An optional constrained hook may add a
   bounded command list. The whole commit succeeds or rolls back.
3. **The client submits intent; authority creates truth.** A network client
   may predict an eligible subset for responsiveness, but the server repeats
   all checks, owns target validation, and publishes the confirmed state.

## What each public concept represents

| Concept | Authored definition | Live state and purpose |
|---|---|---|
| Tag | `GameplayTagDefinition` | A source-counted fact on one component. Dotted names form a hierarchy, so `state.control.stunned` can satisfy a parent-aware query for `state.control`. |
| Attribute | `GameplayAttributeDefinition` | A fixed-point base value plus active modifiers and a clamped current value, such as health or stamina. A definition must still be initialized on every component that uses it. |
| Effect | `GameplayEffectDefinition` | A reusable mutation package for attributes and tags. Effects can be instant, duration-based, infinite, periodic, stackable, conditional, and cue-producing. |
| Ability | `GameplayAbilityDefinition` | A grantable recipe: activation policy, tag requirements, cost, cooldown, commit effects, owned tags, concurrency, lifetime, hook, target schema, and prediction policy. |
| Cue | `GameplayCueDefinition` | A stable presentation name. It does not contain a particle, animation, or sound; game presentation maps the cue to those things. |
| Target schema | `GameplayTargetDataSchema` | The bounded, versioned contract for target intent and authority results. It says which typed value is valid and which provider resolves it. |
| Tag reaction | `GameplayTagReactionDefinition` | An authority-only rule that applies or releases a self effect when a tag predicate changes truth. |
| Catalog | `GameplayDefinitionCatalog` | The project or game-mode definition set from which each component builds its private sealed registries. |
| Component | `GameplayAbilityComponent` | One entity's complete ability state and the main API used by game code. |
| World coordinator | `GameplayAbilityWorldCoordinator` | Per-world typed targeting, sessions, registered components/providers, and atomic cross-component effect batches. |
| Network bridge | `GameplayAbilityNetworkBridge` | Translates component commands and state to Godot high-level multiplayer. It uses a peer created by the game. |

Network policy is authored separately as `GameplayNetworkPolicy` and can be
applied to a bridge with `GameplayNetworkPolicyBridge`. It controls visibility
and relevance; it is not part of an entity's live gameplay state.

## From resources to a running component

### 1. Author a catalog

Most games should create one `GameplayDefinitionCatalog` resource and assign
it in **Project Settings > Gameplay Abilities > Default Definition Catalog**.
A component-level `definition_catalog` overrides that setting, which is useful
for tests or separate game modes.

All definition identifiers use the same grammar:

```text
segment.segment[.segment...]
```

Each segment starts with a lowercase letter and then contains only lowercase
letters, digits, or underscores. A single word such as `health` is invalid;
use at least two segments, such as `attribute.health` or
`attribute.vitals.health`. Identifiers are at most 128 bytes and eight
segments.

References between resources use those identifiers rather than file paths.
For example, an ability's `cost_effect` is the identifier of an effect in the
same catalog, and an effect modifier's `target_attribute` names an attribute
in that catalog.

### 2. Configure once

Before `configure()`, set the component's role, stable entity ID, tick rate,
and catalog. Configuration validates references, builds the native registries,
seals them in canonical order, creates the per-entity runtime, and computes the
content-manifest fingerprint used by multiplayer compatibility checks.

```gdscript
var component := GameplayAbilityComponent.new()
component.role = GameplayAbilityComponent.ROLE_OFFLINE_AUTHORITY
component.entity_id = 1001
component.tick_rate = 60
component.definition_catalog = preload("res://gameplay/catalog.tres")
add_child(component)

var findings: Array = component.configure()
if not GameplayDefinitionValidator.is_ok(findings):
	push_error(GameplayDefinitionValidator.format(findings))
	return
```

Do not use `findings.is_empty()` to decide success. Resolving a catalog adds
an informational `catalog_resolved` finding. `is_ok()` rejects only actual
error findings.

Definitions become immutable after successful configuration. Setters then do
nothing, and a second `configure()` returns an `already_configured` finding.
To change content for a new session, create and configure a new component.

The legacy per-component definition arrays remain supported when no catalog
resolves. A resolved catalog and any populated legacy array are an error; the
runtime never guesses how to merge them.

### 3. Initialize per-entity attributes

A catalog entry does not give an entity a value. Initialize every attribute
the entity will use:

```gdscript
var initialized := component.initialize_attribute(
	&"attribute.vitals.health",
	false, # use the definition's default_base
	0.0,
	0      # explicit gameplay tick
)
if not initialized["status"]["ok"]:
	push_error("Health initialization failed: %s" % initialized["status"])
```

Pass `has_override = true` to use the supplied base value instead. Repeating
initialization fails closed; it does not silently reset the attribute.

### 4. Bind optional behavior hooks

Purely declarative abilities need no hook. A hook is appropriate when commit
behavior depends on the activation context—for example, emitting a gameplay
event or choosing an effect for one of the already-declared targets.

The ability definition chooses `HOOK_BINDING_AUTHORITY_ONLY` or
`HOOK_BINDING_PREDICTION_SAFE`, and game code binds a matching callable after
configuration:

```gdscript
var bound := component.bind_authority_hook(
	&"ability.combat.strike",
	_on_strike_execute
)
if not bound["status"]["ok"]:
	push_error("Hook binding failed: %s" % bound["status"])
	return

func _on_strike_execute(
		context: Dictionary,
		builder: GameplayAbilityCommandBuilder
	) -> bool:
	# Read the immutable context, then submit bounded commands through builder.
	# Do not retain builder after this callback returns.
	return true
```

The context is a value snapshot, not access to mutable containers. The builder
accepts only supported commands and remembers the first rejected command. A
hook cannot hide that failure by returning success; the activation transaction
still rolls back.

Prediction-safe hooks are a stricter family. They must be pure functions of
the supplied context, declare no time, randomness, scene/physics, or
unrestricted-callback dependency, and can apply only eligible self effects.
Remote-target mutation, periodic work, randomness, and physics stay on
authority. See [hooks.md](hooks.md) before marking an ability predictable.

### 5. Grant, then activate by grant handle

Definitions say what can exist. A grant says that this particular component
may use one definition:

```gdscript
var granted := component.grant_ability(
	&"ability.combat.strike", 1, &"input.primary", tick)
if not granted["status"]["ok"]:
	return

var strike_spec: int = int(granted["spec"])
```

`strike_spec` is a component/session-local `AbilitySpecId`, not a project-wide
content ID and not the ability identifier. A snapshot preserves it, but a
replacement component/session may allocate another value, so resolve grants
again when rebuilding. The `input_id` is opaque metadata. GameplayAbilities
never reads an `InputEvent`, registers an InputMap action, or activates from
physical input by itself.

Activation policy controls the definition's built-in entry point. A manual
ability is requested by game code. A gameplay-event ability can match an event
delivered through `handle_gameplay_event()`. A passive-on-grant ability makes
an activation request immediately after its grant commits. Input-kind trigger
metadata does not subscribe to physical input; a game adapter still performs
that mapping.

Your input, AI, replay, or test adapter calls the same logical API:

```gdscript
var result := component.request_activation({
	"spec": strike_spec,
	"command_sequence": next_command_sequence(),
}, tick)

if not result["status"]["ok"]:
	show_activation_error(result["status"])
```

Use a monotonically increasing nonzero `command_sequence` for each grant. The
runtime rejects an older or repeated sequence instead of executing it twice.
If several requests intentionally share a tick, `process_activation_batch()`
sorts them by `(command_sequence, spec)` before using the same activation path.

### 6. Advance gameplay time explicitly

The component has no autonomous clock. Your simulation converts elapsed time
or a server tick into integer gameplay ticks and advances every component:

```gdscript
func advance_gameplay_to(authority_tick: int) -> void:
	var result := component.advance_to(authority_tick)
	if not result["status"]["ok"]:
		push_error("Ability tick failed: %s" % result["status"])
```

`advance_to()` drives task deadlines/due ticks, periodic effects, effect
expiration, resulting tag edges, reactions, and deferred mutations. Call it
from one game-owned tick driver per simulated world; networked clients should
align their advisory ticks through the bridge rather than inventing a second
timeline. Do not let every consumer derive its own tick from wall time, and do
not treat `get_current_tick()` as a clock driver; it reports the highest tick
observed for diagnostics.

The supported tick rate is 10–240 ticks per second, with 60 as the default.
The tick rate contributes to the handshake, so peers must agree.

## What happens during activation

`request_activation()` validates in two ordered layers. Understanding them
explains most status failures:

- The Godot boundary first rejects an unconfigured component, converts and
  bounds the request fields, and validates the ability's declared target
  schema when the grant can be resolved.
- The native core then:

  1. rejects a torn-down owner or a role/provenance mismatch;
  2. resolves the grant and rejects revoked or unknown grants;
  3. rejects a stale command sequence;
  4. applies the ability's concurrency policy;
  5. evaluates required and blocked tag queries;
  6. rejects an active cooldown;
  7. checks whether the cost is affordable without mutating state;
  8. creates an execution in `BEGUN` phase and publishes its lifecycle only
     after that small transaction commits; and
  9. commits immediately when `auto_commit` is enabled. Otherwise, the
     execution stays begun until `commit_activation(execution, tick)` is
     called.

Commit is a second atomic transaction. Its mutation order is:

```text
cost effect
  -> cooldown effect
  -> declared self commit effects, in authored order
  -> validated commands from the bound behavior hook
  -> ability-owned tags
  -> execution becomes ACTIVE
```

If any step fails, every earlier change in that commit rolls back. Observers
never see stamina deducted without its cooldown, or an owned tag surviving a
failed hook. Notifications and signals are queued and dispatched only after
commit, so signal handlers see a coherent state.

If `ends_on_commit` is true, the execution then ends in the same activation
flow. Duration/infinite commit effects keep their own declared lifetime. If it
is false, the execution remains active; its execution-scoped effects, owned
tags, and tasks are cleaned up when it ends or is cancelled.

Calls made from inside a lifecycle/signal callback are deferred to a later
transaction rather than mutating reentrantly. Treat a returned
`{"queued": true}` activation only as confirmation that the request was
deferred: its immediate `status` and `execution` are not the final result.
Lifecycle signals report transitions that later commit. If the caller needs
the exact rejection status too, queue game-owned intent from the signal
handler and call `request_activation()` after the handler returns, where its
ordinary result Dictionary is available.

## Tags, attributes, and effects

### Tags are source-counted facts

An exact tag can be owned by more than one source. Removing one source does
not remove the tag while another still owns it. This is why overlapping stun
effects work without one expiration clearing the other.

- `has_tag_exact("state.control.stunned")` asks for that exact tag.
- `has_tag_parent_aware("state.control")` also matches registered descendants
  such as `state.control.stunned`.
- Ability/effect tag queries choose exact or parent-aware operands explicitly.

There is no separate resource for `state.control`; hierarchy comes from the
dotted identifier.

### Attributes separate base from current

The base is the persistent value modified by instant effects. The current
value is recomputed from base and active duration/infinite modifiers in this
fixed order:

```text
base -> all ADD modifiers -> all MULTIPLY modifiers
     -> first canonical OVERRIDE -> min/max clamp
```

Author-facing numbers are quantized to fixed point with 1,000,000 subunits per
whole unit. Non-finite or out-of-range values fail validation; authoritative
math does not depend on platform floating-point behavior.

### Effects are the mutation package

Before applying an effect, the runtime resolves its definition and magnitudes,
checks source/target requirements and immunity, validates set-by-caller fields,
and checks bounds and stacking policy.

A modifier is ADD, MULTIPLY, or OVERRIDE. Its magnitude can be a constant,
ability-level scale, source/target attribute scale, or a declared
set-by-caller field. Resolution happens once at application against the
transaction's validated input; a caller cannot smuggle an undeclared dynamic
field into the effect.

- **Instant** effects change attribute bases atomically, emit lifecycle/cue
  events, and leave no active handle.
- **Duration** effects keep an active handle until their end tick.
- **Infinite** effects keep an active handle until explicitly removed or
  cleaned up by an owning execution/reaction.
- **Periodic** effects apply their due deltas when the component advances.
- **Stacking** groups compatible active effects, then increments, refreshes,
  replaces, rejects, or applies a declared overflow effect according to the
  authored policy.

Effect-granted tags and persistent modifiers are owned by the active effect's
source token and are removed together with that effect. Cues are logical
notifications; use the optional adapters under `runtime/cues/` or your own
presentation layer to turn them into visuals and sound.

## Cross-entity targeting and effect application

A component owns only its entity. Putting entity IDs in an activation's
`targets` array makes them available to validation and hooks; it does **not**
magically locate another component or apply damage to it.

New integrations should use typed targeting:

1. Configure one `GameplayAbilityWorldCoordinator` for the world with the same
   catalog/target schemas.
2. Register authority components and game-owned authority providers.
3. Build a `GameplayTargetValue` from player, AI, event, or test intent.
4. Call `resolve_direct`, `resolve_ai`, `resolve_gameplay_event`, or
   `resolve_test`. They all use the same schema normalization and provider
   validation.
5. Treat the returned `GameplayValidatedTargetData` as an authority-only value,
   never as a proof that a client can serialize or manufacture.
6. Call `apply_effect_batch()` to apply source and target effects atomically.

An ordinary entity-set attack resolves its target first, requests the source
ability activation with the authority-returned target IDs in its context, and
applies the world batch only if activation succeeds. Do not copy the raw
intent IDs into the activation: a provider may filter, reorder, or replace
them. The component activation and the later cross-component batch are two
explicit transaction boundaries; "atomic batch" means all participants in
`apply_effect_batch()`, not an implicit rollback of an already-committed
ability cost/cooldown. Preflight game-specific conditions before source commit
when that distinction matters.

```gdscript
var resolved := coordinator.resolve_direct(
	source_id,
	&"ability.combat.strike",
	GameplayTargetValue.entity_set(PackedInt64Array([target_id])),
	tick
)

if resolved["status"]["ok"]:
	var validated: GameplayValidatedTargetData = resolved["validated_data"]
	var authoritative_targets := validated.get_result().get_entities()
	var activation := source_component.request_activation({
		"spec": strike_spec,
		"targets": authoritative_targets,
		"command_sequence": next_command_sequence(),
	}, tick)
	if activation["status"]["ok"]:
		var batch := coordinator.apply_effect_batch(
			validated,
			[],
			[{"effect": "effect.combat.damage", "level": 1,
			  "set_by_caller": []}],
			tick
		)
		if not batch["status"]["ok"]:
			push_error("Target batch failed: %s" % batch["status"])
```

The provider is game code because only the game understands range, teams,
cover, physics, or navigation. It returns stable entity IDs and bounded work;
it must not mutate gameplay while preparing a result. The coordinator
revalidates the result, preflights every participant, commits in stable entity
order, and restores all captured participants if an unexpected later
invariant fails.

For interactive targeting, an ability can wait on a `WAIT_TARGET_DATA` task
while the coordinator owns a submit/confirm/cancel session. Local previews
remain presentation only. A client-provided point, ray, hit, target list, or
"validated" flag is always untrusted intent; authority recomputes or validates
it through the registered provider.

The older `pending_remote_effects` / `apply_pending_remote_effect()` seam is
kept for compatibility. Prefer typed validated data plus
`apply_effect_batch()` for new cross-component work.

## Long-running abilities and tasks

An immediate ability can auto-commit and end without a task. A channel,
charge, combo window, delayed cast, or targeting interaction normally uses:

- `ends_on_commit = false` so its execution stays active;
- a hook that creates a `GameplayAbilityTaskRequest` through
  `builder.request_task()`; and
- the hook's optional task callback to submit the next bounded command when
  the task terminates.

Built-in waits cover ticks, gameplay events, tag-query edges, logical input,
authority acknowledgement, and target data. They are execution-owned,
bounded, snapshot-safe, and driven by gameplay ticks. They contain no Node,
Timer, InputEvent, physics object, or callable.

Ending/cancelling the parent, revoke-cancel, owner teardown, or authority
correction cancels its tasks in handle order. A task terminal callback runs
after the transition commits and cannot synchronously recurse into it.

Logical input remains game-owned. Map a key, CommonUI action, AI decision, or
replay entry to `submit_logical_input()` offline/on authority, or
`request_task_input_networked()` on the owning client.

## Tag reactions

A reaction watches the effective truth of one tag operand after transactions
commit:

- `ON_ADDED`: false to true applies its self effect once.
- `ON_REMOVED`: true to false applies its self effect once.
- `WHILE_PRESENT`: false to true applies and binds one infinite self effect;
  true to false removes that exact handle.

Because truth is source-counted, a second source adding an already-present tag
does not retrigger `ON_ADDED`, and removing one of two sources does not trigger
`ON_REMOVED`. Parent-aware reactions use the same first/last matching
descendant rule.

Reactions run only on offline/server authority, after blocking-tag cancellation
work queued by the same transaction. Static cycles are rejected during
component configuration; dynamic chains are capped at eight. A failed reaction
effect rolls back only that effect, not the original tag change or later
reactions in the same canonical batch.

Snapshots restore active `WHILE_PRESENT` bindings and their handles without
replaying historical edges. The native reaction diagnostic stream is not yet
exposed directly to GDScript; observe resulting `effect_lifecycle_changed` and
`tag_changed` signals for now.

## Offline and multiplayer runtime flows

### Offline or server-owned AI

Use `ROLE_OFFLINE_AUTHORITY` for a standalone game and
`ROLE_SERVER_AUTHORITY` for a network authority. Input, AI, tests, and replay
drivers can call `request_activation()` directly with authoritative
provenance. The same validation and commit path is used in every case.

### Owning network client

Put a `GameplayAbilityNetworkBridge` beside the component under the same
branch-scoped `MultiplayerAPI`, set its `component_path` (and
`world_coordinator_path` when targeting is used), and call:

```gdscript
var send_result := bridge.request_activation_networked(request, client_tick)
```

Do not call the client component as if it were authority. On a network-client
role, the bridge:

1. Rejects immediately if there is no active multiplayer peer.
2. Validates and converts the bounded request.
3. If the ability is prediction-eligible and a confirmed baseline exists,
   applies the allowed self-only work locally and journals the original
   command under allocated command-sequence and prediction-key identities.
4. Sends the intent to the server.

The server accepts commands only from handshaken peers. It checks the session,
component identity/ownership gate, sequence and rate limits, grant, target
schema, optional game target-authorization callback, and the ordinary ability
rules. It then executes with authoritative provenance and returns an
acknowledgement or rejection.

On acknowledgement, the client closes the journal entry, maps reported
temporary durable handles to authority handles (the current wire path reports
new cooldown handles), and confirms deduplicated presentation. On rejection or
a replication gap, it restores the last confirmed component/coordinator
baseline, removes rejected work, and replays still-pending commands in their
original order with their original identities. Preserving those identities
lets the server's duplicate cache answer a resend without executing the
logical command twice.

Owner state arrives as ordered deltas/event batches with full snapshots used
for initial state, resync, or when a delta no longer fits the retained change
history. Non-owning observers receive a filtered public-state feed, never the
owner's canonical private snapshot. A heartbeat exposes authoritative progress
even when unchanged state suppresses a delta.

### The handshake

Peers must agree on protocol/features, tick rate, fixed-point scale,
identifier dictionary, content-manifest fingerprint, and packet limits before
state or commands are accepted. The manifest is computed from behavior-affecting
definition fields in canonical order, so changing a cooldown, query, schema,
reaction, or other gameplay field makes incompatible builds fail before play.

The bridge does not create ENet, authenticate users, implement matchmaking, or
perform full-world rollback. The game owns the `MultiplayerPeer`, stable entity
ownership, relevance policy, scene/physics simulation, and any anti-cheat or
lag-compensation layer.

## Signals and presentation

Connect signals after creating the component and before gameplay starts:

- `attribute_changed` and `tag_changed` update UI or game-owned projections.
- `effect_lifecycle_changed` reports apply/stack/period/remove/expire events.
- `ability_granted`/`ability_revoked` and `activation_*` expose published
  grant and execution lifecycle records. The result Dictionary remains the
  authoritative place to read an immediate direct-request rejection.
- `ability_task_event` reports task starts, terminal outcomes, and explicit
  restored-state notifications.
- `effect_cue_triggered` and `prediction_phase_changed` drive presentation.
- bridge acknowledgement/rejection, public-state, gap, and diagnostics signals
  drive network UI and recovery.

Signals carry copied Dictionaries/value data. They are observations of
committed state, not mutable handles into the core.

Predicted presentation must be reversible and deduplicated. A HUD marker or
anticipation pose can start on `CUE_PREDICT` and undo on `CUE_CORRECT`/
`CUE_CANCEL`. Irreversible sound or a one-shot particle should normally wait
for `CUE_CONFIRM`/`CUE_AUTHORITY_ONLY`. On snapshot restore, rebuild persistent
presentation from `CUE_SNAPSHOT_RESTORED` without replaying historical one-shot
cues. The optional `GameplayCueAdapter` implementations under `runtime/cues/`
demonstrate this policy.

## Determinism, bounds, and failure behavior

The runtime is deterministic under the inputs replication actually uses:
identical definitions plus the identical authoritative command/tick sequence
produce identical snapshots and digests. A received snapshot restores the same
state deterministically.

The mechanisms are concrete:

- authoritative numbers use fixed-point math;
- time is explicit integer ticks;
- definitions and output collections use canonical ordering;
- mutations compose into transactions with LIFO undo;
- notifications occur after commit;
- reentrant work is queued;
- snapshots and wire messages use canonical bounded encodings.

One important boundary: two components that reach gameplay-equivalent effect
or ability state through a *different live insertion order* can have different
snapshot bytes because effect, grant, execution, and source handles are
monotonic call-order identities. Same-history replay and restoring the exact
authority snapshot are byte-stable; do not use "equivalent end state from a
different command order" as a byte-equality assertion.

Common enforced ceilings include 128 attributes, 128 active effects, 64
grants, 32 active executions, 32 active tasks, 32 targets per command, 16
set-by-caller fields, 16 pending predictions, a 128 KiB snapshot, and 30
commands per second per peer/component. These are failure boundaries, not
capacity targets. See [protocol.md](protocol.md) for the complete current
table and [budgets.md](budgets.md) for measured budget coverage.

Most mutating calls return a Dictionary containing:

```text
status = { ok, code, diagnostic, detail }
```

Branch on `status.ok` and enum/status codes, never parse diagnostic text.
Invalid identifiers, references, roles, targets, payloads, stale sequences,
capacity, or prediction state fail closed. A failed transaction publishes no
partial state.

`restore_snapshot()` first captures the current state. If decoding/restoration
fails, the wrapper restores that pre-state. If even rollback fails, the
component is quarantined (`is_configured()` becomes false) and emits
`desync_rebuild_required`; discard it and configure a fresh component.

### Common first-integration mistakes

| Symptom | Likely cause |
|---|---|
| `configure()` returned a non-empty array even though the component works | A catalog adds an informational `catalog_resolved` finding. Use `GameplayDefinitionValidator.is_ok(findings)`, not `findings.is_empty()`. |
| An effect or cost reports an unknown/uninitialized attribute | Catalog registration defines the attribute but does not initialize it on the entity. Call `initialize_attribute()` before granting/activating content that uses it. |
| Direct activation on a client reports a role violation | An owning network client sends intent through `request_activation_networked()`; it does not impersonate authority with a direct authoritative component call. |
| Activation succeeds but another entity takes no damage | Target IDs are context, not automatic delivery. Resolve typed targets and call `apply_effect_batch()`, or deliberately consume the legacy pending-remote-effect seam. |
| A duration/cooldown never expires or periodic damage never ticks | No game-owned tick driver is calling `advance_to()` with increasing gameplay ticks. |
| A "predictable" ability falls back or validation rejects it | One of its costs, cooldowns, commit/overflow effects, hook capabilities, periodic behaviors, or target rules is outside the prediction-safe set. See `hooks.md`. |
| Multiplayer rejects otherwise identical scenes at handshake | Compare protocol/features, tick rate, catalog content, and packet-limit build constants. Resource file order is canonicalized; a behavior-affecting field difference is not. |
| A tag reaction visibly applies an effect but no reaction-specific signal fires | Direct reaction diagnostics are not bound to GDScript yet. Observe `effect_lifecycle_changed` and `tag_changed`. |

## Minimal runnable example

This example constructs a tiny runtime catalog from the addon's two shipped
sample resources, adds one declarative self-damage ability, initializes one
component, grants the ability, and activates it. Put it on a Node in a project
where the addon is installed and enabled.

```gdscript
extends Node

const HEALTH_DEFINITION := preload(
	"res://addons/gameplay_abilities/resources/attribute_vitals_health.tres")
const DAMAGE_EFFECT := preload(
	"res://addons/gameplay_abilities/resources/effect_damage_instant.tres")

var abilities: GameplayAbilityComponent
var gameplay_tick := 0
var next_sequence := 1

func _ready() -> void:
	# The ability is data: auto-commit one self effect, then end.
	var take_damage := GameplayAbilityDefinition.new()
	take_damage.set_identifier(&"ability.demo.take_damage")
	take_damage.set_activation_policy(
		GameplayAbilityDefinition.ACTIVATION_MANUAL)
	take_damage.set_commit_effects(
		PackedStringArray(["effect.damage.instant"]))
	take_damage.set_auto_commit(true)
	take_damage.set_ends_on_commit(true)

	var catalog := GameplayDefinitionCatalog.new()
	catalog.set_attribute_definitions([HEALTH_DEFINITION])
	catalog.set_effect_definitions([DAMAGE_EFFECT])
	catalog.set_ability_definitions([take_damage])

	abilities = GameplayAbilityComponent.new()
	abilities.name = "Abilities"
	abilities.role = GameplayAbilityComponent.ROLE_OFFLINE_AUTHORITY
	abilities.entity_id = 1
	abilities.tick_rate = 60
	abilities.definition_catalog = catalog
	add_child(abilities)

	var findings: Array = abilities.configure()
	if not GameplayDefinitionValidator.is_ok(findings):
		push_error(GameplayDefinitionValidator.format(findings))
		return

	var initialized := abilities.initialize_attribute(
		"attribute.vitals.health", false, 0.0, gameplay_tick)
	if not initialized["status"]["ok"]:
		push_error("Initialize failed: %s" % initialized["status"])
		return

	var granted := abilities.grant_ability(
		"ability.demo.take_damage", 1, "input.demo.take_damage",
		gameplay_tick)
	if not granted["status"]["ok"]:
		push_error("Grant failed: %s" % granted["status"])
		return

	var activated := abilities.request_activation({
		"spec": int(granted["spec"]),
		"command_sequence": next_sequence,
	}, gameplay_tick)
	next_sequence += 1
	if not activated["status"]["ok"]:
		push_error("Activation failed: %s" % activated["status"])
		return

	# The shipped effect applies -10 to the shipped 100-health attribute.
	assert(is_equal_approx(
		abilities.get_attribute_current("attribute.vitals.health"), 90.0))
	print("Health after activation: ",
		abilities.get_attribute_current("attribute.vitals.health"))
```

The important part is the order: define/catalog -> configure -> initialize ->
grant -> request with an explicit tick/sequence -> inspect committed state.
Replacing the programmatically created resources with `.tres` assets does not
change the runtime flow.

## Where to go next

- [authoring.md](authoring.md) — create every resource type and validate a
  real catalog.
- [api.md](api.md) — exact methods, properties, signals, enum values, and
  Dictionary shapes.
- [integration.md](integration.md) — connect InputMap, CommonUI, AI, replay,
  and an existing multiplayer session.
- [targeting.md](targeting.md) — providers, sessions, trust boundaries, and
  atomic cross-entity effect batches.
- [tasks.md](tasks.md) — channels, waits, logical input, restore, and task
  callbacks.
- [hooks.md](hooks.md) — authority-only versus prediction-safe behavior.
- [reactions.md](reactions.md) — tag-edge semantics and `WHILE_PRESENT`
  bindings.
- [protocol.md](protocol.md) and [determinism.md](determinism.md) — wire,
  snapshot, ordering, security, and determinism contracts.
- [basic combat example](../../../examples/gameplay_abilities/basic_combat/README.md)
  — small playable integration using a catalog, hooks, targeting, reactions,
  cost, cooldown, damage, and fixed ticks.
- [reference vertical slice](../../../examples/gameplay_abilities/slice/README.md)
  — prediction, acknowledgement/correction, late join, reconnect, poison,
  stun, heal, and dedicated-server flows.
