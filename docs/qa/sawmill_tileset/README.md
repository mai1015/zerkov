# Sawmill source TileSet — Task 3.3

## Scope

This packet covers only the source TileSet slice. It does not compose the
Sawmill Yard layout (Task 3.4), author a TileMap, bake Common Vision, change
UI or movement, modify add-ons, or apply Task 9.2 import-policy behavior or
Task 9.3 external-sheet slicing. Task 3.3 remains unchecked pending
independent review.

## Project-owned source and license

The atlas is authored in-repository as a deterministic, text-authored SVG:

- `assets/world/sawmill/sawmill_greybox_atlas.svg`
- 128x128 source pixels, four by four 32 px cells, crisp edges
- SHA-256: `1af26d2e20a781334ba155381bb64d5c750b84a375a84a4669feb9bbc1b071ad`
- license: `licenses/zerkov-sawmill-greybox-MIT.txt`
- license SHA-256: `c6aa1ec133530b941e0c1d36aec6c0cffc93626f828e94c5e37d400fc26a1709`

Registry identity and provenance are explicit in
`game/content/asset_registry.json`:

- ID `zerkov.asset.world.sawmill.greybox_atlas`
- alias `world.sawmill.greybox_atlas`
- imported runtime path `res://assets/world/sawmill/sawmill_greybox_atlas.svg`
- project-relative provenance root `res://` plus
  `assets/world/sawmill/sawmill_greybox_atlas.svg`
- project-owned family, nearest filtering, mipmaps disabled, cleared MIT license

The pending external `zerkov.asset.world.exterior_textures` row is not used,
copied, or coordinate-guessed. No unmerged Task 9.2 behavior is required.

## Semantic and native authoring

`game/world/sawmill/sawmill_greybox_manifest.json` is the companion semantic
coordinate registry. It fixes row-major coordinates and frame indices, stable
IDs, six terrains, four navigation kinds, three collision kinds, six draw
layers, the eight valid Godot square peering positions, polygon kinds, z/y
metadata, and two alternative IDs. All stable IDs are checked with the bounded
`ZIdentityRules` grammar.

`game/world/sawmill/sawmill_tileset.tres` is a real `TileSet` containing:

- a non-null `TileSetAtlasSource` bound to the SVG, with all 16 base
  coordinates and alternatives 1 at dirt and road;
- native per-tile `TileData` for every catalog row, including four String
  custom-data layers consumable by a TileMap (`source_tile_id`,
  `navigation_kind`, `collision_kind`, `draw_layer`);
- one six-terrain set with explicit peering at only the valid bit set
  `[0, 3, 4, 7, 8, 11, 12, 15]`, one navigation layer with full-cell polygons
  on traversable rows, one physics layer with full-cell/dock-edge collision
  polygons and one-way data, and one occlusion layer;
- tile-local polygons centered around the TileMap cell origin, so a
  `TileMapLayer.map_to_local()` transform places all 11 navigation, 6
  collision, and 4 occluder shapes inside their intended 32 px world cells;
- explicit draw z-order/y-sort metadata and stable semantic metadata linking
  the resource to the registry and manifest.

## Headless contract

Command:

```text
godot --headless --path . --audio-driver Dummy --script res://tests/raid/sawmill_tileset_contract.gd
```

Observed result after repair:

```text
SAWMILL_TILESET_RESULT checks=1319 failures=0 tiles=16 alternatives=2 cache_mode=ignore source_asset=zerkov.asset.world.sawmill.greybox_atlas source_status=available
```

The contract performs two distinct `ResourceLoader.CACHE_MODE_IGNORE` loads and
compares canonical metadata and native TileData signatures. It includes
fail-before probes for zero native coordinates, missing TileData, navigation,
collision, terrain, and custom-data surfaces, and confirms the repaired
resource has no findings. It uses a TileMapLayer and `map_to_local()` to check
world bounds rather than accepting untransformed resource-local geometry. The
registry contract was also run headlessly with zero validation failures; Godot
may print its existing SVG image-dimension warning while checking the imported
source.

No UI, viewport, capture, visual, responsive, compact, or alternate-size test
was run. The exact 1920x1080 visual path was not necessary for this source-only
work.
