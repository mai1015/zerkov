# Task 4.11 · Existing inventory workspace loot presentation

Date: 2026-09-10
Branch: `codex/inventory-loot-ui-4-11`
Baseline: `eb6bc08`

## Scope and extension points

Task 4.11 extends the accepted character workspace in place:

- `ui/screens/character/character_workspace.tscn` keeps the authored 1920×1080 three-column shell, 74px inventory cells, and the existing right-hand Stash/Loot pane. The only new control is the header-level `LootClose` button, hidden in Stash mode.
- `ui/screens/character/character_screen.gd` continues to bind the existing tabs, search, filters, sort/organize controls, grid, status label, and focus graph. Loot state text is concise in the header and full detail remains in the tooltip.
- `ui/screens/character/inventory_actions.gd` keeps search/select/inspect presentation-only and advances the existing binding token on loot open/close so deferred drag/drop payloads fail closed.
- `game/inventory/presentation/inventory_presentation_controller.gd` adds presentation-only loot open/close/state projection and blocks the existing `loot` alias until a confirmed open, while all accepted transfers still go through the injected bridge/adapter.
- `game/inventory/inventory_intent_adapter.gd` exposes read-only world-policy facts to the controller; it does not own inventory state or submit commands.

No replacement route, full-screen loot panel, discovery dashboard, local UI authority, compact-layout gate, vendor/add-on change, clock advancement, or canonical mutation was added.

## Native 1920×1080 evidence

Graphical capture command:

```text
Godot --path . --audio-driver Dummy --script res://tests/visual/inventory_loot_ui_4_11/capture.gd
```

Result: `INVENTORY_LOOT_UI_4_11_CAPTURE_COMPLETE checks=26 failures=0`, macOS OpenGL, exact `[1920, 1080]` for every record.

Captures are under [`captures/`](captures/):

- [`1920x1080_ready.png`](captures/1920x1080_ready.png)
- [`1920x1080_searching.png`](captures/1920x1080_searching.png)
- [`1920x1080_inaccessible.png`](captures/1920x1080_inaccessible.png)
- [`1920x1080_stale.png`](captures/1920x1080_stale.png)
- [`1920x1080_overweight.png`](captures/1920x1080_overweight.png)
- [`1920x1080_resynchronizing.png`](captures/1920x1080_resynchronizing.png)
- [`1920x1080_selection_scroll.png`](captures/1920x1080_selection_scroll.png)
- [`1920x1080_close.png`](captures/1920x1080_close.png)
- [`1920x1080_disconnected.png`](captures/1920x1080_disconnected.png)
- [`captures.json`](captures/captures.json)

Geometry recorded in `captures.json` is unchanged across the open/state captures: `InventoryContent` is `(0,0) 1920×1080`, `DesktopStashScroll` is `(1304,225) 518×740`, the retained Loot tab is `(1328,174) 76×32`, `LootClose` is `(1780,130) 92×28`, the loot grid uses `74`px cells, and `replacement_panel_present` is false for every record.

## Focused 4.11 contract

```text
Godot --headless --path . --audio-driver Dummy --script res://tests/raid/inventory_loot_ui_4_11_contract.gd
INVENTORY_LOOT_UI_4_11_COMPLETE checks=37 failures=0
```

The contract uses a temporary deterministic authority fixture only for test setup, then verifies the production bridge/adapter/controller flow for crate and corpse projections, open/search/close, canonical transfer/no-loss, inaccessible policy, stale and overweight presentation gates, resynchronizing, lifecycle unload/disconnect, binding-token invalidation, and retained workspace geometry. Noncanonical stale/overweight capture states are supplied by a test-only controller subclass; a recursive source scan asserts that production `game/` and `ui/` contain no override API or callsite.

## Regression results

All commands below exited zero:

```text
inventory_ui_binding_contract             checks=138 failures=0
inventory_catalog_contract                checks=543 failures=0 findings=37
inventory_projection_contract             checks=99 failures=0 latest_revision=7
inventory_persistence_replacement_contract checks=97 failures=0 exact_round_trips=4
inventory_weapon_reload_contract          checks=176 failures=0 real_addons=true facade_rollback=false
inventory_mutation_routing_contract       checks=146 failures=0
inventory_multi_controller_contract       checks=23 failures=0
session_lifecycle_contract                checks=44 failures=0
common_ui_integration_smoke               checks=76 failures=0
inventory_smoke                            checks=21 failures=0
ui_smoke                                   checks=947 failures=0
ui_composition_smoke                       checks=109 failures=0
raid_smoke                                 checks=29 failures=0
zerkov_screen_lifecycle_contract           checks=209 failures=0
ui_component_states                        checks=15 failures=0
reentrant_probe                             checks=28 failures=0
presentation_honesty_probe (graphical)     checks=540 failures=0
```

Import/check gate also passed with Godot 4.7.2 and no diagnostics. The focused capture/contract scripts are 1920×1080-only; compact layouts remain deferred and were not used as an acceptance gate.
