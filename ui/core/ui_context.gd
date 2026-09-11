class_name ZUIContext
extends RefCounted

## A screen receives its own route identity and a narrow set of UI services.
## Weak host ownership lets covered/removed screens release cleanly.
var current_route: String
var _host: WeakRef
var _feedback_owner: WeakRef
var _feedback_capability: RefCounted
var fixtures: ZUIFixtureStore
## Records that this view was entered from the explicit developer catalog.
## It does not confer permission to forge later catalog selections.
var developer_context: bool = false
var route_payload: ZUIRoutePayload
var _character_runtime: WeakRef
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
	payload: ZUIRoutePayload = null,
	character_runtime: CharacterUIRuntime = null
) -> void:
	_host = weakref(host)
	current_route = route
	fixtures = store
	developer_context = is_developer_context
	route_payload = payload if payload != null else ZUIRoutePayload.empty()
	_character_runtime = weakref(character_runtime) if character_runtime != null else null


## Bind this context to the one screen instance created with it. The opaque
## capability is never supplied by screen code; it only accompanies requests
## made through this exact context.
func _bind_feedback_owner(owner: ZScreen) -> bool:
	if owner == null or owner.app != self \
			or _feedback_owner != null or _feedback_capability != null:
		return false
	_feedback_owner = weakref(owner)
	_feedback_capability = RefCounted.new()
	return true


func _feedback_owner_for(capability: RefCounted) -> ZScreen:
	if capability == null or capability != _feedback_capability or _feedback_owner == null:
		return null
	return _feedback_owner.get_ref() as ZScreen

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
	var host := _service()
	return bool(host.request_confirm(
		self, _feedback_capability, title, message, callback
	)) if host != null else false

func prompt(title: String, value: String, callback: Callable, max_length: int = 24) -> bool:
	var host := _service()
	return bool(host.request_prompt(
		self, _feedback_capability, title, value, callback, max_length
	)) if host != null else false

func accepts_input(view: Control) -> bool:
	var host := _service()
	return host != null and host.screen == view and not is_instance_valid(modal) and not is_instance_valid(picker)


func character_runtime() -> CharacterUIRuntime:
	return _character_runtime.get_ref() as CharacterUIRuntime \
		if _character_runtime != null else null
