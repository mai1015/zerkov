# Task 6.1 authoritative Vision world evidence

This packet records the implementation-level evidence for approved task 6.1
on branch `codex/vision-world-6-1`, based on `d947b40`. It incorporates both
independent-review repair rounds. Human approval, encounter tuning, tasks 6.2
and 6.3, and whole-game acceptance are not claimed.

## Outcome

The game owns one sealed first-playable Common Vision configuration and one
offline authority world. The live `CommonVisionWorld2D` exists solely in
lexical state captured by an opaque Callable. No reflectively readable owner
property contains the native Node, `Callable.get_object()` is the script
resource, and the Callable has no bound arguments. Its operation protocol
never returns the native value and advances only while the exact reserved
authority callback is synchronously attested. `NOTIFICATION_PREDELETE`
synchronously frees the native state even for an owner configured off-tree;
every retained copy of the Callable observes `alive == false` afterward.

The production owner has no observer, target, occluder, transform, query, or
projection port. Those belong to tasks 6.2/6.3. Native memory/budget behavior is
tested through an explicitly test-only fixture that cannot be obtained from a
normally configured owner.

`RaidAuthority` owns the fixed `raid_vision_world` slot. Generic phase handler
registration rejects that ID in every phase and reserves capacity for it even
when all generic Vision slots are occupied. A typed Vision-owner API derives
the callback and checks the exact configured owner object, owner generation,
raid generation, provisional binding, and callback provenance. A two-sided
release claim plus synchronous authority attestation permits safe PREPARING
replacement; direct/replayed release calls are inert. Direct callbacks,
callbacks forged by an earlier handler in the same VISION phase, replayed
callbacks, and reflected runtime calls outside dispatch cannot advance.

Startup checks the exact project lock, installed debug/release artifacts,
release manifest, API, protocol, algorithm contract, required feature bits,
coordinate scale, and 60 Hz RaidClock before native creation. The accepted
lock schema includes and hashes both claimed source paths, Git head, release
revision, dirty state, package count/tree digest, manifest digest, integration
fields, and every artifact field. Unknown entry/source/artifact fields,
selected-field source replacements, relabels, mismatches, and malformed types
fail closed. The returned fingerprint hashes the immutable accepted record.

The repaired sealed configuration fingerprint is:

```text
3ead6e826bfd2552aa1396a4d266de3603524355c56620033cb1bd84b6df58f3
```

## Fixed configuration contract

| Boundary | Sealed value |
| --- | --- |
| Godot / canonical relation | 32 px = one tile = 1,000,000 Vision microunits |
| Checked coordinate domain | +/-65,536 px = +/-2,048,000,000 raw; one outside rejected atomically |
| Spatial grid | four-tile cells; 256 visited cells maximum |
| Per-evaluation budget | 16,384 deterministic work units |
| Cadence | first tick 1; every 3 authority ticks; 20 Hz at RaidClock 60 Hz |
| Telemetry | 64 evaluation rows; counters saturate at 9,007,199,254,740,000 |
| Scav sight | 18 tiles; 120-degree total cone; 180 memory ticks; urgent priority 200 |
| Mutant sight | 12 tiles; 160-degree total cone; 120 memory ticks; priority 100 |
| Target samples | `ANY_SAMPLE`; center and vertical +/- quarter-tile; three of max eight |
| Target masks | player bit 0; Scav bit 1; mutant bit 2 |
| Occluder masks | structure bit 0; vegetation bit 1 |

The coordinate limit remains the repaired bound from the first review.
Godot's `Vector2i` components are signed 32-bit values, so the inherited
1,048,576-pixel domain could wrap its 32,768,000,000 raw result. The exact
power-of-two 65,536-pixel bound produces 2,048,000,000 raw. Both conversion
directions accept the positive/negative boundary and reject one pixel/raw unit
outside without a partial value.

## Scheduler, memory, and failure evidence

The isolated native memory fixture sees a target at tick 1, hides it before
tick 4, retains it at tick 181 where `181 - 1 == 180`, emits the position-free
`MEMORY_EXPIRED` record at tick 184, and omits it at tick 187. The production
owner receives RaidAuthority ticks 1 through 193 and records exactly 65
evaluation attempts/completions plus 128 cadence skips. It exposes no process,
physics-process, delta, or public direct-tick driver.

