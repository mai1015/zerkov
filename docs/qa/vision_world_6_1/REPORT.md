# Task 6.1 authoritative Vision world evidence

Task 6.1 is complete at the implementation/evidence level on branch
`codex/vision-world-6-1`, based on `d947b40`. Human approval, encounter tuning,
and whole-game acceptance are not claimed.

## Outcome

The game now owns one sealed first-playable Common Vision configuration and a
scene-owned offline authority world. Startup checks the project lock, installed
debug/release native artifact hashes, upstream release-manifest hash, API,
protocol, algorithm contract, feature bits, coordinate scale, and the 60 Hz
raid clock before native state is created. A changed or duplicate record,
unsealed configuration, invalid world identity, incompatible runtime, or
provenance mismatch fails atomically.

The owner can register as the sole `RaidAuthority` `VISION` phase handler. It
accepts exact positive authority ticks only, evaluates at ticks `1, 4, 7, ...`,
and supplies exactly 16,384 work units on evaluation ticks and zero work on the
intervening ticks. Native observer publications remain atomic; deterministic
deferral is exposed through an immutable 64-record telemetry window and
saturating totals. No render delta, `_process()`, wall clock, scene transform,
or presentation callback can advance canonical perception.

The sealed configuration fingerprint is:

```text
9a1bf1980b873fd71bcc864dc9e4f5fc32325597ed49e419e14f9167c0122ed2
```

## Fixed configuration contract

| Boundary | Sealed value |
| --- | --- |
| Godot / canonical relation | 32 px = one tile = 1,000,000 Vision microunits |
| Spatial grid | four-tile cells; 256 visited cells maximum |
| Per-evaluation budget | 16,384 deterministic work units |
| Cadence | first tick 1; every 3 authority ticks; 20 Hz at RaidClock 60 Hz |
| Telemetry | 64 evaluation rows; counters saturate at 9,007,199,254,740,000 |
| Scav sight | 18 tiles; 120-degree total cone; 180 memory ticks; urgent priority 200 |
| Mutant sight | 12 tiles; 160-degree total cone; 120 memory ticks; priority 100 |
| Target samples | `ANY_SAMPLE`; center and vertical +/- quarter-tile; three of native max eight |
| Target masks | player bit 0; Scav bit 1; mutant bit 2 |
| Occluder masks | structure bit 0; vegetation bit 1 |

The 16,384 budget admits a conservative workload of 42 matching three-sample
targets against 128 segments (`42 + 42 * 3 * 128 = 16,170`). The contract test
proves that 43 targets request 16,555: the expensive urgent observer is deferred
whole, a later zero-candidate observer completes, no partial projection is
published, and both isolated runs yield the same telemetry fingerprint. This is
a bounded scheduler fixture, not authored Sawmill geometry or a promised actor
count; task 3.10 still owns real occluder authoring and segment validation.

Memory evidence sees the target at tick 1, hides it before tick 4, retains it at
tick 181 where `181 - 1 == 180`, emits a position-free `MEMORY_EXPIRED` record
at the next cadence tick 184 where the difference is greater than 180, and
omits it afterward. Render frames between configuration and tick 1 leave the
telemetry fingerprint and native projection unchanged.

## Accepted final validation

All commands used
`/Volumes/Data/sdk/godot/editors/4.7.2/Godot.app/Contents/MacOS/Godot`, version
`4.7.2.stable.official.ed1daf0bf`, with the Compatibility renderer. Every final
process exited zero. Output was reviewed for `SCRIPT ERROR`, `ERROR`, extension
load failures, assertions, leaks, and timeout markers; the accepted diagnostic
count is zero.

| Validation | Result |
| --- | ---: |
| Final editor import / script registration | exit 0; diagnostics 0 |
| Vision world focused contract | 310 / 0 |
| Deterministic focused repeat | 310 / 0; identical config fingerprint |
| Combined six-add-on smoke | 155 / 0 |
| Units and clock contract | 29 / 0 |
| Session lifecycle contract | 44 / 0 |
| Authority replay/tick-order contract | 81 / 0; 4 expected reentrant rejections |
| Identity collision contract | 18,442 / 0; 9,216 unique fixtures |
| Inventory/ability phase-adjacency contract | 546 / 0 |
| Toolchain lock | 7 / 0 |
| Locked destination packages | 6 passed; 0 failed |
| Vendor tooling unit tests | 4 passed; 0 failed |
| Strict approved-change validation | `Valid` |
| `git diff --check` | exit 0 |
| Godot assertion executions, including deterministic repeat | **19,917 / 0** |

The freshly created worktree initially had no `.godot` script-class cache. A
pre-import exploratory probe therefore produced cache-miss parse diagnostics;
the required pinned editor import populated the cache. Those exploratory probes
are not acceptance runs. Every run in the final matrix above followed import
and is diagnostic-clean.

## Reproduction

From the repository root:

```sh
export ZERKOV_GODOT=/Volumes/Data/sdk/godot/editors/4.7.2/Godot.app/Contents/MacOS/Godot
$ZERKOV_GODOT --headless --path . --editor --import --audio-driver Dummy --quit
$ZERKOV_GODOT --headless --path . --audio-driver Dummy \
  --script res://tests/ai/vision_world_contract.gd
$ZERKOV_GODOT --headless --path . --audio-driver Dummy \
  --script res://tests/addons/combined_addons_smoke.gd
$ZERKOV_GODOT --headless --path . --audio-driver Dummy \
  --script res://tests/raid/units_clock_contract.gd
$ZERKOV_GODOT --headless --path . --audio-driver Dummy \
  --script res://tests/raid/session_lifecycle_contract.gd
$ZERKOV_GODOT --headless --path . --audio-driver Dummy \
  --script res://tests/raid/authority_replay_contract.gd
$ZERKOV_GODOT --headless --path . --audio-driver Dummy \
  --script res://tests/raid/identity_contract.gd
$ZERKOV_GODOT --headless --path . --audio-driver Dummy \
  --script res://tests/raid/inventory_ability_reconciliation_contract.gd
python3 tools/check_toolchain.py
python3 tools/vendor_addons.py check --scope destination
python3 -m unittest tests/addons/test_vendor_addons.py
python3 /Users/mai1015/.codex/skills/spec-toolkit/scripts/spec_toolkit.py \
  validate add-zerkov-playable-raid-2026-09-09 --type change --strict
git diff --check
```

## Boundaries and remaining risks

- Production observer/target registration, revision updates, transform
  conversion, removal, and liveness are task 6.2. The focused test uses direct
  documented native calls only to exercise this task's scheduler and memory.
- `VisionAIAdapter` and the no-hidden-live-state consumption boundary remain
  task 6.3. No AI state, decisions, navigation, combat, hearing/noise, UI, or
  debug overlay is introduced here.
- Sawmill occluder segments remain task 3.10. The task-6.1 test geometry is
  synthetic, in-memory, and never shipped as level content.
- No `project.godot`, shared bootstrap, central identity, add-on/vendor source,
  truth spec, approved task ledger, UI, inventory, combat, or world scene was
  changed.
- The current provenance is the locked internal macOS development baseline.
  Windows/Linux release support and multiplayer remain gated elsewhere.

Exact source, test, dependency, lock, toolchain, manifest, and native artifact
hashes are recorded in `reviewed_hashes.sha256` beside this report.
