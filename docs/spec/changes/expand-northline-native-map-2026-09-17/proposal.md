# Full Northline native authoring continuation

## Approval and goal
The user reviewed the native freight migration and approved continuing the fix
across the map. Continue PR #24 without changing the offline MVP, raid authority,
original source images, existing legacy review or product entrypoint.

## Scope
Migrate all nine Northline districts and nineteen interiors to a saved native
Godot environment. Preserve all prop placements, wall/cover geometry, spawn/exit
markers and route topology. The scene/resources are authoritative for editing;
a create-only authoring migration is not called by runtime. Original PNGs stay
byte-identical. Native 1920x1080 detail rendering retains the previous logical
640x360 view; zooming out is a map overview, not a low-resolution render pass.

## Non-goals
No live raid, UI/account/save changes, multiplayer, loot/extraction mechanics,
full ambience/weapon animation overhaul, or 60/120 FPS acceptance. No automatic
terrain collision on visual-only cutaway wall tiles. No clearing asset licensing.
The previous freight slice remains available as a regression reference.

## Evidence
Native scene/resource/source-pixel tests, all four collision routes, district
captures, native save/reopen and a canonical editor roundtrip. Original art must
be installed for rendering: absence is BLOCKED, never a passing placeholder.
