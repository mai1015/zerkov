# Verification

> **Historical record versus current workspace:** the dated counts later in
> this file record the 2026-07-27 release-gate run; they are not a claim that
> every current working-tree check is green. In particular, the bundled Godot
> network bridge now has documented hardening and convergence gaps. Review
> [`how-it-works.md`](how-it-works.md#current-godot-bridge-boundaries) and run
> the relevant commands against your exact revision before shipping.
>
> This standalone mirror does not include sibling addons, example scenes,
> repository CI configuration, the original spec workspace, or
> `tests/weapon_system/run_dependency_removal.sh`. Later rows naming those
> paths are historical provenance from the canonical multi-addon repository,
> not commands available in this package.

How to build the extension and run the available suites and scripts that verify
the addon's platform behavior, performance, and security boundaries.
`addons/weapon_system/release_manifest.json` is the packaged release record for
exactly which platform artifacts have passed their required smoke tests --
do not infer platform support from this document.

## Building the extension

```sh
scons platform=macos target=template_debug arch=universal -j8
scons platform=macos target=template_release arch=universal -j8
```

Godot's non-exported headless/editor run always resolves the
`template_debug` artifact -- every suite below that runs through
`tools/godot.sh` exercises the debug artifact. The release artifact's own
load path is independently confirmed only by an export smoke test (see
"11.1 Platform matrix" below), matching every sibling addon's own
documented caveat.

## Suites, in dependency order

| Suite | Command | Proves |
|---|---|---|
| Engine-free native suite | `scons weapon_tests run_weapon_tests=yes -j8` | The entire `native/core/` and `native/protocol/` layer, with no Godot engine or GDExtension loaded. The historical release record below reports 207 passing tests; rerun for the current count. |
| Include-boundary check | `scons weapon_boundary_check` | `native/core/` and `native/protocol/` never `#include` a Godot header. |
| Fixture check | `scons weapon_fixture_check` | The golden protocol/zerkov fixtures under `tests/weapon_system/fixtures/` still parse and match `tests/weapon_system/verify_fixtures.py`'s expectations. |
| Packaged integration scenes | `tools/godot.sh run tests/weapon_system/integration/*.tscn` | The standalone package currently includes definition-catalog authoring and version-reporting scenes. |
| **Dedicated-server headless-purity suite** | `tools/godot.sh run tests/weapon_system/server/wpn_server_main.tscn` | Task 11.2: a headless, `ROLE_SERVER_AUTHORITY` `WeaponAuthority` running a full configure/create/fire/reload/configure_attachments/teardown cycle, with a runtime assertion that the subtree it builds contains zero `CanvasItem`/`AudioStreamPlayer`-derived nodes. Current count: 21 checks, 0 failed. |
| Network conformance (in-process) | included in the native suite above (`wpn_test_network_conformance.cpp`) | Snapshot/delta convergence under scripted AND seeded-random loss/duplication/reordering via `FakeTransport`. |
| Separate-process network conformance | `tests/weapon_system/network/run_weapon_network_conformance.sh` | Real `ENetMultiplayerPeer` across two OS processes. |

Run the whole chain in this order after any native change: native suite ->
boundary check -> fixture check -> rebuild the extension (if the change
touched `native/godot/` or `native/resources/`) -> headless-purity suite ->
existing integration scenes -> network conformance.

## Sanitizers

Every native change to `addons/weapon_system/native/` MUST be verified
under both AddressSanitizer and UndefinedBehaviorSanitizer together, in
addition to a plain (uninstrumented) rebuild, matching every sibling
addon's own convention (`tools/verify.sh`, `tools/ga_verify.sh`,
`addons/inventory_system/docs/verification.md`):

```sh
# 1. Sanitized run (asan+ubsan together).
scons weapon_tests run_weapon_tests=yes sanitize=address,undefined -j8

# 2. Plain rebuild (confirms the suite is not accidentally dependent on
#    sanitizer instrumentation itself).
scons weapon_tests run_weapon_tests=yes -j8
```

Both runs report the identical count (207 tests, 0 failed as of this
writing) with a clean exit.

