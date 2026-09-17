# Offline journey verification

## Implementation and scope

The pass retains the bunker environment and original Inventory/Health/Stats,
Workshop, Facilities and Session controllers. Shared styling and three small
scene resources frame the operation. LocalGame alone owns the transient return
destination and reads native equipped-slot data; the presenter receives frozen
values. Existing inventory projections do not yet expose those native slots,
so their absence is not treated as an unequipped character. The supplement is
matched to the current inventory ID/revision before display.

Briefing-origin Inventory -> Health -> Stats -> Back returns to the briefing.
A bunker-origin visit still returns home. Missing or stale data is unavailable;
an actually empty kit is empty. No new unarmed-deployment restriction is added.
The deployment screen receives one actual rendered frame before synchronous
raid construction, without a fake timer or progress percentage. Results use
committed retained/lost quantities; file generation remains checked at the
receipt/persistence boundary rather than displayed as a player reward.

## Local native results

Locked standard Godot: `4.7.2.stable.official.ed1daf0bf`, Linux x86-64.
New namespaces and real file operations; production root; actual keyboard/mouse
input; real native addon libraries, no GDScript substitutes.

| Run | Checks / failures |
| --- | --- |
| Journey New, including actual deployment and abandoned-raid debrief | 113 / 0 |
| Independent Continue after that committed loss | 78 / 0 |
| Graphical journey New, including loading-frame capture | 125 / 0 |
| Graphical independent Continue | 84 / 0 |
| Existing full campaign cycle | 4241 / 0 |
| Separate-process full-cycle saved-envelope verification | 3 / 0, twice |
| Existing bunker input path | 171 / 0 |

Journey New and Continue agree on final saved fingerprint
`f666ab617e5d253d579170dc84ee2b2ce4dd70df892472648e7094e43735c87f`.
The initial profile changes only through the deliberately executed raid result;
read-only preparation navigation separately preserves its initial fingerprint.
The full cycle covers real search/loot/extraction, an injected settlement-write
failure and real retry, abandonment, death, recovered home and redeployment.

`pytest -q tests/tooling`: 225 passed, 108 subtests. The exact-1080 gate and its
23 tests pass; the bunker runner includes 14 controls. Python compilation and
whitespace checks pass. The workflow now runs `--suite journey` rather than the
initial scaffold's nonexistent runner. Final-head macOS results belong to the
PR Actions checks; local results are not a substitute for that independent run.

## Graphical evidence

Sixteen raw PNGs were captured in a running Linux Godot application on an Xvfb
1920x1080 display with Mesa software rendering: ten New-game frames and six
Continue frames. Every accepted write uses the unchanged physical window,
viewport, texture and image-size guard. Static screens explicitly request a
real redraw before readback; no image resizing, reconstruction or fixture UI
is involved. The loading capture occurs before the actual authority startup.

Inspected frames cover bunker, briefing, existing loadout/health, the return to
briefing, loading, lean HUD, actual abandoned-raid debrief and return home.
An earlier graphical attempt waited indefinitely for an unrequested static
redraw; it failed and is not counted as successful evidence.

## Qualification limits

Linux libraries were hash-verified from the existing native Linux artifact for
`a609daff28673451668026e0b992c37f52923440`, staged only into an outside test copy.
That copy uses explicit extension startup registration for the separately
tracked pinned-engine cold-discovery defect. No shipped addon, engine lock,
source checkout cache or save schema was altered. The macOS workflow uses the
normal isolated-copy importer and installed macOS libraries.

This is native UX/functionality evidence, not exported Windows/Linux package
qualification, a cold-discovery fix, a 60/120 FPS measurement, or physical
controller/human playtest acceptance. Existing unfinished equipment controls
and crafting/building/online mechanics are not implemented by this UX pass.

## Reproduction on a supported native host

```sh
python3 tests/tooling/test_bunker_flow_runner.py
python3 tests/tooling/test_ui_first_playable_scope.py
python3 tools/check_first_playable_1080.py
python3 tools/run_bunker_flow_contracts.py --suite journey \
  --godot "$ZERKOV_GODOT" --output /tmp/zerkov-journey-new
python3 tools/run_bunker_flow_contracts.py --suite journey --graphical \
  --godot "$ZERKOV_GODOT" --output /tmp/zerkov-journey-visual-new
```

Output directories must be new. The graphical command requires a host whose
actual window can satisfy the physical 1920x1080 guard. A smaller hosted display
is not accepted just because its logical viewport is 1920x1080.
