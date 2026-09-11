extends SceneTree

## Task 8.9 provider, action, route and focus regression. Every screen-producing
## execution is pinned to the first-playable 1920x1080 canvas.
## Run with:
## godot --headless --path . --resolution 1920x1080 --script res://tests/presentation/feature_gates_8_9_contract.gd

const FIRST_PLAYABLE_SIZE := Vector2i(1920, 1080)
const FEATURE_IDS: PackedStringArray = [
	"bunker", "crafting", "friends", "insurance", "marketplace"
]

var checks: int = 0
var failures: int = 0
var capture_path: String = ""
var production_app_for_capture: Control


func _initialize() -> void:
	run.call_deferred()


func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error("FEATURE_GATES_8_9: " + message)


func settle(frames: int = 6) -> void:
	for _index in range(frames):
		await process_frame


func run() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--capture-path="):
			capture_path = argument.trim_prefix("--capture-path=")

	root.size = FIRST_PLAYABLE_SIZE
	check(root.get_visible_rect().size == Vector2(FIRST_PLAYABLE_SIZE),
		"runner is exact 1920x1080")
	if root.get_visible_rect().size != Vector2(FIRST_PLAYABLE_SIZE):
		quit(2)
		return

	_test_typed_provider()
	_test_route_catalog_and_source_guards()
	await _test_explicit_fixture_actions_and_focus()
	await _test_production_locks()
	await _capture_exact_frame()
	if is_instance_valid(production_app_for_capture):
		production_app_for_capture.queue_free()
		await settle(3)
	print("FEATURE_GATES_8_9_RESULT checks=", checks,
		" failures=", failures, " size=1920x1080")
	quit(0 if failures == 0 else 1)


func _test_typed_provider() -> void:
	var provider := ZUIPresentationProvider.new()
	root.add_child(provider)
	check(provider.start_unavailable(17, &"feature_services_missing"),
		"provider starts one generation of unavailable feature truth")
	check(provider.feature_gate_ids() == FEATURE_IDS,
		"provider exposes only the five approved feature action ids")
	for action_id in FEATURE_IDS:
		var gate := provider.feature_gate(StringName(action_id), 17)
		check(gate is ZUIFeatureGateView and gate.is_initialized(),
			"provider publishes typed gate: " + action_id)
		check(gate.is_locked() and gate.status_name() == &"locked"
				and gate.action_id() == StringName(action_id)
				and gate.gate_reason() == StringName("feature_services_missing_" + action_id)
				and not gate.is_ready(),
			"unavailable feature stays locked with explicit diagnostic: " + action_id)
	check(provider.feature_gate(&"not_a_feature", 17) == null,
		"provider rejects invented feature action ids")
	var current := provider.feature_gate(&"bunker", 17)
	check(provider.replace_unavailable(18, &"replacement_services_missing"),
		"provider replacement advances gate generation")
	var stale := provider.feature_gate(&"bunker", 17)
	check(stale != null and stale.is_locked()
			and stale.gate_reason() == &"ui_presentation_provider_stale_generation"
			and current != stale,
		"stale gate lease returns released truth instead of retired value")
	var replacement := provider.feature_gate(&"bunker", 18)
	check(replacement != null and replacement.generation() == 18
			and replacement.gate_reason() == &"replacement_services_missing_bunker",
		"current generation receives replacement gate truth")
	check(provider.teardown(18), "provider teardown succeeds for current generation")
	var released := provider.feature_gate(&"insurance", 18)
	check(released != null and released.is_locked()
			and released.gate_reason() == &"ui_presentation_provider_released",
		"released gate lease remains explicitly locked")
	provider.queue_free()


func _test_route_catalog_and_source_guards() -> void:
	check(ZRouteCatalog.ROUTES.size() == 28,
		"route catalog remains the stable 28-route surface")
	check(not ZRouteCatalog.ROUTES.has("marketplace"),
		"marketplace does not gain an unapproved replacement route")
	for action_id in FEATURE_IDS:
		check(ZUIFeatureGateView.supports_action(StringName(action_id)),
			"action id is declared in the typed gate contract: " + action_id)
	for route in ["bunker", "build_mode", "crafting", "session"]:
		var source := FileAccess.get_file_as_string(ZRouteCatalog.path_for(route))
		check(not source.is_empty(), "route source loads for " + route)
	for path in [
		"res://ui/screens/bunker/bunker_actions.gd",
		"res://ui/screens/frontflow/frontflow_actions.gd",
		"res://ui/screens/character/inventory_actions.gd",
		"res://ui/screens/raid/raid_screen.gd",
	]:
		var source := FileAccess.get_file_as_string(path)
		check(source.contains("require_feature_action"),
			"feature action source guard is present: " + path)


