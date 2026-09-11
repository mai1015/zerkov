# Task 8.6 · Live Character inventory and health binding

Date: 2026-09-11
Branch: `codex/live-inventory-health-ui-8-6`
Original baseline: `c265d3a4efd9b49f840b87e201ceb8f4b661d26b`
Merged main: `d4b407f` (accepted Tasks 7.9 and 8.3; Task 5.3 remains open)

## Scope

The accepted Character workspace receives one shared `CharacterUIRuntime`
through its typed CommonUI route context. The runtime projects the existing
4.11 owner/bridge/adapter/controller seam into immutable `InventoryView`
snapshots and consumes immutable `HealthView` snapshots. It retains only
presentation interaction state across Character route replacement.

Production composition is injection-only. The actual app/profile/raid root
retains ownership of `RaidInventoryOwner`, `InventoryProjectionBridge`,
`InventoryIntentAdapter`, and `ZSessionAdmission`; no production UI bootstrap
constructs a parallel owner, session, identity, or empty READY inventory.
Until those real dependencies are supplied, the same presentation runtime
publishes `character_authority_not_injected` through typed unavailable
inventory and health views. The explicit pre-tree runtime injection seam is
used by test/integration fixtures, and no public composition authority getter
or raw public Character runtime/composition field remains.

Runtime release, composition teardown, failed replacement, and successful
rebind publish one coherent unavailable-or-rebound transition. Open screens
clear rows, expire their local gesture token, reject captured stale payloads,
and keep inventory/health diagnostics aligned with `runtime.last_error`.
Externally owned authority dependencies remain alive after composition
teardown. `HealthView` now carries a stable immutable SHA-256 content identity:
same-version identical delivery is a no-op replay, same-version divergent
content is rejected, and neither revision nor source tick may regress.

The existing body-wide health area represents every effect. Effects are sorted
deterministically by severity, harmful state, and content ID; the highest
priority effect occupies the first existing badge and remaining effects are
represented by the second existing aggregate badge and its complete truthful
tooltip. Body-wide, notice, panel, and label targets accept native hover.
Severity/beneficial color applies to panel border, edge, and label, and long
labels are clipped with ellipsis inside the authored badge rectangle.

No route, replacement panel, grid size, health layout, damage/healing mechanic,
HUD binding, or smaller-layout behavior was added. The accepted 74px grids,
right Stash/Loot pane, CommonUI lifecycle, focus/caret, selection, drag lease,
and scroll behavior remain intact. All populated authorities and data in tests
and captures are explicitly test-only. Task 8.6 remains unchecked.

## Exact native evidence

The dedicated runner was statically inspected before execution. It has one
output size (`1920x1080`), is standalone, and does not load the deferred old
inventory visual packet or any compact/responsive runner.

```text
godot --path . --audio-driver Dummy --script res://tests/visual/live_character_ui_8_6/capture.gd
LIVE_CHARACTER_UI_8_6_CAPTURE_RESULT checks=12 failures=0 size=1920x1080
```

Every record in [`captures.json`](captures/captures.json) is exactly
`[1920,1080]`. It records the unchanged `InventoryContent` rectangle
`(0,0) 1920x1080`, right `DesktopStashScroll` rectangle
`(1304,225) 518x740`, 74px cells, retained scroll parent, no replacement panel,
typed view sync state, disabled live Quick Heal, effect count/order, hover
filters, tooltips, and label clipping.

- [`1920x1080_inventory_ready.png`](captures/1920x1080_inventory_ready.png) — SHA-256 `b55851953e5dd6e2bf2655169260e0d491823dbb179bee80cc3bd546b4ca1747`
- [`1920x1080_health_ready.png`](captures/1920x1080_health_ready.png) — SHA-256 `507dcf6cb6957131352068c1d2626db85790ef308dfa5024dd7949c2cf4eefcb`
- [`1920x1080_health_effects_hover.png`](captures/1920x1080_health_effects_hover.png) — SHA-256 `fce0383f4cb6d412ebb3118bf59941737454c97eafd2514b83b4a0f0166b0480`
- [`1920x1080_health_disconnected.png`](captures/1920x1080_health_disconnected.png) — SHA-256 `8817bc07ad732bb7c72d69ca8b67b86e10526fa3a5545393f1d0434dcbb766cc`
- [`captures.json`](captures/captures.json) — SHA-256 `b1aaccd737ef269318be05f138dadf5630de936bb4c45e8391e20d58bf35bef7`

The inventory-ready image remains byte-identical to the independently accepted
4.11 ready image. Visual inspection of the health-ready capture confirms the
critical effect is not hidden and the long label stays within the badge. The
hover capture records Godot's native multiline tooltip with all three
aggregated effect names, severities, remaining ticks, and beneficial state.

## Focused contracts

```text
character_ui_binding_8_6_contract          checks=64  failures=0  size=1920x1080
character_presentation_composition_contract checks=15 failures=0
view_contracts_contract                     checks=115 failures=0
```

These contracts cover injection-only production composition, lack of owner /
session constructors and mutable authority getters, typed unavailable startup,
external dependency lifetime, open-screen teardown/failure/rebind, stale
gesture rejection, binding-token advancement, immutable HealthView digest and
version rules, all-effect health representation and real pointer hover, and
the accepted inventory geometry and interaction-state preservation.

## Regression matrix

All selected UI runners were statically inspected before execution. Their only
viewport is the exact first-playable 1920×1080 canvas; domain-only contracts do
not render a viewport. No compact, responsive, alternate-size, or deferred old
inventory visual runner was invoked. All commands exited zero without engine,
script, warning, or leak diagnostics:

```text
character_ui_binding_8_6_contract           checks=64  failures=0  size=1920x1080
character_presentation_composition_contract checks=15  failures=0
inventory_ui_binding_contract               checks=138 failures=0  size=1920x1080
inventory_loot_ui_4_11_contract              checks=88  failures=0  size=1920x1080
inventory_persistence_replacement_contract  checks=97  failures=0  exact_round_trips=4
inventory_nested_magazine_contract          checks=258 failures=0
view_contracts_contract                      checks=115 failures=0
common_ui_navigation_contract               checks=79  failures=0  routes=28
common_ui_navigation_1080_regression         checks=94  failures=0  maximum_menu_depth=2
zerkov_screen_lifecycle_contract             checks=116 failures=0  size=1920x1080
inventory_smoke                              checks=21  failures=0  size=1920x1080
ui_composition_smoke                         checks=103 failures=0  size=1920x1080
ui_smoke                                     checks=948 failures=0  size=1920x1080
zerkov_input_bindings_contract               checks=380 failures=0  size=1920x1080
live_character_ui_8_6 capture                checks=12  failures=0  size=1920x1080
```

Total: `2528` checks, `0` failures. A clean Godot 4.7.2 editor import and strict
spec validation pass; `git diff --check` is clean.

## Independent acceptance

The prior domain and Astra reviews rejected commit `b723e3b5` and supplied the
repair findings covered above. Independent domain and Astra re-acceptance of
this repair commit remain pending. Task 8.6 remains unchecked; the primary
implementer will mark it only after those reviews pass. Human approval is not
recorded.
