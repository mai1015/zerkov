# Verified map-study delivery

Repository base: `8039a0c19570e022cfc6ec855b77dd014da3e553`.
Normal implementation/evidence tree committed as
`2d0e4745897d31504b95fc83f926e2b53b99312a` on `feat/extraction-map-studies`.
PR: https://github.com/mai1015/zerkov/pull/8

## Actual execution

The local standard Godot executable was obtained from the official release,
verified against the repository's pinned archive SHA-256, and executed with
OpenGL Compatibility, Mesa/llvmpipe and Xvfb. This is graphical rendering, not
headless image generation or a composed screenshot mockup.

The same source candidate also passed GitHub Actions run
https://github.com/mai1015/zerkov/actions/runs/34929497931
(job `104254557902`). That run checked out
`115ec2ceaf9d6cc5a2bc5dd96c3bfbe5eed91b67`, verified the exact source-transfer
archive, materialized the nineteen new implementation files, registered the
new entrypoints and ran the native scene. Only after all gates passed did it
retain normal source files and native PNGs in commit `2d0e474...`. The transfer
pieces and unpack script are absent from the final tree. Subsequent CI is
read-only and never commits to the branch.

```text
Python authored-source/layout contracts: 15 passed
Godot: 4.7.2.stable.official.ed1daf0bf
Native run 1: checks=29 failures=0 maps=2 captures=7
Native run 2: checks=29 failures=0 maps=2 captures=7
Combined: runs=2 checks=58 failures=0 captures=7 repeatable=true
Output: 1920x1080; world: 640x360; nearest scale: 3
```

The 58 checks include repeated execution, not 58 different cases. Both processes
produced byte-identical sets of seven PNGs. CI PNG hashes also match the local
captures. `capture.json` records the exact filenames, hashes and source hashes.
Two known unsupported-VSync notices are disclosed (one per graphical process);
there are no other Godot warnings or errors. All other diagnostics fail the gate.

The existing source-policy checker initially rejected the screenshot assertion
helper's name. The helper now uses the established `check(...)` convention,
without altering the immediate physical window/viewport/texture/raw-image guard
or weakening the checker. Local and CI native tests were rerun after this change.

## What the tests establish

Native tests dispatch real Godot mouse/key events for map selection, sector
selection and design-annotation toggles. They test exact viewport dimensions,
source-pixel camera zoom/clamps, actual sprite/collider construction, repeated
map replacement and guarded native PNG writing. The environment view is the
same scene that can be opened directly in Godot, not a separate capture mockup.

Python tests verify both packs are represented, the atlas/source-region records,
explicit geometry, placement identities, final cover footprints and reachable
proposed exits with a 3px review clearance on a 4px grid. Route guides do not
cross the authored collider set; sealing a dividing corridor is a negative
control that fails reachability. This is layout verification, not native AI
pathfinding integration or a gameplay balance result.

76 explicit source regions from eleven sheets are normalized with nearest
1/3 scaling (48px to 16px) and a shared non-dithered 256-colour palette. WebP
encoding is lossless after those declared transformations. Original PNG bytes
are not claimed preserved. The supplied source archive/sheet hashes and authored
crop/anchor records are in `assets/world/map_studies/atlas.json`.

## Scope limits

These are two original, camera-explorable environment studies. No player
controller, live combat, authoritative loot, AI encounter, extraction settlement
or production raid integration is implemented by this PR. Proposed exits and
loot pockets are visibly design annotations. Existing game routes, project
settings, add-on snapshots and authority modules are unchanged.

The pinned main baseline has eight pre-existing exact-output source-policy
findings: seven unregistered AI GDScript entrypoints and one unreviewed AI PNG
writer. The unchanged checker reports the same eight on this branch, with no
new findings. The nonregression check also verifies preservation of the checker,
prior classifications and AI sources. A green map workflow is not a claim that
the full repository source-policy gate passes.

Human visual approval and full six-add-on host regression remain open. Source
asset distribution/license blockers remain in force. No whole source archive,
font binary, engine executable or image-model output is included in the map PR.
