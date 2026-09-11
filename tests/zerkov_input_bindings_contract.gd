extends SceneTree

## Task 8.3 contract: game-owned logical actions over CommonUI's authoritative
## registry.  This contract deliberately exercises only the fixed 1920x1080
## host composition when a screen is involved; catalog/persistence assertions
## are resolution-independent.
##
## Run with:
##   godot --headless --path . --audio-driver Dummy \
##     --script res://tests/zerkov_input_bindings_contract.gd

var checks: int = 0
var failures: int = 0
var app: Control
var service: ZerkovInputService
var original_persistence_candidates: Dictionary = {}
var persistence_path: String = "user://common_ui_bindings.json"
var teardown_probe: ZerkovInputContextToken


func _initialize() -> void:
	var absolute_path := ProjectSettings.globalize_path(persistence_path)
	for suffix in ["", ".tmp", ".bak"]:
		var candidate_path: String = persistence_path + str(suffix)
		if FileAccess.file_exists(ProjectSettings.globalize_path(candidate_path)):
			original_persistence_candidates[str(suffix)] = FileAccess.get_file_as_bytes(candidate_path)
	run.call_deferred()


func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error("ZERKOV_INPUT_BINDINGS: " + message)


func settle() -> void:
	for _frame in range(12):
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


func has_projected_binding(action_id: StringName, device_kind: int, code: int, axis_direction: int = -1) -> bool:
	if not InputMap.has_action(action_id):
		return false
	for event in InputMap.action_get_events(action_id):
		if device_kind == CommonUIBinding.DEVICE_KEYBOARD:
			var key_event := event as InputEventKey
			if key_event != null and int(key_event.physical_keycode if key_event.physical_keycode != 0 else key_event.keycode) == code:
				return true
		elif device_kind == CommonUIBinding.DEVICE_MOUSE:
			var mouse_event := event as InputEventMouseButton
			if mouse_event != null and int(mouse_event.button_index) == code:
				return true
		elif device_kind == CommonUIBinding.DEVICE_GAMEPAD_BUTTON:
			var button_event := event as InputEventJoypadButton
			if button_event != null and int(button_event.button_index) == code:
				return true
		elif device_kind == CommonUIBinding.DEVICE_GAMEPAD_AXIS:
			var motion_event := event as InputEventJoypadMotion
			if motion_event != null and int(motion_event.axis) == code \
					and (axis_direction < 0 or (axis_direction == CommonUIBinding.AXIS_DIRECTION_NEGATIVE and motion_event.axis_value < 0.0) \
						or (axis_direction == CommonUIBinding.AXIS_DIRECTION_POSITIVE and motion_event.axis_value > 0.0)):
				return true
	return false


func write_persistence(text: String) -> void:
	var file := FileAccess.open(persistence_path, FileAccess.WRITE)
	check(file != null, "fixed persistence path can be opened for the corruption probe")
	if file != null:
		file.store_string(text)
		file.flush()
		file.close()


func remove_persistence_candidates() -> void:
	var directory := DirAccess.open("user://")
	if directory == null:
		return
	for suffix in ["", ".tmp", ".bak"]:
		var candidate: String = "common_ui_bindings.json" + str(suffix)
		if directory.file_exists(candidate):
			directory.remove(candidate)


func restore_persistence() -> void:
	remove_persistence_candidates()
	for suffix_variant in original_persistence_candidates.keys():
		var suffix: String = str(suffix_variant)
		var file := FileAccess.open(persistence_path + suffix, FileAccess.WRITE)
		if file != null:
			file.store_buffer(original_persistence_candidates[suffix_variant])
			file.flush()
			file.close()


func make_binding(device_kind: int, code: int, glyph: StringName = &"") -> CommonUIBinding:
	var binding := CommonUIBinding.new()
	binding.set_device_kind(device_kind)
	binding.set_code(code)
	binding.set_slot(CommonUIBinding.SLOT_PRIMARY)
	binding.set_glyph_id(glyph)
	return binding


func persistence_binding(device_kind: int, code: int, axis_direction: int, glyph: String, dead_zone: float = 0.25) -> Dictionary:
	return {
		"device_kind": device_kind,
		"code": code,
		"axis_direction": axis_direction,
		"dead_zone": dead_zone,
		"shift": false,
		"ctrl": false,
		"alt": false,
		"meta": false,
		"glyph": glyph,
	}


