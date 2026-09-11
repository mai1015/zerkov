extends SceneTree
## Task 8.11 production UI contract. This runner is permanently restricted to
## the exact first-playable canvas and never captures or resizes another output.
## Run with: godot --headless --path . --script res://tests/presentation/ui_production_unavailable_8_11_contract.gd

const FIRST_PLAYABLE_SIZE := Vector2i(1920, 1080)

var checks: int = 0
var failures: int = 0
var capture_path: String = ""


func _initialize() -> void:
	run.call_deferred()


func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error("UI_PRODUCTION_UNAVAILABLE_8_11: " + message)


func settle(frames: int = 8) -> void:
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
	await _test_production_routes()
	await _test_injected_presentation_provider()
	await _test_input_service_composition_is_preserved()
	await _test_character_composition_is_preserved()
	await _test_explicit_fixture_preview()
	print("UI_PRODUCTION_UNAVAILABLE_8_11_RESULT checks=", checks,
		" failures=", failures, " size=1920x1080")
	quit(0 if failures == 0 else 1)


func _test_production_routes() -> void:
	var app := load("res://ui/main.tscn").instantiate() as Control
	app.name = "ProductionUnavailable811Host"
	root.add_child(app)
	await settle()
	check(app.current_route == "title", "normal production boot retains the title")
	check(app.fixture_provider_for_test() == null,
		"normal production boot creates no fixture provider")
	for route in ZRouteCatalog.ROUTES:
		check(app.fixture_provider_for_route(
			route, ZUIRouteIntent.Origin.PRODUCTION) == null,
			"production origin cannot acquire fixture provider: " + route)

	var routes: Array[String] = [
		"main_menu", "hud", "tasks", "maps", "summary_solo",
	]
	for route in routes:
		check(app.request_route(route, false),
			"production navigation admits declared route: " + route)
		await settle()
		_assert_locked_route(app, route)
		if route == "main_menu" and not capture_path.is_empty():
			await _capture_exact_frame()

	app.queue_free()
	await settle(3)


func _capture_exact_frame() -> void:
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	var exact_size := image.get_size() == FIRST_PLAYABLE_SIZE
	check(exact_size,
		"native evidence image is exact 1920x1080")
	if not exact_size:
		capture_path = ""
		quit(2)
		return
	var absolute := ProjectSettings.globalize_path(capture_path)
	var directory_error := DirAccess.make_dir_recursive_absolute(
		absolute.get_base_dir())
	check(directory_error == OK or directory_error == ERR_ALREADY_EXISTS,
		"native evidence directory is available")
	check(image.save_png(absolute) == OK,
		"native exact-1920 unavailable-state evidence saves")


func _assert_locked_route(app: Control, route: String) -> void:
	var screen := app.screen as ZScreen
	var overlay := screen.get_node_or_null("ProductionUnavailableState") as Control
	var card := overlay.get_node_or_null("UnavailableCard") as Control \
			if overlay != null else null
	var detail := card.get_node_or_null("LockedStateDetail") as Label \
			if card != null else null
	check(app.current_route == route and screen != null,
		"production route commits through CommonUI: " + route)
	check(screen != null and not screen.accepts_input()
			and bool(screen.get("_production_state_locked")),
		"unbound production route is inert: " + route)
	check(overlay != null and overlay.is_visible_in_tree()
			and overlay.size.is_equal_approx(Vector2(FIRST_PLAYABLE_SIZE)),
		"unavailable truth fully covers exact canvas: " + route)
	check(card != null and detail != null
			and detail.autowrap_mode == TextServer.AUTOWRAP_WORD_SMART
			and detail.get_line_count() >= 2
			and detail.position.x >= 0.0 and detail.position.y >= 0.0
			and detail.position.x + detail.size.x <= card.size.x
			and detail.position.y + detail.size.y <= card.size.y,
		"unavailable explanation wraps inside its authored panel: " + route)
	check(screen.app.fixture_generation() == 0
			and not screen.app.has_fixture_provider()
			and screen.app.fixture_get("forged", "FORGED") == null
			and not screen.app.fixture_set("forged", true),
		"production context cannot read or write fixture fallbacks: " + route)
	var view := screen.app.presentation_view()
	check(view != null and view.is_initialized() and not view.is_ready()
			and view.sync_state() == ZReadOnlyView.SyncState.UNBOUND,
		"route publishes initialized typed unavailable truth: " + route)
	check(_view_matches_route(view, route),
		"route receives its declared typed view: " + route)
	var visible_text := _visible_text(screen)
	check(visible_text.contains("PRODUCTION DATA UNAVAILABLE")
			and visible_text.contains("NO AUTHORITATIVE PRESENTATION SERVICE"),
		"locked state explains missing authority in text: " + route)
	check(not visible_text.contains("OAK'S BUNKER")
			and not visible_text.contains("AKM")
			and not visible_text.contains("32:14")
			and not visible_text.contains("SUPPLY RUN"),
		"locked production route exposes no sample profile, raid, or task: " + route)


func _view_matches_route(view: ZReadOnlyView, route: String) -> bool:
	match route:
		"main_menu":
			return view is BunkerView
		"hud":
			return view is RaidView
		"tasks":
			return view is TaskView
		"maps":
			return view is MapView
		"summary_solo":
			return view is SummaryView
	return false


