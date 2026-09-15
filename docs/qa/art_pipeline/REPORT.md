# Task 9 readiness and implementation evidence

Reviewed base: `9369baec8858fdb95145ee1381254426f7b5d9aa` (`main`).
Implementation commit: `775a6d18068136bd24c1c0d53d6cc4e5aa0e9c03`.
Pull request: https://github.com/mai1015/zerkov/pull/4

## Verdict

Ready to start the approved early art pipeline; **not ready to complete or
accept every task 9.* item**. This candidate implements bounded parts of 9.2
and 9.3 only. All completion checkboxes remain unchanged. See the companion
README for per-task remaining requirements and exact commands.

## Verification performed in this session

Environment: Python 3.13.5 on Linux. The execution container could not resolve
`github.com` for a clone and had no available Godot executable. Repository
inspection and publication used the connected GitHub API. Local tests use
explicitly synthetic temporary filesystem/image fixtures, not a reconstructed
full checkout and not substitute native add-ons.

- `python -m py_compile tools/art/asset_pipeline.py tests/tooling/test_asset_pipeline.py`: passed.
- Focused unittest suite: **54 tests, 0 failures, 0 errors per run**, run twice.
  These are 54 distinct tests, not 108 distinct scenarios.
- Three deliberately broken variants were detected: forbidden-path bypass
  (five failing subcases), ignored explicit frame order (one failure), and
  linear filtering substituted for pixel sprites (one failure). These negative
  controls are not counted as passing application runs.

The tests exercise exact grid/ordering rules, JSON integers and duplicates,
PNG header and SVG-size checks, import-setting mismatches, alias collisions,
pending assets, missing geometry, hash changes, path traversal and symlinks,
read-only compilation, repeatability, create-only publication, write failures,
scan failures, unchanged source bytes, and presentation-only generated scenes.

## Whole-checkout CI: verified passing

Both workflows for the implementation commit completed successfully:

- Branch push: https://github.com/mai1015/zerkov/actions/runs/34914701522
  (job `104209686041`, decoded log inspected).
- Pull request: https://github.com/mai1015/zerkov/actions/runs/34914722728
  (job `104209752249`, every step verified successful).

The real-checkout log records:

```text
Ran 54 tests
OK
ART_CHECKOUT_AUDIT textures=56 pending=12 non_texture_hashes=7 native=not_run
manifest_sha256=eb8af5c27a54ad563c4c77b4d811d2fdbedd727dceaeee83dce7d29b8aa7d799
ART_SAWMILL_COMPILE frames=16 files=33 repeats=2 identical=true native=not_run
```

The workflow checked all 63 registered runtime-file hashes, texture sidecars
for 56 PNG/SVG entries, and reported the 12 pending external sources without
pretending they were imported. It compiled the existing 16-cell Sawmill SVG
atlas twice in memory and compared the plans. The worktree checks found no
tracked or untracked changes. This is static/import-metadata evidence, not
Godot execution, full PNG decoding, effective existing-consumer filtering or
visual acceptance.

The runner emitted a checkout-action Node 20 deprecation notice and ran the
action on Node 24. No insecure-runtime override was enabled. The notice did
not fail the job; a completely warning-free CI environment is not claimed.

All five initial uploaded files were verified against their local Git blob
identities by reconstructing the tree, yielding the same root tree
`5c3a6b0850ab5a31230dd5aad460eee3883aedb8`. In particular:

- implementation blob: `dd957bb5b8ec8ff93ed62c7215612c9db802b178`
- test blob: `d1afa3f2e5faca4c728652f6267a1d2cf76fcc94`

This evidence update changes only this report; the tested implementation,
tests, workflow and README remain identical to that implementation commit.

## Not performed / not accepted

No full-project Godot import, existing native asset-registry contract, real
texture decode/resource-load, gameplay test, native capture, human visual/audio
approval, full regression suite, distribution-license clearance or completion
of tasks 9.2-9.11 is claimed. No historical smaller-resolution suite ran.
The implementation is submitted as a draft pending the remaining evidence.
