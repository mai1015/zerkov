@tool
class_name ZerkovDialog
extends CommonAnimatedScreen

## Project-owned modal dialog used by Zerkov's confirmation and prompt flows.
##
## The hierarchy is authored in zerkov_dialog.tscn so the component can be
## opened and maintained in the Godot editor. Runtime behaviour stays here:
## CommonUI context suspension, default confirm/back routing, configuration,
## and the small amount of responsive layout needed by the overlay.

const U := preload("res://ui/theme/tokens.gd")

const DEFAULT_DIALOG_SIZE := Vector2(660.0, 280.0)
const PROMPT_DIALOG_SIZE := Vector2(660.0, 340.0)

## Emitted when the confirm action or ConfirmButton is activated.
signal confirmed
## Emitted when the back action or CancelButton is activated.
signal dismissed

@export var title_text: String = "":
	set(value):
		title_text = value
		if is_instance_valid(_title_label):
			_title_label.text = value
			_title_label.visible = not value.is_empty()

@export_multiline var message_text: String = "":
	set(value):
		message_text = value
		if is_instance_valid(_message_label):
			_message_label.text = value

@export var confirm_text: String = "CONFIRM":
	set(value):
		confirm_text = value
		if is_instance_valid(_confirm_button):
			_confirm_button.text = value

@export var cancel_text: String = "CANCEL":
	set(value):
		cancel_text = value
		if is_instance_valid(_cancel_button):
			_cancel_button.text = value

## Hides CancelButton for a one-button alert. Back still dismisses the dialog.
@export var show_cancel: bool = true:
	set(value):
		show_cancel = value
		if is_instance_valid(_cancel_button):
			_cancel_button.visible = value
		_build_focus_graph()

## Shows the authored Prompt LineEdit and grows the panel to fit it.
@export var prompt_enabled: bool = false:
	set(value):
		prompt_enabled = value
		if is_instance_valid(prompt):
			prompt.visible = value
			_update_dialog_layout()
			_build_focus_graph()

## Initial/current value of the optional prompt field.
@export var prompt_text: String = "":
	set(value):
		prompt_text = value
		if is_instance_valid(prompt) and prompt.text != value:
			prompt.text = value

@export var prompt_placeholder: String = "":
	set(value):
		prompt_placeholder = value
		if is_instance_valid(prompt):
			prompt.placeholder_text = value

@export_range(1, 1024, 1) var prompt_max_length: int = 24:
	set(value):
		prompt_max_length = maxi(value, 1)
		if is_instance_valid(prompt):
			prompt.max_length = prompt_max_length

## Compatibility alias for callers that describe the field as a visible prompt.
var show_prompt: bool:
	get:
		return prompt_enabled
	set(value):
		prompt_enabled = value

@onready var _veil: ColorRect = $Veil
@onready var _dialog_panel: Panel = $DialogPanel
@onready var _title_label: Label = $DialogPanel/Margin/Content/Title
@onready var _message_label: Label = $DialogPanel/Margin/Content/Message
@onready var prompt: LineEdit = $DialogPanel/Margin/Content/Prompt
@onready var _cancel_button: CommonButton = $DialogPanel/Margin/Content/Actions/CancelButton
@onready var _confirm_button: CommonButton = $DialogPanel/Margin/Content/Actions/ConfirmButton

var _lower_contexts: Array[CommonUIContextHandle] = []
var _requested_view_size := Vector2(-1.0, -1.0)
var _resolved := false


func _init() -> void:
	if name.is_empty():
		name = "ZerkovDialog"
	# A modal owns a higher-priority context and suspends the screens beneath it.
	screen_context = &"dialog"
	context_priority = CommonUIDefaults.PRIORITY_MODAL
	suspends_lower_contexts = true
	handles_back = false
	# Existing smoke tests exercise dialogs frame-by-frame. Keep this component
	# deterministic; consumers can opt into animation on a derived dialog.
	enter_transition = Transition.NONE
	exit_transition = Transition.NONE
	duration = 0.0
	animations_enabled = false
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP


func _ready() -> void:
	_apply_zerkov_theme()
	_sync_configuration()
	_build_focus_graph()
	_update_dialog_layout()

	if Engine.is_editor_hint():
		return
	if not _confirm_button.triggered.is_connected(_on_confirm_button_triggered):
		_confirm_button.triggered.connect(_on_confirm_button_triggered)
	if not _cancel_button.triggered.is_connected(_on_cancel_button_triggered):
		_cancel_button.triggered.connect(_on_cancel_button_triggered)
	if not prompt.text_submitted.is_connected(_on_prompt_text_submitted):
		prompt.text_submitted.connect(_on_prompt_text_submitted)

	var view_size := _requested_view_size
	if view_size.x < 0.0 or view_size.y < 0.0:
		view_size = size
	if view_size.x <= 0.0 or view_size.y <= 0.0:
		view_size = get_viewport_rect().size
	resize_to_view(view_size)


func _apply_zerkov_theme() -> void:
	theme = ZThemeAdapter.adapt_theme(theme)
	ZThemeAdapter.apply_controls(self)

func _sync_configuration() -> void:
	_title_label.text = title_text
	_title_label.visible = not title_text.is_empty()
	_message_label.text = message_text
	_confirm_button.text = confirm_text
	_cancel_button.text = cancel_text
	_cancel_button.visible = show_cancel
	prompt.visible = prompt_enabled
	prompt.text = prompt_text
	prompt.placeholder_text = prompt_placeholder
	prompt.max_length = prompt_max_length
	_update_default_focus()


