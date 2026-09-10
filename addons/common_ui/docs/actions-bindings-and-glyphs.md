# Actions, bindings, and glyphs

[Back to the package README](../README.md) · [Architecture and routing](how-it-works.md)

CommonUI treats an action as a stable logical name such as
`common_ui/back`. Three separate things then cooperate:

- `CommonUIAction` describes the action and its defaults.
- `CommonInputBindingRegistry` owns the player's effective bindings and mirrors
  them into Godot's `InputMap`.
- A runtime action registration supplies behavior for the screens that are
  currently eligible.

This guide starts with the built-in defaults, then shows how to add actions,
register handlers, support hold/repeat, rebind, and display glyphs.

## Use the built-in actions first

`CommonUIScreenRoot` installs `CommonUIDefaults.build_default_config()` when no
config is present. It defines:

| Constant | Id | Keyboard | Controller | Protection |
|---|---|---|---|---|
| `CommonUIDefaults.BACK` | `common_ui/back` | Escape | East/B button | Required |
| `CommonUIDefaults.CONFIRM` | `common_ui/confirm` | Enter | South/A button | Required |
| `CommonUIDefaults.MENU` | `common_ui/menu` | M | Start | None |
| `CommonUIDefaults.TAB_NEXT` | `common_ui/tab_next` | E | Right shoulder | None |
| `CommonUIDefaults.TAB_PREVIOUS` | `common_ui/tab_previous` | Q | Left shoulder | None |

Back and Confirm are protected so a rebind cannot remove their last binding and
strand the player. The default config has no device profiles or glyph textures;
its bindings carry generic logical ids such as `key_escape` and `pad_east`.

### Confirm and Godot's `ui_accept` are separate

CommonUI routing does not replace Godot's focus navigation. A focused `Button`
gets the engine's `ui_accept` action during GUI handling before CommonUI's
shortcut stage runs. The default Enter binding therefore serves two compatible
paths: `ui_accept` activates a focused button, while `common_ui/confirm` can
route when GUI handling did not consume the event.

Use `CommonButton.triggered` when one operation should work through either
path. Also make sure controller Confirm is present in `ui_accept` if it should
activate focused controls. If the player rebinds `common_ui/confirm`, your
project's rebind controller must mirror that change into `ui_accept`; the
binding registry deliberately rewrites only `common_ui/...` actions and never
changes Godot's `ui_*` actions. A validator warning about an intentional
Confirm/`ui_accept` overlap is informational; collisions on framework-only
actions such as Menu or tab cycling usually mean those actions cannot route
while a control has focus.

## Add a custom action

Action ids must be non-empty and begin with `common_ui/`. The registry only
creates or rewrites `InputMap` actions in that namespace, so it never erases
your gameplay actions.

The following extends the shipped config with an inventory action. If you do
this at startup, disable `install_default_config` on `CommonUIScreenRoot` so one
component clearly owns configuration.

```gdscript
const OPEN_INVENTORY := &"common_ui/open_inventory"


func install_input_config() -> void:
    var keyboard := CommonUIBinding.new()
    keyboard.set_device_kind(CommonUIBinding.DEVICE_KEYBOARD)
    keyboard.set_code(KEY_I)
    keyboard.set_slot(CommonUIBinding.SLOT_PRIMARY)
    keyboard.set_glyph_id(&"key_i")

    var gamepad := CommonUIBinding.new()
    gamepad.set_device_kind(CommonUIBinding.DEVICE_GAMEPAD_BUTTON)
    gamepad.set_code(JOY_BUTTON_Y)
    gamepad.set_slot(CommonUIBinding.SLOT_SECONDARY)
    gamepad.set_glyph_id(&"pad_north")

    var action := CommonUIAction.new()
    action.set_action_name(OPEN_INVENTORY)
    action.set_display_name("Inventory")
    var defaults: Array[CommonUIBinding] = [keyboard, gamepad]
    action.set_default_bindings(defaults)
    action.set_display_priority(40)
    action.set_show_in_action_bar(true)

    var config := CommonUIDefaults.build_default_config()
    var actions := config.get_actions()
    actions.append(action)
    config.set_actions(actions)
    # Increment when the definition set changes so incompatible saved overrides
    # are rejected rather than silently applied to a new schema.
    config.set_definition_version(2)

    var findings := CommonUIActionValidator.validate(config)
    if not CommonUIActionValidator.is_ok(findings):
        push_error(CommonUIActionValidator.format(findings))
        return
    CommonUI.set_input_config(config)
```

