class_name ZUINavigator
extends Node

signal committed(route: String, view: Control)
signal rejected(route: String, reason: String)

var host: Control
var root: CommonUIScreenRoot
var _pending: Array[Dictionary] = []
var busy: bool = false

func configure(owner_host: Control, screen_root: CommonUIScreenRoot) -> void:
	host = owner_host
	root = screen_root

func navigate(route: String, record: bool = true) -> void:
	if not ZRouteCatalog.ROUTES.has(route):
		rejected.emit(route, "Unknown prototype screen: " + route)
		return
	_pending.append({"route": route, "record": record})
	if not busy: _drain.call_deferred()

func back() -> void:
	_pending.append({"back": true})
	if not busy: _drain.call_deferred()

func _drain() -> void:
	if busy: return
	busy = true
	while not _pending.is_empty() and is_inside_tree():
		var request: Dictionary = _pending.pop_front()
		if request.has("back"):
			await _pop()
		else:
			await _open(str(request.route), bool(request.record))
	busy = false

func _open(route: String, record: bool) -> void:
	var scene := ZRouteCatalog.scene_for(route)
	if scene == null:
		rejected.emit(route, "Unable to load UI screen: " + route)
		return
	if host.current_route == route and host.screen is ZScreen:
		host.screen.refresh_view()
		return
	var instance := scene.instantiate()
	var next := instance as ZScreen
	if next == null:
		instance.free()
		rejected.emit(route, "Route does not contain a ZScreen: " + route)
		return
	next.app = ZUIContext.new(host, route, host.fixtures)
	var role := ZRouteCatalog.role_for(route)
	var layer := root.hud_layer() if role == "hud" else root.menu_layer()
	var old_role := ZRouteCatalog.role_for(str(host.current_route))
	var reset := not record or role in ["root", "hud", "summary"] or (role == "bunker" and old_role in ["summary", "hud"])
	var replace := reset or (role == "workspace" and old_role == "workspace") or (role == "bunker" and old_role == "bunker")
	if layer == root.menu_layer() and not reset:
		next.lower_contexts = active_contexts([root.hud_layer()], true)
		next.suspends_lower_contexts = not next.lower_contexts.is_empty()
	var previous := layer.get_top_screen()
	var result: Dictionary
	if replace:
		result = await layer.replace_screen(next)
	else:
		result = await layer.push_screen(next)
	if int(result.get("status", -1)) != CommonUIStackRequest.Status.SUCCESS:
		if is_instance_valid(next) and next.get_parent() == null: next.free()
		rejected.emit(route, str(result.get("error", "Navigation canceled")))
		return
	if reset:
		await _keep_only(layer, next)
		var other := root.menu_layer() if role == "hud" else root.hud_layer()
		if other.get_depth() > 0: await other.teardown()
	elif is_instance_valid(previous) and previous != next:
		previous.hide()
	_publish()

func _keep_only(layer: CommonUILayer, view: CommonActivatableScreen) -> void:
	if layer.get_depth() <= 1: return
	# Stage/activate the destination before discarding history. All removals still
	# use CommonUI transactions; an invalid destination never clears the caller.
	view.keep_alive_when_popped = true
	await layer.pop_screen()
	await layer.teardown()
	await layer.push_screen(view)
	view.keep_alive_when_popped = false

func _pop() -> void:
	var menu := root.menu_layer()
	if menu.get_depth() > 1 or (menu.get_depth() > 0 and root.hud_layer().get_depth() > 0):
		await menu.pop_screen()
		_publish()
	else:
		await _open("main_menu", false)

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
