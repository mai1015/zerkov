# Task 3.6 — Server-Authoritative 2D Movement, Collision, Correction and Blocked-Movement Results

Task ID: 3.6 `[SOL]`
Status: Completed (implementation + evidence)
Verification binary: Godot Engine `v4.7.2.stable.official.ed1daf0bf`
(`/Volumes/Data/sdk/godot/editors/4.7.2/Godot.app/Contents/MacOS/Godot`)
Output target: exact 1920x1080 (headless contract execution)

## Outcome

Implemented the authoritative movement/collision layer as a pure game-owned
module and integrated it into the player's MOVEMENT phase so that
`ZPlayerLocomotion` no longer performs any unchecked integration step:

1. **`ZMovementWorld2D`** (`game/world/movement/z_movement_world_2d.gd`)
   - Pure simulation module: static blocking geometry and the level bounds
     rect are injected by the caller; the world never loads a scene or
     resource (asserted by a source-purity contract check).
   - One axis-aligned box body per registered actor keyed by `ZEntityId`;
     bodies spawn only at collision-free, in-bounds positions.
   - Deterministic resolution on the fixed 60 Hz tick in exact integer
     microunits (1 Godot px = 31,250 µu derived from the published
     `ZWorldUnits` constants). No physics server, no `move_and_slide`, no
     `PhysicsDirectSpaceState2D`, no frame delta, no wall clock.
   - Axis-separated resolution (X then Y, a fixed order) with exact
     wall-slide: a blocked axis clamps flush against the nearest blocking
     rect while the unblocked axis keeps its full displacement; an interior
     corner blocks both axes in one tick.
   - Level bounds clamp the body fully inside the authored world rect.
   - Canonical state (`canonical_record()` + `digest()`) is
     integer/fixed-point only and hashed with `ZCanonicalValue.sha256`.
   - Generations/teardown: `configure`, collider injection, actor
     registration, `teleport_actor`, `resolve_actor_step` and `seal` all
     validate the expected generation; replayed ticks are rejected
     (`tick_regressed`), and a sealed world rejects even the correct
     generation (`world_sealed`) so late calls against a torn-down raid are
     inert.

2. **`ZMovementResult`** (`game/world/movement/z_movement_result.gd`)
   - Typed outcome carrying resolved/requested position (micro + px),
     requested/resolved velocity, `blocked_axes` bitmask, sorted
     `blocking_collider_ids` (stable authored structure ids), a `corrected`
     flag, and a bounded integer canonical record with digest.

3. **Correction log** (in `ZMovementWorld2D`)
   - When an intent's implied displacement disagrees with the resolved
     displacement, authority wins: the body takes the resolved micro
     position and a bounded correction record (tick, actor, requested vs
     resolved position/velocity, blocked axes, collider ids) is appended to
     a 64-entry ring. `corrections_snapshot()`/`corrections_snapshot_for()`
   return deep copies only — presentation can read corrections and mutate
   the copies without any write-back path into the world (contract-checked).

4. **`ZMovementWorldBuilder`** (`game/world/movement/z_movement_world_builder.gd`)
   - The only place authored layout data is translated into injected
     geometry: reads `ZSawmillYardLayout.structures` where
     `layer == "Obstacles"`, injects each authored cell rect as one static
     collider with its stable structure id, and configures the level bounds
     from `world_bounds()` with the level identifier as bounds collider id.
     The layout is consumed duck-typed; `ZMovementWorld2D` itself never
     references the Sawmill.

