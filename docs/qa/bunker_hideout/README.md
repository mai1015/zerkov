# Bunker hideout native review

Open `game/presentation/bunker/bunker_hideout_view.tscn` in the pinned Godot
4.7.2 editor or navigate to the normal bunker route after integration. Click a
room or facility, and use the lighting-preview toggle. Services remain locked.

The supplied Bunker-Assets.zip provides the artwork. The atlas is lossless;
there is no image-generation step. Inspect kit/layout JSON for all placements,
source/archive hashes, original pixel regions, foot anchors and footprints.
The source manifest's two explicit footprint representations are normalized
to image-local x,y,width,height; walking-shape rectangles are not substituted.
User visual approval and licensing clearance are not inferred from upload.

Native reproduction:

```sh
python3 -m unittest discover -s tests/tooling -p test_bunker_hideout.py -v
python3 tests/tooling/run_bunker_hideout_gate.py --godot "$ZERKOV_GODOT" --output /tmp/bunker-review-new
```

The gate uses Xvfb/OpenGL on Linux, the actual production scene, existing fonts,
and the physical 1080 capture guard. It does not load or mock the six unrelated
native add-ons. Actual input dispatch selects facilities and map regions. Two
renderer runs must match byte-for-byte for both lighting presets. `capture.json`
records the tested source commit, engine, output, checks and native PNG hashes.

The dedicated workflow has write access only to retain reviewed output on the
named same-repository PR branch. It refuses a changed branch head, stages only
explicit integration/evidence paths, and never force-pushes or writes main.
Full six-add-on host regression and human visual acceptance remain separate.
