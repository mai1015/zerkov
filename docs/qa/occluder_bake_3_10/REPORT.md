# Task 3.10 — Common Vision Occluder Bake Evidence

Task ID: 3.10 `[SOL]`
Status: Completed
Verification binary: Godot Engine `v4.7.2.stable.official.ed1daf0bf`
(`/Volumes/Data/sdk/godot/editors/4.7.2/Godot.app/Contents/MacOS/Godot`, also on
`PATH` as `godot`)
Output target: exact 1920x1080

## Outcome

Implemented `ZOccluderBake` (`game/ai/vision/occluder_bake.gd`) and
`ZerkovOccluderSegment` (`game/ai/vision/zerkov_occluder_segment.gd`): a pure,
deterministic bake from explicit authored `ZSawmillYardLayout.structures` rows
(`{id, tile, layer, role, rect}`, `rect` in tile/cell units) plus the level's
`size_cells` bound into stable Common Vision occluder line segments.

1. **No scene/physics/TileMap coupling.** `ZOccluderBake.bake(structures,
   size_cells)` takes the authored rows and level bound as plain parameters.
   It never loads `sawmill_yard.tscn`, queries physics, or reads a
   `TileMapLayer`; the contract loads only the authored `.tres` Resource
   (`ZSawmillYardLayout`) directly, never the scene.
2. **Outline, not per-tile boxes.** Rows are rasterized into a per-mask-group
   occupancy grid (one 32 px tile cell each). Connected components ("blobs")
   are found by 4-connectivity flood fill; each blob's boundary is computed
   by unit-edge exposure (a unit edge is only part of the boundary if its
   neighbor cell is unoccupied), then contiguous collinear unit edges on the
   same grid line are merged into one run. A single isolated rect of any size
   always yields exactly 4 segments; touching/overlapping rects (even across
   different authored ids) collapse their shared internal edges and merge
   into one connected outline. This exercises for real on the Sawmill
   perimeter: `north_fence`/`west_fence`/`east_fence`/`south_fence`/
   `southeast_fence` are five separate authored rows that touch at their
   corners and bake into one connected ring outline.
3. **Units.** Every vertex goes through `ZWorldUnits.tile_origin_to_godot(...)`
   then `ZWorldUnits.godot_to_vision(...)` only. Any conversion reporting
   `ok == false` (the narrower +/-65,536 px / +/-2,048,000,000 raw Vision
   bound) fails the whole bake closed, naming the offending blob's
   representative source id with code `vision_conversion_out_of_range`.
4. **Masks.** Reused directly from the sealed `ZerkovVisionConfig` occluder
   domain (`OCCLUDER_LAYER_STRUCTURE = 1`, `OCCLUDER_LAYER_VEGETATION = 2`)
   rather than re-declaring magic numbers. `layer == "Obstacles"` rows bake as
   structure-mask geometry; `layer == "Canopy"` rows bake as vegetation-mask
   geometry. The two mask domains are baked independently, so touching rows
   in different domains never merge into one outline (verified explicitly).
5. **Stable identifiers.** Each blob's representative id is the
   lexicographically smallest contributing authored `structures` id in that
   connected component (ids are validated globally unique first, so this is
   collision-free across blobs and across mask domains). Segment ids are
   `"<blob_representative_id>.occluder.<3-digit ordinal>"`. Every ordering
   decision is explicit: cell keys, boundary runs, and the final segment
   array are all sorted by comparator (never left to Dictionary iteration or
   node/scene-tree order). Two bakes of unchanged input produce identical ids
   in identical order and a byte-identical aggregate digest (see below).
6. **Segment budget.** `ZOccluderBake.SEGMENT_BUDGET_MAX = 128`, matching the
   admission assumption documented in `game/ai/vision/README.md`'s "Fixed
   first-playable values" (128 authored segments behind the sealed 16,384
   work-unit Vision budget). Baking fails closed with the actual count when
   exceeded (`segment_budget_exceeded`, message reports both numbers).
   **The real Sawmill layout bakes to 98 segments** (29 authored rows: 23
   Obstacles + 6 Canopy; naive per-rect boxing would be 116) — comfortably
   within the 128 budget. This is not a blocker.
7. **Malformed-source validation**, each naming the offending source object
   (or, for the aggregate budget, the actual/budget counts):
   `missing_id`, `duplicate_id`, `unknown_layer`,
   `rect_zero_or_negative_area` (covers both zero-area and negative-size
   rects), `rect_outside_level_bounds`, `vision_conversion_out_of_range`,
   `segment_budget_exceeded`, and the defensive `degenerate_segment` guard
   (see "Deliberately not done" below). Any malformed row fails the *whole*
   bake closed (no partial/silent-skip success), matching the capability
   spec's "the raid is not marked release-ready until the issue is resolved."

