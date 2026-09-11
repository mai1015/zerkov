# Sawmill source TileSet — task 3.3

## Scope

This packet covers only the `[LUNA]` task 3.3 source TileSet authoring. The
authored resource is
`game/world/sawmill/sawmill_tileset.tres`; no scene layout, UI, movement,
navigation bake, Common Vision bake, or add-on source was changed.

The TileSet is locked to 32 px square cells and declares one native terrain
set, one physics/collision layer, one navigation layer, four typed custom data
layers, six draw layers, and an explicit semantic catalog of source tile
coordinates. Every catalog row carries terrain, navigation, collision,
draw-layer, z-order, and source-asset identity fields.

## Source provenance

The source slot links to the exact curated registry row
`zerkov.asset.world.exterior_textures` and exact alias
`world.exterior.textures`. The registry remains the source of truth for the
external sheet:

- source path: `/Volumes/Data/Assets/zerkov/Exterior/Exterior Textures.png`
- source SHA-256: `9b09c86b46b9115953362e2a29e48c3f17b5f6cea3e91d95d23727725b91e09a`
- source dimensions: `704x704`
- source grid: `22x22` cells at `32x32`
- filtering: nearest; mipmaps disabled

The registry row is explicitly `pending_unimported`, so this resource keeps a
texture-free `TileSetAtlasSource` slot and does not create a guessed runtime
path, import sidecar, or sliced atlas. Import policy remains task 9.2 and
selected-sheet slicing remains task 9.3; neither lane is modified or required
for this contract.

## Deterministic contract

Command:

```text
godot --headless --path . --audio-driver Dummy --script res://tests/raid/sawmill_tileset_contract.gd
```

Result:

```text
SAWMILL_TILESET_RESULT checks=721 failures=0 source_asset=zerkov.asset.world.exterior_textures source_status=pending_unimported
```

The contract verifies native TileSet shape/layers, source-slot geometry,
registry ID/alias/provenance/hash/filter policy, terrain/navigation/collision
metadata, deterministic draw ordering, bounded integer atlas coordinates,
semantic coverage, and equality across independent resource loads. It runs no
window, capture, responsive, compact, or alternate-resolution path; no visual
validation was necessary for this metadata-only task.

Task 3.3 remains unchecked in `docs/spec/changes/add-zerkov-playable-raid-2026-09-09/tasks.md`
pending independent review.