func run() -> void:
	_catalog_contract()
	await _runtime_contract()
	_persistence_contract()
	_context_contract()
	if is_instance_valid(app) and service != null:
		teardown_probe = service.activate_context(ZerkovInputActions.MODAL_CONTEXT, -1, &"teardown_probe")
		app.queue_free()
		await settle()
	check(teardown_probe != null and not teardown_probe.is_active(),
		"service teardown releases native context handles and invalidates retained capabilities")
	check(teardown_probe == null or not teardown_probe.release(),
		"a retained capability cannot release after service teardown")
	restore_persistence()
	print("ZERKOV_INPUT_BINDINGS_RESULT checks=", checks, " failures=", failures,
		" definition_version=", ZerkovInputActions.CONFIG_DEFINITION_VERSION,
		" persistence_format=", ZerkovInputActions.PERSISTENCE_FORMAT_VERSION)
	quit(0 if failures == 0 else 1)


func _catalog_contract() -> void:
	var definitions := ZerkovInputActions.catalog_definitions()
	check(definitions.size() == 31, "catalog has the five framework plus twenty-six game actions and projections")
	check(ZerkovInputActions.all_action_ids().size() == definitions.size(),
		"stable action id list includes every catalog definition exactly once")
	var ids: Dictionary = {}
	for definition_variant in definitions:
		var definition: Dictionary = definition_variant
		var action_id: StringName = definition["id"]
		check(not ids.has(action_id), "action identifier is unique: " + String(action_id))
		ids[action_id] = true
		check(String(action_id).begins_with("common_ui/"),
			"action is in CommonUI's owned namespace: " + String(action_id))
		check(definition["context"] == ZerkovInputActions.GAMEPLAY_CONTEXT
			or definition["context"] == ZerkovInputActions.UI_CONTEXT,
			"action declares gameplay or UI context: " + String(action_id))
		var families: Dictionary = {}
		for binding_variant in definition["bindings"]:
			var binding: Dictionary = binding_variant
			families[str(binding["family"])] = true
			check(ZerkovInputActions.has_glyph(binding["glyph"]),
				"default glyph is declared: " + String(binding["glyph"]))
		check(families.has(String(ZerkovInputActions.FAMILY_KEYBOARD_MOUSE)),
			"keyboard/mouse default exists: " + String(action_id))
		if action_id not in [ZerkovInputActions.GAME_WEAPON_CYCLE]:
			check(families.has(String(ZerkovInputActions.FAMILY_GENERIC_GAMEPAD)),
				"controller default exists: " + String(action_id))
		check(definition["bindings"].size() <= ZerkovInputActions.MAX_BINDINGS_PER_ACTION,
			"binding metadata stays bounded: " + String(action_id))
	var config := ZerkovInputActions.build_input_config()
	check(config.get_definition_version() == ZerkovInputActions.CONFIG_DEFINITION_VERSION,
		"config carries the approved definition version")
	check(config.validate().is_empty(), "native CommonUI config validation is clean")
	var findings := CommonUIActionValidator.validate(config, false)
	check(CommonUIActionValidator.is_ok(findings),
		"default config has no severe action conflicts")
	check(ZerkovInputActions.glyph_metadata().size() <= ZerkovInputActions.MAX_GLYPH_IDS,
		"glyph metadata stays bounded")

	var pad := make_binding(CommonUIBinding.DEVICE_GAMEPAD_BUTTON, JOY_BUTTON_A, &"pad_a")
	check(ZerkovInputActions.resolve_glyph_for_binding(
		pad, ZerkovInputActions.FAMILY_XBOX) == &"xbox_a",
		"Xbox device family resolves a platform glyph")
	check(ZerkovInputActions.resolve_glyph_for_binding(
		pad, ZerkovInputActions.FAMILY_UNKNOWN) == &"pad_a",
		"unknown device family deterministically falls back to binding glyph")
	var forged := make_binding(CommonUIBinding.DEVICE_GAMEPAD_BUTTON, JOY_BUTTON_A, &"pad_forged")
	check(not ZerkovInputActions.has_glyph(forged.get_glyph_id()),
		"unregistered glyph id is not metadata")


