# PR #3 follow-up: movement identity and navigation isolation

Base reviewed: `d2def16351d958f8f84bf4dbe2a9d5df7611a5dc`.
Branch: `feat/raid-world-player-mechanics-3.6-3.12`.
Engine executed: `4.7.2.stable.official.ed1daf0bf`, Linux x86_64.
Every executed display target was exactly 1920x1080.

## Changes

- `ZMovementWorld2D.digest()` now hashes bounded individual records in explicit
  order and streams their fixed-size hashes with a count/domain prefix. Collider
  and actor counts no longer consume one shared 256-node/64-entry encoding
  budget. Long correction contact lists are summarized the same way. The shared
  `ZCanonicalValue` limits are unchanged. Invalid authored IDs are rejected at
  admission; any remaining hashing failure emits an error instead of silently
  masquerading as a valid identity.
- `query_placement_px()` is a non-mutating static-geometry query shared by actor
  registration and navigation. It does not create probe actors or change even
  the movement world's `last_error`. Checked canonical conversion also rejects
  non-finite, overflowing and zero-after-quantization body shapes.
- Navigation uses a geometry-only source digest and rejects an empty source
  identity. Repeat bakes, failed bakes and bakes with existing actors leave the
  caller's world unchanged. Actor motion and sealing do not alter static grid
  identity; geometry remains inspectable after sealing.
- Blocking collider IDs now identify only the final limiting boundary on each
  axis, including ties. A nearer wall discards provisional farther-wall/bounds
  IDs. `ZMovementResult.digest()` also supports long tied-contact lists.

## Compatibility

World and result digest domains are now `movement-world-v2` and
`movement-result-v2`; navigation source identity uses `movement-geometry-v1`.
Raw inspection records remain available. Digest values deliberately differ
from the prior implementation; do not compare old pinned digest fixtures with
this version or feed unbounded raw world records to the generic encoder.
No add-on API, main scene, authored level or shared encoder budget is changed.

The new `movement_navigation_regression_cases.gd` is a RefCounted helper called
by the existing registered `movement_authority_contract.gd`. No new executable
or display entrypoint is added to the repository. Existing contract bodies are
unchanged; one call adds these regression cases to the normal gate.

## Executed verification

These are independent local results, not a claim to have rerun every PR gate.
The runtime is an isolated project containing the actual modified modules and
unmodified identity, conversion, canonical-encoding, RaidClock and
ZMovementWorldBuilder dependencies. Original source bytes were checked against
GitHub blob hashes. There are no production-class stubs in the final project.

| Suite | Runs | Checks per run | Failures | Diagnostics |
| --- | ---: | ---: | ---: | ---: |
| Original review reproductions | 2 | 20 | 0 | 0 |
| New regression helper | 2 | 329 | 0 | 0 |
| Twelve existing independent movement test functions, copied verbatim | 2 | 236 | 0 | 0 |
| Native rendered X11 keyboard/mouse diagnostic | 1 | 17 | 0 | 0 |

Regression coverage includes 512 colliders, mixed states with 128 actors,
reversed insertion order, 80 coincident contacts, identity admission limits,
read-only query/registration agreement, repeated and rejected navigation bakes,
legacy probe-like actor identities, geometry identity under motion/teardown,
and nearest/tied contacts in both directions on both axes.

Negative controls were run on separate temporary copies, never on the committed
source. Restoring flat whole-world hashing produced 32 failing assertions.
Restoring actor-registering navigation probes produced 8 failing assertions.
Both exited 1 with normal test result markers rather than parser/runtime errors.

## Interactive scope and observations

A real Godot X11 window was rendered through Mesa llvmpipe / OpenGL ES 3.2.
Keyboard and mouse events were sent through the operating system's XTest API,
not direct calls to movement methods or simulated Input.parse_input_event.

The diagnostic uses a synthetic two-obstacle map and the real movement world,
clock and navigation modules. Holding D stopped the actor at x=312 against a
wall beginning at x=320, accounting for its 8px half extent. D+S slid along the
wall; A moved away; releasing keys stopped motion. Mouse clicks distinguished
blocked and free placement without mutation. R rebaked after movement; B added
128 diagnostic actors; further R rebakes preserved all 129 actors and the grid
identity. X sealed the world and subsequent movement keys did not change its
state. Q exited cleanly. Three native framebuffer PNGs are exactly 1920x1080.

The initial GLX attempt passed behavior checks but emitted an unsupported
V-Sync warning. It was not counted as a clean run. Rerunning with the supported
`opengl3_es` rendering driver completed all 17 checks with zero diagnostics.
The separate evidence archive includes both the failed GLX diagnostic attempt
and the clean final run, JSON snapshots, test logs and runnable harnesses.

## Remaining verification before merge

The full project checkout/assets/native add-ons were unavailable to this test
runtime. The main game scene, complete RaidAuthority integration, original
Sawmill navigation/path gate and the full repository scope gate were NOT run.
This is not a human playtest, combat/camera/cursor acceptance or proof of full
raid playability. The interactive mouse check is placement querying, not the
production cursor-targeting adapter. These limits must not be relabeled as
successful full-game validation.

On a complete checkout, run the registered movement gate (now including the
new helper), navigation and Sawmill gates, repository exact-1080 scope tests,
and a normal main-scene smoke test before merging. For example:

```sh
export GODOT_BIN=/absolute/path/to/godot
python3 tests/tooling/run_movement_authority_headless_gate.py
python3 tests/tooling/run_navigation_path_headless_gate.py
python3 tests/tooling/run_sawmill_contract_headless_gate.py
python3 tests/tooling/test_ui_first_playable_scope.py
```

No claim is made that these full-checkout commands ran in this environment.
Human acceptance remains open. This change does not merge the PR into main.
