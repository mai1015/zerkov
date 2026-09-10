# Verification

How to run every gameplay-ability test/build suite locally and in CI, what each
one proves, which spec requirement it maps to, and the current verified/
planned state of each platform artifact.

This addon is a required C++ GDExtension (see the platform-support spec's
"Required Native C++ Runtime" and "Godot and Binding Compatibility"
requirements): there is no script fallback, so every one of these suites
exists to prove the native runtime actually works on a given target before
that target is advertised as supported. The authoritative source of truth for
per-target support is
[`addons/gameplay_abilities/release_manifest.json`](../release_manifest.json)
— a target is supported only while its entry is `"validated"` and has a
`sha256`. `"built"` means present and checksummed but not export-verified;
`"planned"` means declared intent with no artifact yet. See
`docs/common_ui/platforms.md` for the same status-value convention CommonUI
uses; this addon follows it exactly.

The addon is being built by several agents in parallel against the shared
contract in this change
(`docs/spec/changes/add-gameplay-ability-foundation-2026-07-24/`). Several
suites described below reference scenes, a manifest, or scripts that other
agents add separately. Where that is true, this document says so explicitly —
a green `tools/ga_verify.sh` run or a green CI job does **not** by itself mean
every suite ran; read the skip/failure notes.

## Quick start: run everything locally

```bash
tools/ga_verify.sh
```

