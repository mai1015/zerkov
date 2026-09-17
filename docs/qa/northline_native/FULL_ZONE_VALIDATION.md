# Full native Northline continuation

## Result

The user approved continuing the original-sheet/native-TileMap fix beyond the
first freight slice. All nine Northline districts and nineteen interiors now
have a complete saved native counterpart. The old scenes and product entrypoint
are not replaced. This is an environment/editor review, not a completed raid.

Published resource revision: `25b7816b6dfb257aa7c4ecafcc00a9efabe874d8`.
Base freight revision: `8f8287adcb8d726a8ec1c3f41b09d0435d6d9741`.
Main baseline: `36e363625861e3fe3758c345181a66891facdabd`.
The subsequent documentation/read-only-workflow commit does not change the native
world, view, texture metadata or tests executed below.

## Authored implementation

- 75 native TileMapLayers; 53,384 saved cells.
- Nine district markers and nineteen authored building interiors.
- All 541 original prop placements; 528 retain solid native footprints.
- Fifty reusable prop definitions: the original fifteen are retained unchanged,
  with thirty-five added for the other districts.
- All 153 wall/fence/boundary collision rectangles match the previous layout.
- 1,814 source-art ground details, saved native nodes rather than runtime draws.
- Four exit markers, four spawn markers and the retained three route annotations.
- Wall-face tile layers and their native collider share a wall-segment parent.
  Moving the segment carries both; painting another face tile alone is cosmetic.

The complete world `.tscn` contains no script. The separate view owns camera,
inspection walker, overview UI and camera-local light enablement. It does not
read JSON or build terrain at runtime. The optional create-only migration refuses
an existing output directory and does not run from the scene. Native source
regions reference complete original sheets without rewriting them.

All eleven selected PNGs total 9,474,540 bytes and match the existing original
source manifest. Detail renders directly at 1920x1080. Original 48px terrain
cells map to 16 logical units at scale 1/3, then 48 output pixels at camera zoom 3.
The 640x360 logical footprint is unchanged, not a low-resolution render surface.
The overview camera covers the full map; it is not expected to show every source
pixel while zoomed out.

## Executed local native evidence

Engine: `4.7.2.stable.official.ed1daf0bf`.
Executable SHA-256:
`8d106cbe6144c2dc7e881d61d2429c1a8a76e6b22ef48bd5e48dcf934953f71e`.
Linux, Xvfb 1920x1080, Compatibility/OpenGL, Mesa llvmpipe.

| Check | Actual result |
| --- | --- |
| Source-installer and full-map resource tests | 20 passed |
| Exact-output policy unit suite | 23 passed |
| Source policy in the local tracked source reconstruction | Passed |
| Native full map run 1 | 3,096 checks / 0 failures |
| Native full map run 2 | 3,096 / 0 |
| Third-process saved tile/prop edit reopening | 4 / 0 |
| Raw native captures | Twelve files per run, all hashes identical across runs |
| Separate actual editor input/readback | 4 / 0 |
| Fresh extraction of delivered project | Editor import and normal launch exit 0 |

6,196 is the automated native check-execution total, not distinct gameplay
scenarios. Per-node, per-prop and repeated checks are included. The separate
editor readback is four additional checks. None is a human playtest or a
60/120-FPS target-hardware acceptance.

Tests compare every native prop transform/footprint and static collision rectangle
against the retained authoring fixture. They verify original decoded PNG pixels
equal imported texture pixels. Real Godot input opens a district, changes view,
enters walk mode and moves the character. Native `move_and_collide` follows four
recorded routes with bounded steps: west 6, rail 376, drainage 336, north treeline
363, all clear. A closed boundary rejects movement. These are collision tests,
not active extraction triggers or an input-driven gameplay raid.

The final screenshots cover full overview, each of nine districts, route
annotations and the walker. Actual native dimensions are checked before mounting
and before writing images. The final package includes the darker authored
backdrop, not the earlier default-gray-margin capture. Matching screenshots
establish repeatability on this renderer, not visual parity across platforms.