5. **`ZPlayerLocomotion` integration** (`game/world/player/player_locomotion.gd`)
   - Locomotion computes only the desired velocity for the tick
     (accel/decel/stance model unchanged from task 3.5); the authoritative
     position now comes back from the movement world
     (`_resolve_authoritative_step`), and `position_px` is written only
     from a movement result. Velocity receives the resolved (blocked-axis-
     zeroed) value, so wall-slide persists across ticks.
   - A default open world (full canonical coordinate range, no colliders)
     is attached at `configure()`, so even unattached locomotion never
     performs an unchecked integration.
   - `attach_movement_world(world, half_extents)` validates generation
     match (fail-closed), registers the actor at the current position with
     a 16x16 px body (8 px half extents, documented choice inside a 32 px
     tile), and `teleport` now syncs the world body and reads the resolved
     position back (authority wins).
   - The MOVEMENT phase handler is inert when the dispatching authority
     generation no longer matches (late/replayed dispatch), and
     `publish_weapon_actor_pose` still reports the resolved pose (its
     return value is now tracked and exposed as `pose_published`).
   - `canonical_record()` gained `movement_blocked_axes`/`movement_corrected`
     integers; the 3.5 contract is unaffected (check count unchanged).

## Automated Verification

### 1. Movement Authority Contract Gate (new, task 3.6)

Command:
```bash
export GODOT_BIN=/Volumes/Data/sdk/godot/editors/4.7.2/Godot.app/Contents/MacOS/Godot
python3 tests/tooling/run_movement_authority_headless_gate.py
```

Verbatim output:
```text
--- Movement Authority contract run 1 ---
Godot Engine v4.7.2.stable.official.ed1daf0bf - https://godotengine.org

MOVEMENT_AUTHORITY_RESULT checks=539 failures=0
--- Movement Authority contract run 2 ---
Godot Engine v4.7.2.stable.official.ed1daf0bf - https://godotengine.org

MOVEMENT_AUTHORITY_RESULT checks=539 failures=0
MOVEMENT_AUTHORITY_HEADLESS_GATE runs=2 checks=1078 failures=0 diagnostics=0
```

Coverage (539 checks per run): module purity (no resource loading, no physics
server, no wall clock, no banned APIs), construction and collider injection
validation (duplicate/degenerate/stale), cell-vs-px geometry equivalence via
canonical digest, actor registration validation (spawn-in-wall,
out-of-bounds, duplicate, stale generation), free movement in the open world
(exact 66,667 µu displacement per tick at 128 px/s), head-on block (flush
clamp at 300-8 px, requested-vs-resolved micro positions, blocked axis,
authored collider id, zeroed resolved velocity), wall-slide with X blocked
and with Y blocked (unblocked component keeps full travel), interior corner
double block in a single tick (both axes, sorted multi-id list), bounds
clamping (east, west, corner, bounds id reported once), collider-id
reporting determinism, correction record contents (tick, actor, requested vs
resolved micro positions, milliunit velocities, blocked axes, ids) plus the
64-record bounded log, generation rejection (stale registration/teleport/
injection/resolution), replayed/regressed tick rejection, seal rejection of
the correct generation, presentation write-back isolation (held-result and
snapshot tampering cannot move authority), bit-identical determinism for the
same 90-tick accepted intent sequence across two independent runs (chained
`ZCanonicalValue.sha256`, per-tick locomotion digests, world digests,
correction logs, final positions), locomotion integration (convergence to
the resolved flush position, slide, stop, default-open-world regression,
attach validation), and a full `RaidAuthority` loop against the real
authored Sawmill layout (builder injects exactly the Obstacles-layer
structures, 34 admitted intents advance through the authority, the player
converges flush against `zerkov.structure.sawmill.mill_west_wall` at
544-8 px and wall-slides along it, resolved pose published, corrections
recorded, teardown + seal makes a late locomotion step inert).

### 2. Task 3.5 regression gate (unchanged contract)

Command:
```bash
export GODOT_BIN=/Volumes/Data/sdk/godot/editors/4.7.2/Godot.app/Contents/MacOS/Godot
python3 tests/tooling/run_player_locomotion_headless_gate.py
```

Verbatim output (final lines):
```text
PLAYER_LOCOMOTION_RESULT checks=166 failures=0
PLAYER_LOCOMOTION_HEADLESS_GATE runs=2 checks=332 failures=0 diagnostics=0
```

The task 3.5 contract check count is unchanged (166 per run / 332 total);
no edit to `tests/raid/player_locomotion_contract.gd` was needed or made.
The free-space locomotion semantics are preserved because resolution
quantizes positions to the canonical micro grid (error bounded by 1 µu =
1/31250 px per tick), well inside that contract's position tolerances, and
the resolved velocity equals the requested velocity exactly when unblocked.

