# Task 3.4 — Sawmill Yard composition

Accepted after independent Astra review and clean 1080-only integration; Task
3.4 is checked. Human approval remains false. This is level
composition/readability evidence, not a playable raid or acceptance of
movement, AI, loot materialization, tasks, extraction countdown, final art or
human route-finding.

The implementation candidate `93f7f874eeaa5d8c3c5d243e02f537cfd8e13d87`
was merged over the exact 1080-only baseline by integration commit
`27b057f06fcc9fa4c4aba521867f41ccd82ca6de`, then merged into main as
`50c3af7741b7d3e14d0e0c9c2cc04dde4d4f7e84`.
The accepted TileSet/atlas, UI, project settings, add-ons, authority code and
truth specs remain unchanged.

## Result

The reusable scene composes the accepted project-owned 32 px TileSet from an
inspectable authored Resource. West Service, Log Racks, Saw House, Settling
Dock and Road Gate form a west-to-east sequence with a direct Haul Lane and
longer South Bypass. Four three-cell corridors retain 96 px of clearance.
Nine stable anchors include three objective crates, a service cache, corpse,
extract and two future encounter staging points.

The final world has 800 ground cells, 35 detail cells, 231 occluding structure
cells and seven visible marker proxies. All 548 unblocked cells connect to
spawn; 252 unique blocking cells have no overlapping solid layers. The entire
Road Gate zone and every anchor/approach are reachable. Native collision and
occluder vertices stay inside bounds. The 1280×640 bounds are world-coordinate
data, never an output size. `game/world/sawmill/README.md` lists the anchors,
positions, layer responsibilities and later-task handoff.

## Visual inspection

The [exact-1920 contact sheet](1920x1080_contact_sheet.png) is a labeled
composition montage. Inspect the originals for exact 3× pixel fidelity:

| Original frame | Finding |
| --- | --- |
| [Log Racks](1920x1080_northwest.png) | Parallel timber bars on sand frame the first supply proxy; the central aisle opens onto the haul road. |
| [Saw House](1920x1080_north.png) | A roofless U and stone floor distinguish the second landmark; the broad south opening remains legible. |
| [Road Gate north](1920x1080_northeast.png) | Fence wings frame the road throat and yellow extract proxy; cover stays outside the lane. |
| [West Service](1920x1080_southwest.png) | Stone arrival, immediate cover and cache show the choice between the main road and bypass. |
| [Settling Dock](1920x1080_south.png) | The blue inlet, sawdust pad and timber rim distinguish the final supply area beside a clear return corridor. |
| [Road Gate return](1920x1080_southeast.png) | The bypass rejoins before extraction. Corpse and crate proxies stay off the travel lane. |

All six originals and the contact sheet were visually inspected. The first
review strengthened the dock with its adjacent blue inlet. A final geometry
pass closed two peripheral ground pockets and removed redundant water
collision under the timber rim. Static landmark/route readability is visible;
moving actors, live combat, final canopy/lighting and unaided human navigation
remain later gates. Atlas marker glyphs are explicitly abstract greybox proxies.

Capture annotations follow `DESIGN.md` fonts/palette on an independent crisp
canvas. They are test-only labels, not HUD/task state. The frontend skill's
existing-design guidance informed that preservation and native visual review;
browser/React/Lighthouse instructions do not apply to this Godot scene.

## Exact native GPU target

Every Godot command includes `--resolution 1920x1080`. The driver validates
the exact flag before launch; the script rejects nonexact/ambiguous overrides
visible in either Godot argument source. Consumed engine flags are removed by
Godot, so the driver and in-engine dimension checks are complementary.

Evidence comes exclusively from a dedicated native GPU **1920×1080 output
SubViewport**. The accepted **640×360 world SubViewport** is drawn inside it
at exact nearest **3×**; text stays at output resolution. Immediately before
each write the harness checks output target/visible rectangle, world target,
presentation rectangle and final Image dimensions. A mismatch returns before
image path creation/write. Whole-image comparisons prove exact nearest 3×
world pixels. Further checks prove camera/chrome independence, subpixel hold
and a three-output-pixel pan. No world-size image is saved.

macOS clamps this host's physical preview window to 1859×1050. That is host
behavior, not another supported/tested output. The final harness never reads,
resizes or saves that physical framebuffer. Only the dedicated exact-1920 GPU
target provides evidence. The contact sheet is composed directly in the same
exact target from the six original exact-1920 PNGs; no other-size intermediate
artifact is created.

