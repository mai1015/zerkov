# Layout, scale and ownership

Expand actual geometry rather than scaling the original scene or sprite art.
The environment is four times larger on each axis than the 672x448 study.
Customs/checkpoint occupies the west, freight and receiving form the central
contested hub, rail sidings supply the northern approach, power/fuel anchors the
east, and housing/clinic/motor facilities support southern rotations. Two
bridges constrain the drainage crossing without sealing the south route.

The overview and source-pixel camera inspect the same native scene. M uses 1/6
camera zoom to fit the entire map; detail/walking uses zoom 1. Both preserve the
640x360 world raster and exact 1920x1080 output with nearest 3x enlargement.
A crisp overlay projects labels and routes from real world coordinates; it is
not a pre-rendered map image. The normal-camera rectangle gives size context.

Walls and ground cover footprints instantiate StaticBody2D shapes. A standalone
CharacterBody2D inspector with 5px radius uses native collisions; the offline
8px-grid solver reserves 6px clearance and supplies only checked review paths.
Opening the overview pauses the inspector. All production authorities, native
add-on internals, UI routes and ZWorldUnits are unchanged. The inspector must
never be mistaken for an authoritative playable raid actor.

Terrain draw generation culls tiles to the camera's actual world rectangle
while retaining world-anchored atlas phase. Only nearby point lights are enabled
in detail; overview omits local lights for readability. No performance benchmark
or low-end device support is inferred from the software-renderer captures.
