extends SceneTree
## Run with: godot --headless --path . --script res://tests/common_ui_integration_smoke.gd

var failures: int = 0
var checks: int = 0
var app: Control


func _initialize() -> void:
	call_deferred("run")


func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("COMMON_UI_INTEGRATION: " + message)


func settle() -> void:
	for _frame in range(6):
		await process_frame


func run() -> void:
	root.size = Vector2i(1280, 720)

	var runtime := get_root().get_node_or_null("CommonUI")
	check(CommonUIBoot.is_native_runtime_available(), "native CommonUI classes are registered")
	check(runtime is CommonUIRuntime, "CommonUI autoload is a native CommonUIRuntime")
	if runtime is CommonUIRuntime:
		check(runtime.has_method("get_api_version"), "native runtime exposes get_api_version()")
		if runtime.has_method("get_api_version"):
			check(str(runtime.get_api_version()) == "0.1", "native runtime API version is 0.1")

	app = load("res://ui/main.tscn").instantiate() as Control
	check(app != null, "main scene instantiates")
	if app == null:
		print("COMMON_UI_INTEGRATION_RESULT checks=", checks, " failures=", failures)
		quit(1)
		return
	root.add_child(app)
	app.qa_mode = true
	await settle()

	var screen_root := app.get_node_or_null("CommonUIScreenRoot")
	check(screen_root is CommonUIScreenRoot, "main scene contains CommonUIScreenRoot")
	if screen_root is CommonUIScreenRoot:
		var standard_layers: Array[StringName] = [
			CommonUIDefaults.LAYER_HUD,
			CommonUIDefaults.LAYER_MENU,
			CommonUIDefaults.LAYER_MODAL,
			CommonUIDefaults.LAYER_POPUP,
		]
		for layer_id in standard_layers:
			check(screen_root.layer(layer_id) is CommonUILayer,
				"standard layer exists: " + str(layer_id))

	var menu_layer := screen_root.menu_layer() as CommonUILayer if screen_root is CommonUIScreenRoot else null
	check(menu_layer != null, "menu layer is available")
	check(app.current_route == "title", "initial route is title")
	check(app.screen is CommonActivatableScreen, "current route screen is CommonActivatableScreen")
	if menu_layer != null:
		check(menu_layer.get_top_screen() == app.screen, "menu layer top is current route screen")
		check(menu_layer.get_top_screen() != null and menu_layer.get_top_screen().is_routing_active(),
			"menu layer top screen is routing-active")
	if runtime is CommonUIRuntime:
		var active_actions: Array = runtime.get_active_actions()
		var has_screen_back := false
		for action in active_actions:
			if action.get("action") == CommonUIDefaults.BACK and action.get("screen") == app.screen:
				has_screen_back = true
				break
		check(has_screen_back, "current screen registers CommonUI back routing")

	# Rapid requests are committed in order; explicit resets leave the last
	# destination as the only mounted page.
	app.navigate("main_menu", false)
	app.navigate("saves", false)
	app.navigate("settings", false)
	await settle()
	check(app.current_route == "settings", "rapid navigation keeps the latest route")
	check(app.screen is CommonActivatableScreen, "latest route screen remains activatable")
	if menu_layer != null:
		check(menu_layer.get_depth() == 1, "rapid navigation leaves one menu screen")
		check(menu_layer.get_top_screen() == app.screen, "latest route owns the menu top")
		check(menu_layer.get_top_screen() != null and menu_layer.get_top_screen().is_routing_active(),
			"latest route remains routing-active")

	var stale_screen := app.screen as CommonActivatableScreen
	app.navigate("main_menu", false)
	await settle()
	check(app.current_route == "main_menu", "replacement reaches requested route")
	check(app.screen != stale_screen, "replacement installs a fresh screen instance")
	check(not is_instance_valid(stale_screen), "replacement frees stale screen")
	if menu_layer != null:
		check(menu_layer.get_depth() == 1, "replacement keeps one menu screen")
		check(menu_layer.get_top_screen() == app.screen, "replacement updates menu top")

	var menu_cards := ["MenuContinue", "MenuPlay", "MenuJoinFriend", "MenuSettings", "MenuExtras", "MenuQuit"]
	for card_path in menu_cards:
		var card: Node = app.screen.get_node_or_null(card_path)
		check(card is ZMenuActionCard, "main menu uses MenuActionCard: " + card_path)
		check(card != null and card.get_node_or_null("Hit") is CommonButton,
			"main menu card uses CommonButton: " + card_path)

	app.navigate("saves", false)
	await settle()
	for index in range(1, 9):
		var row: Node = app.screen.get_node_or_null("WorldList/Content/WorldRow%d" % index)
		check(row != null and row.scene_file_path == "res://ui/screens/frontflow/components/world_row.tscn",
			"saved world uses WorldRow component: " + str(index))
		check(row != null and row.get_node_or_null("Hit") is CommonButton,
			"saved world row uses CommonButton: " + str(index))
	var new_world: Node = app.screen.get_node_or_null("WorldList/Content/NewWorldRow")
	check(new_world != null and new_world.scene_file_path == "res://ui/screens/frontflow/components/new_world_row.tscn",
		"new-world action uses NewWorldRow component")
	check(new_world != null and new_world.get_node_or_null("Hit") is CommonButton,
		"new-world action uses CommonButton")

	for route in ["inventory", "health", "stats", "maps", "tasks", "settings", "controls"]:
		app.navigate(route, false)
		await settle()
		check(app.screen.get_node_or_null("NavigationChrome") is ZNavigationChrome,
			"route uses NavigationChrome: " + route)

	for route in ["bunker", "build_mode", "crafting", "session"]:
		app.navigate(route, false)
		await settle()
		var top_chrome: Node = app.screen.get_node_or_null("TopChrome")
		check(top_chrome is ZTopChrome, "route uses TopChrome: " + route)
		check(top_chrome != null and top_chrome.get_node_or_null("MenuButton") is CommonButton,
			"top chrome menu action uses CommonButton: " + route)
	check(app.screen.get_node_or_null("TopChrome/WorldBadge/WorldBack") is CommonButton,
		"top chrome world-back action uses CommonButton")

	app.screen.app.confirm("Component check", "CommonUI modal layer", func() -> void: pass)
	await settle()
	check(app.modal is ZerkovDialog, "confirm flow uses ZerkovDialog")
	check(screen_root.modal_layer().get_top_screen() == app.modal,
		"confirm flow mounts on CommonUI modal layer")
	check(app.modal.get_node_or_null("DialogPanel/Margin/Content/Actions/ConfirmButton") is CommonButton,
		"dialog confirm action uses CommonButton")
	app._close_overlay(app.modal)
	await settle()
	check(screen_root.modal_layer().get_depth() == 0, "dialog pop clears CommonUI modal layer")

	print("COMMON_UI_INTEGRATION_RESULT checks=", checks, " failures=", failures)
	app.queue_free()
	await settle()
	quit(0 if failures == 0 else 1)
