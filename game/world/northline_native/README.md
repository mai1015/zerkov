# Native Northline freight slice

This is a migrated freight/inspection slice, **not yet the whole Northline map**.
The existing full-map and game startup are unchanged.

## Run

The standalone project already contains the original sheets. Open its
`project.godot` in Godot 4.7.2 and press F5. In the full repository, install the
originals first (command below), then F6 on:

`game/presentation/northline_native/freight_review.tscn`

WASD or drag pans the camera. Home returns to the loading entrance, End inspects
the annex, and P toggles the collision-aware inspection walker. This scene has
no combat, loot, raid settlement or profile mutation.

## Edit native resources

Open `game/world/northline_native/freight_sector.tscn` in the editor. Frame the
selected node (View -> Frame Selection / Shift+F) because the conserved coordinates are around x=1000/y=600.
Select `Terrain/FreightFloorBounds/FreightFloor` and use Godot's TileMap painting
tools. Its external `tilesets/ground.tres` directly references original sheets.
Props beneath `WorldProps` are instances of the scene files in `props/`; move
an instance to move its sprite, contact shadow and collision footprint together.
Changing a prototype deliberately affects its instances.

The TileSet grid is 48 source pixels. Native layer scale 1/3 maps it to the old
16 logical world units; the native 1080p camera at zoom 3 preserves those original
48 pixels on screen. This is a transform, **not an image downsample**.

Terrain masks preserve partial-tile room/road edges. Walls retain exact native
off-grid physics rectangles rather than adding coarse tile-grid collision.
Painted wall-face tiles do not automatically create new blockers: edit the wall
segment's native shape or move its parent explicitly. Gameplay/navigation/vision
bakes are not connected in this environment-review slice.

The saved scene has no script. `migrate_northline_freight.gd` is a create-only,
one-time migration record, not part of game startup; do not remove your saved
scene and rerun it over hand edits. Original JSON remains a test fixture only.

## Original sheet installation for the repository

The PR contains the native resources and source hashes. The 11 original PNGs
are included in the downloadable project, but are not uploaded into the GitHub
branch by this session. A plain checkout needs them before opening this slice:

```sh
python3 tools/install_northline_native_sources.py --source-dir /path/to/uploaded-zips
python3 tools/install_northline_native_sources.py --verify
```

The source directory must contain the original `abandoned-assets(1).zip` and
`post-apocalyptic-assets(1).zip`. The installer verifies both archive and selected
member hashes, then copies COMPLETE PNG bytes. It does not crop, resize, quantize,
generate or recompress an image. Different existing files are never overwritten.
You can also copy the `assets/world/northline_native/sources/` directory from the
provided project and run `--verify`. Source art availability is an explicit
merge/review prerequisite; missing art is not a passing native test.

## Evidence

```sh
python3 -m unittest discover -s tests/tooling -p test_northline_native_sources.py -v
python3 tests/tooling/run_northline_native_gate.py --godot /path/to/Godot --output /tmp/new-native-review
```

The gate uses a temporary standalone copy of these actual scene sources and the
real pinned engine, not stubs for game addons. It verifies original decoded pixel
data, native geometry/input, repeated 1080p captures and a third-process edited
scene reopen. It is not a full six-addon product-host test.

The actual editor UI was exercised: erase a tile, edit a prop position in the
Inspector, save with Ctrl+S, then reopen in a separate native process. Those edits
persisted. This container also emitted non-fatal Vulkan startup diagnostics in
the graphical editor; a zero-diagnostic editor-startup gate remains open.
Full nine-district migration, dynamic ambient effects and user art approval are
separate follow-up work. Original source receipt does not clear redistribution.
