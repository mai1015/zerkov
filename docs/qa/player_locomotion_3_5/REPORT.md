# Task 3.5 — Player Locomotion, Facing Resolution, and Input Intent Seam Evidence

Task ID: 3.5 `[LUNA]`
Status: Completed
Verification binary: Godot Engine `v4.7.2.stable.official.ed1daf0bf` (`/opt/homebrew/bin/godot`)
Output target: exact 1920x1080

## Outcome

Implemented game-owned authoritative player locomotion (`ZPlayerLocomotion`), deterministic facing resolution (`ZPlayerFacing`), and the input intent generation seam (`UIIntentAdapter`):

1. **Input Intent Seam (`UIIntentAdapter`)**:
   - Converts logical movement vectors and discrete CommonUI action flags (move up/left/down/right, sprint, crouch, aim) into bounded `ZRaidIntent` instances with kind `player_movement`.
   - UI and input controllers possess zero direct transform authority and never write spatial properties or scene transforms.
   - Strictly validates payload structure (`move_vector: Vector2i`, `facing_vector: Vector2i`, `sprint: bool`, `crouch: bool`) within canonical boundaries (`ZCanonicalValue`). Floating-point payload injection fails closed.
   - Enforces the diagonal normalization policy: input vectors exceeding magnitude 1.0 (such as digital diagonals with length $\sqrt{2}$) are normalized to unit length before fixed-point scaling ($1,000,000$ scale), ensuring diagonal movement does not grant unearned speed. Analog stick deflections $\le 1.0$ preserve input magnitude.

2. **Facing Resolution & Deterministic Tie-Breaks (`ZPlayerFacing`)**:
   - Continuous aim/movement vectors are deterministically resolved into discrete 4-way cardinal (`NORTH`, `EAST`, `SOUTH`, `WEST`) and 8-way compass states.
   - Zero/idle input deterministically preserves the previous facing (initial facing defaults to `SOUTH`).
   - 4-way diagonal ties ($|x| == |y|$) use a hysteresis tie-break rule: if the current facing matches either component of the diagonal, it is preserved; otherwise, it falls back to vertical preference (`SOUTH` for $y > 0$, `NORTH` for $y < 0$).
   - 8-way sector boundaries (odd multiples of $22.5^\circ$) resolve to the adjacent cardinal direction, eliminating sector boundary ambiguity.

3. **Deterministic Locomotion Simulation (`ZPlayerLocomotion`)**:
   - Driven exclusively by fixed 60 Hz authority clock ticks ($\Delta t = 1.0 / 60.0$ s) without frame-delta authority.
   - Linear acceleration from rest: $768.0\text{ px/s}^2$ ($12.8\text{ px/s}$ per tick), reaching full walk speed ($128.0\text{ px/s}$, 4 tiles/s) in exactly 10 ticks.
   - Linear deceleration to stop: $1024.0\text{ px/s}^2$ ($17.067\text{ px/s}$ per tick), decelerating from $128.0\text{ px/s}$ to exact $(0, 0)$ in exactly 8 ticks.
   - Clamped max speeds across stances:
     - Walk (`STAND`): $128.0\text{ px/s}$
     - Sprint (`SPRINT`): $192.0\text{ px/s}$
     - Crouch (`CROUCH`): $64.0\text{ px/s}$
     - Simultaneous sprint and crouch: crouch takes priority ($64.0\text{ px/s}$).
   - Integrates with `RaidAuthority` via `register_phase_handler` in `TickPhase.MOVEMENT`.
   - Admitted intents are drained and processed during the movement phase; authoritative actor poses are published directly to `RaidAuthority.publish_weapon_actor_pose` for downstream weapon and vision consumers.
   - Converts coordinates and verifies bounds through `ZWorldUnits` (`godot_to_canonical`, `godot_to_weapon`, `godot_direction_to_weapon`, `godot_to_tile`).
   - Bit-for-bit replay determinism verified: identical tick input scripts produce identical canonical digests (`ZCanonicalValue.sha256`), velocities, and positions.

## Automated Verification

### 1. Player Locomotion Contract Gate (`run_player_locomotion_headless_gate.py`)
Command:
```bash
python3 tests/tooling/run_player_locomotion_headless_gate.py
```
Output:
```text
--- Player Locomotion contract run 1 ---
Godot Engine v4.7.2.stable.official.ed1daf0bf - https://godotengine.org

PLAYER_LOCOMOTION_RESULT checks=166 failures=0
--- Player Locomotion contract run 2 ---
Godot Engine v4.7.2.stable.official.ed1daf0bf - https://godotengine.org

PLAYER_LOCOMOTION_RESULT checks=166 failures=0
PLAYER_LOCOMOTION_HEADLESS_GATE runs=2 checks=332 failures=0 diagnostics=0
```

### 2. Adjacent Contract Regression Proofs
- **Units & Clock Contract**:
  ```bash
  godot --headless --path . --resolution 1920x1080 --audio-driver Dummy --script res://tests/raid/units_clock_contract.gd
  ```
  Result: `UNITS_CLOCK_CONTRACT_RESULT checks=41 failures=0`

- **Identity Contract**:
  ```bash
  godot --headless --path . --resolution 1920x1080 --audio-driver Dummy --script res://tests/raid/identity_contract.gd
  ```
  Result: `IDENTITY_CONTRACT_RESULT checks=18442 failures=0 unique=9216`

- **Session Lifecycle Contract**:
  ```bash
  godot --headless --path . --resolution 1920x1080 --audio-driver Dummy --script res://tests/raid/session_lifecycle_contract.gd
  ```
  Result: `SESSION_LIFECYCLE_RESULT checks=44 failures=0`

- **Authority Replay Contract**:
  ```bash
  godot --headless --path . --resolution 1920x1080 --audio-driver Dummy --script res://tests/raid/authority_replay_contract.gd
  ```
  Result: `AUTHORITY_REPLAY_RESULT checks=81 failures=0 reentrant_rejections=4`

- **Sawmill Layout Contract (Task 3.4)**:
  ```bash
  godot --headless --path . --resolution 1920x1080 --audio-driver Dummy --script res://tests/raid/sawmill_layout_contract.gd
  ```
  Result: `SAWMILL_LAYOUT_RESULT checks=8006 failures=0 anchors=9 landmarks=3 routes=4 reachable_cells=548 native_cells=1073 physics_cells=252 occluder_cells=231 human_approval=false`

## Changed and Added Files

- `game/world/player/player_facing.gd`: Discrete 4-way and 8-way facing resolution with explicit tie-break rules.
- `game/world/player/player_locomotion.gd`: Authoritative 60 Hz player locomotion module with acceleration, deceleration, stance limits, and RaidAuthority phase registration.
- `game/input/ui_intent_adapter.gd`: Input intent adapter generating bounded `ZRaidIntent` movement payloads without direct transform authority.
- `tests/raid/player_locomotion_contract.gd`: Deterministic headless contract validating acceleration, deceleration, max speeds, stances, diagonal normalization, facing tie-breaks, intent validation rejections, authority integration, and replay determinism.
- `tests/tooling/run_player_locomotion_headless_gate.py`: Two-run headless verification gate script.
- `docs/qa/player_locomotion_3_5/REPORT.md`: This evidence document.
- `docs/spec/changes/add-zerkov-playable-raid-2026-09-09/tasks.md`: Task 3.5 marked completed with evidence note.
