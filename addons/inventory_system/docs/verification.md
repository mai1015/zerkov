# Verification

How to build the extension and run every test suite that verifies this
Godot façade slice, what each one proves, and the current status of the
C# contract-suite mirror. `addons/inventory_system/release_manifest.json`
remains the authoritative, up-to-date source for exactly which platform
artifacts have passed their required smoke tests — do not infer platform
support from this document.

## Building the extension

```sh
scons platform=macos target=template_debug arch=universal -j8
scons platform=macos target=template_release arch=universal -j8
```

Godot's non-exported headless run always resolves the `template_debug`
artifact — every suite below that runs through `tools/godot.sh` exercises
the debug artifact. The release artifact's own load path is not
independently confirmed by any suite in this repository (matches
`release_manifest.json`'s own release-target note); treat it as unverified
for load-path purposes until an export-release smoke test exists.

## Suites, in dependency order

| Suite | Command | Proves |
|---|---|---|
| Engine-free native suite | `scons inventory_tests run_inventory_tests=yes -j8` | The entire `native/core/`, `native/protocol/`, and `native/examples/` layer, with NO Godot engine or GDExtension loaded at all — the fastest, most isolated signal. Includes `inv_test_transactions.cpp` (the ONLY place `StatusCode.STATUS_REVISION_MISMATCH`/`conflicting_inventory`/`authoritative_revision` is actually exercised — see [`integration.md`](integration.md)'s "Authority boundary" for why the Godot façade cannot reach that path itself), plus staged-discovery state, authenticated gateway/session admission, protocol conformance, recipient-isolation, replay, malformed-input, and fuzz coverage. Current evidence: **373/373 passed**. |
| Engine-free ASan+UBSan suite | `scons inventory_tests run_inventory_tests=yes sanitize=address,undefined -j8` | The same native coverage under AddressSanitizer and UndefinedBehaviorSanitizer. Current evidence: **373/373 passed with no sanitizer diagnostics**. |
| Include-boundary check | `scons inventory_boundary_check` | `native/core/` and `native/protocol/` never `#include` a Godot header. Current evidence: **pass**. |
| Fixture check | `scons inventory_fixture_check` | `tests/inventory/fixtures/zerkov_v1/*.json` still parse and match `tests/inventory/verify_fixtures.py`'s expectations. Current evidence: **pass**. |
| Godot import | `tools/godot.sh import` | Re-imports the project and refreshes `.godot/` through the pinned Godot 4.7.2 standard build. Current evidence: **pass**. |
| Extension-load smoke | `tools/godot.sh smoke` | The GDExtension loads and exposes the expected façade surface, including API version **0.4.0**, authenticated gateway surface, and observer role safety. Current evidence: **pass**. |
| **Authenticated gateway contract suite** | `tools/godot.sh run tests/inventory_system/gateway/inv_gateway_main.tscn` | Gateway server-role/configuration, trusted peer/session/actor/epoch admission, exact hello/readiness, default-deny command classes, grants, canonical identity replacement, normalized exact replay, policy ordering, retained-byte/rate/bounds, reconnect-budget preservation, owner/observer resync scope and metadata, mixed-scope result redaction, lifecycle invalidation, and trusted egress. Current evidence: **939/939 passed**. |
| **Façade contract suite (GDScript)** | `tools/godot.sh run tests/inventory_system/contract/inv_contract_main.tscn` | The full Godot-facing contract suite, including recipient-safe observer bootstrap/delta/resync behavior. Current evidence: **522/522 passed**. |
| Staged-discovery façade suite | `tools/godot.sh run tests/inventory_system/discovery/inv_discovery_main.tscn` | Recipient-bound discovery flows, stale/reconnect/teardown behavior, mutation reconciliation, policy bounds, and resource contracts. Current evidence: **197/197 passed**. |
| Component/state harness | `tools/godot.sh run tests/inventory_system/harness/inv_harness_main.tscn` | The full primitive×state matrix plus resolution×UI-scale×density geometry/hit-target/overflow coverage. Current evidence: **6140/6140 passed**. |
| Presentation model + controls suite | `tools/godot.sh run tests/inventory_system/presentation/inv_presentation_main.tscn` | `InventoryPresentationModel`, renderer registry, container controls, discovery rendering handoff, and state coverage. Current evidence: **654/654 passed**. |
| Interaction controller suite | `tools/godot.sh run tests/inventory_system/presentation/inv_interaction_main.tscn` | Drag/drop/rotate/split/merge/swap/quick-transfer/auto-place/inspect/context-action/cancel and keyboard/gamepad traversal. Current evidence: **1601/1601 passed**. |
| Icon registry suite | `tools/godot.sh run tests/inventory_system/icons/inv_icons_main.tscn` | Every declared state/action token resolves and every shipped SVG is registered. Current evidence: **193/193 passed**. |
| **Dedicated-server operation suite** | `tools/godot.sh run tests/inventory_system/server/inv_server_main.tscn` | Headless authority-only (`ROLE_SERVER_AUTHORITY`) command/snapshot/delta/persistence cycle plus replica role safety. Current evidence: **113/113 passed**. |
| Integration probe, vertical slice, CommonUI adapter, and Gameplay Abilities adapter suites | Separate scene commands | **Not run in this final metadata pass; no current result is claimed here.** |

The final Task 4.6 evidence recorded above covers native plain and sanitized
runs, boundary/fixture checks, debug+release macOS universal builds, Godot
4.7.2 import, API 0.4.0 smoke, the authenticated gateway contract, the full
GDScript façade contract, discovery, harness, presentation, interaction,
icons, and dedicated-server operation. The integration probe, vertical slice,
CommonUI adapter, and Gameplay Abilities adapter suites were not run in this
pass and are not represented as passing.

## Sanitizers

Every native change to `addons/inventory_system/native/` MUST be verified
under both AddressSanitizer and UndefinedBehaviorSanitizer together, in
addition to a plain (uninstrumented) rebuild:

```sh
# 1. Sanitized run (asan+ubsan together, matching every sibling addon's own
#    convention -- tools/verify.sh, tools/ga_verify.sh).
scons inventory_tests run_inventory_tests=yes sanitize=address,undefined -j8

# 2. Plain rebuild (confirms the suite is not accidentally dependent on
#    sanitizer instrumentation itself, and that release builds are unaffected).
scons inventory_tests run_inventory_tests=yes -j8
```

Both runs must report the identical count (373/373 passed in the current
evidence) with a clean exit. `sanitize=address,undefined` instruments both
`CXXFLAGS` and `LINKFLAGS` for the engine-free test binary only (see
`SConstruct`'s `inv_test_env` block) — it does not touch the GDExtension
shared-library build, matching every sibling addon (`tests`/`ga_tests`/
`weapon_tests`/`vision_tests` share the same convention).

**ThreadSanitizer is not applicable** and is deliberately not part of this
policy: this addon's entire native core is a documented single-threaded,
main-thread-only contract (`integration.md`'s "Single-threaded / main-thread
contract" — `inv::InventoryTransactionPipeline`, `inv::InventoryRuntime`, and
every other core/protocol type are plain, non-thread-safe C++ objects with no
internal locking, by design). Running TSan over code that is never
concurrently accessed by contract would not exercise anything TSan is built
to catch; a future concurrent core would need this policy revisited, not
retrofitted onto the current one.

A transient `container-overflow` (or any other sanitizer finding) appearing
under load/build contention with other concurrent `scons` invocations is NOT
an acceptable explanation to fall back on if a real run reports one — treat
any sanitizer finding from a solo, uncontended run as a genuine bug and stop
to report it rather than re-running until it disappears. (This addon's own
sanitized run above was executed as the only `scons` invocation in the
repository at the time, specifically to rule that out; it was clean.)

## The GDScript contract suite (`tests/inventory_system/contract/`)

`inv_contract_main.gd` + `.tscn`, following the same self-contained check-
count/fail-list pattern as `inventory_probe.gd` and
`inv_smoke_main.gd` (a top-level `Node` script, `_checks`/`_failures`
counters, `get_tree().quit(0 or 1)`). It SUPERSETS the probe rather than
replacing it (the probe stays untouched per this task's explicit
instruction). Coverage, in the order the suite runs it:

1. **Version queries** — every `InventoryCatalog` version getter compared
   directly against a parsed `release_manifest.json`.
2. **Catalog registration** — a full 9-resource-type authoring catalog (all
   3 layout kinds, named-slot filters, container access/retention policy,
   item traits, profile limits) built in code and registered via
   `register_catalog_resource()`.
3. **`validate_resource()` diagnostics** — a bad (non-namespaced) identifier,
   an "ambiguous" (zero-dimension) spatial-grid layout, a duplicate
   identifier, and an unknown trait reference (the deferred-to-`seal()`
   case — see [`authoring.md`](authoring.md)'s validation-timing table),
   plus the pre-existing unrecognized-Resource-type and `null` cases.
4. **Post-seal registration rejection** — every `register_*()` call and a
   second `seal()` call after the catalog is already sealed.
5. **Manifest fingerprint stability and registration-order independence** —
   two separately built, field-identical catalogs fingerprint identically;
   a fully group- AND element-order-reversed registration (mirroring
   `native/examples/inv_example_profiles.cpp`'s own reverse-order proof)
   fingerprints identically too.
6. **7.2 mutation isolation** — every field of every registered authoring
   Resource (trait schemas, items, containers, nested constraints/named
   slots, profiles, nested limits) is mutated AFTER `seal()`; the sealed
   catalog's `manifest_fingerprint()` — and, by every later test in the
   suite continuing to operate correctly against that same catalog,
   its behavior — is unaffected.
7. **Every `InventoryAuthority` command method** — `move_item`, `rotate_item`,
   `split_stack`, `merge_stacks`, `insert_item`, `remove_item`, `equip_item`,
   `unequip_item`, `swap_items`, `auto_place_item`, `quick_transfer_item`,
   `loot_item`, `drop_item`, `settle_inventory`, `assign_reference`,
   `clear_reference`, `set_item_component`, `remove_item_component` — asserting the result Dictionary's full documented
   shape, the correct `TransactionEventKind`, and revision advancement.
8. **The rejection contract** — occupied destination (`PLACEMENT_OVERLAP`),
   filter rejection (`FILTER_TRAIT_MISMATCH`), access rejection
   (`ACCESS_DENIED`, using the newly bound
   `InventoryContainerConstraints.ACCESS_*` names to author the restricted
   container), and idempotent duplicate replay (`replayed == true`, zero
   events, `DUPLICATE_RESULT_REPLAY`). Stale-revision rejection is
   DELIBERATELY not exercised — see [`integration.md`](integration.md)'s
   explanation of why it is structurally unreachable through this façade,
   with a shape-contract check in its place.
9. **Snapshots and observer views** — owner-only canonical byte/hash stability,
   local/debug non-owner projection, recipient-safe observer bootstrap, opaque
   handles, aggregate-only redaction, and the observer node's read-only role
   boundary. Non-owner projected `InventorySnapshotResource.canonical_bytes()`
   is empty and is never transmitted or used for canonical restore.
10. **Deltas and resync** — canonical fresh-replica convergence plus the
    observer full-replacement predecessor-gap → `needs_resync()` →
    `resync_request_bytes()` → snapshot-heal cycle, and duplicate-delta
    no-ops.
11. **Persistence** — `make_persistence_record()` → a second, independent
    `InventoryAuthority` → `apply_persistence_record()` → byte-identical
    canonical state.

Every accepted-command signal (`transaction_committed`, `delta_ready`) and
every replica signal (`snapshot_replaced`, `resync_needed`) is asserted to
fire the documented number of times with the documented payload shape as
part of the sections above, rather than as a separate pass. `delta_ready` is
server-local evidence only; raw multi-inventory authority bytes are never
treated as client egress, which is verified through the gateway's
per-session/per-inventory permission-filtered paths.

## C# suite status: unavailable in this workspace

`tests/inventory_system/contract_csharp/InvContractTests.cs` remains the source
parity reference, but it was **not compiled or run** for this verification:
the workspace contains no `.csproj`, `.sln`, or `.slnx` despite the installed
`.NET SDK 10.0.302`. The pinned Godot 4.7.2 standard binary also has no
.NET/Mono support. No C# pass count is claimed; run it only after a Godot
.NET runner and project file are supplied.

## Generated documentation

`tools/bin/Godot.app`'s `--doctool` flag DOES work headlessly against this
project and this extension build (confirmed: `godot --headless --path .
--doctool <out_dir> --gdextension-docs` produces one XML file per bound
class — all 22 of `InventoryCatalog`, `InventoryAuthority`,
`InventoryNetworkGateway`, `InventoryReplicaNode`, `InventoryObserverReplicaNode`,
`InventorySnapshotResource`, and the 9 authoring `Resource` classes plus 7
discovery `Resource` classes). See
[`generated/README.md`](generated/README.md) for
what that output does and does not add over the hand-written docs in this
directory, and how to regenerate it.