func _visible_text(owner: Node) -> String:
	var values: Array[String] = []
	for node in owner.find_children("*", "Label", true, false):
		var label := node as Label
		if label != null and label.is_visible_in_tree():
			values.append(label.text.to_upper())
	return "\n".join(PackedStringArray(values))


func _test_injected_presentation_provider() -> void:
	var provider := ZUIPresentationProvider.new()
	provider.name = "InjectedPresentation811Provider"
	check(provider.start_unavailable(41, &"injected_services_missing"),
		"external composition starts its typed provider before injection")
	root.add_child(provider)
	var app := load("res://ui/main.tscn").instantiate() as Control
	app.name = "InjectedPresentation811Host"
	check(app.inject_presentation_provider(provider),
		"production host accepts one pre-tree typed provider")
	root.add_child(app)
	await settle()
	check(not app.inject_presentation_provider(provider),
		"provider injection closes when host composition enters the tree")
	check(app.request_route("tasks", false),
		"injected-provider route is admitted")
	await settle()
	var stale_screen := app.screen as ZScreen
	check(stale_screen.app.presentation_generation() == 41
			and stale_screen.app.task_view().diagnostic()
				== &"injected_services_missing_tasks"
			and not stale_screen.app.has_fixture_provider(),
		"route context captures injected typed truth without a fixture")
	check(provider.replace_unavailable(42, &"replacement_services_missing"),
		"external composition advances its generation")
	await settle()
	check(stale_screen.app.presentation_diagnostic()
			== &"ui_presentation_provider_stale_generation"
			and stale_screen.get_node_or_null("ProductionUnavailableState") != null,
		"retained screen fails closed after external generation replacement")
	check(app.request_route("maps", false),
		"new route acquires the replacement generation")
	await settle()
	var current_screen := app.screen as ZScreen
	check(current_screen.app.presentation_generation() == 42
			and current_screen.app.map_view().diagnostic()
				== &"replacement_services_missing_map",
		"replacement route observes only current typed truth")
	app.queue_free()
	await settle(3)
	check(provider.is_active(),
		"host teardown does not tear down its externally owned provider")
	check(provider.teardown(42), "external owner tears down its provider")
	provider.queue_free()
	await settle(2)


func _test_input_service_composition_is_preserved() -> void:
	var app := load("res://ui/main.tscn").instantiate() as Control
	app.name = "ProductionControls811Host"
	root.add_child(app)
	await settle()
	check(app.request_route("controls", false),
		"production Controls route remains admitted")
	await settle()
	var screen := app.screen as ZScreen
	var service: ZerkovInputService = screen.app.input_service() \
			if screen != null else null
	var control_groups: Variant = screen.get("CONTROL_GROUPS") \
			if screen != null else null
	check(screen != null and app.current_route == "controls"
			and screen.get_node_or_null("ProductionUnavailableState") == null,
		"accepted Task 8.10 Controls composition remains active")
	check(service != null and service.is_configured(),
		"Controls receives the game-owned typed input facade")
	check(control_groups is Array and (control_groups as Array).size() == 4
			and screen.has_node("BindingsPane/BindingsBody/MapPrimary"),
		"authored binding rows remain available without a utility fixture import")
	check(screen.app.fixture_generation() == 0
			and not screen.app.has_fixture_provider(),
		"live Controls creates no prototype state provider")
	app.queue_free()
	await settle(3)


func _test_character_composition_is_preserved() -> void:
	var app := load("res://ui/main.tscn").instantiate() as Control
	app.name = "ProductionCharacter811Host"
	root.add_child(app)
	await settle()
	check(app.request_route("inventory", false),
		"production Character route remains admitted")
	await settle()
	var screen := app.screen as ZScreen
	var runtime := screen.app.character_runtime()
	var stash_grid := screen._grid_for_source("stash") as Control
	check(screen.get_node_or_null("ProductionUnavailableState") == null,
		"generic gate does not replace accepted Task 8.6 Character composition")
	check(runtime != null and not runtime.is_configured()
			and runtime.inventory_view(&"profile").diagnostic()
				== CharacterPresentationComposition.REASON_AUTHORITY_NOT_INJECTED,
		"missing Character service publishes Task 8.6 typed unavailable truth")
	check(screen.get_node_or_null("InventoryContent") != null
			and stash_grid != null and int(stash_grid.get("cell_size")) == 74,
		"existing designed inventory workspace and 74px grid are preserved")
	check(screen._items_for("stash").is_empty()
			and screen.app.fixture_generation() == 0
			and not screen.app.has_fixture_provider(),
		"uninjected production Character screen synthesizes no sample inventory")
	app.queue_free()
	await settle(3)


func _test_explicit_fixture_preview() -> void:
	var app := load("res://ui/main.tscn").instantiate() as Control
	app.name = "ExplicitFixture811Host"
	app.prototype_fixture_mode = true
	root.add_child(app)
	await settle()
	check(app.request_route("main_menu", false),
		"explicit prototype session admits authored preview route")
	await settle()
	var screen := app.screen as ZScreen
	var state: Dictionary = app.fixture_state_for_test()
	check(screen.get_node_or_null("ProductionUnavailableState") == null
			and screen.app.has_fixture_provider(),
		"explicit prototype session receives the developer provider")
	check((state.get("frontflow_worlds", []) as Array).size() == 3,
		"authored sample data exists behind the explicit provider")
	check(screen.has_node("MenuContinue") and screen.get_node("MenuContinue").is_visible_in_tree(),
		"explicit preview retains the existing authored main-menu UI")
	app.queue_free()
	await settle(3)
