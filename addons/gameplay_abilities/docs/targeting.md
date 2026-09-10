# Typed Ability Targeting

Typed targeting separates untrusted intent from canonical intent and
authority-validated results. It gives direct attacks, ground points,
directions, rays, hit records, interactive confirmation, AI selection, and
multi-target effects one bounded pipeline.

The core never owns a camera, physics world, faction system, reticle, UI, or
navigation query. Games register those algorithms as providers on an explicit
per-world `GameplayAbilityWorldCoordinator`.

## Trust model

The pipeline has three stages:

1. `TargetIntent`: local controller, AI, gameplay event, test, or remote owner
   input. It is not authority provenance.
2. `CanonicalTargetIntent`: kind/cardinality/quantization/order/duplicate/self
   validation under a registered schema.
3. `GameplayValidatedTargetData`: authority-provider result with schema,
   source, ability/execution/session, authority tick, canonical intent, typed
   result, and per-entity outcomes.

Only the current authority coordinator can construct valid
`GameplayValidatedTargetData`. A client boolean, serialized dictionary, or
forged provenance value cannot drive an authoritative batch.

Offline authority, listen-host input, dedicated-server AI, gameplay events,
and network clients all use the same normalization/provider path.

## Typed values

`GameplayTargetValue` is a closed tagged union:

| Kind | Local factory | Read-only accessors |
|---|---|---|
| `ENTITY_SET` | `entity_set(PackedInt64Array)` | `get_entities()` |
| `POINT` | `point_2d(Vector2)`, `point_3d(Vector3)` | `get_point_2d/3d()` |
| `DIRECTION` | `direction_2d/3d(...)` | `get_direction_2d/3d()` |
| `RAY` | `ray_2d/3d(origin, direction, length)` | `get_ray_origin_*`, `get_ray_direction_*`, `get_ray_length()` |
| `HIT_SET` | `hit_set(Array[GameplayTargetHit])` | `get_hits()` |

`GameplayTargetHit.hit_2d/3d(position, normal, distance, entity=0,
surface_tag_id=0)` creates an immutable local hit.

Local float vectors exist only until schema normalization. Canonical wire and
snapshot values are signed integers using the schema’s scale/precision. Typed
accessors dequantize with the originating schema scale and dimension;
`to_dictionary()` additionally exposes raw canonical integers for diagnostics.

## Schema contract

`GameplayTargetDataSchema` contributes every behavior-affecting field to the
content manifest:

- `identifier`, `schema_version`
- `intent_kind`, `result_kind`
- `spatial_dimension`, `coordinate_space`
- `coordinate_scale`, `precision_raw`, `max_coordinate_raw`
- `min_entities`, `max_entities`, `min_hits`, `max_hits`,
  `max_payload_bytes`
- `entity_order`, `duplicate_policy`, `allow_self`, `allow_empty`
- `session_mode`, `acceptance_policy`
- `authority_provider`, `provider_contract_version`
- `result_visibility`, `deadline_ticks`, `max_submissions`,
  `max_provider_work`
- `preview_allowed`, `prediction_policy`

Spatial schemas fix 2D or 3D explicitly. Direction/normal vectors are
normalized during canonicalization. Invalid dimensions, zero directions,
negative ray length, overflow, out-of-range coordinates, count/byte excess,
and forbidden duplicates/self/empty values fail before provider work.

Provider-ranked order is retained; canonical-by-ID schemas sort entity results
by stable `EntityId`. Duplicate policy is reject or stable-first deduplicate.

## World coordinator

Create one coordinator per game world/session:

```gdscript
var coordinator := GameplayAbilityWorldCoordinator.new()
coordinator.definition_catalog = shared_catalog
add_child(coordinator)
var findings := coordinator.configure()
assert(GameplayDefinitionValidator.is_ok(findings))

coordinator.register_component(source_component, true)
coordinator.register_component(target_component, true)
```

