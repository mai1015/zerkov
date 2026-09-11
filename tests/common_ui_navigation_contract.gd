extends SceneTree
## Focused task 8.2 contract for production CommonUI navigation ownership.
## Run with: godot --headless --path . --audio-driver Dummy \
##   --script res://tests/common_ui_navigation_contract.gd

var app: Control
var checks := 0
var failures := 0
var rejected: Array[Dictionary] = []


func _initialize() -> void:
	run.call_deferred()


func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error("COMMON_UI_NAVIGATION: " + message)


func settle() -> void:
	for _frame in range(10):
		await process_frame


func key(code: Key) -> void:
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.keycode = code
		event.physical_keycode = code
		event.pressed = pressed
		root.push_input(event)
	await settle()


func joypad_button(code: JoyButton) -> void:
	for pressed in [true, false]:
		var event := InputEventJoypadButton.new()
		event.button_index = code
		event.pressed = pressed
		event.pressure = 1.0 if pressed else 0.0
		root.push_input(event)
	await settle()


func focus_is_inside(owner: Node) -> bool:
	var focused := root.gui_get_focus_owner()
	return focused != null and (focused == owner or owner.is_ancestor_of(focused))


func context_is(view: CommonActivatableScreen, expected: StringName) -> bool:
	if view == null:
		return false
	var handle := view.get_context_handle()
	return handle != null and handle.is_active() and handle.get_context() == expected


func composition_signature() -> Array:
	var signature: Array = [app.current_route]
	for layer_id in [
		CommonUIDefaults.LAYER_HUD,
		CommonUIDefaults.LAYER_MENU,
		CommonUIDefaults.LAYER_MODAL,
		CommonUIDefaults.LAYER_POPUP,
	]:
		var layer := app.common_ui_root.layer(layer_id) as CommonUILayer
		var top := layer.get_top_screen() if layer != null else null
		signature.append([
			String(layer_id),
			layer.get_depth() if layer != null else -1,
			top.get_instance_id() if top != null else 0,
		])
	return signature


func reject_record(route: String, reason: String) -> void:
	rejected.append({"route": route, "reason": reason})


