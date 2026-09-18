# Blackwater Crossing — authored environment

1792x1344 logical units; nine environment districts, twelve interiors, 102 original
prop instances and 45 saved TileMapLayers / 17,477 cells. Three river crossings
provide alternatives across the northern road, central checkpoint and southern
service walkway. The original native scene is retained from the previously
reviewed standalone package; no source-image transformation is performed.

Edit `blackwater_world.tscn` with the normal Godot 2D editor. Tiles and reusable
prop instances reference the complete original PNG sheets now committed to the
repository. Wall segments carry their face tiles and native collision; painting
additional visual wall tiles alone does not author a new physical obstruction.
Water uses the saved sloping convex polygons, not an inferred bounding rectangle.
No generator rebuilds this environment on startup.

The production wrapper is `game/world/live_maps/blackwater_live.tscn`. It adds
explicit map-scoped gameplay anchors and one EastRoadSupply crate without rewriting
this environment. Use normal F5 -> local campaign -> bunker raid briefing ->
Blackwater Crossing -> Deploy Solo. Current live scope is a three-cache Supply
Run, one extraction zone and the existing scav/mutant encounters, not every
inspection marker as an active mission or extraction.

The earlier standalone inspection gallery is a separate delivery, not required
by this repository integration. Production tests and launch instructions are in
`game/world/live_maps/README.md` and `docs/qa/live_maps/VALIDATION.md`.
