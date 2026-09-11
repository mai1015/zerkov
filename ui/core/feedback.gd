class_name ZUIFeedback
extends Control

const DialogScene = preload("res://ui/components/feedback/zerkov_dialog.tscn")
const CatalogScene = preload("res://ui/dev/screen_catalog.tscn")
const CLOSING_META := &"_zui_overlay_closing"
const CALLBACK_CONTEXT_META := &"_zui_callback_context"
const CALLBACK_CAPABILITY_META := &"_zui_callback_capability"
var host: Control
var common_ui_root: CommonUIScreenRoot
@onready var toast_label: Label = $Toast
@onready var toast_timer: Timer = $ToastTimer
var picker: CommonActivatableScreen
var modal: ZerkovDialog
var _developer_authorization: RefCounted

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

func confirm(
	requester: ZUIContext,
	capability: RefCounted,
	title_text: String,
	message: String,
	callback: Callable
) -> bool:
	if not _accept_requester(requester, capability) or not _can_open_overlay():
		return false
	var dialog := _new_dialog(requester, capability, title_text, message)
	dialog.confirmed.connect(_confirm_dialog.bind(dialog, callback), CONNECT_ONE_SHOT)
	dialog.dismissed.connect(_dismiss_dialog.bind(dialog), CONNECT_ONE_SHOT)
	return _push_dialog(dialog)

func prompt(
	requester: ZUIContext,
	capability: RefCounted,
	title_text: String,
	initial_value: String,
	callback: Callable,
	max_length: int = 24
) -> bool:
	if not _accept_requester(requester, capability) or not _can_open_overlay():
		return false
	var dialog := _new_dialog(requester, capability, title_text, "")
	dialog.configure_prompt(initial_value, max_length)
	dialog.screen_context = &"modal/prompt"
	dialog.confirmed.connect(_confirm_prompt.bind(dialog, callback), CONNECT_ONE_SHOT)
	dialog.dismissed.connect(_dismiss_dialog.bind(dialog), CONNECT_ONE_SHOT)
	return _push_dialog(dialog)

func _new_dialog(
	requester: ZUIContext,
	capability: RefCounted,
	title_text: String,
	message: String
) -> ZerkovDialog:
	var dialog := DialogScene.instantiate() as ZerkovDialog
	dialog.configure(title_text.to_upper(), message, "CONFIRM", "CANCEL", true)
	dialog.screen_context = &"modal/confirm"
	dialog.set_meta(CALLBACK_CONTEXT_META, requester)
	dialog.set_meta(CALLBACK_CAPABILITY_META, capability)
	dialog.resize_to_view(get_viewport_rect().size)
	dialog.set_lower_contexts(ZUINavigator.active_contexts([
		common_ui_root.hud_layer(), common_ui_root.menu_layer(), common_ui_root.popup_layer()]))
	return dialog

func _push_dialog(dialog: ZerkovDialog) -> bool:
	# The reference is claimed before CommonUI's deferred drain, making two
	# same-frame confirm calls idempotent instead of creating depth two.
	if is_instance_valid(modal) or common_ui_root.modal_layer().get_depth() > 0:
		dialog.free()
		return false
	modal = dialog
	var request := common_ui_root.modal_layer().request_push(dialog)
	request.finished.connect(_overlay_push_finished.bind(dialog), CONNECT_ONE_SHOT)
	return true

func toggle_picker() -> bool:
	if is_instance_valid(picker):
		if bool(picker.get_meta(CLOSING_META, false)):
			return false
		_close_overlay(picker)
		return true
	if not _can_open_overlay():
		return false
	picker = CatalogScene.instantiate()
	_developer_authorization = RefCounted.new()
	picker.current_route = host.current_route
	picker.lower_contexts = ZUINavigator.active_contexts([
		common_ui_root.hud_layer(), common_ui_root.menu_layer(), common_ui_root.modal_layer()])
	picker.selected.connect(_on_catalog_selected.bind(picker, _developer_authorization))
	picker.dismissed.connect(_dismiss_picker.bind(picker), CONNECT_ONE_SHOT)
	var request := common_ui_root.popup_layer().request_push(picker)
	request.finished.connect(_overlay_push_finished.bind(picker), CONNECT_ONE_SHOT)
	return true


func _on_catalog_selected(
	route: String,
	catalog: CommonActivatableScreen,
	authorization: RefCounted
) -> void:
	# The navigator validates this opaque capability, then closes this exact
	# popup and waits for focus/context restoration before committing the route.
	if catalog == picker and is_live_developer_authorization(authorization):
		host.open_developer_route(route, authorization)


func _confirm_dialog(dialog: ZerkovDialog, callback: Callable) -> void:
	var requester := dialog.get_meta(CALLBACK_CONTEXT_META, null) as ZUIContext
	var capability := dialog.get_meta(CALLBACK_CAPABILITY_META, null) as RefCounted
	var result: Dictionary = await _close_overlay(dialog)
	if int(result.get("status", -1)) == CommonUIStackRequest.Status.SUCCESS:
		_call_if_current(requester, capability, callback)


func _confirm_prompt(dialog: ZerkovDialog, callback: Callable) -> void:
	var value := dialog.get_prompt_text(true)
	var requester := dialog.get_meta(CALLBACK_CONTEXT_META, null) as ZUIContext
	var capability := dialog.get_meta(CALLBACK_CAPABILITY_META, null) as RefCounted
	var result: Dictionary = await _close_overlay(dialog)
	if int(result.get("status", -1)) == CommonUIStackRequest.Status.SUCCESS:
		_call_if_current(requester, capability, callback, [value])


