# Task-9 validation evidence

## Verified revision and execution

Implementation: `ce918cacb0fd9ebf2215b4e2f78e2e9ff4904706`.
Integrated main baseline: `8039a0c19570e022cfc6ec855b77dd014da3e553`.
GitHub-tested PR merge: `24d52766fc1fd1f18d78d5b545375dbb1cb65f58`.

Successful workflow: https://github.com/mai1015/zerkov/actions/runs/34922168407
Job `104232504434`, `isolated-art-contract`, completed successfully.
Execution: September 15, 2026, 02:42 UTC (September 14, 22:42 America/Toronto).
The commit adding this report changes documentation only.

The workflow checked out the repository and ran the real standard Godot
`4.7.2.stable.official.ed1daf0bf` on Ubuntu 24.04. The downloaded Linux archive
passed SHA-256 verification against
`cadd3204e728a35d3f13adb7fd0d7902636b79f6b95c40c265eb73b6c35329e4`.
Every Godot invocation used `--resolution 1920x1080 --headless --audio-driver Dummy`.
The isolated project contains the actual new presentation modules, synthetic
negative-control textures, and 20 actual player source PNGs supplied by the user.
No native add-on was replaced with a stub. This is not the complete six-add-on
raid composition or a graphical/human acceptance run.

## Results actually observed

```text
Python: Ran 55 tests; OK
ART_REGISTRY_MERGE_RESULT before=75 after=98 failures=0
ART_SCOPE_DELTA_RESULT baseline_issues=8 current_issues=8 new_issues=0 full_policy_pass=False
```

The isolated editor import completed without Godot diagnostics. Each of two
independent process runs then reported:

```text
ART_MODULE_RESULT checks=3359 failures=0 digest=08911946192aee0e046bcd9f2e9a340979e1cc4dc7d5661d41376c70dc684d75
ART_REAL_PLAYER_RESULT checks=1555 failures=0 sources=20 poses=66
```

Combined native gate:

```text
ART_NATIVE_GATE runs=2 checks=9828 failures=0 diagnostics=0 digest=08911946192aee0e046bcd9f2e9a340979e1cc4dc7d5661d41376c70dc684d75 scope=isolated-real-player-and-synthetic
```

The 9,828 count includes both repeated suites; it is not 9,828 distinct cases.
The real-art contract covers 33 authored frames in source-facing and mirrored
form (66 samples), four ordered layers, exact regions and pivots, nearest
filtering, original hashes/native dimensions, no mipmaps, terminal death and
texture-reference cleanup. Replay, malformed/stale inputs, bounded pooling,
replacement and release are covered by the module contract.

The workflow emitted a checkout-action Node 20 deprecation notice. This is
separate from the zero Godot runtime diagnostics above.

## Actual supplied archive and deterministic compilation

Archive: `zerkov.zip`.
SHA-256: `ae2296dd78ba7310a512a2d3a9a575884dadefaf54eac8f9b3d535b31551b006`.
Compiler SHA-256: `3964907d1fa6e6e6dbfd7ee9ded030818535e9063fd1742ceeade2c52a903a49`.

The actual archive was read in the working container using the checked-in
compiler and explicit recipe: 28 selected PNGs, 619,029 original bytes,
165 authored regions, 224 output files. Two create-only builds matched for all
224 file hashes. A further rebuild with the final compiler was compared
byte-for-byte against both outputs and matched. The build receipt seals the
other 223 outputs. This packet excludes a merged production asset registry;
registry additions are an explicit integration candidate.

Twenty verified player PNGs are committed in PR #5. The complete 28-source
compiled overlay is supplied separately as a development artifact, not silently
installed into production. No entire source ZIP, forbidden directory, font
binary or Godot executable is added to the repository or overlay.

The source-art contact sheet is a labeled 1920x1080 source composition, not a
Godot screenshot, gameplay capture, or visual approval.

## Failures caught and repaired

- Registry promotion dropped accepted atlas metadata. Promotion now preserves
  the existing record, including custom authoring and license fields, and only
  changes materialization fields plus the merged alias set.
- Applying output size in `_initialize` was overwritten by engine startup.
  The driver now sets and checks the approved output at deferred entry before
  constructing any presentation objects.
- Malformed Variant inputs caused three runtime diagnostics despite zero
  assertion failures and exit zero. The driver rejected that run. Type checks
  now precede cross-type comparisons; the final runs contain no such errors.
- The initial launcher location was not independently discoverable by the
  existing policy. It was moved to `tests/tooling/run_art_module_headless_gate.py`
  and registered with its exact hash, without weakening the checker.

## Existing source-policy findings remain open

The unchanged checker reports the same eight findings on exact main baseline
and the art branch: seven unclassified AI GDScript entrypoints and one
unreviewed AI PNG writer. `check_art_scope_delta.py` verifies the checker,
its tests, existing policy semantics and affected AI files have not been
modified to hide those findings. It fails on any additional finding.

A green art/nonregression workflow does NOT imply that the full repository
source-policy gate passes. `full_policy_pass=False` is intentional disclosure,
not a successful skip or a task-12 acceptance claim.

## Task status and non-claims

Task checkboxes remain unchanged. The tested work supplies early 9.2/9.3
pipeline components and 9.4/9.5 layered-animation components. Integrated import
and filtering consumers, full overlay/production-registry integration,
root-owned gameplay projection/lifecycle binding, genuine hit-reaction artwork,
held-AKM/machete alignment and native visual approval remain required.

Tasks 9.6-9.11, full-game regression, encounters, VFX/audio/lighting, human
playtests and release approval are not completed by these results. Existing
license/distribution blockers remain unchanged.

## Reproduce

```sh
python3 -m pip install 'Pillow==12.3.0'
python3 -m unittest discover -s tests/tooling -p 'test_art_*.py' -v
python3 tests/tooling/run_art_module_headless_gate.py --godot "$ZERKOV_GODOT"
python3 tools/check_art_scope_delta.py
python3 tools/zerkov_art_pipeline.py --archive /path/to/zerkov.zip
python3 tools/zerkov_art_pipeline.py --archive /path/to/zerkov.zip \
  --registry game/content/asset_registry.json --output ../zerkov-art-overlay
```
