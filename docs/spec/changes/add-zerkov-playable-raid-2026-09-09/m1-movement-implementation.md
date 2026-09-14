# M1: normal-launch Sawmill playable room

Date: 2026-09-14
Baseline: `55362911aa089c3b87100697181a982eebd3c209`
Status: **Partial implementation candidate. M1 is NOT complete.**

This is an implementation note for the approved Stage 2 change, not a new
product proposal or an amendment to the capability specifications. Existing
task identifiers and acceptance requirements remain authoritative. Do not
check off tasks 3.5 or 3.6 on the strength of this patch.

## Milestone outcome

From the ordinary project launch, a player can enter the authored Sawmill,
move and aim, collide with actual blocking geometry, approach a real raid-owned
loot container, and use the existing inventory workspace. Walking into Road
Gate is observable, but must not pretend extraction or settlement exists.

The display stays exact 1920x1080, with the selected 640x360 world surface
mapped 3x beneath the existing crisp UI. No responsive/compact work is reopened.

This milestone is an intermediate integration checkpoint. It does not claim a
complete extraction loop, saved raid loot, combat tuning, AI encounters, human
acceptance, multiplayer, or platform release readiness.

## What this patch implements

`game/world/movement/z_movement_step_2d.gd` supplies a pure one-tick movement
calculation for a future game-owned MOVEMENT phase handler. It uses the existing
`ZWorldUnits` canonical microunit space, integer arithmetic, bounded analog axes,
per-component acceleration/braking, radial speed limiting, static axis-aligned
body/blocker collision, boundary contact, wall sliding, and blocked-axis results.

The collision policy sweeps X first, then Y. This is deterministic axis-ordered
sliding, NOT a simultaneous swept-disc solver or an isotropic corner response.
A thin blocker cannot be skipped along either sweep. Touching a surface is
valid contact; an initially penetrating body is rejected rather than silently
teleported. Obstacle ordering does not change the resolved coordinates.

The input axes use [-1000, 1000]. This is a dimensionless control encoding, not a
new spatial unit system. Position and half-extents use canonical microunits;
velocity and speed use microunits/tick. Acceleration is a per-component change in
velocity per tick. Configuration is supplied explicitly; no gameplay speed,
body size, or acceleration tuning is approved by this patch. Conservative
integer normalization can undershoot the requested radial speed slightly.

The result is a flat read-only Dictionary of value types. It is a calculation
candidate, not an authenticated result receipt or proof that a mutation occurred.
The function has no clock, entity registry, history, session, scene node,
callbacks, input reads, or mutable persistent state. It neither commits a body
position nor updates a weapon, inventory, Vision world, or UI.

Limits are explicit: 2048 static AABBs, positive half-extents up to one canonical
world unit, and at most one canonical world unit of speed per tick. These are
implementation safety bounds, not play-feel settings. Generic runtime thread
safety, dynamic body-body collision, rotated shapes, slopes, correction replay,
and stance/facing mechanics are not implemented. Do not approximate unsupported
collision shapes with bounding boxes without an explicit review.

## Verification state

`tests/world/movement_step_contract.gd` contains 24 named scenario allocations
covering acceleration/braking, analog/diagonal speed, sweeps in both directions,
a one-unit wall, sliding, movement away from contact, world boundaries, rejected
inputs, work bounds, result isolation, replay, and coordinate arithmetic.

**The unchanged movement component and contract were subsequently executed in
Godot `4.7.2.stable.official.ed1daf0bf` in an isolated project.** The original
contract passed 24 scenarios / 36 checks with zero failures. Extended native
checks passed 5000 generated collision cases and two identical 10000-tick
traces. The standard-build import and movement logs are error-free. A separate
synthetic software-OpenGL probe produced an exact 1920x1080 framebuffer; it is
not a Sawmill screenshot, visual acceptance, or a performance benchmark.

Readable evidence is in `docs/qa/m1_movement_native/`; the replay capsule
remains the separately delivered conversation attachment, not a checked-in file.
Source hashes were checked again when preparing this commit. These are recorded
isolated executions, not a fresh run of the complete project or its current
source-policy gates. The .NET attempt emitted errors and is not accepted.
Full-project import, frame timing, Sawmill traversal, authority integration,
and human acceptance remain unverified. Tasks 3.5 and 3.6 remain incomplete.

The delivery bundle separately includes a Python numerical model and its log:
11 test methods passed, including 5000 generated sweeps compared with an
independent unit-by-unit collision oracle and two identical 10000-step runs.
These support the numerical design only. They do not compile or execute the
GDScript and cannot substitute for the native contract or integration gates.

## Remaining implementation order

### 1. Validate full-project integration on the pinned toolchain

Tasks: partial 3.5 / 3.6 only.