func _runtime_contract() -> void:
	root.size = Vector2i(1920, 1080)
	app = load("res://ui/main.tscn").instantiate() as Control
	check(app != null, "1920x1080 main scene instantiates")
	if app == null:
		return
	root.add_child(app)
	await settle()
	service = app.get_node_or_null("ZerkovInputService") as ZerkovInputService
	check(service != null, "main scene owns one game input service")
	if service == null:
		return
	check(service.is_configured(), "game-owned config is installed through CommonUI")
	check(service.definition_version == ZerkovInputActions.CONFIG_DEFINITION_VERSION,
		"service publishes the stable definition version")
	check(service.persistence_format_version == ZerkovInputActions.PERSISTENCE_FORMAT_VERSION,
		"service publishes the stable persistence format")
	var runtime := root.get_node_or_null("CommonUI") as CommonUIRuntime
	check(runtime != null and CommonUIActionValidator.is_ok(
		CommonUIActionValidator.validate_runtime(runtime, false)),
		"active CommonUI lifecycle registrations resolve to declared bound actions")
	if runtime != null:
		var runtime_findings := CommonUIActionValidator.validate(runtime.get_input_config(), false)
		var unexpected_collisions := 0
		for finding_variant in runtime_findings:
			var finding: Dictionary = finding_variant
			if finding.get("severity") == CommonUIActionValidator.SEVERITY_WARNING \
					and str(finding.get("action", "")) not in [
						String(ZerkovInputActions.UI_BACK), String(ZerkovInputActions.UI_CONFIRM)]:
				unexpected_collisions += 1
		check(unexpected_collisions == 0,
			"installed defaults enforce ui_* collision findings except documented framework Back/Confirm overlap")
	for movement_id in [ZerkovInputActions.GAME_MOVE_UP, ZerkovInputActions.GAME_MOVE_LEFT,
			ZerkovInputActions.GAME_MOVE_DOWN, ZerkovInputActions.GAME_MOVE_RIGHT]:
		check(has_projected_binding(movement_id, CommonUIBinding.DEVICE_KEYBOARD,
				KEY_W if movement_id == ZerkovInputActions.GAME_MOVE_UP else KEY_A if movement_id == ZerkovInputActions.GAME_MOVE_LEFT else KEY_S if movement_id == ZerkovInputActions.GAME_MOVE_DOWN else KEY_D),
			"every advertised movement direction projects its keyboard binding: " + String(movement_id))
	check(has_projected_binding(ZerkovInputActions.GAME_MOVE_LEFT,
		CommonUIBinding.DEVICE_GAMEPAD_AXIS, JOY_AXIS_LEFT_X, CommonUIBinding.AXIS_DIRECTION_NEGATIVE),
		"left-stick negative X movement is installed through CommonUI")
	check(has_projected_binding(ZerkovInputActions.GAME_MOVE_UP,
		CommonUIBinding.DEVICE_GAMEPAD_AXIS, JOY_AXIS_LEFT_Y, CommonUIBinding.AXIS_DIRECTION_NEGATIVE),
		"left-stick negative Y movement is installed through CommonUI")
	check(has_projected_binding(ZerkovInputActions.GAME_MOVE_DOWN,
		CommonUIBinding.DEVICE_GAMEPAD_AXIS, JOY_AXIS_LEFT_Y, CommonUIBinding.AXIS_DIRECTION_POSITIVE),
		"left-stick positive Y movement is installed through CommonUI")
	check(has_projected_binding(ZerkovInputActions.GAME_MOVE_RIGHT,
		CommonUIBinding.DEVICE_GAMEPAD_AXIS, JOY_AXIS_LEFT_X, CommonUIBinding.AXIS_DIRECTION_POSITIVE),
		"left-stick positive X movement is installed through CommonUI")
	check(has_projected_binding(ZerkovInputActions.GAME_WEAPON_CYCLE,
		CommonUIBinding.DEVICE_MOUSE, MOUSE_BUTTON_WHEEL_UP),
		"weapon-cycle wheel binding is installed through CommonUI")
	check(has_projected_binding(ZerkovInputActions.GAME_WEAPON_CYCLE_CONTROLLER,
		CommonUIBinding.DEVICE_GAMEPAD_BUTTON, JOY_BUTTON_GUIDE),
		"controller weapon-cycle binding is installed through CommonUI")
	var snapshot_one := service.active_bindings_snapshot()
	var snapshot_two := service.active_bindings_snapshot()
	check(snapshot_one == snapshot_two, "detached binding snapshots are deterministic")
	check(service.active_bindings_bytes() == service.active_bindings_bytes(),
		"canonical binding bytes are deterministic")
	check(snapshot_one.get("schema_version") == ZerkovInputActions.PERSISTENCE_FORMAT_VERSION,
		"snapshot carries schema version")
	check(snapshot_one.get("format_version") == ZerkovInputActions.PERSISTENCE_FORMAT_VERSION,
		"snapshot carries persistence format version")
	check(snapshot_one.get("definition_version") == ZerkovInputActions.CONFIG_DEFINITION_VERSION,
		"snapshot carries definition version")
	var actions: Array = snapshot_one.get("actions", [])
	check(actions.size() == ZerkovInputActions.catalog_definitions().size(),
		"snapshot exposes framework and game-owned actions")
	var detached := snapshot_one.duplicate(true)
	(detached["actions"] as Array)[0]["slots"][0]["code"] = 999
	check(service.active_bindings_snapshot() == snapshot_two,
		"published binding snapshots cannot mutate effective state")
	var effective := service.effective_binding(ZerkovInputActions.UI_OPEN_MAP, CommonUIBinding.SLOT_PRIMARY)
	check(effective != null, "effective UI binding is available")
	if effective != null:
		var original_code := effective.get_code()
		effective.set_code(999)
		check(service.effective_binding(ZerkovInputActions.UI_OPEN_MAP,
			CommonUIBinding.SLOT_PRIMARY).get_code() == original_code,
			"effective binding reads are detached from registry state")
	check(service.resolve_glyph(ZerkovInputActions.UI_OPEN_MAP,
		CommonUIBinding.SLOT_PRIMARY, ZerkovInputActions.FAMILY_KEYBOARD_MOUSE) == &"key_m",
		"keyboard glyph resolution is stable")
	check(service.resolve_glyph(ZerkovInputActions.UI_OPEN_MAP,
		CommonUIBinding.SLOT_SECONDARY, ZerkovInputActions.FAMILY_XBOX) == &"xbox_back",
		"controller glyph resolution follows the active device family")
	if runtime != null:
		var registry := runtime.get_binding_registry()
		for glyph_probe in [
			[ZerkovInputActions.GAME_FIRE, &"xbox_rt"],
			[ZerkovInputActions.GAME_MOVE_UP, &"xbox_ls"],
			[ZerkovInputActions.GAME_QUICK_USE, &"xbox_dpad_up"],
			[ZerkovInputActions.GAME_MELEE, &"xbox_rs"],
		]:
			var probe_id: StringName = glyph_probe[0]
			var expected: StringName = glyph_probe[1]
			var native_glyph := registry.resolve_glyph(probe_id, CommonInputBindingRegistry.SLOT_SECONDARY, "xbox")
			check(native_glyph == expected and service.resolve_glyph(probe_id,
				CommonUIBinding.SLOT_SECONDARY, ZerkovInputActions.FAMILY_XBOX) == native_glyph,
				"published glyph agrees with authoritative CommonUI resolver: " + String(probe_id))
	var modality_events: Array = []
	var modality_callback := func(modality: int, device: int) -> void:
		modality_events.append([modality, device])
	service.modality_changed.connect(modality_callback)
	var mouse_motion := InputEventMouseMotion.new()
	mouse_motion.relative = Vector2(24, 0)
	root.push_input(mouse_motion)
	await settle()
	await joypad_button(JOY_BUTTON_GUIDE)
	check(not modality_events.is_empty(), "device switching publishes modality changes")
	service.modality_changed.disconnect(modality_callback)
	check(app.request_route("hud", false), "exact 1920x1080 HUD route is admitted")
	await settle()
	await key(KEY_I)
	check(app.current_route == "inventory", "keyboard UI action opens inventory through CommonUI")
	await key(KEY_M)
	check(app.current_route == "maps", "keyboard UI action opens maps through CommonUI")
	await key(KEY_J)
	check(app.current_route == "tasks", "keyboard UI action opens tasks through CommonUI")
	await joypad_button(JOY_BUTTON_START)
	check(app.current_route == "inventory", "controller UI action opens inventory through CommonUI")
	check(service.effective_binding(ZerkovInputActions.UI_OPEN_INVENTORY,
		CommonUIBinding.SLOT_SECONDARY).get_code() == JOY_BUTTON_START,
		"inventory controller default avoids Godot's ui_select reservation")
	check(service.effective_binding(ZerkovInputActions.UI_OPEN_TASKS,
		CommonUIBinding.SLOT_SECONDARY).get_code() == JOY_BUTTON_RIGHT_STICK,
		"tasks controller default avoids Godot's ui_down reservation")
	check(app.request_route("inventory", false), "focused-button controller probe enters inventory at exact 1920x1080")
	await settle()
	var focused_button := app.screen.get_node_or_null("NavigationChrome/Tasks") as BaseButton
	if focused_button != null:
		focused_button.grab_focus()
	await settle()
	check(focused_button != null and root.gui_get_focus_owner() == focused_button,
		"exact-1920 controller probe owns a focused CommonUI button")
	await joypad_button(JOY_BUTTON_RIGHT_STICK)
	check(app.current_route == "tasks",
		"non-reserved controller UI action reaches CommonUI with a focused button")

	var keyboard_candidate := make_binding(CommonUIBinding.DEVICE_KEYBOARD, KEY_M, &"key_m")
	var conflicts := service.preview_conflicts(
		ZerkovInputActions.UI_OPEN_TASKS, CommonUIBinding.SLOT_PRIMARY, keyboard_candidate)
	check(not conflicts.is_empty(), "same-context candidate reports a conflict")
	var malformed := make_binding(CommonUIBinding.DEVICE_KEYBOARD, 0, &"key_m")
	check(not service.rebind(ZerkovInputActions.UI_OPEN_TASKS,
		CommonUIBinding.SLOT_PRIMARY, malformed).get("ok", false),
		"malformed binding is rejected")
	check(not service.rebind(&"common_ui/forged", CommonUIBinding.SLOT_PRIMARY,
		keyboard_candidate).get("ok", false), "unknown action id is rejected")
	check(not service.rebind(ZerkovInputActions.UI_OPEN_TASKS,
		CommonUIBinding.SLOT_PRIMARY, forged_binding()).get("ok", false),
		"forged glyph metadata is rejected")
	var incompatible_glyph := make_binding(CommonUIBinding.DEVICE_KEYBOARD, KEY_Z, &"pad_a")
	check(not service.rebind(ZerkovInputActions.UI_OPEN_TASKS,
		CommonUIBinding.SLOT_PRIMARY, incompatible_glyph).get("ok", false),
		"known but device-incompatible glyph metadata is rejected")
	check(not service.rebind(ZerkovInputActions.UI_OPEN_TASKS,
		CommonUIBinding.SLOT_PRIMARY, keyboard_candidate, 99).get("ok", false),
		"unknown conflict policy is rejected")
	var focus_collision := make_binding(CommonUIBinding.DEVICE_KEYBOARD, KEY_TAB)
	var collision_result := service.rebind(ZerkovInputActions.UI_OPEN_MAP,
		CommonUIBinding.SLOT_PRIMARY, focus_collision)
	check(not collision_result.get("ok", false)
			and str(collision_result.get("error", "")).contains("ui_"),
		"rebinds that target a Godot ui_* focus key are rejected before registry mutation")
	var controller_focus_collision := make_binding(CommonUIBinding.DEVICE_GAMEPAD_BUTTON,
		JOY_BUTTON_DPAD_UP, &"pad_dpad_up")
	var controller_collision_result := service.rebind(ZerkovInputActions.UI_OPEN_MAP,
		CommonUIBinding.SLOT_PRIMARY, controller_focus_collision)
	check(not controller_collision_result.get("ok", false)
			and str(controller_collision_result.get("error", "")).contains("ui_"),
		"rebinds that target a Godot ui_* controller focus button are rejected")
	var controller_select_collision := make_binding(CommonUIBinding.DEVICE_GAMEPAD_BUTTON,
		JOY_BUTTON_Y, &"pad_y")
	var controller_select_result := service.rebind(ZerkovInputActions.UI_OPEN_INVENTORY,
		CommonUIBinding.SLOT_SECONDARY, controller_select_collision)
	check(not controller_select_result.get("ok", false)
			and str(controller_select_result.get("error", "")).contains("ui_"),
		"rebinds that target a Godot ui_* controller select button are rejected")
	var controller_axis_collision := make_binding(CommonUIBinding.DEVICE_GAMEPAD_AXIS,
		JOY_AXIS_LEFT_Y, &"pad_ls_up")
	controller_axis_collision.set_axis_direction(CommonUIBinding.AXIS_DIRECTION_NEGATIVE)
	var controller_axis_result := service.rebind(ZerkovInputActions.UI_OPEN_MAP,
		CommonUIBinding.SLOT_SECONDARY, controller_axis_collision)
	check(not controller_axis_result.get("ok", false)
			and str(controller_axis_result.get("error", "")).contains("ui_"),
		"rebinds that target a Godot ui_* controller focus axis are rejected")
	var confirm_focus_collision := make_binding(CommonUIBinding.DEVICE_KEYBOARD, KEY_TAB,
		&"key_tab")
	var confirm_collision_result := service.rebind(ZerkovInputActions.UI_CONFIRM,
		CommonUIBinding.SLOT_PRIMARY, confirm_focus_collision)
	check(not confirm_collision_result.get("ok", false)
			and str(confirm_collision_result.get("error", "")).contains("ui_"),
		"Confirm cannot repurpose a ui_* focus key outside its authored Enter overlap")
	var high_godot_key := make_binding(CommonUIBinding.DEVICE_KEYBOARD, KEY_F24)
	var high_key_result := service.rebind(ZerkovInputActions.UI_OPEN_TASKS,
		CommonUIBinding.SLOT_PRIMARY, high_godot_key,
		CommonInputBindingRegistry.CONFLICT_REJECT, false, &"task_8_3_high_godot_key")
	check(high_key_result.get("ok", false)
			and service.effective_binding(ZerkovInputActions.UI_OPEN_TASKS,
				CommonUIBinding.SLOT_PRIMARY).get_code() == KEY_F24,
		"valid high Godot keyboard codes are accepted by device-specific validation")
	check(service.restore_action_defaults(ZerkovInputActions.UI_OPEN_TASKS).get("ok", false),
		"high-key validation probe restores the task default")
	var protected_replace := service.rebind(ZerkovInputActions.UI_OPEN_TASKS,
		CommonUIBinding.SLOT_PRIMARY, keyboard_candidate,
		CommonInputBindingRegistry.CONFLICT_REPLACE, true)
	check(protected_replace.get("ok", false)
		and service.effective_binding(ZerkovInputActions.UI_OPEN_MAP,
			CommonUIBinding.SLOT_SECONDARY) != null,
		"replace policy preserves another binding on a protected conflicting action")
	check(service.restore_defaults().get("ok", false),
		"policy probe restores the complete default set")
	var duplicate_before := service.active_bindings_bytes()
	var duplicate_allowed := service.rebind(ZerkovInputActions.UI_OPEN_TASKS,
		CommonUIBinding.SLOT_PRIMARY, keyboard_candidate,
		CommonInputBindingRegistry.CONFLICT_ALLOW_DUPLICATE, true)
	check(not duplicate_allowed.get("ok", false)
		and duplicate_allowed.get("error") == "duplicate_conflict_policy_not_persistable"
		and service.active_bindings_bytes() == duplicate_before,
		"unsupported allow-duplicate policy is rejected before mutation for round-trip safety")
	var oversized_request := StringName("x".repeat(ZerkovInputService.MAX_REQUEST_ID_LENGTH + 1))
	check(not service.restore_defaults(oversized_request).get("ok", false),
		"oversized request id is rejected before persistence")

	var request_id: StringName = &"task_8_3_restore_defaults"
	var first := service.restore_defaults(request_id)
	var replay := service.restore_defaults(request_id)
	check(first.get("ok", false), "default restoration is accepted")
	check(replay.get("replayed", false), "identical request id is idempotently replayed")
	var conflict_reuse := service.restore_action_defaults(ZerkovInputActions.UI_OPEN_MAP, request_id)
	check(not conflict_reuse.get("ok", false)
		and conflict_reuse.get("error") == "request_id_reuse_conflict",
		"request id reuse with a different operation is rejected")
	var nested_request_id: StringName = &"task_8_3_nested_reservation"
	var nested_results: Array[Dictionary] = []
	var nested_callback := func(_snapshot: Dictionary) -> void:
		if nested_results.is_empty():
			nested_results.append(service.restore_defaults(nested_request_id))
	service.bindings_published.connect(nested_callback)
	var nested_outer := service.restore_defaults(nested_request_id)
	service.bindings_published.disconnect(nested_callback)
	check(nested_outer.get("ok", false) and nested_results.size() == 1
			and nested_results[0].get("error") == "request_id_in_flight",
		"request ids are reserved before synchronous CommonUI publication prevents nested reuse")
	check(service.restore_defaults(nested_request_id).get("replayed", false),
		"completed reserved request replays deterministically")
	var reload_candidate := make_binding(CommonUIBinding.DEVICE_KEYBOARD, KEY_Z)
	var reload_result := service.rebind(ZerkovInputActions.UI_OPEN_TASKS,
		CommonUIBinding.SLOT_PRIMARY, reload_candidate,
		CommonInputBindingRegistry.CONFLICT_REJECT, false, &"task_8_3_reload")
	check(reload_result.get("ok", false), "a valid rebind persists through the fixed transaction")
	var persisted_bytes := service.active_bindings_bytes()
	check(registry_reload_succeeds_and_keeps(service),
		"a valid persisted override reloads through the native registry")
	check(service.active_bindings_bytes() == persisted_bytes,
		"accepted rebind bytes round-trip without changing the canonical publication")
	check(service.restore_defaults().get("ok", false),
		"reload probe restores the complete default set")
	check(service.persistence_descriptor().get("path") == "user://common_ui_bindings.json",
		"persistence path is fixed and not caller-controlled")


