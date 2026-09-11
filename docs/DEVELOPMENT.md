# Zerkov Development Baseline

The Stage 2 gameplay slice uses Godot `4.7.2.stable.official.ed1daf0bf` with
the Compatibility renderer. The exact local baseline is machine-readable in
[`config/toolchain.lock.json`](../config/toolchain.lock.json); all six add-ons
share `godot-cpp` commit `5ffd70e34d0ab87009a9f0ffa3361bc8f4b09731`.

Set an alternate executable only when it reports the exact pinned version:

```sh
export ZERKOV_GODOT=/Volumes/Data/sdk/godot/editors/4.7.2/Godot.app/Contents/MacOS/Godot
python3 tools/check_toolchain.py
```

The validated macOS host is arm64 with SCons 4.10.1, Apple Clang 21, Xcode
26.4 and the macOS 26.4 SDK. The accepted minimums remain those declared by
the add-ons: Python 3.8, SCons 4.7, Apple Clang 15 and macOS SDK 14.

## Current UI verification scope (2026-09-10)

The active first-playable UI and visual-verification target is exact
1920×1080. Current agents, runners and tests MUST NOT invoke smaller windows,
responsive/compact suites or regenerate their captures. Existing smaller
reports, PNGs and dedicated sources remain immutable historical evidence and
may be reopened only by task 11.8 or a later approved display-support proposal.
The post-acceptance scope results for this enforcement change are recorded in
[`docs/qa/1080-only-scope.md`](qa/1080-only-scope.md); prior task 8.1/8.2 source
seals remain valid only for their recorded immutable commits.

## Locked add-on workflow

The project runs the snapshots under `addons/`; it never loads directly from
the mutable SDK workspace.

```sh
python3 tools/vendor_addons.py check --scope destination
python3 tools/vendor_addons.py check --scope source
python3 tools/vendor_addons.py apply --dry-run
python3 tools/vendor_addons.py apply
```

`check --scope source` is expected to fail after an SDK package changes. Review
the change and intentionally update `config/addons.lock.json` before applying
it. `apply` stages and verifies all six packages before replacing any existing
snapshot; it rejects an unlocked tree or native artifact.

## Foundation verification

```sh
$ZERKOV_GODOT --headless --editor --path . --audio-driver Dummy --quit-after 120
$ZERKOV_GODOT --headless --path . --audio-driver Dummy \
  --script res://tests/addons/combined_addons_smoke.gd
$ZERKOV_GODOT --headless --path . --audio-driver Dummy \
  --script res://tests/common_ui_integration_smoke.gd
$ZERKOV_GODOT --headless --path . --audio-driver Dummy \
  --script res://tests/ui_smoke.gd
python3 -m unittest tests/addons/test_vendor_addons.py
```

The typed empty-raid authority contracts are:

```sh
$ZERKOV_GODOT --headless --path . --audio-driver Dummy \
  --script res://tests/raid/identity_contract.gd
$ZERKOV_GODOT --headless --path . --audio-driver Dummy \
  --script res://tests/raid/units_clock_contract.gd
$ZERKOV_GODOT --headless --path . --audio-driver Dummy \
  --script res://tests/raid/session_lifecycle_contract.gd
$ZERKOV_GODOT --headless --path . --audio-driver Dummy \
  --script res://tests/raid/authority_replay_contract.gd
$ZERKOV_GODOT --headless --path . --audio-driver Dummy \
  --script res://tests/raid/inventory_catalog_contract.gd
$ZERKOV_GODOT --headless --path . --audio-driver Dummy \
  --script res://tests/raid/inventory_authority_contract.gd
$ZERKOV_GODOT --headless --path . --audio-driver Dummy \
  --script res://tests/raid/inventory_intent_adapter_contract.gd
$ZERKOV_GODOT --headless --path . --audio-driver Dummy \
  --script res://tests/raid/inventory_projection_contract.gd
$ZERKOV_GODOT --headless --path . --audio-driver Dummy \
  --script res://tests/raid/inventory_mutation_routing_contract.gd
$ZERKOV_GODOT --headless --path . --audio-driver Dummy \
  --script res://tests/raid/equipped_item_reconciliation_contract.gd
$ZERKOV_GODOT --headless --path . --audio-driver Dummy \
  --script res://tests/raid/inventory_ability_reconciliation_contract.gd
$ZERKOV_GODOT --headless --path . --audio-driver Dummy \
  --script res://tests/combat/content_contract.gd
$ZERKOV_GODOT --headless --path . --audio-driver Dummy \
  --script res://tests/raid/profile_store_contract.gd
```