The isolated native candidate gate passed. Run the full-checkout toolchain
and vendored-artifact checks, import the project, then run the new contract.
Resolve parse/type/runtime failures before connecting production.
Review the X-then-Y corner behavior and required body shape against the actual
character footprint. Do not change add-on snapshots to make this candidate pass.

### 2. Compile authoritative Sawmill geometry and bind movement

Tasks: 3.5, 3.6, 3.11, 3.12; coordinate with 3.9 and 3.10.

Create a game-owned owner for actor position/velocity and collision data. Read
blocking information from authored collision metadata, not sprite appearance,
labels, or the name of a draw layer. Ground obstacles such as water must not be
lost merely because they are not in an Obstacles node. Convert through
`ZWorldUnits`; do not duplicate the tile/pixel/canonical conversion constants.
Validate required anchors, body-clearance spawn positions, geometry bounds,
duplicate IDs, and a traversable route to Road Gate. Reject unsupported shapes.

Use the existing RaidAuthority registration/admission APIs after reading their
current contracts. Invoke the calculation only in the registered MOVEMENT
phase, once per actor per canonical tick, from accepted intent data. The game
owner commits the result and provides the shared actor pose to hitboxes,
weapon context, Vision, and interaction policies. None of those services may
maintain a competing authoritative transform. Register matching pose updates
in the documented per-tick order.

Required integration tests: stale actor/session/epoch/generation, duplicate or
out-of-window input, teardown, reentrant calls, invalid spawn, blocked results,
and accepted-input replay including movement state in the canonical digest.
The pure calculation alone supplies none of those authorization guarantees.

### 3. Connect logical input and world presentation

Tasks: 3.5, 3.7, selected 9.4/9.5; retain 8.3 and 8.10.

Read logical actions from the existing input service; do not introduce an
independent hard-coded key map. Sample input for each canonical simulation tick,
not once per render frame. Define and test neutral-input behavior for missing
samples, focus loss, modal activation, pause, and actor replacement. Do not
retain a stale move vector after the input context changes. Commands go through
the bounded intent queue; presentation never moves the canonical body directly.

Render the resolved actor pose on the selected low-resolution world surface.
Keep interpolation, animation, camera rounding, and any visual correction out
of collision authority. Resolve cursor coordinates through the actual world
viewport/camera transform, not UI coordinates divided by a guessed constant.
Capture evidence at exact 1920x1080 only; headless runs are not visual evidence.

### 4. Add the production owner and wire the existing UI

Tasks: scoped composition across 2, 4, 7.2, 8.4, 8.6, and 8.8.

A proposed `game/bootstrap/game_root.tscn` / `.gd` composition owns ProfileStore,
SessionCoordinator, RaidAuthority, the world owner, and the established inventory
and presentation adapters. These filenames are proposed, not existing APIs.
Inspect each constructor/bind/teardown contract before implementation. Do not
place canonical state in `ui/main.gd` or construct a second inventory in the UI.

Instantiate the UI host off-tree and use its existing pre-tree injection seams:
`inject_character_runtime(...)` and `inject_presentation_provider(...)`.
Supply genuinely owner-backed views. Do not bypass unavailable states by
marking fixture values as READY. Keep the F1 catalog a developer path.

Complete the approved deployment/profile-generation ownership behavior before
exposing persistent gear to a raid. Without settlement, returning from this
intermediate slice must explicitly avoid claiming raid loot was committed.
Do not invent an undocumented practice-mode economy to hide that limitation.

Only change `project.godot` to the game-level composition after launch,
deployment, pause/resume, return, teardown, and redeployment work through real
providers. Preserve direct F6 UI preview behavior.

### 5. Connect one real loot interaction and accept M1

Tasks: 3.8 and integration of accepted 4.4-4.7 / 4.11 / 8.6.

Map a stable authored crate anchor to its existing raid-owned inventory. Check
identity, range, line of interaction, generation, and search/access state in the
game-owned policy. Open the existing inventory/loot interface through its
canonical adapter and projection. Do not replace the designed grid or directly
edit presentation item arrays. Walking away, actor replacement, and teardown
must invalidate access and pending actions safely.

M1 evidence: normal-launch traversal and aiming; collision and frame/tick checks;
a real crate transfer visible in confirmed state; no F1/test-only dependency
in the product flow; repeated start/exit/redeploy lifecycle checks; a native
1920x1080 recording; and explicit review. These are not substitutes for the
later ten extract/death cycles required by task 12.3.

## Scope guard and next checkpoint

Do not rebuild CommonUI, add a new UI system, expand the add-on architecture,
reopen smaller resolutions, add multiplayer, or implement crafting/trading to
finish this milestone. Preserve existing authority and unavailable-state rules.

After M1, connect one real combat encounter, then complete Supply Run, extraction,
death-loss settlement, durable result recovery, and the committed summary. Only
then attempt the complete offline vertical-slice acceptance in section 12.
