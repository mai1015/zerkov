class_name ZUIFeedback
extends Control

const DialogScene = preload("res://ui/components/feedback/zerkov_dialog.tscn")
const CatalogScene = preload("res://ui/dev/screen_catalog.tscn")
var host: Control
var common_ui_root: CommonUIScreenRoot
@onready var toast_label: Label = $Toast
@onready var toast_timer: Timer = $ToastTimer
var picker: CommonActivatableScreen
var modal: ZerkovDialog

func configure(owner_host: Control, screen_root: CommonUIScreenRoot) -> void:
	host = owner_host
	common_ui_root = screen_root

func _ready() -> void:
	ZThemeAdapter.apply_controls(toast_label)
	toast_timer.timeout.connect(toast_label.hide)

func resize_to_view(view: Vector2) -> void:
	if is_instance_valid(modal): modal.resize_to_view(view)
	if is_instance_valid(picker): picker.resize_to_view(view)
	if is_instance_valid(toast_label):
		toast_label.size.x = minf(880, view.x - 48)
		toast_label.position = Vector2((view.x - toast_label.size.x) / 2, view.y - 136)

func toast(message: String) -> void:
	toast_label.text = message
	resize_to_view(get_viewport_rect().size)
	toast_label.show()
	toast_timer.start(3.5)

func confirm(title_text: String, message: String, callback: Callable) -> void:
	var dialog := _new_dialog(title_text, message)
	dialog.confirmed.connect(func() -> void:
		_close_overlay(dialog)
		callback.call(), CONNECT_ONE_SHOT)
	dialog.dismissed.connect(func() -> void: _close_overlay(dialog), CONNECT_ONE_SHOT)
	_push_dialog(dialog)

func prompt(title_text: String, initial_value: String, callback: Callable, max_length: int = 24) -> void:
	var dialog := _new_dialog(title_text, "")
	dialog.configure_prompt(initial_value, max_length)
	dialog.screen_context = &"modal/prompt"
	dialog.confirmed.connect(func() -> void:
		var value := dialog.get_prompt_text(true)
		_close_overlay(dialog)
		callback.call(value), CONNECT_ONE_SHOT)
	dialog.dismissed.connect(func() -> void: _close_overlay(dialog), CONNECT_ONE_SHOT)
	_push_dialog(dialog)

func _new_dialog(title_text: String, message: String) -> ZerkovDialog:
	var dialog := DialogScene.instantiate() as ZerkovDialog
	dialog.configure(title_text.to_upper(), message, "CONFIRM", "CANCEL", true)
	dialog.screen_context = &"modal/confirm"
	dialog.resize_to_view(get_viewport_rect().size)
	dialog.set_lower_contexts(ZUINavigator.active_contexts([
		common_ui_root.hud_layer(), common_ui_root.menu_layer(), common_ui_root.popup_layer()]))
	return dialog

func _push_dialog(dialog: ZerkovDialog) -> void:
	var modal_layer := common_ui_root.modal_layer()
	modal = dialog
	if modal_layer.get_depth() > 0:
		modal_layer.request_replace(dialog)
	else:
		modal_layer.request_push(dialog)

func toggle_picker() -> void:
	if is_instance_valid(picker):
		_close_overlay(picker)
		return
	picker = CatalogScene.instantiate()
	picker.current_route = host.current_route
	picker.lower_contexts = ZUINavigator.active_contexts([
		common_ui_root.hud_layer(), common_ui_root.menu_layer(), common_ui_root.modal_layer()])
	picker.selected.connect(_on_catalog_selected)
	picker.dismissed.connect(func(): _close_overlay(picker))
	common_ui_root.popup_layer().request_push(picker)


func _on_catalog_selected(route: String) -> void:
	# The popup is the sole compatibility entrance for developer study routes.
	# Admission happens before dismissal, so an unknown catalog value leaves the
	# current CommonUI composition and focus trap intact.
	if host.open_developer_route(route):
		_close_overlay(picker)

func _close_overlay(control: Control) -> void:
	if not is_instance_valid(control): return
	var layer: CommonUILayer
	if control == modal:
		modal = null
		layer = common_ui_root.modal_layer()
	elif control == picker:
		picker = null
		layer = common_ui_root.popup_layer()
	else:
		return
	var request := layer.request_pop()
	request.finished.connect(func(_result: Dictionary):
		if host._resize_pending: host._finish_window_resize.call_deferred(), CONNECT_ONE_SHOT)

func dismiss_all() -> void:
	if is_instance_valid(picker): _close_overlay(picker)
	if is_instance_valid(modal): _close_overlay(modal)
