# World render-scale spike — tasks 3.1–3.2

Selected recommendation: **fixed 640×360 world SubViewport, camera zoom 1,
nearest filtering, integer enlargement, centered letterboxing**. Keep the
existing UI on its independent 1920×1080 design canvas, rasterized at output
resolution. This is an isolated recommendation and evidence packet, not a
production renderer change or human approval.

Baseline: clean UI checkpoint `93f337e`. Native evidence: Godot
`4.7.2.stable.official.ed1daf0bf`, Compatibility, Apple M4 Pro, macOS.

The comparison table and PNG packet below are immutable historical evidence.
The retained `capture.gd` and `verify.py` entry points are inert and exit before
argument handling, renderer setup, imports, paths, or writes. There is no
current render-scale command. Current agents/tests MUST NOT regenerate this
packet until task 11.8 or a later approved display-support proposal.

## Comparison

[Resolution comparison sheet](comparison_sheet.png) shows all 12 combinations.
Its thumbnails are for composition only. Inspect the original linked frames
and [900p details at 1:1 pixels](900p_pixel_details.png) for actual pixel quality.

| Candidate | 1920×1080 | 1600×900 | 1280×720 | Finding |
| --- | --- | --- | --- | --- |
| 320×180, zoom 0.5, fit | [6×](1920x1080_320_fixed.png) | [5×](1600x900_320_fixed.png) | [4×](1280x720_320_fixed.png) | Same 640×360 world area, but downsampling drops source detail. All 64 alternating source columns collapse to one run. |
| 640×360, zoom 1, fractional fit | [3×](1920x1080_640_fractional.png) | [2.5×](1600x900_640_fractional.png) | [2×](1280x720_640_fractional.png) | Full window; 900p produces alternating 2px/3px source columns, violating uniform-pixel tolerance. |
| **640×360, zoom 1, integer fit** | [3×](1920x1080_640_integer.png) | [2× + margins](1600x900_640_integer.png) | [2×](1280x720_640_integer.png) | Preserves source detail, uniform pixels and constant world area. Recommended. |
| Adaptive integer surface, zoom 1 | [640×360 at 3×](1920x1080_adaptive_integer.png) | [800×450 at 2×](1600x900_adaptive_integer.png) | [640×360 at 2×](1280x720_adaptive_integer.png) | Uniform and full-window, but 900p reveals 25% more world on each axis (56.25% more area). Changes framing/visibility with window size. |

The approved handoff art's clean play region is `Rect2(3, 3, 640, 360)` inside
`assets/handoff/bg_raid_frame.png` (660×371). The fixture draws it at one source
pixel per world coordinate unit. It repeats the region only to supply diagnostic
overscan; repeated terrain in the adaptive candidate is a fixture seam, not an
art or level recommendation. The stripe, diagonal, one-pixel dot, 32px tile
ruler and 64px character-cell outline are calibration probes. The latter is
not an approved character size or sprite composition. No source art was added.

The frontend skill's existing-design branch informed preservation of the
authored HUD, project palette, typography and native screenshot verification.
No new design tokens or production UI components were introduced. Native Godot
verification follows `DESIGN.md`; web-specific tooling does not apply.

## Surface and camera policy

For physical output dimensions `(W, H)`, use `k = floor(min(W/640, H/360))`
and a centered `640k × 360k` world rectangle. Its origin is the integer floor of
half the remaining space. The tested layouts are:

| Output | World raster | Integer scale | World display rectangle (x, y, width, height) | Margins |
| --- | --- | --- | --- | --- |
| 1920×1080 | 640×360 | 3 | 0, 0, 1920, 1080 | None |
| 1600×900 | 640×360 | 2 | 160, 90, 1280, 720 | 160px left/right; 90px top/bottom |
| 1280×720 | 640×360 | 2 | 0, 0, 1280, 720 | None |

At 900p, the world occupies 80% of each output dimension and 64% of its area.
This visible framing cost is deliberate and must be part of the integrator's
visual review. The HUD continues to use the whole output canvas and its existing
safe-area anchors; it can occupy the black margins. Its text, crosshair and
health/ammo indicators do not pass through the world texture.

Use an unrotated orthographic Camera2D at zoom `(1,1)`. Presentation may derive
a desired follow pose from simulation snapshots, but round the final desired
pose, including any presentation impulse, to whole world-raster pixels once.
Keep Camera2D smoothing off after that rounding. Do not independently snap
camera components at multiple points in the chain. Enable viewport transform
pixel snapping; retain nearest filtering on sprites and the output TextureRect.
Do not apply fractional scale, camera rotation, bilinear filtering or world
effects to the UI canvas. The checked impulse is desired `(3.6,-2.2)`, rendered
as `(4,-2)` source pixels. This spike does not choose combat impulse timing.

Snap visual actor roots to the same grid at the final presentation step; keep
atlas regions, pivots, tiles and child offsets integral. Do not round simulation
positions, ranges, collision shapes, authoritative movement or `ZWorldUnits`.
The fixture verifies camera/static-world behavior; moving layered actor
animations remain task 9.4/9.5 evidence, not a claimed result here.

Pointer mapping first rejects any point outside the world display rectangle,
then subtracts its origin, divides by integer scale, subtracts half the surface,
and adds the **rendered** camera pose. The pure inverse is in
`surface_policy.gd`. UI hit testing stays in its normal independent canvas.
Actual gameplay aim/interaction wiring belongs to task 3.7.

