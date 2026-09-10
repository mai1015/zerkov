@tool
class_name CommonButton
extends Button

## A themed button that can also be driven by a CommonUI action.
##
## Games may inherit, compose, or replace this scene. Any button that follows
## the same contract -- register the action while visible, release it when
## hidden, and emit [signal triggered] -- participates in action registration,
## focus, and glyph updates without native code changes.

signal triggered

## Action that activates this button in addition to a click. Empty means the
## button is click and focus driven only.
@export var action: StringName = &"":
	set(value):
		action = value
		_watch_disabled = not String(action).is_empty()
		if is_inside_tree():
			set_process(_watch_disabled and not Engine.is_editor_hint())
			_refresh_registration()
			_update_glyph()

@export var action_priority: int = 0
## Shows the action's glyph beside the label.
@export var show_glyph: bool = true:
	set(value):
		show_glyph = value
		_update_glyph()

@export var glyph_set: Dictionary = {}:
	set(value):
		glyph_set = value
		_update_glyph()

var _handle: CommonUIActionHandle = null
var _glyph: InputGlyph = null
## Whether [method _process] should poll [member BaseButton.disabled] for
## changes. Only worth the per-frame check while an action is actually
## registered; see [method _process].
var _watch_disabled := false
var _last_disabled := false
var _ready_done := false


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	_ready_done = true
	pressed.connect(_on_pressed)
	visibility_changed.connect(_refresh_registration)
	_bind_to_screen_lifecycle()
	_last_disabled = disabled
	_watch_disabled = not String(action).is_empty()
	set_process(_watch_disabled)
	_update_glyph()
	_refresh_registration()


## Re-registers when this control re-enters the tree without a full [method _ready]
## running again, e.g. a pooled screen that is removed and re-added rather than
## freed (see [method Node._enter_tree], which fires on every entry, including
## the very first one -- before [method _ready] -- hence the guard). Registration
## and the screen-lifecycle connections are the only per-add state; the glyph
## child and its own signal connections are ordinary children that travel with
## this button across a reparent and need no rebuilding.
func _enter_tree() -> void:
	if Engine.is_editor_hint() or not _ready_done:
		return
	_bind_to_screen_lifecycle()
	set_process(_watch_disabled)
	_refresh_registration()


## [member BaseButton.disabled] has no signal or notification to observe (Godot
## 4.7's BaseButton exposes no NOTIFICATION_DISABLED, and a native property
## cannot be redeclared with a scripted setter -- both were tried), so a flipped
## `disabled` is instead detected by comparing it once a frame, and only while an
## action is actually registered: otherwise a stale action-bar/registration
## advertises a control that would refuse the press.
func _process(_delta: float) -> void:
	if disabled == _last_disabled:
		return
	_last_disabled = disabled
	_refresh_registration()


func _get_screen() -> CommonActivatableScreen:
	var node: Node = get_parent()
	while node != null:
		if node is CommonActivatableScreen:
			return node
		node = node.get_parent()
	return null


func _get_runtime() -> CommonUIRuntime:
	# An absolute path is only resolvable while inside the tree; nodes that are
	# tearing down must not try to reach the autoload.
	if Engine.is_editor_hint() or not is_inside_tree():
		return null
	return get_node_or_null(^"/root/CommonUI") as CommonUIRuntime


func _refresh_registration() -> void:
	if Engine.is_editor_hint():
		return
	if _handle != null:
		_handle.release()
		_handle = null
	if String(action).is_empty() or not is_visible_in_tree() or disabled:
		return

	# Registering through the owning screen scopes the action to that screen's
	# layer and context, so it only routes while the screen is on top.
	var screen := _get_screen()
	if screen != null:
		_handle = screen.register_action(action, _on_action, {"priority": action_priority})
		return
	var runtime := _get_runtime()
	if runtime != null:
		_handle = runtime.register_action(action, _on_action,
			{"owner": self, "priority": action_priority})


## Keeps this control's action registration in step with its screen.
##
## Deactivating a screen releases every action registered through it, so a
## control that only registered once would silently lose its action when a
## screen above it on the same layer is popped.
func _bind_to_screen_lifecycle() -> void:
	var screen := _get_screen()
	if screen == null:
		return
	if not screen.activated.is_connected(_refresh_registration):
		screen.activated.connect(_refresh_registration)
	if not screen.deactivated.is_connected(_drop_registration):
		screen.deactivated.connect(_drop_registration)


## Forgets the handle a screen deactivation already released.
func _drop_registration() -> void:
	_handle = null


func _on_action(event: Dictionary) -> int:
	if event["phase"] != CommonUIRuntime.PHASE_PRESSED:
		return CommonUIRuntime.ROUTE_UNHANDLED
	if disabled or not is_visible_in_tree():
		return CommonUIRuntime.ROUTE_UNHANDLED
	_emit_triggered()
	return CommonUIRuntime.ROUTE_HANDLED


func _on_pressed() -> void:
	_emit_triggered()


func _emit_triggered() -> void:
	triggered.emit()


func _update_glyph() -> void:
	if Engine.is_editor_hint():
		return
	if not show_glyph or String(action).is_empty():
		if _glyph != null:
			_glyph.queue_free()
			_glyph = null
		return
	if _glyph == null:
		_glyph = InputGlyph.new()
		add_child(_glyph)
	_glyph.action = action
	_glyph.glyph_set = glyph_set


func _exit_tree() -> void:
	if _handle != null:
		_handle.release()
		_handle = null
