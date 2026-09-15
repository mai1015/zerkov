# Review-walker facing correction

The user correctly identified backward-looking motion in the six-second freight
recording from PR #10. This was an implementation bug, not deliberate backpedal.

The supplied gas-mask/hoodie idle and walk artwork is authored facing LEFT.
`face_left` records desired world facing, but `show_frame()` used it directly as
`Sprite2D.flip_h`, silently assuming a right-facing source. Thus rightward motion
kept left-facing pixels and leftward motion mirrored them to face right.

The correction declares `SOURCE_FACES_LEFT = true` alongside the bound source
texture and uses `flip_h = face_left != SOURCE_FACES_LEFT` on every layer:

| Desired facing | Source | Horizontal flip |
| --- | --- | --- |
| Left | Left | false |
| Right | Left | true |

Frame order, gait cadence, key-to-motion mapping, collision and map layout are
unchanged. Stopping and vertical-only movement retain the logical horizontal
facing. There are still no authored north/south/strafe or independently aimed
upper-body poses in this inspector; this correction does not claim those.

## Regression evidence

The existing native freight contract now tests both desired facings, idle and
walk, and all six frames: 24 samples checking all four layers and unchanged
source region order. Two further checks ensure visual facing does not alter
physics or gait state. The test restores the original displayed pose afterwards.
The expected orientation is literal and based on source-art inspection; it is
not computed from the implementation constant being tested.

Executed locally with checksum-verified Godot 4.7.2.stable.official.ed1daf0bf:

- Unfixed walker with the new regression: 105 checks, 24 failures (all orientation samples).
- Corrected walker: two native processes, 105 checks each, zero failures.
- All 14 guarded 1920x1080 captures match byte-for-byte between the corrected runs.
- Nine freight Python tests pass. Existing native wall blocking, keyboard
  movement and four exit-route collision checks still execute in the same suite.

The earlier 79-check results and screenshots are historical evidence for their
recorded revision, not evidence that source orientation was correct. That missing
assertion was the gap in the previous animation audit. New CI artifacts are the
source of current-revision capture hashes. No prior screenshot is silently
relabelled as corrected, and no capture-policy rules are weakened.
