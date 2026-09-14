# Task 3.9 — Navigation data and the deterministic path-request seam

Change: `add-zerkov-playable-raid-2026-09-09` · Task: `3.9 [SOL]`
Worktree: `.claude/worktrees/implement_moving` · Engine: Godot `4.7.2.stable.official.ed1daf0bf`
Date: 2026-09-14 · Evidence: headless contract, two-run Python gate · Human approval: not applicable (no visual output)

## What was built

`game/world/navigation/` (new package, all `RefCounted`, no scene tree):

| File | Role |
| --- | --- |
| `z_navigation_grid.gd` | Authored navigation data. `bake_from_sawmill_layout()` / `bake_from_movement_world()` derive the blocked-cell set by probing task 3.6's `ZMovementWorld2D` (built through `ZMovementWorldBuilder` from the same authored layout) with its own `register_actor` predicate at every authored cell centre, using the task 3.5/3.6 player body half extents (8 px). No overlap test is re-implemented and no structure list is re-interpreted, so navigation blocking **is** the authoritative collision truth at navigation-body scale. Exposes `revision()`, `is_blocked/is_walkable/has_cell`, explicitly `(y, then x)`-ordered `blocked_cells()`, and an advisory `digest()`. |
| `z_navigation_path_result.gd` | Typed outcome value object: `ok`, `unreachable`, `start_blocked`, `goal_blocked`, `out_of_bounds`, `budget_exhausted`, `stale_revision` — never a bare array. Carries `cells`, integer `cost`, `expanded_nodes`, `budget_nodes`, `cached`, plus `canonical_record()/digest()` (chunked so any path length stays within `ZCanonicalValue` bounds). |
| `z_navigation_astar.gd` | Bounded A*: integer costs (10 orthogonal / 14 diagonal), integer octile heuristic, array-based binary heap totally ordered by `(f, h, cell.y, cell.x)`, fixed neighbour order, parent replacement only on strict improvement, diagonal steps may not cut a blocked corner. Pure function of `(grid, start, goal, budget)`; no floats, no Dictionary/Set iteration order in any ordering decision. |
| `z_navigation_path_service.gd` | The request seam. `request_path(start, goal, expected_revision, budget_nodes)` validates in fixed order (stale_revision → out_of_bounds → start_blocked → goal_blocked → budget_exhausted-with-zero-work → bounded search), returns the typed result, and caches only `ok` results. Cache is keyed by `revision:grid-digest|start|goal|budget`, hard-cleared on every (re)bind and on `invalidate_cache()`, verified against the revision block on every hit (never silently stale), FIFO-bounded at 64 entries. `seal()` is terminal teardown; every later request returns `stale_revision` and mutates nothing. Same-revision rebinding is refused (`revision_unchanged`) so entries can never outlive their grid. |

No engine navigation API is used anywhere: no `NavigationServer2D`, no `NavigationAgent`, no `NavigationRegion2D`, no async/threaded navigation map, no `get_simple_path`. The contract enforces this by scanning all four sources for those tokens (plus `randf`, `Time.get_`, `await`, `_process(`, `delta`, `preload(`, `res://`).

## How pathfinding results are kept OUTSIDE canonical add-on state

1. **By construction.** The package is four `RefCounted` modules. Nothing in it holds a reference to `RaidAuthority`, `InventoryAuthority`, `WeaponAuthority`, `GameplayAbilityWorldCoordinator`, `CommonVisionWorld2D` or `LevelTaskRuntimeOwner` — the contract's purity scan treats those identifiers (and `enqueue_intent`, `register_phase_handler`) as banned tokens in the seam sources. The service registers with no authority phase, submits no intents, and its results are value objects with no back-reference to any world.
2. **By proof.** `_test_requests_leave_state_digest_unchanged` builds a real `RaidAuthority` raid (sawmill layout, active lifecycle, two advanced ticks), snapshots `state_digest()`, then issues fresh, cached, `start_blocked`, `out_of_bounds`, `budget_exhausted` and `stale_revision` requests, re-bakes the grid, rebuilds and refills a second service cache — and asserts the digest is **bit-identical** afterwards. It then advances one more tick and asserts the digest **changes**, proving the digest is live and the equality was not vacuous. Teardown is observed as a digest change too.
3. **What would break if someone tried.** Writing a path into canonical state would put a 30–50-cell array (and its expansion count) into every hashing of `state_digest()`. Re-pathing between two ticks would then change the raid digest with no authoritative cause, breaking bit-identical replay of the same accepted inputs, breaking digest-equality settlement checks, and giving late/stale AI controllers the power to mutate a replaced raid's canonical record after teardown. The revision-keyed cache keeps all of that outside the digest: rebuilding it is proven digest-neutral.
4. `ZNavigationGrid.canonical_record()`/`digest()` and `ZNavigationPathResult.canonical_record()`/`digest()` are explicitly **advisory** audit values; nothing in `RaidAuthority.state_digest()` consumes them.

## Verification commands

```sh
export ZERKOV_GODOT=/Volumes/Data/sdk/godot/editors/4.7.2/Godot.app/Contents/MacOS/Godot

# Contract (single run)
$ZERKOV_GODOT --headless --path . --resolution 1920x1080 --audio-driver Dummy \
  --script res://tests/raid/navigation_path_contract.gd

# Gate (two runs + diagnostic scan)
GODOT_BIN=$ZERKOV_GODOT python3 tests/tooling/run_navigation_path_headless_gate.py
```

