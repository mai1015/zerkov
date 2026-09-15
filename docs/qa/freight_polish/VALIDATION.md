# Freight polish: execution evidence

## Revision and scope

PR #10 is stacked on PR #8 (`feat/extraction-map-studies`), whose inspected
baseline is `e9720bbafed702aa372dfea971098fc839c21792`.
The normal implementation and two native comparison PNGs were retained in
`b7b3340cf4624d02db9a52a221952df514da2997` after native validation.
The temporary source-transfer pieces and their decoder are absent from that
tree. Commit `db7f6bf10f9438c102dc1d34e76815844f4007c3` replaces the one-time
publication job with read-only capture/regression CI. This report is docs-only.

First successful full-checkout execution:
https://github.com/mai1015/zerkov/actions/runs/35014850571
Job: `104535586925` / `native-freight`.
The run materialized the checksum-verified, locally tested source candidate
from `44e5d37fcf0f8f9328c3eaabcc4f6e0a9b7a2be1`, validated old file preimages,
ran the real new sources, then committed ordinary readable files. `capture.json`
records that input revision plus individual tested source hashes; it does not
claim that the temporary transport tree itself was the running game source.

## Observed results

- Freight source/animation-policy tests: 9 passed.
- Existing full-zone layout/source tests: 14 passed.
- Existing compact-map layout/source tests: 15 passed.
- Full-zone/freight native contract: 79 checks per process, two processes,
  158 repeated checks, zero failures, 14 screenshots per process.
- All 14 PNGs matched byte-for-byte across the repeated processes.
- Original compact-map native regression also completed successfully.
- Unexpected Godot diagnostics: 0. Two exact known Xvfb unsupported-V-Sync
  notices were reported by the two full-zone graphical runs, not discarded.

Engine: standard `4.7.2.stable.official.ed1daf0bf`.
Linux engine archive SHA-256:
`cadd3204e728a35d3f13adb7fd0d7902636b79f6b95c40c265eb73b6c35329e4`.
Physical output stays 1920x1080 and world raster stays 640x360 at nearest 3x.
The existing physical-window/viewport/texture/raw-image guard protects all PNG
writes. This runs the exact standalone environment view, not the six-add-on
production raid host. No add-on is substituted with a mock.

## What the native tests exercise

The inherited collision walkthrough still traverses all four proposed exit
paths and rejects a closed boundary. An actual held-W keyboard test places the
inspector against a wall and verifies that its animation resolves to idle.
Additional checks cover separate gait/idle phases, distance-based cadence,
malformed sample rejection, frozen-time reproducibility, camera/overview
suspension, G/H keyboard toggles, reduced-motion mode, shadow/light masks,
bounded effect counts, reversible dressing and unchanged authored map data.
The counts include repeated runs and are not a count of distinct scenarios.

## Native before/after pair

Both comparison captures use camera (1184,650), review actor (1132,718), the same
fixed outfit/pose and the same original geometry. Only the environment-polish
layer is toggled. The after view samples presentation time 3.0 seconds.
The before view is therefore an environment A/B, not an image of the old naked
review character. Neither image is resized or composited after Godot capture.

SHA-256:

- `northline-polish-before-1080.png`:
  `c5e23ec25fd8b2a075fc41707942fe8d5cee97909ea481a5363d816d7c677ffc`
- `northline-polish-after-1080.png`:
  `a8d7036f13ebec5c52d0fe25df6fe7e6eb8d89a662c11b03a449272f9ff39bd0`

The locally captured and CI-captured comparison hashes match. Both were visually
inspected at original dimensions. This is a restrained freight-area pass, not a
claim of completed lighting or storytelling for all nine districts.

## Native motion recording and standalone package

A separate local invocation of the same contract with `--motion-frames=144`
completed with 223 checks and zero failures (79 contract checks plus 144 guarded
frame writes). Each frame advances the real inspector through native collision,
samples its gait from resolved movement and sets the environment presentation
time. The 144 Godot frames were encoded without scaling as a 1920x1080, 24 FPS,
six-second H.264 demonstration. This is an inspection animation, not combat or
live raid gameplay. The known Xvfb V-Sync notice remains disclosed.

The standalone downloadable package was extracted into a new directory, imported
and launched with the pinned engine. Import exit 0; graphical launch exit 0;
no script errors or unexpected diagnostics. It contains no fonts, engine, .godot
cache, complete source pack or image-model output. The UI uses fallback fonts.

## Geometry and integration boundaries

The original `zone.json` remains SHA-256
`53a3960f6d4b8df6129b36c0feb3c7e08ce745bee44f563ba6d93799eac6cba1`.
The original environment atlas remains SHA-256
`d2b018bd1fe2bfed07554c7e13c1aa2bbb7bd2d569698cf471539dfdb963179c`.
No cover, collision, route, authority, game clock or production UI route changes.
The eight source outfit sheets have matching 64x64 geometry and preserved RGBA
pixels in a lossless atlas; the outfit is fixed review art, not inventory-backed.

PR #5's candidate layered-animation system remains separate. The outstanding
root-owned actor/action presentation adapter, aiming/directions, equipment
sockets, reload/cancel/hit/death integration and material-specific cues are
listed in `ANIMATION_AUDIT.md`. The new inspector pose helper is not a second
production movement authority. Cosmetic wind and steam never create gameplay
noise, damage, obstacles or loot.

The existing main source-policy checker still reports eight AI registration/
capture findings. The unchanged nonregression checker reports no new finding.
Passing this PR's workflow does not certify the full repository policy gate.
Human acceptance, supported full-host regressions and distribution provenance
remain open; no task-9 completion or release approval is inferred.