Godot may return exit code zero for a script parse error, so a run is successful
only when its named `*_RESULT` line reports zero failures and console output has
no `SCRIPT ERROR`, `ERROR`, or extension-load failure. The current inventory
and authority evidence includes these named zero-failure lines:

```text
INVENTORY_MUTATION_ROUTING_RESULT checks=146 failures=0
INVENTORY_INTENT_ADAPTER_RESULT checks=162 failures=0
INVENTORY_PROJECTION_RESULT checks=99 failures=0
INVENTORY_CATALOG_RESULT checks=537 failures=0
INVENTORY_AUTHORITY_RESULT checks=79 failures=0
AUTHORITY_REPLAY_RESULT checks=81 failures=0
EQUIPPED_ITEM_RECONCILIATION_RESULT checks=123 failures=0
INVENTORY_ABILITY_RECONCILIATION_RESULT checks=546 failures=0
IDENTITY_CONTRACT_RESULT checks=18442 failures=0
COMBAT_CONTENT_RESULT checks=79 failures=0
```

## ProfileStore checkpoint (task 7.9)

The game-owned profile boundary is documented in
[`game/profile/README.md`](../game/profile/README.md). Its promoted contract
covers canonical bytes, strict malformed/tampered input rejection, primary and
backup precedence, exact replay, monotonic generation/revision CAS, temp and
backup rotation, injected failures on both sides of replacement, real symlink
rejection, and a restart-like host filesystem flow. A named zero-failure result
and a clean diagnostics scan are both required:

```text
PROFILE_STORE_RESULT checks=220 failures=0
```

The production Godot adapter writes and flushes a same-directory temp before
`DirAccess.rename_absolute()`. Godot exposes no directory-fsync API, so a
verified production replacement is reported as
`committed_durability_uncertain`; the checkpoint does not claim power-loss
durability or an interprocess writer lock.

## Inventory UI binding checkpoint (task 4.7b)

Task 4.7b is complete at the implementation/evidence level. The fresh
independent Astra gate accepted 31 distinct final suite/probe variants with
`4228` raw checks and `0` failures across its historical resolution matrix.
Those dimensions are immutable historical evidence; current 1920×1080-only
reruns MUST NOT invoke the compact probes or regenerate their captures. The
full packet is
[`docs/qa/inventory_ui_binding/astra_final_accept/REPORT.md`](qa/inventory_ui_binding/astra_final_accept/REPORT.md);
earlier rejection packets are retained there as history and are not acceptance
evidence.

The native continuous flow passed `88/0`; compact native continuity passed
`34/0`, the promoted compact-selection probe `37/0`, the unchanged sealed
live-section and tooltip regressions `18/0` and `17/0`, and the independent
overlay/section challenge `112/0`. The UI renders immutable confirmed
snapshots and emits strict authority intents for drag, rotate, split, merge,
loot and complete-only quick transfer; presentation-only search, filter,
hover, selection and tooltip behavior cannot mutate canonical state. Command
correlation is protected by owner/scope generations, binding tokens, exact item
facts, captured dependencies, globally distinct pre-published command IDs and
fail-closed exhaustion handling.

Live-empty gear/economy actions are unavailable. Fixture restoration is visibly
marked `FIXTURE PREVIEW`; Encrypted Drive and Gold Watch keep their true
identities with neutral artwork and accessible `PLACEHOLDER` disclosure; Health
and Stats are authored preview values with explicit notices. This is native
macOS Compatibility evidence, not a human playtest or a complete raid loop.
Human gates 5.13, 8.13 and 12.5, whole-game completion, multiplayer and
Windows/Linux release acceptance remain open.

## Ammunition/magazine reload checkpoint (task 4.9)

Task 4.9 is accepted at the implementation/evidence level by the fresh Astra
packet in [`docs/qa/inventory_weapon_reload/astra_final/REPORT.md`](qa/inventory_weapon_reload/astra_final/REPORT.md).
The pinned reload contract can be run directly:

```sh
$ZERKOV_GODOT --headless --path . --audio-driver Dummy \
  --script res://tests/raid/inventory_weapon_reload_contract.gd
```

The current-safe headless subset of the retained packet is:

```sh
python3 docs/qa/inventory_weapon_reload/astra_final/run_validation.py capacity
python3 docs/qa/inventory_weapon_reload/astra_final/run_validation.py flow
python3 docs/qa/inventory_weapon_reload/astra_final/run_validation.py suites
```

The visible `native` packet mode is retained historical evidence and is
intentionally omitted from current commands; do not invoke it until task 11.8
or a later approved display-support proposal.