func forged_binding() -> CommonUIBinding:
	return make_binding(CommonUIBinding.DEVICE_KEYBOARD, KEY_M, &"pad_forged")


func registry_reload_succeeds_and_keeps(candidate_service: ZerkovInputService) -> bool:
	if candidate_service == null:
		return false
	var reloaded := candidate_service.reload_overrides()
	var binding := candidate_service.effective_binding(
		ZerkovInputActions.UI_OPEN_TASKS, CommonUIBinding.SLOT_PRIMARY)
	return reloaded and binding != null and binding.get_code() == KEY_Z


func _persistence_contract() -> void:
	if service == null:
		return
	var registry := (root.get_node("CommonUI") as CommonUIRuntime).get_binding_registry()
	check(registry != null, "CommonUI exposes the authoritative binding registry")
	if registry == null:
		return
	var before := service.active_bindings_bytes()
	remove_persistence_candidates()
	write_persistence("{\"format_version\":999,\"definition_version\":803,\"overrides\":[]}")
	check(not service.reload_overrides(), "unsupported persistence format is rejected")
	check(service.active_bindings_bytes() == before,
		"corrupt persistence leaves live bindings unchanged")
	remove_persistence_candidates()
	write_persistence("{\"format_version\":1,\"definition_version\":803,\"overrides\":[]}")
	check(service.reload_overrides(), "known older persistence format is accepted without guessing")
	check(service.active_bindings_bytes() == before,
		"known migration format leaves effective bindings deterministic")
	remove_persistence_candidates()
	write_persistence("{\"format_version\":2,\"definition_version\":1,\"overrides\":[]}")
	check(not service.reload_overrides(), "stale definition version is rejected")
	check(service.active_bindings_bytes() == before,
		"stale persistence leaves live bindings unchanged")
	remove_persistence_candidates()
	write_persistence(JSON.stringify({
		"format_version": 2,
		"definition_version": ZerkovInputActions.CONFIG_DEFINITION_VERSION,
		"overrides": [{
			"action": String(ZerkovInputActions.UI_OPEN_TASKS),
			"slot": 0,
			"cleared": false,
			"binding": persistence_binding(CommonUIBinding.DEVICE_KEYBOARD, KEY_Z,
				CommonUIBinding.AXIS_DIRECTION_NONE, "pad_forged"),
		}],
	}))
	check(not service.reload_overrides(), "unknown persisted glyph metadata is rejected before install")
	check(service.active_bindings_bytes() == before,
		"forged glyph persistence leaves live bindings unchanged")
	remove_persistence_candidates()
	write_persistence(JSON.stringify({
		"format_version": 2,
		"definition_version": ZerkovInputActions.CONFIG_DEFINITION_VERSION,
		"overrides": [{
			"action": String(ZerkovInputActions.UI_OPEN_TASKS),
			"slot": 0,
			"cleared": false,
			"binding": persistence_binding(CommonUIBinding.DEVICE_KEYBOARD, KEY_Z,
				CommonUIBinding.AXIS_DIRECTION_NONE, "pad_a"),
		}],
	}))
	check(not service.reload_overrides(), "known but incompatible persisted glyph metadata is rejected")
	check(service.active_bindings_bytes() == before,
		"incompatible persisted glyph leaves live bindings unchanged")
	remove_persistence_candidates()
	write_persistence(JSON.stringify({
		"format_version": 2,
		"definition_version": ZerkovInputActions.CONFIG_DEFINITION_VERSION,
		"overrides": [{
			"action": String(ZerkovInputActions.UI_OPEN_TASKS),
			"slot": 0,
			"cleared": false,
			"binding": persistence_binding(CommonUIBinding.DEVICE_KEYBOARD, KEY_M,
				CommonUIBinding.AXIS_DIRECTION_NONE, "key_m"),
		}],
	}))
	check(not service.reload_overrides(), "persisted same-context collisions are rejected before install")
	check(service.active_bindings_bytes() == before,
		"persisted collision leaves live bindings unchanged")
	remove_persistence_candidates()
	write_persistence(JSON.stringify({
		"format_version": 2,
		"definition_version": ZerkovInputActions.CONFIG_DEFINITION_VERSION,
		"overrides": [{
			"action": String(ZerkovInputActions.UI_OPEN_MAP),
			"slot": 1,
			"cleared": false,
			"binding": persistence_binding(CommonUIBinding.DEVICE_GAMEPAD_BUTTON,
				JOY_BUTTON_DPAD_UP, CommonUIBinding.AXIS_DIRECTION_NONE, "pad_dpad_up"),
		}],
	}))
	check(not service.reload_overrides(), "persisted ui_* controller collision is rejected before install")
	check(service.active_bindings_bytes() == before,
		"persisted controller focus collision leaves live bindings unchanged")
	remove_persistence_candidates()
	write_persistence(JSON.stringify({
		"format_version": 2,
		"definition_version": ZerkovInputActions.CONFIG_DEFINITION_VERSION,
		"overrides": [{
			"action": String(ZerkovInputActions.UI_OPEN_TASKS),
			"slot": 0,
			"cleared": false,
			"binding": persistence_binding(CommonUIBinding.DEVICE_MOUSE, KEY_F24,
				CommonUIBinding.AXIS_DIRECTION_NONE, "mouse_left"),
		}],
	}))
	check(not service.reload_overrides(), "device-specific persisted code bounds reject a mouse/key mismatch")
	check(service.active_bindings_bytes() == before,
		"device-mismatched persistence leaves live bindings unchanged")
	remove_persistence_candidates()
	write_persistence(JSON.stringify({
		"format_version": 2,
		"definition_version": ZerkovInputActions.CONFIG_DEFINITION_VERSION,
		"overrides": [{
			"action": String(ZerkovInputActions.UI_OPEN_TASKS),
			"slot": 0,
			"cleared": false,
			"binding": persistence_binding(CommonUIBinding.DEVICE_KEYBOARD, KEY_B,
				CommonUIBinding.AXIS_DIRECTION_NONE, "key_b", 2.0),
		}],
	}))
	check(not service.reload_overrides(), "out-of-range persisted dead zone is rejected before CommonUI clamping")
	check(service.active_bindings_bytes() == before,
		"out-of-range persisted dead zone leaves live bindings unchanged")
	remove_persistence_candidates()


