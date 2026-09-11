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


func run() -> void:
	_catalog_contract()
	await _runtime_contract()
	_persistence_contract()
	_context_contract()
	if is_instance_valid(app):
		app.queue_free()
		await settle()
	restore_persistence()
	print("ZERKOV_INPUT_BINDINGS_RESULT checks=", checks, " failures=", failures,
		" definition_version=", ZerkovInputActions.CONFIG_DEFINITION_VERSION,
		" persistence_format=", ZerkovInputActions.PERSISTENCE_FORMAT_VERSION)
	quit(0 if failures == 0 else 1)


func _catalog_contract() -> void:
	var definitions := ZerkovInputActions.catalog_definitions()
	check(definitions.size() == 26, "catalog has the five framework plus twenty-one game actions")
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
	await key(KEY_TAB)
	check(app.current_route == "inventory", "keyboard UI action opens inventory through CommonUI")
	await key(KEY_M)
	check(app.current_route == "maps", "keyboard UI action opens maps through CommonUI")
	await key(KEY_J)
	check(app.current_route == "tasks", "keyboard UI action opens tasks through CommonUI")
	await joypad_button(JOY_BUTTON_Y)
	check(app.current_route == "inventory", "controller UI action opens inventory through CommonUI")

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
	check(not service.rebind(ZerkovInputActions.UI_OPEN_TASKS,
		CommonUIBinding.SLOT_PRIMARY, keyboard_candidate, 99).get("ok", false),
		"unknown conflict policy is rejected")
	var protected_replace := service.rebind(ZerkovInputActions.UI_OPEN_TASKS,
		CommonUIBinding.SLOT_PRIMARY, keyboard_candidate,
		CommonInputBindingRegistry.CONFLICT_REPLACE, true)
	check(protected_replace.get("ok", false)
		and service.effective_binding(ZerkovInputActions.UI_OPEN_MAP,
			CommonUIBinding.SLOT_SECONDARY) != null,
		"replace policy preserves another binding on a protected conflicting action")
	check(service.restore_defaults().get("ok", false),
		"policy probe restores the complete default set")
	var duplicate_allowed := service.rebind(ZerkovInputActions.UI_OPEN_TASKS,
		CommonUIBinding.SLOT_PRIMARY, keyboard_candidate,
		CommonInputBindingRegistry.CONFLICT_ALLOW_DUPLICATE, true)
	check(duplicate_allowed.get("ok", false),
		"allow-duplicate policy is explicit and transactional")
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
	var reload_candidate := make_binding(CommonUIBinding.DEVICE_KEYBOARD, KEY_Z)
	var reload_result := service.rebind(ZerkovInputActions.UI_OPEN_TASKS,
		CommonUIBinding.SLOT_PRIMARY, reload_candidate,
		CommonInputBindingRegistry.CONFLICT_REJECT, false, &"task_8_3_reload")
	check(reload_result.get("ok", false), "a valid rebind persists through the fixed transaction")
	check(registry_reload_succeeds_and_keeps(service),
		"a valid persisted override reloads through the native registry")
	check(service.restore_defaults().get("ok", false),
		"reload probe restores the complete default set")
	check(service.persistence_descriptor().get("path") == "user://common_ui_bindings.json",
		"persistence path is fixed and not caller-controlled")


func forged_binding() -> CommonUIBinding:
	return make_binding(CommonUIBinding.DEVICE_KEYBOARD, KEY_M, &"pad_forged")


func registry_reload_succeeds_and_keeps(candidate_service: ZerkovInputService) -> bool:
	if candidate_service == null:
		return false
	var runtime := root.get_node_or_null("CommonUI") as CommonUIRuntime
	var registry := runtime.get_binding_registry() if runtime != null else null
	if registry == null:
		return false
	var reloaded := registry.load_overrides()
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
	check(not registry.load_overrides(), "unsupported persistence format is rejected")
	check(service.active_bindings_bytes() == before,
		"corrupt persistence leaves live bindings unchanged")
	remove_persistence_candidates()
	write_persistence("{\"format_version\":1,\"definition_version\":803,\"overrides\":[]}")
	check(registry.load_overrides(), "known older persistence format is accepted without guessing")
	check(service.active_bindings_bytes() == before,
		"known migration format leaves effective bindings deterministic")
	remove_persistence_candidates()
	write_persistence("{\"format_version\":2,\"definition_version\":1,\"overrides\":[]}")
	check(not registry.load_overrides(), "stale definition version is rejected")
	check(service.active_bindings_bytes() == before,
		"stale persistence leaves live bindings unchanged")
	remove_persistence_candidates()


func _context_contract() -> void:
	if service == null:
		return
	var gameplay := service.activate_context(ZerkovInputActions.GAMEPLAY_CONTEXT)
	var ui := service.activate_context(ZerkovInputActions.UI_CONTEXT)
	check(gameplay != null and ui != null, "gameplay and UI contexts activate")
	if gameplay == null or ui == null:
		return
	check(ui.is_active() and gameplay.is_active(), "context leases are active")
	check(not gameplay.snapshot().get("released", true), "context snapshot is detached")
	var forged_token := ZerkovInputContextToken.new()
	forged_token.context_id = ZerkovInputActions.UI_CONTEXT
	forged_token.generation = ui.generation
	check(not service.release_context_token(forged_token),
		"forged context token identity cannot release a live context")
	var stale_ui := ui
	check(ui.release(), "an active UI context can be released before replacement")
	var replacement_ui := service.activate_context(ZerkovInputActions.UI_CONTEXT)
	check(replacement_ui != null and replacement_ui.generation != stale_ui.generation,
		"replacement context receives a fresh generation")
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
