class_name ZUINavigator
extends Node

signal committed(route: String, view: Control)
signal rejected(route: String, reason: String)

const MAX_PENDING_INTENTS := 32

var host: Control
var root: CommonUIScreenRoot
var _pending: Array[ZUIRouteIntent] = []
var busy: bool = false

func configure(owner_host: Control, screen_root: CommonUIScreenRoot) -> void:
	host = owner_host
	root = screen_root


func has_work() -> bool:
	return busy or not _pending.is_empty()


func submit(value: Variant) -> bool:
	var reason := ZRouteCatalog.validate_intent(value)
	var route := String(value.route_id) if value is ZUIRouteIntent else ""
	if not reason.is_empty():
		_reject(route, reason)
		return false
	var intent := value as ZUIRouteIntent
	if intent.origin == ZUIRouteIntent.Origin.SYSTEM:
		_reject(route, "System UI route intents are internal-only.")
		return false
	reason = _validate_live_origin(intent)
	if not reason.is_empty():
		_reject(route, reason)
		return false
	reason = _overlay_blocker(intent)
	if not reason.is_empty():
		_reject(route, reason)
		return false
	if _pending.size() >= MAX_PENDING_INTENTS:
		_reject(route, "UI route intent queue is full.")
		return false
	# Queue a detached command value. Callers cannot mutate an already-admitted
	# route or payload while a CommonUI transition is awaiting completion.
	_pending.append(ZUIRouteIntent.new(
		intent.kind,
		intent.route_id,
		intent.origin_route,
		intent.origin,
		intent.stack_mode,
		intent.payload,
		intent.authorization
	))
	if not busy:
		_drain.call_deferred()
	return true


func _validate_live_origin(intent: ZUIRouteIntent) -> String:
	var expected := String(intent.origin_route)
	if intent.kind == ZUIRouteIntent.Kind.BACK and expected != String(host.current_route):
		return "Stale Back intent from '%s'; active route is '%s'." % [
			expected,
			str(host.current_route),
		]
	if intent.origin == ZUIRouteIntent.Origin.REVIEW:
		if not host.allows_review_navigation():
			return "Review UI navigation is unavailable in a production session."
		# Review crawlers intentionally enqueue resets faster than routes commit.
		return ""
	if intent.origin == ZUIRouteIntent.Origin.SYSTEM:
		return ""
	if expected.is_empty():
		return "" if String(host.current_route).is_empty() else "Missing UI route intent origin."
	if expected != String(host.current_route):
		return "Stale UI route intent from '%s'; active route is '%s'." % [
			expected,
			str(host.current_route),
		]
	return ""


func _overlay_blocker(intent: ZUIRouteIntent) -> String:
	if host.feedback == null:
		return ""
	return host.feedback.navigation_blocker(intent)


func _reject(route: String, reason: String) -> void:
	rejected.emit(route, reason)

func _drain() -> void:
	if busy:
		return
	busy = true
	while not _pending.is_empty() and is_inside_tree():
		var intent: ZUIRouteIntent = _pending.pop_front()
		var reason := ZRouteCatalog.validate_intent(intent)
		if reason.is_empty():
			reason = _validate_live_origin(intent)
		if reason.is_empty():
			reason = _overlay_blocker(intent)
		if not reason.is_empty():
			_reject(String(intent.route_id), reason)
			continue
		if intent.origin == ZUIRouteIntent.Origin.DEVELOPER_CATALOG:
			var close_result: Dictionary = await host.feedback.close_picker_for_navigation(
				intent.authorization
			)
			if int(close_result.get("status", -1)) != CommonUIStackRequest.Status.SUCCESS:
				_reject(String(intent.route_id), str(close_result.get(
					"error", "Developer catalog could not close safely."
				)))
				continue
			reason = _validate_live_origin(intent)
			if reason.is_empty() and host.feedback.has_blocking_overlay():
				reason = "A UI overlay opened while the developer catalog was closing."
			if not reason.is_empty():
				_reject(String(intent.route_id), reason)
				continue
		if intent.kind == ZUIRouteIntent.Kind.BACK:
			await _apply_back(intent)
		else:
			await _open(intent)
	busy = false


