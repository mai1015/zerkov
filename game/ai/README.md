# Zerkov AI workstream (tasks 6.2-6.10)

Small game-specific Scav/mutant state machine. No behavior-tree dependency,
new clock, replacement movement, or direct weapon/health mutation. This branch
contains reviewable implementation, not an accepted Sawmill encounter.

## Ownership and order

| Phase | Owner/action |
| --- | --- |
| MOVEMENT (1) | Task 3 resolves poses; `ai_actor_sync` stages a complete authoritative actor/geometry frame after its named handler. |
| VISION (2) | The existing exact `RaidVisionWorldOwner` applies staged registration/update/removal inside its reserved callback. Native evaluation remains ticks 1,4,7,... at 16,384 work units. Only completed native projections are collected. |
| AI_DECISIONS (3) | `RaidAIRuntime` distributes recipient observations and own-actor facts. Brains emit path requests and next-tick action requests, never mutations. |
| TASKS_AND_AUDIT (7) | Committed gunshot/impact/sprint/interaction events resolve through `RaidNoiseService`; audible facts are consumed on the next tick. |
| Presentation | Optional `ZAIDebugOverlay` reads a detached diagnostic snapshot only. |

`RaidVisionActorRegistry` is a trusted composition port, never a capability given
to a brain or UI. It retains values, not the native Vision world. Native commands
are explicitly allowlisted; partial native failures fail-stop the registry and
quarantine the owning Vision world. A dead/removed identity cannot be revived
under the same ID. New spawned actors require new authored/runtime identities.

`VisionAIAdapter` never asks for an unseen actor's current properties. It exposes
only disclosed positions and timestamps. A deferred projection does not become
fresh: a VISIBLE record older than two raid ticks becomes remembered; history
expires without requiring another successful native query. Confidence is a
fixed presentation/policy label, not a calibrated probability.

## Root integration contract

The root supplies one concrete `RaidAIWorldPort`. Its base implementation is
unavailable and startup rejects it. The implementation must provide:

* Complete authoritative actor/geometry frames after movement. An actor is
  exactly `{entity_id, revision, position_raw, facing_raw, archetype, alive}`.
  Coordinates are checked Vision microunits. Actor revisions are identical for
  unchanged data or exactly previous+1 for a replacement. Segments come from
  task 3.10's explicit bake; no geometry is inferred from art or scene order.
* Own-actor facts through `ZAIAgent.SELF_KEYS`; patrol/cover candidates and bounded
  path results through task 3.9. A path failure or timeout means stop and retry,
  not direct wall-crossing pursuit. A newer navigation revision invalidates paths.
* Action admission through the **same movement/combat encoder used by the player**,
  then `RaidAuthority.enqueue_intent` with `ZRaidIntent.Source.AI`. The root must
  authorize each AI actor while PREPARING. Do not forward a Vector2i directly into
  `ZCanonicalValue` payloads: the shared encoder must convert it to its bounded
  integer schema. Aim/move requests carry `direction_milli`; fire/reload/melee
  carry no untrusted hit result. Equipment/weapon context stays in existing adapters.
* Actual committed/rejected receipts and committed noise events. Enqueue success
  is not an attack, hit, successful reload, or sound. Receipts are request-, actor-,
  generation-, and tick-correlated. A missing receipt times out without inventing
  effects. Cosmetic AudioStream playback never creates hearing facts.

Construction sequence (the movement handler ID comes from task 3):

```gdscript
var registry := RaidVisionActorRegistry.new()
assert(registry.configure(raid.generation()))
# Configure/register this same exact owner only once. Do not create a second world.
assert(vision_owner.configure(world_id, {}, registry))
assert(vision_owner.register_with_raid_authority(raid))
var ai := RaidAIRuntime.new()
assert(ai.configure(raid.raid_id().canonical_key(), raid.generation(), seed,
    game_ai_world_port, registry, ZAIProfile.scav(), ZAIProfile.mutant()))
var driver := RaidAIPhaseDriver.new()
assert(driver.bind(raid, raid.generation(), ai, movement_handler_id))
```

The snippet shows ownership/order, not a replacement for error handling. Keep
all owners alive in the raid composition. Use weak authority references in port
adapters to avoid owner/handler cycles. Set handler priorities/dependencies so
actor sync follows movement and noise resolution follows all phase-7 producers.
A failed callback fails the raid tick; no pending UI or AI state is a commit.

Before teardown, release the phase driver, then the Vision owner, then remaining
raid ownership. A blocked handler removal must be resolved/retried rather than
freeing its dependency. Recreate all generation-scoped components for a new raid.

## Behavior and tuning

States: idle, patrol, investigate, engage, search, retreat, dead. Scavs wait for
reaction delay, aim, request shots/reload and seek authored cover candidates.
Mutants chase visible observations and request melee at reach; task 5.8 still owns
wind-up, contact, recovery and stamina. Neither actor learns hidden health or
moves toward a hidden live transform. Hearing gives a coarse historical region,
not identity/visual confirmation. Cover candidates are not proof of protection.

`profiles/scav.tres` and `profiles/mutant.tres` are provisional starting values.
Scav reaction is 18 ticks (0.3 s), mutant 12 (0.2 s); perception remains the sealed
18/12-tile sight and 180/120-tick memory. Search paths use deterministic seed-based
offsets, not global randomness. Attack-request cadence is subordinate to actual
weapon/melee validation. These values are **not playtest-approved task 6.10**.

The default decision budget is 64; lower budgets use oldest-decision-first with
stable-ID tie breaks. Hearing is retained in a bounded inbox while deferred. Dead
actors bypass decision deferral to clear pending state. The cap is 64 tracked NPCs
(including dead entries until omitted from the root frame), 128 total actors,
128 occluder segments, and 4,096 lifetime actor identities per raid registry.

## Debugging and verification

Mount `debug/ai_debug_overlay.tscn` under world presentation. It is disabled by
default and consumes `ai.debug_snapshot()`; the root may append a detached latest
Vision telemetry record as `vision_budget`. Labels distinguish current/remembered
knowledge, paths, and decision/perception work. Never feed diagnostics into a brain.

```sh
python3 tools/run_ai_contracts.py --godot "$ZERKOV_GODOT"
# Real graphical session; optional synthetic diagnostic PNG, always exact 1080p.
python3 tools/run_ai_contracts.py --godot "$ZERKOV_GODOT" --render --capture /tmp/ai-1080.png
# Supported pinned full checkout with native addons; does not allow passing skips.
python3 tools/run_ai_contracts.py --godot "$ZERKOV_GODOT" --native
```

The default runner is an explicit isolated source allowlist, not full-game
acceptance. It executes the real game AI code with named Vision/world/authority
test doubles and the real existing noise service. Native LOS/owner tests are
separate. Missing CommonVisionWorld2D returns BLOCKED, never a pass.

Review run: standard Godot 4.7.2.stable.official.ed1daf0bf; headless contract
2,292 checks/0 failures twice, 64 NPCs over 120 ticks in both insertion orders.
Exact-1080 synthetic debug render: 8 checks/0 failures, software OpenGL with a
V-Sync warning. Native Vision and owner runs were blocked by missing Linux native
classes. The modified owner's GDScript loaded using explicit semantic test stubs;
that is not native lifecycle/authority validation. No full game, human encounter,
Windows/Linux release, or task completion checkbox is claimed by those runs.