You can author the same object graph as `.tres` resources in the inspector.
Call `set_input_config()` once the final resource is ready and before screens
register behavior. Setting a new config replaces the definition set; it does
not merge with the old config automatically. The registry copies validated
binding values, so after mutating a live config/binding resource, call
`set_input_config()` again to apply the new definition deliberately.

### `CommonUIAction` fields

| Property | Default | Purpose |
|---|---:|---|
| `action_name` | empty | Stable `common_ui/...` identifier |
| `display_name` | empty | Label shown by `ActionBar` |
| `conflict_context` | empty | Binding conflict group; empty is global |
| `default_bindings` | `[]` | Up to one effective binding per primary/secondary slot |
| `hold_threshold` | `0.4` s | Delay before `PHASE_HOLD_STARTED` |
| `repeat_interval` | `0.1` s | Repeat cadence after a hold starts |
| `repeat_enabled` | `false` | Whether `PHASE_HOLD_REPEAT` is generated |
| `display_priority` | `0` | Higher actions appear first in `ActionBar` |
| `show_in_action_bar` | `true` | Whether active registrations are advertised |
| `protection` | `PROTECTION_NONE` | Rules for rebinding/clearing |

Protection modes are:

- `PROTECTION_NONE`: freely rebindable and may be left unbound.
- `PROTECTION_REQUIRED`: must keep at least one binding.
- `PROTECTION_CONFIRM`: must keep a binding and changing it requires
  `confirmed = true`.

`conflict_context` applies only to *binding conflicts*, not runtime routing.
Two non-global actions may share one physical binding when their conflict
contexts differ. An empty conflict context conflicts with every action using
that physical binding.

### `CommonUIBinding` fields

| Property | Meaning |
|---|---|
| `device_kind` | Keyboard, mouse, gamepad button, gamepad axis, or touch |
| `slot` | `SLOT_PRIMARY` or `SLOT_SECONDARY` |
| `code` | Key code, mouse button, joy button, or joy axis index |
| `axis_direction` | Required positive/negative direction for a gamepad axis |
| `dead_zone` | Axis threshold, clamped to `0.0..1.0` |
| modifier booleans | Exact Shift/Ctrl/Alt/Meta state for keyboard/mouse |
| `glyph_id` | Device-agnostic logical glyph id |

Useful checks are:

```gdscript
binding.is_valid_binding()
binding.get_signature()   # stable identity used for conflict detection
binding.to_input_event()  # event projected into InputMap
```

For keyboard and mouse, the signature includes exact modifiers. `Shift+I` and
`I` are therefore distinct for conflict checks and press matching.

### `CommonUIInputPolicy`

The config's optional input policy controls when observed input is intentional
enough to switch modality and how unassigned devices route:

| Property | Default | Meaning |
|---|---:|---|
| `mouse_jitter_threshold` | `8.0` px | Accumulated mouse motion needed to take modality from another device |
| `stick_dead_zone` | `0.25` | Smaller axis motion is drift and cannot start an action or switch modality |
| `modality_hysteresis` | `0.15` s | Minimum dwell before a different modality takes over |
| `mouse_motion_decay` | `0.5` s | Gap after which accumulated mouse motion is discarded as stale |
| `mouse_button_always_activates` | `true` | A click can switch to keyboard/mouse without meeting the motion threshold |
| `unassigned_devices_use_default_user` | `true` | Unassigned raw devices route to UI user 0 |
| `shared_device_policy` | `false` | Reserved shared-device policy flag; see the current boundary below |

Values below zero are clamped to zero; the stick dead zone is clamped to
`0.0..1.0`. The current Godot façade routes each event to one UI user even when
`shared_device_policy` is enabled, so do not treat that flag as multi-user
fan-out.

## Register behavior on an active screen

Register screen behavior in `_on_activated()`. The helper fills in owner,
screen, layer, and (when non-empty) the screen context. Deactivation releases
the returned handle automatically.

```gdscript
extends CommonActivatableScreen

signal inventory_requested

const OPEN_INVENTORY := &"common_ui/open_inventory"


func _init() -> void:
    screen_context = &"gameplay"


func _on_activated() -> void:
    register_action(OPEN_INVENTORY, _on_open_inventory, {"priority": 10})


func _on_open_inventory(event: Dictionary) -> int:
    if event["phase"] != CommonUIRuntime.PHASE_PRESSED:
        return CommonUIRuntime.ROUTE_UNHANDLED
    inventory_requested.emit()
    return CommonUIRuntime.ROUTE_HANDLED
```

Use a named method when possible: it is easier to reconnect correctly after a
screen is uncovered and easier to find in route diagnostics.

### Choosing a route result

