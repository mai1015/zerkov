# Animation audit and remaining integration work

Inspected map branch: PR #8, e9720bbafed702aa372dfea971098fc839c21792.
Inspected task-9 components: PR #5, 34ad860818135fc8ed617fbf0636eb885d37c01d.
These are separate branches and separate presentation paths. No claim that the
review scene exercises task-9's production event adapter is valid yet.

## Fixed in this change

1. review_walker.gd selected walk from requested keys after move_and_slide. A
   blocked character could animate walking. Selection now uses actual resolved
   displacement; a native held-W wall test verifies idle on contact.
2. A shared elapsed timer was multiplied by either idle or walk FPS, causing
   discontinuous transitions and unchanged sprint cadence. Separate idle and
   distance-driven gait phases now reset on transitions. Cadence follows distance.
3. Visual sprite positions followed fractional movement directly. Only sprite
   offsets are now snapped; the CharacterBody still uses fractional positions.
4. The visible actor used unclothed base body layers and a permanent inspection
   ring. A fixed supplied outfit is now shown, while F3 toggles the review ring.
   This does not establish inventory-backed clothing or held weapons.

## What already exists but is NOT connected to this scene

PR #5's ZPlayerAnimationState validates generation/sequence/committed-event data,
samples explicit ticks and keeps death terminal. It admits idle, walk, attack,
grenade and death. ZLayeredPlayerPresenter is a bounded layered sprite consumer.
The architectural separation between gameplay consequences and appearance is
appropriate; replacing it wholesale with AnimationTree is not a prerequisite.
However, tick validation and sprite-frame tests alone are not production wiring.
The new inspector pose helper must not become a second production movement owner.

## Outstanding animation contracts

| Gap | Required next work |
| --- | --- |
| Authoritative actor binding | Connect resolved pose, speed, facing and committed action events to one root-owned presentation adapter. Bind actor ID and generation; detach on despawn/replacement. |
| Direction coverage | Current art is source-facing plus horizontal mirror, not eight authored facing directions or independently aimed upper body. Explicitly decide minimum north/south/diagonal/strafe coverage. |
| Weapon/equipment layers | Verified hand/grip/muzzle anchors, held AKM/machete silhouettes, per-pose layer ordering and inventory-backed outfit selection. Fixed review costume is not this. |
| Combat state coverage | Firing/recoil, reload and cancel, equip/holster, genuine hit reaction and death ordering. The existing knife attack must not stand in for all weapon attacks; grenade animation does not implement throwing gameplay. |
| Movement actions | Decide sprint, crouch and backward/strafe poses; native movement intent does not imply an authored animation exists. |
| Feedback and audio | Foot-contact markers plus surface-aware footsteps; shot/impact/reload cues from confirmed events with replay/deduplication rules. Wind/steam never create gameplay noise. |
| Authoring workflow | Keep frame rectangles, pivots, FPS/distance cadence and sockets editable as explicit resources. Review full source/mirror contact sheets, not only the idle frame. |
| Integration QA | Pause/resume, rapid reversal, moving-to-blocked, simultaneous hit/reload/death, equipment switch, screen re-entry and stale callback tests in the supported full host. |

## Visual boundary

Implemented: four shadowed task lamps, reduced floor contrast, short contact
shadows, paint/loading tracks, paper and broken-cargo debris, damp patch, authored
pipe/dispatch sign, anchored existing vegetation, six steam puffs, 24 dust motes,
three paper specks, localized ripple and loose cable. No floorplan or cover move.
This is a modest freight slice, not final lighting for all nine districts.

Not implemented: full tree canopy set, material-specific combat VFX, weapon
flashlight, dynamic weather, spatial audio, persistent world damage or story
mission triggers. Layout and story staging remain editable; ambiguous remnants
are environmental suggestions, not a prescribed quest.