For other desktop aspects, preserve 640×360 and center the integer-fit rectangle;
do not widen world visibility. Uneven spare pixels put the extra pixel on the
right/bottom. Only the three requested 16:9 layouts have new capture evidence.
The historical packet below the current 1920×1080 target retained the compact
UI contract, but that path is deferred and has no current capture gate. Current
agents/tests MUST NOT execute or regenerate any smaller world/compact
composition until task 11.8 or a later approved display-support proposal.
Below 640×360 the spike has no supported render policy.

## Measurable acceptance and failure limits

| Check | Failure threshold | Observed result |
| --- | --- | --- |
| Output framebuffer | Any width/height mismatch | All 12 frames have exact requested dimensions. |
| Source stripe retention | Anything other than 64 runs | Recommended candidate: 64 at every resolution. 320 candidate deliberately fails this fidelity criterion. |
| Physical source-pixel width | Any width other than integer `k` | Recommended: only 3px at 1080p; only 2px at 900p/720p. Fractional 900p deliberately yields 2px and 3px. |
| Camera quantization | More than 0.5 raster pixel error per axis | Maximum 0.5, over 33 deterministic fractional poses per candidate/resolution. |
| Subpixel pan stability | Any changed byte before the rounding boundary | Zero changed bytes between `(0,0)` and desired `(0.49,0.49)`, all three chosen layouts. |
| One-pixel camera movement | Any unequal byte in the translated interior crop | Desired x=0.51 renders x=1; entire checked crop shifts exactly `k` physical pixels, all three layouts. |
| HUD independence | Any changed UI-only pixel across candidates or impulse | Byte-identical HUD buffers across all candidates and chosen camera impulses at each resolution. |
| Pointer inverse | Error ≥0.0001 world pixel or accepting outside right/bottom boundary | Maximum 0.0 for the tested points/poses; outside endpoints rejected. |
| Runtime diagnostics | Any `ERROR:` or `SCRIPT ERROR`, even with exit 0 | None in final recorded runs. |

The negative controls are successful experiments: their observed detail loss
and nonuniform pixel widths are asserted, not silently treated as acceptable
production quality. Full-frame inspection found that 320 loses fine roofing,
fence and prop texture; fractional 900p alters narrow-stripe widths; fixed
integer scaling preserves those details while retaining the same view framing.
Adaptive integer scaling remains viable only if window-dependent field of view
is explicitly accepted later. No motion-comfort or human readability acceptance
is claimed from static captures.

## Historical verification artifacts

There is deliberately no runnable verification or sheet-generation command for
this packet. Direct invocation of either retained launcher exits with
`DEFERRED_DISPLAY_SUITE`; agents must not bypass that retirement guard. The
historical PNGs, logs, metrics, manifests, and contact sheets remain available
for provenance only and are not current acceptance evidence.

At the original checkpoint, the harness mounted the existing `ui/main.tscn`
HUD, hid only its instantiated background/atmosphere, froze fixture animation,
and rendered the UI independently from the low-resolution world. That old
virtual-framebuffer workaround is not an approved current capture method. Only
genuine renderer-backed 1920×1080 readback may be used for current visual work;
no smaller framebuffer may be resized or regenerated.

| Suite | Checks | Failures | Evidence |
| --- | --- | --- | --- |
| Native render-scale spike | 1292 | 0 | [capture.log](capture.log), [metrics.json](metrics.json) |
| Existing UI composition | 109 | 0 | [ui_composition.log](ui_composition.log) |
| Existing responsive layouts | 96 | 0 | [responsive.log](responsive.log) |
| Existing native border rendering | 135 | 0 | [border_render.log](border_render.log) |

At the original historical checkpoint, all four processes exited 0.
[verification.json](verification.json) records those retired commands and
results. [captures.sha256.json](captures.sha256.json) records all 26 PNG hashes:
12 comparison frames, 3 HUD-only frames, 6 pan frames, 3 impulse frames, 2
contact sheets. The chosen temporal evidence uses suffixes
`_640_integer_pan_000`, `_640_integer_pan_051`, and `_640_integer_impulse` at
each of the three resolutions.

Initial diagnostic attempts exposed a renamed UI token and the desktop window
clamp. Both were corrected before the final recorded run; the final captures
and metrics supersede the failed attempts. No errors were waived.

## Readiness and limits

Task 3.1 has implementation, the complete native resolution matrix, pixel
measurements and unchanged-UI regressions. Task 3.2 has a concrete selected
recommendation with camera, scale, letterbox, mapping and failure rules.
The primary integrator must independently inspect this packet before marking
the selection accepted, in accordance with `model-routing.md` (implementers do
not approve their own subjective gate). **Human approval is not recorded.**
The approved change says gameplay ranges, collision and UI layout may not assume
a candidate surface until the comparison is approved. This packet makes that
review possible and does not silently promote the policy into production.

No production `ui/**`, `addons/**`, `project.godot`, source art, or spec ledger
was edited. This is not a Sawmill layout, combat-feel test, player-animation
approval, performance benchmark, live input test, or Windows/Linux support
claim. Once the integrator accepts the selection, tasks 3.3 and 9.1–9.3 may
proceed with the corresponding source-pixel assumptions; production camera/input
integration still belongs to task 3.7.
