# Distribution

Task 12.1 (tasks.md section 12: Distribution and documentation). What is
actually shipped, in what state, how a target earns the right to be called
"supported," the symbols policy as implemented today, the checksum workflow,
the pre-1.0 API/protocol policy, unsupported-target behavior, and the task
12.5 gate that keeps the API and protocol pre-1.0.

Cross-references, not duplicated here:
- [`verification.md`](verification.md) — how to run every test suite locally
  and in CI, and what each one proves.
- [`protocol.md`](protocol.md) — the wire codec, the handshake, the
  `ga_limits.h` constants table, and the versioning policy in full, including
  the `MAX_SNAPSHOT_BYTES` worked example this document cross-references
  below.
- [`../release_manifest.json`](../release_manifest.json) — the single
  authoritative, machine-readable source for every field this document
  describes in prose. If this document and the manifest ever disagree, the
  manifest is correct and this document is stale.
- [`../THIRD_PARTY_LICENSES.md`](../THIRD_PARTY_LICENSES.md) — full
  third-party attribution.

## The central rule

Per the platform-support spec's "Declared Client Artifact Matrix" and
"Headless Dedicated Server Support" requirements: **a target must not be
advertised as supported until its artifact loads and passes the applicable
export and multiplayer smoke tests.** This document and the manifest it
describes exist to make that rule checkable rather than aspirational. A
target that has not passed its tests is `planned` or `experimental` — never
`supported`.

## Artifact matrix and current state

Sixteen target entries in `release_manifest.json`: the client matrix (macOS
universal, Windows x86_64, Linux x86_64, Android arm64-v8a and x86_64, iOS
device (arm64) and simulator*, Web wasm32 — each debug and release), plus a
distinguished Linux x86_64 headless dedicated-**server** entry (debug and
release) required by "Headless Dedicated Server Support."

\* The manifest currently declares one iOS `arch: arm64` entry per build
type rather than separate device/simulator entries; `dependencies.json`'s iOS
toolchain section does not yet distinguish a simulator SDK target. Splitting
this into explicit `ios-device`/`ios-simulator` arch values is open follow-up
work, not something this task fabricates evidence for.

| Platform | Arch | Build | Role | `status` | `support_state` | What's actually been verified |
|---|---|---|---|---|---|---|
| macOS | universal | debug | client | `built` | **`experimental`** | Extension-load smoke (`tests/gameplay_abilities/smoke/ga_smoke_main.tscn`) passed against this exact artifact. Confirmed (by temporarily removing the release artifact and re-running) that this is the specific binary Godot's non-exported headless run resolves. |
| macOS | universal | release | client | `built` | **`experimental`** | Compiled and checksummed. Its own load path is *not* independently confirmed in this environment (see "Known verification gaps" below) — reported honestly rather than assumed identical to the debug artifact. |
| Windows | x86_64 | debug/release | client | `planned` | `planned` | No artifact built in this environment. |
| Linux | x86_64 | debug/release | client | `planned` | `planned` | No artifact built in this environment. |
| Linux | x86_64 | debug/release | **server** | `planned` | `planned` | No artifact built in this environment; see "Why a separate server entry" below. |
| Android | arm64-v8a, x86_64 | debug/release | client | `planned` | `planned` | No artifact built in this environment. |
| iOS | arm64 | debug/release | client | `planned` | `planned` | No artifact built in this environment. |
| Web | wasm32 | debug/release | client | `planned` | `planned` | No artifact built in this environment. |

**No target in this manifest is `supported` today.** Only macOS is even a
plausible candidate, and even it has not cleared the full bar (see below).

### Why a separate server entry

The dedicated-server export ("Linux Dedicated Server" preset,
`export_presets.cfg` `[preset.3]`, `dedicated_server=true`) is built from the
*same* GDExtension shared library as the ordinary Linux client entry — this
addon defines no custom feature tag to select a different binary for it, so
`gameplay_abilities.gdextension`'s `linux.debug.x86_64` /
`linux.release.x86_64` entries resolve identically either way. The manifest
still tracks it as a distinct target because the platform-support spec
requires it to be **separately verified**: a client Linux target earns
`supported` via extension-load smoke + headless integration tests + generic
export smoke, while the server role additionally requires
`tools/ga_export_smoke.sh "Linux Dedicated Server"` (debug and release) and
`tools/ga_dedicated_server.sh`'s startup/session smoke against
`examples/gameplay_abilities/dedicated_server.tscn` to pass before it can be
called `supported` — a binary that is a fine client artifact is not
automatically a proven dedicated server, and vice versa.