func _dismiss_dialog(dialog: ZerkovDialog) -> void:
	await _close_overlay(dialog)


func _dismiss_picker(catalog: CommonActivatableScreen) -> void:
	await _close_overlay(catalog)


func _call_if_current(
	requester: ZUIContext,
	capability: RefCounted,
	callback: Callable,
	arguments: Array = []
) -> void:
	if not _requester_reason(requester, capability).is_empty() or not callback.is_valid():
		toast("Dialog action expired because its owning screen is no longer active.")
		return
	callback.callv(arguments)


func _overlay_push_finished(result: Dictionary, control: CommonActivatableScreen) -> void:
	if int(result.get("status", -1)) == CommonUIStackRequest.Status.SUCCESS:
		return
	_clear_overlay_reference(control)
	if is_instance_valid(control) and control.get_parent() == null:
		control.queue_free()


func _can_open_overlay() -> bool:
	return not has_blocking_overlay() \
			and (host.navigator == null or not host.navigator.has_work())


func _accept_requester(requester: ZUIContext, capability: RefCounted) -> bool:
	var reason := _requester_reason(requester, capability)
	if not reason.is_empty():
		toast(reason)
		return false
	return true


func _requester_reason(requester: ZUIContext, capability: RefCounted) -> String:
	if requester == null or capability == null:
		return "Dialog request requires an active UI screen context."
	var owner := requester._feedback_owner_for(capability)
	if not is_instance_valid(owner):
		return "Dialog request context has expired."
	if not is_instance_valid(host.screen) or host.screen != owner \
			or owner.app != requester \
			or requester.current_route != String(host.current_route):
		return "Dialog request does not own the active UI screen."
	var menu_top := common_ui_root.menu_layer().get_top_screen()
	var hud_top := common_ui_root.hud_layer().get_top_screen()
	if owner != menu_top and owner != hud_top:
		return "Dialog request screen is no longer in the active CommonUI layer."
	var context := owner.get_context_handle()
	if not owner.is_routing_active() or context == null \
			or not context.is_active() or context.is_suspended():
		return "Dialog request screen is not routing-active."
	return ""


func has_blocking_overlay() -> bool:
	return is_instance_valid(modal) \
			or is_instance_valid(picker) \
			or common_ui_root.modal_layer().get_depth() > 0 \
			or common_ui_root.popup_layer().get_depth() > 0


func is_live_developer_authorization(authorization: RefCounted) -> bool:
	return authorization != null \
			and authorization == _developer_authorization \
			and is_instance_valid(picker) \
			and not bool(picker.get_meta(CLOSING_META, false)) \
			and common_ui_root.popup_layer().get_top_screen() == picker \
			and picker.is_routing_active()


func navigation_blocker(intent: ZUIRouteIntent) -> String:
	if is_instance_valid(modal) or common_ui_root.modal_layer().get_depth() > 0:
		return "UI navigation is blocked while a modal dialog is active."
	var popup_open := is_instance_valid(picker) \
			or common_ui_root.popup_layer().get_depth() > 0
	if intent.origin == ZUIRouteIntent.Origin.DEVELOPER_CATALOG:
		if not is_live_developer_authorization(intent.authorization):
			return "Developer route requires live F1 catalog authorization."
		return ""
	if popup_open:
		return "UI navigation is blocked while the developer catalog is active."
	return ""


func close_picker_for_navigation(authorization: RefCounted) -> Dictionary:
	if not is_live_developer_authorization(authorization):
		return _stack_result(CommonUIStackRequest.Status.ERROR,
			"Developer catalog authorization is no longer active.")
	return await _close_overlay(picker)


func _close_overlay(control: Control) -> Dictionary:
	if not is_instance_valid(control):
		return _stack_result(CommonUIStackRequest.Status.ERROR, "UI overlay is no longer valid.")
	if bool(control.get_meta(CLOSING_META, false)):
		return _stack_result(CommonUIStackRequest.Status.CANCELED, "UI overlay is already closing.")
	var layer: CommonUILayer
	if control == modal:
		layer = common_ui_root.modal_layer()
	elif control == picker:
		layer = common_ui_root.popup_layer()
	else:
		return _stack_result(CommonUIStackRequest.Status.ERROR, "UI overlay is not owned by this host.")
	if layer.get_depth() > 0 and layer.get_top_screen() != control:
		return _stack_result(CommonUIStackRequest.Status.ERROR,
			"UI overlay is not the top of its CommonUI layer.")
	control.set_meta(CLOSING_META, true)
	var request := layer.request_pop()
	var result: Dictionary = await request.wait()
	if int(result.get("status", -1)) == CommonUIStackRequest.Status.SUCCESS:
		_clear_overlay_reference(control)
	elif layer.has_screen(control):
		control.remove_meta(CLOSING_META)
	else:
		_clear_overlay_reference(control)
		if is_instance_valid(control):
			control.queue_free()
	if is_instance_valid(host) and host._resize_pending:
		host._finish_window_resize.call_deferred()
	return result


func _clear_overlay_reference(control: Control) -> void:
	if control == modal:
		modal = null
	if control == picker:
		picker = null
		_developer_authorization = null


func _stack_result(status: int, error: String) -> Dictionary:
	return {"status": status, "screen": null, "error": error}
