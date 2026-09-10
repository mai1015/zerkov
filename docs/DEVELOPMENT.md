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
  --script res://tests/combat/content_contract.gd
```

Godot may return exit code zero for a script parse error, so a run is successful
only when its named `*_RESULT` line reports zero failures and console output has
no `SCRIPT ERROR`, `ERROR`, or extension-load failure. The current inventory
and authority evidence includes these named zero-failure lines:

```text
INVENTORY_MUTATION_ROUTING_RESULT checks=146 failures=0
INVENTORY_INTENT_ADAPTER_RESULT checks=162 failures=0
INVENTORY_PROJECTION_RESULT checks=99 failures=0
INVENTORY_CATALOG_RESULT checks=504 failures=0
INVENTORY_AUTHORITY_RESULT checks=79 failures=0
AUTHORITY_REPLAY_RESULT checks=81 failures=0
EQUIPPED_ITEM_RECONCILIATION_RESULT checks=123 failures=0
IDENTITY_CONTRACT_RESULT checks=18442 failures=0
COMBAT_CONTENT_RESULT checks=79 failures=0
```

## Render-scale verification

The isolated native render-scale spike compares the fixed 640x360 world surface
with the existing full-output HUD at 1920x1080, 1600x900 and 1280x720. Run it
from the project root with:

```sh
uv run --with pillow python tests/visual/render_scale/verify.py
```

The recorded zero-failure lines are:

```text
RENDER_SCALE_COMPLETE checks=1292 failures=0
UI_COMPOSITION_COMPLETE checks=109 failures=0
RESPONSIVE_TEST_COMPLETE checks=96 failures=0
BORDER_RENDER_TEST_COMPLETE checks=135 failures=0
```

The evidence packet records 26 PNG hashes. At 1600x900, the selected
integer-fit world is 1280x720 centered with 160 px horizontal and 90 px
vertical matte; this constant-FOV policy is a fairness trade-off, not a human
approval or a later animation, combat, readability or cursor-mapping
acceptance.

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
