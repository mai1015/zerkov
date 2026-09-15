# Task 3.7 — Camera Follow, Cursor-to-World Aim, and Interaction Targeting Presentation/Input Adapters Evidence

Task ID: 3.7 `[LUNA]`
Status: Completed
Verification binary: Godot Engine `v4.7.2.stable.official.ed1daf0bf` (`/Volumes/Data/sdk/godot/editors/4.7.2/Godot.app/Contents/MacOS/Godot` / `/opt/homebrew/bin/godot`)
Output target: exact 1920x1080

## Outcome

Implemented presentation and input adapters for camera follow, cursor-to-world aim projection, and interaction candidate targeting without transform authority:

1. **Presentation Camera Math & Fit (`ZWorldViewportPolicy`, `ZWorldCameraFollow`, `ZWorldCamera2D`)**:
   - Fixed 640x360 SubViewport rendering surface.
   - Integer scale fit: $k = \lfloor \min(W/640, H/360) \rfloor$. At acceptance resolution 1920x1080, $k = 3$ with zero matte.
   - Non-acceptance aspect ratios (e.g. 1920x1200 letterbox) compute centered pillarbox/letterbox matte rects and reject out-of-surface pointers as typed `outside_world_surface`.
   - Round-once raster rule: presentation camera position is rounded once to whole world-raster pixels (`fmod(pos, 1.0) == 0.0`) with `Camera2D` smoothing disabled.
   - Clamps to level bounds across all four cardinal edges (West, East, North, South), accounting for the half-viewport dimensions $(320, 180)$.
   - Monotonic convergence to movement correction records without overshoot oscillation or secondary collision outcomes.
   - Holds zero transform authority: simulation runs with and without camera follow produce bit-identical `RaidAuthority.state_digest()` values.

2. **Cursor-to-World Aim Mapping (`ZWorldCursorAdapter`, `ZWorldCursorAimResult`)**:
   - Exact inverse mapping of the presentation projection.
   - Round-trip world $\rightarrow$ screen $\rightarrow$ world lands in the identical world raster pixel across corners, center, and arbitrary interior points.
   - Pointers falling in matte regions or out of screen boundaries return typed `ZWorldCursorAimResult.outside_surface(...)` with `inside_surface = false` and `reason = &"outside_world_surface"`.

3. **Interaction Candidate Targeting (`ZWorldCursorAdapter`)**:
   - Deterministically ranks candidate target markers (`ZWorldMarker`) using an explicit total tie-break:
     1. Primary: squared distance to cursor aim position (`aim_d2`).
     2. Secondary: squared distance to resolved actor pose (`actor_d2`).
     3. Total tie-break: lexicographical string order of stable `marker_id`.
   - Verified 100% order-independent across arbitrary permutations of candidate input arrays.
   - Emits `ZRaidIntent` with kind `interaction` naming the selected `target_id`.
   - Performs no eligibility, range, line-of-sight, or state-change pre-authorization (reserved for Task 3.8 authoritative policy).

## Automated Verification

### 1. Headless Gate Runner (`tests/tooling/run_world_camera_cursor_headless_gate.py`)
Command:
```bash
python3 tests/tooling/run_world_camera_cursor_headless_gate.py
```
Verbatim output:
```text
--- World Camera Cursor contract run 1 ---
Godot Engine v4.7.2.stable.official.ed1daf0bf - https://godotengine.org

WORLD_CAMERA_CURSOR_RESULT checks=70 failures=0
--- World Camera Cursor contract run 2 ---
Godot Engine v4.7.2.stable.official.ed1daf0bf - https://godotengine.org

WORLD_CAMERA_CURSOR_RESULT checks=70 failures=0
WORLD_CAMERA_CURSOR_HEADLESS_GATE runs=2 checks=140 failures=0 diagnostics=0
```

### 2. Direct Headless Contract (`tests/presentation/world_camera_cursor_contract.gd`)
Command:
```bash
/Volumes/Data/sdk/godot/editors/4.7.2/Godot.app/Contents/MacOS/Godot --headless --path . --resolution 1920x1080 --audio-driver Dummy --script res://tests/presentation/world_camera_cursor_contract.gd
```
Verbatim output:
```text
Godot Engine v4.7.2.stable.official.ed1daf0bf - https://godotengine.org

WORLD_CAMERA_CURSOR_RESULT checks=70 failures=0
```

### 3. Upstream Locomotion & Movement Authority Regression Verification
- **Player Locomotion Contract (Task 3.5)**:
  ```bash
  /Volumes/Data/sdk/godot/editors/4.7.2/Godot.app/Contents/MacOS/Godot --headless --path . --resolution 1920x1080 --audio-driver Dummy --script res://tests/raid/player_locomotion_contract.gd
  ```
  Result: `PLAYER_LOCOMOTION_RESULT checks=166 failures=0`

- **Movement Authority Contract (Task 3.6)**:
  ```bash
  /Volumes/Data/sdk/godot/editors/4.7.2/Godot.app/Contents/MacOS/Godot --headless --path . --resolution 1920x1080 --audio-driver Dummy --script res://tests/raid/movement_authority_contract.gd
  ```
  Result: `MOVEMENT_AUTHORITY_RESULT checks=539 failures=0`

## Changed and Added Files

### Owned Files Created:
- `game/presentation/world/world_cursor_aim_result.gd` (and `.uid`)
- `game/presentation/world/world_viewport_policy.gd` (and `.uid`)
- `game/presentation/world/world_camera_follow.gd` (and `.uid`)
- `game/presentation/world/world_camera_2d.gd` (and `.uid`)
- `game/input/world_cursor_adapter.gd` (and `.uid`)
- `tests/presentation/world_camera_cursor_contract.gd` (and `.uid`)
- `tests/tooling/run_world_camera_cursor_headless_gate.py`
- `docs/qa/world_camera_cursor_3_7/REPORT.md`

### Files for Central Manifest Registration:
New entrypoints to be registered in `config/first_playable_1080_gate.json` by orchestrator:
- GDScript entrypoint: `res://tests/presentation/world_camera_cursor_contract.gd`
- Python display driver: `tests/tooling/run_world_camera_cursor_headless_gate.py`

## Remaining Risks & Scope Exclusions

- **Deliberately Excluded / Did Not Do**:
  - Did NOT modify `game/world/**`, `game/raid/**`, `game/input/ui_intent_adapter.gd`, `game/input/zerkov_input_service.gd`, or any `ui/` scene.
  - Did NOT touch concurrent task 3.8 `game/raid/interaction/**` or evaluate interaction eligibility/range/line-of-sight (reserved exclusively for authoritative policy).
  - Did NOT edit `tasks.md` or `config/first_playable_1080_gate.json` (owned centrally by the orchestrator).
  - Did NOT test or regenerate historical resolutions (1600x900, 1280x720, 960x540); only verified against exact 1920x1080.
