extends SceneTree
## Exact 1920x1080 regressions from the independent task 8.2 review.
## Run with: godot --headless --path . --audio-driver Dummy \
##   --script res://tests/common_ui_navigation_1080_regression.gd

var app: Control
var checks := 0
var failures := 0
var rejected: Array[Dictionary] = []
var maximum_menu_depth := 0


func _initialize() -> void:
	run.call_deferred()


func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error("COMMON_UI_NAVIGATION_1080: " + message)


func settle() -> void:
	for _frame in range(10):
		await process_frame
	if is_instance_valid(app) and app.common_ui_root != null:
		maximum_menu_depth = maxi(maximum_menu_depth,
			app.common_ui_root.menu_layer().get_depth())


func key(code: Key) -> void:
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.keycode = code
		event.physical_keycode = code
		event.pressed = pressed
		root.push_input(event)
	await settle()


func joypad_button(code: JoyButton) -> void:
	await joypad_taps(code, 1)


func joypad_taps(code: JoyButton, count: int) -> void:
	push_joypad_taps(code, count)
	await settle()


func push_joypad_taps(code: JoyButton, count: int) -> void:
	for _tap in range(count):
		for pressed in [true, false]:
			var event := InputEventJoypadButton.new()
			event.button_index = code
			event.pressed = pressed
			event.pressure = 1.0 if pressed else 0.0
			root.push_input(event)


func focus_is_inside(owner: Node) -> bool:
	var focused := root.gui_get_focus_owner()
	return focused != null and (focused == owner or owner.is_ancestor_of(focused))


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


func _record_rejection(route: String, reason: String) -> void:
	rejected.append({"route": route, "reason": reason})


