extends SceneTree

## Exact first-playable input regressions. The runner boots the authored
## CommonUI-backed screens at one fixed viewport and exercises all three input
## modalities through the real route, modal and binding services.
## Run with: godot --headless --path . --audio-driver Dummy \
##   --script res://tests/common_ui_input_regression_1080.gd
const FIRST_PLAYABLE_SIZE := Vector2i(1920, 1080)

const InputActions = preload("res://game/input/zerkov_input_actions.gd")

var app: Control
var checks := 0
var failures := 0


func _initialize() -> void:
	run.call_deferred()


func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error("COMMON_UI_INPUT_1080: " + message)


func settle() -> void:
	for _frame in range(10):
		await process_frame


func focus_is_inside(owner: Node) -> bool:
	var focused := root.gui_get_focus_owner()
	return focused != null and (focused == owner or owner.is_ancestor_of(focused))


func push_key(code: Key) -> void:
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.keycode = code
		event.physical_keycode = code
		event.pressed = pressed
		root.push_input(event)


func key(code: Key) -> void:
	push_key(code)
	await settle()


func push_joypad_button(code: JoyButton) -> void:
	for pressed in [true, false]:
		var event := InputEventJoypadButton.new()
		event.button_index = code
		event.pressed = pressed
		event.pressure = 1.0 if pressed else 0.0
		root.push_input(event)


func joypad_button(code: JoyButton) -> void:
	push_joypad_button(code)
	await settle()


func click(control: Control) -> void:
	var position := control.get_global_rect().get_center()
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.position = position
	down.pressed = true
	root.push_input(down)
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.position = position
	up.pressed = false
	root.push_input(up)
	await settle()


func key_binding(code: Key, slot: int = CommonUIBinding.SLOT_PRIMARY) -> CommonUIBinding:
	var binding := CommonUIBinding.new()
	binding.set_device_kind(CommonUIBinding.DEVICE_KEYBOARD)
	binding.set_code(code)
	binding.set_slot(slot)
	return binding


func current_controls() -> ZScreen:
	return app.screen as ZScreen


func controls_button(action: String, column: String) -> Button:
	var controls := current_controls()
	var suffix := ""
	for part in action.split("_"):
		suffix += str(part).capitalize()
	match column:
		"primary": suffix += "Primary"
		"secondary": suffix += "Secondary"
		_: suffix += "Controller"
	return controls.get_node("BindingsPane/BindingsBody/" + suffix) as Button


func open_confirm(owner: ZScreen, count: Dictionary) -> bool:
	return owner.app.confirm("INPUT OWNERSHIP", "Only the active modal may consume this input.",
		func() -> void: count.value += 1)


