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
var production_render_target: SubViewport
var exact_cli_resolution: bool = false


func _initialize() -> void:
	exact_cli_resolution = _has_exact_cli_resolution()
	run.call_deferred()


func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error("FEATURE_GATES_8_9: " + message)


func settle(frames: int = 6) -> void:
	for _index in range(frames):
		await process_frame


func _has_exact_cli_resolution() -> bool:
	# Godot consumes --resolution before OS.get_cmdline_args(). Inspect only this
	# process's real argv through ps; never accept a forwarded user-argument
	# claim as proof of the engine flag. Unsupported hosts fail before mounting.
	# https://docs.godotengine.org/en/stable/classes/class_os.html#class-os-method-get-cmdline-args
	if OS.get_name() not in ["macOS", "Linux", "FreeBSD", "NetBSD", "OpenBSD", "BSD"]:
		return false
	var output: Array = []
	var status := OS.execute("/bin/ps",
		PackedStringArray(["-ww", "-p", str(OS.get_process_id()), "-o", "command="]), output)
	if status != 0 or output.size() != 1:
		return false
	var engine_command := str(output[0]).strip_edges().split(" -- ", true, 1)[0]
	var expression := RegEx.new()
	if expression.compile("(?:^|[[:space:]])--resolution(?:[[:space:]]+|=)([^[:space:]]+)") != OK:
		return false
	var matches := expression.search_all(engine_command)
	return matches.size() == 1 and matches[0].get_string(1) == "1920x1080"


func run() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--capture-path="):
			capture_path = argument.trim_prefix("--capture-path=")
	if DisplayServer.get_name() != "headless" and not await _native_output_preflight():
		print("FEATURE_GATES_8_9_RESULT checks=0 failures=1 size=1920x1080 preflight=rejected")
		quit(2)
		return
	check(exact_cli_resolution,
		"screen-producing CLI explicitly requests --resolution 1920x1080")
	if not exact_cli_resolution:
		quit(2)
		return

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
	if is_instance_valid(production_render_target):
		production_render_target.queue_free()
		await settle(3)
	print("FEATURE_GATES_8_9_RESULT checks=", checks,
		" failures=", failures, " size=1920x1080")
	quit(0 if failures == 0 else 1)


func _native_output_preflight() -> bool:
	# Fullscreen may be supplied by the launcher on a 1920x1080 display. Never
	# relabel a clamped physical window by assigning a logical root size.
	await settle()
	if not exact_cli_resolution or not _native_window_is_exact():
		push_error("FEATURE_GATES_8_9: physical window/root preflight rejected before UI mount")
		return false
	await RenderingServer.frame_post_draw
	var texture := root.get_texture()
	if texture == null or texture.get_size() != Vector2(FIRST_PLAYABLE_SIZE):
		push_error("FEATURE_GATES_8_9: physical root texture rejected before UI mount")
		return false
	var image := texture.get_image()
	if image == null or image.get_size() != FIRST_PLAYABLE_SIZE or not _native_window_is_exact():
		push_error("FEATURE_GATES_8_9: physical root readback rejected before UI mount")
		return false
	print("EXACT_1920_NATIVE_PREFLIGHT physical_window=1920x1080 root=1920x1080",
		" root_texture=1920x1080 raw_root_image=1920x1080 ui_mounted=false")
	return true


func _native_window_is_exact() -> bool:
	return DisplayServer.window_get_size(root.get_window_id()) == FIRST_PLAYABLE_SIZE \
		and root.size == FIRST_PLAYABLE_SIZE \
		and root.get_visible_rect().size == Vector2(FIRST_PLAYABLE_SIZE)


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