## Verbatim output

Contract (single run):

```
Godot Engine v4.7.2.stable.official.ed1daf0bf - https://godotengine.org

NAVIGATION_PATH_RESULT checks=611 failures=0
```

Gate:

```
--- Navigation path contract run 1 ---
Godot Engine v4.7.2.stable.official.ed1daf0bf - https://godotengine.org

NAVIGATION_PATH_RESULT checks=611 failures=0
--- Navigation path contract run 2 ---
Godot Engine v4.7.2.stable.official.ed1daf0bf - https://godotengine.org

NAVIGATION_PATH_RESULT checks=611 failures=0
NAVIGATION_PATH_HEADLESS_GATE runs=2 checks=1222 failures=0 diagnostics=0
```

Read-only dependency contracts re-run clean after this task (no regressions):

```
MOVEMENT_AUTHORITY_RESULT checks=539 failures=0
SAWMILL_LAYOUT_RESULT checks=8006 failures=0 anchors=9 landmarks=3 routes=4 reachable_cells=548 native_cells=1073 physics_cells=252 occluder_cells=231 human_approval=false
```

## Evidence coverage map

| Required evidence | Where |
| --- | --- |
| Straight open path | `_test_straight_open_path` — exact straight cell line, cost 90, 10 expansions, oracle agreement; plus start==goal single-cell path |
| Path routed around an authored wall | `_test_path_around_authored_wall` — synthetic wall column with one opening (hand-computed optimum 88, cross-checked by an independent uniform-cost oracle) and the real authored mill wall forcing the authored y=6 doorway at x∈[20,22] |
| Spawn → extraction reachable on the real layout | `_test_spawn_to_extraction` — typed task 3.11 markers, optimal path (34 cells, cost 350), plus every extraction-zone cell and every patrol waypoint |
| Blocked start / blocked goal | `_test_blocked_start_goal_and_out_of_bounds` — north-fence start, mill-wall goal, precedence ordering |
| Out of bounds | same test — negative start, x/y beyond the authored grid, precedence over blocked cells |
| Unreachable (fully enclosed goal) | `_test_unreachable_enclosed_goal` — enclosing ring; the enclosed cell stays *walkable* but unreachable; negative results are never cached |
| Budget exhaustion | `_test_budget_exhaustion` — exact boundary: budget == expanded → identical ok path, expanded−1 → `budget_exhausted` with exactly that many expansions, zero/negative budget performs no work |
| Identical path across two independent runs | `_test_determinism_two_independent_runs` — two full bake+service pipelines produce identical `ZCanonicalValue.sha256` path digests, cell sequences and expansion counts; identical after cache invalidation and after interleaved requests |
| Blocking agrees cell-for-cell with 3.6 collision | `_test_blocking_agrees_with_collision` — all 800 cells probed against an independently built `ZMovementWorldBuilder` world (0 mismatches), equal to the authored Obstacles union (179 blocked / 621 walkable), plus a synthetic directly-constructed world |
| Path requests leave `state_digest()` unchanged | `_test_requests_leave_state_digest_unchanged` — see the canonical-state section above |

## Files changed (all inside the task's owned paths)

- `game/world/navigation/z_navigation_grid.gd` (+ generated `.uid`)
- `game/world/navigation/z_navigation_path_result.gd` (+ generated `.uid`)
- `game/world/navigation/z_navigation_astar.gd` (+ generated `.uid`)
- `game/world/navigation/z_navigation_path_service.gd` (+ generated `.uid`)
- `tests/raid/navigation_path_contract.gd` (+ generated `.uid`)
- `tests/tooling/run_navigation_path_headless_gate.py`
- `docs/qa/navigation_path_3_9/REPORT.md`

## New entrypoints for the orchestrator to register

`config/first_playable_1080_gate.json` does not classify these yet; per the shared brief that registration is central and out of this task's scope:

- GDScript entrypoint: `tests/raid/navigation_path_contract.gd`
- Python display driver: `tests/tooling/run_navigation_path_headless_gate.py`

## Remaining risks and deliberate non-goals

- **Blocking semantics.** A cell is "walkable" iff the 8 px-half-extent player body can stand at its centre in task 3.6 collision. The authored Sawmill data is cell-aligned, so this equals "no Obstacles rect covers the cell"; water and Canopy do **not** block navigation (task 3.4's display-oriented reachability counts water as blocked — a different, intentionally stricter notion, not a conflict). If future authored geometry introduces sub-cell-thin obstacles between cell centres, cell standability would need re-review; today's contract would catch a drift cell-for-cell.
- **Budget identity.** The cache key includes the request budget because a truncated budget is a different request outcome. For the same revision, any budget large enough to finish yields the *identical* path (asserted), so callers see one path per (start, goal, revision).
- **Not done (out of scope):** no AI controller consumes the seam yet (tasks 6.x); the seam is not wired into `ZSawmillYard`/`RaidSession` composition (scene wiring belongs to the integration task that owns those files; `ZSawmillYard`'s comment about the "game-owned Task 3.9 bake" refers to this package, which that read-only file still names but does not yet reference); no runtime re-bake on layout edit; no diagonal-corner policy options; no path smoothing (paths are cell sequences by design — steering stays with locomotion and authoritative collision).
- The `.uid` sidecars were generated by one engine pass over the project (`--headless --editor --quit-after 120`); the pass touched no tracked file outside this task's owned paths.
