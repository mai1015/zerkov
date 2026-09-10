# CommonUI for Godot

CommonUI is a screen-stack and input-routing framework for Godot 4.7+. It is
designed for interfaces that must work consistently with mouse, keyboard,
controller, and touch: HUDs, menus, pause screens, settings, modals, input
prompts, and rebinding screens.

You do not need to read the C++ or GDScript implementation to use it. Start
with this page, then open the guide for the part you are building.

## What the addon owns

CommonUI separates four jobs that are easy to tangle together in a large UI:

1. `CommonUIRuntime`, installed as the `CommonUI` autoload, observes input and
   deterministically chooses which action handler receives it.
2. `CommonUIInputConfig` defines logical actions, their default bindings,
   trigger timing, action-bar metadata, and controller glyph profiles.
3. `CommonUILayer` serializes screen-stack changes. Only the top screen of a
   layer is routing-active.
4. Controls such as `CommonButton`, `ActionBar`, `InputGlyph`, and
   `BindingEntry` present that state without becoming a second source of truth.

The native GDExtension is authoritative. There is no GDScript fallback, so the
matching native library must be present for every platform you run or export.

## Requirements and platform check

- Godot 4.7 or newer, single-precision build.
- The complete `addons/common_ui/` directory, including `bin/`.
- A native artifact matching the target, architecture, and debug/release mode.

Check [`release_manifest.json`](release_manifest.json) before shipping. A
target is supported only when its entry is `validated` and has a checksum.
This package currently contains macOS universal debug and release artifacts,
but the manifest marks them `built`, not `validated`; the other declared
targets are `planned`. Treat the manifest, rather than the presence of a row in
`common_ui.gdextension`, as the support source of truth.

## Ten-minute setup

### 1. Install and enable

Copy this whole directory to:

```text
res://addons/common_ui/
```

In Godot, open **Project > Project Settings > Plugins** and enable
**CommonUI**. The plugin adds this autoload:

```text
/root/CommonUI  ->  res://addons/common_ui/runtime/common_ui_autoload.tscn
```

If the plugin reports missing native classes, do not continue with a partial
setup. Install or build the artifact named by the error. You can print the same
diagnostic yourself:

```gdscript
if not CommonUIBoot.is_native_runtime_available():
    push_error(CommonUIBoot.describe_missing_runtime())
```

### 2. Add the standard screen root

Instance
[`runtime/common_ui_screen_root.tscn`](runtime/common_ui_screen_root.tscn) as a
child of your main scene. It creates four full-rect layers:

| Layer | Priority | Typical content |
|---|---:|---|
| `hud` | 0 | Gameplay HUD and persistent prompts |
| `menu` | 50 | Main, pause, inventory, and settings screens |
| `modal` | 100 | Confirmation and alert dialogs |
| `popup` | 150 | Notifications or UI that must route above everything else |

It also creates an `ActionBar` and installs the default input configuration if
the runtime does not already have one. The defaults define Back, Confirm, Menu,
Next Tab, and Previous Tab for keyboard and controller.

If you supply a custom `CommonUIInputConfig`, turn off
`install_default_config` on the screen root and call
`CommonUI.set_input_config(config)` before pushing the first screen.

### 3. Make a screen

Create a scene whose root script extends `CommonActivatableScreen` or
`CommonAnimatedScreen`. The latter adds configurable fade, scale, and slide
transitions.

```gdscript
extends CommonAnimatedScreen

signal play_requested

@onready var play_button: CommonButton = $Panel/Buttons/PlayButton


func _init() -> void:
    screen_context = &"main_menu"
    context_priority = 50
    default_focus = NodePath("Panel/Buttons/PlayButton")
    handles_back = true


func _ready() -> void:
    # Connect ordinary control signals once. A screen can activate many times.
    play_button.triggered.connect(func() -> void: play_requested.emit())
```

Use a `CommonButton` node for `PlayButton`. A `CommonButton` emits `triggered`
for a pointer/keyboard GUI activation and, when its `action` property is set,
for a routed CommonUI action too.

`handles_back = true` makes Back pop this screen from its owning layer. Leave
it false when the screen needs custom Back behavior and register your own
handler in `_on_activated()`.

### 4. Push it onto a layer

```gdscript
const MainMenuScene := preload("res://ui/main_menu.tscn")

@onready var ui: CommonUIScreenRoot = $CommonUIScreenRoot


func open_main_menu() -> void:
    var result := await ui.menu_layer().push_screen(MainMenuScene)
    if result["status"] == CommonUIStackRequest.Status.ERROR:
        push_error(result["error"])
```

`push_screen()` accepts a `PackedScene` or an existing
`CommonActivatableScreen`. It returns only after activation and any transition
finish. Push, pop, replace, and teardown requests are serialized, so callers
never observe a half-transitioned stack.

### 5. Open a modal

```gdscript
func ask_to_quit() -> void:
    var dialog := await ui.open_dialog(
        "Quit game?",
        "Unsaved progress will be lost.",
        "Quit",
        "Stay"
    )
    dialog.confirmed.connect(
        func() -> void: get_tree().quit(),
        CONNECT_ONE_SHOT
    )
```

`open_dialog()` pushes the shipped `CommonDialog` on the modal layer. It
suspends the HUD/menu contexts beneath it, traps focus inside the dialog, and
automatically pops itself after `confirmed` or `dismissed`.

## Rules worth knowing on day one

- Put action registrations in a screen's `_on_activated()`. The screen releases
  them automatically on deactivation and recreates them when uncovered.
- An action callback must synchronously return `ROUTE_UNHANDLED`,
  `ROUTE_HANDLED`, or `ROUTE_HANDLED_CONTINUE` for the pressed phase. Falling
  off the end is treated as unhandled and warns once.
- A configured binding makes a physical event recognizable; a registered
  handler says what should happen now. You normally need both.
- Higher context and layer priorities route first. A screen-scoped handler is
  eligible only while that screen is the top of its layer.
- `CommonUILayer` owns the presentation stack for UI user 0 in the root
  viewport. The native façade supports additional `(ui_user, Viewport)` scopes,
  but those are a lower-level integration; see the architecture guide before
  using them.
- Godot's focus-based `ui_*` actions run before CommonUI routing. Keep
  `ui_accept` aligned with the physical inputs that should activate a focused
  button (including a rebound Confirm action). For framework-only actions that
  must still route while a `Control` has focus, avoid `ui_*` collisions. Run
  `CommonUIActionValidator` to find bindings that need review.

## Documentation map

- [How CommonUI works](docs/how-it-works.md) — ownership, input pipeline,
  routing order, trigger capture, and lifecycle.
- [Screens and layers](docs/screens-and-layers.md) — build screens, transitions,
  dialogs, focus, stack transactions, and custom layer setups.
- [Actions, bindings, and glyphs](docs/actions-bindings-and-glyphs.md) — define
  actions, register handlers, handle holds/repeats, rebind safely, and supply
  controller artwork.
- [Widgets and diagnostics](docs/widgets-and-diagnostics.md) — shipped controls,
  validation, the live overlay, troubleshooting, and current limitations.

When working from the full source checkout, the runnable vertical slice is in
[`../../examples/reference/`](../../examples/reference/) and the larger
showcase is in [`../../examples/showcase/`](../../examples/showcase/). These
examples are not required by the distributable addon.

## License

CommonUI is MIT licensed; see [LICENSE](LICENSE). Third-party notices are in
[THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).