func _new_render_target() -> SubViewport:
	var result := SubViewport.new()
	result.name = "Task89ContractExact1920RenderTarget"
	result.disable_3d = true
	result.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	result.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	result.canvas_item_default_texture_filter = Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST
	result.snap_2d_transforms_to_pixel = true
	result.size = FIRST_PLAYABLE_SIZE
	root.add_child(result)
	var input_router := CommonUIViewportRouter.new()
	input_router.name = "Task89ContractExact1920InputRouter"
	result.add_child(input_router)
	return result


func _new_app(prototype: bool, host: Node = null) -> Control:
	var app := load("res://ui/main.tscn").instantiate() as Control
	app.prototype_fixture_mode = prototype
	var parent: Node = root if host == null else host
	parent.add_child(app)
	app.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	app.position = Vector2.ZERO
	app.size = Vector2(FIRST_PLAYABLE_SIZE)
	await settle()
	return app


func _focus_stays_on_screen(app: Control, screen: ZScreen, label: String) -> void:
	var focus: Control = app.get_viewport().gui_get_focus_owner() as Control
	check(is_instance_valid(focus) and screen.is_ancestor_of(focus)
			and focus.focus_mode != Control.FOCUS_NONE,
		"CommonUI focus remains inside route after feature action: " + label)


func _test_explicit_fixture_actions_and_focus() -> void:
	var fixture_target := _new_render_target()
	var app := await _new_app(true, fixture_target)
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
	var bunker_state_before := JSON.stringify(app.fixture_state_for_test())
	await _activate_with_enter(app, station_hit)
	await settle()
	_focus_stays_on_screen(app, app.screen as ZScreen, "bunker station")
	check(JSON.stringify(app.fixture_state_for_test()) == bunker_state_before
			and app.current_route == "bunker" and app.modal == null
			and app.toast_label.visible and app.toast_label.text.contains("PROTOTYPE ONLY")
			and app.toast_label.text.contains("Bunker"),
		"bunker prototype callback reports the gate without fixture side effects")
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
	var crafting_state_before := JSON.stringify(app.fixture_state_for_test())
	await _activate_with_enter(app, craft_action)
	await settle()
	_focus_stays_on_screen(app, app.screen as ZScreen, "crafting action")
	check(JSON.stringify(app.fixture_state_for_test()) == crafting_state_before
			and app.current_route == "crafting" and app.modal == null
			and app.toast_label.visible and app.toast_label.text.contains("PROTOTYPE ONLY")
			and app.toast_label.text.contains("Crafting"),
		"crafting prototype callback reports the gate without fixture side effects")

	app.navigate("join_friend", false)
	await settle()
	var friends := app.screen as ZScreen
	var friend_filter := friends.get_node("FilterAll") as Button
	check(friend_filter.get_meta("z_feature_action", &"") == &"friends"
			and friend_filter.tooltip_text.contains("PROTOTYPE ONLY"),
		"friend action exposes prototype metadata and tooltip")
	friend_filter.grab_focus()
	var friends_state_before := JSON.stringify(app.fixture_state_for_test())
	await _activate_with_enter(app, friend_filter)
	await settle()
	check(app.current_route == "join_friend", "friend filter does not bypass route authority")
	_focus_stays_on_screen(app, app.screen as ZScreen, "friend filter")
	check(JSON.stringify(app.fixture_state_for_test()) == friends_state_before
			and app.modal == null and app.toast_label.visible
			and app.toast_label.text.contains("PROTOTYPE ONLY")
			and app.toast_label.text.contains("Friends"),
		"friend prototype callback reports the gate without fixture side effects")

	app.navigate("summary_solo", false)
	await settle()
	var summary := app.screen as ZScreen
	var reinsure := summary.get_node("Reinsure") as Button
	check(reinsure.get_meta("z_feature_action", &"") == &"insurance"
			and reinsure.tooltip_text.contains("PROTOTYPE ONLY"),
		"insurance action exposes prototype metadata and tooltip")
	reinsure.grab_focus()
	await _activate_with_enter(app, reinsure)
	await settle()
	check(not is_instance_valid(app.modal)
			and app.current_route == "summary_solo"
			and app.toast_label.visible and app.toast_label.text.contains("PROTOTYPE ONLY")
			and app.toast_label.text.contains("Insurance"),
		"insurance prototype callback reports the gate without opening a modal")

	app.navigate("inventory", false)
	await settle()
	var inventory := app.screen as ZScreen
	var sell := inventory.get_node_or_null("InventoryContent/PostRaidBar/SellJunk") as Button
	check(sell != null and sell.get_meta("z_feature_action", &"") == &"marketplace"
			and sell.tooltip_text.contains("PROTOTYPE ONLY"),
		"marketplace sell action is explicitly prototype-only")
	if sell != null:
		sell.grab_focus()
		await _activate_with_enter(app, sell)
		await settle()
		_focus_stays_on_screen(app, app.screen as ZScreen, "marketplace sell action")
		check(app.current_route == "inventory" and app.modal == null
				and app.toast_label.visible and app.toast_label.text.contains("PROTOTYPE ONLY")
				and app.toast_label.text.contains("Marketplace"),
			"marketplace prototype callback reports the gate without fixture side effects")

	fixture_target.queue_free()
	await settle(3)