func _update_default_focus() -> void:
	if prompt_enabled:
		default_focus = get_path_to(prompt)
	elif show_cancel:
		default_focus = get_path_to(_cancel_button)
	else:
		default_focus = get_path_to(_confirm_button)


func _build_focus_graph() -> void:
	if not is_instance_valid(_confirm_button) or not is_instance_valid(_cancel_button) \
			or not is_instance_valid(prompt):
		return
	var focusables: Array[Control] = []
	if prompt_enabled:
		focusables.append(prompt)
	if show_cancel:
		focusables.append(_cancel_button)
	focusables.append(_confirm_button)
	if focusables.is_empty():
		return
	for index in range(focusables.size()):
		var current := focusables[index]
		var previous := focusables[posmod(index - 1, focusables.size())]
		var next := focusables[(index + 1) % focusables.size()]
		current.focus_neighbor_left = current.get_path_to(previous)
		current.focus_neighbor_right = current.get_path_to(next)
		current.focus_neighbor_top = current.get_path_to(previous)
		current.focus_neighbor_bottom = current.get_path_to(next)
		current.focus_previous = current.get_path_to(previous)
		current.focus_next = current.get_path_to(next)
	_update_default_focus()


func _update_dialog_layout() -> void:
	if not is_instance_valid(_dialog_panel):
		return
	_dialog_panel.size = PROMPT_DIALOG_SIZE if prompt_enabled else DEFAULT_DIALOG_SIZE
	var view_size := _requested_view_size
	if view_size.x < 0.0 or view_size.y < 0.0:
		view_size = size
	if view_size.x > 0.0 and view_size.y > 0.0:
		_dialog_panel.position = (view_size - _dialog_panel.size) * 0.5


## Resizes the full-screen veil and centers DialogPanel inside the supplied view.
##
## The requested size is retained so callers can safely invoke this before the
## instance enters the tree; _ready applies it again after authored layout data
## has been loaded.
func resize_to_view(view: Vector2) -> void:
	_requested_view_size = Vector2(maxf(view.x, 0.0), maxf(view.y, 0.0))
	if is_instance_valid(_dialog_panel):
		_dialog_panel.size = PROMPT_DIALOG_SIZE if prompt_enabled else DEFAULT_DIALOG_SIZE
		_dialog_panel.position = (_requested_view_size - _dialog_panel.size) * 0.5


## Applies the dialog copy in one call and returns this instance for chaining.
func configure(p_title: String, p_message: String, p_confirm := "CONFIRM",
		p_cancel := "CANCEL", p_show_cancel := true) -> ZerkovDialog:
	title_text = p_title
	message_text = p_message
	confirm_text = p_confirm
	cancel_text = p_cancel
	show_cancel = p_show_cancel
	return self


## Enables and initializes the authored LineEdit prompt in one call.
func configure_prompt(initial_value: String, max_length: int = 24,
		placeholder := "") -> ZerkovDialog:
	prompt_enabled = true
	prompt_text = initial_value
	prompt_max_length = max_length
	prompt_placeholder = placeholder
	return self


## Returns the current prompt value, or an empty string when the prompt is off.
func get_prompt_text(trim_edges := false) -> String:
	if not is_instance_valid(prompt) or not prompt_enabled:
		return ""
	var value := prompt.text
	return value.strip_edges() if trim_edges else value


func get_prompt_field() -> LineEdit:
	return prompt


## Context handles opened by screens below this dialog. CommonUI suspends them
## while this modal is active and restores them when it is dismissed.
func set_lower_contexts(handles: Array[CommonUIContextHandle]) -> void:
	_lower_contexts = handles


func _collect_lower_contexts() -> Array[CommonUIContextHandle]:
	return _lower_contexts.duplicate()


func _on_activated() -> void:
	if Engine.is_editor_hint():
		return
	register_action(CommonUIDefaults.CONFIRM, _on_confirm_action)
	register_action(CommonUIDefaults.BACK, _on_back_action)


func _on_confirm_action(event: Dictionary) -> int:
	if event.get("phase", -1) != CommonUIRuntime.PHASE_PRESSED:
		return CommonUIRuntime.ROUTE_UNHANDLED
	# Enter is also ui_accept. When a button owns focus, Godot's GUI stage will
	# trigger that button; leave this route unhandled to avoid a double emit.
	var focused := get_viewport().gui_get_focus_owner()
	if focused is BaseButton and is_ancestor_of(focused):
		return CommonUIRuntime.ROUTE_UNHANDLED
	_emit_confirmed()
	return CommonUIRuntime.ROUTE_HANDLED


func _on_back_action(event: Dictionary) -> int:
	if event.get("phase", -1) != CommonUIRuntime.PHASE_PRESSED:
		return CommonUIRuntime.ROUTE_UNHANDLED
	_emit_dismissed()
	return CommonUIRuntime.ROUTE_HANDLED


func _on_confirm_button_triggered() -> void:
	_emit_confirmed()


func _on_cancel_button_triggered() -> void:
	_emit_dismissed()


func _on_prompt_text_submitted(_value: String) -> void:
	if prompt_enabled:
		_emit_confirmed()


func _emit_confirmed() -> void:
	if _resolved:
		return
	_resolved = true
	confirmed.emit()


func _emit_dismissed() -> void:
	if _resolved:
		return
	_resolved = true
	dismissed.emit()