func _open(intent: ZUIRouteIntent) -> void:
	var route := String(intent.route_id)
	var scene := ZRouteCatalog.scene_for(route)
	if scene == null:
		_reject(route, "Unable to load UI screen: " + route)
		return
	if host.current_route == route and host.screen is ZScreen:
		host.screen.refresh_view()
		return
	var instance := scene.instantiate()
	var next := instance as ZScreen
	if next == null:
		instance.free()
		_reject(route, "Route does not contain a ZScreen: " + route)
		return
	next.app = ZUIContext.new(
		host,
		route,
		host.fixtures,
		intent.origin == ZUIRouteIntent.Origin.DEVELOPER_CATALOG \
				or ZRouteCatalog.is_developer_only(route),
		intent.payload
	)
	if not next.app._bind_feedback_owner(next):
		next.free()
		_reject(route, "Unable to bind the UI screen feedback context: " + route)
		return
	var role := ZRouteCatalog.role_for(route)
	var layer := root.layer(ZRouteCatalog.layer_for(route))
	if layer == null:
		next.free()
		_reject(route, "CommonUI layer is unavailable for route: " + route)
		return
	var old_role := ZRouteCatalog.role_for(str(host.current_route))
	var reset := intent.stack_mode == ZUIRouteIntent.StackMode.RESET \
			or role in ["root", "hud", "summary"] \
			or (role == "bunker" and old_role in ["summary", "hud"])
	var replace := reset or (role == "workspace" and old_role == "workspace") or (role == "bunker" and old_role == "bunker")
	if layer == root.menu_layer() and not reset:
		next.lower_contexts = active_contexts([root.hud_layer()], true)
		next.suspends_lower_contexts = not next.lower_contexts.is_empty()
	var previous := layer.get_top_screen()
	if reset:
		next.app.return_route = ""
	elif replace and previous is ZScreen:
		next.app.return_route = previous.app.return_route
	elif previous is ZScreen:
		next.app.return_route = previous.app.current_route
	var result: Dictionary
	var options := {
		"route_id": intent.route_id,
		"payload_type": intent.payload.type_id,
		"return_route": StringName(next.app.return_route),
	}
	if replace:
		result = await layer.replace_screen(next, options)
	else:
		result = await layer.push_screen(next, options)
	if int(result.get("status", -1)) != CommonUIStackRequest.Status.SUCCESS:
		if is_instance_valid(next) and next.get_parent() == null:
			next.free()
		_reject(route, str(result.get("error", "Navigation canceled")))
		return
	if reset:
		await _keep_only(layer, next, options)
		var other := root.menu_layer() if role == "hud" else root.hud_layer()
		if other.get_depth() > 0:
			await other.teardown()
	elif is_instance_valid(previous) and previous != next:
		previous.hide()
	_publish()

func _keep_only(
	layer: CommonUILayer,
	view: CommonActivatableScreen,
	options: Dictionary
) -> void:
	if layer.get_depth() <= 1:
		return
	# Stage/activate the destination before discarding history. All removals still
	# use CommonUI transactions; an invalid destination never clears the caller.
	view.keep_alive_when_popped = true
	await layer.pop_screen()
	await layer.teardown()
	await layer.push_screen(view, options)
	view.keep_alive_when_popped = false


func _apply_back(intent: ZUIRouteIntent) -> void:
	var route := String(intent.route_id)
	var policy := ZRouteCatalog.back_policy_for(route)
	if policy.get("operation") == ZRouteCatalog.BACK_OPEN:
		var target := String(policy.get("target", ""))
		# When this route was pushed directly over its declared Back target,
		# reveal that retained CommonUI screen instead of pushing a duplicate.
		# Example: HUD -> Pause -> Session -> Back must reveal Pause, whose
		# Resume then reveals the retained HUD.
		if host.screen is ZScreen \
				and host.screen.app.return_route == target \
				and root.menu_layer().get_depth() > 1:
			await _pop(route)
			return
		await _open(ZUIRouteIntent.open_route(
			StringName(target),
			StringName(route),
			ZUIRouteIntent.Origin.SYSTEM
		))
		return
	await _pop(route)


func _pop(route: String = "") -> void:
	var menu := root.menu_layer()
	if menu.get_depth() > 1 or (menu.get_depth() > 0 and root.hud_layer().get_depth() > 0):
		var result := await menu.pop_screen({"route_id": StringName(route), "operation": ZRouteCatalog.BACK_POP})
		if int(result.get("status", -1)) != CommonUIStackRequest.Status.SUCCESS:
			_reject(route, str(result.get("error", "Back navigation canceled")))
			return
		_publish()
	else:
		await _open(ZUIRouteIntent.open_route(
			&"main_menu",
			StringName(route),
			ZUIRouteIntent.Origin.SYSTEM,
			ZUIRouteIntent.StackMode.RESET
		))

func _publish() -> void:
	var view := root.menu_layer().get_top_screen()
	var hud := root.hud_layer().get_top_screen()
	if hud != null:
		hud.process_mode = Node.PROCESS_MODE_DISABLED if view != null else Node.PROCESS_MODE_INHERIT
	if view == null: view = hud
	if view is ZScreen:
		committed.emit(view.app.current_route, view)

func history() -> Array[String]:
	var result: Array[String] = []
	for layer in [root.hud_layer(), root.menu_layer()]:
		for child in layer.get_children():
			if child is ZScreen and child != host.screen and layer.has_screen(child):
				result.append(child.app.current_route)
	return result

static func active_contexts(layers: Array, include_suspended: bool = false) -> Array[CommonUIContextHandle]:
	var handles: Array[CommonUIContextHandle] = []
	for layer in layers:
		var view: CommonActivatableScreen = layer.get_top_screen()
		if view != null:
			var handle := view.get_context_handle()
			if handle != null and handle.is_active() and (include_suspended or not handle.is_suspended()):
				handles.append(handle)
	return handles