Aggregate hashing uses a framed streaming digest
(`ZOccluderBake.segments_digest`) rather than a single
`ZCanonicalValue.sha256()` call on the whole segments array, because the real
98-segment (and the budget-test's 132-segment) arrays exceed
`ZCanonicalValue.DEFAULT_MAX_COLLECTION` (64) — the same framing idiom as
`game/raid/raid_event_journal.gd`'s `digest()`.

## Automated Verification

### 1. Occluder Bake Contract Gate (`run_occluder_bake_headless_gate.py`)
Command:
```bash
export GODOT_BIN=/Volumes/Data/sdk/godot/editors/4.7.2/Godot.app/Contents/MacOS/Godot
python3 tests/tooling/run_occluder_bake_headless_gate.py
```
Verbatim output:
```text
--- Occluder Bake contract run 1 ---
Godot Engine v4.7.2.stable.official.ed1daf0bf - https://godotengine.org

OCCLUDER_BAKE_SAWMILL_SEGMENTS count=98 budget=128 authored_rows=29
OCCLUDER_BAKE_RESULT checks=264 failures=0
--- Occluder Bake contract run 2 ---
Godot Engine v4.7.2.stable.official.ed1daf0bf - https://godotengine.org

OCCLUDER_BAKE_SAWMILL_SEGMENTS count=98 budget=128 authored_rows=29
OCCLUDER_BAKE_RESULT checks=264 failures=0
OCCLUDER_BAKE_HEADLESS_GATE runs=2 checks=528 failures=0 diagnostics=0
```

### 2. Direct Contract Run
Command:
```bash
export ZERKOV_GODOT=/Volumes/Data/sdk/godot/editors/4.7.2/Godot.app/Contents/MacOS/Godot
$ZERKOV_GODOT --headless --path . --resolution 1920x1080 --audio-driver Dummy \
  --script res://tests/ai/occluder_bake_contract.gd
```
Result: `OCCLUDER_BAKE_SAWMILL_SEGMENTS count=98 budget=128 authored_rows=29` /
`OCCLUDER_BAKE_RESULT checks=264 failures=0`

Covers, at minimum:
- Double-bake of the real Sawmill layout produces byte-identical canonical
  digests and identifiers in identical order (`_test_double_bake_determinism_and_stable_ids`),
  including stability against a freshly `.duplicate(true)`-ed copy of the
  same `structures` data.
- Adjacent rects collapse their shared internal edge into one 4-segment
  outline (`_test_adjacent_rects_collapse_shared_edge`).
- Three collinear 1x1 authored cells (three distinct source ids) merge into
  one 4-segment perimeter, with the merged run naming all three contributing
  ids (`_test_collinear_line_merges_into_one_perimeter`).
- A single isolated rect yields exactly 4 segments
  (`_test_isolated_rect_yields_four_segments`).
- Masks are assigned per authored layer, and the two mask domains never merge
  across each other even when touching (`_test_masks_assigned_per_layer_and_domains_stay_separate`).
- Every malformed-source case is rejected naming the source id:
  `_test_malformed_missing_id`, `_test_malformed_duplicate_id`,
  `_test_malformed_unknown_layer`, `_test_malformed_zero_area_rect`,
  `_test_malformed_negative_size_rect`, `_test_malformed_rect_outside_bounds`.
- Out-of-Vision-range geometry is rejected naming the source object
  (`_test_out_of_vision_range_rejected`).
- The authored segment budget is enforced and reports actual-vs-budget counts
  (`_test_segment_budget_exceeded`).
- The real Sawmill layout bakes within budget
  (`_test_real_sawmill_layout_within_budget`): **98 segments vs a 128 budget**.

### 3. Adjacent Regression Proof (sealed Vision config untouched)
Command:
```bash
$ZERKOV_GODOT --headless --path . --resolution 1920x1080 --audio-driver Dummy \
  --script res://tests/ai/vision_world_contract.gd
```
Result: `VISION_CONFIG_FINGERPRINT=3ead6e826bfd2552aa1396a4d266de3603524355c56620033cb1bd84b6df58f3` /
`VISION_WORLD_CONTRACT_RESULT checks=305 failures=0` — confirms
`game/ai/vision/zerkov_vision_config.gd` was read-only and its sealed
fingerprint is unchanged.

## Sawmill Segment Count vs Budget

| Metric | Value |
| --- | --- |
| Authored `structures` rows | 29 (23 `Obstacles`, 6 `Canopy`) |
| Naive per-rect boxing (rows * 4) | 116 |
| Actual baked segments | **98** |
| Segment budget (`SEGMENT_BUDGET_MAX`) | 128 |
| Headroom | 30 segments (23%) |

The real map is within budget; this is not a blocker. Merging reduced the
naive count by 18 segments, mostly from the five perimeter fence rows
(`north_fence`, `west_fence`, `east_fence`, `south_fence`, `southeast_fence`)
touching corner-to-corner and baking into one connected ring outline instead
of five independent 4-segment boxes.

## Changed and Added Files

- `game/ai/vision/occluder_bake.gd` (new): `ZOccluderBake` — the deterministic
  bake, mask assignment, malformed-source validation, and the 128-segment
  budget gate.
- `game/ai/vision/zerkov_occluder_segment.gd` (new): `ZerkovOccluderSegment` —
  the typed baked-segment record (`id`, `mask`, `a`, `b`, `source_ids`) with
  `canonical_record()` / `digest()`.
- `tests/ai/occluder_bake_contract.gd` (new): headless contract covering
  determinism, edge cancellation/merge, mask domains, every malformed-source
  case, the Vision point bound, the segment budget, and the real Sawmill
  layout.
- `tests/tooling/run_occluder_bake_headless_gate.py` (new): two-run headless
  gate script, copied from `run_player_locomotion_headless_gate.py`'s
  structure.
- `docs/qa/occluder_bake_3_10/REPORT.md` (new): this evidence document.

No file outside these paths was modified. `game/ai/vision/zerkov_vision_config.gd`
and `game/ai/vision/raid_vision_world_owner.gd` were read only (constants
`OCCLUDER_LAYER_STRUCTURE` / `OCCLUDER_LAYER_VEGETATION` are read from the
sealed config rather than re-declared). `game/world/sawmill/sawmill_yard_layout.gd`
/ `.tres` / `sawmill_yard.gd` were read only; the concurrent task 3.11 marker
additions visible in the worktree during this run were not touched and the
`structures` / `size_cells` fields this bake consumes were unaffected by them.

One incidental side effect: running the pinned engine once (required to
generate `.uid` sidecars for the new scripts) auto-recreated a pre-existing,
unrelated missing sidecar the editor flagged
(`game/presentation/exact_1080_capture_guard.gd.uid`, owned by other,
concurrent task work) — no content in that file was touched, only its missing
`.uid` was filled in by the engine itself, consistent with "let Godot generate
it by running the engine once."

## Remaining Risks

- The bake is a pure function over authored data; it is not yet wired into
  `RaidVisionWorldOwner`/the runtime Common Vision occluder list. That wiring
  (and any runtime consumption of `ZerkovOccluderSegment` records) is out of
  this task's scope per the brief and belongs to the task(s) that build the
  concrete Vision capability (task 6.2/6.3 territory) or a later Sawmill
  integration task.
- Segment identifiers are stable under "unchanged source geometry" per the
  capability spec, but are *not* stable across an edit that changes which row
  becomes a blob's lexicographically-smallest id (e.g., renaming or removing
  the id that currently anchors a merged run reassigns that run's id to the
  next-smallest contributing id). This is inherent to any content-derived
  (non-arbitrary, non-incrementing) identifier scheme and was a deliberate
  choice over an opaque counter, to keep ids traceable to authored content;
  it is not tested here since the spec's "unchanged source geometry" scenario
  does not require edit-time id stability.
