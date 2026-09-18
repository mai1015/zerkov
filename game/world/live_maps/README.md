# Native offline raid maps

## Play through the actual application

Open the full repository in its locked standard Godot (`4.7.2.stable.official.ed1daf0bf`)
and press **F5**. Use New Local Game / Continue, enter the bunker and open the raid
briefing through its existing briefing action or M shortcut. Select **Sawmill Yard**,
**Northline Exclusion Zone**, or **Blackwater Crossing**, then click **Deploy Solo**.
The same production actor, native inventory, combat, health, AI, search task,
extraction and local settlement owners run each map. An inspection walker is never
mounted by this flow. No Steam, server, account or cloud-save service is required.

The current mission on each map is: search its three marked caches, take and retain
the Supply Crate objective, then enter and complete the named extraction countdown.
The existing inventory interaction opens the searched cache; transfer the item
through the retained loot workspace. Leaving an exit interrupts the countdown;
losing the objective prevents completion. Current native-map exits are West Service
on Northline and East Road on Blackwater. Other original review exit markers are
not active extraction zones. Combat/reload/interaction use existing input bindings.

Each native map currently instantiates the existing scav and mutant encounters.
These are functional integrations, not completed map-population or loot balancing.
The HUD/task/map/summary use actual selected or committed map identities. Unsupported
future regions remain locked. Original artwork renders at native 1920x1080 with
zoom 3 over the same 640x360 logical detail footprint. Sawmill keeps its old scale.

## Authoring and collision truth

NativeRaidMap preflights one allowlisted script-free wrapper before equipment escrow:

- `northline_live.tscn` references the saved whole native Northline environment.
- `blackwater_live.tscn` references the saved Blackwater environment and adds one
  EastRoadSupply crate. Its nine sloping river polygons remain exact convex solids.
- Each wrapper supplies seven stable gameplay anchors: player, scav, mutant,
  three caches and one extraction zone. Cache markers are children of actual props;
  Approach children define production-body access points.
- Every enabled native solid is copied into the existing authoritative movement
  owner. Walking-only water does not become opaque or bulletproof geometry.
  Other rectangles supply shot obstruction and sight/interaction segments too.
- Navigation probes the same owner, checks corridors between adjacent cells, and
  reserves a conservative 4px steering allowance. Thin walls cannot be crossed
  simply because both neighboring cell centers are free. Physical body size is
  unchanged. This advisory grid can conservatively reject narrow passages.

Save tiles, props and collision edits in Godot. Startup does not call the old JSON
map generator. Changes to any scene/resource/source image participate in the map
content digest, and invalid sources, executable dependencies, duplicate anchors,
unsupported collision shapes, blocked/unreachable approaches or budget overflow
reject preflight before deployment. The finite collider limits are 1,024 movement,
1,024 shot obstacles and 4,096 sight segments. There is no silent truncation.

Selecting a native map in the briefing reads only its committed, derived tactical
preview. It does not instantiate the authored world, inspect collision, bake
navigation, reserve gear or write the profile. The real deployment action first
renders the existing loading route, then performs source/dependency integrity,
scene, collision and anchor preflight while the home owner is still intact. Only a
successful preflight may save/retire home and create escrow. A failure returns to
the briefing without changing the saved loadout.

Large-map navigation grids are committed as derived caches under `cache/`. Runtime
accepts one only when its map identity, bounds, collision-geometry digest, payload
shape, reciprocal edge relations and final grid digest validate. Missing/stale
cache data falls back to a fresh authoritative bake behind the loading screen.
Regenerate or verify the committed records explicitly; normal startup never writes
project files:

```sh
"$ZERKOV_GODOT" --headless --path . --script res://tools/build_live_map_cache.gd -- --write
"$ZERKOV_GODOT" --headless --path . --script res://tools/build_live_map_cache.gd -- --check
```

Preflight remains synchronous after the loading screen is visible. Large-map load
time and steady-state rendering still need target-hardware qualification. Tests
that advance canonical ticks explicitly do not prove 60 or 120 displayed FPS. No
scenery is downscaled to improve a reported timing result.

## Persistence and ownership

The existing ProfileStore and settlement format retain an optional closed map
field `{id, revision, digest}` for these native maps. Fieldless legacy Sawmill
records remain valid. That descriptor is pinned before escrow, checked on request
retries and copied from the active record into the committed receipt. UI cannot
change a deployed raid's map or attribute an old receipt to a new selection.

Recovery never loads the map or resumes interrupted simulation. Existing
abandonment/prepared-receipt rules retain map attribution while resolving the same
local gear state. No new save backend, export format, interprocess lock or power-loss
guarantee is introduced. Default map selection on a newly opened home is Sawmill;
selection is ephemeral presentation state, not a new persisted profile preference.

## Reproduce validation

```sh
python3 tests/tooling/test_live_maps_runner.py
python3 tests/tooling/test_ui_first_playable_scope.py
python3 tools/check_first_playable_1080.py
python3 tools/run_live_maps_contracts.py --godot "$ZERKOV_GODOT" --output /tmp/native-raids-new
# On an actual exact-1080 graphical display:
python3 tools/run_live_maps_contracts.py --godot "$ZERKOV_GODOT" --output /tmp/native-raids-visual-new --maps northline blackwater --scenarios launch --graphical
```

Use fresh output directories. The runner cold-copies the real application and
native add-ons, uses isolated test profile IDs, sends actual Godot keyboard/mouse
input and paces canonical ticks for reproducible functional scenarios. It performs
extraction and enemy-driven death, one injected settlement-write failure/retry,
return home, redeployment, abandonment recovery and two independent fingerprint
reads. It does not call inspection teleports or substitute fixture providers.
A separate contract uses explicit fake storage/inventory ports for exhaustive
persistence checkpoint cases; those are not the actual-file user-flow runs.

See `docs/qa/live_maps/VALIDATION.md` for exact results, diagnostics, CI status,
known limitations and remaining human/controller/performance acceptance.
