# Task 3.12 Verification Report: Sawmill Headless Contract

- Task: 3.12 `[SOL]` Add a headless Sawmill contract checking required anchors, collisions, reachable extract, occluder bounds and duplicate identifiers.
- Spec: `docs/spec/changes/add-zerkov-playable-raid-2026-09-09/tasks.md`
- Worktree: `/Volumes/Data/codes/games/zerkov/.claude/worktrees/implement_moving`
- Engine: Godot 4.7.2 (`/Volumes/Data/sdk/godot/editors/4.7.2/Godot.app/Contents/MacOS/Godot`)
- Acceptance Output: Exact 1920x1080 headless dummy audio execution

## Outcome Summary

Implemented the headless Sawmill contract (`tests/raid/sawmill_contract.gd`), headless two-run gate driver (`tests/tooling/run_sawmill_contract_headless_gate.py`), and verification report for Task 3.12.

The contract verifies the real authored Sawmill Yard level (`game/world/sawmill/sawmill_yard_layout.tres`) across five named check families using the landed dependencies from Tasks 3.6, 3.9, 3.10, and 3.11, without modifying any game code (`game/` was treated as strictly read-only):

1. **Required Anchors:**
   - All 9 required authored anchors exist and resolve to their respective typed classes:
     - Player spawn: `zerkov.spawn.sawmill.west_service` -> `ZSpawnMarker`
     - 3 Objective crates:
       - `zerkov.loot.sawmill.crate.log_racks` -> `ZObjectiveMarker`
       - `zerkov.loot.sawmill.crate.saw_house` -> `ZObjectiveMarker`
       - `zerkov.loot.sawmill.crate.settling_dock` -> `ZObjectiveMarker`
     - Service cache: `zerkov.loot.sawmill.service_cache` -> `ZLootMarker` (`is_corpse == false`)
     - Corpse: `zerkov.loot.sawmill.corpse.haul_lane` -> `ZLootMarker` (`is_corpse == true`)
     - Extraction zone: `zerkov.extract.sawmill.road_gate` -> `ZExtractionMarker`
     - Encounters:
       - `zerkov.encounter.sawmill.scav_cover` -> `ZEncounterMarker`
       - `zerkov.encounter.sawmill.mutant_verge` -> `ZEncounterMarker`
   - All 10 derived patrol waypoints exist as `ZPatrolMarker`.
   - Every anchor and approach cell sits strictly within the level boundaries `Rect2i(0, 0, 40, 20)`.
   - All approach cells are adjacent (Manhattan distance = 1).
   - Content references validated:
     - Objective crates reference valid authored landmarks (`layout.landmarks`) and valid content profile (`zerkov.profile.raid.world_crate`).
     - Cache and corpse reference valid content profiles (`zerkov.profile.raid.world_crate`, `zerkov.profile.raid.corpse`).
     - Extraction marker `zone_cells` (`Rect2i(36, 9, 3, 3)`) is fully within level bounds and contains its cell `(37, 10)`.

2. **Collisions:**
   - No anchor cell or approach cell sits inside blocking geometry, verified against task 3.6's authoritative `ZMovementWorld2D` built via `ZMovementWorldBuilder.build_from_sawmill_layout(layout, generation)`.
   - Each anchor cell and approach cell is verified through `world.register_actor` with player body half extents `Vector2(8.0, 8.0)`.
   - No two anchors illegally overlap (all anchor cells are unique).
   - Collision geometry fidelity: verified against task 3.6's authoritative geometry (23 static colliders registered from `Obstacles` layer structures; 0 colliders from `Canopy` layer structures; level bounds collider matching `zerkov.level.sawmill_yard` and 1280x640 px).