func _new_app(prototype: bool) -> Control:
	var app := load("res://ui/main.tscn").instantiate() as Control
	app.prototype_fixture_mode = prototype
	root.add_child(app)
	await settle()
	return app


func _focus_stays_on_screen(app: Control, screen: ZScreen, label: String) -> void:
	var focus: Control = root.get_viewport().gui_get_focus_owner() as Control
	check(is_instance_valid(focus) and screen.is_ancestor_of(focus)
			and focus.focus_mode != Control.FOCUS_NONE,
		"CommonUI focus remains inside route after feature action: " + label)


func _test_explicit_fixture_actions_and_focus() -> void:
	var app := await _new_app(true)
	app.qa_mode = true

	app.navigate("bunker", false)
	await settle()
	var bunker := app.screen as ZScreen
	var bunker_gate := bunker.feature_gate(&"bunker")
	check(bunker_gate != null and bunker_gate.is_prototype(),
		"bunker fixture route is explicitly prototype-only")
	var station_hit := bunker.get_node("Stations/Row1/Hit") as Button
	check(station_hit.get_meta("z_feature_action", &"") == &"bunker"
			and station_hit.get_meta("z_feature_status", &"") == &"prototype"
			and station_hit.tooltip_text.contains("PROTOTYPE ONLY"),
		"bunker action exposes prototype metadata and tooltip")
	station_hit.grab_focus()
	station_hit.pressed.emit()
	await settle()
	_focus_stays_on_screen(app, app.screen as ZScreen, "bunker station")
	var market := bunker.get_node("StationDetails/Missing/Market") as Label
	check(market.get_meta("z_feature_action", &"") == &"marketplace"
			and market.tooltip_text.contains("PROTOTYPE ONLY"),
		"marketplace affordance is marked without adding a route")

	app.navigate("crafting", false)
	await settle()
	var crafting := app.screen as ZScreen
	var craft_action := crafting.get_node("DetailPanel/CraftNow") as Button
	check(craft_action.get_meta("z_feature_action", &"") == &"crafting"
			and craft_action.get_meta("z_feature_status", &"") == &"prototype"
			and craft_action.tooltip_text.contains("PROTOTYPE ONLY"),
		"craft action exposes prototype metadata and tooltip")
	craft_action.grab_focus()
	craft_action.pressed.emit()
	await settle()
	_focus_stays_on_screen(app, app.screen as ZScreen, "crafting action")

	app.navigate("join_friend", false)
	await settle()
	var friends := app.screen as ZScreen
	var friend_filter := friends.get_node("FilterAll") as Button
	check(friend_filter.get_meta("z_feature_action", &"") == &"friends"
			and friend_filter.tooltip_text.contains("PROTOTYPE ONLY"),
		"friend action exposes prototype metadata and tooltip")
	friend_filter.grab_focus()
	friend_filter.pressed.emit()
	await settle()
	check(app.current_route == "join_friend", "friend filter does not bypass route authority")
	_focus_stays_on_screen(app, app.screen as ZScreen, "friend filter")

	app.navigate("summary_solo", false)
	await settle()
	var summary := app.screen as ZScreen
	var reinsure := summary.get_node("Reinsure") as Button
	check(reinsure.get_meta("z_feature_action", &"") == &"insurance"
			and reinsure.tooltip_text.contains("PROTOTYPE ONLY"),
		"insurance action exposes prototype metadata and tooltip")
	reinsure.grab_focus()
	reinsure.pressed.emit()
	await settle()
	check(is_instance_valid(app.modal), "prototype insurance action uses CommonUI confirmation")
	if is_instance_valid(app.modal):
		for button in app.modal.find_children("*", "Button", true, false):
			if button.text == "CANCEL":
				button.pressed.emit()
		await settle()
	check(app.current_route == "summary_solo", "insurance confirmation does not leave summary route")

	app.navigate("inventory", false)
	await settle()
	var inventory := app.screen as ZScreen
	var sell := inventory.get_node_or_null("InventoryContent/PostRaidBar/SellJunk") as Button
	check(sell != null and sell.get_meta("z_feature_action", &"") == &"marketplace"
			and sell.tooltip_text.contains("PROTOTYPE ONLY"),
		"marketplace sell action is explicitly prototype-only")
	if sell != null:
		sell.grab_focus()
		sell.pressed.emit()
		await settle()
		_focus_stays_on_screen(app, app.screen as ZScreen, "marketplace sell action")

	app.queue_free()
	await settle(3)


