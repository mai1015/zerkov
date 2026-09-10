# Public API Reference

Every Godot-facing class this addon exposes, including
`GameplayAbilityComponent`, `GameplayAbilityNetworkBridge`,
`GameplayAbilityWorldCoordinator`, typed target values, Ability Task
requests, `GameplayAbilityVersion`, and every authoring `Resource` class.
Sourced directly from each class's
`_bind_methods()`/`ADD_SIGNAL`/`ADD_PROPERTY` calls in `native/godot/*.cpp`
and `native/resources/*.h` — not inferred from the delta specs. Where a
signature or enum value could not be verified against source, it is not
included.

## Pre-1.0 status — read this before depending on anything below

Per `native/core/ga_limits.h` (`GA_API_VERSION_MAJOR/MINOR/PATCH = 0/2/0`,
`GameplayAbilityVersion.get_api_version() == "0.2.0"`): **every class,
enum, method, signal, and resource field in this document is pre-1.0.**
The API remains pre-1.0 under the platform proposal's explicit promotion
gate; neither the task nor targeting change promotes it to 1.0. Breaking
pre-1.0 changes are expected and require
migration notes, not a protocol/API version bump, unless they also change
wire-relevant behavior (see `protocol.md`'s "Versioning" section).

Per design.md's Migration Plan: **games integrate through
`GameplayAbilityComponent`, `GameplayAbilityNetworkBridge`,
`GameplayAbilityVersion`, the authoring `Resource` classes, and the value
Dictionaries they exchange — never against internal native classes
(anything under `ga::`/`ga::proto::` C++ namespaces) or the packet byte
layouts documented in `protocol.md`.** Everything under `ga::`/`ga::proto::`
is engine-independent core/protocol, has no ClassDB registration, and is
not reachable from GDScript at all; it is documented in `protocol.md`,
`determinism.md`, and `hooks.md` purely so the *behavior* those classes
implement is traceable, not as a surface to call directly.

## `GameplayAbilityVersion`

A stable, static facade (`native/godot/gameplay_ability_version.h`) — every
value is read straight from `native/core/ga_version.h`/`ga_limits.h`, so it
can never drift from what the handshake and manifest tooling compute.

| Method | Returns | Notes |
|---|---|---|
| `get_api_version()` | `String` | `"major.minor.patch"`, currently `"0.2.0"` |
| `get_api_version_major()` | `int` | `0` |
| `get_api_version_minor()` | `int` | `2` |
| `get_api_version_patch()` | `int` | `0` |
| `get_protocol_version()` | `int` | `GA_PROTOCOL_VERSION`, currently `4` |
| `get_manifest_algorithm()` | `String` | `"fnv1a64-canonical-v1"` |
| `get_supported_features()` | `int` | bitmask of `FeatureFlag` |
| `has_feature(feature: int)` | `bool` | tests one `FeatureFlag` bit |

`FeatureFlag` enum: `FEATURE_PREDICTION = 1<<0`, `FEATURE_DEDICATED_SERVER = 1<<1`,
`FEATURE_SNAPSHOT_RESYNC = 1<<2`, `FEATURE_PERIODIC_EFFECTS = 1<<3`,
`FEATURE_GAMEPLAY_EVENTS = 1<<4`, `FEATURE_ABILITY_TASKS = 1<<5`,
`FEATURE_TYPED_TARGETING = 1<<6`, `FEATURE_OBSERVER_TASK_STATE = 1<<7`.

## `GameplayAbilityComponent`

A `Node` (`native/godot/gameplay_ability_component.h`). Owns one entity's
tags/attributes/effects/ability grants/executions. Every mutating method
below takes an explicit `tick`; the component holds no implicit "current
tick" driver of its own (`get_current_tick()` is only the highest tick
value observed so far, for diagnostics).

### Properties (immutable once `configure()` succeeds)

| Property | Type | Default | Notes |
|---|---|---|---|
| `role` | `Role` (int enum) | `ROLE_OFFLINE_AUTHORITY` | |
| `entity_id` | `int` | `0` | authoritative `EntityId`; ignored after `configure()` (component then reports its assigned id) |
| `tick_rate` | `int` | `DEFAULT_TICK_RATE` (60) | task 7.19: the authoritative ticks/second `configure()` feeds into `ga::ManifestBuilder` (see `get_content_manifest_fingerprint()`). Non-positive input clamps to the default. `GameplayAbilityNetworkBridge` reads THIS once it resolves a configured served component (its own `tick_rate` property is only a pre-wiring bootstrap default) -- see `protocol.md`'s "Handshake fingerprints are live" |
| `tag_definitions` | `Array[GameplayTagDefinition]` | empty | |
| `attribute_definitions` | `Array[GameplayAttributeDefinition]` | empty | |
| `effect_definitions` | `Array[GameplayEffectDefinition]` | empty | |
| `cue_definitions` | `Array[GameplayCueDefinition]` | empty | |
| `ability_definitions` | `Array` (of `Dictionary`) | empty | see "Ability definitions Dictionary shape" below — **not** `Array[GameplayAbilityDefinition]` yet |
| `target_data_schemas` | `Array[GameplayTargetDataSchema]` | empty | typed targeting schemas used when no catalog is selected |
| `definition_catalog` | `GameplayDefinitionCatalog` | `null` | resolution order at `configure()`: this property, else the project setting `gameplay_abilities/default_definition_catalog`, else no catalog (the legacy arrays above then apply). A resolved catalog and any populated legacy array above together fail `configure()` — see `authoring.md`'s "Mixed catalog/legacy configuration is rejected" — never merged. |

Every setter above is a silent no-op once `is_configured()` is true —
definitions are immutable for the session per design.md's "Stable
identities and immutable definitions".

### Configuration

| Method | Signature | Notes |
|---|---|---|
| `configure()` | `() -> Array[Dictionary]` | Builds and seals every registry, constructs the owned core component, wires listeners. Returns a bounded findings array (`{severity, resource_path, field, code, message}`, same shape `GameplayDefinitionValidator` uses); empty means success. A second call returns a single `already_configured` finding and changes nothing. |
| `is_configured()` | `() -> bool` | |
| `get_content_manifest_fingerprint()` | `() -> int` | 0 before `configure()` succeeds; otherwise the FNV-1a64 fingerprint over every sealed registry — the value the network handshake compares (see `protocol.md`). |
| `initialize_attribute(identifier, has_override, override_base, tick)` | `(String, bool, double, int) -> Dictionary` | `{status}`. Must be called once per attribute before any effect/cost/cooldown referencing it applies. `has_override == false` uses the definition's own `default_base`. Fails closed (`ALREADY_EXISTS`/`UNKNOWN_ATTRIBUTE`) on a repeat or unregistered identifier. |

### Grants

| Method | Signature | Returns |
|---|---|---|
| `grant_ability(identifier, level, input_id, tick)` | `(String, int, String, int) -> Dictionary` | `{status, spec}` |
| `revoke_ability(spec, tick, provenance = PROVENANCE_AUTHORITATIVE)` | `(int, int, Provenance) -> Dictionary` | `{status}` |
| `has_grant(spec)` | `(int) -> bool` | |
| `get_grant(spec)` | `(int) -> Dictionary` | see "Grant Dictionary shape" below; empty `Dictionary` if unknown |
| `granted_specs()` | `() -> PackedInt64Array` | ascending `AbilitySpecId` |
| `ability_id_of(identifier)` | `(String) -> int` | resolved `DefinitionId`, or `0` (`INVALID_DEFINITION_ID`) if unregistered |

### Activation

