# Native freight migration: local execution and limits

## Candidate

Additive freight/inspection migration against main
`36e363625861e3fe3758c345181a66891facdabd`. Existing map/character source files
were checked against the repository lineage; the main changes since the available
source export do not alter the existing Northline/atlas/character dependencies.
No complete-repository local clone is claimed: direct GitHub clone DNS failed.
New native scenes and selected original art were executed in a standalone copy.

## Native runtime gate

Pinned standard engine: `4.7.2.stable.official.ed1daf0bf`.
Linux Godot ZIP SHA-256:
`cadd3204e728a35d3f13adb7fd0d7902636b79f6b95c40c265eb73b6c35329e4`.
Graphical execution: Xvfb 1920x1080, OpenGL Compatibility, Mesa llvmpipe.

Two native scene runs: 871 checks each, zero failures.
Separate edited-scene reopening process: 5 checks, zero failures.
Total: 1747 check executions (many are per-node/per-pixel-array assertions,
not 1747 distinct gameplay scenarios). Four screenshots match byte-for-byte
between both runs; all are raw 1920x1080 renderer readbacks. The guarded capture
occurs only after verifying physical window, viewport and image dimensions.

Checks establish:
- 12 saved TileMapLayers / 5520 authored cells and shared external TileSets.
- 11 complete original PNGs, 9474540 original bytes, matching archived hashes.
- Original decoded RGBA arrays equal native imported texture data; no palette
  loss, pre-resize, custom repack or mipmaps.
- 49 original prop positions, 15 reusable prop scene definitions and their
  footprints; 18 unchanged wall/fence collision rectangles with no duplicates.
- Source pixels/world positions/render resolution are separate: 48 source pixels
  span 16 original world units and 48 output pixels at the normal camera.
- Real camera/walk input, loading-door traversal and adjacent wall collision.
- A changed native tile and moved prop serialize/reload, then survive another
  process. Canonical scene/assets remain byte-unchanged during the gate.

Runtime logs contain only the disclosed unsupported-VSync notice per graphical
process; there are no SCRIPT ERROR, ERROR or parse failures. This is an isolated
native environment test, not a full six-addon game or desktop performance claim.

## Real editor interaction

A second isolated copy was opened in the actual Godot editor. Through mouse and
keyboard input, the test selected the FreightFloor TileMapLayer, picked a tile,
erased a neighbouring floor cell, changed prop 0052's Inspector position from
(1024,600) to (1031,597), and saved with Ctrl+S. No EditorPlugin was enabled for
this interaction. A fresh Godot process loaded the saved scene and reported:

`NATIVE_FREIGHT_RESULT checks=4 failures=0 mode=editor_reopen`

It verified 447 remaining floor cells (448 before the erasure), the moved prop,
and its attached collider. The canonical delivery scene is NOT this modified test
copy. The editor screenshot shows the actual scene tree, TileMapLayer inspector
and original-sheet palette, not a generated mockup.

**Editor diagnostic boundary:** graphical editor startup in this container logs
missing `VK_KHR_surface` / Vulkan initialization errors while its OpenGL 2D editor
continues to work. An earlier EditorPlugin-driven Save experiment additionally
logged a native list-erase error and stalled on programmatic selection; that
experiment is not accepted evidence. The later actual-input editor path did not
reproduce the list-erase diagnostic, but still has the Vulkan probe diagnostics.
An empty-project graphical editor launch reproduces the same two Vulkan startup
errors, establishing that they are an environment baseline rather than introduced
by this scene. The fresh-process readback is clean. Do not call this a zero-diagnostic graphical
editor acceptance or conceal the earlier failed attempts.

## Python and authoring checks

Ten source-installer/structure tests passed: exact byte copy/idempotence, missing
sources, source/archive drift, duplicate ZIP entry, source/output symlinks,
existing-file overwrite rejection, unsafe paths, and native-resource structure.
These synthetic installer fixtures are not the artwork used in native captures.

The migration tool is an optional create-only authoring artifact. Native runtime
loads the saved scene directly and never invokes it. Native wall faces are tiles,
while exact off-grid collision stays in attached native shape nodes. Painting an
extra wall-face tile alone does not create gameplay collision; editing geometry
requires editing the corresponding native wall segment.

## Publication and review gates

The complete standalone project includes all selected original sheets. The
repository PR contains native resources, metadata and a byte-copy installer;
its 11 full PNGs are not uploaded to the branch in this session. Existing source
archives or the supplied project must provision those paths before native CI.
The native runner reports BLOCKED before import if a source is absent/different.
A green source-only workflow is not evidence that CI rendered the original art.
This remains a draft pending that asset provisioning and clean editor/user review.

Only freight/inspection is migrated. The old whole Northline and Mercury scenes,
product F5, local-only saves, authorities, addons and release policy are untouched.
The new scene includes static dressing and four lights, not the earlier animated
wind/steam/dust system. Full-map replacement, multiplayer, gameplay map binding
and redistribution clearance are outside this task.
