# Native full-zone design

## Ownership
`game/world/northline_native/zone/northline_world.tscn` stores authored cells,
props, exact collision shapes, labels, markers, rails and lighting. It has no
runtime script. Shared TileSets reference original sheets. Reusable prop scenes
own their collision footprints. The view adds only camera, inspection walker,
UI and light culling. No runtime JSON terrain construction is permitted.

## Geometry and scale
Keep the original 2688x1792 logical map. Original 48px floor cells are displayed
at scale 1/3 in logical space and zoom 3 into native 1920x1080. Collision rectangles
are not scaled/recomputed from texture pixels. North-wall faces become children
of their associated StaticBody2D so moving a wall segment carries its face and
collider. Editing a face cell alone is explicitly cosmetic.

## Authoring
The exporter operates only on a new output scene and resources, and refuses to
replace a saved map. Inputs are the archived authoring snapshot, not a runtime
source of truth. Subsequent edits use Godot. The full zone reuses already saved
freight prop prototypes without rewriting them; new prop definitions use native
Sprite2D region metadata over the complete original sheets.

## Verification
Tests inspect all nine district markers, nineteen buildings, 541 prop instances,
153 authored wall/fence/boundary rectangles and 528 solid prop footprints. They
compare exact transforms and traverse the four original review paths with the
actual CharacterBody2D. Save/close/reopen tests must retain edited cells/instances.
Map camera input and original source RGBA are checked separately from mechanics.
Archive-only original assets cannot be represented as installed repository files.
