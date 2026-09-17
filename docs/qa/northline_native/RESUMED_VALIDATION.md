# Resumed native freight verification

## Exact source and delivery

Verified source: `72d3a939d55d2a6d57133d697f1b9c5f0d684d3b` on PR #24.
This differs from the previous candidate `e60b69ebe4806e35bff13e31ba56f19b50b79892` only by replacing the temporary publication workflow with normal read-only verification. No scene, texture metadata, runtime script or test implementation changed during this resumed verification. This report is a subsequent documentation-only commit.

The connected GitHub workflow exported the exact tracked source at that revision. The downloaded archive SHA-256 was checked (`bb184ebbb40614e21ee3bc5181367773b0c6f088f973c89cf4573aa8bce82f39`), and each of its 2,136 selected file records was verified against its SHA-256 and Git blob ID. Direct clone still failed DNS in the container; this was an authenticated source-artifact reconstruction, not a claimed local full clone.

The existing byte-copy installer provisioned all 11 complete original PNGs from the user-supplied archives. Their 9,474,540 bytes match the committed source manifest. No crops were exported, no PNG was resampled, quantized or re-encoded, and no image model was used. The source sheets are referenced by native TileSet/AtlasTexture resources.

The downloadable `zerkov-northline-native-tilemap.zip` contains an immediately runnable standalone project with those exact original sheets, the actual saved resources and the required inspection character. No engine, native addon binary, font binary, cache or original whole source archive is included. Product F5 and the existing full Northline/Mercury scenes are unchanged in the repository.

## Fresh local runs

Engine: `4.7.2.stable.official.ed1daf0bf`.
Executable SHA-256: `8d106cbe6144c2dc7e881d61d2429c1a8a76e6b22ef48bd5e48dcf934953f71e`.
Engine ZIP SHA-256: `cadd3204e728a35d3f13adb7fd0d7902636b79f6b95c40c265eb73b6c35329e4`.
Environment: Linux, Xvfb at 1920x1080, Compatibility/OpenGL, Mesa llvmpipe.

- Original-source installer verification: 11/11 sheets match.
- Source-installer/resource tests: 10 tests, zero failures.
- First native scene run: 871 checks, zero failures.
- Second independent native scene run: 871 checks, zero failures.
- Third-process serialized-edit reopening: 5 checks, zero failures.
- Total native contract executions: 1,747, not 1,747 distinct gameplay cases.
- All four raw 1920x1080 screenshot files are byte-identical between the two runs and also match the earlier retained candidate captures.
- Separate clean extraction of the delivery ZIP: editor import exits 0 and normal main-scene startup exits 0, with no script/engine error diagnostics.

The contract covers saved TileMap cells, external shared TileSets, source/imported RGBA equality, 49 unchanged prop placements, 18 unchanged wall/fence solids, camera and character input, a traversable doorway, wall collision, and persistence of a changed native tile and a moved prop. Native rendering is 1920x1080; 640x360 denotes the conserved world-space camera footprint, not a small render surface. Source tile size 48, visual scale 1/3 and camera zoom 3 preserve both original image detail and existing logical geometry.

Native screenshot SHA-256:

| File | SHA-256 |
| --- | --- |
| northline-native-warehouse-1080.png | b166f0ea4660e678fc2ad9d8b278653aa1aadf1d90d0ecc5d71b73acdb61d5d7 |
| northline-native-entrance-1080.png | 1685dbeaeef7a2b1cb54ea3c6e7ff09fd292b4fc5ad26a8fa8803538743d8e1c |
| northline-native-inspection-1080.png | 5c246678385cded95134aa5ac6b36b8493727bf2fd2fa374b83162b65f419765 |
| northline-native-walkthrough-1080.png | 9170643a3a4bd9ef90fbd5b2fe1ec3673e1d92b10fe85b580916fe775c4deb71 |

The first outer tool invocation was terminated by its 120-second execution limit before it could complete the suite. It is not counted as a pass. The subsequent independently launched runner completed all three bounded engine processes; its complete logs and result JSON are in the delivered evidence packet. A local attempt to run the repository-path policy directly on a source-only extraction failed because that extraction is not a Git checkout; the actual full-checkout CI policy result below is the applicable evidence.

## Actual editor input, repeated during this resume

A separate disposable copy was opened in the graphical Godot editor. Through actual X11 mouse/keyboard events, with no EditorPlugin and no direct edits to the scene file:

1. Select the FreightFloor TileMapLayer and erase one cell using its painting tool.
2. Select reusable prop `northline_zone_prop_0052` in the scene tree.
3. Change its Inspector position from `(1024, 600)` to `(1031, 597)`.
4. Save using Ctrl+S.
5. Load that saved scene in a fresh headless Godot process.

The fresh process reports `NATIVE_FREIGHT_RESULT checks=4 failures=0 mode=editor_reopen`, verifying 447 floor cells instead of 448, the moved instance and its attached collision footprint. The canonical source and delivery scenes are unchanged; these edits exist only in the test copy. An actual editor screenshot shows the native scene tree, TileMapLayer Inspector and original-sheet palette.

The graphical editor still reports the two Vulkan-probe errors (`VK_KHR_surface` missing, initialization returns error). An empty-project control using the same executable, display and explicit OpenGL flags reproduces both. Runtime captures and fresh-process scene readback have no script/engine errors; the unsupported-VSync driver notice is retained. Clean graphical-editor startup and user visual acceptance therefore remain open. The earlier audio-device probe failure was avoided in the final editor run by explicitly selecting Dummy audio; no game audio feature was altered.

## GitHub CI and remaining gate

Read-only workflow: https://github.com/mai1015/zerkov/actions/runs/35168145441

- `source-contracts` job `105033771245`: passed installer/resource tests and the full exact-output policy in a real repository checkout.
- `native-scene` job `105033771039`: correctly failed source preflight with `NATIVE_SOURCES_BLOCKED`, before engine installation/import, because the 11 original PNGs are not in the GitHub checkout.
- No claim that GitHub rendered this source. Source-only CI success cannot replace the local original-art native evidence.
- The final workflow has contents-read permission, no persisted credentials, no source expansion, no commit/push operation and no transfer payload in the final tree.

The original sheets ARE in the runnable project delivered in the conversation. In a repository checkout, install from the existing archives before opening the new scene:

```sh
python3 tools/install_northline_native_sources.py --source-dir /path/to/uploaded-zips
python3 tools/install_northline_native_sources.py --verify
```

Or copy `assets/world/northline_native/sources/` from the provided project and run the verify command. No importer runs during normal scene startup. Repository/CI asset provisioning remains task N8, unchecked. PR #24 is draft and unmerged, not a green cold-full-repository acceptance.

Only the representative freight/inspection slice has been migrated. All-district replacement, live raid binding, porting the previous animated ambience, target-hardware performance, local-save changes and redistribution clearance are outside this change. Native wall-face tiles are visual-only where legacy geometry is off-grid: move/edit the associated wall-segment shape for collision; do not assume painting another face tile creates a gameplay obstruction.
