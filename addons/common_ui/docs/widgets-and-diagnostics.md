# Widgets and diagnostics

[Back to the package README](../README.md) · [Actions and bindings](actions-bindings-and-glyphs.md)

The shipped widgets are deliberately small. They are usable as-is, but they do
not impose a visual language: use Godot themes, inherit the scripts/scenes, or
replace them with controls that read the same runtime snapshots.

## Widget responsibilities at a glance

| Class | Base | Runtime effect |
|---|---|---|
| `CommonButton` | `Button` | Optionally registers one action while visible and enabled |
| `ActionBar` | `HBoxContainer` | Read-only view of active action registrations |
| `InputGlyph` | `HBoxContainer` | Read-only glyph/label for one action slot |
| `CommonTabList` | `HBoxContainer` | Registers next/previous actions through its owning screen |
| `BindingEntry` | `HBoxContainer` | Captures input and runs registry rebind transactions |
| `CommonDialog` | `CommonAnimatedScreen` | Modal screen with Confirm/Back registrations and focus behavior |
| `CommonUIDiagnosticOverlay` | `PanelContainer` | Read-only live view of routing state |

Script-only scene wrappers for these controls live under `controls/`. You may
instance them from the filesystem or create the global class directly.

## `CommonButton`

`CommonButton` emits one `triggered` signal for both ordinary button activation
and an optional CommonUI action:

```gdscript
@onready var inventory_button: CommonButton = $InventoryButton


func _ready() -> void:
    inventory_button.text = "Inventory"
    inventory_button.action_priority = 10
    # Set priority before action when configuring an already-ready button;
    # assigning action refreshes the registration.
    inventory_button.action = &"common_ui/open_inventory"
    inventory_button.triggered.connect(open_inventory)
```

How registration works:

- Empty `action`: behaves like a normal Godot `Button` only.
- Inside a `CommonActivatableScreen`: registers through the screen, inheriting
  its context/layer/top-screen eligibility and automatic release.
- Outside a screen: registers directly with the runtime, owned by the button.
- Hidden or disabled: releases its action registration, so it does not remain
  routable or appear in the action bar.
- Shown or re-enabled: registers again.
- Covered/deactivated screen: drops the registration and recreates it when that
  screen activates again.

Exports:

| Property | Default | Meaning |
|---|---:|---|
| `action` | empty | Logical action that also triggers the button |
| `action_priority` | `0` | Runtime handler priority |
| `show_glyph` | `true` | Add an `InputGlyph` child |
| `glyph_set` | `{}` | Logical glyph id to `Texture2D` map for that child |

The built-in glyph child uses the primary slot. If primary and secondary mean
keyboard and controller in your config, it can still show readable text for the
active modality when artwork is missing, but it does not switch texture slots.
For modality-specific artwork, set `show_glyph = false` and add your own
`InputGlyph` whose `slot` you update as shown below.

`triggered` is the abstraction to connect. Connecting both `pressed` and
`triggered` to the same operation runs it twice for pointer activation, because
the button's own `pressed` handler emits `triggered`.

The action callback handles `PHASE_PRESSED` only. If you need hold/repeat or
custom route-result behavior, use `screen.register_action()` directly instead
of relying on `CommonButton`.

## `InputGlyph`

`InputGlyph` asks the runtime for a logical glyph id, then presents a texture or
text. It never changes a binding and never handles input.

```gdscript
@onready var back_hint: InputGlyph = $BackHint


func _ready() -> void:
    back_hint.action = CommonUIDefaults.BACK
    back_hint.glyph_size = Vector2i(28, 28)
    back_hint.glyph_set = {
        &"key_escape": preload("res://ui/glyphs/key_escape.svg"),
        &"pad_east": preload("res://ui/glyphs/pad_east.svg"),
    }
    back_hint.glyph_missing.connect(_report_missing_glyph)
    CommonUI.input_modality_changed.connect(_on_input_modality_changed)
    _on_input_modality_changed(CommonUI.get_input_modality(), CommonUI.get_active_device())


func _on_input_modality_changed(modality: int, _device: int) -> void:
    back_hint.slot = CommonInputBindingRegistry.SLOT_SECONDARY \
        if modality == CommonUIRuntime.MODALITY_GAMEPAD \
        else CommonInputBindingRegistry.SLOT_PRIMARY
```

Exports and queries:

| Member | Meaning |
|---|---|
| `action` | Logical action id |
| `slot` | Primary (`0`) or secondary (`1`) binding used for texture resolution |
| `glyph_set` | `Dictionary[StringName, Texture2D]` supplied by the game |
| `text_fallback` | Explicit label when no matching texture exists |
| `glyph_size` | Texture minimum size; defaults to `24x24` |
| `get_resolved_glyph()` | Current logical id |
| `get_display_text()` | Currently visible text, or empty when using a texture/hidden |

The widget refreshes after `input_modality_changed` and
`bindings_changed`. If a resolved id is absent from `glyph_set`, it emits
`glyph_missing(glyph_id)` once for that action/modality missing state rather
than every refresh.

Fallback order inside the widget is:

1. texture at `glyph_set[resolved_id]`;
2. explicit `text_fallback`;
3. readable effective binding matching the active modality (selected slot
   first, then the other slot);
4. raw logical glyph id.

The selected `slot` is still authoritative for texture resolution. To swap
primary keyboard art for secondary gamepad art, set `slot` when modality
changes or build a wrapper that chooses the appropriate slot.

## `ActionBar`

`ActionBar` renders the actions a user can route *right now*:

```gdscript
var bar := ActionBar.new()
bar.ui_user = 0
bar.glyph_set = project_glyphs
bar.entry_theme_type = &"ActionBarLabel"
add_child(bar)
```

It listens to `active_actions_changed` and `input_modality_changed`, coalescing
same-frame rebuilds. A rebuild:

1. reads `CommonUI.get_active_actions(ui_user)`;
2. skips definitions whose `show_in_action_bar` is false;
3. collapses multiple eligible registrations to one row per logical action;
4. orders rows by descending `display_priority`, then action id;
5. creates an `InputGlyph` plus label for each row.

The matching `CommonUIAction` is the only source for display name, display
priority, and visibility. Passing old presentation keys to
`register_action()` does nothing. If no display name exists, the bar capitalizes
the last segment of the action id.

The stock bar queries the root viewport and creates its glyph with the default
primary slot. For per-viewport state, custom row layouts, clickable actions, or
automatic keyboard/controller texture-slot switching, create your own bar from
`get_active_actions()`; you do not need to modify routing.

Assign `glyph_set` before adding a programmatically created bar to the tree, or
call `rebuild()` after changing it; that property alone does not schedule a
rebuild. Likewise, call `rebuild()` after changing `ui_user` if no matching
runtime signal has caused one yet.

## `CommonTabList`

`CommonTabList` builds toggle buttons from ids/labels and optionally cycles them
with actions:

```gdscript
@onready var tabs: CommonTabList = $Tabs


func _ready() -> void:
    tabs.tab_ids = [&"graphics", &"audio", &"controls"]
    tabs.tab_labels = ["Graphics", "Audio", "Controls"]
    tabs.wrap_around = true
    tabs.tab_selected.connect(_show_tab)
```

Exports:

| Property | Default |
|---|---|
| `tab_ids` | `[]` |
| `tab_labels` | `[]`; missing labels fall back to capitalized ids |
| `next_action` | `common_ui/tab_next` |
| `previous_action` | `common_ui/tab_previous` |
| `wrap_around` | `true` |
| `button_theme_type` | empty |

Queries/mutation are `get_selected_index()`, `get_selected_id()`, and
`select(index)`. A changed selection emits `tab_selected(index, id)`.

The control must be beneath a `CommonActivatableScreen` for its next/previous
registrations to exist. It recreates them on screen activation and handles both
pressed and hold-repeat phases. The active config must define bindings for the
chosen action ids; the default config already defines both.

Set `next_action`, `previous_action`, and `button_theme_type` in the inspector
or before the control becomes ready. Those plain exported properties do not
automatically rebuild an already-live tab strip.

`tab_ids` is authoritative. Extra labels are ignored, and missing labels use the
id. Selecting an unchanged index emits nothing.

## `BindingEntry`

`BindingEntry` is a small “action / current glyph / Change button” row:

```gdscript
@onready var back_binding: BindingEntry = $BackBinding


func _ready() -> void:
    # Set action, slot, and glyph_set in the inspector (or before add_child()).
    back_binding.rebind_finished.connect(_show_rebind_result)
    back_binding.conflict_detected.connect(_show_conflicts)
```

`start_listening()` captures the next usable press before GUI dispatch:

- keyboard: pressed, non-echo physical key plus exact modifiers;
- mouse: pressed button plus exact modifiers;
- gamepad: pressed button;
- axis: magnitude at least `0.5`, including direction.

Mouse motion, releases, key echo, touch, and small stick motion are ignored.
The accepted event is marked handled so the Change button cannot immediately
reactivate from the same press/release path.

