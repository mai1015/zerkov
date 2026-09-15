# Native bunker hideout validation

Tested source: `bf6664056c68b2c34999ccd307297013379f046b`.
Evidence commit: `30d4276de287a9ce4444656076ce0e6eefc5a93b`.
Main baseline: `8039a0c19570e022cfc6ec855b77dd014da3e553`.
Successful workflow: https://github.com/mai1015/zerkov/actions/runs/34925787750
Artifact: `bunker-native-1080`, ID `10379108356`.

## Actually executed

- Nine Python source/layout tests passed in the working container and CI.
- Standard Godot `4.7.2.stable.official.ed1daf0bf` was downloaded by the workflow
  and its archive SHA-256 verified against the repository's pinned release.
- The isolated editor import passed.
- The actual production bunker view rendered with OpenGL Compatibility,
  llvmpipe and Xvfb. Two separate native processes each passed 34 assertions:
  `BUNKER_NATIVE_RESULT checks=34 failures=0 output=1920x1080 world=640x360 scale=3 rooms=6 props=20 captures=2`.
- Both standard and emergency PNGs matched byte-for-byte between the two runs.
- Physical window, root viewport, texture and raw screenshot were checked by
  the existing exact-1080 capture guard. No smaller display suite was run.
- Native mouse events selected facilities and map rooms and toggled lighting.
  The world changed while the sampled interface background remained stable.

Total: 68 native assertions across two runs, zero assertion failures, zero
unexpected diagnostics. Each graphical run emitted the known Xvfb V-Sync
unsupported notice (two total), retained in logs and counted in capture.json.
It is the only exact, narrowly classified warning. Other warnings, script
errors and process errors fail the gate. This is not a performance benchmark.

The first run was rejected because it also emitted a Control anchor/size
warning; the root scene now uses fixed exact-canvas offsets rather than
conflicting opposite anchors. The known V-Sync notice is not claimed absent.

## Native screenshots

These are raw Godot viewport captures, not constructed screenshot mockups.
The downloaded workflow artifact was unpacked and both images were visually
inspected at their original 1920x1080 dimensions. Room separation, original
sprite placement, workstation silhouettes, inspector text and the contrasting
lighting treatments are visible. Human/product approval is still pending.

| Capture | SHA-256 |
| --- | --- |
| `bunker-standard-1080.png` | `b2adf3485588d6e7e53b04a37a3b30adc6d5c1f44ff48dfef4ecce39a9b0521e` |
| `bunker-emergency-1080.png` | `15928ed86ea98ad8db8ccee3e7a5b0328a00f73efc73f1b9f1dbb49fd4a132de` |

The artifact ZIP SHA-256 is
`dfef8f13c73b9da1236f53e67f2f4f41269320e405753d67a9c734c5ea7d851e`.
The files retrieved into the working container matched these hashes exactly.
No resizing, painting or image-generation step was applied to the screenshots.

## Integration and boundaries

The normal `ui/screens/bunker/bunker.tscn` now references the presentation
wrapper. The original CommonActivatableScreen-derived controller and menu
owner remain inherited; its old visual children are hidden and replaced by
the new view. Other bunker-family routes, native add-ons, raid authority,
project.godot and source-policy checker implementation are unchanged.

The tested view is the production view, but it was run without the unrelated
six native add-ons. Full host/lifecycle regression and user visual acceptance
remain separate gates; this report does not claim them. The inherited route
binding is source-checked, not a full native host run.

Only room inspection and cosmetic lighting are interactive here. Crafting,
building, upgrades, power, resource balances, navigation and persistence are
not implemented or implied. Existing distribution/license blockers remain.
The existing main repository's broader source-policy issues are not certified
fixed by this visual PR; the bunker entrypoint and capture writer are registered.

The atlas is an 8,372-byte lossless packing of 72 supplied source sprites,
with original pixel coordinates, anchors and normalized footprint metadata.
Temporary upload transport pieces were removed from the branch's final tree.
No font binaries, engine executables or full user source ZIP are added.

## Reproduce

```sh
python3 -m unittest discover -s tests/tooling -p test_bunker_hideout.py -v
python3 tests/tooling/run_bunker_hideout_gate.py --godot "$ZERKOV_GODOT" --output /tmp/bunker-review-new
```

Edit `game/presentation/bunker/bunker_layout.json` for room and prop placements,
and open `bunker_hideout_view.tscn` for the isolated presentation. The workflow
retains native PNGs in this directory and as a downloadable Actions artifact.