The 16,384-work-unit fixture installs 128 synthetic segments and 43 matching
three-sample targets. Each cadence evaluation requests 16,555: the expensive
urgent observer defers whole, a later zero-candidate observer completes, and no
partial expensive projection is published. Two isolated worlds yield identical
metrics and projections. This fixture is not shipped Sawmill geometry and does
not claim task 3.10.

The native failure fixture advances observer 2 to tick 4, then schedules tick
1. Observer 1 publishes before observer 2 rejects the regressed tick, reproducing
the documented per-observer publication prefix:

```text
requested=0 consumed=0 completed=1 deferred=0 invalidated=0
code=6 diagnostic=13 detail=1
```

The owner contract delivers that exact value record through a nested test-only
owner/authority fixture (never a native handle); production RaidAuthority
explicitly rejects subclass claim methods. The owner records attempted tick 1 versus successful
tick 0, accounts every exact bounded metric in immutable history and totals,
enters `QUARANTINED`, invalidates the opaque runtime synchronously, and refuses
further advancement. Recovery requires teardown and a new owner/generation.

## Accepted validation

All Godot commands used
`/Volumes/Data/sdk/godot/editors/4.7.2/Godot.app/Contents/MacOS/Godot`, version
`4.7.2.stable.official.ed1daf0bf`, with Compatibility rendering configured by
the project. Every accepted command exited zero. Output was reviewed for script
errors, engine errors, extension failures, assertions, leaks, and timeouts; the
accepted diagnostic count is zero.

These are domain-only headless checks. No UI/composition/screen suite or visual
evidence was invoked, so no alternate-resolution artifact was created; the
project's exact 1920x1080 UI boundary was not exercised by this task.

| Validation | Result |
| --- | ---: |
| Final editor import / script registration | exit 0; diagnostics 0 |
| Vision world focused contract | 190 / 0 |
| Deterministic focused repeat | 190 / 0; identical seal/failure metrics |
| Combined six-add-on smoke | 155 / 0 |
| Units and clock contract | 33 / 0 |
| Session lifecycle domain contract | 44 / 0 |
| Authority replay/tick-order contract | 81 / 0; 4 expected reentrant rejections |
| Toolchain lock | 7 / 0 |
| Locked destination packages | 6 passed; 0 failed |
| Vendor tooling unit tests | 4 passed; 0 failed |
| Strict approved-change validation | `Valid` |
| `git diff --check` | exit 0 |
| Accepted Godot assertion executions | **693 / 0** |

## Reproduction

From the isolated repository root:

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
python3 tools/check_toolchain.py
python3 tools/vendor_addons.py check --scope destination
python3 -m unittest tests/addons/test_vendor_addons.py
python3 /Users/mai1015/.codex/skills/spec-toolkit/scripts/spec_toolkit.py \
  validate add-zerkov-playable-raid-2026-09-09 --type change --strict
git diff --check
```

## Boundaries and remaining risks

- Task 6.2 still owns the concrete lifecycle capability, actor identities,
  transform revisions/liveness, and observer/target/occluder orchestration.
- Task 6.3 still owns the AI-facing immutable projection adapter. There is no AI
  state, decision, navigation, combat, hearing/noise, UI, or overlay here.
- Authored Sawmill occluders remain task 3.10; all geometry in this evidence is
  synthetic and test-only.
- The native package publishes atomically per observer, not scheduler call. The
  owner therefore fail-stops on any whole-call failure and never recovers the
  partial native instance in place.
- Exact source paths intentionally make the accepted local macOS provenance
  non-portable. A relocated SDK, Windows/Linux artifacts, or a changed package
  must be explicitly re-attested and resealed rather than silently accepted.
- No `project.godot`, bootstrap, central identity, add-on/vendor source, truth
  spec, approved task ledger, UI, inventory, combat, or world scene was changed.

Exact source, test, dependency, lock, toolchain, manifest, and artifact hashes
are recorded in `reviewed_hashes.sha256` beside this report.