The row attempts `registry.rebind(..., CONFLICT_REJECT, false)`, emits the
result, and refreshes. `cancel_listening()` stops capture. For a full conflict
confirmation workflow, prefer a project controller around the binding registry:
the stock `conflict_detected` signal contains conflicts but not the candidate
that must be retried. See [Rebinding safely](actions-bindings-and-glyphs.md#rebinding-safely).

Assign `glyph_set` before `_ready()`; unlike `action` and `slot`, changing the
row's exported glyph dictionary later is not forwarded to its internal
`InputGlyph`.

## `CommonDialog`

Use the screen-root helper for the complete behavior:

```gdscript
var dialog := await ui.open_dialog(
    "Reset controls?",
    "All custom bindings will be removed.",
    "Reset",
    "Cancel",
    true
)
dialog.confirmed.connect(_restore_defaults, CONNECT_ONE_SHOT)
```

Exports are `title_text`, `message_text`, `confirm_text`, `cancel_text`, and
`show_cancel`. `configure(...)` sets them together and returns the dialog.

The dialog:

- fills the viewport and blocks pointer events from reaching lower screens;
- uses context `dialog` at modal priority;
- suspends supplied lower contexts and traps focus;
- starts in quick-action mode with Confirm/Back glyph hints;
- changes to focus-navigation mode after the first directional action; and
- emits `confirmed` or `dismissed` without deciding game behavior itself.

`CommonUIScreenRoot.open_dialog()` automatically pops on either signal. If you
instantiate and push a dialog yourself, connect that pop yourself too.

## Validate configuration before debugging behavior

The native config validator rejects structural errors. The GDScript
`CommonUIActionValidator` additionally identifies survivable configurations
that are likely unusable:

- duplicate action ids;
- missing required bindings;
- physical binding collisions in the same conflict context;
- action ids without a namespace; and
- keyboard keys already claimed by Godot `ui_*` actions.

Run it after the active screens have registered actions if you also want to
find registered actions missing from the config:

```gdscript
func validate_common_ui() -> void:
    var findings := CommonUIActionValidator.validate_runtime(CommonUI)
    print(CommonUIActionValidator.format(findings))
    if not CommonUIActionValidator.is_ok(findings):
        push_error("CommonUI has blocking configuration errors.")
```

Each finding is:

```text
{severity: &"error" | &"warning" | &"info", action: StringName, message: String}
```

`validate_runtime()` checks active registrations for UI user 0. For a custom
multi-user/viewport integration, also inspect the appropriate runtime
snapshots yourself.

## Add the live diagnostic overlay

Add `CommonUIDiagnosticOverlay` above your UI in a debug-only scene. It displays:

- active modality, device id, and controller name;
- active/suspended contexts and their priorities;
- eligible actions with context/layer/handler priority;
- captured triggers and repeat state; and
- the most recent route, including every candidate's eligibility reason.

```gdscript
var diagnostics := CommonUIDiagnosticOverlay.new()
diagnostics.ui_user = 0
diagnostics.refresh_interval = 0.15
diagnostics.overlay_visible = OS.is_debug_build()
ui.add_child(diagnostics)

# Bind this to your own debug shortcut if desired.
diagnostics.toggle()
```

The overlay only reads immutable snapshots. It is pause-immune and stops its
timer while hidden.

For machine-readable diagnostics:

```gdscript
var actions := CommonUI.get_active_actions(0)
var contexts := CommonUI.get_active_contexts(0)
var triggers := CommonUI.get_captured_triggers(0)
var route := CommonUI.get_last_route_report()
```

The route report includes `action`, device fields, `consumed`, `stopped`,
`suppressed`, captured `chain`, and `entries`. Each entry identifies a handle,
whether it was invoked, its result/order, and an `IneligibleReason` such as
`REASON_CONTEXT_SUSPENDED` or `REASON_SCREEN_NOT_TOP`.

## Troubleshooting by symptom

### The plugin will not enable or the autoload is missing

1. Confirm the directory is exactly `res://addons/common_ui/`.
2. Keep `bin/` and `common_ui.gdextension` with the scripts.
3. Check Godot is 4.7+ and single precision.
4. Check [`../release_manifest.json`](../release_manifest.json) for an artifact
   matching platform, architecture, and build type.
5. Run `CommonUIBoot.describe_missing_runtime()` for the target-specific error.

There is no script fallback. Fix the native artifact before investigating UI
code.

### A registered action never fires

Work downward through the same pipeline the runtime uses:

1. Does `CommonUI.get_input_config().find_action(action)` return a definition?
2. Does `get_binding_registry().get_effective_binding(action, slot)` return a
   valid binding?
3. Does `InputMap.has_action(action)` return true after the config is installed?
4. Does `get_active_actions(user, viewport)` show the registration?
5. Is its context active and unsuspended?
6. Is its layer active, and is its screen the top of that layer?
7. Is the event consumed by a focused `Control`'s built-in `ui_*` action before
   the shortcut stage? Run the validator.
8. Does every pressed path return a `CommonUIRuntime.ROUTE_*` value?

The diagnostic overlay usually answers steps 4–6 immediately.

### The action fires but the Godot event leaks to gameplay

Return `ROUTE_HANDLED` or `ROUTE_HANDLED_CONTINUE` for `PHASE_PRESSED`.
`ROUTE_UNHANDLED` deliberately leaves the event available. If several logical
actions share one physical event, only the first action with a consuming result
wins.

### Back activates the screen underneath

Confirm the top screen's Back handler returns `ROUTE_HANDLED`, not unhandled.
For the standard “close top” behavior, set `handles_back = true`. For a modal,
also supply the lower context handles; `CommonUIScreenRoot.open_dialog()` does
this automatically.

### An action appears twice in behavior

`ActionBar` deduplicates rows, but the router can still have two registrations.
Check `get_active_actions()` for multiple handle ids. Common causes are:

- registering in `_ready()` and again in `_on_activated()`;
- raw registrations with no explicit release; or
- reconnecting a fresh lambda to a control signal on every activation.

Use the screen's `register_action()` helper and register only in
`_on_activated()`.

### The action bar has no row

Rows require an eligible registration, not merely a config definition. Also
check `CommonUIAction.show_in_action_bar`, the action's display metadata, the
bar's `ui_user`, and whether the screen has finished activating. A screen-scoped
registration becomes eligible once its layer push completes.

### A glyph shows text instead of artwork

Inspect `InputGlyph.get_resolved_glyph()`. Add that exact `StringName` key to
the widget's `glyph_set`, or fix the binding/profile mapping. Remember that the
stock glyph's `slot` controls texture resolution; its readable text fallback is
more flexible and can choose the other slot for the active modality.

### Rebinding fails or resets to defaults

Read the returned `error`, `needs_confirmation`, and `conflicts`. Listen to the
registry's `binding_error(message)` for persistence/load failures. Check that:

- the action exists;
- the candidate is valid;
- replacing conflicts would not unbind a protected action;
- `confirmed` is true when changing a `PROTECTION_CONFIRM` action;
- `user://` is writable; and
- the saved `definition_version` matches the active config.

Malformed or version-mismatched override files are rejected as a whole; the
live set remains unchanged.

### A held action keeps repeating

Handle `PHASE_RELEASED`/`PHASE_CANCELED` for visual cleanup and inspect
`get_captured_triggers()`. The runtime reconciles key/button physical state,
cancels on focus loss or controller disconnect, and exposes
`CommonUI.cancel_action(action, user, viewport)` for an explicit abort.

When overriding trigger policy in registration options, specify threshold,
interval, and enabled state together. Supplying only one replaces the complete
action-level policy with zero/default values for the omitted fields.

### A pause menu freezes

The default layers use `pause_immune = true`. A custom layer applies
`PROCESS_MODE_ALWAYS` only during `_ready()`, so set `pause_immune` before it
enters the tree. A `CommonAnimatedScreen` tween itself is pause-safe, but other
custom timers/animations must also be configured to process while paused.

### A SubViewport registration warns or never routes

Put one `CommonUIViewportRouter` inside that viewport. Pass the *same viewport*
to the registration, its context, its configured layer, and native screen stack
operations. State with the same ids but a different viewport belongs to a
different scope and cannot satisfy eligibility.

The stock `CommonUILayer`/screen convenience path is root-viewport/user-0 only;
use a project wrapper around the low-level façade for split-screen presentation.

## Current boundaries

- The addon requires its native GDExtension; unsupported targets do not degrade
  to a partial implementation.
- The standard screen/layer classes target UI user 0 and the root viewport.
- Runtime change signals identify the UI user but not the viewport.
- `ActionBar` is display-only, root-viewport, and primary-slot by default.
- `BindingEntry` is a capture/reject row, not a complete conflict-confirmation
  dialog.
- No glyph artwork or product theme is bundled.
- `CommonUIInputPolicy.shared_device_policy` is exposed in the resource, but
  the current Godot routing façade still selects exactly one UI user for each
  event; do not rely on multi-user fan-out from this flag.

These boundaries are extension points: they do not require changes to the
native router for a game-specific presentation wrapper.
