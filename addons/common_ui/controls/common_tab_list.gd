@tool
class_name CommonTabList
extends HBoxContainer

## A themed tab strip driven by next/previous CommonUI actions.
##
## The list owns no routing state. It registers two actions through the screen
## that contains it and reports selection changes; what a tab shows is entirely
## up to the game.

signal tab_selected(index: int, id: StringName)

## Identifiers, one per tab, in display order.
@export var tab_ids: Array[StringName] = []:
	set(value):
		tab_ids = value
		_rebuild()

@export var tab_labels: Array[String] = []:
	set(value):
		tab_labels = value
		_rebuild()

@export var next_action: StringName = &"common_ui/tab_next"
@export var previous_action: StringName = &"common_ui/tab_previous"
@export var wrap_around: bool = true
@export var button_theme_type: StringName = &""

var _selected := 0
var _buttons: Array[Button] = []
var _handles: Array[CommonUIActionHandle] = []
var _ready_done := false


func _ready() -> void:
	_rebuild()
	if Engine.is_editor_hint():
		return
	_ready_done = true
	_bind_to_screen_lifecycle()
	_register()


## Re-registers when this control re-enters the tree without a full [method _ready]
## running again, e.g. a pooled screen that is removed and re-added rather than
## freed. Mirrors [method CommonButton._enter_tree]; see its comment for why the
## guard is needed (this fires before the very first [method _ready] too).
func _enter_tree() -> void:
	if Engine.is_editor_hint() or not _ready_done:
		return
	_bind_to_screen_lifecycle()
	_register()


func _get_screen() -> CommonActivatableScreen:
	var node: Node = get_parent()
	while node != null:
		if node is CommonActivatableScreen:
			return node
		node = node.get_parent()
	return null


func get_selected_index() -> int:
	return _selected


func get_selected_id() -> StringName:
	return tab_ids[_selected] if _selected >= 0 and _selected < tab_ids.size() else &""


func select(index: int) -> void:
	if tab_ids.is_empty():
		return
	var count := tab_ids.size()
	if wrap_around:
		index = ((index % count) + count) % count
	else:
		index = clampi(index, 0, count - 1)
	if index == _selected:
		return
	_selected = index
	_update_pressed_state()
	tab_selected.emit(_selected, get_selected_id())


func _rebuild() -> void:
	for button in _buttons:
		if is_instance_valid(button):
			button.queue_free()
	_buttons.clear()

	for i in tab_ids.size():
		var button := Button.new()
		button.toggle_mode = true
		button.text = tab_labels[i] if i < tab_labels.size() else String(tab_ids[i]).capitalize()
		if not String(button_theme_type).is_empty():
			button.theme_type_variation = button_theme_type
		button.pressed.connect(func() -> void: select(i))
		add_child(button)
		_buttons.append(button)
	_update_pressed_state()


func _update_pressed_state() -> void:
	for i in _buttons.size():
		if is_instance_valid(_buttons[i]):
			_buttons[i].button_pressed = i == _selected


## Deactivating a screen releases every action registered through it, so the
## tab actions have to be re-registered when the screen becomes active again.
func _bind_to_screen_lifecycle() -> void:
	var screen := _get_screen()
	if screen == null:
		return
	if not screen.activated.is_connected(_register):
		screen.activated.connect(_register)
	if not screen.deactivated.is_connected(_drop_registrations):
		screen.deactivated.connect(_drop_registrations)


## Releases every handle this control currently holds, then forgets them.
## release() is idempotent, so this is safe to call even when the owning
## screen's own deactivation already released the same handles -- which is
## exactly why it doubles as both the screen's `deactivated` handler and
## _register()'s own pre-registration clear. The latter matters on its own:
## _register() can run twice with no deactivation in between (the initial
## _ready()/_enter_tree() registration, immediately followed by the screen's
## `activated` signal once it finishes activating), and without releasing here
## too, that first generation of handles would be silently orphaned -- forgotten
## by this control, but still live in the runtime.
func _drop_registrations() -> void:
	for handle in _handles:
		if handle != null:
			handle.release()
	_handles.clear()


func _register() -> void:
	var screen := _get_screen()
	if screen == null:
		return
	_drop_registrations()
	_handles.append(screen.register_action(next_action,
		func(event: Dictionary) -> int: return _step(event, 1)))
	_handles.append(screen.register_action(previous_action,
		func(event: Dictionary) -> int: return _step(event, -1)))


func _step(event: Dictionary, delta: int) -> int:
	# Repeats let a held shoulder button walk through the tabs.
	if event["phase"] != CommonUIRuntime.PHASE_PRESSED and \
			event["phase"] != CommonUIRuntime.PHASE_HOLD_REPEAT:
		return CommonUIRuntime.ROUTE_UNHANDLED
	if tab_ids.is_empty() or not is_visible_in_tree():
		return CommonUIRuntime.ROUTE_UNHANDLED
	select(_selected + delta)
	return CommonUIRuntime.ROUTE_HANDLED


func _exit_tree() -> void:
	for handle in _handles:
		if handle != null:
			handle.release()
	_handles.clear()