### 3. `.uid` sidecars

Generated by one engine pass (no hand-written uids):
```bash
$GODOT_BIN --headless --editor --path . --audio-driver Dummy --quit-after 120
```
Produced `game/world/movement/*.gd.uid` and
`tests/raid/movement_authority_contract.gd.uid`.

## Changed and Added Files

- `game/world/movement/z_movement_world_2d.gd` (+ `.uid`): authoritative
  deterministic 2D world — injected static geometry, AABB bodies keyed by
  `ZEntityId`, integer micro resolution, wall-slide, bounds clamp, bounded
  correction log, generation/seal contract, canonical digest.
- `game/world/movement/z_movement_result.gd` (+ `.uid`): typed movement
  result with canonical record/digest and shared milliunit velocity
  projection.
- `game/world/movement/z_movement_world_builder.gd` (+ `.uid`): duck-typed
  adapter from the authored Sawmill layout (`Obstacles` layer + world
  bounds) into injected movement geometry.
- `game/world/player/player_locomotion.gd`: resolves every tick through the
  movement world (default open world when unattached); no unchecked
  `position_px` writes; `attach_movement_world`, `seal_movement_world`,
  `movement_world`, `last_movement_result`; generation-mismatch fail-closed;
  handler inert on stale generation; `teleport` syncs the world body;
  snapshot/canonical record carry the movement outcome; pose publication
  tracked. (Also fixes a latent wrong-property access
  `canonical_check.error` -> `error_code` on that path.)
- `tests/raid/movement_authority_contract.gd` (+ `.uid`): the contract
  described above.
- `tests/tooling/run_movement_authority_headless_gate.py`: two-run headless
  gate with diagnostics scan.
- `docs/qa/movement_authority_3_6/REPORT.md`: this evidence document.

## Design decisions

- **AABB bodies (not circles).** Authored blocking geometry is axis-aligned
  tile rects, so axis-separated AABB resolution is exact integer arithmetic
  with closed-form flush clamping and deterministic wall-slide. Circle
  bodies would add square roots/normalizations and per-contact tolerance
  decisions to a layer that must stay bit-reproducible.
- **Body shape.** 16x16 px box (8 px half extents) inside a 32 px authored
  tile; all authored Sawmill corridors are 3 cells wide (96 px), so the
  body passes with margin. Set per actor at `attach_movement_world`.
- **Micro resolution.** Positions and geometry live in `ZWorldUnits`
  canonical microunits (1 px = 31,250 µu); displacement per tick is
  round-half-away-from-zero of `velocity * 31250 / 60`. Published px values
  derive from the micro state, so presentation can never drift more than
  1 µu from authority.
- **Single MOVEMENT handler.** `ZPlayerLocomotion` remains the only
  MOVEMENT phase handler and owns the resolution call, avoiding handler-
  ordering ambiguity; the movement world is a composed module of the
  authority's movement domain, not a second handler.
- **Bounds identity.** Bounds clamping reports the configured bounds
  collider id (the authored level identifier) so even level-edge
  corrections name a stable authored identity; the open default world
  reports no id.

## Remaining Risks / Not Done

- `game/world/sawmill/**` and `game/ai/vision/**` are being changed by
  concurrent executors in this worktree; the builder consumes the layout
  duck-typed and the gates above passed against the current concurrent
  state, but a later structural change to `structures` rows could require
  a builder update.
- No dynamic bodies yet: AI/enemy actors can register bodies and resolve
  steps through the same world, but no AI controller does so until the
  perception/AI tasks; no actor-vs-actor collision is implemented
  (deliberately out of 3.6 scope).
- Corrections are bounded at 64 records per world (ring); long blocked
  sessions drop the oldest records by design.
- Movement for mounted/knockback/external displacements is not modeled;
  `teleport_actor` is the composition-only repositioning path.
- No smaller-output layout work, no capture suites, and no `tasks.md`
  edits were performed (display-scope and orchestrator rules).