3. **Reachable Extract:**
   - Evaluated using task 3.9's deterministic navigation seam: `ZNavigationGrid.bake_from_sawmill_layout(layout)` and `ZNavigationPathService`.
   - Deterministic paths successfully resolve to the Road Gate extract (`zerkov.extract.sawmill.road_gate` at `Vector2i(37, 10)`):
     - Spawn -> Extract: optimal path of 34 cells, cost 350.
     - Objective crate log racks -> Extract: optimal path of 30 cells, cost 306.
     - Objective crate saw house -> Extract: optimal path of 19 cells, cost 196.
     - Objective crate settling dock -> Extract: optimal path of 14 cells, cost 142.
     - Service cache -> Extract: optimal path.
     - Corpse -> Extract: optimal path.

4. **Occluder Bounds:**
   - Evaluated using task 3.10's deterministic `ZOccluderBake.bake(layout.structures, layout.size_cells)`.
   - Real Sawmill layout bakes to exactly 98 segments, comfortably within the declared budget of 128 segments.
   - Every segment carries a stable identifier with infix `.occluder.` traceable to its authored source structure.
   - Every segment vertex (`a` and `b`) lies inside the level rect in Vision microunits (`[0, 40_000_000] x [0, 20_000_000]`).
   - Every segment vertex converts within Vision coordinate bounds via `ZWorldUnits.vision_to_godot(v).ok`.
   - No degenerate segments (`a != b`).

5. **Duplicate Identifiers:**
   - Unified single namespace sweep across all collections:
     - 17 ground regions (`zerkov.terrain_region.sawmill.*`)
     - 5 detail regions (`zerkov.detail.sawmill.*`)
     - 29 structures (`zerkov.structure.sawmill.*`)
     - 3 landmarks (`zerkov.landmark.sawmill.*`)
     - 9 authored anchors (`zerkov.spawn.*`, `zerkov.loot.*`, `zerkov.extract.*`, `zerkov.encounter.*`)
     - 10 derived patrol waypoints (`zerkov.patrol.sawmill.*`)
     - 4 routes (`zerkov.route.sawmill.*`)
     - 98 baked occluder segments (`zerkov.structure.sawmill.*.occluder.*`)
   - All 175 identifiers are globally unique across the combined level namespace.

## Negative Controls

The contract asserts that corrupted inputs are rejected with actionable, identifier-bearing messages across 17 distinct negative controls:

| Control # | Corrupted Input | Expected Diagnostic | Verified Diagnostic Fragment |
|---|---|---|---|
| Control 1 | Missing required anchor (`zerkov.loot.sawmill.crate.log_racks` removed) | `missing_required_anchor` naming missing ID | `missing_required_anchor: zerkov.loot.sawmill.crate.log_racks` |
| Control 2 | Anchor cell outside bounds (`zerkov.spawn.sawmill.west_service` moved to `(-1, 5)`) | `out_of_bounds` naming ID and cell | `out_of_bounds: zerkov.spawn.sawmill.west_service cell (-1, 5)` |
| Control 3 | Anchor approach cell outside bounds (`saw_house` crate approach moved to `(21, -2)`) | `approach_out_of_bounds` naming ID and cell | `approach_out_of_bounds: zerkov.loot.sawmill.crate.saw_house approach_cell (21, -2)` |
| Control 4 | Crate referencing non-existent landmark (`zerkov.landmark.sawmill.nonexistent_pad`) | `missing_landmark` naming crate and missing landmark | `missing_landmark: zerkov.loot.sawmill.crate.settling_dock references unknown landmark 'zerkov.landmark.sawmill.nonexistent_pad'` |
| Control 5 | Extract zone not containing cell (`zone_cells` set to `Rect2i(10, 10, 2, 2)`) | `zone_does_not_contain_cell` naming extract ID | `zone_does_not_contain_cell: zerkov.extract.sawmill.road_gate` |
| Control 6 | Anchor moved into wall (`west_service` spawn moved to `(17, 3)` inside `mill_west_wall`) | `anchor_collision` naming colliding ID and cell | `anchor_collision: 'zerkov.spawn.sawmill.west_service' cell (17, 3) in blocking geometry` |
| Control 7 | Approach cell moved into wall (`saw_house` approach moved to `(17, 2)` inside `mill_north_wall`) | `approach_collision` naming colliding ID and cell | `approach_collision: 'zerkov.loot.sawmill.crate.saw_house' approach_cell (17, 2) in blocking geometry` |
| Control 8 | Illegal anchor overlap (`west_service` spawn and `log_racks` crate at `(4, 15)`) | `illegal_overlap` naming both IDs and cell | `illegal_overlap: anchors 'zerkov.spawn.sawmill.west_service' and 'zerkov.loot.sawmill.crate.log_racks' share cell (4, 15)` |
| Control 9 | Cross-namespace duplicate ID (occluder segment sharing `zerkov.structure.sawmill.north_fence`) | `duplicate_identifier` naming ID and both owners | `duplicate_identifier: 'zerkov.structure.sawmill.north_fence' owned by 'structure' and 'occluder_segment'` |
| Control 10 | Cross-namespace duplicate ID (route sharing `zerkov.landmark.sawmill.saw_house`) | `duplicate_identifier` naming ID and both owners | `duplicate_identifier: 'zerkov.landmark.sawmill.saw_house' owned by 'landmark' and 'route'` |
| Control 11 | Out-of-bounds structure in occluder bake (`Rect2i(50, 50, 2, 2)`) | `rect_outside_level_bounds` / `bake_error` naming source ID | `source='zerkov.structure.sawmill.oob_test_box' code=rect_outside_level_bounds` |
| Control 12 | Baked segment vertex out of Vision bounds (`(999000000, 999000000)`) | `segment_a_out_of_bounds` naming source ID | `segment_a_out_of_bounds: segment '...' (source '["zerkov.structure.sawmill.dock_rim"]')` |
| Control 13 | Untraceable occluder segment (source `zerkov.structure.sawmill.phantom_box`) | `unknown_source_id` naming phantom source | `unknown_source_id: segment '...' references unknown source 'zerkov.structure.sawmill.phantom_box'` |
| Control 14 | Degenerate occluder segment (`a == b`) | `degenerate_segment` naming segment ID | `degenerate_segment: segment 'zerkov.structure.sawmill.north_fence.occluder.999' has zero length` |
| Control 15 | Segment count exceeding budget (98 segments with budget 5) | `budget_exceeded` naming actual count and budget | `budget_exceeded: baked count 98 exceeds budget 5` |
| Control 16 | Unreachable extract from spawn (extract moved to blocked fence `(0, 0)`) | `unreachable_pair` naming spawn and extract | `unreachable_pair: 'zerkov.spawn.sawmill.west_service' ((4, 15)) -> 'zerkov.extract.sawmill.road_gate' ((0, 0))` |
| Control 17 | Unreachable extract from crate (`saw_house` crate moved to wall `(17, 2)`) | `unreachable_pair` naming crate and extract | `unreachable_pair: 'zerkov.loot.sawmill.crate.saw_house' ((17, 2)) -> 'zerkov.extract.sawmill.road_gate'` |

## Verification Commands and Verbatim Output

### 1. Direct Contract Execution

Command:
```sh
export ZERKOV_GODOT=/Volumes/Data/sdk/godot/editors/4.7.2/Godot.app/Contents/MacOS/Godot
$ZERKOV_GODOT --headless --path . --resolution 1920x1080 --audio-driver Dummy \
  --script res://tests/raid/sawmill_contract.gd
```

Verbatim output:
```text
Godot Engine v4.7.2.stable.official.ed1daf0bf - https://godotengine.org

SAWMILL_CONTRACT_RESULT checks=192 failures=0
```

### 2. Two-Run Headless Gate Execution

Command:
```sh
export GODOT_BIN=/Volumes/Data/sdk/godot/editors/4.7.2/Godot.app/Contents/MacOS/Godot
python3 tests/tooling/run_sawmill_contract_headless_gate.py
```