The accepted totals are catalog `537/0`, reload `159/0`, capacity `33/0`,
headless flow `208/0`, native flow `213/0` (the same 208 core assertions plus
five capture checks), and `20750/0` raw assertions across 17 distinct programs
and 18 execution variants. The flow reserves held rounds in
magazine -> rig -> pockets order and commits inventory and weapon state as one
coherent in-memory single-writer/no-yield sequence. This is not crash-safe
symmetric 2PC, physical detachable-magazine swapping, production weapon
instance/input integration, or human playtest evidence.

## Inventory-to-ability equipment checkpoint (task 4.10)

Task 4.10 is accepted at the implementation/evidence level by the fresh Astra
packet in
[`docs/qa/inventory_ability_equipment/astra_final/REPORT.md`](qa/inventory_ability_equipment/astra_final/REPORT.md).
Run the promoted contract directly with the pinned executable:

```sh
$ZERKOV_GODOT --headless --path . --audio-driver Dummy \
  --script res://tests/raid/inventory_ability_reconciliation_contract.gd
```

The current-safe headless subset of the retained packet can be run from the
repository root:

```sh
python3 -B docs/qa/inventory_ability_equipment/astra_final/run_validation.py suites
python3 -B docs/qa/inventory_ability_equipment/astra_final/run_validation.py flow
python3 -B docs/qa/inventory_ability_equipment/astra_final/finalize_packet.py
```

The visible `native` packet mode is retained historical evidence and is
intentionally omitted from current commands; do not invoke it until task 11.8
or a later approved display-support proposal.

The accepted totals are promoted reconciliation `546/0`, independent headless
flow `451/0`, independent native flow `463/0`, and `21756/0` raw assertion
executions across 17 distinct test programs and 18 execution variants. Inventory
mutations commit in `RaidAuthority` phase 5; phase 7 pulls the complete owner
snapshot and reconciles idempotent source-item grants/revokes. The matrix covers
duplicate/full/replayed/batched/gapped revisions, AKM and machete native
abilities/effects/tags/modifiers, explicit no-grant gear, replacement,
destruction, teardown, failure recovery/quarantine and the 64-record native
grant-history boundary.

This is offline, synchronous, in-memory evidence and the visible window is an
automated validation harness, not production UI or a human playtest. Until the
tasks 4.12/7.1 lifecycle follow-up, composition must release the adapter or tear
down its owner/component before `RaidAuthority` terminalizes; raid-terminal-first
cleanup is not automatic. Task 4.11 is next, while whole-game, multiplayer and
release acceptance remain open.

## Render-scale verification

The current isolated native render-scale check uses the fixed 640x360 world
surface with the existing full-output HUD at exact 1920×1080 only. Run the
current exact-size subset from the project root with:

```sh
uv run --with pillow python tests/visual/render_scale/verify.py
```

Current generated render-scale files are written under
`docs/qa/render_scale/current_1080/`; the historical root packet is not
overwritten.

The historical packet also contains smaller-resolution and responsive results;
those are not current commands and MUST NOT be regenerated before task 11.8 or
a later approved display-support proposal. Current exact-size results are
recorded separately in [`docs/qa/1080-only-scope.md`](qa/1080-only-scope.md).

The historical packet's zero-failure lines are:

```text
RENDER_SCALE_COMPLETE checks=1292 failures=0 (historical matrix)
UI_COMPOSITION_COMPLETE checks=109 failures=0 (historical matrix)
RESPONSIVE_TEST_COMPLETE checks=96 failures=0 (historical; deferred)
BORDER_RENDER_TEST_COMPLETE checks=135 failures=0 (historical matrix)
```

The historical evidence packet records 26 PNG hashes. Its smaller-output
integer-fit and matte details are retained for audit only; they do not define
the current first-playable acceptance scope.

## Platform status

macOS universal debug is the only currently proven combined development path.
Windows x86_64 client and Linux x86_64 dedicated-server artifacts remain
unproven until every required add-on binary exists and the corresponding clean
export/startup smoke passes. Declared `.gdextension` library paths are intent,
not support evidence.

Reproduce the current artifact and distribution gates with:

```sh
python3 tools/check_platform_artifacts.py windows-debug-client
python3 tools/check_platform_artifacts.py linux-debug-server
python3 tools/check_distribution_licenses.py
```

Exit code 2 means the gate is structurally valid but an enumerated external
artifact/license requirement is still blocked. See `docs/platform/` and
`THIRD_PARTY_NOTICES.md`; do not turn that result into a public support claim.
