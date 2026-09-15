# Layout and presentation boundary

Each study is 672x448 study pixels on a 16-pixel authoring grid, viewed through
the existing 640x360 / exact-3x / 1920x1080 visual convention. Study units are NOT
a change to canonical ZWorldUnits. Camera zoom is one; presentation camera
positions round to whole pixels. The 48px source tiles use explicitly recorded
nearest 1/3 normalization and a shared 256-colour non-dithered palette.

Northline: the short exposed loading-road route competes with the more winding
customs/rear-loading approach. A central freight room, service room, rail gate
and southern fuel yard provide independent landmarks and future loot pockets.
Mercury: the bus-obstructed crossing competes with the rear alley, supermarket
and clinic approaches. Metro stairs and the south barricade are proposed exits.
These are design hypotheses, not measured encounter balance or working extracts.

Floor/road surfaces and cutaway walls are rendered from authored rectangles.
Props remain separate native sprites with foot-based draw order. Explicit wall
and ground-footprint rectangles also instantiate native StaticBody2D collision
shapes. A four-neighbour layout test checks reachability with 3 study-pixel
clearance. Its routes are guide annotations, not a second raid navigation owner.

The view holds no RaidAuthority, inventory, ability or settlement capability.
Inputs control only the review camera, map, sector and annotations. Production
boot remains unchanged. Any production adapter or gameplay use requires later
integration and native full-host regressions.