func run() -> void:
	root.size = FIRST_PLAYABLE_SIZE
	app = load("res://ui/main.tscn").instantiate() as Control
	app.name = "CommonUIInput1080Host"
	root.add_child(app)
	await settle()
	var service := app.input_service as ZerkovInputService
	var screen_root := app.common_ui_root as CommonUIScreenRoot
	check(root.get_visible_rect().size == Vector2(FIRST_PLAYABLE_SIZE),
		"runner keeps the exact first-playable viewport")
	check(service != null and service.is_configured(),
		"production host exposes the configured game-owned input facade")
	if service == null or not service.is_configured():
		print("COMMON_UI_INPUT_1080_RESULT checks=", checks, " failures=", failures)
		app.queue_free()
		await settle()
		quit(1)
		return

	var restore := service.restore_defaults(&"common_ui_input_runner_setup")
	check(bool(restore.get("ok", false)), "runner starts from persisted CommonUI defaults")
	check(app.request_route("controls", false), "controls route is admitted through CommonUI")
	await settle()
	var controls := current_controls()
	check(app.current_route == "controls" and screen_root.menu_layer().get_depth() == 1,
		"controls is the active CommonUI menu screen")
	check(not app.state.has("utility_bindings"),
		"live controls does not hydrate the retained fixture binding table")
	var map_primary := controls_button("map", "primary")
	check(map_primary != null and map_primary.text == "M",
		"map row resolves its default primary binding from CommonUI")

	# Keyboard capture updates the logical action, persists it, and consumes the
	# candidate before the route action stage can see it.
	controls.call("_begin_capture", "map", "primary")
	await settle()
	check(current_controls().capture_action == "map", "keyboard capture owns one row")
	await key(KEY_Z)
	var map_binding := service.effective_binding(InputActions.UI_OPEN_MAP, CommonUIBinding.SLOT_PRIMARY)
	check(map_binding != null and map_binding.get_device_kind() == CommonUIBinding.DEVICE_KEYBOARD \
		and map_binding.get_code() == KEY_Z, "keyboard capture commits the CommonUI binding")
	check(current_controls().capture_action.is_empty() \
		and controls_button("map", "primary").text == "Z",
		"keyboard capture clears its pending state and refreshes the authored row")
	var bytes_after_keyboard := service.active_bindings_bytes()
	check(service.reload_overrides(), "keyboard rebind reloads through the fixed persistence seam")
	check(service.active_bindings_bytes() == bytes_after_keyboard \
		and service.effective_binding(InputActions.UI_OPEN_MAP, CommonUIBinding.SLOT_PRIMARY).get_code() == KEY_Z,
		"keyboard rebind survives a persistence reload")
	await key(KEY_Z)
	check(app.current_route == "maps", "the rebound CommonUI action routes from the active screen")
	check(app.request_route("controls", false), "controls returns through the typed route boundary")
	await settle()

	# Backspace is a real clear operation, and a controller candidate can then
	# occupy the released secondary slot without touching the primary binding.
	current_controls().call("_begin_capture", "map", "secondary")
	await key(KEY_BACKSPACE)
	check(service.effective_binding(InputActions.UI_OPEN_MAP, CommonUIBinding.SLOT_SECONDARY) == null,
		"Backspace clears an optional binding through the service")
	current_controls().call("_begin_capture", "map", "secondary")
	await joypad_button(JOY_BUTTON_A)
	var map_secondary := service.effective_binding(InputActions.UI_OPEN_MAP, CommonUIBinding.SLOT_SECONDARY)
	check(map_secondary != null and map_secondary.get_device_kind() == CommonUIBinding.DEVICE_GAMEPAD_BUTTON \
		and map_secondary.get_code() == JOY_BUTTON_A,
		"controller capture commits a CommonUI gamepad binding")
	check(app.current_route == "controls", "captured controller input cannot open another route")

	# The service rejects a same-context collision before writing it. The test
	# uses an uncommitted candidate so the screen remains on the same route.
	var collision := service.preview_conflicts(InputActions.UI_OPEN_MAP,
		CommonUIBinding.SLOT_PRIMARY, key_binding(KEY_I))
	var collision_seen := false
	for conflict_variant in collision:
		if str((conflict_variant as Dictionary).get("action", "")) == String(InputActions.UI_OPEN_INVENTORY):
			collision_seen = true
	check(collision_seen, "UI action context collision is visible before a rebind commit")
	var unchanged := service.active_bindings_bytes()
	current_controls().call("_begin_capture", "map", "primary")
	await key(KEY_I)
	check(service.active_bindings_bytes() == unchanged and app.current_route == "controls",
		"colliding keyboard input is rejected without changing route or persisted state")

	# Pointer, keyboard and controller modal ownership all suspend the controls
	# screen, keep focus in the modal layer, and restore the exact prior control.
	service.restore_defaults(&"common_ui_input_runner_modal_defaults")
	await settle()
	controls = current_controls()
	var focus_control := controls_button("map", "primary")
	focus_control.grab_focus()
	await settle()
	var prior_focus := root.gui_get_focus_owner()
	check(prior_focus == focus_control, "controls establishes the focus restoration target")
	var callback_count := {"value": 0}
	check(open_confirm(controls, callback_count), "keyboard modal request is admitted")
	await settle()
	var modal := app.modal as ZerkovDialog
	check(modal != null and screen_root.modal_layer().get_depth() == 1,
		"modal ownership is claimed synchronously by CommonUI")
	check(focus_is_inside(modal) and not controls.accepts_input(),
		"modal focus is contained and the covered screen cannot accept input")
	await key(KEY_ESCAPE)
	check(app.modal == null and screen_root.modal_layer().get_depth() == 0 \
		and callback_count.value == 0 and root.gui_get_focus_owner() == prior_focus,
		"keyboard Back dismisses the modal and restores the prior focus exactly")

	controls = current_controls()
	focus_control = controls_button("map", "primary")
	focus_control.grab_focus()
	await settle()
	check(open_confirm(controls, callback_count), "pointer modal request is admitted")
	await settle()
	modal = app.modal as ZerkovDialog
	var cancel_button := modal.get_node("DialogPanel/Margin/Content/Actions/CancelButton") as Control
	await click(cancel_button)
	check(app.modal == null and screen_root.modal_layer().get_depth() == 0 \
		and callback_count.value == 0 and root.gui_get_focus_owner() == focus_control,
		"pointer Cancel owns the modal click and restores controls focus")

	controls = current_controls()
	focus_control = controls_button("map", "primary")
	focus_control.grab_focus()
	await settle()
	check(open_confirm(controls, callback_count), "controller modal request is admitted")
	await settle()
	await joypad_button(JOY_BUTTON_B)
	check(app.modal == null and screen_root.modal_layer().get_depth() == 0 \
		and callback_count.value == 0 and root.gui_get_focus_owner() == focus_control \
		and app.current_route == "controls",
		"controller Back dismisses only the modal and restores the controls route")

	# Prompt focus is also owned by the modal and its callback cannot escape the
	# owner when the dialog is dismissed through a different device.
	controls = current_controls()
	focus_control = controls_button("map", "primary")
	focus_control.grab_focus()
	var prompt_value := {"value": ""}
	check(controls.app.prompt("RENAME", "Zerkov", func(value: String) -> void:
		prompt_value.value = value), "prompt request is admitted")
	await settle()
	modal = app.modal as ZerkovDialog
	check(focus_is_inside(modal) and root.gui_get_focus_owner() == modal.get_prompt_field(),
		"prompt modal focuses its editable field deterministically")
	await joypad_button(JOY_BUTTON_B)
	check(app.modal == null and prompt_value.value.is_empty() \
		and root.gui_get_focus_owner() == focus_control,
		"dismissed prompt cannot commit stale text and restores focus")

	# A retained controls capture is invalidated as its CommonUI screen leaves the
	# route. A deferred physical candidate must not mutate the next screen.
	controls = current_controls()
	controls.call("_begin_capture", "map", "primary")
	var bytes_before_stale := service.active_bindings_bytes()
	check(app.request_route("hud", false), "route transition is admitted during capture")
	await settle()
	push_key(KEY_K)
	await settle()
	check(app.current_route == "hud" and service.active_bindings_bytes() == bytes_before_stale,
		"stale deferred input cannot rebind a deactivated controls screen")

	# Context disconnect/rebind is exercised against the same service used by the
	# screen; teardown invalidates a still-held token and focus safely.
	var token := service.activate_modal(&"common_ui_input_runner")
	check(token != null and token.is_active(), "modal context lease activates")
	check(token != null and service.is_context_token_active(token),
		"active modal lease is visible in the service snapshot")
	check(token.release(), "modal context lease releases once")
	check(not token.is_active() and not service.is_context_token_active(token),
		"released modal lease cannot be reused")
	var teardown_token := service.activate_modal(&"common_ui_input_runner_teardown")
	check(teardown_token != null and teardown_token.is_active(),
		"a second modal lease remains held for teardown coverage")
	var app_ref: WeakRef = weakref(app)
	var controls_ref: WeakRef = weakref(controls)
	app.queue_free()
	await settle()
	check(app_ref.get_ref() == null and controls_ref.get_ref() == null,
		"CommonUI screen and host teardown release retained references")
	check(teardown_token != null and not teardown_token.is_active(),
		"teardown invalidates a still-held input capability")

	print("COMMON_UI_INPUT_1080_RESULT checks=", checks, " failures=", failures,
		" viewport=", FIRST_PLAYABLE_SIZE)
	quit(0 if failures == 0 else 1)