func run() -> void:
	# This is the resolution from the reported advertised-Continue focus defect.
	root.size = Vector2i(1600, 900)
	app = load("res://ui/main.tscn").instantiate() as Control
	app.name = "CommonUINavigationHost"
	root.add_child(app)
	await settle()
	app.navigator.rejected.connect(reject_record)

	var runtime := root.get_node_or_null("CommonUI") as CommonUIRuntime
	var screen_root := app.common_ui_root as CommonUIScreenRoot
	check(runtime != null, "native CommonUI runtime is available")
	check(screen_root != null, "main scene owns one CommonUIScreenRoot")
	check(ZRouteCatalog.ROUTES.size() == 28, "all 28 stable route IDs remain registered")
	for layer_id in [
		CommonUIDefaults.LAYER_HUD,
		CommonUIDefaults.LAYER_MENU,
		CommonUIDefaults.LAYER_MODAL,
		CommonUIDefaults.LAYER_POPUP,
	]:
		check(screen_root.layer(layer_id) is CommonUILayer,
			"standard CommonUI layer exists: " + str(layer_id))
	check(app.current_route == "title", "production boot commits the title route")
	check(screen_root.menu_layer().get_top_screen() == app.screen,
		"title is owned by the CommonUI menu layer")
	check(context_is(app.screen, &"screen/title"),
		"title owns its route-scoped CommonUI context")
	check(app.screen.app.route_payload.type_id == ZUIRoutePayload.EMPTY_TYPE \
			and app.screen.app.route_payload.is_empty(),
		"admitted route exposes its typed empty payload to the screen context")
	var title_has_confirm := false
	for action in runtime.get_active_actions():
		if action.get("action") == CommonUIDefaults.CONFIRM and action.get("screen") == app.screen:
			title_has_confirm = true
			break
	check(title_has_confirm, "title registers CommonUI Confirm while active")

	# The synthetic south/A path failed before 8.2 because Main only listened for
	# keyboard and pointer events. It now reaches the same screen-scoped intent.
	await joypad_button(JOY_BUTTON_A)
	check(app.current_route == "main_menu", "physical controller A leaves title")
	check(screen_root.menu_layer().get_top_screen() == app.screen,
		"controller title activation commits through the menu layer")
	var continue_button := app.screen.get_node_or_null("MenuContinue/Hit") as Control
	var switch_account := app.screen.get_node_or_null("Header/SwitchAccount") as Control
	check(root.gui_get_focus_owner() == continue_button,
		"main-menu activation focuses the advertised Continue action")
	check(root.gui_get_focus_owner() != switch_account,
		"main-menu activation never falls back to Switch Account")

	# Exercise the keyboard path independently, then activate the focused CTA.
	check(app.request_route("title", false), "production reset to title is admitted")
	await settle()
	await key(KEY_ENTER)
	check(app.current_route == "main_menu", "physical Enter leaves title through CommonUI")
	continue_button = app.screen.get_node_or_null("MenuContinue/Hit") as Control
	check(root.gui_get_focus_owner() == continue_button,
		"keyboard title activation also focuses Continue")
	await key(KEY_ENTER)
	check(app.current_route == "session", "second advertised Enter activates Continue")
	check(not str(app.toast_label.text).contains("ACCOUNT SWITCHING"),
		"advertised Continue path does not activate the account-switch toast")

	# HUD/menu composition is retained and Back is routed only by the active
	# CommonUI context. Covered HUD gameplay shortcuts remain unavailable.
	check(app.request_route("hud", false), "production HUD intent is admitted")
	await settle()
	var hud := app.screen as CommonActivatableScreen
	var hud_handle := hud.get_context_handle()
	check(screen_root.hud_layer().get_top_screen() == hud, "HUD uses the HUD layer")
	check(screen_root.menu_layer().get_depth() == 0, "HUD does not occupy menu history")
	check(context_is(hud, &"screen/hud"), "HUD route context is active")
	app.state.raid_ammo = 17
	await key(KEY_ESCAPE)
	var pause := app.screen as CommonActivatableScreen
	check(app.current_route == "pause", "physical Back opens pause through CommonUI")
	check(screen_root.hud_layer().get_top_screen() == hud, "pause retains the HUD instance")
	check(screen_root.menu_layer().get_top_screen() == pause, "pause uses the menu layer")
	check(hud_handle.is_suspended(), "pause suspends the retained HUD context")
	check(context_is(pause, &"screen/pause"), "pause route context is active")
	check(root.gui_get_focus_owner() == pause.get_node_or_null("ActionsPanel/ResumeRow/Hit"),
		"pause activation focuses Resume")
	await key(KEY_R)
	check(not bool(app.state.get("raid_reloading", false)),
		"covered HUD cannot receive physical reload input")
	await key(KEY_ESCAPE)
	check(app.screen == hud and app.current_route == "hud",
		"pause Back exposes the same CommonUI-owned HUD")
	check(not hud_handle.is_suspended(), "pause Back resumes the HUD context")

	check(app.request_route("inventory"), "production workspace intent is admitted")
	await settle()
	var inventory := app.screen as CommonActivatableScreen
	var inventory_handle := inventory.get_context_handle()
	var workspace_focus := inventory.get_node_or_null("NavigationChrome/Character") as Control
	check(screen_root.menu_layer().get_top_screen() == inventory,
		"workspace route is owned by the menu layer over HUD")
	check(hud_handle.is_suspended(), "workspace suspends HUD routing")
	check(workspace_focus != null, "workspace exposes a deterministic focus target")
	if workspace_focus != null:
		workspace_focus.grab_focus()
	await settle()

	# Invalid request types, routes, payload types, payload values, and stale
	# origins are rejected synchronously. A live modal and every layer depth/top
	# remain unchanged; only non-modal diagnostic toast text may change.
	app.confirm("Navigation contract", "Invalid intents must not alter this modal.", func() -> void: pass)
	await settle()
	var modal := app.modal as CommonActivatableScreen
	check(screen_root.modal_layer().get_top_screen() == modal, "dialog uses the modal layer")
	check(context_is(modal, &"modal/confirm"), "dialog has a stable modal context")
	check(inventory_handle.is_suspended(), "modal suspends the workspace context")
	check(focus_is_inside(modal), "modal traps focus inside its CommonUI screen")
	var before_invalid := composition_signature()
	var rejection_start := rejected.size()
	check(not app.submit_navigation({"route_id": "maps"}), "untyped route request is rejected")
	check(not app.submit_navigation(ZUIRouteIntent.open_route(
		&"not-a-route", &"inventory", ZUIRouteIntent.Origin.PRODUCTION)),
		"unknown typed route is rejected")
	check(not app.submit_navigation(ZUIRouteIntent.open_route(
		&"maps", &"inventory", ZUIRouteIntent.Origin.PRODUCTION,
		ZUIRouteIntent.StackMode.AUTO, ZUIRoutePayload.new(&"unknown", {}))),
		"unknown typed payload is rejected")
	check(not app.submit_navigation(ZUIRouteIntent.open_route(
		&"maps", &"inventory", ZUIRouteIntent.Origin.PRODUCTION,
		ZUIRouteIntent.StackMode.AUTO, ZUIRoutePayload.new(ZUIRoutePayload.EMPTY_TYPE, {"extra": true}))),
		"unexpected payload values are rejected")
	check(not app.submit_navigation(ZUIRouteIntent.open_route(
		&"maps", &"main_menu", ZUIRouteIntent.Origin.PRODUCTION)),
		"stale production origin is rejected")
	await settle()
	check(rejected.size() == rejection_start + 5, "each invalid intent reports one rejection")
	for index in range(rejection_start, rejected.size()):
		check(not str(rejected[index].reason).is_empty(),
			"rejection includes a safe diagnostic: " + str(index - rejection_start))
	check(composition_signature() == before_invalid,
		"invalid routes and payloads leave every CommonUI stack intact")
	check(app.modal == modal and focus_is_inside(modal),
		"invalid intents preserve modal ownership and focus containment")
	await key(KEY_ESCAPE)
	check(app.modal == null and screen_root.modal_layer().get_depth() == 0,
		"physical Back dismisses only the modal layer")
	check(app.screen == inventory and app.current_route == "inventory",
		"modal Back preserves the workspace route")
	check(not inventory_handle.is_suspended(), "modal Back resumes workspace routing")
	check(root.gui_get_focus_owner() == workspace_focus, "modal Back restores prior workspace focus")

	# F1 is the sole developer compatibility path. Rejected production or
	# malformed catalog selections keep the popup and current composition alive.
	await key(KEY_F1)
	var picker := app.picker as CommonActivatableScreen
	check(screen_root.popup_layer().get_top_screen() == picker, "F1 catalog uses the popup layer")
	check(context_is(picker, &"developer/catalog"), "F1 catalog has a stable developer context")
	check(inventory_handle.is_suspended(), "developer popup suspends workspace routing")
	check(focus_is_inside(picker), "developer popup traps focus")
	check(picker.get_node("Panel/ScreenCatalog/Entries").get_child_count() == 28,
		"F1 catalog retains all 28 review routes")
	var before_developer_reject := composition_signature()
	check(not app.request_route("showcase"), "production cannot open a developer study route")
	await settle()
	check(composition_signature() == before_developer_reject and app.picker == picker,
		"rejected production study route preserves the popup")
	app.picker.selected.emit("not-a-route")
	await settle()
	check(composition_signature() == before_developer_reject and app.picker == picker,
		"unknown developer selection preserves popup and focus stack")
	app.picker.selected.emit("showcase")
	await settle()
	check(app.picker == null and screen_root.popup_layer().get_depth() == 0,
		"admitted F1 selection closes the popup layer")
	check(app.current_route == "showcase" and screen_root.menu_layer().get_top_screen() == app.screen,
		"F1 selection commits the developer route through CommonUI")
	check(bool(app.screen.app.developer_context), "developer route keeps explicit catalog provenance")
	await key(KEY_ESCAPE)
	check(app.screen == inventory and app.current_route == "inventory",
		"developer route Back restores the retained workspace")
	check(context_is(inventory, &"screen/inventory"),
		"restored workspace owns a fresh active context")

	# Popup dismissal also uses CommonUI Back and restores the captured focus.
	workspace_focus.grab_focus()
	await settle()
	await key(KEY_F1)
	picker = app.picker as CommonActivatableScreen
	check(picker != null and focus_is_inside(picker), "reopened developer popup owns focus")
	await key(KEY_ESCAPE)
	check(app.picker == null and app.screen == inventory,
		"physical Back dismisses popup without navigating")
	check(root.gui_get_focus_owner() == workspace_focus, "popup Back restores prior workspace focus")
	await key(KEY_ESCAPE)
	check(app.screen == hud and app.current_route == "hud",
		"workspace Back returns to the retained HUD; route=%s menu_depth=%s hud_same=%s" % [
			app.current_route,
			screen_root.menu_layer().get_depth(),
			app.screen == hud,
		])
	check(not hud_handle.is_suspended() and context_is(hud, &"screen/hud"),
		"workspace Back restores HUD lifecycle and input context; suspended=%s context=%s" % [
			hud_handle.is_suspended(),
			str(hud_handle.get_context()),
		])
	check(app.state.raid_ammo == 17, "layer transitions preserve HUD presentation state")

	print("COMMON_UI_NAVIGATION_RESULT checks=", checks,
		" failures=", failures, " routes=", ZRouteCatalog.ROUTES.size())
	app.queue_free()
	await settle()
	quit(0 if failures == 0 else 1)