- `RealLayout.structures` / `size_cells` are read directly from the `.tres`
  Resource, not from a live `ZSawmillYard` scene instance; this is intentional
  (the bake must not depend on the scene) but means this contract does not
  re-verify the scene's own painted tiles match the authored rows -- that is
  `tests/raid/sawmill_layout_contract.gd`'s (task 3.4) job.

## Deliberately Not Done

- **`degenerate_segment` is not exercised end-to-end through `bake()`.** Given
  the zero/negative-area guard on every row and `ZWorldUnits`' exact,
  collision-free integer tile-to-Vision-raw scaling, a zero-length resulting
  segment cannot occur through the normal pipeline once a row has passed
  validation (adjacent integer tile boundaries never convert to identical
  Vision points). The guard (`ZOccluderBake.is_degenerate_segment`) is still
  implemented as defense in depth in `_boundary_segments_for_blob` and is
  validated directly as a pure predicate in the contract
  (`_test_degenerate_segment_guard`), rather than fabricating a contrived
  end-to-end trigger for a structurally unreachable path.
- Did not add a convenience `ZOccluderBake.bake_layout(layout)` overload that
  accepts a `ZSawmillYardLayout` directly. The brief explicitly says the bake
  must take rows as parameters and not touch the Sawmill scene; keeping
  `bake()` fully decoupled from `ZSawmillYardLayout`/`ZSawmillYard` avoids any
  implied coupling, at the minor cost of the caller (here, the test) needing
  to pass `.structures` and `.size_cells` explicitly.
- Did not wire the bake into `RaidVisionWorldOwner` or any runtime tick phase.
  Task 3.10 is scoped to the bake itself ("runtime Vision does not infer them
  from physics or TileMaps" — the bake is the explicit alternative); the
  `VISION` reserved phase slot and `raid_vision_world_owner.gd` were read but
  not modified, per the brief's ownership rules.