The automated edit test changes one tile, moves prop `northline.zone.prop.0052`,
saves through native ResourceSaver, then verifies that data in a separate process.
Canonical inputs remain byte-unchanged. Test output is isolated from all profiles.

## Actual graphical editor roundtrip

A separate disposable copy was opened in Godot's graphical editor. X11
mouse/keyboard input selected FreightFloor, erased one cell, selected reusable
prop 0052, changed its Inspector position from (1024,600) to (1031,597), and saved
with Ctrl+S. No plugin or direct scene-file edit performed those operations.

A fresh headless process loaded the editor-saved scene:

```text
ACTUAL_EDITOR_REOPEN_DATA floor_cells=447 prop=(1031.0, 597.0) collider=(1031.0, 594.0)
ACTUAL_EDITOR_REOPEN_RESULT checks=4 failures=0
```

The original floor had 448 cells. The delivered scene is the unchanged canonical
map, not this edited test copy. The editor screenshot shows a native TileMapLayer
and the original-sheet palette. The full text scene is about 2.1 MiB; Godot's
large-text-resource save notice is retained rather than concealed.

The editor still emits the two Vulkan-probe startup errors previously reproduced
by the empty-project control in this environment. The new runtime processes have
no script/engine errors, but emit the unsupported-VSync driver notice. The separate
editor readback also reports the engine's root-user warning. This is not a claim
of zero diagnostics or clean graphical-editor startup; user/editor-host acceptance
remains open.

## Source publication versus native rendering

Direct clone failed DNS; the starting source was reconstructed from the exact
connected repository artifact, with its records verified against SHA-256 and Git
blob IDs. Original PNGs were installed locally from the supplied archives.

The connector lacks mounted-file upload, and the saved full scene is a large text
resource. To publish it without transporting altered images, a temporary bounded
job serialized native metadata in a disposable dimensions-only cache. It compared
all forty newly authored resource files against the already original-art-tested
local SHA-256 values in `full_zone_resource_hashes.json`. Deterministic sequential
editor node IDs were applied only to newly created resources; no retained scene
was normalized or overwritten. Every resulting byte, not just geometry, matched.
No placeholder resource or PNG was saved. This was source serialization/transport,
not a rendering test or proof that original art was installed in CI.

Publication succeeded in workflow `35172529460`, then committed only the verified
resources, view backdrop and approved runner registrations to the same branch by
fast-forward. The temporary write-enabled workflow is deleted in the final tree.
The final full-map workflow is read-only, preserves no Git credentials, writes no
source and performs no commits or pushes.

An initial publication run timed out due to the wrong source-ID field in its
throwaway dimension cache; no resources were pushed. The next serialized the
correct bytes but exposed the old freight test's directory-wide fifteen-prop
assumption. That regression now checks the fifteen definitions referenced by the
retained freight scene, while the full-map test independently requires all fifty.
No resource/geometry/asset guard was relaxed. Both failed attempts remain historical
failures, not native successes. A first local flow attempt used an incorrect prop
ID and failed its assertion; the final tests use the actual stable ID. The final
capture writer uses the explicit existing physical guard required by source policy.

## Remaining asset and integration gate

The eleven complete original PNGs ARE in the runnable delivery but are not yet
uploaded to GitHub. Both native CI jobs must report missing-original-art BLOCKED
before importing/rendering. A source-contract pass is not native CI acceptance.
Use the existing byte-copy installer or copy the source directory from the delivery
and verify it. No source installer or metadata serializer runs during scene load.

The first freight reference, old Northline/Mercury, product startup, bunker/local
saves, raid authorities, addons and release provenance are unchanged. The native
map retains static lights/dressing; porting the prior animated ambience is separate.
No combat, AI, loot, extraction/settlement or multiplayer is wired by this change.
Original-asset CI provisioning, clean editor-host review, full-product integration
and user visual approval remain open. PR #24 remains draft and unmerged.

Delivery: `zerkov-northline-full-native.zip`, SHA-256
`32d6f49311cc1eb2f019a48a7a52d77888c32feeea38ea2c5cb663e862947eb6`.
Native evidence: twelve screenshots repeated, per-process logs/result JSON,
editor screenshot/readback, source/resource seals and cold-delivery smoke.
