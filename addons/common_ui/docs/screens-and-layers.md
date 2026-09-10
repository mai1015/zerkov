# Screens and layers

[Back to the package README](../README.md) · [Architecture and lifecycle](how-it-works.md)

The screen API is the normal way to build with CommonUI. A layer owns a stack
of `CommonActivatableScreen` nodes, and the runtime considers only the top of
that stack routing-active. The layer serializes every mutation so transitions,
focus, contexts, and registrations settle together.

Layers are independent. The HUD top can remain active while the menu layer has
its own top; context/layer priority decides which handler runs first, and an
unhandled action may continue to the lower layer. Use context suspension for an
overlay that must block everything beneath it.

## Start with `CommonUIScreenRoot`

Instance
[`../runtime/common_ui_screen_root.tscn`](../runtime/common_ui_screen_root.tscn)
under your main scene. It creates the standard layers and exposes them through:

```gdscript
ui.hud_layer()
ui.menu_layer()
ui.modal_layer()
ui.popup_layer()
ui.layer(CommonUIDefaults.LAYER_MENU) # The same object as ui.menu_layer().
```

`layer(id)` and `push_to(id, ...)` resolve the four layers created by this root.
Adding a custom `CommonUILayer` child does not add it to that lookup table;
retain your custom layer reference and call its stack methods directly.

The root fills the viewport, ignores pointer input itself, and puts higher
priority layers later in the scene tree so they draw above lower layers. Its
direct children run while `SceneTree.paused`, including the default action bar.

Exports:

| Property | Default | Effect |
|---|---:|---|
| `install_default_config` | `true` | Installs `CommonUIDefaults.build_default_config()` only when the runtime has no config |
| `show_action_bar` | `true` | Creates one shared `ActionBar` along the bottom |

Common helpers:

```gdscript
await ui.push_to(CommonUIDefaults.LAYER_MENU, MenuScene)
var dialog := await ui.open_dialog("Delete?", "This cannot be undone.")
```

`open_dialog()` is more than a scene factory: it gathers context handles from
the routing-active HUD/menu screens, passes them to the dialog for suspension,
pushes it on the modal layer, and connects both outcomes to an automatic pop.

## Author a screen scene

Use one of these as the root script:

- `CommonActivatableScreen` for your own lifecycle/animation.
- `CommonAnimatedScreen` for built-in fade, scale, or slide transitions.
- `CommonDialog` as-is, inherited, or re-themed for standard modal behavior.

A practical screen usually has a scene file and a script:

```text
PauseMenu (Control, script extends CommonAnimatedScreen)
└── Panel
    └── Buttons
        ├── ResumeButton (CommonButton)
        └── OptionsButton (CommonButton)
```

```gdscript
extends CommonAnimatedScreen

signal resume_requested
signal options_requested

@onready var resume_button: CommonButton = $Panel/Buttons/ResumeButton
@onready var options_button: CommonButton = $Panel/Buttons/OptionsButton


func _init() -> void:
    screen_context = &"pause_menu"
    context_priority = 50
    default_focus = NodePath("Panel/Buttons/ResumeButton")
    enter_transition = Transition.SCALE
    exit_transition = Transition.SCALE


func _ready() -> void:
    # Connect node signals once. `_on_activated()` may run many times.
    resume_button.triggered.connect(func() -> void: resume_requested.emit())
    options_button.triggered.connect(func() -> void: options_requested.emit())


func _on_activated() -> void:
    # Registrations belong here because deactivation releases them.
    register_action(CommonUIDefaults.BACK, _on_back)


func _on_back(event: Dictionary) -> int:
    if event["phase"] != CommonUIRuntime.PHASE_PRESSED:
        return CommonUIRuntime.ROUTE_UNHANDLED
    resume_requested.emit()
    return CommonUIRuntime.ROUTE_HANDLED
```

The flow/controller that owns the layer handles those requests:

```gdscript
const PauseMenuScene := preload("res://ui/pause_menu.tscn")
const OptionsScene := preload("res://ui/options_menu.tscn")

@onready var ui: CommonUIScreenRoot = $CommonUIScreenRoot


func open_pause_menu() -> void:
    var result := await ui.menu_layer().push_screen(PauseMenuScene)
    if result["status"] != CommonUIStackRequest.Status.SUCCESS:
        return
    var pause_menu := result["screen"]
    pause_menu.resume_requested.connect(close_top_menu)
    pause_menu.options_requested.connect(open_options)
    get_tree().paused = true


func close_top_menu() -> void:
    var result := await ui.menu_layer().pop_screen()
    if result["status"] == CommonUIStackRequest.Status.SUCCESS \
            and ui.menu_layer().get_depth() == 0:
        get_tree().paused = false


func open_options() -> void:
    await ui.menu_layer().push_screen(OptionsScene)
```

The standard layers are pause-immune, so the transition and controls continue
while the rest of the scene tree is paused.

### Simpler Back behavior

If Back always means “pop me,” set:

```gdscript
handles_back = true
```

The screen registers `CommonUIDefaults.BACK` on activation and asks its parent
layer to pop on a press. Leave this off when Back first closes an internal
panel, prompts for unsaved changes, or emits a higher-level navigation request.

## Screen exports and hooks

### Configuration

| Property | Default | Meaning |
|---|---:|---|
| `screen_context` | empty | Context pushed while active; empty adds no context |
| `context_priority` | `0` | Priority of that context |
| `suspends_lower_contexts` | `false` | Suspend context handles returned by `_collect_lower_contexts()` |
| `default_focus` | empty | Preferred focus target on first activation |
| `keep_alive_when_popped` | `false` | Hide instead of free after pop |
| `handles_back` | `false` | Automatically register Back and pop this screen |

### Lifecycle hooks

Override these rather than `activate()`/`deactivate()`:

```gdscript
func _on_activating() -> void:   # may await; runs before ACTIVE
func _on_activated() -> void:    # register actions here
func _on_deactivating() -> void: # may await; actions already released
func _on_deactivated() -> void:
```

`CommonAnimatedScreen` already implements `_on_activating()` and
`_on_deactivating()`. Prefer its exported transition settings and use
`_on_activated()`/`_on_deactivated()` for game behavior. If you replace an
animation hook, you replace the built-in transition for that direction too.

Public state helpers:

```gdscript
screen.is_routing_active()
screen.get_context_handle()
screen.register_action(action, callback, options)
screen.release_actions()
screen.restore_focus()
```

Let the layer drive `activate()`, `deactivate()`, and `cancel_activation()`.
Calling those directly bypasses stack bookkeeping and can make visual and
native top-screen state disagree.

## Stack operations

The high-level methods wait for a settled result:

```gdscript
await layer.push_screen(source, options)
await layer.pop_screen(options)
await layer.replace_screen(source, options)
await layer.teardown()
```

`source` may be a `PackedScene` or an existing
`CommonActivatableScreen`. The current implementation stores the optional
`options` dictionary on the request for extensions/inspection but does not
interpret any keys.

Every result has this shape:

```text
{
  status: CommonUIStackRequest.Status,
  screen: CommonActivatableScreen,
  error: String
}
```

| Status | Meaning |
|---|---|
| `SUCCESS` | The request completed. `screen` is the pushed/replacement screen, or the newly exposed top after a pop. |
| `CANCELED` | The request was coalesced or no longer applied; the stack is unchanged. |
| `ERROR` | Instantiation/ownership failed; the stack is unchanged. Read `error`. |

Pushing the existing top is an idempotent success. Pushing a screen already
buried in the same layer raises it instead of duplicating it. Pushing an
instance parented to a different node is an error.

`replace_screen()` instantiates the destination before disturbing the current
top. If activation later cancels, it restores the previous screen. A successful
replace emits `screen_popped` for the outgoing top and `screen_pushed` for the
incoming screen.

### Queue without awaiting

Use `request_*` when an input callback or coordinator must enqueue immediately:

```gdscript
var request := layer.request_push(SettingsScene)
request.finished.connect(_on_settings_push_finished)

# Or await safely later. `wait()` returns cached data if already completed.
var result := await request.wait()
```

Available requests are `request_push`, `request_pop`, `request_replace`, and
`request_teardown`.

The queue has two explicit coalescing rules:

1. A pending push immediately followed by another push of the exact same
   `source` is canceled in favor of the newer one. Button mashing cannot create
   one screen per press during an existing transition.
2. Queuing teardown cancels everything still pending because none of those
   requests applies after the stack is cleared.

Requests already running always finish. Other sequences remain FIFO; for
example, unrelated push then pop is not optimized away.

### Layer queries and signals

```gdscript
layer.get_depth()
layer.get_top_screen()
layer.has_screen(screen)
```

Signals:

- `stack_changed(depth)` after a successful mutation;
- `screen_pushed(screen)` for push and the incoming side of replace;
- `screen_popped(screen)` for pop, the outgoing side of replace, and each
  screen removed by teardown.

## Keep-alive screens

Set `keep_alive_when_popped = true` for an expensive screen you intend to reuse.
After pop it remains parented to the layer but hidden. Keep your own reference,
then push that instance again:

```gdscript
var inventory_screen: CommonActivatableScreen


func ensure_inventory() -> void:
    if inventory_screen == null:
        inventory_screen = InventoryScene.instantiate()
        inventory_screen.keep_alive_when_popped = true
    await ui.menu_layer().push_screen(inventory_screen)
```

The layer reactivates the instance, recreates its context/action registrations,
and restores remembered focus when possible. Do not reconnect ordinary button
signals on every activation; connect them once in `_ready()`.

## Focus behavior

On activation a screen tries, in order:

1. its remembered focus from a prior activation;
2. `default_focus`;
3. the first visible, enabled, focusable descendant.

Every candidate must still be inside the screen. When a screen is covered, the
layer disables focus on its descendant controls so directional navigation
cannot land on controls visible behind the active top. Those focus modes are
restored when it becomes top again.

### Modal focus containment

`suspends_lower_contexts` is the modal switch. During activation it:

- suspends the lower context handles returned by `_collect_lower_contexts()`;
- contains explicit navigation paths inside the modal;
- fills empty directional paths using the nearest modal-local control after
  layout settles;
- traps focus as a backstop if code tries to focus a control behind it; and
- restores every authored neighbor path when the modal closes.

The base `_collect_lower_contexts()` returns an empty array because a screen
does not know the rest of your UI hierarchy. `CommonUIScreenRoot.open_dialog()`
supplies the active HUD/menu handles to the shipped `CommonDialog`. For a custom
modal, pass the handles explicitly and override the hook:

```gdscript
extends CommonAnimatedScreen

var lower_contexts: Array[CommonUIContextHandle] = []


func _init() -> void:
    screen_context = &"save_prompt"
    context_priority = 100
    suspends_lower_contexts = true


func set_lower_contexts(handles: Array[CommonUIContextHandle]) -> void:
    lower_contexts = handles


func _collect_lower_contexts() -> Array[CommonUIContextHandle]:
    return lower_contexts
```

Suspension begins before the intro hook, while the modal's own context/actions
become available only after activation completes. During the transition,
neither the modal nor the covered screen can accidentally act.

## Built-in transitions

`CommonAnimatedScreen.Transition` supports:

```text
NONE, FADE, SCALE, SLIDE_LEFT, SLIDE_RIGHT, SLIDE_UP, SLIDE_DOWN
```

Exports:

| Property | Default | Notes |
|---|---:|---|
| `enter_transition` | `FADE` | Intro transition |
| `exit_transition` | `FADE` | Exit transition; same directional value reverses on close |
| `duration` | `0.16` s | Non-positive is instant |
| `scale_from` | `0.92` | Start/end scale for `SCALE` |
| `transition_curve` | `TRANS_CUBIC` | Tween curve |
| `easing` | `EASE_OUT` | Tween ease |
| `animations_enabled` | `true` | Per-screen switch |