Modeled directly on `tools/verify.sh` (CommonUI's equivalent): same shell
style, same section banners, same skip-with-exit-3 convention for missing
export templates. Runs, in order:

| # | Stage | Proves | Spec / task |
|---|---|---|---|
| 1 | `scons ga_tests run_ga_tests=yes sanitize=address,undefined` | Engine-independent core+protocol tests build clean and pass under ASan+UBSan | tasks.md 11.1, 11.5; spec "Native and Multiplayer Verification Matrix" (sanitizer scenario) |
| 2 | `scons platform=macos target=template_debug\|release arch=universal` | The GDExtension builds for macOS debug and release | tasks.md 1.3, 11.7 |
| 3 | `tools/godot.sh run tests/gameplay_abilities/smoke/ga_smoke_main.tscn` | The extension loads in a running Godot process (extension-load smoke) | tasks.md 1.5, 11.7; spec "Required Native C++ Runtime" |
| 4 | `tools/godot.sh run tests/gameplay_abilities/integration/integration_main.tscn` | Headless Godot integration, including deterministic tasks and typed-target coordinator/batch behavior | foundation 11.3; task change 5.8; targeting change 6.10 |
| 5 | `tests/gameplay_abilities/network/run_multipeer_conformance.sh` | Five ENet stages: harness/discovery, foundation dedicated/listen scenarios, focused task/target protocol, playable typed basic combat, and a dedicated granular delta-replication conformance stage (task 6.3: delta-parity digest checkpoints, idle-suppression, duplication/reorder convergence, overflow-fallback recovery) | foundation 7.14/7.15/11.3; task 5.5/5.8; targeting 6.7/6.10; delta-replication 6.3 |
| 6 | `tools/ga_checksums.py --update` / `--verify` | Built artifacts match their recorded checksums | tasks.md 12.1, 12.4; spec "Release Manifest and Fail-Fast Diagnostics" |
| 7 | `tools/ga_export_smoke.sh macOS debug` | The exported package actually bundles the native library | tasks.md 11.7; spec "Declared Client Artifact Matrix" |

Steps 3–6 depend on files other agents are adding in parallel (an
extension-load smoke scene, integration scene, a multi-peer conformance
runner, and the release manifest). **Locally**, `tools/ga_verify.sh` tolerates
any of them not existing yet: it prints `(skipped: not yet present - ...)` and
keeps going, because failing a developer's everyday verification loop on
another agent's in-progress work would make the script useless during
parallel development. It still fails loudly — immediately, via `set -e` — on
any **real** failure: a native test failure, a build failure, or a genuine
failure of any suite that *is* present. The final summary lists every skipped
suite so a green run is never mistaken for full coverage.

As of this writing, step 3 (extension-load smoke), step 4 (headless
integration — see below), step 5 (multi-peer conformance — see below), and
step 6 (checksums, now that the release manifest exists) all run for real;
step 7 skips with exit 3 because export templates are not installed in this
environment (this exit code is expected locally — CI installs templates and
does not tolerate it).

`tests/gameplay_abilities/integration/integration_main.tscn` now exists: it
is an AGGREGATE runner, not a scenario of its own. It auto-discovers every
sibling `test_*.tscn` in `tests/gameplay_abilities/integration/` (including
`test_typed_targeting_and_tasks.tscn`; sorted, so future scenes are picked up
without changes here or in CI),
runs each as its own separate `godot --headless` process (see its own doc
comment for why: every sub-scene calls `get_tree().quit()` on itself, which
would tear down this process's own `SceneTree` if instanced in-process
instead), and aggregates pass/fail with a non-zero exit on any sub-scene
failure or timeout. `tools/godot.sh run
tests/gameplay_abilities/integration/integration_main.tscn` exercises every
discovered sub-scene end to end.

## Tools

### `tools/ga_verify.sh`

Full local verification, described above. Exits non-zero only on a genuine
failure among the suites that exist; exit 0 otherwise (with a skip summary
printed to stdout).

### `tools/ga_export_smoke.sh <preset-name> [debug|release]`

`tools/export_smoke.sh`'s gameplay-ability counterpart. Exports the named
preset headlessly and confirms the package actually contains
`libgameplay_abilities.*` (not just that the export process exited zero — a
package that "succeeds" but omits the native library is a release blocker).
Kept as its own file, rather than a flag added to `tools/export_smoke.sh`,
because that script is owned by CommonUI's tooling per the shared
implementation contract and its native-library check is hardcoded to
`libcommon_ui`. Same CLI, same Godot resolution (`GODOT_BIN`, defaulting to
`tools/bin/Godot.app/Contents/MacOS/Godot`), and the same skip-on-missing-
templates convention (exit code 3) as the original.

### `tools/ga_checksums.py`

`tools/checksums.py`'s gameplay-ability counterpart — same CLI
(`--update` / `--verify` / `--validate PLATFORM`), same semantics, pointed at
`addons/gameplay_abilities/release_manifest.json` instead of CommonUI's.
Kept as its own file for the same reason as `ga_export_smoke.sh`: the
original is hardcoded to `addons/common_ui` and is off-limits to modify.
**Gap**: a cleaner long-term fix is to generalize `tools/checksums.py` (e.g.
an `--addon` argument) so both addons share one implementation instead of two
near-identical files; that was not done here because the task explicitly
restricts changes to `tools/checksums.py` to a report rather than an edit.

### `tools/ga_dedicated_server.sh [--port PORT] [--scene SCENE] [--timeout SECONDS]`

Starts a headless dedicated-server run of the gameplay-ability reference
example (`examples/gameplay_abilities/dedicated_server.tscn`, default scene;
default port `27500`) for local and CI startup/session smoke testing. Proves
tasks.md 11.8 and the spec's "Headless Dedicated Server Support" requirement:
uses Godot's `--headless` flag (headless display driver + dummy audio driver
in one), fails with an actionable message if the scene does not exist yet
(rather than silently passing), and exits non-zero if the server process dies
during its startup grace period.

