class_name ZUIContext
extends RefCounted

## A screen receives its own route identity and a narrow set of UI services.
## Weak host ownership lets covered/removed screens release cleanly.
var current_route: String
var _host: WeakRef
var fixtures: ZUIFixtureStore
## Records that this view was entered from the explicit developer catalog.
## It does not confer permission to forge later catalog selections.
var developer_context: bool = false
var route_payload: ZUIRoutePayload
## Route immediately beneath this view when it was pushed, or the inherited
## return target when it replaced a view. CommonUI remains stack authority.
var return_route: String = ""

var state: Dictionary:
	get: return fixtures.state
var qa_mode: bool:
	get: return bool(_service().qa_mode) if _service() != null else true
var modal: Control:
	get: return _service().modal if _service() != null else null
var picker: Control:
	get: return _service().picker if _service() != null else null

func _init(
	host: Node,
	route: String,
	store: ZUIFixtureStore,
	is_developer_context: bool = false,
	payload: ZUIRoutePayload = null
) -> void:
	_host = weakref(host)
	current_route = route
	fixtures = store
	developer_context = is_developer_context
	route_payload = payload if payload != null else ZUIRoutePayload.empty()

func _service() -> Node:
	return _host.get_ref() as Node

func navigate(
	route: String,
	record: bool = true,
	payload: ZUIRoutePayload = null
) -> bool:
	var host := _service()
	if host == null:
		return false
	return bool(host.submit_navigation(ZUIRouteIntent.open_route(
		StringName(route),
		StringName(current_route),
		ZUIRouteIntent.Origin.PRODUCTION,
		ZUIRouteIntent.StackMode.AUTO if record else ZUIRouteIntent.StackMode.RESET,
		payload
	)))

func back() -> bool:
	var host := _service()
	if host == null:
		return false
	return bool(host.submit_navigation(ZUIRouteIntent.back(
		StringName(current_route),
		ZUIRouteIntent.Origin.PRODUCTION
	)))

func toast(message: String) -> void:
	if _service() != null: _service().toast(message)

func confirm(title: String, message: String, callback: Callable) -> bool:
	return bool(_service().confirm(title, message, callback)) if _service() != null else false

func prompt(title: String, value: String, callback: Callable, max_length: int = 24) -> bool:
	return bool(_service().prompt(title, value, callback, max_length)) if _service() != null else false

func accepts_input(view: Control) -> bool:
	var host := _service()
	return host != null and host.screen == view and not is_instance_valid(modal) and not is_instance_valid(picker)
