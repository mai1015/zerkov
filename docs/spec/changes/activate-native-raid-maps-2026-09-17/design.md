# Integration contracts

An allowlisted map catalog loads a script-free saved native environment with
explicit gameplay markers. Scene geometry is copied into detached immutable values
before deployment. It is not reconstructed from the historical layout JSON.
The selected scene, original source bytes, geometry and marker digest are pinned
before loadout escrow. Failed preflight does not mutate the profile. Scene objects
are never passed to UI or domain callbacks; a root-owned map adapter supplies the
existing owners. No collider, occluder or shot obstruction is silently discarded
at a legacy capacity limit. The bounds are raised explicitly with negative tests.

Movement uses exact scene rectangle AABBs and strictly convex authored water
polygons through ZMovementWorld2D. River banks are not replaced by oversized
bounding boxes. Polygon queries use bounded integer separating axes and exact
rational sweep intervals. AI navigation is baked by probing that owner, including
center-to-center corridor checks so free cells cannot connect through thin walls.
Native-map navigation uses a 4px conservative steering allowance around the real
8px half-extent actor; the physical actor is never shrunk. Legacy Sawmill retains
its previous navigation behavior. Explicit water-only blocks walking but not sight
or gunfire. All interactive crate markers reference their actual prop; approach
positions must fit the production 8px half-extents body. Default Sawmill retains
its legacy data contract. Three map-scoped searches plus possession of the objective
and the named map exit feed the existing native LevelTask/ExtractionCountdown.
Foreign-map interaction IDs are rejected before accessing a native inventory.
Blackwater adds one explicit saved EastRoadSupply crate instance in its live
wrapper, increasing enabled colliders from 188 to 189; the original environment
scene is retained unchanged. Three viable native approaches replace review-only
assumptions about where a production-sized player could stand.

An optional closed map descriptor in existing escrow/receipt records pins map id,
revision and content digest. Old fieldless Sawmill records remain valid. Reusing a
deployment request with a different descriptor rejects rather than allocating or
returning an unrelated raid. Recovery retains the original map context without
loading scene assets and never resumes an active raid or transfers uncommitted loot.

UI submits finite selection commands in a current home/briefing epoch. Existing
briefing, HUD and summary reflect the selected/committed map; cached view dependencies
include map identity. No map switch is admitted during deploying/active/settling.
Native maps render at 1920x1080 with the original 640x360 logical footprint; Sawmill
retains its existing scale. Gameplay transforms remain separate from rendering.

Deliver on a follow-up branch without altering native addon packages, font files,
source sheets, current health/equipment policies or unrelated map/editor scenes.