| Method | Signature | Returns |
|---|---|---|
| `request_activation(request, tick)` | `(Dictionary, int) -> Dictionary` | see "Activation request/result Dictionary shapes" below |
| `process_activation_batch(requests, tick)` | `(Array, int) -> Array[Dictionary]` | sorts by `(command_sequence, spec)` and processes each through the identical path, in that order |
| `commit_activation(execution, tick)` | `(int, int) -> Dictionary` | `{status, pending_remote_effects}`; only meaningful for a `BEGUN`-phase execution of an `auto_commit == false` ability |
| `handle_gameplay_event(event, tick)` | `(Dictionary, int) -> Dictionary` | `{status}`; `event` shape below |
| `apply_pending_remote_effect(command, source, tick)` | `(Dictionary, GameplayAbilityComponent, int) -> Dictionary` | compatibility-only legacy seam; new cross-component work should use `GameplayAbilityWorldCoordinator.apply_effect_batch()`. Applies one captured command on its target through the normal validated runtime. |
| `preflight_pending_remote_effect(command, source, tick)` | `(Dictionary, GameplayAbilityComponent, int) -> Dictionary` | compatibility-only, side-effect-free check for the legacy command above; not a reservation |

### Ability Tasks

The lifecycle, event shapes, ordering, prediction policy, and safe examples
are in [`tasks.md`](tasks.md).

| Method | Signature | Notes |
|---|---|---|
| `start_ability_task(execution, request, tick, provenance=AUTHORITATIVE)` | `(int, GameplayAbilityTaskRequest, int, Provenance) -> Dictionary` | Starts one execution-owned wait; returns `{status, task, terminal, event}`. Hooks normally use `builder.request_task(request)` instead. |
| `cancel_ability_task(task, tick, reason=EXPLICIT, provenance=AUTHORITATIVE)` | `(int, int, TaskCancelReason, Provenance) -> Dictionary` | Idempotent structured cancellation. |
| `submit_logical_input(execution, task, logical_input, phase, command_sequence, prediction_key, tick, provenance=AUTHORITATIVE)` | `(...) -> Dictionary` | Feeds one registered logical phase; physical input remains game-owned. |
| `acknowledge_task_authority(prediction_key, tick)` | `(int, int) -> Dictionary` | Completes matching `WAIT_AUTHORITY` barriers. |
| `has_ability_task(task)` / `get_ability_task(task)` | `(int) -> bool/Dictionary` | Immutable task query. |
| `active_ability_tasks()` / `ability_tasks_for_execution(execution)` | `()/(int) -> PackedInt64Array` | Ascending component-local handles. |
| `notify_restored_ability_tasks(tick)` | `(int) -> void` | Emits restored-state presentation notifications without replaying historical starts or terminals. |

### Ending & cancellation

| Method | Signature | Returns |
|---|---|---|
| `end_execution(execution, tick, provenance = PROVENANCE_AUTHORITATIVE)` | `(int, int, Provenance) -> Dictionary` | `{status}` |
| `cancel_execution(execution, tick, provenance = PROVENANCE_AUTHORITATIVE, reason = END_REASON_EXPLICIT_CANCEL)` | `(int, int, Provenance, EndReason) -> Dictionary` | `{status, execution}` |
| `has_execution(execution)` | `(int) -> bool` | |
| `get_execution(execution)` | `(int) -> Dictionary` | see "Execution Dictionary shape" below |
| `active_executions()` | `() -> PackedInt64Array` | ascending `ExecutionId` |

### Tick driver, queries, diagnostics

| Method | Signature | Returns |
|---|---|---|
| `advance_to(tick)` | `(int) -> Dictionary` | drives effect expiration/periodic execution and drains reentrant requests |
| `get_current_tick()` | `() -> int` | |
| `has_attribute(identifier)` | `(String) -> bool` | |
| `get_attribute_base(identifier)` | `(String) -> double` | |
| `get_attribute_current(identifier)` | `(String) -> double` | |
| `get_initialized_attributes()` | `() -> PackedStringArray` | every initialized attribute's identifier, ascending `DefinitionId` order |
| `has_tag_exact(identifier)` | `(String) -> bool` | |
| `has_tag_parent_aware(identifier)` | `(String) -> bool` | |
| `owned_tags()` | `() -> PackedStringArray` | |
| `get_diagnostics()` | `() -> Dictionary` | `{configured, role, entity_id, current_tick, owner_valid, torn_down}` plus, if configured: `{grant_count, active_execution_count, active_effect_count, tag_revision}` |
| `predicted_effect_authority_handle(temp_handle)` | `(int) -> int` | task 8.11; `ga::PredictionHandleMap` lookup — 0 if `temp_handle` has no recorded authority mapping (not yet confirmed, already pruned, or not `ROLE_NETWORK_CLIENT`) |

**No bound method or signal exposes tag-reaction state to script yet**:
`ga::AbilityComponent::active_tag_reaction_bindings()` and
`add_tag_reaction_diagnostic_listener` (the native `TagReactionDiagnosticEvent`
stream — application failures, stale-handle clears, chain-limit hits) are
not wired into this class at all — see `reactions.md`'s "Observing
reactions from GDScript" for how to detect a reaction firing indirectly
via `effect_lifecycle_changed`/`tag_changed` in the meantime.

### Snapshots and teardown

| Method | Signature | Returns |
|---|---|---|
| `write_snapshot()` | `() -> PackedByteArray` | canonical bytes; empty if not configured or writing fails |
| `restore_snapshot(bytes)` | `(PackedByteArray) -> bool` | replaces every attribute/tag/effect/grant/execution atomically; never invokes a hook or emits a lifecycle/cue event |
| `queue_teardown(tick)` | `(int) -> void` | idempotent; also called automatically from `NOTIFICATION_PREDELETE`/`NOTIFICATION_EXIT_TREE` |
| `is_owner_valid()` | `() -> bool` | |
| `is_torn_down()` | `() -> bool` | |

### Network-bridge seams

| Method | Signature | Notes |
|---|---|---|
| `notify_replication_gap(reason_code, detail)` | `(int, int) -> void` | called by `GameplayAbilityNetworkBridge`; emits `replication_gap_detected` |
| `notify_prediction_phase(payload)` | `(Dictionary) -> void` | emits `prediction_phase_changed`; driven internally by this component's own owned `ga::PredictingComponent` for a `ROLE_NETWORK_CLIENT` component (task 8.10) — still public so a caller composing its own prediction flow (e.g. `request_activation`+explicit `PROVENANCE_PREDICTED`) may call it directly too |
| `bind_authority_hook(ability_identifier, callable, task_callable=Callable())` | `(String, Callable, Callable) -> Dictionary` | The optional task callback receives immutable terminal task events; see `hooks.md`/`tasks.md`. |
| `bind_prediction_safe_hook(ability_identifier, callable, depends_on_time=false, depends_on_randomness=false, depends_on_scene_or_physics=false, uses_unrestricted_callback=false, task_callable=Callable())` | `(String, Callable, bool, bool, bool, bool, Callable) -> Dictionary` | Prediction-safe counterpart with the same bounded task callback. |
| `resolve_tag_identifier(id)` / `resolve_attribute_identifier(id)` / `resolve_ability_identifier(id)` | `(int) -> String` | `DefinitionId -> identifier` resolvers for the raw numeric ids carried by `tag_changed`/`attribute_changed`/ability-owning events. `resolve_ability_identifier` is additive (add-granular-delta-replication-2026-07-27, Wave 4): the observer-side scratch mirror `GameplayAbilityNetworkBridge` decodes public deltas onto has no `AbilityRegistry` reference of its own to resolve a grant's `DefinitionId` back to a string for `public_state_updated`, so it calls this on the SERVED component instead — the same pattern `resolve_tag_identifier`/`resolve_attribute_identifier` already established. |
| `get_target_data_schema_for_ability(ability_identifier)` | `(String) -> Dictionary` | `{schema, max_targets, max_payload_bytes}` resolved from `target_data_schemas`, or empty if this ability declared no `target_schema` (task 7.16) |

### Enums