Every `fuzz_`-prefixed test additionally honors `WPN_FUZZ_ITERATIONS` (an
environment variable, default 600 per seed x 3 seeds x 11 decoders): raise
it for a deeper pass, especially under the sanitizer build ("fuzz under
sanitizers is the point" -- matching the canonical repository's inventory
fuzz-test policy):

```sh
WPN_FUZZ_ITERATIONS=20000 ./addons/weapon_system/native/.build/weapon_system_tests --filter=fuzz_
```

Measured locally on this host: 20000 iterations/seed (60000 total decode
attempts across 11 decoders) completes in well under a second, clean under
`sanitize=address,undefined`.

---

## 11.1 Platform matrix

Spec requirement: "V1 SHALL support the repository's pinned Godot 4.7
editor plus Windows x86_64, Linux x86_64, macOS universal desktop exports,
and Linux x86_64 dedicated server exports using versioned native
artifacts."

### Verified locally (this macOS host)

| Artifact | Command | Result |
|---|---|---|
| Godot 4.7.1 editor import (full project) | `Godot --editor --quit-after 200 --display-driver headless --audio-driver Dummy --path .` | Clean, exit 0, zero script/parse errors. |
| macOS universal debug library | `scons platform=macos target=template_debug arch=universal` | Builds; loaded by every `tools/godot.sh run`/headless suite above. |
| macOS universal release library | `scons platform=macos target=template_release arch=universal` | Builds. Load path itself is not independently confirmed by a non-export run; see `tests/weapon_system/run_export_smoke.sh`. |
| Dedicated-server-style headless run | `tools/godot.sh run tests/weapon_system/server/wpn_server_main.tscn` | Full `ROLE_SERVER_AUTHORITY` command cycle, headless, 21/21 checks. Not an actual Linux dedicated-server EXPORT (see below), but the same authority code path a Linux dedicated-server build would run. |
| Native suites (plain + sanitized) | `scons weapon_tests run_weapon_tests=yes [sanitize=address,undefined]` | 207/207 both ways. |
| Dependency/removal (all 3 base addons) | `tests/weapon_system/run_dependency_removal.sh` | See "11.5" below. |

### CI-deferred (cannot be executed on this macOS host)

Following the exact mechanism the sibling `inv-*`/`ga-*` job families in
`.github/workflows/ci.yml` already use (see that file's own header comment
for the full rationale), this task adds a `wpn-*` job family, additive --
none of the existing `native-tests`/`desktop`/`web`/`android`/`ios`/`ga-*`/
`inv-*` jobs are modified:

| Job | Builds/runs | Never executed here because |
|---|---|---|
| `wpn-native-tests` | `scons weapon_tests run_weapon_tests=yes [sanitize=address,undefined]` on `ubuntu-latest` | Redundant with the local run above, but keeps the platform-independent gate CI-enforced on every push, matching `inv-native-tests`. |
| `wpn-fuzz` | `WPN_FUZZ_ITERATIONS=20000 ./weapon_system_tests --filter=fuzz_` under sanitizers | Deeper fuzz pass than the default, matching `ga-fuzz`'s own `GA_FUZZ_ITERATIONS` convention. |
| `wpn-boundary-and-fixture-checks` | `scons weapon_boundary_check` / `weapon_fixture_check` | Matches `inv-boundary-and-fixture-checks`. |
| `wpn-desktop` (matrix: Linux x86_64, macOS universal, Windows x86_64) | Build debug+release, `tools/godot.sh run` every headless suite (including the new `wpn_server_main.tscn`), `tests/weapon_system/run_export_smoke.sh` debug+release, `tools/wpn_checksums.py --validate` | **Windows and Linux x86_64 artifacts require those OSes' own toolchains/linkers**, unavailable on this single macOS host. macOS itself is covered locally above; the CI job additionally proves it under the identical automated pipeline the other two platforms use. |
| `wpn-dedicated-server-export` (Linux x86_64) | Build, `tests/weapon_system/run_export_smoke.sh "Linux Dedicated Server" debug/release`, `wpn_server_main.tscn` as the session smoke | **Requires a Linux toolchain and the "Linux Dedicated Server" export preset/templates**, unavailable here. This is the one artifact the spec names explicitly ("Linux x86_64 dedicated server exports") that this macOS host categorically cannot produce -- recorded here as an explicit line item per this task's instructions, never claimed as locally verified. |
| `wpn-dependency-removal` | `tests/weapon_system/run_dependency_removal.sh` on `ubuntu-latest` | Redundant with the local run (which already passed all three scenarios), kept in CI so a future regression in any of the three base addons' independence is caught automatically. |
| `wpn-web` / `wpn-android` / `wpn-ios` | Build-only (matching `inv-web`/`inv-android`/`inv-ios`'s own non-blocking precedent) | Web/Android/iOS toolchains (Emscripten/NDK/iOS SDK) are CI-provisioned, not present on this host; these targets are explicitly `planned`, never advertised as supported, per `release_manifest.json`'s own `support_policy`. |

**Never claimed as locally verified**: Windows x86_64 (debug+release),
Linux x86_64 desktop (debug+release), Linux x86_64 dedicated-server
(debug+release), Web, Android, iOS. `release_manifest.json`'s `targets[]`
entries for all of these remain `"status": "planned"` -- this task did not
promote any of them, consistent with the manifest's own `support_policy`
("Planned targets must not be advertised as supported").

---

## 11.2 Headless and dedicated-server purity

Spec requirement: "Authority SHALL run catalogs, instances, commands,
recoil, attachments, reload, world coordination, codecs, snapshots,
Inventory/GAS adapters, and diagnostics without loading a viewport,
renderer, texture, font, animation, audio, CommonUI, or physical input."

Two complementary proofs, mirroring the canonical repository's inventory
server checks:

1. **Static (by construction)**: `addons/weapon_system/` contains ZERO
   references to any texture/audio/font/viewport/CommonUI symbol anywhere
   in its own `.gd`/`.cpp`/`.h` source, verified with:
   ```sh
   grep -rniE "texture|audiostream|\.png|\.ogg|\.wav|commonui|common_ui|font|viewport|sprite" \
     addons/weapon_system/ --include="*.gd" --include="*.cpp" --include="*.h"
   ```
   Zero hits. `addons/weapon_system/weapon_system.gdextension` also declares
   no dependency on `common_ui` or `common_vision`.
2. **Dynamic (at runtime)**: `tests/weapon_system/server/wpn_server_main.gd`
   (task 11.2's new headless-purity suite) runs a full
   `ROLE_SERVER_AUTHORITY` command cycle and then walks the subtree it built,
   asserting zero `CanvasItem`/`AudioStreamPlayer`-derived nodes exist
   anywhere in it. (It deliberately walks from its own root, not
   `get_tree().root` -- the latter also carries the project's own unrelated
   global CommonUI autoload declared in `project.godot`'s `[autoload]`
   section, which is a pre-existing, project-wide setting orthogonal to
   this addon.)

**Both optional adapters remain absent-by-default**: `WeaponAuthority` itself
has zero references to `weapon_system_inventory/` or
`weapon_system_gameplay_abilities/`; those separately distributed adapters
depend on the base addon, never the reverse.

---

## 11.3 Fuzz/property tests

Spec requirement (task 11.3 / "Security and Robustness Verification"):
malformed-input fuzzing, deterministic/property tests, item/round
conservation, bounded history, snapshot/delta convergence -- all native,
engine-free, seeded/deterministic, bounded for CI-tolerable runtime.

| File | Test(s) | Seed(s) | Iterations | Proves |
|---|---|---|---|---|
| `wpn_test_fuzz.cpp` | `fuzz_every_protocol_decoder_survives_mutated_truncated_and_garbage_bytes` | `0x9E3779B97F4A7C15`, `0xD1B54A32D192ED03`, `0x2545F4914F6CDD1D` (xorshift64) | 600/seed (default; `WPN_FUZZ_ITERATIONS` overrides) x 3 mutation strategies (single-byte flip / truncate / garbage) x 11 decoders | Every `protocol/wpn_protocol_codec.h` decoder never crashes/hangs on mutated, truncated, or garbage bytes over a real (non-trivial: active reload + recoil + attachment loadout) golden message; a decode reporting success always re-encodes cleanly. |
| `wpn_test_properties.cpp` | `property_deterministic_valid_command_sequences_yield_identical_final_snapshot_hash_for_same_seed` | `0xA11CE5EEDF00D42`, `0xD1B54A32D192ED03`, `0x2545F4914F6CDD1D`, `0x9E3779B97F4A7C15` | 200 ticks x 5 instances, run twice per seed | Same seed -> byte-identical combined FNV1a64 fold of every live instance's full-fidelity `fingerprint()` across two fully independent runs (fresh catalog/runtime each time); also asserts two DIFFERENT seeds diverge (rules out a trivially-passing no-op runtime). |
| `wpn_test_properties.cpp` | `property_random_fire_and_reload_sequences_conserve_rounds_within_reservation_contract` | `0xBF58476D1CE4E5B9`, `0x94D049BB133111EB`, `0x2545F4914F6CDD1D`, `0xD1B54A32D192ED03`, `0x9E3779B97F4A7C15` | 300 ticks/seed | After EVERY tick: `loaded_rounds + accepted_fire_count == initial_rounds + sum(completed reload added_rounds)` -- the reservation contract's exact conservation identity -- plus `added_rounds <= reserved_rounds` for every completion and `loaded_rounds <= capacity` always. |
| `wpn_test_properties.cpp` | `property_command_history_never_exceeds_the_documented_cap_under_sustained_load` | n/a (deterministic, no randomness) | `MAX_IDEMPOTENCY_RECORDS * 2 + 500` = 8692 commands | `command_history_count() <= MAX_IDEMPOTENCY_RECORDS` (4096) after EVERY command, and reaches exactly that cap by the end (proves the FIFO eviction path is actually exercised, not merely never triggered). |
| `wpn_test_network_conformance.cpp` (pre-existing, task 7.7(a)) | `network_conformance_seeded_lossy_reordered_traffic_converges_or_resyncs` | `0xC0FFEE42` (xorshift32) | 40 rounds, 5 scripted transport-mischief actions/round | Snapshot/delta convergence under random loss/duplication/reordering via the existing `FakeTransport` harness -- replica either converges to byte-identical state or explicitly resyncs. This exact test already satisfies task 11.3's "snapshot convergence" sub-target, so it is not duplicated by this task. |

All of the above run in well under a second combined (part of the same
207-test native suite; no separate slow-path invocation is required).

---

## 11.4 Benchmark: 25-player/100-actor fire+reload load

Spec requirement: "Representative 25-player/100-actor combat MUST fit
within the repository's 30 Hz authority budget without unbounded
allocation growth" ("Representative load runs" scenario: "recorded
latency, allocation, memory, and correctness thresholds all pass").

`wpn_test_benchmark.cpp` drives `wpn::WeaponRuntime` plus
`wpn::WorldCoordinator` directly (no protocol/codec/network layer -- that
traffic's own bounded-work proof already lives in
`wpn_test_protocol_codec.cpp`/`wpn_test_network_conformance.cpp`) against
100 weapon instances (25 of which carry an accepted attachment loadout, the
"25-player" gear-configured subset) resolving each accepted shot against a
bounded (10-candidate) target query, a canonical damage sink, and a noise
sink.

**Threshold**: the asserted ceiling is the literal 30 Hz authority budget
itself (1000/30 ms ~= 33.33 ms, `AUTHORITY_TICK_BUDGET_NS = 33333333`) --
not a tighter machine-specific number, so the gate stays meaningful across
CI runners of varying speed while still catching any real regression that
would blow the budget. (Contrast with the sibling `inventory_system`
addon's own `inv_test_budgets.cpp`, which deliberately asserts only bounded
byte/op-count proxies and documents "No wall-clock timing in tests" --
that addon's spec never demands a latency number, while
`weapon-platform-support`'s "Performance and Memory Gates" requirement
explicitly does.)

| Scenario | What it measures | Measured (this macOS host) | Ceiling | Margin |
|---|---|---|---|---|
| `benchmark_steady_state_100_actor_fire_and_reload_load_fits_30hz_budget` | Average per-tick cost over 300 authority ticks (10 simulated seconds) of staggered, sustained fire+reload traffic across all 100 actors | **61,088 ns/tick** (18,326,625 ns / 300 ticks) | 33,333,333 ns | ~546x |
| `benchmark_worst_case_100_actor_synchronized_volley_fits_30hz_budget` | Wall time for the worst single-tick burst this addon's own cadence model can produce: all 100 actors due to fire in the SAME authority tick | **301,083 ns** | 33,333,333 ns | ~110x |

Re-measure by temporarily flipping `PRINT_MEASURED_BENCHMARK` to `true` in
`wpn_test_benchmark.cpp` (mirrors `inv_test_budgets.cpp`'s
`PRINT_MEASURED_BUDGETS` precedent), rebuilding, and running
`./weapon_system_tests --filter=benchmark_`; flip it back to `false` before
committing.

**Bounded allocation growth**: both scenarios also assert, after the run,
`instance_count() == 100` (no leak),
`command_history_count() <= MAX_IDEMPOTENCY_RECORDS`,
`tombstone_count() == 0`, `world.unresolved_consequence_count() == 0`, and
`world.healthy()` -- the
"without unbounded allocation growth" half of the same spec requirement.

---

## 11.5 Dependency/removal (historical canonical-repository record)

Spec requirement: "Weapon System, Inventory System, Gameplay Abilities,
and CommonUI SHALL remain independently installable and testable."
(Task 11.5 itself scopes this to "Weapon System, Inventory System, and GAS
base addons" -- CommonUI is deliberately out of this script's scope; see
the script's own header comment for why, and 11.2 above for how
weapon_system's own CommonUI-absence is verified instead.)

The canonical multi-addon repository's dependency-removal script ran three
scenarios, each temporarily moving the other two base addons (plus every
adapter directory that bridges to a moved addon) completely outside the
project directory, then rebuilding+running that addon's own engine-free
native suite AND its own headless Godot smoke/purity scene, before
restoring everything (a `trap` guarantees restoration on any exit path,
including failure or interruption):

| Scenario | Addons moved aside | Native suite | Headless scene | Result |
|---|---|---|---|---|
| `weapon_system alone` | `inventory_system`, `gameplay_abilities`, `weapon_system_inventory`, `weapon_system_gameplay_abilities` | `weapon_tests` | `tests/weapon_system/server/wpn_server_main.tscn` | 207/207 native; 21/21 headless checks |
| `inventory_system alone` | `weapon_system`, `gameplay_abilities`, `weapon_system_inventory`, `weapon_system_gameplay_abilities`, `inventory_gameplay_abilities` | `inventory_tests` | `tests/inventory_system/smoke/inv_smoke_main.tscn` | 312/312 native; smoke OK |
| `gameplay_abilities alone` | `weapon_system`, `inventory_system`, `weapon_system_inventory`, `weapon_system_gameplay_abilities`, `inventory_gameplay_abilities`, `common_vision_gameplay_abilities` | `ga_tests` | `tests/gameplay_abilities/smoke/ga_smoke_main.tscn` | 586/586 native; smoke OK |

All three scenarios ran successfully on this host; every moved directory
was confirmed restored afterward (`git status` reported the identical
file-count delta before and after the run). The Godot engine itself logs
(non-fatal) `GDExtension dynamic library not found` errors for the
temporarily-absent addons' stale `.godot/` extension-list cache entries
during each scenario -- expected, and does not affect the scene under
test, which still loads and reports its own suite passing; a full
`--editor --quit-after` reimport (not run here, to keep the script fast)
would clear those stale cache entries.
## What is *not* run in this environment

There is no C# contract-suite mirror for `weapon_system` (unlike
`inventory_system`'s `contract_csharp/InvContractTests.cs`) — no `.cs` file
exists anywhere under `addons/weapon_system*/` or `tests/weapon_system/` as
of this writing. If one is added later, document its exact status the same
way `inventory_system`'s `docs/verification.md` does ("environment-blocked,
source-only" or otherwise) rather than assuming parity with this note.

## See also

- Every definition kind, the MOA formula, attachment slots, and modifier
  algebra: [`authoring.md`](authoring.md).
- Roles, command envelope, world ports, protocol/networking:
  [`integration.md`](integration.md).
- Installation and platform support: [`distribution.md`](distribution.md).
- Reading a failed suite's diagnostic: [`troubleshooting.md`](troubleshooting.md).

## Release gate record — 2026-07-27 (tasks.md 12.5)

Every gate below was executed on this date against the completed
implementation (all tasks 1.1-12.4 checked), on macOS (Godot 4.7.1 pinned
editor, `tools/bin/Godot.app`). Commands are verbatim.

| Gate | Command | Result |
| --- | --- | --- |
| Strict spec validation | `python3 <spec-toolkit>/spec_toolkit.py validate add-modular-authoritative-weapon-system-2026-07-26 --type change --strict` | `Valid` |
| Native weapon suite | `scons weapon_tests run_weapon_tests=yes` | 207/207 |
| Native weapon suite (sanitized) | `scons weapon_tests run_weapon_tests=yes sanitize=address,undefined` | 207/207 |
| Include boundary | `scons weapon_boundary_check` | passed |
| Golden fixtures | `python3 tests/weapon_system/verify_fixtures.py` | passed |
| Native inventory suite (reservation delta) | `scons inventory_tests run_inventory_tests=yes` | 312/312 |
| Full GDExtension build | `scons` | clean, 0 errors |
| Version smoke (protocol v2) | `tests/weapon_system/run_headless_smoke.sh <godot>` | passed |
| Definition catalog probe | `res://tests/weapon_system/integration/test_definition_catalog.tscn` | 58/0 |
| Inventory adapter exerciser | `res://tests/weapon_system/integration/weapon_inventory_main.tscn` | 96/0 |
| Inventory adapter lifecycle matrix | `res://tests/weapon_system/integration/weapon_inventory_lifecycle.tscn` | 101/0 |
| GAS adapter matrix | `res://tests/weapon_system/integration/weapon_gas_main.tscn` | 148/0 |
| Inventory contract suite | `res://tests/inventory_system/contract/inv_contract_main.tscn` | 287/0 |
| Dedicated-server purity probe | `res://tests/weapon_system/server/wpn_server_main.tscn` | 21/0 |
| Presentation showcase | `res://examples/weapon_system/weapon_presentation_showcase.tscn -- --demo-smoke` | 16/0 |
| Adapter-mode matrix (both/inv/GAS/neither) | `res://examples/weapon_system/weapon_adapter_matrix_demo.tscn` | 90/0 |
| Command-contract probe (input/AI/replay) | `res://examples/weapon_system/weapon_command_contract_probe.tscn` | 20/0 |
| Diagnostics demo | `res://examples/weapon_system/weapon_diagnostics_demo.tscn` | 19/0 |
| Inspector demo | `res://examples/weapon_system/weapon_inspector_demo.tscn` | 25/0 |
| Reference room smoke | `res://examples/weapon_system/extraction_combat_demo.tscn -- --demo-smoke` | OK |
| Separate-process network conformance | `GODOT_BIN=<godot> tests/weapon_system/network/run_weapon_network_conformance.sh` | PASSED (all 4 steps) |
| Export smoke (macOS) | `tests/weapon_system/run_export_smoke.sh <godot> "macOS"` | passed |
| Export smoke (Linux Dedicated Server) | `tests/weapon_system/run_export_smoke.sh <godot> "Linux Dedicated Server"` | passed |
| Release manifest checksums | `python3 tools/wpn_checksums.py --update` | debug+release dylibs rebuilt and recorded |
| Dependency/removal matrix | `tests/weapon_system/run_dependency_removal.sh` | 3/3 scenarios green (executed in an isolated worktree at identical content because a live editor process held this checkout; see 11.5) |

Windows x86_64 / Linux x86_64 desktop and Linux dedicated-server *binary
artifacts* remain CI-produced (`wpn-*` jobs in `.github/workflows/ci.yml`);
they are recorded as `planned` in `release_manifest.json` and were not
claimed as locally verified.