func _activate_with_enter(app: Control, control: BaseButton) -> void:
	check(control.is_visible_in_tree() and not control.disabled,
		"authored gated button is visible and enabled for Enter")
	app.toast_timer.stop()
	app.toast_label.hide()
	app.toast_label.text = ""
	var pressed_count := {"value": 0}
	var observer := func() -> void: pressed_count["value"] += 1
	control.pressed.connect(observer)
	var event := InputEventKey.new()
	event.keycode = KEY_ENTER
	event.physical_keycode = KEY_ENTER
	event.pressed = true
	control.get_viewport().push_input(event)
	event = event.duplicate()
	event.pressed = false
	control.get_viewport().push_input(event)
	await settle()
	control.pressed.disconnect(observer)
	check(pressed_count["value"] == 1, "Enter activates the real authored button exactly once")
	check(control.get_viewport().gui_get_focus_owner() == control,
		"Enter preserves the authored focus owner")


func _test_production_locks() -> void:
	production_render_target = _new_render_target()
	check(production_render_target.size == FIRST_PLAYABLE_SIZE
			and production_render_target.get_visible_rect().size == Vector2(FIRST_PLAYABLE_SIZE),
		"production capture target is an exact renderer-backed 1920x1080 SubViewport")
	var app := await _new_app(false, production_render_target)
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
		print("HEADLESS_CAPTURE_SKIPPED exact SubViewport is not written by a dummy renderer")
		return
	# Failed action or geometry checks must never create paths or replace files.
	if failures > 0 or not _assert_capture_geometry("before draw"):
		return
	await RenderingServer.frame_post_draw
	if not _assert_capture_geometry("after draw"):
		return
	var texture := production_render_target.get_texture()
	var image: Image = texture.get_image()
	check(image != null and image.get_size() == FIRST_PLAYABLE_SIZE,
		"native capture Image is raw exact 1920x1080")
	if image == null or image.get_size() != FIRST_PLAYABLE_SIZE:
		return
	if not _assert_capture_geometry("raw Image captured"):
		return
	check(image.get_size() == FIRST_PLAYABLE_SIZE,
		"raw Image remains exact 1920x1080 before path creation")
	if image.get_size() != FIRST_PLAYABLE_SIZE:
		return
	var absolute := ProjectSettings.globalize_path(capture_path)
	var directory_error := DirAccess.make_dir_recursive_absolute(absolute.get_base_dir())
	var directory_ok := directory_error == OK or directory_error == ERR_ALREADY_EXISTS
	check(directory_ok,
		"native feature-gate evidence directory is available")
	if not directory_ok or not _assert_capture_geometry("immediately before file write"):
		return
	check(image.get_size() == FIRST_PLAYABLE_SIZE,
		"raw Image remains exact 1920x1080 immediately before file write")
	if image.get_size() != FIRST_PLAYABLE_SIZE:
		return
	var save_error := image.save_png(absolute)
	check(save_error == OK,
		"native exact-1920 feature-gate evidence saves")
	if save_error != OK or not _assert_capture_geometry("immediately after file write", image):
		return
	var encoded := image.save_png_to_buffer()
	check(not encoded.is_empty(), "native exact-1920 PNG encoding buffer is non-empty")
	if encoded.is_empty():
		return
	var decoded_buffer := Image.new()
	var decode_buffer_error := decoded_buffer.load_png_from_buffer(encoded)
	check(decode_buffer_error == OK and decoded_buffer.get_size() == FIRST_PLAYABLE_SIZE,
		"native decoded PNG buffer is exact 1920x1080 after write")
	if decode_buffer_error != OK or decoded_buffer.get_size() != FIRST_PLAYABLE_SIZE:
		return
	var decoded_file := Image.new()
	var decode_file_error := decoded_file.load(absolute)
	check(decode_file_error == OK and decoded_file.get_size() == FIRST_PLAYABLE_SIZE,
		"native decoded PNG file is exact 1920x1080 immediately after write")
	if decode_file_error != OK or decoded_file.get_size() != FIRST_PLAYABLE_SIZE:
		return
	if not _assert_capture_geometry("decoded file verified", decoded_file):
		return
	check(decoded_file.get_data() == image.get_data(),
		"native PNG preserves the raw Image pixels without resampling")
	if failures == 0:
		print("EXACT_1920_PNG_VERIFIED action=production_unavailable",
			" cli=1920x1080 root=1920x1080 ui=1920x1080 target=1920x1080",
			" image=1920x1080 decoded_png=1920x1080 raw_pixels_preserved=true")