`Role`: `ROLE_OFFLINE_AUTHORITY=0`, `ROLE_SERVER_AUTHORITY=1`, `ROLE_NETWORK_CLIENT=2`.
`Provenance`: `PROVENANCE_AUTHORITATIVE=0`, `PROVENANCE_PREDICTED=1`.
`Phase`: `PHASE_REQUESTED=0`, `PHASE_VALIDATING=1`, `PHASE_BEGUN=2`, `PHASE_COMMITTED=3`, `PHASE_ACTIVE=4`, `PHASE_ENDED=5`, `PHASE_CANCELLED=6`.
`EndReason`: `END_REASON_NONE=0`, `END_REASON_EXPLICIT_SUCCESS=1`, `END_REASON_EXPLICIT_CANCEL=2`, `END_REASON_CANCEL_TAG=3`, `END_REASON_REVOKED=4`, `END_REASON_OWNER_TEARDOWN=5`, `END_REASON_AUTHORITY_CORRECTION=6`, `END_REASON_HOOK_FAILURE=7`.
`LifecycleKind`: `LIFECYCLE_GRANTED=0`, `LIFECYCLE_REVOKED=1`, `LIFECYCLE_REQUESTED=2`, `LIFECYCLE_PHASE_CHANGED=3`, `LIFECYCLE_COMMITTED=4`, `LIFECYCLE_ENDED=5`, `LIFECYCLE_CANCELLED=6`, `LIFECYCLE_FAILED=7`, `LIFECYCLE_SNAPSHOT_RESTORED=8`.
`DiagnosticEventKind`: `DIAGNOSTIC_EVENT_RECURSION_LIMIT_REACHED=0`, `DIAGNOSTIC_EVENT_CAPABILITY_VIOLATION_DETECTED=1`, `DIAGNOSTIC_EVENT_ROLE_VIOLATION_DETECTED=2`.
`EffectLifecycleKind`: `EFFECT_LIFECYCLE_APPLIED=0`, `EFFECT_LIFECYCLE_STACK_CHANGED=1`, `EFFECT_LIFECYCLE_PERIODIC_EXECUTED=2`, `EFFECT_LIFECYCLE_REMOVED=3`, `EFFECT_LIFECYCLE_EXPIRED=4`.
`EffectRemovalReason`: `EFFECT_REMOVAL_NONE=0`, `EFFECT_REMOVAL_EXPLICIT=1`, `EFFECT_REMOVAL_EXPIRED=2`, `EFFECT_REMOVAL_REPLACED_BY_STACK_POLICY=3`.
`CuePhase`: `CUE_PREDICT=0`, `CUE_CONFIRM=1`, `CUE_CORRECT=2`, `CUE_CANCEL=3`, `CUE_AUTHORITY_ONLY=4`, `CUE_SNAPSHOT_RESTORED=5`.

Task enums mirror [`tasks.md`](tasks.md): `TaskLifecycleKind`,
`TaskOutcome`, `TaskCancelReason`, and `LogicalInputPhase`. Task request
kind/visibility/prediction enums live on `GameplayAbilityTaskRequest`.

`StatusCode` — every `status.code` value either class's Dictionaries can
carry (mirrors `ga::StatusCode` exactly; additive, never renumbered):

| Value | Name | | Value | Name |
|---|---|---|---|---|
| 0 | `STATUS_OK` | | 88 | `STATUS_HOOK_FAILED` |
| 1 | `STATUS_INVALID_ARGUMENT` | | 100 | `STATUS_UNKNOWN_ABILITY` |
| 2 | `STATUS_NOT_FOUND` | | 101 | `STATUS_ABILITY_NOT_GRANTED` |
| 3 | `STATUS_ALREADY_EXISTS` | | 102 | `STATUS_ABILITY_ALREADY_GRANTED` |
| 4 | `STATUS_OUT_OF_BOUNDS` | | 103 | `STATUS_ABILITY_ALREADY_ACTIVE` |
| 5 | `STATUS_ARITHMETIC_ERROR` | | 104 | `STATUS_ABILITY_MISSING_TAG` |
| 6 | `STATUS_CAPACITY_EXCEEDED` | | 105 | `STATUS_ABILITY_BLOCKED_TAG` |
| 7 | `STATUS_NOT_SUPPORTED` | | 106 | `STATUS_ABILITY_ON_COOLDOWN` |
| 8 | `STATUS_INTERNAL_ERROR` | | 107 | `STATUS_ABILITY_COST_UNAFFORDABLE` |
| 20 | `STATUS_INVALID_IDENTIFIER` | | 108 | `STATUS_ABILITY_INVALID_TARGET` |
| 21 | `STATUS_DUPLICATE_DEFINITION` | | 109 | `STATUS_ABILITY_ALREADY_ENDED` |
| 22 | `STATUS_UNKNOWN_DEFINITION` | | 110 | `STATUS_ABILITY_REVOKED` |
| 23 | `STATUS_INVALID_REFERENCE` | | 111 | `STATUS_ABILITY_POLICY_VIOLATION` |
| 24 | `STATUS_REGISTRY_SEALED` | | 112 | `STATUS_RECURSION_LIMIT` |
| 25 | `STATUS_MANIFEST_MISMATCH` | | 113 | `STATUS_CAPABILITY_VIOLATION` |
| 40 | `STATUS_UNKNOWN_TAG` | | 140 | `STATUS_ROLE_VIOLATION` |
| 41 | `STATUS_UNKNOWN_TAG_SOURCE` | | 141 | `STATUS_NOT_AUTHORITY` |
| 42 | `STATUS_TAG_COUNT_UNDERFLOW` | | 142 | `STATUS_NOT_OWNER` |
| 43 | `STATUS_INVALID_QUERY` | | 143 | `STATUS_PERMISSION_DENIED` |
| 60 | `STATUS_UNKNOWN_ATTRIBUTE` | | 144 | `STATUS_NETWORK_UNAVAILABLE` |
| 61 | `STATUS_INVALID_BOUNDS` | | 145 | `STATUS_PROTOCOL_MISMATCH` |
| 62 | `STATUS_INSUFFICIENT_ATTRIBUTE` | | 146 | `STATUS_SESSION_MISMATCH` |
| 63 | `STATUS_UNKNOWN_MODIFIER` | | 147 | `STATUS_STALE_COMMAND` |
| 80 | `STATUS_UNKNOWN_EFFECT` | | 148 | `STATUS_DUPLICATE_COMMAND` |
| 81 | `STATUS_INVALID_EFFECT_SPEC` | | 149 | `STATUS_RATE_LIMITED` |
| 82 | `STATUS_EFFECT_REQUIREMENTS_FAILED` | | 150 | `STATUS_SEQUENCE_GAP` |
| 83 | `STATUS_EFFECT_IMMUNE` | | 151 | `STATUS_DECODE_FAILED` |
| 84 | `STATUS_EFFECT_STACK_REJECTED` | | 152 | `STATUS_PAYLOAD_TOO_LARGE` |
| 85 | `STATUS_UNKNOWN_EFFECT_HANDLE` | | 153 | `STATUS_SNAPSHOT_REQUIRED` |
| 86 | `STATUS_MISSING_SET_BY_CALLER` | | 154 | `STATUS_UNKNOWN_NETWORK_IDENTITY` |
| 87 | `STATUS_UNDECLARED_SET_BY_CALLER` | | 180–185 | `STATUS_PREDICTION_UNAVAILABLE` … `STATUS_PREDICTION_UNKNOWN_KEY` (see below) |

Prediction codes: `180 STATUS_PREDICTION_UNAVAILABLE`, `181 STATUS_PREDICTION_NOT_SAFE`,
`182 STATUS_PREDICTION_REJECTED`, `183 STATUS_PREDICTION_JOURNAL_FULL`,
`184 STATUS_PREDICTION_BASELINE_LOST`, `185 STATUS_PREDICTION_UNKNOWN_KEY`.
Task codes occupy `200–205`; typed-target codes occupy `220–225`. Their
stable names are declared in `native/core/ga_status.h`.

Every `status` Dictionary is `{code: int, diagnostic: int, detail: int, ok: bool}`
(`diagnostic` mirrors `ga::DiagnosticId`, not separately re-bound to
GDScript constants — read it as a plain int and cross-reference
`native/core/ga_status.h` or `protocol.md`/`hooks.md`'s prose where a
specific diagnostic matters).

### Dictionary shapes

**Activation request** (`request_activation`/`process_activation_batch`'s
`request` argument):

