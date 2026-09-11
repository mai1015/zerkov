# Task 4.11 · Existing inventory workspace loot presentation

Date: 2026-09-10
Branch: `codex/inventory-loot-ui-4-11`
Baseline: `eb6bc08`
Post-implementation merge: `bb0d281` (accepted CommonUI navigation)

## Scope and extension points

Task 4.11 extends the accepted character workspace in place:

- `ui/screens/character/character_workspace.tscn` keeps the authored 1920×1080 three-column shell, 74px inventory cells, and the existing right-hand Stash/Loot pane. The only new control is the header-level `LootClose` button, hidden in Stash mode.
- `ui/screens/character/character_screen.gd` continues to bind the existing tabs, search, filters, sort/organize controls, grid, status label, and focus graph. Loot state text is concise in the header and full detail remains in the tooltip.
- `ui/screens/character/inventory_actions.gd` keeps search/select/inspect presentation-only and advances the existing binding token on loot open/close so deferred drag/drop payloads fail closed.
- `game/inventory/presentation/inventory_presentation_controller.gd` adds presentation-only loot open/close/state projection and blocks the existing `loot` alias until a confirmed open, while all accepted transfers still go through the injected bridge/adapter.
- `game/inventory/inventory_intent_adapter.gd` exposes read-only world-policy facts to the controller; it does not own inventory state or submit commands.

No replacement route, full-screen loot panel, discovery dashboard, local UI authority, compact-layout gate, vendor/add-on change, clock advancement, or canonical mutation was added.

## Native 1920×1080 evidence

Graphical capture command (the accepted PNGs below were retained; the
tooltip/cause repair changes hit-testing and state bookkeeping only, so no
pixels changed):

```text
Godot --path . --audio-driver Dummy --script res://tests/visual/inventory_loot_ui_4_11/capture.gd
```

Result: `INVENTORY_LOOT_UI_4_11_CAPTURE_COMPLETE checks=26 failures=0`, macOS OpenGL, exact `[1920, 1080]` for every record. The PNG SHA-256 values remain unchanged from the accepted 1920×1080 evidence; `captures.json` additionally records the exact status hit target and tooltip probe.

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

Evidence hashes (SHA-256; all images are exact 1920×1080): `captures.json` `42496e4d2dc396b589aec982f880e370f03abdd9e3d7f98060af5c6f86ef7de3`; ready `b55851953e5dd6e2bf2655169260e0d491823dbb179bee80cc3bd546b4ca1747`; searching `ebc5af9a24c758389a8e432c1e3251e6d826e46f744d72b215ff58203330bb9d`; inaccessible `332d08bbb75e5ac78e2a8d42658988a96d418b4d2dfcbe4730b4566c7450eb0d`; stale `686455163af03db108a54ddbdf16c30f7010b51ae033a0ab12b8ed781b9c5e0e`; overweight `b0346f68c377b81136eab4665dacfc8b6807a9ccc96e1d6dcdc7b87f818951bf`; resynchronizing `e1b6bdc5cd97352e53b4953c1e1338815c6d00b149f183170f7aad8638cabc1e`; selection `bad55d1e98193c24448571e7ba927dc63ae26119a2273ffef7debfef8a77aae4`; close `cb5d4d8e4ebaeb7076536d58eda0f459c7a8c6fdacf06ade7f85384ab8b07db0`; disconnected `331375f940c8867b7f366a7f18a8c268067ffb7641ea77ad4d8cd51853981c2d`.

Geometry recorded in `captures.json` is unchanged across the open/state captures: `InventoryContent` is `(0,0) 1920×1080`, `DesktopStashScroll` is `(1304,225) 518×740`, the retained Loot tab is `(1328,174) 76×32`, `LootClose` is `(1780,130) 92×28`, the loot grid uses `74`px cells, and `replacement_panel_present` is false for every record. The status hit target remains the authored `(1628,133) 146×23` in Loot mode, includes exact point `(1701,144)`, uses `MOUSE_FILTER_PASS` with `FOCUS_NONE`, and carries the full state explanation in `tooltip_text`.

## Focused 4.11 contract

```text
Godot --headless --path . --audio-driver Dummy --script res://tests/raid/inventory_loot_ui_4_11_contract.gd
INVENTORY_LOOT_UI_4_11_COMPLETE checks=88 failures=0
```

The contract uses temporary deterministic authorities only as test fixtures, then verifies the production bridge/adapter/controller flow for crate and corpse projections, open/search/close, canonical transfer/no-loss, inaccessible policy, stale and overweight presentation gates, resynchronizing, lifecycle unload/disconnect, binding-token invalidation, and retained workspace geometry. It also drives a real native 25 kg backpack against the authored 28 kg capacity, proves source+destination causal predecessor revisions survive model feedback stripping, ignores generic feedback for persistent state, retains the hint across same-source close/open, gives inaccessible policy precedence, clears on destination-only revision advance, and drops the old hint on source switch. Eight temporary policy probes tear down their owner during both successful and denying returns at each of the four read stages; each returns a stable stale-binding result without a script error. A controller probe confirms post-policy disconnected truth, consistent rejection, and zero request delta. Noncanonical stale/overweight capture frames are supplied by a test-only controller subclass; a recursive source scan asserts that production `game/` and `ui/` contain no override API or callsite.

## Regression results

The final UI/visual matrix was kept at the required native 1920×1080 canvas;
the remaining checks are resolution-independent domain contracts. All commands
below exited zero:

```text
common_ui_navigation_1080_regression       checks=94 failures=0 maximum_menu_depth=2 (1920x1080)
inventory_smoke                            checks=21 failures=0 (1920x1080)
ui_smoke                                   checks=948 failures=0 (1920x1080)
raid_smoke                                 checks=29 failures=0 (1920x1080)
inventory_intent_adapter_contract          checks=162 failures=0 native_transactions=3
inventory_catalog_contract                checks=543 failures=0 findings=37
inventory_projection_contract             checks=99 failures=0 latest_revision=7
inventory_persistence_replacement_contract checks=97 failures=0 exact_round_trips=4
inventory_weapon_reload_contract          checks=176 failures=0 real_addons=true facade_rollback=false
inventory_mutation_routing_contract       checks=146 failures=0
inventory_multi_controller_contract       checks=23 failures=0
session_lifecycle_contract                checks=44 failures=0
```

Import/check gate also passed with Godot 4.7.2 and no diagnostics. The focused
capture/contract scripts are 1920×1080-only; compact layouts remain deferred
and were not used as an acceptance gate.