func run() -> void:
	root.size = Vector2i(1920, 1080)
	app = load("res://ui/main.tscn").instantiate() as Control
	app.name = "CommonUINavigation1080Host"
	root.add_child(app)
	await settle()
	app.navigator.rejected.connect(_record_rejection)

	var screen_root := app.common_ui_root as CommonUIScreenRoot
	check(root.get_visible_rect().size == Vector2(1920, 1080),
		"regression runs at the exact independent-review canvas")

	# Exact retained-caller repro: title -> main menu reset -> Saves push ->
	# Session push. A late call on the retained inactive Saves instance must not
	# acquire a modal or commit its hidden callback.
	check(app.request_route("main_menu", false), "main-menu reset is admitted")
	await settle()
	check(app.current_route == "main_menu" and screen_root.menu_layer().get_depth() == 1,
		"main-menu reset establishes one menu root")
	check(app.request_route("saves"), "Saves push is admitted")
	await settle()
	var retained_saves := app.screen as ZScreen
	var retained_saves_context := retained_saves.app
	var retained_saves_capability: RefCounted = retained_saves_context._feedback_capability
	var world_count_before := int(app.state.get("frontflow_worlds", []).size())
	check(world_count_before == 3, "retained-caller fixture begins with three worlds")
	check(app.request_route("session"), "Session push over Saves is admitted")
	await settle()
	var owning_session := app.screen as ZScreen
	check(app.current_route == "session" and screen_root.menu_layer().get_depth() == 3,
		"Session retains inactive Saves beneath the active screen")
	retained_saves.call("_delete_world")
	check(app.modal == null and screen_root.modal_layer().get_depth() == 0,
		"inactive retained Saves cannot acquire a modal")
	await settle()
	retained_saves.call("_rename_world")
	check(app.modal == null and screen_root.modal_layer().get_depth() == 0,
		"inactive retained Saves cannot acquire a prompt")
	check(app.current_route == "session" \
			and int(app.state.get("frontflow_worlds", []).size()) == world_count_before,
		"inactive Saves cannot commit its hidden delete callback")
	check("does not own" in app.toast_label.text.to_lower(),
		"inactive request fails with an ownership diagnostic")

	var forged_context := ZUIContext.new(app, "session", app.fixtures)
	var forged_callback_count := {"value": 0}
	check(not app.request_confirm(
		forged_context,
		RefCounted.new(),
		"Forged context",
		"Must not open.",
		func() -> void: forged_callback_count.value += 1
	), "an unbound context and arbitrary capability cannot forge modal ownership")
	check(app.modal == null and forged_callback_count.value == 0,
		"forged ownership leaves modal state and callbacks untouched")

	var stale_commit_count := {"value": 0}
	check(owning_session.app.confirm(
		"Stale commit",
		"Captured ownership must be revalidated.",
		func() -> void: stale_commit_count.value += 1
	), "current owner can open the stale-commit guard fixture")
	await settle()
	app.modal.set_meta(ZUIFeedback.CALLBACK_CONTEXT_META, retained_saves_context)
	app.modal.set_meta(ZUIFeedback.CALLBACK_CAPABILITY_META, retained_saves_capability)
	app.modal.confirmed.emit()
	await settle()
	check(stale_commit_count.value == 0 and app.modal == null \
			and app.screen == owning_session,
		"replayed inactive ownership cannot commit a captured callback")
	check("expired" in app.toast_label.text.to_lower(),
		"stale callback commit fails safely with an expiry diagnostic")

	var current_callback_count := {"value": 0}
	check(owning_session.app.confirm(
		"Current owner",
		"Must commit once.",
		func() -> void: current_callback_count.value += 1
	), "the current routing-active context can acquire a modal")
	await settle()
	check(app.modal.get_meta(ZUIFeedback.CALLBACK_CONTEXT_META, null) == owning_session.app,
		"dialog captures the exact requesting context rather than host.screen ID")
	check(app.modal.get_meta(ZUIFeedback.CALLBACK_CAPABILITY_META, null) \
			== owning_session.app._feedback_capability,
		"dialog captures the exact requesting context capability")
	app.modal.confirmed.emit()
	await settle()
	check(current_callback_count.value == 1 and app.modal == null,
		"current owner callback commits once after CommonUI modal closure: count=%d toast=%s active=%s" % [
			current_callback_count.value,
			app.toast_label.text,
			str(owning_session.is_routing_active()),
		])

	check(app.request_route("main_menu", false), "teardown reset is admitted")
	await settle()
	check(not app.request_confirm(
		retained_saves_context,
		retained_saves_capability,
		"Replayed context",
		"Must not open after teardown.",
		func() -> void: forged_callback_count.value += 10
	), "a captured context capability cannot replay after owner teardown")
	check(app.modal == null \
			and int(app.state.get("frontflow_worlds", []).size()) == world_count_before \
			and forged_callback_count.value == 0,
		"teardown replay cannot open or commit")

	# HUD -> Pause -> Session used to push another Pause on Back forever.
	# Measure that chain independently of the deliberate three-screen retained
	# caller fixture above.
	maximum_menu_depth = 0
	check(app.request_route("hud", false), "HUD reset is admitted")
	await settle()
	var hud := app.screen as CommonActivatableScreen
	var hud_handle := hud.get_context_handle()
	await joypad_button(JOY_BUTTON_B)
	var pause := app.screen as CommonActivatableScreen
	check(app.current_route == "pause", "controller B opens Pause from HUD")
	check(screen_root.menu_layer().get_depth() == 1 \
			and screen_root.hud_layer().get_depth() == 1,
		"Pause retains one HUD beneath one menu")
	app.screen.call("_open_session")
	await settle()
	var session := app.screen as CommonActivatableScreen
	check(app.current_route == "session", "Pause Session action opens bunker session")
	check(screen_root.menu_layer().get_depth() == 2,
		"Session is pushed once over retained Pause")
	check(session.app.return_route == "pause", "Session records Pause as its CommonUI return target")
	await joypad_button(JOY_BUTTON_B)
	check(app.screen == pause and app.current_route == "pause",
		"Session Back reveals the retained Pause instead of pushing a duplicate")
	check(screen_root.menu_layer().get_depth() == 1,
		"Session Back reduces menu depth from two to one")
	check(root.gui_get_focus_owner() == pause.get_node_or_null("ActionsPanel/ResumeRow/Hit"),
		"revealed Pause restores Resume focus")
	await joypad_button(JOY_BUTTON_B)
	check(app.screen == hud and app.current_route == "hud",
		"Pause Resume/Back reaches the original HUD")
	check(screen_root.menu_layer().get_depth() == 0 \
			and screen_root.hud_layer().get_depth() == 1,
		"completed Back chain leaves no menu trap")
	check(not hud_handle.is_suspended(), "completed Back chain resumes the HUD context")

	# A modal claims ownership synchronously. Duplicate opens are idempotent and
	# neither production nor review routes can replace its callback owner.
	check(app.request_route("summary_solo", false), "summary reset is admitted")
	await settle()
	var summary := app.screen as CommonActivatableScreen
	var summary_focus := summary.get_node_or_null("BackBunker") as Control
	summary_focus.grab_focus()
	summary.call("_on_reinsure")
	var first_modal := app.modal as CommonActivatableScreen
	var duplicate_callback_count := 0
	check(first_modal != null, "summary action claims one modal synchronously")
	check(not summary.app.confirm("Duplicate", "Must be idempotent.", func() -> void:
		duplicate_callback_count += 1), "same-frame duplicate modal is rejected")
	check(not app.toggle_picker(), "F1 popup cannot open over a claimed modal")
	await settle()
	var modal_signature := composition_signature()
	var modal_rejections := rejected.size()
	check(not app.request_route("main_menu", false),
		"valid production route is blocked while modal is active")
	check(not app.navigate_for_review("main_menu", false),
		"review facade cannot bypass a production session or active modal")
	await settle()
	check(rejected.size() == modal_rejections + 2,
		"blocked production/review routes report one diagnostic each")
	check(screen_root.modal_layer().get_depth() == 1 \
			and screen_root.modal_layer().get_top_screen() == first_modal \
			and app.modal == first_modal,
		"duplicate confirms retain one tracked CommonUI modal")
	check(composition_signature() == modal_signature,
		"blocked valid routes do not replace the modal callback owner")
	check(focus_is_inside(first_modal), "modal keeps focus contained")
	first_modal.confirmed.emit()
	await settle()
	check(app.modal == null and screen_root.modal_layer().get_depth() == 0,
		"confirm completion clears modal reference and layer together")
	check(app.screen == summary and app.current_route == "summary_solo",
		"summary callback owner remains current until callback completion")
	check(bool(app.state.get("raid_loadout_insured", false)),
		"summary callback executes after the modal pop")
	check(duplicate_callback_count == 0, "rejected duplicate callback never executes")
	check(root.gui_get_focus_owner() == summary_focus,
		"modal callback completion restores the prior summary focus")

	# Reverse ordering is coordinated too: an admitted route prevents a stale
	# modal from opening before the route transaction drains.
	check(app.request_route("main_menu", false), "route is admitted while overlays are clear")
	check(not summary.app.confirm("Stale owner", "Must not open.", func() -> void: pass),
		"modal cannot open behind a pending navigation transaction")
	await settle()
	check(app.current_route == "main_menu" \
			and app.modal == null and screen_root.modal_layer().get_depth() == 0,
		"pending route commits without a stale modal")

	# A popup blocks every ordinary route. Enum forgery, public-facade calls,
	# mismatched Back identity and production review calls grant no capability.
	check(app.request_route("inventory", false), "inventory reset is admitted")
	await settle()
	var inventory := app.screen as CommonActivatableScreen
	var workspace_focus := inventory.get_node_or_null("NavigationChrome/Character") as Control
	workspace_focus.grab_focus()
	await key(KEY_F1)
	var picker := app.picker as CommonActivatableScreen
	check(picker != null and screen_root.popup_layer().get_depth() == 1,
		"F1 owns one tracked popup")
	check(focus_is_inside(picker), "F1 popup owns focus")
	var popup_signature := composition_signature()
	var popup_rejections := rejected.size()
	check(not app.request_route("maps", false),
		"ordinary valid route is blocked while popup is active")
	check(not app.open_developer_route("showcase"),
		"developer facade without a catalog capability is rejected")
	check(not app.submit_navigation(ZUIRouteIntent.open_route(
		&"showcase", &"inventory", ZUIRouteIntent.Origin.DEVELOPER_CATALOG,
		ZUIRouteIntent.StackMode.AUTO, null, RefCounted.new())),
		"forged developer enum and arbitrary capability are rejected")
	check(not app.submit_navigation(ZUIRouteIntent.new(
		ZUIRouteIntent.Kind.BACK, &"pause", &"inventory",
		ZUIRouteIntent.Origin.PRODUCTION, ZUIRouteIntent.StackMode.AUTO,
		ZUIRoutePayload.empty())),
		"Back route cannot differ from its claimed origin")
	check(not app.submit_navigation(ZUIRouteIntent.back(
		&"pause", ZUIRouteIntent.Origin.PRODUCTION)),
		"Back origin must also match the currently committed route")
	check(not app.submit_navigation(ZUIRouteIntent.open_route(
		&"maps", &"inventory", ZUIRouteIntent.Origin.SYSTEM)),
		"forged system origin is rejected")
	await settle()
	check(rejected.size() == popup_rejections + 6,
		"every popup/origin forgery reports one diagnostic")
	check(composition_signature() == popup_signature,
		"blocked and forged intents preserve the popup composition")
	await joypad_button(JOY_BUTTON_B)
	check(app.picker == null and screen_root.popup_layer().get_depth() == 0,
		"controller B clears popup reference and layer together")
	check(app.screen == inventory and root.gui_get_focus_owner() == workspace_focus,
		"controller B restores the exact workspace and focus")

	# A real catalog-issued capability closes the popup first, restores lower
	# lifecycle, and only then commits the selected route.
	await key(KEY_F1)
	picker = app.picker as CommonActivatableScreen
	var stale_authorization: RefCounted = app.feedback._developer_authorization
	picker.selected.emit("showcase")
	check(app.picker == picker, "selected popup remains tracked until CommonUI pop completes")
	await settle()
	check(app.picker == null and screen_root.popup_layer().get_depth() == 0,
		"catalog selection closes popup before route commit settles")
	check(app.current_route == "showcase" \
			and screen_root.menu_layer().get_top_screen() == app.screen,
		"authorized catalog selection commits on the menu layer")
	check(focus_is_inside(app.screen), "authorized destination owns non-null focus")
	check(not app.submit_navigation(ZUIRouteIntent.open_route(
		&"showcase", &"showcase", ZUIRouteIntent.Origin.DEVELOPER_CATALOG,
		ZUIRouteIntent.StackMode.AUTO, null, stale_authorization)),
		"catalog capability expires when its popup closes")
	await joypad_button(JOY_BUTTON_B)
	check(app.screen == inventory and app.current_route == "inventory",
		"developer route Back restores retained workspace")
	check(root.gui_get_focus_owner() == workspace_focus,
		"developer route Back restores workspace focus")

	# Repeat with a workspace-to-workspace replacement, the exact shape that
	# previously left the replacement context unsuspended and focus null.
	await key(KEY_F1)
	picker = app.picker as CommonActivatableScreen
	picker.selected.emit("settings")
	await settle()
	var settings := app.screen as CommonActivatableScreen
	var settings_handle := settings.get_context_handle()
	check(app.current_route == "settings" and screen_root.popup_layer().get_depth() == 0,
		"catalog coordinates popup close before workspace replacement")
	check(settings_handle != null and settings_handle.is_active() \
			and not settings_handle.is_suspended(),
		"replacement context is active and unsuspended")
	check(focus_is_inside(settings), "workspace replacement owns non-null focus")
	await joypad_button(JOY_BUTTON_B)
	check(app.current_route == "main_menu" and focus_is_inside(app.screen),
		"controller B from replacement reaches a focused CommonUI destination")
	check(app.request_route("inventory", false), "final inventory reset is admitted")
	await settle()
	inventory = app.screen as CommonActivatableScreen
	workspace_focus = inventory.get_node_or_null("NavigationChrome/Character") as Control
	workspace_focus.grab_focus()
	await settle()

	# Two same-frame confirmations still produce one modal. Repeated controller
	# Back while its pop is in flight cannot leave an untracked residual depth.
	var final_callback_count := 0
	check(inventory.app.confirm("Once", "Only one modal.", func() -> void:
		final_callback_count += 1), "first same-frame modal is admitted")
	check(not inventory.app.confirm("Twice", "Must not stack.", func() -> void:
		final_callback_count += 10), "second same-frame modal is idempotently rejected")
	await settle()
	check(screen_root.modal_layer().get_depth() == 1 and app.modal != null,
		"same-frame confirms create exactly one tracked modal")
	var closing_modal := app.modal as Control
	push_joypad_taps(JOY_BUTTON_B, 2)
	check(app.modal == closing_modal and screen_root.modal_layer().get_depth() == 1,
		"modal remains tracked until its queued CommonUI pop completes")
	await settle()
	check(screen_root.modal_layer().get_depth() == 0 and app.modal == null,
		"repeated controller Back leaves no residual or untracked modal")
	check(app.current_route == "inventory" and app.screen == inventory,
		"modal dismissal does not leak Back into the workspace")
	check(final_callback_count == 0, "dismissed modal callbacks do not execute")

	for rejection in rejected:
		check(not str(rejection.reason).is_empty(),
			"rejected intent includes a diagnostic: " + str(rejection.route))
	print("COMMON_UI_NAVIGATION_1080_RESULT checks=", checks,
		" failures=", failures,
		" maximum_menu_depth=", maximum_menu_depth,
		" final_menu_depth=", screen_root.menu_layer().get_depth(),
		" final_modal_depth=", screen_root.modal_layer().get_depth(),
		" final_popup_depth=", screen_root.popup_layer().get_depth())
	app.queue_free()
	await settle()
	quit(0 if failures == 0 else 1)