Use `register_component(component, false)` for network-client mirrors.
Authority registration requires an authority component role; mirror
registration requires `ROLE_NETWORK_CLIENT`. Duplicate/stale identities fail
explicitly. `unregister_component(entity, tick)` cancels affected sessions and
their attached target tasks before publication.

The coordinator is not an autoload or singleton. Two instances can reuse the
same entity numbers without sharing components, providers, sessions, batches,
or allocators.

## Authority providers

Register a stable contract:

```gdscript
coordinator.register_authority_provider(
    &"target_provider.game.radius_2d",
    1,
    GameplayTargetDataSchema.VALUE_POINT,
    GameplayTargetDataSchema.VALUE_ENTITY_SET,
    false, # prediction-safe
    64,    # max work units
    resolve_radius)
```

The resolver signature is:

```gdscript
func resolve_radius(
        context: Dictionary,
        canonical_intent: GameplayTargetValue
    ) -> Dictionary:
    return {
        "result": GameplayTargetValue.entity_set(entity_ids),
        "work_units": candidates_examined,
        "outcomes": [
            {"entity": entity_ids[0], "rank": 0, "kind": 0},
        ],
    }
```

Context fields are `source`, numeric `ability`, `execution`, `session`,
`authority_tick`, `schema_id`, `schema_identifier`, `schema_version`, and
`canonical_hash`.

A provider may instead return a structured non-OK `status`. Its result kind,
cardinality, quantization, outcomes, work count, and contract
identity/version are revalidated after the callback.

Provider rules:

- Read authoritative world state; do not mutate components, apply effects,
  grant tags, emit events, send RPCs, or update external gameplay state.
- Examine no more candidates/queries than the declared work bound.
- Return stable entity identities, never `ObjectID`, `RID`, node path, or
  collider instance identity.
- Break ranking ties deterministically.
- Version the provider contract when resolution behavior becomes incompatible.
- Treat a client hit/point/ray as intent and recompute/validate on authority.

Component mutations attempted during provider preparation are detected and
rolled back. External side effects are outside the transaction and therefore
remain prohibited.

Reference implementations for direct entity, point-to-radius,
server-selected nearest, and ray-to-hit in both 2D and 3D:
[`ga_reference_target_providers.gd`](../../../examples/gameplay_abilities/targeting/ga_reference_target_providers.gd).

## Preview providers

Preview is presentation/untrusted intent, never validated provenance:

```gdscript
coordinator.register_preview_provider(
    provider_id, version, intent_kind, result_kind,
    prediction_safe, max_work, preview_callback)
```

The callback receives context and returns:

```text
{
  status: Dictionary,                 # optional
  presentation_value: GameplayTargetValue,
  intent: GameplayTargetValue,
}
```

Call `preview_target(source, ability, execution, session, schema, tick)`.
A dedicated server need not register preview providers. Camera and local
physics previews may disagree with authority; correction/rejection is a normal
presentation state.

## Direct, AI, event, and test entry points

`resolve_direct`, `resolve_gameplay_event`, `resolve_ai`, and `resolve_test`
all normalize and invoke the same authority provider. Only the origin metadata
differs.

```gdscript
var resolved := coordinator.resolve_direct(
    source_id,
    "ability.fireball",
    GameplayTargetValue.point_3d(cursor_world_position),
    authority_tick)
if resolved["status"]["ok"]:
    var validated: GameplayValidatedTargetData = resolved["validated_data"]
```

The legacy `targets` entity array is normalized through the explicit
ENTITY_SET adapter only when an ability declares a registered compatible
schema. It does not bypass provider validation.

## Targeting sessions and `WAIT_TARGET_DATA`

Session modes:

- `SESSION_INSTANT`
- `SESSION_EXPLICIT_CONFIRM`
- `SESSION_CONFIRM_OR_CANCEL`

An ability may start a `KIND_WAIT_TARGET_DATA` task with `target_schema`, then
attach it:

```gdscript
var task_result := component.start_ability_task(
    execution, target_task_request, tick)
var session_result := coordinator.attach_targeting(
    owner_id,
    execution,
    task_result["task"],
    tick,
    initial_intent)
```

For non-task flows use `begin_targeting(owner, execution, schema, tick,
initial_intent)`.

Game-owned adapters call:

- `submit_target_intent(session, intent, sequence, tick, prediction_key)`
- `confirm_target(session, sequence, tick, latest_intent, prediction_key)`
- `cancel_target(session, sequence, tick, prediction_key)`
- `get_target_session(session)` / `active_target_sessions()`
- `advance_to(tick)`

Commands are idempotent and strictly sequenced per session. One terminal
completion/rejection/cancel/timeout is published. Parent end/cancel, revoke,
authority correction, owner teardown, and referenced entity unregistration
also tear down the session/task.

`target_session_changed` publishes immutable lifecycle dictionaries.
`notify_restored_sessions(tick)` emits distinct `RESTORED` notifications;
snapshot restore never replays requests, preview calls, submissions,
confirmations, outcomes, or task callbacks.

CommonUI preview/confirm/cancel uses the same game-owned adapter boundary
described in the
[integration guide](integration.md#feeding-ability-tasks-and-typed-targeting).
This standalone mirror deliberately does not ship a CommonUI-specific
targeting adapter.

## Atomic cross-component effect batches

Use authority-validated data:

```gdscript
var batch := coordinator.apply_effect_batch(
    validated,
    [], # source effects
    [{
        "effect": "effect.damage.fire",
        "level": 1,
        "set_by_caller": [],
    }],
    authority_tick)
```

Preparation is side-effect-free and freezes:

- provider result and per-target outcomes;
- source/target effect definitions and magnitudes;
- requirements, immunity, stack/overflow topology, and capacity;
- every participating component’s pre-batch snapshot.

Policies:

- `ACCEPT_REQUIRE_ALL`: any rejected requested target rejects the batch.
- `ACCEPT_REQUIRE_ANY`: commit the accepted subset; at least one is required.
- `ACCEPT_ALLOW_EMPTY`: an empty accepted set is valid.

Commit order is stable entity order. Events, signals, cues, and callbacks are
deferred until every participant commits. An unexpected post-preparation
invariant failure restores every captured component before external
publication.

Applied effects/cues/snapshots carry bounded immutable target context:
schema/version, source/target, ability/execution/session, authority tick,
rank/status, canonical intent, and validated result under visibility policy.

## Network and prediction

Set `GameplayAbilityNetworkBridge.world_coordinator_path` to the sibling
coordinator before the bridge enters the tree.

Owning clients use:

```gdscript
bridge.request_target_command_networked(
    session,
    command_kind, # 0 submit, 1 confirm, 2 cancel
    intent,
    global_command_sequence,
    session_sequence,
    client_tick,
    prediction_key)
```

Authority validates network session/control, live component/execution/task/
target session, schema/version/kind, global and per-session sequences,
deadline, rate, quantization/count/byte bounds, and provider output.

Signals:

- `target_state_synced(info)` for owner-visible baseline/session restore;
- `target_outcome_received(result)` for sanitized owner outcomes;
- generic `command_acknowledged` / `command_rejected`.

Outcome data is decoded presentation data only. It never constructs
authority-valid `GameplayValidatedTargetData`.

Prediction is opt-in per schema/provider. Local preview does not imply gameplay
prediction. Prediction-safe commands journal canonical intent and temporary
task/session identities; authority may accept, reject, deduplicate, reorder,
filter, or replace the result. Reconciliation restores both component and
coordinator baselines before replay.

Hidden/authority physics, secret targets, randomness, or unbounded providers
must use authority-only/preview-only policy and may pair with `WAIT_AUTHORITY`.

## Security checklist

- Never trust client-supplied entity membership, hit records, normals,
  distances, surface tags, or “validated” flags.
- Never expose private target results to observer feeds; owner-only is the
  default.
- An effect definition's `retain_target_context` keeps its immutable
  `TargetEffectContext` (schema-declared `visibility`, plus the private
  canonical intent/validated result) inside canonical active-effect state.
  A component's owner-facing full snapshot sanitizes each retained context
  per its OWN source (`OWNER_ONLY` audience if the receiving peer owns that
  source, `OBSERVABLE` otherwise) rather than handing it out at full,
  server-local fidelity — see protocol.md's "Effect target-context
  visibility" section for the full audience matrix, the own-vs-foreign
  derivation, and its one accepted over-sanitization edge (a peer owning
  both the attacker's and the target's component).
- Retained target contexts share one per-component byte budget,
  `MAX_RETAINED_TARGET_CONTEXT_BYTES` (ga_limits.h), enforced at
  effect-application time (fails closed with a structured capacity status
  before any mutation, freed again on removal) — independent of
  `MAX_ACTIVE_EFFECTS`, which bounds effect count, not the bytes any one
  retained context may carry. Content-authoring guidance: `retain_target_context`
  is for SPARSE, deliberate use — a handful of effects whose originating
  aim/hit data genuinely needs to survive a later recomputation or a resync
  (e.g. a damage-over-time effect whose tooltip shows what applied it) — not
  for every concurrent effect on a component. The budget admits 5 of the
  largest single shape (a HIT_SET `validated_result` at `MAX_TARGET_HITS`)
  at once, or many more of a smaller, more typical one; see budgets.md
  Finding 5 for the full measurement.
- Keep provider work and physics query counts explicit and bounded.
- Reject unknown schema/provider versions and incompatible feature manifests.
- Use component/session ownership and monotonic command sequences.
- Sanitize structured status/outcomes; do not echo arbitrary remote text.
- Do not store Nodes/RIDs/callables in target values or snapshots.

Global hard limits include 32 entities/hits per value, 16 active target
sessions, 4 sessions per execution, 128 submissions per session, 256 provider
work units, 32 batch participants, and 2,048 target-value bytes. Schemas should
normally choose smaller limits.

## Migrating `pending_remote_effects`

`pending_remote_effects`, `remote_effects_pending`,
`preflight_pending_remote_effect`, and `apply_pending_remote_effect` remain a
deprecated compatibility seam for existing ENTITY_SET hooks.

For new code:

1. author a target schema/provider contract;
2. create/register a world coordinator and every authority/mirror component;
3. normalize/resolve intent through the coordinator;
4. keep the ability hook focused on validation/continuation;
5. apply target effects with `apply_effect_batch`;
6. point network bridges at the coordinator;
7. add snapshot, cancellation, reconnect, rejection, and correction tests;
8. remove the manual pending-command router.

The offline and multiplayer basic-combat examples now use coordinator batches
while retaining compatibility result aliases for older UI/tests.

When a call site on step 3 still only has a raw entity id list (a
`pending_remote_effects`-style `targets` array) and cannot yet author a typed
intent directly, `adapt_legacy_entity_targets(schema, entities, source)` is
the sanctioned bridge. It never submits anything: it only normalizes the list
against a registered ENTITY_SET schema -- same duplicate/order/cardinality
rules as any other typed authoring path -- and hands back a canonical
`GameplayTargetValue` for the caller to route through the normal resolve/
session entry points:

```gdscript
var adapted := coordinator.adapt_legacy_entity_targets(
    schema_identifier, legacy_entity_ids, source_id)
if adapted["status"]["ok"]:
    var resolved := coordinator.resolve_direct(
        source_id, ability_identifier, adapted["value"], tick)
```

It only accepts a schema whose intent and result kind are both ENTITY_SET,
rejecting everything else with `INVALID_TARGET_SCHEMA` -- it never guesses a
compatible schema on the caller's behalf.