func _assert_capture_geometry(stage: String, image: Image = null) -> bool:
	var baseline_failures := failures
	check(_native_window_is_exact(),
		stage + " physical window and root remain exact 1920x1080")
	check(_has_exact_cli_resolution(),
		stage + " CLI remains explicitly --resolution 1920x1080")
	check(root.get_visible_rect().size == Vector2(FIRST_PLAYABLE_SIZE),
		stage + " orchestration root visible rect is exact 1920x1080")
	var target := production_render_target
	check(target != null and target.size == FIRST_PLAYABLE_SIZE,
		stage + " renderer target size is exact 1920x1080")
	check(target != null and target.get_visible_rect().size == Vector2(FIRST_PLAYABLE_SIZE),
		stage + " renderer target visible rect is exact 1920x1080")
	check(target != null and target.get_texture() != null
			and target.get_texture().get_size() == Vector2(FIRST_PLAYABLE_SIZE),
		stage + " renderer target texture is exact 1920x1080")
	var app := production_app_for_capture
	check(app != null and app.get_viewport() == target,
		stage + " authored UI belongs to the dedicated renderer target")
	check(app != null and app.size == Vector2(FIRST_PLAYABLE_SIZE),
		stage + " UI logical root is exact 1920x1080")
	check(app != null and app.get_rect().size == Vector2(FIRST_PLAYABLE_SIZE),
		stage + " UI visible rect is exact 1920x1080")
	check(app != null and app.get_viewport_rect().size == Vector2(FIRST_PLAYABLE_SIZE),
		stage + " UI viewport is exact 1920x1080")
	var screen := app.screen as Control if app != null else null
	check(screen != null and screen.get_rect().size == Vector2(FIRST_PLAYABLE_SIZE)
			and screen.get_viewport_rect().size == Vector2(FIRST_PLAYABLE_SIZE),
		stage + " authored screen and visible rect are exact 1920x1080")
	if image != null:
		check(image.get_size() == FIRST_PLAYABLE_SIZE,
			stage + " Image is exact 1920x1080")
	return failures == baseline_failures