Verbatim output:
```text
--- Sawmill contract run 1 ---
Godot Engine v4.7.2.stable.official.ed1daf0bf - https://godotengine.org

SAWMILL_CONTRACT_RESULT checks=192 failures=0
--- Sawmill contract run 2 ---
Godot Engine v4.7.2.stable.official.ed1daf0bf - https://godotengine.org

SAWMILL_CONTRACT_RESULT checks=192 failures=0
SAWMILL_CONTRACT_HEADLESS_GATE runs=2 checks=384 failures=0 diagnostics=0
```

### 3. Regression Verification of Existing Contracts

All upstream dependency gates and the task 3.4 layout contract were re-verified and remain 100% passing:

```text
SAWMILL_LAYOUT_RESULT checks=8006 failures=0 anchors=9 landmarks=3 routes=4 reachable_cells=548 native_cells=1073 physics_cells=252 occluder_cells=231 human_approval=false
MOVEMENT_AUTHORITY_HEADLESS_GATE runs=2 checks=1078 failures=0 diagnostics=0
NAVIGATION_PATH_HEADLESS_GATE runs=2 checks=1222 failures=0 diagnostics=0
OCCLUDER_BAKE_HEADLESS_GATE runs=2 checks=528 failures=0 diagnostics=0
WORLD_MARKERS_HEADLESS_GATE runs=2 checks=612 failures=0 diagnostics=0
```

## Findings in Landed Dependencies (Tasks 3.6, 3.9, 3.10, 3.11)

No defects were found. All upstream tasks conformed strictly to their documented contracts:
- Task 3.6 (`ZMovementWorldBuilder` / `ZMovementWorld2D`): Produced exact static colliders for all 23 Obstacles structures, preserved bounds, and resolved actor registrations without error.
- Task 3.9 (`ZNavigationGrid` / `ZNavigationPathService`): Deterministic path search produced expected optimal paths for spawn and all crates to extract (spawn->extract 34 cells, cost 350).
- Task 3.10 (`ZOccluderBake`): Produced exactly 98 segments within the 128 budget; all segments in-bounds and traceable to authored structures.
- Task 3.11 (`ZWorldMarker` / `ZSawmillYardLayout`): Provided typed marker resolution for all 9 authored anchors and 10 derived patrol waypoints without collision.

## Owned Files Created / Modified

- `tests/raid/sawmill_contract.gd`: Headless contract implementing the 5 check families and 17 negative controls.
- `tests/raid/sawmill_contract.gd.uid`: Engine-generated `.uid` sidecar.
- `tests/tooling/run_sawmill_contract_headless_gate.py`: Two-run Python headless gate driver enforcing exact 1920x1080 resolution and zero diagnostics.
- `docs/qa/sawmill_contract_3_12/REPORT.md`: This verification report.

## Central Entrypoints for Orchestrator Registration

As expected per `TASK3_BRIEF.md`, the following two new entrypoints will be classified centrally by the orchestrator:
- GDScript entrypoint: `tests/raid/sawmill_contract.gd`
- Python display driver: `tests/tooling/run_sawmill_contract_headless_gate.py`

## Remaining Risks & Deliberately Not Done

- **Deliberately not done:**
  - Did not modify any file under `game/` (`game/` is read-only for validation gate tasks).
  - Did not edit `tasks.md`, `config/first_playable_1080_gate.json`, `tests/tooling/test_ui_first_playable_scope.py`, or `tools/check_first_playable_1080.py` (owned centrally by orchestrator).
  - Did not touch `tests/raid/sawmill_layout_contract.gd` (owned by task 3.4).
  - Did not touch concurrent task 3.8 paths (`game/raid/interaction/`).
- **Remaining risks:**
  - Future map content additions to `ZSawmillYardLayout` (e.g. adding new structures or moving anchors) must remain within the 128 occluder segment budget, maintain non-overlapping anchor positions, and ensure unblocked reachability to extract. The contract gate will automatically catch any regression.
