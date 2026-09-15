# Task 3.11 Verification Report: World Markers

- Task: 3.11 `[LUNA]` Add spawn, loot, patrol, objective and extraction marker resources with stable authored identifiers.
- Worktree: `/Volumes/Data/codes/games/zerkov/.claude/worktrees/implement_moving`
- Engine: Godot 4.7.2 (`/Volumes/Data/sdk/godot/editors/4.7.2/Godot.app/Contents/MacOS/Godot`)
- Acceptance Output: Exact 1920x1080 dummy audio headless execution

## Summary of Implementation

1. **Typed Marker Resources (`game/world/markers/`)**:
   - `ZWorldMarker` (`world_marker.gd`): Base `Resource` carrying `marker_id: StringName`, `cell: Vector2i`, `approach_cell: Vector2i`, `display_name: String`, `tile: String`, and `label_offset_px: Vector2i`. Implements `validate() -> Array[String]` enforcing the lower-case dotted namespace convention, non-empty display name, whitespace rejection, and uppercase rejection.
   - `ZSpawnMarker` (`spawn_marker.gd`): Subclass for player/actor spawn points. Validates `spawn` namespace.
   - `ZLootMarker` (`loot_marker.gd`): Subclass for loot containers/caches and corpses. Carries `content_profile_id: StringName` and `is_corpse: bool`. Validates `loot` namespace and profile grammar.
   - `ZObjectiveMarker` (`objective_marker.gd`): Subclass for objective crates. Carries `landmark_id: StringName` and `content_profile_id: StringName`. Validates landmark and profile grammars.
   - `ZExtractionMarker` (`extraction_marker.gd`): Subclass for extraction zones. Carries `zone_cells: Rect2i`. Validates positive dimensions and cell containment within `zone_cells`.
   - `ZPatrolMarker` (`patrol_marker.gd`): Subclass for deterministically derived patrol waypoints. Carries `route_id: StringName` and `ordinal: int`.
   - `ZEncounterMarker` (`encounter_marker.gd`): Subclass for enemy staging anchors (scavs/mutants).

2. **Deterministic Patrol Markers & Layout Accessors (`game/world/sawmill/sawmill_yard_layout.gd`)**:
   - Added typed accessors `marker(id) -> ZWorldMarker`, `markers_of_kind(kind) -> Array[ZWorldMarker]`, `all_markers() -> Array[ZWorldMarker]`, `patrol_markers() -> Array[ZPatrolMarker]`, and `validate_markers() -> Array[String]`.
   - Maintained strict freeze on existing `ground_regions`, `detail_regions`, `structures`, `landmarks`, `anchors`, and `routes` arrays.
   - Patrol waypoints are derived deterministically as a pure function of authored route vertices (`routes`), creating stable IDs of the form `zerkov.patrol.sawmill.<route>.<ordinal>`:
     - `zerkov.patrol.sawmill.haul_lane.0` and `.1`
     - `zerkov.patrol.sawmill.south_bypass.0`, `.1`, `.2`, and `.3`
     - `zerkov.patrol.sawmill.mill_approach.0` and `.1`
     - `zerkov.patrol.sawmill.log_approach.0` and `.1`
   - Every waypoint features an adjacent `approach_cell` with Manhattan distance 1 oriented along its route segment corridor.
   - Duplicate identifier detection across all marker kinds records offending IDs and fails validation loudly.
   - Lookup is dictionary-keyed and order-independent.

3. **Scene Integration (`game/world/sawmill/sawmill_yard.gd`)**:
   - Attached typed `marker_resource` metadata to instantiated `Anchors` nodes while retaining legacy metadata (`stable_id`, `authored`).
   - Added delegating accessors `marker()`, `markers_of_kind()`, and `all_markers()`.

## Verification Commands and Verbatim Output

### 1. World Markers Headless Gate (Two Runs)

Command:
```sh
python3 tests/tooling/run_world_markers_headless_gate.py
```

Verbatim Output:
```
--- World Markers contract run 1 ---
Godot Engine v4.7.2.stable.official.ed1daf0bf - https://godotengine.org

WORLD_MARKERS_RESULT checks=306 failures=0
--- World Markers contract run 2 ---
Godot Engine v4.7.2.stable.official.ed1daf0bf - https://godotengine.org

WORLD_MARKERS_RESULT checks=306 failures=0
WORLD_MARKERS_HEADLESS_GATE runs=2 checks=612 failures=0 diagnostics=0
```

### 2. World Markers Contract (Direct)

Command:
```sh
/Volumes/Data/sdk/godot/editors/4.7.2/Godot.app/Contents/MacOS/Godot --headless --path . --resolution 1920x1080 --audio-driver Dummy --script res://tests/raid/world_markers_contract.gd
```

Verbatim Output:
```
Godot Engine v4.7.2.stable.official.ed1daf0bf - https://godotengine.org

WORLD_MARKERS_RESULT checks=306 failures=0
```

### 3. Task 3.4 Sawmill Layout Contract Gate

Command:
```sh
/Volumes/Data/sdk/godot/editors/4.7.2/Godot.app/Contents/MacOS/Godot --headless --path . --resolution 1920x1080 --audio-driver Dummy --script res://tests/raid/sawmill_layout_contract.gd
```

Verbatim Output:
```
Godot Engine v4.7.2.stable.official.ed1daf0bf - https://godotengine.org

SAWMILL_LAYOUT_RESULT checks=8006 failures=0 anchors=9 landmarks=3 routes=4 reachable_cells=548 native_cells=1073 physics_cells=252 occluder_cells=231 human_approval=false
```

## Contract Coverage Verification

The `tests/raid/world_markers_contract.gd` suite tests:
- **Typed Resolution & Legacy ID Preservation**: All 9 authored anchors resolve to their respective typed classes (`ZSpawnMarker`, `ZObjectiveMarker`, `ZLootMarker`, `ZExtractionMarker`, `ZEncounterMarker`), preserving exact stable IDs, cells, approach cells, and display names.
- **Deterministic Patrol Derivation**: All 10 patrol waypoints across the 4 authored routes are derived identically across two distinct layout instantiations with bit-matching IDs, coordinates, ordinals, and route references.
- **Negative Identifier Grammar & Rejections**:
  - Empty identifier rejection
  - Uppercase identifier rejection (e.g. `zerkov.spawn.sawmill.WEST_SERVICE`) with diagnostic containing the offending ID
  - Whitespace identifier rejection (e.g. `zerkov.spawn.sawmill.west service`) with diagnostic containing the offending ID
  - Malformed grammar rejection (e.g. `bad_id_without_namespace`) with diagnostic containing the offending ID
  - Namespace kind mismatch rejection (e.g. `ZSpawnMarker` with `zerkov.loot.*` ID)
  - Duplicate identifier rejection detecting and reporting the exact duplicate identifier
- **Extraction Boundary**: Confirms `zone_cells == Rect2i(36, 9, 3, 3)` containing extraction cell `(37, 10)`, and verifies negative controls for non-positive dimensions and cell outside boundary.
- **Order Independence**: Validates that lookups by stable identifier return identical results when source arrays are reversed or shuffled, and when `sawmill_yard.tscn` scene tree nodes are reordered.
