class_name ZUIContext
extends RefCounted

## A screen receives its own route identity and a narrow set of UI services.
## Weak host ownership lets covered/removed screens release cleanly.
var current_route: String
var _host: WeakRef
var _feedback_owner: WeakRef
var _feedback_capability: RefCounted
var _fixture_provider: WeakRef
var _fixture_generation: int = 0
var _presentation_provider: WeakRef
var _presentation_generation: int = 0
## Records that this view was entered from the explicit developer catalog.
## It does not confer permission to forge later catalog selections.
var developer_context: bool = false
var route_payload: ZUIRoutePayload
var _local_game_ui: WeakRef
var _local_epoch: int = 0
var _character_runtime: WeakRef
## Route immediately beneath this view when it was pushed, or the inherited
## return target when it replaced a view. CommonUI remains stack authority.
var return_route: String = ""

var qa_mode: bool:
	get: return bool(_service().qa_mode) if _service() != null else true
var modal: Control:
	get: return _service().modal if _service() != null else null
var picker: Control:
	get: return _service().picker if _service() != null else null

## The one game-owned input facade available to production screens.  Screens
## never receive CommonUI's native registry or an InputMap mirror; controls and
## other presentation surfaces ask this facade to resolve or mutate logical
## bindings through its bounded request API.
func input_service() -> ZerkovInputService:
	var host := _service()
	return host.input_service as ZerkovInputService if host != null else null

func _init(
	host: Node,
	route: String,
	fixture_provider: ZUIFixtureProvider = null,
	is_developer_context: bool = false,
	payload: ZUIRoutePayload = null,
	character_runtime: CharacterUIRuntime = null,
	presentation_provider: ZUIPresentationProvider = null
) -> void:
	_host = weakref(host)
	current_route = route
	_fixture_provider = weakref(fixture_provider) if fixture_provider != null else null
	_fixture_generation = fixture_provider.generation() if fixture_provider != null else 0
	_presentation_provider = weakref(presentation_provider) \
			if presentation_provider != null else null
	_presentation_generation = presentation_provider.generation() \
			if presentation_provider != null else 0
	developer_context = is_developer_context
	route_payload = payload if payload != null else ZUIRoutePayload.empty()
	_character_runtime = weakref(character_runtime) if character_runtime != null else null
	if fixture_provider == null and not is_developer_context and host.has_method("local_game_ui"):
		var local: LocalGameUI = host.call("local_game_ui")
		if local != null:
			_local_game_ui = weakref(local)
			_local_epoch = int(local.snapshot().get("epoch", 0))


func local_game_ui() -> LocalGameUI:
	var local := _local_game_ui.get_ref() as LocalGameUI if _local_game_ui != null else null
	return local if local != null and int(local.snapshot().get("epoch", 0)) == _local_epoch else null


func local_epoch() -> int:
	return _local_epoch



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


func has_fixture_provider() -> bool:
	var provider := _fixture_service()
	return provider != null and provider.is_current(_fixture_generation)


func fixture_generation() -> int:
	return _fixture_generation


## Mutable fixture access is intentionally conspicuous and generation-gated.
## It exists only for developer/test contexts; production screens receive no
## fixture provider and therefore cannot read or write this document.
func fixture_state() -> Dictionary:
	var provider := _fixture_service()
	if provider == null:
		return {}
	var value: Variant = provider.state(_fixture_generation)
	return value as Dictionary if value is Dictionary else {}


func fixture_get(key: String, fallback: Variant = null) -> Variant:
	var provider := _fixture_service()
	if provider == null:
		return null
	var value: Variant = provider.state(_fixture_generation)
	return (value as Dictionary).get(key, fallback) \
			if value is Dictionary else null


func fixture_has(key: String) -> bool:
	var provider := _fixture_service()
	if provider == null:
		return false
	var value: Variant = provider.state(_fixture_generation)
	return value is Dictionary and (value as Dictionary).has(key)


func fixture_set(key: String, value: Variant) -> bool:
	var provider := _fixture_service()
	if provider == null:
		return false
	var document: Variant = provider.state(_fixture_generation)
	if not document is Dictionary:
		return false
	(document as Dictionary)[key] = value
	return true