## How support state is earned

`release_manifest.json`'s `support_state_policy` object is the authoritative,
machine-readable version of this section:

- **`planned`** — declared intent only. No artifact has been built for this
  target, or (server role) the dedicated-server-specific smoke tests have
  not run against it.
- **`experimental`** — the artifact builds and there is direct evidence it
  loads (extension-load smoke passed for at least this build type), but
  export smoke and/or the role-applicable multiplayer/integration smoke test
  have not yet passed for this exact entry. Usable for development; never
  advertised to end users as supported.
- **`supported`** — all of the following, for this exact platform/arch/build/
  role combination:
  1. The artifact builds (`status` is `built` or `validated`, with a
     recorded `sha256`).
  2. The extension loads: `tests/gameplay_abilities/smoke/ga_smoke_main.tscn`
     passes against it.
  3. The exported package actually bundles the native library: the relevant
     export smoke test passes for *both* debug and release
     (`tools/export_smoke.sh` is CommonUI's own script and is never modified
     or reused here; `tools/ga_export_smoke.sh <preset> debug|release` is
     this addon's counterpart, and `tools/ga_export_smoke.sh "Linux
     Dedicated Server" debug|release` for the server role specifically).
  4. The role-applicable multiplayer/integration smoke test passes: headless
     integration tests (`tests/gameplay_abilities/integration/`) for client
     targets; additionally the dedicated-server startup/session smoke
     (`tools/ga_dedicated_server.sh`) and the multi-peer conformance suite
     (`tests/gameplay_abilities/network/run_multipeer_conformance.sh`) for
     the server role.
  5. Every entry that claims `supported` names the smoke test(s) that
     justify it in its `verified_by` array. An entry with `support_state:
     "supported"` and an empty `verified_by` is a manifest defect —
     `tools/ga_package_release.py --check` (and `--package`, which always
     runs the same check first) treats it as a hard error and refuses to
     package that target.

Promoting a target's build/checksum pipeline `status` to `validated` via
`tools/ga_checksums.py --validate <platform>` is **necessary but not
sufficient** for `support_state: "supported"`: `--validate` only proves the
artifact is present and checksummed after that platform's export smoke test
ran (see `ga-desktop`'s CI job), it does not know about the `role` field or
the dedicated-server-specific tests. `support_state` and `verified_by` are
the actual spec-facing gate; they are reviewed and updated deliberately
(today, by hand — `tools/ga_package_release.py --check` verifies internal
consistency but does not auto-promote `support_state`), not derived
mechanically from `status`.

### Known verification gaps (honest, not hidden)

- **Export smoke has not passed for any target.** Godot export templates are
  not installed in this environment; `tools/ga_export_smoke.sh macOS debug`
  currently reports `SKIP: export templates ... are not installed` (exit 3).
  CI (`ga-desktop`, `ga-dedicated-server-export`) installs templates and does
  not tolerate that skip for a declared target.
- **The multi-peer conformance suite exists and passes; the aggregate
  headless integration scene does not, yet.** `tests/gameplay_abilities/
  network/run_multipeer_conformance.sh` (tasks.md 11.3's multi-process,
  multi-peer requirement) is real and exercised by the `ga-multipeer` CI
  job. `tests/gameplay_abilities/integration/integration_main.tscn` — the
  separate aggregate scene the `ga-integration` job (and part of
  `ga-desktop`) expects — does not exist yet; it is being added separately
  this week. See `verification.md`'s CI table for exactly which `ga-*` jobs
  fail loudly because of this. No target can reach `supported` until it
  lands and passes.
- **The macOS release artifact's own load path is unconfirmed.** Godot's
  non-exported headless run (`tools/godot.sh run <scene>`) always resolves
  the `template_debug` artifact — confirmed empirically by temporarily
  removing each variant in turn while re-running the extension-load smoke
  scene. This means the release artifact's ability to load has not been
  directly observed in this sandbox; it is reported as unverified rather
  than assumed identical to the debug build. See its `notes` field in
  `release_manifest.json`.

## Compatibility metadata

Every target entry in `release_manifest.json` carries a `compatibility`
object (not just the top-level fields) so a future entry could diverge
without ambiguity:

```json
"compatibility": {
  "engine_compatibility_minimum": "4.7",
  "engine_compatibility_maximum": null,
  "engine_validated_against": "4.7.1-stable",
  "godot_cpp_commit": "5ffd70e34d0ab87009a9f0ffa3361bc8f4b09731",
  "api_version": "0.2.0",
  "protocol_version": 4,
  "manifest_algorithm": "fnv1a64-canonical-v1"
}
```

`engine_compatibility_maximum` is `null` because
`gameplay_abilities.gdextension`'s `[configuration]` block only sets
`compatibility_minimum = "4.7"` — there is no declared upper bound. The
`godot_cpp_commit` is the one pin shared with CommonUI
(`native/dependencies.json`'s note: "never a second incompatible binding
revision"). `api_version`, `protocol_version`, and `manifest_algorithm` must
agree with what the running native library itself reports through
`GameplayAbilityVersion` (`get_api_version()`, `get_protocol_version()`,
`get_manifest_algorithm()`) — `tests/gameplay_abilities/integration/
test_release_manifest.gd` asserts exactly this at runtime, so the manifest
can never silently drift from the compiled build.

## Symbols policy (as actually implemented today)

Read from `SConstruct` and this addon's tooling directly, not from intent:

- **`SConstruct` appends `-g` (macOS/iOS/Linux/Android/Web) or `/Zi` +
  `/DEBUG` (Windows/MSVC) for *every* GDExtension build type** — there is no
  branch that omits it for `template_release`. Every artifact this
  repository builds today, release included, embeds full debug symbols.
- **No stripping step runs anywhere in this repository as of this task.**
  Neither `tools/checksums.py`, `tools/ga_checksums.py`,
  `tools/export_smoke.sh`, `tools/ga_export_smoke.sh`, nor any
  `.github/workflows/ci.yml` job invokes a symbol-stripping, `dsymutil`, or
  side-car step for either addon. `SConstruct`'s own comment ("release
  symbols are stripped into a side-car by `tools/package_release.py` rather
  than discarded here") describes an *intended* step; that file did not
  exist anywhere in `tools/` before this task, and nothing in this repo
  invoked it. Both macOS artifacts currently in
  `addons/gameplay_abilities/bin/` — debug **and** release — carry embedded,
  unstripped symbols today, confirmed by inspection (their sizes track
  source size, not a stripped release binary's).
- **`tools/ga_package_release.py`** (new, this task) is the first thing in
  this repository that actually performs the stripping `SConstruct`'s
  comment describes, and only for gameplay-abilities (CommonUI's own
  packaging remains exactly as stale-referenced below). When it packages a
  `release` build it strips symbols into a `<artifact-filename>.debug`
  side-car next to the packaged copy **in its output directory**, never
  touching the source file under `bin/`:
  - macOS / iOS: `dsymutil` + `strip -x` (the dSYM output is zipped into one
    `.debug` side-car file for a single-extra-file-per-artifact convention).
  - Linux / Android: `objcopy --only-keep-debug`, then `--strip-debug
    --strip-unneeded`, then `--add-gnu-debuglink`.
  - Windows: left as-is — `/Zi` already emits symbols to a separate `.pdb`
    rather than embedding them, so there is nothing to strip out of the
    `.dll` itself.
  - Web/wasm32: left embedded — no stripping tool is assumed present in a
    wasm toolchain, and browser debugging tooling generally expects the
    unstripped module anyway.
  - `debug`-build artifacts are **never** stripped, by design, regardless of
    platform.
  - A missing stripping tool (e.g. no `dsymutil`/`objcopy` on a given
    packaging host) is treated as a packaging-environment gap, not a fatal
    error: the artifact is copied as-is and the summary reports that no
    side-car was produced for it.
  - This has been exercised end-to-end against the real macOS release
    artifact during this task's own verification (copy + `dsymutil`/`strip`
    succeeded, producing a `.debug` side-car, while the source `bin/`
    artifact's checksum was unchanged afterward) — but no artifact recorded
    in `release_manifest.json` has been packaged through it as part of an
    actual release yet, which is why every target's `"symbols"` field in the
    manifest still reads `"embedded"`.

### `tools/package_release.py` — checked, does not exist

`SConstruct`'s comment (`# side-car by tools/package_release.py rather than
discarded here`) references `tools/package_release.py` without the `ga_`
prefix — CommonUI's own hypothetical packaging script. It was checked for
directly:

```
$ find tools -iname '*package*'
(no output)
```

**It does not exist.** Neither addon has ever had a packaging/stripping
script in this repository; the comment describes an intended future step
that was never built, for either addon. `tools/ga_package_release.py` (this
task) is new, gameplay-abilities-specific tooling — it does not create, and
was not asked to create, a generic `tools/package_release.py` for CommonUI,
since `SConstruct` is off-limits to modify and CommonUI's own tooling is
explicitly out of this task's scope.

## Checksum workflow

`tools/ga_checksums.py` (already existing, not modified by this task) is
authoritative for the `status`/`sha256` pipeline fields:

```bash
python3 tools/ga_checksums.py --update              # sha256 present artifacts; planned -> built
python3 tools/ga_checksums.py --verify              # fail if a recorded checksum no longer matches
python3 tools/ga_checksums.py --validate <platform>  # promote present+checksummed targets of PLATFORM to 'validated'
```

`tools/ga_package_release.py --package` calls `tools/ga_checksums.py
--update` itself after copying (unless `--skip-checksum-update` is passed),
so the source manifest's checksums stay current with whatever is in `bin/`
at packaging time. `--validate` is a separate, deliberate step — CI's
`ga-desktop` job runs it only after that platform's export smoke passes.

## Licenses

- The addon itself: MIT (`LICENSE`).
- Third-party attribution: `THIRD_PARTY_LICENSES.md`. Summary: godot-cpp
  (MIT, pinned revision shared with CommonUI) is statically linked; Godot
  Engine itself is required but not redistributed.
- **No mandatory third-party gameplay or networking runtime.** This was
  verified by auditing every `#include` across `native/core/`,
  `native/protocol/`, `native/godot/`, and `native/resources/`: beyond the
  C++ standard library and the godot-cpp binding (required only in
  `native/godot/`/`native/resources/`), nothing else is included. No vendored
  GAS-alike framework, no third-party transport/serialization/compression
  library. The reference ENet harness under `examples/gameplay_abilities/
  net/` is game-layer GDScript calling Godot's own built-in
  `ENetMultiplayerPeer` — not a vendored dependency, and not part of the
  addon's native runtime (see the platform-support spec's "Game-Owned
  Network Transport" requirement).

## Pre-1.0 API and protocol policy

Per the platform-support spec's "Pre-1.0 API and Protocol Policy": the
current gameplay-ability build identifies its public API (`0.2.0`,
`GA_API_VERSION_MAJOR == 0`) and wire protocol (`GA_PROTOCOL_VERSION == 4`)
as pre-1.0. See `protocol.md`'s "Versioning" section for the full policy and
the complete `ga_limits.h` constants table; summarized here for the
distribution-facing view:

- **What forces a protocol-version bump:** a change to **required packet
  meaning or the canonical wire encoding** — anything `protocol.md` documents
  as wire layout. `decode_message` rejects any peer whose
  `protocol_version` does not exactly match the running build's; there is no
  forward/backward-compatibility window (mixed sessions fail the
  handshake explicitly, per the "Compatible implementation fix ships" /
  "Packet schema changes incompatibly" scenarios).
- **Protocol-2 boundary:** Ability Tasks and Typed Targeting add required
  messages, codecs, snapshot sections, feature flags, and a 131,072-byte
  snapshot cap. That wire-relevant change deliberately bumps protocol 1 to
  2; mixed peers fail before gameplay state is exchanged.
- **Protocol-3 boundary:** the observable-task observer wire path adds a
  bounded, whitelisted observable-task section to the public
  `encode_public_state` payload, gated by the new required
  `FeatureSet::OBSERVER_TASK_STATE` feature bit. That wire-relevant change
  deliberately bumps protocol 2 to 3; mixed peers (a peer built before this
  change, talking to one built after) fail the handshake closed before
  gameplay state is exchanged, exactly like the protocol-2 boundary above.
- **Protocol-4 boundary:** granular delta replication changes the MEANING of
  an owner `EVENT_BATCH` payload (canonical delta, not a full snapshot),
  replaces the observer's per-tick unsequenced full public envelope with a
  sequenced public delta stream, and adds the `HEARTBEAT` message type,
  gated by the new required `FeatureSet::DELTA_REPLICATION` feature bit.
  That wire-relevant change deliberately bumps protocol 3 to 4; mixed peers
  fail the handshake closed before gameplay state is exchanged, exactly
  like the protocol-2 and protocol-3 boundaries above.
- **What does not force a bump:** an internal implementation change that
  preserves required packet meaning and canonical encoding.
- **Migration impact:** breaking resource, API, manifest, or packet changes
  document their migration impact in `protocol.md` and this file's revision
  history (tracked via normal commit history in this pre-1.0 phase; a
  dedicated CHANGELOG is a reasonable follow-up once the API stabilizes past
  0.x).

### Revision note: global definition catalog and tag reactions (`add-global-tag-catalog-and-reactions-2026-07-25`)

Originally landed before the Ability Task/Typed Targeting `0.2.0` /
protocol-2 boundary. It widens both manifest and snapshot surfaces:

- **Manifest**: adds `ManifestEntryKind::REACTION` (value 6, appended after
  `TARGET_SCHEMA` — see `authoring.md`'s "How definitions feed the content
  manifest"). A catalog with no `tag_reactions` contributes none, so an
  unrelated project's fingerprint is unaffected; a project that adopts
  reactions gets a fingerprint that already differs from any earlier build
  that predates this change, which is exactly the handshake behavior
  `reactions.md`'s "Manifest fingerprinting" documents and depends on.
- **Snapshot wire format**: canonical component snapshots now include active
  `WHILE_PRESENT` reaction bindings (see `reactions.md`'s "Snapshot and
  restore: no replay"). A snapshot written by a build before this change
  simply has no bindings to restore; a snapshot written after this change by
  a component with no reactions is byte-identical to before.
- **New authoring surface**: `GameplayDefinitionCatalog`,
  `GameplayTagReactionDefinition`, the project setting
  `gameplay_abilities/default_definition_catalog`, and
  `GameplayAbilityComponent.definition_catalog` are all additive — no
  existing exported property, method, or signal was removed or repurposed.

**Migration window (pre-1.0)**: the project catalog is now the *documented
default* authoring path (`authoring.md`'s "The project definition catalog: identity
vs. runtime state") — new content should be authored into a catalog, not the
legacy per-component arrays. Those legacy arrays remain **fully supported**
for any existing scene that resolves no catalog; they are not deprecated,
scheduled for removal, or silently migrated. A component may not mix a
resolved catalog with a populated legacy array (`authoring.md`'s "Mixed
catalog/legacy configuration is rejected") — that failure is intentional,
not a bug to route around. Per proposal.md's "Compatibility": legacy support
remains through the current pre-1.0 line; removing it is out of this
change's scope and would require its own breaking-change proposal once this
addon approaches 1.0.

### Revision note: Ability Tasks and Typed Targeting (`0.2.0`, protocol 2)

These paired changes are an additive Godot API release and an intentionally
breaking wire revision:

- API `0.2.0` adds task requests/events, task hook continuation, typed target
  wrappers, the world coordinator, provider/session APIs, and bridge
  task/target commands.
- Protocol `2` adds message types 9–13, task/target codecs and restore state,
  negotiated `ABILITY_TASKS`/`TYPED_TARGETING` features, and the enlarged
  snapshot bound.
- Existing entity-list authoring remains available through a registered
  typed `ENTITY_SET` legacy adapter. Manual `pending_remote_effects` routing
  remains callable but is deprecated in favor of coordinator batches.
- Protocol-1 peers fail closed; there is no downgrade or partial mode.

### Revision note: Observer task state replication (`0.2.0`, protocol 3)

An additive Godot API change and an intentionally breaking wire revision:

- API: `public_state_updated`'s Dictionary payload gains one additive key,
  `observable_tasks` (an `Array` of `Dictionary` entries — see `protocol.md`'s
  "Task state visibility" section for the exact shape). No existing exported
  property, method, signal, or dictionary key was removed or repurposed.
- Protocol `3` adds the observable-task section to the public
  `encode_public_state`/`decode_public_state` payload and the negotiated
  `OBSERVER_TASK_STATE` feature (required, mirroring how `ABILITY_TASKS`/
  `TYPED_TARGETING` shipped with protocol 2).
- The section is a whitelist projection (`ObserverTaskRecord`), never a
  sanitized copy of the full task state: only stable task handle, owning
  execution identity, owning ability identifier, task kind, and start/
  deadline ticks cross the wire to an observer. Prediction keys, change
  provenance, command/input sequences, tag queries, logical input
  identities, authority prediction keys, and target schemas are never
  encoded in this section, by construction.
- Hidden-ability suppression (`hidden_ability_identifiers`) applies to this
  section exactly as it already applies to the public grant list: a task
  whose owning ability is hidden is omitted entirely, never with a blanked
  identity.
- Protocol-2 (and protocol-1) peers fail closed at the handshake; there is
  no downgrade or partial mode. No persisted-data migration is needed —
  canonical component snapshots (the data an owner restores) are unchanged;
  only the public observer payload's layout changed.

### Revision note: Granular delta replication (`0.2.0`, protocol 4)

An additive Godot API change (no new bound Godot-facing methods/signals —
see "Godot-facing API" below) and an intentionally breaking wire revision:

- Protocol `4` changes the owner `EVENT_BATCH` payload from a full canonical
  component snapshot to a canonical granular delta (dirty snapshot sections
  as record-level add/update/remove operations, or a whole-section
  re-encode when churn crosses a documented threshold), replaces the
  observer's per-tick unsequenced full public envelope with a sequenced
  public delta stream sharing the SAME codec, and adds one new message type
  (`HEARTBEAT`, a bounded 16-byte liveness/tick-alignment payload sent at a
  documented cadence while a peer's state is unchanged). All of this is
  gated by the negotiated, required `FeatureSet::DELTA_REPLICATION` bit
  (mirroring how `ABILITY_TASKS`/`TYPED_TARGETING` shipped with protocol 2
  and `OBSERVER_TASK_STATE` with protocol 3).
- **Godot-facing API**: additive only. `GameplayAbilityComponent::
  resolve_ability_identifier(id)` (task 4.2) is one new bound method —
  `DefinitionId -> identifier`, the same resolver shape
  `resolve_tag_identifier`/`resolve_attribute_identifier` already had; the
  observer-side scratch mirror's public-state decode needs it to resolve a
  mirrored grant's ability identifier without its own `AbilityRegistry`
  reference (see `api.md`). No property, method, or signal was removed or
  repurposed. `public_state_updated`'s Dictionary payload shape is
  unchanged — the observer feed is now assembled from sequenced delta
  batches instead of a per-tick full envelope, but the decoded surface a
  game script observes is identical. `set_hidden_attribute_identifiers`/
  `set_hidden_tag_identifiers`/`set_hidden_ability_identifiers` (pre-existing
  setters) now ALSO drive the delta codec's own PUBLIC-audience filtering in
  addition to the legacy `encode_public_state` filtering they already drove —
  a behavioral widening of an existing setter, not a new one.
- **Wire-level correctness fix included in this bump**: a stream's sequence
  no longer advances for a batch that was never actually sent — see
  `protocol.md`'s "Owner event-batch delta path and the `SNAPSHOT` fallback"
  for the `event_batch_fits_stream` guard this generalizes from the
  full-snapshot-as-batch shape to the delta shape.
- Protocol-3 (and earlier) peers fail closed at the handshake; there is no
  downgrade or partial mode. No persisted-data migration is needed: a
  canonical component snapshot (the data a fresh `SNAPSHOT`/baseline
  restores) is unchanged in shape — only the routine per-tick `EVENT_BATCH`/
  observer payload's meaning changed.

## Unsupported-target behavior

Per the platform-support spec's "Required Native C++ Runtime" and "Godot and
Binding Compatibility" requirements, and enforced today by
`tests/gameplay_abilities/smoke/ga_smoke_main.gd` and the addon having *no*
GDScript fallback path anywhere in `runtime/` or `editor/`:

- **A target with no matching native library**: Godot's own GDExtension
  loader reports a missing library; the addon defines no compatibility
  shim and no pure-GDScript reimplementation of `GameplayAbilityComponent`
  or the protocol. Gameplay does not continue under a script fallback with
  different authority behavior — there is no such fallback to fall back to.
  This is a deliberate absence, not an oversight: task 1's foundation work
  and every later task were built against this constraint from the start.
- **An incompatible Godot build**: `compatibility_minimum` in
  `gameplay_abilities.gdextension`'s `[configuration]` block causes Godot
  itself to refuse to load the extension before any gameplay session begins,
  per "Incompatible Godot build loads the artifact." `GameplayAbilityVersion`
  additionally exposes the compiled API/protocol/manifest versions so a
  higher-level compatibility check (e.g. a lobby/matchmaking layer) can fail
  fast with the expected range, rather than discovering a mismatch mid-game.
- **What this addon explicitly does NOT do**: silently degrade to a
  different, less-authoritative code path, retry against a lower protocol
  version, or substitute a partial/emulated implementation. Both the
  extension-load smoke test and this policy treat "the artifact is missing
  or incompatible" as a hard, actionable failure — the diagnostic names the
  missing class/manifest entry (see `ga_smoke_main.gd`'s failure messages)
  rather than leaking raw untrusted state or silently continuing.
- **Export-time validation**: "Export selects a wrong architecture" (spec
  scenario) is exercised today by `tools/ga_export_smoke.sh`, which fails the
  whole export smoke step (not just a warning) if the exported package does
  not actually contain `libgameplay_abilities.*` for the target preset —
  "export succeeded" is never treated as proof the native library shipped.

## Task 12.5 gate: staying pre-1.0

Per tasks.md 12.5 and the platform-support spec's "Pre-1.0 API and Protocol
Policy": **the API and protocol stay pre-1.0 (major version `0`) until both**:

1. **The reference vertical slice** (tasks.md section 10: Dash, Poison,
   Stun, Heal) passes its full conformance run — loopback and direct-IP ENet,
   offline/listen-server/dedicated-server/late-join/disconnect-reconnect/
   relevance-loss-and-regain modes, and predicted-cue confirmation/
   cancellation without duplicate irreversible presentation.
2. **A second representative game integration** exercises the same public
   API and protocol independently of the reference project and passes the
   same conformance tests.

As of this writing, section 10 (the reference vertical slice — Dash,
Poison, Stun, and Heal, run offline, over loopback and direct-IP ENet, in
listen-server/dedicated-server/late-join/disconnect-reconnect/relevance-
loss-and-regain modes, with predicted-cue confirmation/cancellation — tasks
10.1–10.8) is complete and checked off in `tasks.md`, demonstrated by
`examples/gameplay_abilities/slice/`. **The gate's second condition does
not**: no second representative game integration exists yet, so this gate
stays unmet on that basis alone. `GA_API_VERSION_MAJOR` is `0` and stays
there — this is enforced by convention and by `ga_smoke_main.gd`'s own
assertion (`get_api_version_major() != 0` is treated as a smoke-test
failure) rather than by a version-bump gate elsewhere in the build, since
there is currently only one implementation of the version constants
(`native/core/ga_limits.h`) for the smoke test to check against.