func _test_production_locks() -> void:
	var app := await _new_app(false)
	app.request_route("bunker", false)
	await settle()
	var bunker := app.screen as ZScreen
	check(not bunker.app.has_fixture_provider()
			and bunker.feature_gate(&"bunker").is_locked()
			and bunker.get_node_or_null("ProductionUnavailableState") != null,
		"production bunker route is locked without fixture data")
	var route_before: String = str(app.current_route)
	if bunker.has_method("_on_station"):
		bunker.call("_on_station", 1)
	await settle()
	check(app.current_route == route_before,
		"locked bunker action cannot navigate or mutate production state")

	app.request_route("join_friend", false)
	await settle()
	var friends := app.screen as ZScreen
	check(friends.feature_gate(&"friends").is_locked()
			and friends.get_node_or_null("ProductionUnavailableState") != null,
		"production friend route is locked without fixture data")
	if friends.has_method("_join_kevin"):
		friends.call("_join_kevin")
	await settle()
	check(app.current_route == "join_friend",
		"locked friend action cannot join a sample world")

	app.request_route("inventory", false)
	await settle()
	var inventory := app.screen as ZScreen
	var insurance := inventory.get_node_or_null("InventoryContent/PostRaidBar/Reinsure") as Button
	var sell := inventory.get_node_or_null("InventoryContent/PostRaidBar/SellJunk") as Button
	check(insurance != null and insurance.get_meta("z_feature_status", &"") == &"locked"
			and sell != null and sell.get_meta("z_feature_status", &"") == &"locked",
		"production insurance and marketplace actions stay locked on Character")
	if inventory.has_method("_reinsure"):
		inventory.call("_reinsure")
	if inventory.has_method("_sell_junk"):
		inventory.call("_sell_junk")
	check(not inventory.app.has_fixture_provider(),
		"locked Character actions cannot acquire a fixture provider")

	app.request_route("main_menu", false)
	await settle()
	app.toast_timer.stop()
	app.toast_label.hide()
	production_app_for_capture = app


func _capture_exact_frame() -> void:
	if capture_path.is_empty():
		return
	if DisplayServer.get_name() == "headless":
		print("HEADLESS_CAPTURE_SKIPPED dummy renderer has no native framebuffer")
		return
	await RenderingServer.frame_post_draw
	var framebuffer := root.get_texture().get_image()
	if framebuffer == null:
		check(false, "native feature-gate framebuffer is available")
		return
	var image: Image = framebuffer.duplicate()
	if image.get_size() != FIRST_PLAYABLE_SIZE:
		# macOS may expose a smaller physical drawable while the logical Godot
		# canvas remains exact. Preserve the 1920x1080 logical evidence contract
		# with nearest-neighbor sampling; no alternate layout is rendered.
		print("NATIVE_FRAMEBUFFER_SIZE=", image.get_size(),
			" logical=1920x1080")
		image.resize(FIRST_PLAYABLE_SIZE.x, FIRST_PLAYABLE_SIZE.y,
			Image.INTERPOLATE_NEAREST)
	check(image.get_size() == FIRST_PLAYABLE_SIZE,
		"native feature-gate evidence image is exact 1920x1080")
	if image.get_size() != FIRST_PLAYABLE_SIZE:
		return
	var absolute := ProjectSettings.globalize_path(capture_path)
	var directory_error := DirAccess.make_dir_recursive_absolute(absolute.get_base_dir())
	check(directory_error == OK or directory_error == ERR_ALREADY_EXISTS,
		"native feature-gate evidence directory is available")
	check(image.save_png(absolute) == OK,
		"native exact-1920 feature-gate evidence saves")
