# Sawmill Yard composition — Task 3.4

`sawmill_yard.tscn` is the reusable greybox level. Its editable source is
`sawmill_yard_layout.tres`: ordered terrain/detail rectangles, named solid
structures, three landmark records, nine anchors and four route footprints.
`sawmill_yard.gd` places those cells into real `TileMapLayer` nodes on tree
entry. Change the Resource, then reinstantiate/recompose the scene to see the
edit. `compose()` rebuilds the same authored cells without random placement.
The accepted Task 3.3 TileSet and atlas are unchanged.

The 40×20 tile bounds describe a 1280×640 **world-coordinate rectangle**, not
a display or capture size. A world unit remains one accepted 32 px source tile
through `ZWorldUnits`. The isolated visual harness renders a 640×360 world at
exact nearest 3× into the only supported 1920×1080 output. Production camera,
movement and authority composition remain later work.

West Service is a stone arrival pocket with immediate cover and a nearby
service cache. A vertical link reveals the direct Haul Lane and longer South
Bypass. Log Racks use parallel timber bars and a sawdust aisle on sand. Saw
House is a stone room bounded by a roofless U with a three-cell opening.
Settling Dock combines a sawdust pad, blue inlet and timber rim. Fence wings
frame Road Gate at the eastern road throat. Its extract zone is inside the
closed world perimeter.

Every declared corridor has a three-cell (96 source px) swept footprint;
cover stays outside it. All 548 unblocked cells connect to spawn. The 252
distinct blocking cells close the perimeter and form obstacles. There are no
orphan walkable pockets or overlapping blocking layers. Named structures
account for all 231 occluding tile cells.

## Authored anchors

Positions are source/world pixels at tile centers. IDs, rather than child
order or display names, identify the records.

| Stable ID | Cell | Position px | Purpose |
| --- | --- | --- | --- |
| `zerkov.spawn.sawmill.west_service` | 4,15 | 144,496 | Player arrival |
| `zerkov.loot.sawmill.crate.log_racks` | 9,5 | 304,176 | Supply landmark 01 |
| `zerkov.loot.sawmill.crate.saw_house` | 21,4 | 688,144 | Supply landmark 02 |
| `zerkov.loot.sawmill.crate.settling_dock` | 25,14 | 816,464 | Supply landmark 03 |
| `zerkov.loot.sawmill.service_cache` | 10,14 | 336,464 | Fixed extra crate |
| `zerkov.loot.sawmill.corpse.haul_lane` | 29,12 | 944,400 | Fixed corpse anchor |
| `zerkov.extract.sawmill.road_gate` | 37,10 | 1200,336 | Zone `(1152,288,96,96)` px |
| `zerkov.encounter.sawmill.scav_cover` | 30,6 | 976,208 | Future Scav staging |
| `zerkov.encounter.sawmill.mutant_verge` | 15,17 | 496,560 | Future mutant staging |

`layout.anchor(id)` returns a detached record. Each has a distinct, adjacent,
reachable approach cell. Crate/corpse records reference accepted inventory
profiles; they do not create inventories or grant contents. Purple and blue
atlas glyphs are greybox proxies, not crate, actor or corpse art. The yellow
gate glyph is the extraction proxy.

## Separation and handoff

- `Ground`, `Detail`, `Obstacles`, `Canopy` and `Markers` are native tile layers.
  Only Ground, Obstacles and Canopy enable collision. Detail and marker art
  cannot change collision or traversal.
- `Anchors` exposes metadata on Marker2D children, without spawning, inventory,
  interaction, task or countdown behavior.
- `Routes` exposes authoring reachability metadata. Native TileMap navigation
  stays disabled so ground under solids cannot form accidental navigation.
  The path-request seam/bake remains Task 3.9.
- `OccluderSources` exposes each structure's ID, layer, tile, role and cell
  rectangle. Deduplicated Common Vision segments/admission remain Task 3.10.
- `Bounds` exposes the source-pixel rectangle. Marker lifecycle integration
  and the whole Sawmill authority contract remain Tasks 3.11–3.12.

Run `python3 tests/tooling/run_sawmill_layout_gate.py` from the project root.
It checks exact launch arguments, two headless composition runs, retained
TileSet/registry contracts, native captures/contact sheet, PNG headers/hashes,
display scope, strict specs and the diff. See the Task 3.4 QA report for evidence.
