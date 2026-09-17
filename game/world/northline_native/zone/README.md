# Full native Northline

This is the saved native counterpart of all nine Northline districts, not a live
raid map and not a change to the local-save bunker application. It retains the
2688x1792 logical layout, nineteen interiors and all 541 prop placements.

## Open, inspect, edit

Repository review: F6 `game/presentation/northline_native/zone_review.tscn`.
Standalone delivery: open its `project.godot` with Godot 4.7.2, then F5.
The standalone starts with a complete overview. M switches overview/detail;
click the map or a district button to inspect. Q/E cycles districts, WASD/drag
pans, Shift is faster, P enables the collision walkthrough and Tab shows routes.
Exit markers are annotations, not active extraction behavior.

Edit `game/world/northline_native/zone/northline_world.tscn` in Godot's 2D editor.
Terrain and wall faces are ordinary TileMapLayers with shared external TileSets.
Props are reusable `.tscn` instances grouped by district. Walls group their native
face tiles and exact collider under one wall-segment body. Move that segment to
move both. Painting a face tile alone is cosmetic and does not add a collision
shape; edit its associated shape for new wall geometry.

Runtime loads the saved resources. No JSON parser, image cropper or generator
reconstructs the level on open. `tools/migrate_northline_zone_native.gd` is an
optional create-only authoring snapshot; it refuses existing output. Do not delete
saved work merely to rerun it. The previous freight slice remains unchanged.

The scene is about 2.1 MiB of editable text. Godot may show its large-text-resource
save notice. Future subdivision/export optimization is separate from this
fidelity and authoring migration; no frame-rate target is certified here.

## Original art

Eleven full original PNGs are referenced directly, without resizing, quantizing,
repacking or re-encoding. 48 source pixels span 16 logical world units at layer
scale 1/3. Camera zoom 3 into a native 1920x1080 target retains 48 output pixels.
640x360 is the world-space camera footprint, never a small offscreen surface.

The runnable delivery contains all required original sheets. They are not yet
uploaded to this branch. Install from the user-supplied archive directory:

```sh
python3 tools/install_northline_native_sources.py --source-dir /path/to/uploaded-zips
python3 tools/install_northline_native_sources.py --verify
```

Alternatively copy `assets/world/northline_native/sources/` from the delivery and
run `--verify`. No installer runs at game/editor startup. Missing sources remain a
native-CI blocker; source-only checks cannot establish rendering acceptance.

## Tests and scope

```sh
python3 -m unittest discover -s tests/tooling -p 'test_northline_native*.py' -v
xvfb-run -a -s '-screen 0 1920x1080x24' python3 tests/tooling/run_northline_native_zone_gate.py --godot "$ZERKOV_GODOT" --output /tmp/northline-native-new
```

The native gate tests original imported pixels, saved cells, exact geometry,
all four cross-map collision routes, native input, twelve screenshots repeated
in independent runs, and saved tile/prop edits reopened in a fresh process.
See `docs/qa/northline_native/FULL_ZONE_VALIDATION.md` for the precise evidence.

There is no live combat/loot/AI/extraction binding, new save format, multiplayer,
full ambient-animation port or redistribution clearance. Existing product startup,
legacy Northline, Mercury, original freight and addon snapshots are untouched.
