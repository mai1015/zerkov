# Task 9 readiness and implementation evidence

Reviewed base: `9369baec8858fdb95145ee1381254426f7b5d9aa` (`main`).

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

## Whole-checkout CI

The new read-only-permission GitHub Actions workflow runs the synthetic suite,
then audits the real checkout and compiles the existing 16-cell Sawmill SVG
atlas twice. It compares the compilation plans and checks that the worktree
has no tracked or untracked changes. This is static/import-metadata evidence,
not Godot execution. The CI result is not claimed in this initial packet;
consult the PR checks and any subsequent evidence update.

## Not performed / not accepted

No full-project Godot import, existing native asset-registry contract, real
texture decode/resource-load, gameplay test, native capture, human visual/audio
approval, full regression suite, distribution-license clearance or completion
of tasks 9.2-9.11 is claimed. No historical smaller-resolution suite ran.
The implementation is submitted as a draft pending the remaining evidence.
