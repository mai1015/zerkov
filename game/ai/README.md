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

Staging is mandatory once per **60 Hz authority tick**, not just the 20 Hz
perception cadence. Unchanged ticks must repeat the full frame with unchanged
revisions. An empty actor list means removal, not "no changes". A missing frame
fails closed. Runtime roster capacity is checked before publishing a staged frame.

Construction sequence (the movement handler ID comes from task 3):

```gdscript
var scav := load("res://game/ai/profiles/scav.tres") as ZAIProfile
var mutant := load("res://game/ai/profiles/mutant.tres") as ZAIProfile
var registry := RaidVisionActorRegistry.new()
assert(registry.configure(raid.generation(), scav, mutant))
# Configure/register this same exact owner only once. Do not create a second world.
assert(vision_owner.configure(world_id, {}, registry, raid.generation()))
assert(vision_owner.register_with_raid_authority(raid))
var ai := RaidAIRuntime.new()
assert(ai.configure(raid.raid_id().canonical_key(), raid.generation(), seed,
    game_ai_world_port, registry, scav, mutant))
var driver := RaidAIPhaseDriver.new()
assert(driver.bind(raid, raid.generation(), ai, movement_handler_id))
```

Registry injection requires the explicit expected raid generation (fourth
`configure` argument). Mismatches are rejected before native allocation and again
before registering with the actual raid. Registry-free task-6.1 startup is unchanged.

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
Scav reaction defaults to 18 ticks (0.3 s), mutant 12 (0.2 s); sight defaults to
18/12 tiles and memory to 180/120 ticks. `ZAIProfile` is the single authoring source
for sight, cone and memory. Pass the same profiles to the registry and runtime;
they snapshot configuration per generation. The runtime and perception adapter
reject mismatched settings. Debug FOV reads that same snapshot, not magic numbers.
Recreate the generation to apply tuning changes; this is not live hot-reconfiguration. Search paths use deterministic seed-based
offsets, not global randomness. Attack-request cadence is subordinate to actual
weapon/melee validation. These values are **not playtest-approved task 6.10**.

`action_timeout_ticks` governs fire/reload/melee receipts independently of
`path_timeout_ticks`. Retreat latches once per injury episode and rearms after
health reaches `retreat_recover_health_milli`; remaining injured does not restart
retreat on every timeout. Idle decisions emit no zero-move spam. A transition
from movement still emits an explicit stop, and a rejected stop is retried.

The default decision budget is 64; lower budgets use oldest-decision-first with
stable-ID tie breaks. Hearing is retained in a bounded inbox while deferred. Dead
actors bypass decision deferral to clear pending state. The cap is 64 tracked NPCs
(including dead entries until omitted from the root frame), 128 total actors,
128 occluder segments, and 4,096 lifetime actor identities per raid registry.

## Debugging and verification

Mount `debug/ai_debug_overlay.tscn` under world presentation. It is disabled by
default and consumes `ai.debug_snapshot()` safely between phases and after failure.
Entries missing from the newly staged actor frame are omitted; `staged_tick` and
`observer_tick` distinguish pose timing from the last decision tick. The root may
append `vision_budget = {consumed, budget, deferred}` with nonnegative integer
counters; malformed records are rejected without replacing the last good frame. Labels distinguish current/remembered
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

The runner reads its engine version exclusively from `config/toolchain.lock.json`.
Both modes import in temporary projects; `--native` copies the checkout without
`.git`, `.godot`, or `.codegraph`, so it does not modify the working import cache.
It runs the new noise-window/phase-gap regressions, and native mode also runs
`native_ai_owner_review_contract.gd` (generation rejection, missing per-tick frame,
partial native synchronization, collection failure, movement, geometry and removal).
Runner unit tests: `python3 tests/tooling/test_ai_runner.py`.

The reviewer reproduced the pre-fix `ac4ece85` native contracts on macOS with the
pinned engine and real Common Vision: Vision 438/0, owner 47/0, and matching AI
replay digests. Missing Linux artifacts were a local test-host limitation, not a
project-wide native failure. The new owner regressions require a fresh supported
native run; isolated tests or semantic stubs do not replace that gate. Per-revision
results are recorded in PR #2, not committed as log bundles.