- Return `ROUTE_UNHANDLED` when this handler declines the press. Routing keeps
  searching and the handler does not receive later phases.
- Return `ROUTE_HANDLED` for the usual case: consume the Godot event, capture
  this handler for later phases, and stop searching.
- Return `ROUTE_HANDLED_CONTINUE` when this handler should consume/capture but a
  lower handler must also observe the same logical press. This is useful for
  analytics or shared behavior, but it should be intentional.

The pressed callback must return synchronously. Do not make it an async
function. Emit a signal or call `request_push()`/`request_pop()` to begin work
that completes later.

### Raw runtime registration

Use `CommonUI.register_action()` for a handler not owned by an activatable
screen:

```gdscript
var handle: CommonUIActionHandle
var context_handle: CommonUIContextHandle


func _ready() -> void:
    context_handle = CommonUI.push_context(&"gameplay", 0)
    handle = CommonUI.register_action(
        CommonUIDefaults.MENU,
        _on_menu,
        {
            "owner": self,
            "context": &"gameplay",
            "priority": 5,
            "ui_user": 0,
        }
    )


func _exit_tree() -> void:
    if handle != null:
        handle.release()
    if context_handle != null:
        context_handle.release()
```

Recognized options are `owner`, `context`, `layer`, `screen`, `priority`,
`ui_user`, `viewport`, `hold_threshold`, `repeat_interval`, and
`repeat_enabled`. Unknown keys warn once. Legacy `display_priority` and
`show_in_action_bar` keys are accepted but ignored; presentation comes from the
matching `CommonUIAction` definition.

The callback's bound object is the default owner. Pass `owner` explicitly when
that is not the intended lifetime. Retain the handle only if you need to query
or release it early; dropping the handle reference does not unregister it.

## Hold and repeat

Enable repeat on the action definition when every handler should share one
policy:

```gdscript
action.set_hold_threshold(0.35)
action.set_repeat_enabled(true)
action.set_repeat_interval(0.08)
```

Then respond to the phases you need:

```gdscript
func _on_next_tab(event: Dictionary) -> int:
    var phase: int = event["phase"]
    if phase == CommonUIRuntime.PHASE_PRESSED \
            or phase == CommonUIRuntime.PHASE_HOLD_REPEAT:
        select_next_tab()
        return CommonUIRuntime.ROUTE_HANDLED
    if phase == CommonUIRuntime.PHASE_CANCELED:
        stop_press_feedback()
    return CommonUIRuntime.ROUTE_UNHANDLED
```

Only the pressed return controls capture. Return values for hold, repeat,
release, and cancel are ignored.

A registration can override trigger timing in its options. Supplying *any* of
`hold_threshold`, `repeat_interval`, or `repeat_enabled` makes the registration's
complete trigger policy authoritative, so specify all three together:

```gdscript
register_action(&"common_ui/step", _on_step, {
    "hold_threshold": 0.30,
    "repeat_interval": 0.07,
    "repeat_enabled": true,
})
```

The first handler captured for a press supplies the registration-level override
for that entire trigger chain.

## Rebinding safely

Get the single authoritative registry from the runtime:

```gdscript
var registry: CommonInputBindingRegistry = CommonUI.get_binding_registry()
```

`set_input_config()` creates/configures this registry. Rebinding before a config
is installed has no useful action definitions.

A change is transactional:

1. Validate action, binding, protection, and conflicts.
2. Apply the change to an in-memory snapshot.
3. Save only differences from defaults to
   `user://common_ui_bindings.json`.
4. Rebuild the addon's namespaced `InputMap` actions.
5. Emit `bindings_changed`.

If saving fails, the in-memory state and `InputMap` projection roll back. The
registry emits `binding_error(message)` and the previous bindings stay active.

### Direct rebind example

```gdscript
func bind_inventory_to_k() -> Dictionary:
    var candidate := CommonUIBinding.new()
    candidate.set_device_kind(CommonUIBinding.DEVICE_KEYBOARD)
    candidate.set_code(KEY_K)
    candidate.set_slot(CommonUIBinding.SLOT_PRIMARY)
    candidate.set_glyph_id(&"key_k")

    var registry := CommonUI.get_binding_registry()
    var result: Dictionary = registry.rebind(
        &"common_ui/open_inventory",
        CommonInputBindingRegistry.SLOT_PRIMARY,
        candidate,
        CommonInputBindingRegistry.CONFLICT_REJECT,
        false
    )
    return result
```

Every mutation returns:

```text
{
  ok: bool,
  error: String,
  needs_confirmation: bool,
  conflicts: Array[Dictionary] # each {action, slot, protected}
}
```