Early authoring attempts rejected unconfigured/clamped root metadata before
saving. An invalid SubViewport property was repaired and an idle draw wait was
replaced by explicit native GPU drawing. They are not acceptance evidence;
all used the exact resolution flag. The final gate has no waived diagnostics.

## Independent and integration acceptance

The independent Astra reviewer reported zero P0/P1/P2 findings and kept human
approval false. It regenerated all seven exact 1920×1080 images byte-for-byte,
proved finite occupancy/reachability with `8130/0` checks, and passed larger
collision/approach sweeps with `10616/0` checks. The clean integration reran 20
gates: layout `8006/0` twice, TileSet `1319/0`, registry `1447/0`, native
capture `74/0` twice, exact display scope, strict spec, import/parses, hashes,
and diff checks. Both native runs reproduced all seven PNGs byte-for-byte.

## Verification

Run `python3 tests/tooling/run_sawmill_layout_gate.py` from the worktree root.

| Gate | Result |
| --- | --- |
| Editor import | exit 0; no engine diagnostics |
| Layout contract, two isolated runs | `8006/0` each |
| Accepted TileSet contract | `1319/0` |
| Asset registry | `1447/0` |
| Native capture/contact sheet | `74/0`; seven exact 1920×1080 PNGs |
| Static display scope | 7 tests, 0 failures; no screens executed |
| Strict spec validation | Valid |
| Diff | clean |
| Launch guard negative controls | 5 rejected without launching |

The registry's 64 content/provenance warnings are retained metadata, not engine
warnings introduced here. The final logs pass the strict engine ERROR/WARNING,
script error, assertion, resource-in-use and ObjectDB/RID leak scan.

The level contract reads actual native TileData, checks boundary cells and
polygon bounds, computes bounded four-neighbor reachability, validates entire
corridor footprints, and checks stable IDs/content profiles. Mutation probes
reject sealed spawn, blocked road, missing fence, duplicate ID and out-of-bounds
crate. Recomposition, separate instances and child reordering preserve IDs and
poses. This does not complete Tasks 3.6 or 3.9–3.12.

`verification.json` records every final command and each image's dimensions
and SHA-256. `captures.json` records camera poses, native renderer, pixel-match
results and the host-window distinction. `frozen_sources.sha256` seals source
and dependencies; `packet.sha256` seals this report, logs, manifests and images.

Every viewport command used in authoring is one of these exact-size forms;
the gate records fully expanded `<worktree>` paths for final executions:

```text
/Volumes/Data/sdk/godot/editors/4.7.2/Godot.app/Contents/MacOS/Godot --headless --path . --resolution 1920x1080 --editor --import --quit
/Volumes/Data/sdk/godot/editors/4.7.2/Godot.app/Contents/MacOS/Godot --headless --path . --resolution 1920x1080 --audio-driver Dummy --script res://tests/raid/sawmill_layout_contract.gd
/Volumes/Data/sdk/godot/editors/4.7.2/Godot.app/Contents/MacOS/Godot --path . --resolution 1920x1080 --borderless --position 0,0 --audio-driver Dummy --script res://tests/visual/sawmill_yard/capture.gd
/Volumes/Data/sdk/godot/editors/4.7.2/Godot.app/Contents/MacOS/Godot --path <worktree> --resolution 1920x1080 --audio-driver Dummy --headless --editor --import --quit
/Volumes/Data/sdk/godot/editors/4.7.2/Godot.app/Contents/MacOS/Godot --path <worktree> --resolution 1920x1080 --audio-driver Dummy --headless --script res://tests/raid/sawmill_layout_contract.gd
/Volumes/Data/sdk/godot/editors/4.7.2/Godot.app/Contents/MacOS/Godot --path <worktree> --resolution 1920x1080 --audio-driver Dummy --headless --script res://tests/raid/sawmill_tileset_contract.gd
/Volumes/Data/sdk/godot/editors/4.7.2/Godot.app/Contents/MacOS/Godot --path <worktree> --resolution 1920x1080 --audio-driver Dummy --headless --script res://tests/raid/asset_registry_contract.gd
/Volumes/Data/sdk/godot/editors/4.7.2/Godot.app/Contents/MacOS/Godot --path <worktree> --resolution 1920x1080 --audio-driver Dummy --borderless --position 0,0 --script res://tests/visual/sawmill_yard/capture.gd
```

No responsive, compact or historical alternative-output suite was run. Task
3.4 alone is accepted; no later task checkbox or human gate was closed.