func prepare_fixture_route() -> bool:
	var provider := _fixture_service()
	return provider != null \
			and provider.prepare_route(current_route, _fixture_generation)


func fixture_catalog(name: StringName) -> Variant:
	var provider := _fixture_service()
	return provider.catalog(name, _fixture_generation) \
			if provider != null else null


func presentation_generation() -> int:
	return _presentation_generation


func presentation_view() -> ZReadOnlyView:
	var provider := _presentation_service()
	return provider.view_for_route(current_route, _presentation_generation) \
			if provider != null else null


func bunker_view() -> BunkerView:
	var provider := _presentation_service()
	return provider.bunker_view(_presentation_generation) \
			if provider != null else BunkerView.unavailable(
				ZReadOnlyView.SyncState.UNBOUND,
				&"ui_presentation_provider_missing")


func raid_view() -> RaidView:
	var provider := _presentation_service()
	return provider.raid_view(_presentation_generation) \
			if provider != null else RaidView.unavailable(
				ZReadOnlyView.SyncState.UNBOUND,
				&"ui_presentation_provider_missing")


func task_view() -> TaskView:
	var provider := _presentation_service()
	return provider.task_view(_presentation_generation) \
			if provider != null else TaskView.unavailable(
				ZReadOnlyView.SyncState.UNBOUND,
				&"ui_presentation_provider_missing")


func map_view() -> MapView:
	var provider := _presentation_service()
	return provider.map_view(_presentation_generation) \
			if provider != null else MapView.unavailable(
				ZReadOnlyView.SyncState.UNBOUND,
				&"ui_presentation_provider_missing")


func summary_view() -> SummaryView:
	var provider := _presentation_service()
	return provider.summary_view(_presentation_generation) \
			if provider != null else SummaryView.unavailable(
				ZReadOnlyView.SyncState.UNBOUND,
				&"ui_presentation_provider_missing")


## Feature gates are typed presentation metadata, never a mutation surface.
## Explicit fixture contexts expose a visibly marked prototype status; every
## production context asks the generation-scoped provider for locked truth.
func feature_gate(action_id: StringName) -> ZUIFeatureGateView:
	if not ZUIFeatureGateView.supports_action(action_id):
		return null
	if has_fixture_provider():
		return ZUIFeatureGateView.prototype(action_id, &"ui_feature_fixture_only",
			_fixture_generation)
	var provider := _presentation_service()
	return provider.feature_gate(action_id, _presentation_generation) \
			if provider != null else ZUIFeatureGateView.locked(
				action_id, &"ui_presentation_provider_missing",
				_presentation_generation if _presentation_generation > 0 else 0)


func feature_gate_ids() -> PackedStringArray:
	return ZUIFeatureGateView.ACTION_IDS.duplicate()


func presentation_diagnostic() -> StringName:
	var view := presentation_view()
	if view != null:
		return view.diagnostic()
	var provider := _presentation_service()
	if provider == null:
		return &"ui_presentation_provider_missing"
	if provider.generation() != _presentation_generation:
		return &"ui_presentation_provider_stale_generation"
	if not provider.is_active():
		return &"ui_presentation_provider_released"
	return &"ui_route_service_not_injected"


func _fixture_service() -> ZUIFixtureProvider:
	return _fixture_provider.get_ref() as ZUIFixtureProvider \
			if _fixture_provider != null else null


func _presentation_service() -> ZUIPresentationProvider:
	return _presentation_provider.get_ref() as ZUIPresentationProvider \
			if _presentation_provider != null else null

func navigate(
	route: String,
	record: bool = true,
	payload: ZUIRoutePayload = null
) -> bool:
	var local := local_game_ui()
	if _local_game_ui != null and local == null: return false
	var command := LocalGameUI.route_command(route)
	if local != null and not command.is_empty(): return local.request(command, _local_epoch)
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
	var local := local_game_ui()
	if _local_game_ui != null and local == null: return false
	if local != null:
		if current_route == "summary_solo": return local.request(&"return_home", _local_epoch)
		return local.request(&"pause" if current_route in ["hud", "bunker"] else &"resume", _local_epoch)
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
