# Task 8.6 · Live Character inventory and health binding

Date: 2026-09-11
Branch: `codex/live-inventory-health-ui-8-6`
Baseline: `c265d3a4efd9b49f840b87e201ceb8f4b661d26b`

## Scope

The accepted Character workspace now receives a game-owned
`CharacterUIRuntime` through its typed CommonUI route context. The runtime
projects the existing 4.11 owner/bridge/adapter/controller seam into immutable
`InventoryView` snapshots and accepts immutable `HealthView` snapshots. It
retains presentation-only selection, search focus/caret, scroll coordinates,
and loot mode across Character route replacement without becoming gameplay
authority.

Normal production composition creates a real empty `RaidInventoryOwner`, real
`InventoryProjectionBridge`, `InventoryIntentAdapter`, offline admission and
identity adapter. It never materializes test loot or a mock canonical store.
World interaction is deny-by-default until its real policy is connected, and
health is an explicit typed unavailable state until the health authority from
the deferred gameplay work publishes a view. Populated data in the focused
contract and capture runner is explicitly test-only.

No route, scene, panel, grid size, health layout, visual token, damage/healing
mechanic, HUD binding, input action, or global fixture-state migration was
added. Quick Heal remains disabled in live mode pending task 5.7.

## Exact native evidence

The dedicated runner was statically inspected before execution. It contains
one output size (`1920x1080`), is standalone, and does not load the deferred
`tests/visual/inventory_ui_binding/` packet or any compact/responsive runner.

```text
godot --path . --audio-driver Dummy --script res://tests/visual/live_character_ui_8_6/capture.gd
LIVE_CHARACTER_UI_8_6_CAPTURE_RESULT checks=8 failures=0 size=1920x1080
```

Every record in [`captures.json`](captures/captures.json) is exactly
`[1920,1080]`. It records the unchanged `InventoryContent` rectangle
`(0,0) 1920x1080`, right `DesktopStashScroll` rectangle
`(1304,225) 518x740`, `74`px grid cells, the retained scroll parent, no
replacement panel, typed view sync state, and disabled live Quick Heal.

- [`1920x1080_inventory_ready.png`](captures/1920x1080_inventory_ready.png) — SHA-256 `b55851953e5dd6e2bf2655169260e0d491823dbb179bee80cc3bd546b4ca1747`
- [`1920x1080_health_ready.png`](captures/1920x1080_health_ready.png) — SHA-256 `5745e5d8f1b5150ae45e965dffd1b3ca5582752a803d3047420f7cf5abaaef6a`
- [`1920x1080_health_disconnected.png`](captures/1920x1080_health_disconnected.png) — SHA-256 `8817bc07ad732bb7c72d69ca8b67b86e10526fa3a5545393f1d0434dcbb766cc`
- [`captures.json`](captures/captures.json) — SHA-256 `013327ce2982e158c667559cbc1f00adaed066b894772402dec7c75d402bf048`

The inventory-ready image is byte-identical to the independently accepted 4.11
ready image, confirming that live view injection did not change the approved
workspace pixels.

## Focused binding contract

```text
godot --headless --path . --script res://tests/presentation/character_ui_binding_8_6_contract.gd
CHARACTER_UI_BINDING_8_6_RESULT checks=37 failures=0 size=1920x1080
```

The contract proves production composition contains real dependencies and no
mock fallback; `InventoryView`/`HealthView` collections remain immutable;
widget rows ignore forged `app.state`; exact geometry is unchanged; a live loot
gesture submits one declared intent; stale health revisions and pre-teardown
payloads are rejected; teardown publishes disconnected views; a replacement
authority advances the screen binding token; and selection, focus/caret,
query, scroll and CommonUI route lifecycle behave as specified.

## Regression matrix

All selected UI runners were statically inspected before execution. Their only
viewport is the exact first-playable 1920×1080 canvas; domain-only contracts do
not render a viewport. No compact, responsive, alternate-size, or deferred old
inventory visual test was invoked. All commands exited zero without engine,
script, warning, or leak diagnostics:

```text
character_ui_binding_8_6_contract          checks=37  failures=0  size=1920x1080
inventory_ui_binding_contract              checks=138 failures=0  size=1920x1080
inventory_loot_ui_4_11_contract            checks=88  failures=0  size=1920x1080
inventory_persistence_replacement_contract checks=97  failures=0  exact_round_trips=4
inventory_nested_magazine_contract         checks=258 failures=0
view_contracts_contract                     checks=111 failures=0
common_ui_navigation_contract              checks=79  failures=0  routes=28
common_ui_navigation_1080_regression        checks=94  failures=0  maximum_menu_depth=2
zerkov_screen_lifecycle_contract            checks=116 failures=0  size=1920x1080
inventory_smoke                             checks=21  failures=0  size=1920x1080
ui_composition_smoke                        checks=103 failures=0  size=1920x1080
ui_smoke                                    checks=948 failures=0  size=1920x1080
live_character_ui_8_6 capture               checks=8   failures=0  size=1920x1080
```

Total: `2098` checks, `0` failures. A clean Godot 4.7.2 editor import and strict
spec validation also pass; `git diff --check` is clean.

## Independent acceptance

Domain and Astra visual acceptance are intentionally pending. Task 8.6 remains
unchecked in the change task list; the primary implementer will mark it only
after both independent reviews pass. Human approval is not recorded.
