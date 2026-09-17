# Design

## Native source of truth
`game/world/northline_native/freight_sector.tscn` owns the authored scene. It has
no script. Terrain/road/interior/wall layers reference shared external TileSet
resources; prop instances reference editable `.tscn` prototypes. Source PNGs
are full unmodified 768x768 sheets. Atlas regions are native Godot metadata,
not extracted or recompressed image files.

## Scale and physics
TileSet cells retain their original 48x48 source pixels. Layer/Sprite scale of
1/3 maps these to the pre-existing logical coordinates, while a native 1920x1080
camera at zoom 3 displays one source pixel per output pixel at normal view.
No low-resolution SubViewport is used. The same 640x360 world-space area remains
visible. This conversion changes neither actor movement speeds nor door widths.

The slice is Rect2(864,448,832,432), containing freight and inspection interiors.
All 49 prior prop positions and 18 intersecting wall/fence solids are retained.
Off-grid old wall geometry is represented by native StaticBody2D rectangles;
wall-face tilemaps are visual-only. There is no duplicate TileSet collision.
Moving a wall-segment parent moves its face and collider together. Painting an
extra wall-face tile does NOT automatically author a new obstruction; geometry
editing is explicit. Prop instances carry their own native footprints.

## Authoring versus runtime
The create-only migration tool was used once to create native resources from
legacy records. It rejects an existing sector scene and is never called by the
review runtime. After migration, edit and save the scene in Godot. Do not
regenerate it over manual edits. The new review controller only handles camera
and inspection movement. Tests may read the old layout as a comparison fixture;
the new level does not depend on it to draw or reconstruct placement.

## Presentation scope
Four native task lights and static freight dressing are included. Wind, steam,
dust, independent aiming and combat effects are not reimplemented here. Existing
review character art is reused with the corrected source-facing convention.
No claim that this inspector is a RaidAuthority actor is made.

## Verification and delivery
Validate unchanged archive/member hashes, all decoded RGBA pixels after native
import, exact collision transforms, actual camera/walk input, scene save/reload
and fresh-process reopening. Only 1920x1080 native readbacks count as captures.
The original art must be present before native tests. Source-only CI may check
structure and installer failures but cannot substitute for a rendering run.