func _context_contract() -> void:
	if service == null:
		return
	var gameplay := service.activate_context(ZerkovInputActions.GAMEPLAY_CONTEXT)
	var ui := service.activate_context(ZerkovInputActions.UI_CONTEXT)
	var gameplay_peer := service.activate_context(ZerkovInputActions.GAMEPLAY_CONTEXT, -1, &"peer")
	var ui_peer := service.activate_context(ZerkovInputActions.UI_CONTEXT, -1, &"peer")
	check(gameplay != null and ui != null and gameplay_peer != null and ui_peer != null,
		"gameplay and UI contexts activate with caller-owned leases")
	if gameplay == null or ui == null:
		return
	check(ui.is_active() and gameplay.is_active() and gameplay_peer != gameplay and ui_peer != ui
			and gameplay_peer.capability_id != gameplay.capability_id
			and ui_peer.capability_id != ui.capability_id,
		"context leases are distinct capabilities for distinct callers")
	var edited_capability := service.activate_context(ZerkovInputActions.GAMEPLAY_CONTEXT, -1, &"edited")
	if edited_capability != null:
		edited_capability.context_id = ZerkovInputActions.UI_CONTEXT
		edited_capability.generation = -1
		edited_capability.capability_id = -1
	check(edited_capability != null and edited_capability.release(),
		"lease release uses service-owned capability identity rather than mutable caller fields")
	check(not gameplay.snapshot().get("released", true), "context snapshot is detached")
	var forged_token := ZerkovInputContextToken.new()
	forged_token.context_id = ZerkovInputActions.UI_CONTEXT
	forged_token.generation = ui.generation
	forged_token.capability_id = ui.capability_id
	check(not service.release_context_token(forged_token),
		"forged context token identity cannot release a live context")
	check(service.activate_context(ZerkovInputActions.GAMEPLAY_CONTEXT, ZerkovInputService.MODAL_PRIORITY) == null,
		"caller cannot manufacture a project-owned modal priority for gameplay")
	check(service.activate_context(ZerkovInputActions.UI_CONTEXT, -2) == null,
		"only the documented -1 default sentinel is accepted for context priority")
	var stale_ui := ui
	check(ui.release(), "an active UI context can be released before replacement")
	check(ui_peer.is_active(), "releasing one caller capability keeps the peer lease active")
	var replacement_ui := service.activate_context(ZerkovInputActions.UI_CONTEXT)
	check(replacement_ui != null and replacement_ui != stale_ui
			and replacement_ui.capability_id != stale_ui.capability_id,
		"replacement context receives a distinct caller capability")
	check(not stale_ui.release() and replacement_ui != null and replacement_ui.is_active(),
		"stale context token cannot release its replacement")
	ui = replacement_ui
	var gameplay_row := _context_row(ZerkovInputActions.GAMEPLAY_CONTEXT)
	var ui_row := _context_row(ZerkovInputActions.UI_CONTEXT)
	check(bool(gameplay_row.get("suspended", false)) and not bool(ui_row.get("suspended", true)),
		"higher-priority UI context suspends gameplay without dropping its lease")
	var modal := service.activate_modal(&"contract")
	check(modal != null and modal.is_active(), "modal context has priority")
	if modal != null:
		gameplay_row = _context_row(ZerkovInputActions.GAMEPLAY_CONTEXT)
		ui_row = _context_row(ZerkovInputActions.UI_CONTEXT)
		check(bool(gameplay_row.get("suspended", false)) and bool(ui_row.get("suspended", false)),
			"modal priority suspends both lower context leases")
		check(modal.release(), "modal lease releases cleanly")
	check(gameplay.release(), "gameplay lease releases cleanly")
	check(gameplay_peer.release(), "peer gameplay lease releases independently")
	check(ui_peer.release(), "peer UI lease releases independently")
	check(ui.release(), "UI lease releases cleanly")
	check(not gameplay.release(), "stale context release is idempotently rejected")


func _context_row(context_id: StringName) -> Dictionary:
	if service == null:
		return {}
	for row_variant in service.context_snapshot():
		var row: Dictionary = row_variant
		if row.get("context") == String(context_id):
			return row.duplicate(true)
	return {}
