@tool
class_name BindingEntry
extends HBoxContainer

## One rebindable row in a settings screen.
##
## The row captures a candidate binding, hands it to
## [CommonInputBindingRegistry] as a single transaction, and reports the result.
## It never writes InputMap or the override file itself, so a rejected or failed
## rebind leaves the previously active binding untouched.

## Emitted when a rebind transaction resolves. `result` is the registry's result
## dictionary: ok, error, needs_confirmation, conflicts.
signal rebind_finished(result: Dictionary)
## Emitted when a candidate conflicts and the policy is reject, so a game can
## show its own confirmation UI and retry with a replace policy.
signal conflict_detected(conflicts: Array)

@export var action: StringName = &"":
	set(value):
		action = value
		_refresh()

@export_range(0, 1) var slot: int = 0:
	set(value):
		slot = value
		_refresh()

@export var glyph_set: Dictionary = {}

@export var listening_text: String = "Press any input…"

var _label: Label
var _button: Button
var _glyph: InputGlyph
var _listening := false


func _ready() -> void:
	_build()
	if Engine.is_editor_hint():
		return
	var runtime := _get_runtime()
	if runtime != null:
		var registry := runtime.get_binding_registry()
		if registry != null:
			registry.bindings_changed.connect(_refresh)
	set_process_input(false)
	_refresh()


func _get_runtime() -> CommonUIRuntime:
	# An absolute path is only resolvable while inside the tree; nodes that are
	# tearing down must not try to reach the autoload.
	if Engine.is_editor_hint() or not is_inside_tree():
		return null
	return get_node_or_null(^"/root/CommonUI") as CommonUIRuntime


func _get_registry() -> CommonInputBindingRegistry:
	var runtime := _get_runtime()
	return runtime.get_binding_registry() if runtime != null else null


func _build() -> void:
	if _label != null:
		return
	_label = Label.new()
	add_child(_label)

	_glyph = InputGlyph.new()
	_glyph.glyph_set = glyph_set
	add_child(_glyph)

	_button = Button.new()
	_button.text = "Change"
	_button.pressed.connect(start_listening)
	add_child(_button)


## Begins capturing the next input event as a candidate binding.
func start_listening() -> void:
	if _listening:
		return
	_listening = true
	_button.text = listening_text
	set_process_input(true)


func cancel_listening() -> void:
	_listening = false
	_button.text = "Change"
	set_process_input(false)


## Capture ahead of GUI dispatch. A focused Change button sees keyboard/gamepad
## activation on the GUI path; waiting until `_unhandled_input` lets its release
## activate the button again after a successful capture and re-arm the row.
func _input(event: InputEvent) -> void:
	if not _listening:
		return
	var candidate := _candidate_from(event)
	if candidate == null:
		return
	get_viewport().set_input_as_handled()
	cancel_listening()
	_apply(candidate, CommonInputBindingRegistry.CONFLICT_REJECT, false)


## Retries the last candidate with an explicit replace policy, which is what a
## game calls after the player confirms a conflict dialog.
func apply_with_replace(candidate: CommonUIBinding, confirmed: bool = true) -> void:
	_apply(candidate, CommonInputBindingRegistry.CONFLICT_REPLACE, confirmed)


func _apply(candidate: CommonUIBinding, policy: int, confirmed: bool) -> void:
	var registry := _get_registry()
	if registry == null:
		return
	var result: Dictionary = registry.rebind(action, slot, candidate, policy, confirmed)
	if not result["ok"] and not (result["conflicts"] as Array).is_empty():
		conflict_detected.emit(result["conflicts"])
	rebind_finished.emit(result)
	_refresh()


## Translates a raw InputEvent into a CommonUIBinding. Returns null for events
## that cannot form a binding, such as mouse motion or an echo.
func _candidate_from(event: InputEvent) -> CommonUIBinding:
	var binding := CommonUIBinding.new()
	binding.set_slot(slot as CommonUIBinding.Slot)

	if event is InputEventKey:
		var key := event as InputEventKey
		if not key.pressed or key.echo:
			return null
		binding.set_device_kind(CommonUIBinding.DEVICE_KEYBOARD)
		binding.set_code(key.physical_keycode)
		binding.set_shift_pressed(key.shift_pressed)
		binding.set_ctrl_pressed(key.ctrl_pressed)
		binding.set_alt_pressed(key.alt_pressed)
		binding.set_meta_pressed(key.meta_pressed)
		return binding

	if event is InputEventMouseButton:
		var mouse := event as InputEventMouseButton
		if not mouse.pressed:
			return null
		binding.set_device_kind(CommonUIBinding.DEVICE_MOUSE)
		binding.set_code(mouse.button_index)
		binding.set_shift_pressed(mouse.shift_pressed)
		binding.set_ctrl_pressed(mouse.ctrl_pressed)
		binding.set_alt_pressed(mouse.alt_pressed)
		binding.set_meta_pressed(mouse.meta_pressed)
		return binding

	if event is InputEventJoypadButton:
		var pad := event as InputEventJoypadButton
		if not pad.pressed:
			return null
		binding.set_device_kind(CommonUIBinding.DEVICE_GAMEPAD_BUTTON)
		binding.set_code(pad.button_index)
		return binding

	if event is InputEventJoypadMotion:
		var motion := event as InputEventJoypadMotion
		# Ignore drift so a resting stick cannot capture a binding.
		if absf(motion.axis_value) < 0.5:
			return null
		binding.set_device_kind(CommonUIBinding.DEVICE_GAMEPAD_AXIS)
		binding.set_code(motion.axis)
		binding.set_axis_direction(
			CommonUIBinding.AXIS_DIRECTION_NEGATIVE if motion.axis_value < 0.0
			else CommonUIBinding.AXIS_DIRECTION_POSITIVE)
		return binding

	return null


func _refresh() -> void:
	if _label == null:
		return
	_label.text = String(action).get_file().capitalize()
	_glyph.action = action
	_glyph.slot = slot
	if not _listening:
		_button.text = "Change"