Godot binary resolution mirrors `tools/godot.sh` exactly — same `GODOT_BIN`
environment variable, same default path — but invokes the binary directly
rather than shelling out to `tools/godot.sh run`, because that command is a
thin foreground wrapper with no room for `--port` plumbing and because this
script needs the real Godot process ID (not a wrapper script's PID) to reliably
detect a startup crash and to shut the server down again via signal.

Once the process survives the startup grace period, it prints a
machine-greppable ready line to stdout:

```
GA_DEDICATED_SERVER_READY port=<port> pid=<pid> scene=<scene>
```

and then blocks, waiting for the server to exit on its own or be interrupted.
A caller that wants to run clients against the server should background this
script, poll its stdout (or a redirected log file) for the ready line, run its
clients, then send `SIGTERM`/`SIGINT` to shut the server down — the script
handles that signal as a clean, requested stop (exit 0), separately from an
unrequested crash (non-zero).

**Convention this script establishes for the not-yet-existing scene**: the
target port is exported as the `GA_DEDICATED_SERVER_PORT` environment
variable, since the addon has no CLI-argument-forwarding convention yet. The
scene script that task 11.8 adds is expected to read
`OS.get_environment("GA_DEDICATED_SERVER_PORT")`.

### `tests/gameplay_abilities/network/run_multipeer_conformance.sh` — multi-peer conformance suite (task 11.3)

The `ga-multipeer` CI job's and `tools/ga_verify.sh`'s single entry point.
Five stages:

1. `tests/gameplay_abilities/network/test_enet_harness.tscn` (tasks 7.14/7.15)
   — the reference ENet session harness and bounded LAN-discovery beacon,
   in-process, over isolated loopback ports.
2. `tests/gameplay_abilities/network/run_multipeer_processes.sh` (task
   11.3) — **real, separate OS processes**, not an in-process simulation: a
   dedicated-server scenario (one server process plus three client
   processes) and a listen-server scenario (one host process that is also a
   local player, plus one remote client process), communicating over real
   loopback ENet sockets on a randomized, isolated port range so parallel
   runs cannot collide. Every process's stdout/stderr is captured to a
   bounded log file and dumped on any failure; a hard overall timeout
   (`GA_MULTIPEER_TIMEOUT_SEC`, default 300s, backed by both polling-loop
   deadline checks and a background watchdog that can interrupt even a
   blocked `wait`) fails the run instead of hanging; every child process's
   exit code is checked explicitly; a cleanup trap kills and reaps every
   tracked child on any exit path (success, failure, or signal) so a failed
   run never leaves orphans.

3. `tests/gameplay_abilities/network/run_task_target_processes.sh` — a
   focused, real dedicated-server/client ENet scenario. It proves late-join
   task restore, duplicate logical input executing once, local oversized
   intent rejection, out-of-order session-command rejection, sanitized
   provider rejection, disconnect/reconnect session restore with no
   historical outcomes, and duplicate corrected confirmation preserving
   authority canonical intent.

4. `tests/gameplay_abilities/network/run_basic_multiplayer_demo.sh` — the
   playable listen-server/client main scene using typed direct-entity
   resolution and coordinator effect batches; proves movement, stamina,
   damage, destruction, and XP convergence.

5. `tests/gameplay_abilities/network/test_delta_conformance.tscn` (task 6.3,
   add-granular-delta-replication-2026-07-27) — a dedicated in-process, real
   loopback ENet scene proving granular delta-replication conformance a
   real transport is needed for (native tests already exhaustively prove the
   codec/state-machine in isolation: `ga_test_change_tracking.cpp`,
   `ga_test_delta_codec.cpp`, `ga_test_delta_parity.cpp`,
   `ga_test_replication_gate.cpp`, `ga_test_heartbeat.cpp`,
   `ga_test_delta_conformance.cpp`'s `FakeTransport` duplication/reorder
   coverage, and `ga_test_event_stream.cpp`'s own
   `stream_convergence_under_duplication_and_reordering_is_deterministic`).
   Four scenarios, each its own real server+client (or server+owner+observer)
   ENet session pair:
     - **`_test_delta_parity_digest_checkpoints`** (spec "Delta path matches
       snapshot path") — after a real predicted-then-acknowledged Dash
       commits and both streams catch up, an explicit resync's fresh full
       snapshot digest-equals the state already reached through
       baseline+deltas, for BOTH the owner (byte-for-byte snapshot digest)
       and the observer (field-for-field `public_state_updated` parity)
       audiences.
     - **`_test_idle_suppression_and_heartbeat_cadence`** (spec "Idle
       component sends no state" / "Tick estimation survives suppression")
       — across many genuinely idle ticks, `debug_owner_stream_head_sequence`
       never advances, no `SNAPSHOT`/`TARGET_STATE`/gap is observed, at least
       one but no more than `ceil(ticks / HEARTBEAT_SUPPRESSED_CADENCE_TICKS)`
       heartbeats are sent, and the owner's estimated tick keeps correcting
       from those heartbeats alone; a real committed change afterward resumes
       sends exactly once.
     - **`_test_duplication_and_reorder_convergence`** (spec "Duplicated and
       reordered deliveries still converge") — two real owner event batches
       and a real heartbeat, captured via the bridge's own test/debug peek
       methods (`debug_peek_owner_event_batch_frame`/
       `debug_peek_last_heartbeat_frame`, added to
       `GameplayAbilityNetworkBridge` specifically for this stage) and
       redelivered directly to `_rpc_event_batch`/`_rpc_heartbeat` out of
       order and/or twice: an out-of-order batch is detected as a gap and
       never partially mutates state, a redelivered duplicate never applies
       twice (including across the resync boundary), and the client
       automatically recovers a byte-identical baseline.
     - **`_test_overflow_fallback_recovery`** (spec "Worst-case churn falls
       back to snapshot") — stalling a peer (never calling `push_full_state`
       for it) through 100 real committed grant/revoke commits, well past
       `MAX_CHANGE_REVISION_RING_DEPTH` (64), forces `ResyncTrigger::
       DELTA_OVERFLOW` on the next push: the peer receives a fresh full
       snapshot proactively (never a `replication_gap` first), converges
       byte-for-byte to authority's current state, and a routine change
       afterward rides a normal delta batch on the new baseline rather than
       triggering another snapshot.

Stage 2 reuses the reference vertical slice's content and routing
(`examples/gameplay_abilities/slice/**`, unedited). Its process entry points
are `multipeer_server.gd`/`multipeer_client.gd`; `multipeer_common.gd` owns
bounded marker-file coordination that never crosses the ENet connection.

**Stage 2 scenario coverage**:

   | Spec-named scenario | Covered by |
   |---|---|
   | Listen server mode | `run_listen_scenario`: `multipeer_server.gd` (`GA_MP_MODE=listen`) hosts and plays its own `hero1` via direct authoritative calls (no bridge round trip — the same distinction `ROLE_SERVER_AUTHORITY` documents), while a real remote client process controls `hero2` |
   | Dedicated server mode | `run_dedicated_scenario`: `multipeer_server.gd` (`GA_MP_MODE=dedicated`) has no local player at all |
   | At least two clients simultaneously | Dedicated scenario: clients A (hero1), B (hero2), and (from late join onward) C (hero3) are all connected at once |
   | Accepted prediction | Every client's own Dash: predicted locally, sent, and acknowledged (`main_a`/`main_b`/`late_join_c`/`listen_client` scripts in `multipeer_client.gd`) |
   | Rejected prediction | Client A's second Dash after the server induces an authoritative Stun on hero1: rejected with `ABILITY_BLOCKED_TAG`, whether caught locally or via server round trip (robust to either — see that code's own comment on the inherent race between the test-harness marker signal and ordinary event-batch delivery) |
   | Late join | Client C connects (as hero3) only after hero1 and hero2 have already acted; its own initial snapshot shows unaffected default state, then it predicts normally |
   | Resynchronization after an induced gap | Client A calls `request_resync(0)` after the induced Stun and converges to the true `state.control.stunned` tag |
   | Ownership spoofing | Client A builds a second, minimal local mirror of hero2 (matching hero2's NodePath so the RPC actually routes to the server's real hero2 bridge) and sends an activation command through it; rejected `PERMISSION_DENIED`, and hero2's real state (independently confirmed by client B's own checks) is unaffected |
   | Target rejection | Client B casts Heal targeting itself; rejected `ABILITY_INVALID_TARGET` by the reference slice's own (unedited) `_authorize_target` "no self-targeting" rule |
   | Malformed payloads | Client A sends a truncated and an oversized garbage `PackedByteArray` directly through `_rpc_activation_command` (`RPC_MODE_ANY_PEER`, so any connected client may call it); the server rejects both without disruption, proven by a subsequent explicit resync still succeeding |
   | Disconnect/reconnect | Client A's own process leaves and rejoins the same server: a new peer id is issued, a fresh full snapshot is required before predicting again, and (verified by inspection, plus the native `auth_reconnect_new_session_invalidates_old_session` test) the wire protocol carries no client-supplied session field at all, so an old session identity cannot be replayed through the real activation-command path |
   | Deterministic final state | After every scripted action, the server freezes its tick and each owning client performs one final explicit resync, then both sides hex-encode `write_snapshot()` and compare; equal for hero1/hero2/hero3 (dedicated) and hero2 (listen). Excludes the one field that is *correctly* expected to differ between a server's authoritative component and a client's mirror of the same entity (`ga::ComponentRole`, `SERVER_AUTHORITY` vs `NETWORK_CLIENT` — not gameplay state) — see `multipeer_common.gd`'s `snapshot_digest_excluding_role` for why and how |

**Reliability**: run repeatedly (46+ consecutive local runs in the final
   configuration; 45 passed) it passes cleanly the large majority of the
   time. A residual, intermittent (roughly one run in ~10-45, depending on
   the run) engine-level crash (SIGSEGV, surfaced as exit code 134) was
   observed in either a CLIENT or the SERVER OS process's own shutdown path
   shortly after genuinely active ENet traffic — never correlated with any
   specific scenario step, and never after a failed assertion (it happens
   only once a process's own checks have all already passed). Several
   GDScript-level mitigations were tried (explicit `leave()` before
   quitting, omitting it entirely to match `test_slice.gd`'s own proven
   pattern, waiting on the harness's `session_closed` signal, real-time
   delays from 0.3s to 1.0s); each changed the crash rate but none
   eliminated it. Six matching macOS crash reports (2026-07-24) confirmed
   the cause: an identical null-deref SIGSEGV on the main thread INSIDE
   stock Godot 4.7.1's own engine cleanup path, strictly after the main
   loop exits — this addon's GDExtension dylib never appears on the
   crashing stack — i.e. an upstream ENetMultiplayerPeer/MultiplayerAPI
   shutdown-ordering bug in the engine itself, not this suite's own
   scripts, and outside the files this task may edit (task 11.13).

   Since that crash cannot be eliminated from this repo, the harness instead
   tolerates it (task 11.14): every process writes a `clean_exit_<id>` (or
   `clean_exit_server`) marker immediately once its own checks have all
   passed, before its final `quit()` call, and `run_multipeer_processes.sh`'s
   `wait_and_check_exit` treats a nonzero child exit as a tolerated, loudly
   logged, known-crash WARN when that marker is present in the scenario
   workdir, rather than a hard failure — a nonzero exit WITHOUT the marker
   still fails the run exactly as before. Set `GA_MULTIPEER_STRICT=1` to
   disable this tolerance and restore unconditional hard-fail behavior (e.g.
   to confirm a suspected real, non-teardown crash locally). See the task
   report for this change for the full investigation and reproduction data.

## CI jobs (`.github/workflows/ci.yml`)

All gameplay-ability jobs are prefixed `ga-` and added alongside the existing
CommonUI jobs (`native-tests`, `desktop`, `web`, `android`) without modifying
any of them.

| Job | Proves | Spec / task | Status |
|---|---|---|---|
| `ga-native-tests` | Native core+protocol tests pass under ASan+UBSan | foundation 11.5; task 5.1–5.4; targeting 6.4–6.6/6.8 | Passing (594 `GA_TEST` cases at this revision) |
| `ga-fuzz` | Protocol fuzz tests (`--filter=fuzz_`) run cleanly | tasks.md 11.5 ("protocol fuzz tests where supported") | Passing (the bounded, deterministic `fuzz_message_envelope_never_crashes_or_succeeds_on_malformed_input`, `fuzz_handshake_decode_never_crashes_or_succeeds_on_malformed_input`, and `fuzz_definition_id_decode_never_crashes` tests in `ga_test_protocol.cpp` match `--filter=fuzz_`; see convention below) |
| `ga-integration` | Headless Godot integration behavior | foundation 11.3; task 5.8; targeting 6.10 | Passing — aggregate auto-discovers every sibling scene, including typed targeting/tasks |
| `ga-multipeer` | Five real ENet stages covering foundation, task/target, playable typed-combat, and dedicated delta-replication conformance flows | foundation 7.14/7.15/11.3; task 5.5; targeting 6.7; delta-replication 6.3 | Passing — see "Multi-peer conformance suite" |
| `ga-dedicated-server-export` | Linux x86_64 dedicated-server export bundles the native library and starts headlessly | tasks.md 11.8; "Headless Dedicated Server Support" | `examples/gameplay_abilities/dedicated_server.tscn` and `tools/ga_dedicated_server.sh` now exist and are exercised by this job's startup/session smoke step; task 11.8 itself remains open (see tasks.md) |
| `ga-desktop` (windows/macos/linux matrix) | Declared desktop artifacts build, smoke-load, integration-test, and export cleanly | tasks.md 12.2; "Declared Client Artifact Matrix" | Passing on Linux/macOS — the extension-load smoke step and the aggregate integration step (`integration_main.tscn`, see above) both run for real now. The Windows leg skips both headless steps (matching CommonUI's own Windows carve-out) and passes today on build + export smoke alone |
| `ga-web` | WebAssembly artifact compiles | "WebAssembly Extension and Protocol Support" | `continue-on-error: true` — no Web-hosted, cross-origin-isolated multiplayer smoke test exists in this repo |
| `ga-android` | Android arm64/x86_64 artifacts compile | "Declared Client Artifact Matrix" | `continue-on-error: true` — no Android device/emulator smoke test exists in this repo |
| `ga-ios` | iOS artifact compiles | "Declared Client Artifact Matrix" | `continue-on-error: true` — no iOS device/simulator smoke test exists in this repo; CommonUI itself has no iOS job yet either |

Jobs marked "fails loudly" are intentional: per this task's instructions, a
job whose scenes do not exist yet must fail with an actionable message rather
than skip silently, so CI cannot be mistaken for green coverage of unfinished
work. Once the referenced scene/script lands, the same job starts exercising
it for real — no further CI changes should be needed.

`ga-web`, `ga-android`, and `ga-ios` are marked non-blocking because this repo
genuinely cannot verify those targets yet (no browser, device, or emulator
multiplayer smoke test), and the platform-support spec's "Declared Client
Artifact Matrix" requirement explicitly forbids advertising a target as
supported before its export and multiplayer smoke tests pass — a
`continue-on-error` build proves compilation only, never that.

### Conventions this CI relies on

- **`GA_FUZZ_ITERATIONS`** (`ga-fuzz` job, default `2000`): the shared test
  harness (`native/tests/ga_test_support.h`) only supports `--filter=<substr>`
  and `--list`, with no iteration-count flag of its own, so each bounded-
  iteration `fuzz_`-prefixed `GA_TEST` (`ga_test_protocol.cpp`) reads this
  environment variable itself to bound its own loop.
- **`GA_DEDICATED_SERVER_PORT`** and the `GA_DEDICATED_SERVER_READY` stdout
  line (`tools/ga_dedicated_server.sh`): see the tool reference above.

## Known gaps

- **`tools/checksums.py` is CommonUI-only.** `tools/ga_checksums.py` mirrors
  it for gameplay-abilities rather than generalizing the shared script, per
  this task's restriction against modifying it. Generalizing
  `tools/checksums.py` (e.g. an `--addon` flag) and deleting the duplicate
  would be a reasonable follow-up once someone is willing to touch that file.
- **The Linux dedicated-server startup/session smoke test
  (`ga-dedicated-server-export`) runs the scene through the Godot editor
  binary** (via `tools/ga_dedicated_server.sh`, same as local development),
  not through the final exported standalone executable. It proves the scene
  starts headlessly and stays up, and (via the preceding export-smoke step)
  that the exported package separately bundles the native library — but it
  does not prove the *exported binary itself* boots correctly end-to-end.
  Closing that gap needs a way to run an exported executable directly and is
  left for whoever builds `examples/gameplay_abilities/dedicated_server.tscn`
  to extend.
- **No `[preset.4]` Windows/Android/iOS export presets exist yet** beyond the
  ones already seeded by CommonUI (macOS, Linux, Web) plus the new "Linux
  Dedicated Server" preset added here. Add them the same way, as those
  artifacts approach `"validated"`.
- **An intermittent client-process-shutdown SIGSEGV in the multi-peer
  conformance suite (task 11.3).** See "Multi-peer conformance suite"
  above's "Reliability" note for the full description. Believed to be an
  ENetMultiplayerPeer/MultiplayerAPI engine-shutdown-ordering interaction,
  not a bug in this suite's own scripts; reproducing it with a symbolized
  debug build and root-causing it in `native/godot`/the engine is left for
  whoever owns that layer.

## Platform artifact status

Mirrors [`release_manifest.json`](../release_manifest.json), which is the
authoritative source — check it directly for the current, exact state. As of
this writing:

| Platform | Arch | Status |
|---|---|---|
| macOS | universal | `built` (compiled and checksummed locally; not yet `validated` — export templates are not installed in this environment, so export smoke has not run) |
| Windows | x86_64 | `planned` |
| Linux | x86_64 | `planned` |
| Android | arm64, x86_64 | `planned` |
| iOS | arm64 | `planned` |
| Web | wasm32 | `planned` |

No target is advertised as supported yet. Promoting a target to `validated`
follows the same steps as CommonUI (`docs/common_ui/platforms.md`): build with
SCons, `tools/ga_checksums.py --update`, run the matching export smoke test,
then `tools/ga_checksums.py --validate <platform>` on success — steps CI's
`ga-desktop` job performs automatically for desktop targets.
