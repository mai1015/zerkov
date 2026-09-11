# Task 6.1 authoritative Vision world evidence

Task 6.1 is complete at the implementation/evidence level on branch
`codex/vision-world-6-1`, based on `d947b40`. This packet incorporates the six
requested independent-review repairs to `bf4d2dd`. Human approval, encounter
tuning, and whole-game acceptance are not claimed.

## Outcome

The game owns one sealed first-playable Common Vision configuration and one
privately retained offline authority world. The native `CommonVisionWorld2D`
is not attached for public scene traversal and no method returns its mutable
handle. The only production-facing operations are bound-generation-checked,
sealed-profile mutation ports and recursively immutable detached projection
copies. Teardown frees native state synchronously before incrementing the
generation, so a retained operation callable is immediately inert.

The owner uses exactly one fixed `raid_vision_world` slot per `RaidAuthority`.
There is no caller-selected handler identity and no public direct tick driver.
`RaidAuthority` attests the synchronously executing generation, phase, tick,
and handler slot. Direct calls, calls forged from another handler in the same
VISION phase, replay after dispatch, and retained callbacks after authority
teardown all fail closed without advancing telemetry.

Startup checks the project lock, installed debug/release artifact hashes,
release-manifest hash, API, protocol, algorithm contract, feature bits,
coordinate scale, and the 60 Hz raid clock before native state is created. The
accepted lock fingerprint covers Git head, release revision, package dirty
state/count/tree digest, manifest schema/digest, integration fields, and each
artifact's platform, architecture, build, status, artifact digest, manifest
digest, and manifest-match label. Fingerprints are calculated from the
normalized accepted records returned by validation. Numeric strings and other
malformed types are rejected before conversion across configuration, schedule,
budget, layer, profile, sample, runtime-contract, and lock fields.

The repaired sealed configuration fingerprint is:

```text
0abdcc202b3f0299fa6d9d3726e16ab955b8a1d1481c201c1770aea21e57dd2e
```

## Fixed configuration contract

| Boundary | Sealed value |
| --- | --- |
| Godot / canonical relation | 32 px = one tile = 1,000,000 Vision microunits |
| Checked coordinate domain | +/-65,536 px = +/-2,048,000,000 canonical raw; one outside rejected |
| Spatial grid | four-tile cells; 256 visited cells maximum |
| Per-evaluation budget | 16,384 deterministic work units |
| Cadence | first tick 1; every 3 authority ticks; 20 Hz at RaidClock 60 Hz |
| Telemetry | 64 evaluation rows; counters saturate at 9,007,199,254,740,000 |
| Scav sight | 18 tiles; 120-degree total cone; 180 memory ticks; urgent priority 200 |
| Mutant sight | 12 tiles; 160-degree total cone; 120 memory ticks; priority 100 |
| Target samples | `ANY_SAMPLE`; center and vertical +/- quarter-tile; three of native max eight |
| Target masks | player bit 0; Scav bit 1; mutant bit 2 |
| Occluder masks | structure bit 0; vegetation bit 1 |

The coordinate limit is intentionally reduced from the inherited
1,048,576-pixel bound. Godot `Vector2i` components are signed 32-bit values;
the old bound produced 32,768,000,000 raw and could wrap. The new exact
power-of-two pixel bound produces 2,048,000,000 raw, leaving explicit headroom
below `INT32_MAX`. Both conversion directions cover the exact positive and
negative boundary and reject one pixel/raw unit outside without a partial
result. Target base-plus-sample sums are also checked before native mutation.

## Scheduler, memory, and failure evidence

The 16,384 budget admits a conservative workload of 42 matching three-sample
targets against 128 segments (`42 + 42 * 3 * 128 = 16,170`). The contract proves
that 43 targets request 16,555: the expensive urgent observer is deferred
whole, a later zero-candidate observer completes, no partial observer
projection is published, and two isolated runs yield the same telemetry
fingerprint. This is a bounded scheduler fixture, not authored Sawmill geometry
or a promised actor count; task 3.10 still owns real occluder authoring.

Memory evidence sees the target at tick 1, hides it before tick 4, retains it at
tick 181 where `181 - 1 == 180`, emits a position-free `MEMORY_EXPIRED` record
at the next cadence tick 184, and omits it afterward. Render frames between
configuration and tick 1 leave the telemetry fingerprint and projection
unchanged.

The adversarial native fixture advances observer 2 to tick 4 and then calls
the scheduler at tick 1. Observer 1 publishes before observer 2 rejects the
regressed tick, reproducing Common Vision's documented whole-call partial
failure. The exact returned prefix is:

```text
requested=0 consumed=0 completed=1 deferred=0 invalidated=0
code=6 diagnostic=13 detail=1
```

The owner records attempted tick 1 separately from successful tick 0, retains
all five exact metrics in immutable bounded history and cumulative totals,
enters `QUARANTINED`, destroys native state synchronously, and refuses further
mutation or advancement. Recovery requires teardown and a fresh owner.

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
| Vision world focused contract | 388 / 0 |
| Deterministic focused repeat | 388 / 0; identical config/failure metrics |
| Combined six-add-on smoke | 155 / 0 |
| Units and clock contract | 33 / 0 |
| Session lifecycle contract | 44 / 0 |
| Authority replay/tick-order contract | 81 / 0; 4 expected reentrant rejections |
| Identity collision contract | 18,442 / 0; 9,216 unique fixtures |
| Inventory/ability phase-adjacency contract | 546 / 0 |
| Toolchain lock | 7 / 0 |
| Locked destination packages | 6 passed; 0 failed |
| Vendor tooling unit tests | 4 passed; 0 failed |
| Strict approved-change validation | `Valid` |
| `git diff --check` | exit 0 |
| Godot assertion executions, including deterministic repeat | **20,077 / 0** |

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

- The low-level sealed-profile ports do not implement production actor
  identity, transform/liveness ownership, or observer/target orchestration;
  those remain task 6.2.
- `VisionAIAdapter` and the no-hidden-live-state consumption boundary remain
  task 6.3. No AI state, decisions, navigation, combat, hearing/noise, UI, or
  debug overlay is introduced here.
- Sawmill occluder segments remain task 3.10. The task-6.1 geometry is
  synthetic, in-memory, and never shipped as level content.
- The native package documents atomic publication per observer, not per
  scheduler call. This owner therefore fail-stops on any whole-call failure;
  it does not attempt in-place recovery of the partial world.
- No `project.godot`, shared bootstrap, central identity, add-on/vendor source,
  truth spec, approved task ledger, UI, inventory, combat, or world scene was
  changed.
- The accepted provenance is the exact locked internal macOS development
  baseline. Windows/Linux release support and multiplayer remain gated.

Exact source, test, dependency, lock, toolchain, manifest, and native artifact
hashes are recorded in `reviewed_hashes.sha256` beside this report.