Tweens continue while the scene tree is paused. A screen covered by another
screen skips its exit animation and remains fully shown behind it; a real pop
plays the exit transition.

Set this project setting for a global reduced-motion switch:

```gdscript
ProjectSettings.set_setting("common_ui/disable_screen_animations", true)
```

Slide transitions animate the screen root's `position`. A screen placed
directly under a `CommonUILayer` is safe; if you manually place it under a
`Container`, animate a child instead because the container can reset position.

## Custom layers

You can add a `CommonUILayer` beside the defaults:

```gdscript
var tutorial_layer := CommonUILayer.new()
tutorial_layer.name = "TutorialLayer"
tutorial_layer.layer_id = &"tutorial"
tutorial_layer.layer_priority = 75
tutorial_layer.layer_active = true
tutorial_layer.pause_immune = true
tutorial_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
tutorial_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
ui.add_child(tutorial_layer)
# Routing priority does not change CanvasItem draw order. Put priority 75
# visually between the built-in menu (50) and modal (100) layers.
ui.move_child(tutorial_layer, ui.modal_layer().get_index())
```

Set `layer_id` and `layer_priority` before adding it to the tree; `_ready()`
registers those values with the runtime. Changing either plain configuration
value later does not reconfigure native state automatically. An empty id is a
configuration error. Pushing a screen to an unconfigured native layer is a
warned no-op.

`layer_priority` controls native routing order only. Scene-tree order (or an
explicit `z_index`) controls drawing. The standard root orders its four layers
for you; place a custom child deliberately, as the example does. Keep the
`tutorial_layer` reference because `ui.layer(&"tutorial")` and
`ui.push_to(&"tutorial", ...)` do not discover manually added children.

`layer_active = false` keeps the visual stack but makes its handlers ineligible.
Re-enabling it restores eligibility without rebuilding the stack.

`pause_immune = true` sets the layer to `PROCESS_MODE_ALWAYS` when it becomes
ready. If you change that property after `_ready()`, also set `process_mode`
yourself; the property has no runtime setter for process mode.

The convenience layer/screen implementation currently targets UI user 0 and
the root viewport. Use the low-level scoped façade described in
[How CommonUI works](how-it-works.md#root-viewport-subviewports-and-ui-users)
for a custom split-screen wrapper.

## Dialog behavior

The shipped `CommonDialog` extends `CommonAnimatedScreen` and defaults to a
scale transition. Configure it directly or use `CommonUIScreenRoot.open_dialog`:

```gdscript
var dialog := CommonDialog.new().configure(
    "Overwrite save?",
    "Slot 2 already contains a save.",
    "Overwrite",
    "Cancel",
    true
)
dialog.set_lower_contexts(lower_handles)
await ui.modal_layer().push_screen(dialog)
```

Signals are `confirmed` and `dismissed`. The dialog has two interaction modes:

- It opens in quick-action mode. Confirm/Back act directly and their hint
  glyphs are visible.
- The first directional input switches to focus mode and hides those hints.
  Confirm activates the focused button. Back first focuses Cancel and dismisses
  only when Cancel is already focused. A one-button alert dismisses on Back.

When pushing a dialog directly, you own signal-to-pop wiring. The screen root's
`open_dialog()` installs it for you.

## What not to do

- Do not add screens to a layer with `add_child()` and expect stack routing.
  Use `push_screen()`.
- Do not call `queue_free()` as your normal pop mechanism. External removal is
  repaired, but it cannot return a transaction result to your flow.
- Do not register actions only in `_ready()` on a screen. Deactivation releases
  them, and `_ready()` will not run when the screen is merely uncovered.
- Do not connect the same control signal with a fresh lambda in every
  `_on_activated()` unless you also disconnect it. Activation may happen many
  times.
- Do not use `keep_alive_when_popped` without retaining the instance you plan
  to push again.