```
{
  spec: int,                       # AbilitySpecId, required
  targets: Array[int] | PackedInt64Array,  # <= MAX_TARGETS_PER_COMMAND (32), optional
  set_by_caller: Array[Dictionary{field: String, value: float}],  # <= MAX_SET_BY_CALLER (16), optional
  command_sequence: int,           # default 0
  provenance: int,                 # Provenance, default PROVENANCE_AUTHORITATIVE
  prediction_key: int,             # default 0 (INVALID_PREDICTION_KEY)
}
```

**Gameplay event** (`handle_gameplay_event`'s `event` argument):

```
{
  event_tag: String,   # required; must resolve to a registered tag identifier
  instigator: int,     # EntityId, default 0
  target: int,          # EntityId, default 0
  magnitude: float,     # default 0.0, quantized via ga::fixed_quantize
  payload_tag: int,     # opaque, default 0
}
```

**Activation result** (`request_activation`/each element of
`process_activation_batch`'s return, and the `activation_*` signal payload
minus `id`/`kind`):

```
{ status: Dictionary, execution: int, cooldown_ready_tick: int, queued: bool, pending_remote_effects: Array[Dictionary] }
```

`cooldown_ready_tick` is only meaningful when `status.code == STATUS_ABILITY_ON_COOLDOWN`.
`queued == true` means this call was deferred (reentrant call during
dispatch) — `status`/`execution` are not yet meaningful; the eventual
outcome arrives later via an `activation_*` signal.

`pending_remote_effects` (task 6.13) is every `APPLY_TARGET_EFFECT` hook
command this commit validated and accepted but whose target was not this
component's own owner — validated then previously silently discarded; now
surfaced instead so a caller can apply it on the target's own component via
`apply_pending_remote_effect`. Each entry:

```
{
  source: int, target: int,             # EntityId
  effect_definition: int, effect_identifier: String,
  level: int,
  set_by_caller: Array[Dictionary{field: String, value: float}],
  provenance: int, prediction_key: int, # informational only -- never trusted
                                         # by apply_pending_remote_effect's own
                                         # authority decision
  originating_spec: int, originating_execution: int, tick: int,
}
```

A `PENDING_REMOTE_EFFECT_DROPPED` diagnostic (native
`ga::AbilityDiagnosticKind`, not yet surfaced as a Godot signal) fires if a
C++ caller of `ga::AbilityComponent::commit_activation` supplies no
destination for a produced remote command; the Godot `commit_activation`
binding above always supplies one, so it can never trigger this from
script.

**Cancellation result** (`cancel_execution`'s return):

```
{ status: Dictionary, execution: int }
```

**Grant** (`get_grant`'s return, and every `ability_granted`/`ability_revoked`
signal payload):

```
{
  spec: int, ability: int, ability_identifier: String, level: int,
  input_id: String, revoked: bool, cooldown_handle: int,
  last_command_sequence: int, revision: int,
}
```

**Execution** (`get_execution`'s return):

```
{
  id: int, spec: int, ability: int, ability_identifier: String,
  phase: int, begin_tick: int, commit_tick: int, targets: PackedInt64Array,
  provenance: int, prediction_key: int, revision: int,
}
```

**Ability definitions array entries** (each `Dictionary` in the
`ability_definitions` property/`set_ability_definitions` argument — mirrors
`ga::AbilityDefinitionDesc` field-for-field; see also
`GameplayAbilityDefinition` below, the not-yet-wired editor-authored
counterpart):

```
{
  identifier: String,
  activation_policy: int,          # 0 MANUAL, 1 GAMEPLAY_EVENT, 2 PASSIVE_ON_GRANT
  required_tags: Dictionary,       # {all_of, any_of, none_of} — see "Tag requirement shape" below
  blocked_tags: Dictionary,
  cancel_tags: Dictionary,
  owned_tags: PackedStringArray,
  cost_effect: String,             # effect identifier, or "" for none
  cooldown_effect: String,
  commit_effects: PackedStringArray,
  triggers: Array[Dictionary{kind: int, input_id: String, gameplay_event_tag: String}],  # kind: 0 INPUT, 1 GAMEPLAY_EVENT
  concurrency_policy: int,         # 0 REJECT_IF_ACTIVE, 1 ALLOW_MULTIPLE
  duplicate_grant_policy: int,     # 0 REJECT, 1 REPLACE, 2 MULTI_GRANT
  revoke_policy: int,              # 0 CANCEL_ACTIVE, 1 PERMIT_COMPLETION
  prediction_policy: int,          # 0 NOT_PREDICTABLE, 1 PREDICTABLE
  hook_binding: int,               # 0 NONE, 1 AUTHORITY_ONLY, 2 PREDICTION_SAFE
  auto_commit: bool,               # default true
  ends_on_commit: bool,            # default true
  prediction_safe_declared: bool,  # default false
}
```

**Tag requirement shape** (`required_tags`/`blocked_tags`/`cancel_tags`
above, and `GameplayTagQueryResource`'s equivalent): `{all_of, any_of, none_of}`,
each an `Array` of either a plain tag-name `String` (exact match) or a
`Dictionary{tag: String, match_mode: int}` (`0` exact, `1` parent-aware).

### Signals (18)

Every payload is a `Dictionary`, emitted only after the transaction that
produced it commits (design.md's "Signals expose immutable snapshots...
deferred until the current mutation transaction completes").

| Signal | Payload arg | Shape |
|---|---|---|
| `ability_granted` | `grant: Dictionary` | Grant shape above |
| `ability_revoked` | `grant: Dictionary` | Grant shape above |
| `activation_requested` | `event: Dictionary` | Lifecycle event shape below |
| `activation_phase_changed` | `event: Dictionary` | Lifecycle event shape below |
| `activation_committed` | `event: Dictionary` | Lifecycle event shape below |
| `activation_ended` | `event: Dictionary` | Lifecycle event shape below |
| `activation_cancelled` | `event: Dictionary` | Lifecycle event shape below |
| `activation_failed` | `event: Dictionary` | Lifecycle event shape below |
| `ability_snapshot_restored` | `event: Dictionary` | Lifecycle event shape below |
| `ability_task_event` | `event: Dictionary` | immutable start/terminal/restored task event; see `tasks.md` |
| `attribute_changed` | `record: Dictionary` | `{attribute: int, old_base: float, new_base: float, old_current: float, new_current: float, requested_current: float, revision: int, transaction: int, provenance: int}` |
| `tag_changed` | `record: Dictionary` | `{tag: int, source: int, added: bool, owner_count_after: int, revision_after: int}` |
| `effect_lifecycle_changed` | `record: Dictionary` | `{id: int, kind: int, definition: int, definition_identifier: String, handle: int, source: int, target: int, stack_count_after: int, tick: int, transaction: int, removal_reason: int, provenance: int, has_hook_result: bool, hook_result: float}` |
| `effect_cue_triggered` | `cue: Dictionary` | `{id: int, target: int, definition: int, definition_identifier: String, handle: int, occurrence: int, prediction_key: int, phase: int, source: int, tick: int, cue_identifiers: PackedStringArray}` |
| `prediction_phase_changed` | `payload: Dictionary` | predict/confirm/correct/cancel presentation phase; normally driven by the component/bridge prediction runtime |
| `replication_gap_detected` | `payload: Dictionary` | `{reason_code: int, detail: int}` |
| `diagnostics_reported` | `event: Dictionary` | `{kind: int, owner: int, spec: int, execution: int, status: Dictionary, tick: int}` |
| `desync_rebuild_required` | `status: Dictionary` | snapshot rollback also failed; discard/reconfigure this quarantined component |

The nine `ability_*`/`activation_*` signals (all but the last seven rows)
share one payload shape (**Lifecycle event**), distinguished only by which
signal fired (equivalently, by `kind`):

```
{
  id: int, kind: int, owner: int, spec: int, ability: int,
  ability_identifier: String, execution: int, phase: int, end_reason: int,
  status: Dictionary, tick: int, transaction: int, provenance: int,
  prediction_key: int,
}
```

## `GameplayAbilityNetworkBridge`

A `Node` (`native/godot/gameplay_ability_network_bridge.h`) that attaches
beneath a game-selected `MultiplayerAPI` branch (see
[`integration.md`](integration.md)). One bridge instance serves exactly
one `GameplayAbilityComponent`, named by `component_path`. Never creates,
replaces, or owns a `MultiplayerPeer`.

### Properties

| Property | Type | Default | Exported? | Notes |
|---|---|---|---|---|
| `component_path` | `NodePath` | empty | yes | path to the `GameplayAbilityComponent` this bridge serves |
| `world_coordinator_path` | `NodePath` | empty | yes | path to the per-world coordinator used for typed target commands/session snapshots |
| `server_peer_id` | `int` | `1` | yes | peer id treated as "the server" for outbound RPCs on `ROLE_NETWORK_CLIENT` |
| `owner_view` | `bool` | `true` | yes | `true`: full canonical snapshot/event feed; `false`: relevance-filtered public feed only, never restores into the local component |
| `tick_rate` | `int` | `DEFAULT_TICK_RATE` (60) | yes | task 7.19: bootstrap value used only before this bridge resolves a *configured* served `GameplayAbilityComponent`; once one exists, `effective_tick_rate()` (private) defers to THAT component's own `tick_rate` for the handshake's `tick_rate` field, `RateLimiter`/`CommandGate`/`ResyncCoordinator` session timing, and `_process()`'s local advisory clock — see `GameplayAbilityComponent`'s own `tick_rate` property above for the authoritative source |
| `hidden_attribute_identifiers` | `PackedStringArray` | empty | yes | server-side visibility policy |
| `hidden_tag_identifiers` | `PackedStringArray` | empty | yes | |
| `hidden_ability_identifiers` | `PackedStringArray` | empty | yes | governs the public-state feed (`public_state_updated`) only -- never cue visibility, see `hidden_effect_identifiers` |
| `hidden_effect_identifiers` | `PackedStringArray` | empty | yes | Finding 7: the list `on_effect_cue_triggered`'s cue filter actually checks a cue's `definition_identifier` (an EFFECT identifier) against -- a hidden effect's cue never leaves the server, for ANY peer |
| `target_authorization_callback` | `Callable` | invalid | **no** (method-only: `set_target_authorization_callback`/`get_target_authorization_callback`, no `ADD_PROPERTY`) | Finding 8: called `callv([context])` with ONE Dictionary argument (`peer`, `session`, `component`, `spec`, `ability_identifier`, `targets`, `set_by_caller`, `command_sequence`, `prediction_key`, `client_tick`, `current_tick`), must return `bool`; unset means only the structural bounds check runs unless `require_target_authorization` is true |
| `require_target_authorization` | `bool` | `false` | yes | Finding 8: when true, a targeted command arriving with no callback configured is rejected fail-closed (`ABILITY_INVALID_TARGET`) instead of silently allowed |
| relevant-peer override | `PackedInt32Array` | empty | **no** (method-only: `set_relevant_peers`, no getter, no `ADD_PROPERTY`) | empty means "every currently connected peer is relevant" |

### Methods

**Wiring / role / transport**

| Method | Signature |
|---|---|
| `is_multiplayer_active()` | `() -> bool` |
| `get_estimated_tick()` | `() -> int` — presentation-only estimate; server ticks always govern validation |

**Server-side ownership** (per design.md's "Server-Controlled Ownership and Permission")

| Method | Signature |
|---|---|
| `begin_session(peer, session)` | `(int, int) -> void` |
| `end_session(peer)` | `(int) -> void` |
| `authorize_control(peer, entity)` | `(int, int) -> bool` |
| `revoke_control(peer, entity)` | `(int, int) -> bool` |
| `authorize_server_entity(entity)` | `(int) -> bool` |
| `drop_peer(peer)` | `(int) -> void` |

**Activation**

| Method | Signature | Notes |
|---|---|---|
| `request_activation_networked(request, client_tick)` | `(Dictionary, int) -> Dictionary` | `request` is the identical shape `GameplayAbilityComponent.request_activation` takes, plus optional `command_sequence`/`prediction_key` fields the bridge reads directly. Returns `{status, sent: bool}`. On `ROLE_OFFLINE_AUTHORITY`/`ROLE_SERVER_AUTHORITY`: validates/executes locally (`sent = false`, real result immediately). On `ROLE_NETWORK_CLIENT` with an active peer: encodes and sends an RPC (`sent = true`, real result arrives later via `command_acknowledged`/`command_rejected`). On `ROLE_NETWORK_CLIENT` with no active peer: `{status: NETWORK_UNAVAILABLE, sent: false}` — never silently becomes authority. |
| `request_task_input_networked(task, phase, command_sequence, client_tick, prediction_key=0)` | `(...) -> Dictionary` | Local authority or bounded owner-to-server Ability Task input. |
| `request_target_command_networked(session, kind, intent, command_sequence, session_sequence, client_tick, prediction_key=0)` | `(...) -> Dictionary` | Sends submit/confirm/cancel target commands using a typed `GameplayTargetValue`. |
| `request_resync(reason)` | `(int) -> void` | client-side: request a fresh full snapshot |

**Server-side state push**

| Method | Signature | Notes |
|---|---|---|
| `push_full_state(tick)` | `(int) -> void` | call once per authoritative tick on `ROLE_SERVER_AUTHORITY`/`ROLE_OFFLINE_AUTHORITY`; no-op otherwise |
| `set_relevant_peers(peers)` | `(PackedInt32Array) -> void` | restricts `push_full_state`'s targets |

### Signals (11)

| Signal | Payload arg | Shape |
|---|---|---|
| `handshake_completed` | `result: Dictionary` | `{compatible: bool, reason: int, status: Dictionary}` — `reason` mirrors `ga::proto::HandshakeIncompatibilityReason` (see `protocol.md`'s handshake compatibility matrix) |
| `command_acknowledged` | `result: Dictionary` | `{component: int, command_sequence: int, prediction_key: int, execution: int, status: Dictionary, authority_durable_handles: PackedInt64Array}` — the last field (task 8.11) is the wire's raw ordered authority-handle list, surfaced for observability only; the actual temp→authority mapping happens internally via `predicted_effect_authority_handle` |
| `command_rejected` | `result: Dictionary` | same shape as `command_acknowledged` (`authority_durable_handles` is always empty for a rejection) |
| `state_synced` | `info: Dictionary` | `{confirmed_sequence: int}` |
| `replication_gap` | `info: Dictionary` | a `status` Dictionary directly (`{code, diagnostic, detail, ok}`) |
| `public_state_updated` | `state: Dictionary` | `{entity_id: int, tick: int, attributes: Dictionary[String, float], tags: PackedStringArray, granted_abilities: PackedStringArray, observable_tasks: Array[Dictionary]}` — never includes set-by-caller values, source context, target data, or prediction metadata (task 7.11). `observable_tasks` (protocol 3, additive) lists every currently active `OBSERVABLE` task as `{task: int, execution: int, ability_identifier: String, kind: int, start_tick: int, has_deadline: bool, deadline_tick: int}` (`deadline_tick` is `-1` when `has_deadline` is `false`); see `protocol.md`'s "Task state visibility" section for the whitelist this is built from |
| `cue_received` | `cue: Dictionary` | `{component: int, id: int, target: int, definition: int, handle: int, occurrence: int, prediction_key: int, phase: int, source: int, tick: int, cue_identifiers: PackedStringArray}` — Finding 7: on the OBSERVER side of a relayed `_rpc_presentation_event` (never on the owner's own copy), `prediction_key`/`handle`/`source` arrive zeroed/invalid — see "Owner and Observer Visibility" below |
| `network_diagnostic` | `info: Dictionary` | a `status` Dictionary directly |
| `target_outcome_received` | `result: Dictionary` | bounded acknowledged/rejected/corrected typed-target result |
| `target_state_synced` | `info: Dictionary` | owner-visible active targeting-session reconstruction |
| `remote_effects_pending` | `payload: Dictionary` | **Deprecated compatibility seam.** Existing manual routers may consume legacy hook commands; new code uses typed commands and coordinator batches. An unconsumed non-empty legacy list still emits `REMOTE_EFFECT_UNCONSUMED`. |

### Owner and Observer Visibility -- cue redaction (Finding 7)

`on_effect_cue_triggered` (the `effect_cue_triggered` -> `PRESENTATION_EVENT` forwarder) now builds and encodes TWO wire variants per cue, once, and picks between them per relevant peer via `peer_is_owner(peer)`:

- **Owner** receives the cue unchanged: `prediction_key`, `handle`, and `source` all carry their real values.
- **Observer** receives a redacted copy: `prediction_key = INVALID_PREDICTION_KEY` (a prediction detail), `handle = 0` (internal effect bookkeeping), and `source = INVALID_ENTITY_ID` (source context) -- exactly the categories the "Owner and Observer Visibility" requirement names as never part of any observer-facing feed. `component`/`id`/`target`/`definition`/`occurrence`/`phase`/`tick`/`cue_identifiers` are unchanged -- enough for an observer to play a deduplicated cue on the right entity, and nothing more.

A peer not yet in `handshake_ok_peers` is skipped entirely in the cue send loop too (consistency with `push_full_state`'s own Finding 3b handshake gate) -- never sent either variant.

### Prediction is wired into the Godot layer (task 8.10)

`GameplayAbilityComponent` owns one `ga::PredictingComponent` and one
`ga::PredictionReconciler` for a `ROLE_NETWORK_CLIENT` component,
constructed at the end of a successful `configure()` (see that class's
"C++-only collaborator seams" section — these are non-ClassDB accessors,
`predicting_component()`/`prediction_reconciler()`, reachable only from
other `native/godot/` code such as the bridge, since `Variant` cannot
marshal the core types). `GameplayAbilityNetworkBridge.request_activation_networked`
tries local prediction first (`PredictingComponent::request`) whenever the
caller has not already supplied its own `prediction_key` — a caller that
already ran its own predicted `request_activation(..., PROVENANCE_PREDICTED)`
composing directly against the pre-existing seams below is treated as a
pass-through, unmodified, so that pattern keeps working. On a `PREDICTED`
outcome the returned Dictionary carries `prediction_mode`
(`GameplayAbilityNetworkBridge.PredictionMode`, mirroring `ga::PredictionMode`);
`command_acknowledged`/`command_rejected` feed
`PredictionReconciler::handle_acknowledgement`, and a rejection or a
detected replication gap drives `reconcile(...)`, resending any
still-eligible replayed commands. `notify_prediction_phase`/
`prediction_phase_changed` is now driven for real by the component's own
presentation-listener wiring, with predict/confirm/correct/cancel phases
and a `{target, definition, handle, occurrence}` dedup identity matching
`ga::CueDedupId` field-for-field, so `runtime/ga_cue_adapter.gd`'s existing
dedup logic works unmodified.

Task 8.11 closed the gap this section used to describe here:
`CommandResultWire` (this bridge's own COMMAND_ACK/COMMAND_REJECT wire
shape) now carries `authority_durable_handles` -- an ordered list of every
durable (non-instant) effect handle the accepted commit actually produced
that a predicting client would also have journaled a temp handle for
(today, exactly the cooldown's handle, if this commit applied one; see
`ga_prediction.cpp`'s own `predict_full`, whose `SELF_EFFECT_APPLIED` op
never captures a declared commit effect's handle -- a separate,
pre-existing gap this task does not extend). `feed_prediction_acknowledgement`
zips this list, positionally, against this component's own journaled temp
handles before calling `PredictionReconciler::handle_acknowledgement`, so
`ga::PredictionAck`'s `temp_handles`/`authority_handles` are populated for
real and a predicted cooldown's temporary handle now maps to its
authoritative counterpart via `PredictionHandleMap`.
`GameplayAbilityComponent.predicted_effect_authority_handle(temp_handle)`
reads that mapping back out. No protocol-version bump: see
`protocol.md`'s "Versioning" section -- this is a purely additive,
bounded, fail-closed wire field on a protocol that has never shipped.

`get_estimated_tick()` now delegates to `ga::ServerTickEstimator`
(`gameplay_ability_network_bridge.cpp`'s `correct_estimated_tick`/
`local_tick_counter` members) instead of a second, bridge-local
snap/smooth implementation — one implementation, not two.

## Typed targeting value classes

These are immutable `RefCounted` wrappers. See
[`targeting.md`](targeting.md) for provider contracts, trust boundaries,
sessions, and transaction semantics.

### `GameplayTargetValue`

Static factories: `entity_set(entities)`, `point_2d/3d(point)`,
`direction_2d/3d(direction)`, `ray_2d/3d(origin, direction, length)`, and
`hit_set(hits)`.

Read-only methods: `get_kind()`, `get_dimension()`, `is_canonical()`,
`get_entities()`, the typed point/direction/ray accessors, `get_hits()`, and
`to_dictionary()`. Local factories hold engine vectors only until a
coordinator canonicalizes them; coordinator-returned values dequantize with
their schema's scale while retaining canonical integers for serialization.

### `GameplayTargetHit`

`hit_2d/3d(position, normal, distance, entity=0, surface_tag_id=0)` are the
only constructors. Read-only accessors expose dimension, optional stable
entity/surface tag, position, normal, distance, and `to_dictionary()`.

### `GameplayValidatedTargetData`

Constructing this class directly creates an invalid carrier. Only a configured
authority coordinator can populate the private provenance seal. Read-only
methods are `is_valid()`, `get_source()`, `get_execution()`,
`get_session()`, `get_schema_id()`, `get_schema_version()`,
`get_authority_tick()`, `get_canonical_intent()`, `get_result()`, and
`get_provider_outcomes()`.

## `GameplayAbilityWorldCoordinator`

An explicit per-world `Node`, never an autoload. Its two properties are
`definition_catalog` and `target_data_schemas`; call `configure()` before
registration.

| Area | Public methods |
|---|---|
| Components | `register_component(component, authoritative=true)`, `unregister_component(entity, tick)`, `has_component(entity)` |
| Providers | `register_authority_provider(...)`, `register_preview_provider(...)`, `validate_provider_contracts()`, `preview_target(...)` |
| Direct origins | `resolve_direct(...)`, `resolve_gameplay_event(...)`, `resolve_ai(...)`, `resolve_test(...)` |
| Sessions | `begin_targeting(...)`, `attach_targeting(...)`, `submit_target_intent(...)`, `confirm_target(...)`, `cancel_target(...)`, `advance_to(tick)`, `get_target_session(session)`, `active_target_sessions()` |
| Effects | `apply_effect_batch(validated_data, source_effects, target_effects, tick)` |
| Restore | `write_snapshot(audience=2)`, `restore_snapshot(bytes)`, `notify_restored_sessions(tick)` |

Signals are `target_session_changed(event)` and
`component_pruned(entity)`. Provider callables and every Dictionary return
shape are documented with examples in [`targeting.md`](targeting.md).

## Authoring `Resource` classes

Every editor-visible definition type under `native/resources/`. Each is
"pure data" — validated and resolved against the sealed core registries by
`GameplayDefinitionValidator` (see [`authoring.md`](authoring.md)), never
by the resource class itself. Full authoring workflow, the identifier
rule, and quantization are in `authoring.md`; this section is the
property/enum reference only.

### `GameplayDefinitionCatalog`

The project-wide, explicit source of definition identity — see
`authoring.md`'s "The project definition catalog: identity vs. runtime
state". Pure data; owns no runtime registry or gameplay state of its own.

| Property | Type | Notes |
|---|---|---|
| `tag_definitions` | `Array[GameplayTagDefinition]` | |
| `attribute_definitions` | `Array[GameplayAttributeDefinition]` | |
| `effect_definitions` | `Array[GameplayEffectDefinition]` | |
| `ability_definitions` | `Array[GameplayAbilityDefinition]` | **strictly typed**, unlike `GameplayAbilityComponent.ability_definitions` (which also accepts raw Dictionaries) — the catalog has no Dictionary form |
| `cue_definitions` | `Array[GameplayCueDefinition]` | |
| `target_data_schemas` | `Array[GameplayTargetDataSchema]` | |
| `tag_reactions` | `Array[GameplayTagReactionDefinition]` | see [`reactions.md`](reactions.md) |

### `GameplayTagDefinition`

| Property | Type | Notes |
|---|---|---|
| `identifier` | `StringName` | ≥ 2 dotted segments — see `authoring.md` |
| `description` | `String` | |
| `source_label` | `String` | duplicate-conflict diagnostic label; falls back to the resource's own path if empty |

### `GameplayAttributeDefinition`

| Property | Type | Notes |
|---|---|---|
| `identifier` | `StringName` | |
| `default_base` | `double` | quantized at validation time |
| `has_min` / `min_value` | `bool` / `double` | `min_value` hidden in the inspector unless `has_min` |
| `has_max` / `max_value` | `bool` / `double` | `max_value` hidden unless `has_max` |
| `display_name` | `String` | |

### `GameplayEffectDefinition`

| Property | Type | Notes |
|---|---|---|
| `identifier` | `StringName` | |
| `duration_policy` | `DurationPolicy` | `DURATION_INSTANT=0`, `DURATION_DURATION=1`, `DURATION_INFINITE=2` |
| `duration_ticks` | `int64` | meaningful only for `DURATION_DURATION` |
| `has_period` / `period_ticks` | `bool` / `int64` | `period_ticks` meaningful only when `has_period` |
| `modifiers` | `Array[GameplayModifierDeclaration]` | |
| `granted_tags` | `PackedStringArray` | |
| `source_requirements` / `target_requirements` | `GameplayTagQueryResource` | |
| `immunity` | `GameplayTagQueryResource` | evaluated against the target; satisfying it rejects application |
| `stacking` | `GameplayStackingPolicy` | |
| `set_by_caller_fields` | `Array[GameplaySetByCallerField]` | |
| `cue_identifiers` | `PackedStringArray` | each must be declared by a `GameplayCueDefinition` in the same validated set |
| `prediction_safe` | `bool` | declares eligibility for the v1 prediction-safe self-effect set — see `hooks.md` |

### `GameplayModifierDeclaration`

| Property | Type | Notes |
|---|---|---|
| `target_attribute` | `StringName` | |
| `op` | `Op` | `OP_ADD=0`, `OP_MULTIPLY=1`, `OP_OVERRIDE=2` |
| `magnitude` | `GameplayMagnitude` | |
| `priority` | `int` | stable tie-breaker within a phase |

### `GameplayMagnitude`

| Property | Type | Notes |
|---|---|---|
| `kind` | `Kind` | `KIND_CONSTANT=0`, `KIND_ABILITY_LEVEL=1`, `KIND_SOURCE_ATTRIBUTE=2`, `KIND_TARGET_ATTRIBUTE=3`, `KIND_SET_BY_CALLER=4` |
| `coefficient` | `double` | resolved value is `coefficient * raw_value`; `raw_value` is `1` for `KIND_CONSTANT` |
| `attribute` | `StringName` | only for `KIND_SOURCE_ATTRIBUTE`/`KIND_TARGET_ATTRIBUTE` |
| `set_by_caller_field` | `StringName` | only for `KIND_SET_BY_CALLER`; must name a field the owning effect declares |

### `GameplayStackingPolicy`

| Property | Type | Notes |
|---|---|---|
| `stackable` | `bool` | every other field below is hidden in the inspector when false |
| `stack_key` | `String` | defaults to the owning effect's own identifier if empty |
| `source_scope` | `SourceScope` | `SOURCE_SCOPED=0`, `TARGET_SCOPED=1` |
| `max_stacks` | `int` | |
| `overflow_policy` | `OverflowPolicy` | `OVERFLOW_REJECT=0`, `OVERFLOW_REFRESH=1`, `OVERFLOW_REPLACE=2`, `OVERFLOW_APPLY_EFFECT=3` |
| `refresh_duration_on_add` | `bool` | |
| `reset_period_on_add` | `bool` | |
| `removal_rule` | `RemovalRule` | `REMOVE_SINGLE_STACK=0`, `REMOVE_ALL_STACKS=1` |
| `overflow_effect` | `StringName` | only permitted non-empty when `overflow_policy == OVERFLOW_APPLY_EFFECT` — see `hooks.md`'s overflow-chain prediction subtlety |

### `GameplayTagOperand`

| Property | Type | Notes |
|---|---|---|
| `tag` | `StringName` | |
| `match_mode` | `MatchMode` | `MATCH_EXACT=0`, `MATCH_PARENT_AWARE=1` |

### `GameplayTagQueryResource`

| Property | Type | Notes |
|---|---|---|
| `all_of` / `any_of` / `none_of` | `Array[GameplayTagOperand]` | any list may be empty; an entirely empty resource is the trivial always-true query |

### `GameplayTagReactionDefinition`

See [`reactions.md`](reactions.md) for full semantics; this is the
property reference only. Only meaningful inside a
`GameplayDefinitionCatalog`'s `tag_reactions` collection — there is no
legacy per-component reaction array.

| Property | Type | Notes |
|---|---|---|
| `identifier` | `StringName` | ≥ 2 dotted segments — see `authoring.md` |
| `operand` | `GameplayTagOperand` | the observed tag + exact/parent-aware match mode |
| `mode` | `Mode` | `MODE_ON_ADDED=0`, `MODE_ON_REMOVED=1`, `MODE_WHILE_PRESENT=2` |
| `effect_identifier` | `StringName` | resolved against the same catalog's `effect_definitions`; applied from the owning component to itself only — v1 has no target selector |

### `GameplayCueDefinition`

| Property | Type | Notes |
|---|---|---|
| `identifier` | `StringName` | |
| `display_name` | `String` | |
| `description` | `String` | |
| `category` | `StringName` | free-form logical grouping (`"vfx"`, `"audio"`, `"hud"`, `"animation"`, ...); never a framework/resource reference |

### `GameplayTargetDataSchema`

| Property | Type | Notes |
|---|---|---|
| `identifier` | `StringName` | |
| `schema_version` | `int` | bumped whenever the schema's shape changes |
| `intent_kind` / `result_kind` | `ValueKind` | entity set, point, direction, ray, or hit set |
| `spatial_dimension` | `SpatialDimension` | none, 2D, or 3D; Inspector hides spatial-only fields when not applicable |
| `coordinate_space` | `StringName` | stable registered contract label, not a `NodePath` |
| `coordinate_scale` / `precision_raw` / `max_coordinate_raw` | `int64` | canonical fixed-point quantization and range |
| `min_entities` / `max_entities` | `int` | entity cardinality; `max_targets` remains a deprecated alias for `max_entities` |
| `min_hits` / `max_hits` | `int` | hit cardinality |
| `max_payload_bytes` | `int` | canonical value byte cap |
| `entity_order` | `EntityOrder` | canonical by ID or provider-ranked |
| `duplicate_policy` | `DuplicatePolicy` | reject or stable-first deduplicate |
| `allow_self` / `allow_empty` | `bool` | schema-level intent/result policy |
| `session_mode` | `SessionMode` | instant, explicit confirm, or confirm/cancel |
| `acceptance_policy` | `AcceptancePolicy` | require all, require any, or allow empty |
| `authority_provider` / `provider_contract_version` | `StringName` / `int` | stable provider handshake contract |
| `result_visibility` | `ResultVisibility` | owner-only, observable, or internal |
| `deadline_ticks` / `max_submissions` / `max_provider_work` | `int64` / `int` / `int` | bounded session/provider work |
| `preview_allowed` / `prediction_policy` | `bool` / `PredictionPolicy` | presentation preview and prediction restrictions |
| `description` | `String` | |

Every behavior-affecting field is converted into the sealed core schema,
validated by `GameplayDefinitionValidator`, and folded into the content
manifest. An ability's `target_schema` names one registered schema.
Inspector visibility is kind-sensitive, and provider/schema references are
catalog validated.

### `GameplayAbilityTaskRequest`

| Property group | Fields |
|---|---|
| Common | `kind`, `has_deadline`, `deadline_tick`, `visibility`, `prediction_policy` |
| Wait ticks | `wait_ticks` |
| Gameplay event | `gameplay_event_tag`, `gameplay_event_match` |
| Tag query | `tag_query`, `tag_edge`, `complete_if_already_satisfied` |
| Logical input | `logical_input`, `logical_phase` |
| Authority | `authority_prediction_key` |
| Target data | `target_schema` |

The Inspector shows only the selected kind's fields. Runtime submission
rejects hidden/stale payload from any other kind. Enum names and examples
are in [`tasks.md`](tasks.md).

### `GameplayNetworkPolicy`

| Property | Type | Feeds |
|---|---|---|
| `hidden_attribute_identifiers` | `PackedStringArray` | `GameplayAbilityNetworkBridge.set_hidden_attribute_identifiers` |
| `hidden_tag_identifiers` | `PackedStringArray` | `GameplayAbilityNetworkBridge.set_hidden_tag_identifiers` |
| `hidden_ability_identifiers` | `PackedStringArray` | `GameplayAbilityNetworkBridge.set_hidden_ability_identifiers` |
| `default_relevant_peers` | `PackedInt32Array` | `GameplayAbilityNetworkBridge.set_relevant_peers` |
| `owner_view_default` | `bool` | `GameplayAbilityNetworkBridge.set_owner_view` |
| `resync_rate_limit_per_minute` | `int` | **declarative only** — no bridge setter exists; the bridge always uses the fixed `ga::MAX_RESYNCS_PER_MINUTE` budget |
| `prediction_opt_in` | `bool` | **declarative only** — an ability's own `prediction_policy` governs whether it predicts, not this field; see "Prediction is wired into the Godot layer" below |

`runtime/ga_network_policy_bridge.gd` (`GameplayNetworkPolicyBridge.apply()`)
reads this resource and pushes `hidden_attribute_identifiers`/
`hidden_tag_identifiers`/`hidden_ability_identifiers`/
`default_relevant_peers`/`owner_view_default` onto a
`GameplayAbilityNetworkBridge`'s existing setters in one call (task 9.1's
remainder; see [`integration.md`](integration.md)). It is a one-way,
one-time push — call it again after mutating the policy resource for the
change to take effect. Finding 7's new `hidden_effect_identifiers` bridge
property (see above) has no counterpart field on THIS resource yet -- a
game using `GameplayNetworkPolicy` today still calls
`GameplayAbilityNetworkBridge.set_hidden_effect_identifiers()` directly.
`resync_rate_limit_per_minute` and
`prediction_opt_in` remain **declarative-only**: the bridge always enforces
the fixed `ga::MAX_RESYNCS_PER_MINUTE` budget and has no exposed setter to
override it, and prediction eligibility is governed by each ability's own
`prediction_policy`, not this resource — `GameplayNetworkPolicyBridge.apply()`
intentionally does not touch either field. A game may still call the
bridge's setters directly instead of using the bridge helper.

### `GameplayAbilityDefinition`

| Property | Type | Notes |
|---|---|---|
| `identifier` | `StringName` | |
| `activation_policy` | `ActivationPolicy` | `ACTIVATION_MANUAL=0`, `ACTIVATION_GAMEPLAY_EVENT=1`, `ACTIVATION_PASSIVE_ON_GRANT=2` |
| `required_tags` / `blocked_tags` / `cancel_tags` | `GameplayTagQueryResource` | evaluated against the owner |
| `owned_tags` | `PackedStringArray` | granted for as long as an execution stays `ACTIVE` |
| `cost_effect` / `cooldown_effect` | `StringName` | effect identifier, or empty for none |
| `commit_effects` | `PackedStringArray` | |
| `triggers` | `Array[GameplayAbilityTrigger]` | |
| `concurrency_policy` | `ConcurrencyPolicy` | `CONCURRENCY_REJECT_IF_ACTIVE=0`, `CONCURRENCY_ALLOW_MULTIPLE=1` |
| `duplicate_grant_policy` | `DuplicateGrantPolicy` | `DUPLICATE_GRANT_REJECT=0`, `DUPLICATE_GRANT_REPLACE=1`, `DUPLICATE_GRANT_MULTI_GRANT=2` |
| `revoke_policy` | `RevokePolicy` | `REVOKE_CANCEL_ACTIVE=0`, `REVOKE_PERMIT_COMPLETION=1` |
| `prediction_policy` | `PredictionPolicy` | `PREDICTION_NOT_PREDICTABLE=0`, `PREDICTION_PREDICTABLE=1` |
| `hook_binding` | `HookBinding` | `HOOK_BINDING_NONE=0`, `HOOK_BINDING_AUTHORITY_ONLY=1`, `HOOK_BINDING_PREDICTION_SAFE=2` |
| `auto_commit` | `bool` | default `true` |
| `ends_on_commit` | `bool` | default `true` |
| `prediction_safe_declared` | `bool` | hidden unless `prediction_policy == PREDICTION_PREDICTABLE`; see `hooks.md` |

`GameplayAbilityComponent.set_ability_definitions`/`ability_definitions`
stay a plain `Array` (task 12.3's ergonomic follow-up widened `configure()`
to accept either element shape, not the property's declared type, which
was already untyped): each entry may be a Dictionary (see the shape above)
**or** a `GameplayAbilityDefinition` resource directly — `configure()`
converts a resource entry through the identical field-for-field mapping
`GameplayAbilityDefinitionBridge.to_dictionary()`
(`runtime/ga_ability_definition_bridge.gd`) already used, so a caller may
pass a `TypedArray[GameplayAbilityDefinition]` (or a mixed `Array`)
straight in and skip that conversion step entirely; the bridge script
remains available as an explicit, optional convenience for a caller that
wants the Dictionary shape itself (e.g. to inspect or mutate it before
passing it in). One additional field beyond the table above is read from
either shape: `target_schema` (`StringName`/Dictionary key `"target_schema"`),
naming a `GameplayTargetDataSchema` this ability's target data must
conform to — see that resource's own entry above (task 7.16).

### `GameplayAbilityTrigger`

| Property | Type | Notes |
|---|---|---|
| `kind` | `Kind` | `KIND_INPUT=0`, `KIND_GAMEPLAY_EVENT=1` |
| `input_id` | `String` | only for `KIND_INPUT`; opaque, never a Godot `InputEvent` (see `integration.md`) |
| `gameplay_event_tag` | `StringName` | only for `KIND_GAMEPLAY_EVENT`; must name a registered tag |

### `GameplaySetByCallerField`

| Property | Type | Notes |
|---|---|---|
| `identifier` | `StringName` | a lightweight single-segment name, matched only against the same effect's own declaration — never registered in a shared registry |
| `required` | `bool` | |

## See also

- [`integration.md`](integration.md) — how a game reaches these methods
  from input, AI, replay, and the network session.
- [`hooks.md`](hooks.md) — the typed hook contract these signals and
  the `hook_binding`/`prediction_policy` fields above connect to.
- [`authoring.md`](authoring.md) — the resource-authoring workflow, the
  identifier rule, and the editor validator.
- [`protocol.md`](protocol.md) — wire byte layouts, versioning, and the
  full `ga_limits.h` constants table this document's bounds reference.
- [`reactions.md`](reactions.md) — `GameplayTagReactionDefinition`/
  `GameplayDefinitionCatalog.tag_reactions` runtime semantics in full.
- [`tasks.md`](tasks.md) — deterministic waits, logical input, hooks,
  snapshots, prediction, and migration.
- [`targeting.md`](targeting.md) — typed values, schemas, providers,
  sessions, coordinated batches, security, and migration.
- [`editor_workflows.md`](editor_workflows.md) — how to author every
  reference property above through the Inspector.
