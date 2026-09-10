# Zerkov UI composition

The UI preview is separate from the ongoing gameplay authority implementation.
Components render values and emit intent; they do not find `Main`, navigate
globally, mutate fixture state, or depend on `game/`.

## Ownership

```text
ui/
  main.{tscn,gd}                 bootstrap, viewport fitting, QA facade
  core/                         context, routes, navigation, feedback, reflow
  theme/                        authored Theme, tokens, pixel-border adapter
  components/
    controls/                   project CommonButton
    layout/                     cross-feature navigation
    feedback/                   dialog and noninteractive toast
    backgrounds/                parallax planes
  screens/
    frontflow/                  title, menu, saves, join, deploying
      components/               menu cards, world rows, compact layout
    bunker/                     stations, build, crafting, session
      components/               bunker header, retained compact workspace
    character/                  inventory, health, stats wrappers
      character_workspace.tscn  one shared shell and binding controller
      components/               gear/health/stats sections, grid, compact panes
    utilities/                  maps, tasks, settings, controls
    raid/                       HUD, pause, summaries and HUD visuals
  dev/                          fixture provider, preview host, F1 catalog
    fixtures/                   family sample data
    screens/                    seven visual studies/showcase
```

Keep `.tscn`, `.gd`, and `.gd.uid` together. A component used only by one feature
stays with that feature. Static hierarchy, copy, styles and geometry belong in
scenes. Controllers bind data, connect actions once, and apply responsive layout.
Variable item/task populations may change within their owning data component;
fixed shells and shared headers must not be rebuilt.

## Public component APIs

Paths below are relative to `ui/`. Internal child names are not a consumer API.

| Scene / controller | Configuration | Intent / layout |
| --- | --- | --- |
| `components/controls/zerkov_button.tscn` | `text`, `variant`, `disabled`; CommonUI action properties | Connect `triggered` once. Variants: `secondary`, `primary`, `flat`, `hit`, `destructive`, `dialog_secondary`. |
| `screens/frontflow/components/menu_action_card.tscn` | `card_title`, `card_subtitle`, `active_accent`, `disabled` | `activated()`, `get_focus_target()`; root resizing updates internal hit/label bounds. |
| `screens/frontflow/components/world_row.tscn` | `world` (copied dictionary), `index`, `selected`, `disabled` | `activated(world_id, index)`, `get_focus_target()`, `layout_for(width, compact)`. |
| `screens/frontflow/components/new_world_row.tscn` | `disabled` | `activated()`, `get_focus_target()`. |
| `components/layout/navigation_chrome.tscn` | `active_route`, `level_text`, `money_text`, `task_count` | `navigate_requested(route)`, `back_requested()`, `insurance_requested()`, `layout_for(view)`, `get_focus_targets()`. |
| `screens/bunker/components/top_chrome.tscn` | `variant` (`bunker/build/crafting/session`), `title`, `level`, `world_status`, `money` | `menu_requested()`, `world_back_requested()`, `layout_for(view)`. |
| `screens/character/components/inventory_grid.gd` | `set_items()` copies presentation data; selection/compatibility fields | Existing selection, drag/drop, transfer and context signals. Stable item IDs retain unchanged cells. No authority mutation. |
| `components/feedback/zerkov_dialog.tscn` | `configure()`, `configure_prompt()`, `get_prompt_text()` | `confirmed()`, `dismissed()`; access through `app.confirm()` / `app.prompt()`, which manage CommonUI and focus. |
| `components/feedback/toast.tscn` | Text set by feedback service | `app.toast(message)`; retained noninteractive notification. |
| `components/backgrounds/parallax_background.tscn` | Authored planes/depth | Pointer easing and overscan; fixed foreground UI stays outside it. |

Cards, rows and chrome support Inspector and runtime updates. Their `@tool`
scripts must not invoke runtime services in the editor. Use the project button
scene for authored and data-created actions. Do not bind both `pressed` and
`triggered` to the same action.

`theme/zerkov_theme.tres` owns shared native styles and type variations.
`ZThemeAdapter` adapts authored styles at runtime for physical-pixel borders;
the editor keeps editable `StyleBoxFlat` resources. Use shared variants before
adding feature-specific overrides. Do not restyle a component's children from
its consumer.

## Add a screen or component

1. Create a Control scene and adjacent controller under its feature. Extend
   `ZScreen`; compose existing project components in the scene.
2. Add a stable ID, label, explicit scene path and role to `ZRouteCatalog.ROUTES`.
   Do not derive resource paths from route names. F1 and `--screen=<id>` use it.
3. Implement `build()` as repeatable binding, not child deletion. Connect each
   callable once. Use the supplied `app: ZUIContext` for UI services.
4. Define compact placement using named nodes/components or authored
   `metadata/compact_group`. Preserve fixed controls. `ZLayoutSnapshot` restores
   authored parents/geometry before binding and reflow; use `layout_value()` for
   reversible compact-only text/style changes, not live data rollback.
5. Run the screen with F6. Registered scenes create an isolated fixture-backed
   host automatically; they do not require `/root/Main`. Add focused tests and
   desktop/compact captures before extending the catalog acceptance baseline.

For example, an authored `NavigationChrome` instance can be wired as follows:

```gdscript
extends ZScreen

func build() -> void:
    var chrome: ZNavigationChrome = $NavigationChrome
    chrome.active_route = app.current_route
    if not chrome.navigate_requested.is_connected(go):
        chrome.navigate_requested.connect(go)
    if not chrome.back_requested.is_connected(_back):
        chrome.back_requested.connect(_back)

func _back() -> void:
    app.back()
```

For an action card, set its exported values in the Inspector or script, then
connect `card.activated` to the owning screen's action. Use
`card.get_focus_target()` when assigning default focus; never reach through
`Title`, `Subtitle`, or `Hit` to configure it. Add a reusable component beside
its consumer first; promote it to `ui/components/` when another family needs it.
A new component needs a configuration API, semantic signals, documented states,
and a preview; it does not need a new route for each variant.

## Navigation and lifetime

The navigator serializes CommonUI operations and publishes route state only on
success. Root/HUD/summary transitions reset obsolete stacks. Temporary pages
push; workspace and bunker tab changes replace the top within their family.
Back pops to the retained caller. The HUD lives on the HUD layer and stays alive
under pause/workspaces; covered preview timers and input are disabled.

Dialogs use the modal layer; F1 uses the popup layer. Both contain focus and
suspend applicable lower contexts. Any raw screen input handler must begin with
`if not accepts_input(): return`. CommonUI context suspension alone does not
disable raw `_input`/`_unhandled_input`.

`dev/fixture_store.gd` and family fixtures remain explicit preview state. They
are not replacement contracts for ongoing gameplay integration. That later
work should bind real projections/intents at the feature boundary without
making visual components authoritative.

## Verification

Run the commands in the root README. In addition to the existing suites:

- `tests/ui_composition_smoke.gd`: isolated host, invalid/canceled navigation,
  retained HUD/workspace, physical input isolation, focus and component APIs.
- `tests/ui_reflow_smoke.gd`: all 28 routes, three desktop/compact round trips,
  retained authored controls, no accumulating nodes, restored desktop textures.
- `tests/ui_component_states.gd`: native card/row/button states, runtime updates,
  disabled hit-target transparency, single activation, dialogs and prompts.
- `tests/border_render_smoke.gd`: real renderer required; headless is not proof.

Native QA covers 1920×1080, 1600×900, 1280×720, 960×540 and forced compact
1280×720. Inspect logs for runtime errors even when Godot exits successfully.