Conflict policies:

| Policy | Behavior |
|---|---|
| `CONFLICT_REJECT` | Change nothing; report all conflicts |
| `CONFLICT_REPLACE` | Clear conflicting slots, unless that would remove the last binding of a protected action |
| `CONFLICT_ALLOW_DUPLICATE` | Allow several actions to share the physical binding |

A confirmation flow should keep the candidate in your controller code, show the
reported conflicts, then retry explicitly:

```gdscript
func apply_confirmed_replacement(
    action: StringName,
    slot: int,
    candidate: CommonUIBinding
) -> Dictionary:
    return CommonUI.get_binding_registry().rebind(
        action,
        slot,
        candidate,
        CommonInputBindingRegistry.CONFLICT_REPLACE,
        true
    )
```

Other operations are:

```gdscript
registry.clear_binding(action, slot, confirmed)
registry.restore_action_defaults(action)
registry.restore_defaults()
registry.get_effective_binding(action, slot)
registry.find_conflicts(action, slot, candidate) # read-only preview
registry.get_action_names()
registry.has_action(action)
```

`definition_version` in the saved file must exactly match the active
`CommonUIInputConfig`. Increment the config version when action ids, slots, or
protection rules change. A mismatched or malformed saved document is rejected
as a whole, reports `binding_error`, and leaves defaults/current state intact.

### `BindingEntry`

The shipped `BindingEntry` captures the next key, mouse button, joypad button,
or sufficiently large joypad-axis motion and first tries
`CONFLICT_REJECT`. It emits:

- `rebind_finished(result)` for every attempted transaction;
- `conflict_detected(conflicts)` when the candidate was rejected for conflicts.

It intentionally delegates policy/UI decisions to the game. Its public
`apply_with_replace(candidate, confirmed)` can retry a candidate your own
controller retained. The stock row does not include the candidate in
`conflict_detected`, so use the registry directly (or wrap the row with your own
capture controller) when your confirmation dialog needs to retry the exact
captured event.

## Device profiles and glyph artwork

A `CommonUIDeviceProfile` maps platform controller names to a family and that
family's logical glyph ids:

```gdscript
var xbox := CommonUIDeviceProfile.new()
xbox.set_family_id(&"xbox")
xbox.set_name_patterns(PackedStringArray(["xbox", "xinput"]))
xbox.set_glyph_map({
    "2:%d" % JOY_BUTTON_A: &"xbox_a",
    "2:%d" % JOY_BUTTON_B: &"xbox_b",
    "2:%d" % JOY_BUTTON_Y: &"xbox_y",
})
xbox.set_fallback_glyph_id(&"pad_generic")

var profiles := config.get_device_profiles()
profiles.append(xbox)
config.set_device_profiles(profiles)
```

`name_patterns` are case-insensitive substrings of Godot's joypad name. The
first matching profile wins. `glyph_map` keys use
`"<CommonUIBinding.DeviceKind integer>:<code>"`; modifiers and axis direction
are not part of a profile-map key.

Resolution for one requested action slot is:

1. Find its effective binding.
2. If the active gamepad name matches a profile, check the profile map.
3. Fall back to the binding's own `glyph_id`.
4. Fall back to the profile's `fallback_glyph_id`.
5. Return an empty id if none exists.

`InputGlyph.glyph_set` then maps that logical id to a `Texture2D`:

```gdscript
@onready var hint: InputGlyph = %InventoryHint


func _ready() -> void:
    hint.action = &"common_ui/open_inventory"
    hint.slot = CommonInputBindingRegistry.SLOT_PRIMARY
    hint.glyph_set = {
        &"key_i": preload("res://ui/glyphs/key_i.svg"),
        &"xbox_y": preload("res://ui/glyphs/xbox_y.svg"),
        &"pad_generic": preload("res://ui/glyphs/pad_generic.svg"),
    }
```

`slot` determines which binding is used for texture-id resolution. If no
texture is found, the widget's text fallback searches the selected slot first
and then the other slot for a binding matching the current modality. For a
custom prompt that must swap between primary keyboard and secondary gamepad
*textures*, update `slot` on `input_modality_changed` or provide a custom widget
that chooses the desired slot.

No controller artwork ships with the addon; games supply licensed art and
localized text themselves.

For a label without a widget, use the stateless formatter:

```gdscript
var binding := CommonUI.get_binding_registry().get_effective_binding(
    CommonUIDefaults.BACK,
    CommonInputBindingRegistry.SLOT_PRIMARY
)
var short_label := CommonBindingText.describe(binding) # for example, "Esc"
```
