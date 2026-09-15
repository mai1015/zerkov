# Northline full-zone validation

## Delivered environment

The user's follow-up requested a full map rather than a compact study. Northline
now has one continuous 2688x1792 world, compared with the previous 672x448 study:
4x each axis, exactly 16x the area. Source art and the normal camera scale are
unchanged. There are nine districts, nineteen authored cutaway interiors,
541 prop placements plus fence runs, 1,814 decals, four entry anchors and four
proposed exit anchors. Three route annotations connect the different approaches.
The old Northline and Mercury studies remain unchanged and independently usable.

The default view is the complete map. Click a district or a point on the map to
inspect it; M switches overview/detail, Q/E cycles districts, Tab shows routes,
and P enables a collision-aware inspection character. WASD moves the character
or camera; Shift increases inspection speed. Overview pauses the walker.

The overview uses the SAME world at a 1/6 camera zoom. The outlined box is one
normal 640x360 camera footprint. Normal inspection and walkthrough use zoom 1.
The world raster remains 640x360 and the output remains native 1920x1080 at 3x
nearest enlargement. This is not a postprocessed mosaic, a flattened background,
or an image-model result. Fine-pixel aliasing in the overview is a consequence
of the explicit zoomed-out inspection mode, not the normal gameplay view.

## Executed verification

First successful full-zone workflow:
https://github.com/mai1015/zerkov/actions/runs/34958436403

Source candidate: `905c949b74c0c6cd761a3507691abc355d8b6ad5`.
Validated ordinary-source/evidence commit:
`20193fb23626517ee699d5b565520ee502a40f32`.
Underlying map-study revision:
`8046c19593501353c6584992136e99bf47d33215`.
Main integration baseline:
`8039a0c19570e022cfc6ec855b77dd014da3e553`.

Actual standard Godot `4.7.2.stable.official.ed1daf0bf` ran locally and on Ubuntu
CI using Xvfb / OpenGL Compatibility / llvmpipe. The Linux engine archive was
verified against SHA-256
`cadd3204e728a35d3f13adb7fd0d7902636b79f6b95c40c265eb73b6c35329e4`.

```text
New Python authored-layout contracts: 14 passed
Unchanged original map-study contracts: 15 passed
Native process 1: 38 checks, zero failures, 12 captures
Native process 2: 38 checks, zero failures, 12 captures
Combined native result: 76 checks, zero failures
All 12 PNGs identical between the two native processes
Unexpected Godot diagnostics: 0
Known Xvfb unsupported-V-Sync notices: 2
```

The topology review checks all nine districts, nineteen interiors, four entry
points and four proposed exits using an 8px grid and 6px clearance. A sealed
cross-map negative control is rejected. Native tests additionally use the
actual 5px-radius CharacterBody2D to traverse all four proposed exit paths,
verify a closed boundary blocks it, and test keyboard movement. These are not
only assertions against an offline graph. Mouse/key events also exercise the
GUI, map/sector selection and walkthrough controls. The existing physical
window/viewport/texture/raw-image guard protects every PNG write.

The twelve screenshots cover the full overview, every district, route overview,
and character walkthrough. Native logs and PNGs are in the
`northline-full-zone-native` workflow artifact. Two representative native PNGs
and `capture.json` are retained in this PR. Local and CI capture hashes match.
`capture.json` seals source and capture hashes; it does not assert human approval.
The 76 count includes repeated execution, not 76 independent scenarios.

The 22-file source candidate used a one-time checksum-verified transfer. The
large editable JSON was regenerated from the authored recipe and route review,
then checked against
`53a3960f6d4b8df6129b36c0feb3c7e08ce745bee44f563ba6d93799eac6cba1`.
After passing native validation, ordinary source files were committed and the
transfer helper/parts were removed. The final workflow is read-only and uploads
capture artifacts; it does not regenerate or commit authored layouts.

## Explicit boundaries

This is a full connected environment with a review walker, NOT a completed raid.
The walker is isolated from RaidAuthority and all domain capabilities. No live
AI, combat, loot, extraction trigger, settlement or persistence is implemented.
Exit markers and entry anchors are design data, not activation or spawn policy.
Production movement/vision integration, combat balance, host/lifecycle regression
and user visual acceptance remain open. Main, its normal UI routes, add-ons and
project settings are not replaced by this scene.

The existing broad source-policy checker retains the eight preexisting main AI
registration/capture findings. The updated comparison adds only the new native
entrypoint/runner registrations and corresponding inventory count, preserves
prior policy and the checker itself, and rejects new findings. Its passing
nonregression result is not a full repository-policy pass.

The environment reuses the two supplied packs and their recorded 48-to-16
nearest normalization. The inspection actor uses eight verified original player
sheets packed losslessly into a 384x512 PNG. Source hashes and provenance are
recorded. No font file, engine binary, complete asset archive or cache is shipped
with the standalone package or new source diff. Redistribution clearance and
human approval are not inferred from the user's development-asset upload.

## Reproduce

```sh
python3 -m unittest discover -s tests/tooling -p test_northline_zone.py -v
python3 -m unittest discover -s tests/tooling -p test_map_studies.py -v
python3 tools/review_northline_routes.py
python3 tools/check_map_study_scope.py
python3 tests/tooling/run_northline_zone_gate.py --godot "$ZERKOV_GODOT" --output /tmp/northline-review-new
```

In the repository, open
`game/presentation/northline_zone/northline_zone.tscn` and press F6.
The separate downloadable standalone project starts this scene with F5.
