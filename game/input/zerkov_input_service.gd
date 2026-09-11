class_name ZerkovInputService
extends Node

## Product-owned input definitions, effective binding projection, and context
## leases.  CommonUI owns physical dispatch and its native registry owns the
## atomic fixed-path persistence transaction; this service owns what those
## inputs mean to Zerkov and never treats InputMap as canonical gameplay state.

signal configuration_ready(definition_version: int)
signal bindings_published(snapshot: Dictionary)
signal persistence_error(reason: String)
signal contexts_published(snapshot: Array)
signal modality_changed(modality: int, device: int)

const ACTIONS := preload("res://game/input/zerkov_input_actions.gd")
const CONTEXT_TOKEN := preload("res://game/input/zerkov_input_context_token.gd")

const MAX_REQUEST_HISTORY: int = 64
const MAX_REQUEST_ID_LENGTH: int = 96
const MAX_CONTEXT_SOURCE_LENGTH: int = 96
const MAX_CONTEXTS: int = 8
const PERSISTENCE_PATH: String = "user://common_ui_bindings.json"

const GAMEPLAY_PRIORITY: int = 0
const UI_PRIORITY: int = 50
const MODAL_PRIORITY: int = 100
const DEVELOPER_PRIORITY: int = 150

var definition_version: int = ACTIONS.CONFIG_DEFINITION_VERSION
var persistence_format_version: int = ACTIONS.PERSISTENCE_FORMAT_VERSION
var configured: bool = false
var last_error: String = ""
var last_persistence_error: String = ""

var _runtime: CommonUIRuntime
var _registry: CommonInputBindingRegistry
var _config: CommonUIInputConfig
var _specs: Array[Dictionary] = []
var _spec_by_id: Dictionary = {}
var _request_history: Dictionary = {}
var _request_order: Array[String] = []
var _contexts: Dictionary = {}
var _next_generation: int = 0


func _ready() -> void:
	_install_configuration()


func _install_configuration() -> bool:
	_runtime = get_node_or_null(^"/root/CommonUI") as CommonUIRuntime
	if _runtime == null:
		return _fail("CommonUI runtime is unavailable; input configuration was not installed.")
	_specs = ACTIONS.catalog_definitions()
	_index_specs()
	if _specs.size() > ACTIONS.MAX_ACTIONS:
		return _fail("Zerkov input catalog exceeds its bounded action count.")
	var catalog_error := _validate_specs()
	if not catalog_error.is_empty():
		return _fail(catalog_error)
	_config = ACTIONS.build_input_config()
	var native_errors := _config.validate()
	if not native_errors.is_empty():
		return _fail("Input configuration failed native validation: " + "; ".join(native_errors))
	var findings := CommonUIActionValidator.validate(_config, true)
	for finding_variant in findings:
		var finding: Dictionary = finding_variant
		if finding.get("severity") == CommonUIActionValidator.SEVERITY_ERROR:
			return _fail("Input configuration failed action validation: " + str(finding.get("message", "")))

	# The runtime's setter configures the native registry, loads the fixed
	# user:// document, and applies its InputMap projection.  We retain the
	# registry as the effective-binding source and never read InputMap back.
	_runtime.set_input_config(_config)
	_registry = _runtime.get_binding_registry()
	if _registry == null:
		return _fail("CommonUI did not expose a binding registry after configuration.")
	if not _registry.binding_error.is_connected(_on_binding_error):
		_registry.binding_error.connect(_on_binding_error)
	if not _registry.bindings_changed.is_connected(_on_bindings_changed):
		_registry.bindings_changed.connect(_on_bindings_changed)
	# set_input_config performs the first load before the signal connection is
	# possible. A second load observes a malformed/forged document as a diagnostic
	# while leaving the native defaults/effective state unchanged.
	_registry.load_overrides()
	if not _runtime.input_modality_changed.is_connected(_on_modality_changed):
		_runtime.input_modality_changed.connect(_on_modality_changed)
	configured = true
	configuration_ready.emit(definition_version)
	_publish_bindings()
	_publish_contexts()
	return true


func is_configured() -> bool:
	return configured and _registry != null and _config != null


func action_definitions() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for spec in _specs:
		result.append(spec.duplicate(true))
	return result


func action_definition(action_id: StringName) -> Dictionary:
	var spec: Variant = _spec_by_id.get(action_id, null)
	return (spec as Dictionary).duplicate(true) if spec is Dictionary else {}


func effective_binding(action_id: StringName, slot: int) -> CommonUIBinding:
	if _registry == null or not _valid_slot(slot) or not _spec_by_id.has(action_id):
		return null
	return _clone_binding(_registry.get_effective_binding(action_id, slot))


func resolve_glyph(action_id: StringName, slot: int, device_family: StringName = &"") -> StringName:
	var binding := effective_binding(action_id, slot)
	if binding == null:
		return &"glyph_unbound"
	var family := device_family if device_family != &"" else active_device_family()
	return ACTIONS.resolve_glyph_for_binding(binding, family)


func active_device_family() -> StringName:
	if _runtime == null:
		return ACTIONS.FAMILY_KEYBOARD_MOUSE
	return ACTIONS.family_for_device_name(_runtime.get_active_device_name())


func glyph_metadata() -> Dictionary:
	return ACTIONS.glyph_metadata()


func active_bindings_snapshot() -> Dictionary:
	var actions: Array[Dictionary] = []
	for spec_variant in _specs:
		var spec: Dictionary = spec_variant
		var slots: Array[Dictionary] = []
		for slot in [CommonUIBinding.SLOT_PRIMARY, CommonUIBinding.SLOT_SECONDARY]:
			slots.append(ACTIONS.binding_descriptor(effective_binding(spec["id"] as StringName, slot), slot))
		actions.append({
			"id": String(spec["id"]),
			"label": str(spec["label"]),
			"context": String(spec["context"]),
			"conflict_context": String(spec["conflict_context"]),
			"slots": slots,
			"glyphs": [String(resolve_glyph(spec["id"] as StringName, 0)), String(resolve_glyph(spec["id"] as StringName, 1))],
		})
	return {
		"schema_version": persistence_format_version,
		"format_version": persistence_format_version,
		"definition_version": definition_version,
		"persistence_path": PERSISTENCE_PATH,
		"actions": actions,
	}


func active_bindings_bytes() -> PackedByteArray:
	return _canonical_json(active_bindings_snapshot()).to_utf8_buffer()


func persistence_descriptor() -> Dictionary:
	return {
		"path": PERSISTENCE_PATH,
		"format_version": persistence_format_version,
		"definition_version": definition_version,
		"recovery": "CommonUI native target/temp/backup atomic replacement; invalid candidates are rejected as a whole",
		"migration": "known override formats up to the current version are schema-compatible; exact definition version only; a changed action/slot/protection schema fails closed and keeps defaults",
	}


func rebind(
	action_id: StringName,
	slot: int,
	candidate: CommonUIBinding,
	policy: int = CommonInputBindingRegistry.CONFLICT_REJECT,
	confirmed: bool = false,
	request_id: StringName = &""
) -> Dictionary:
	if not _valid_request_id(request_id):
		return {"ok": false, "error": "request_id_exceeds_bound", "replayed": false}
	if not _valid_policy(policy):
		return {"ok": false, "error": "unknown_conflict_policy", "replayed": false}
	if _registry == null:
		return {"ok": false, "error": "Input binding registry is unavailable.", "replayed": false}
	var fingerprint := _request_fingerprint("rebind", action_id, slot, candidate, policy, confirmed)
	var replay := _replayed_request(request_id, fingerprint)
	if not replay.is_empty():
		return replay
	var validation := _validate_candidate(action_id, slot, candidate)
	if not bool(validation.get("ok", false)):
		return _remember_request(request_id, fingerprint, validation)
	var result := _registry.rebind(
		action_id,
		slot,
		validation["binding"] as CommonUIBinding,
		policy,
		confirmed
	)
	result = _decorate_result(result, action_id, slot, request_id, false)
	return _remember_request(request_id, fingerprint, result)


func clear_binding(
	action_id: StringName,
	slot: int,
	confirmed: bool = false,
	request_id: StringName = &"") -> Dictionary:
	if not _valid_request_id(request_id):
		return {"ok": false, "error": "request_id_exceeds_bound", "replayed": false}
	if not _valid_slot(slot) or not _spec_by_id.has(action_id):
		return {"ok": false, "error": "Unknown action or slot.", "action": String(action_id), "slot": slot}
	if _registry == null:
		return {"ok": false, "error": "Input binding registry is unavailable.", "replayed": false}
	var fingerprint := _request_fingerprint("clear", action_id, slot, null, 0, confirmed)
	var replay := _replayed_request(request_id, fingerprint)
	if not replay.is_empty():
		return replay
	var result := _registry.clear_binding(
		action_id,
		slot,
		confirmed
	)
	result = _decorate_result(result, action_id, slot, request_id, false)
	return _remember_request(request_id, fingerprint, result)


func restore_defaults(request_id: StringName = &"") -> Dictionary:
	if not _valid_request_id(request_id):
		return {"ok": false, "error": "request_id_exceeds_bound", "replayed": false}
	if _registry == null:
		return {"ok": false, "error": "Input binding registry is unavailable.", "replayed": false}
	var fingerprint := "restore_defaults|" + String(request_id)
	var replay := _replayed_request(request_id, fingerprint)
	if not replay.is_empty():
		return replay
	var result := _registry.restore_defaults()
	result = _decorate_result(result, &"", -1, request_id, false)
	return _remember_request(request_id, fingerprint, result)


func restore_action_defaults(action_id: StringName, request_id: StringName = &"") -> Dictionary:
	if not _valid_request_id(request_id):
		return {"ok": false, "error": "request_id_exceeds_bound", "replayed": false}
	if not _spec_by_id.has(action_id):
		return {"ok": false, "error": "Unknown action.", "action": String(action_id)}
	if _registry == null:
		return {"ok": false, "error": "Input binding registry is unavailable.", "replayed": false}
	var fingerprint := "restore_action_defaults|" + String(action_id)
	var replay := _replayed_request(request_id, fingerprint)
	if not replay.is_empty():
		return replay
	var result := _registry.restore_action_defaults(action_id)
	result = _decorate_result(result, action_id, -1, request_id, false)
	return _remember_request(request_id, fingerprint, result)


func preview_conflicts(action_id: StringName, slot: int, candidate: CommonUIBinding) -> Array[Dictionary]:
	if _registry == null:
		return [{"action": String(action_id), "slot": slot, "protected": true, "error": "Input binding registry is unavailable."}]
	var validation := _validate_candidate(action_id, slot, candidate)
	if not bool(validation.get("ok", false)):
		return [{"action": String(action_id), "slot": slot, "protected": true, "error": validation.get("error", "invalid_candidate")}]
	var result: Array[Dictionary] = []
	for conflict_variant in _registry.find_conflicts(
		action_id,
		slot,
		validation["binding"] as CommonUIBinding
	):
		result.append((conflict_variant as Dictionary).duplicate(true))
	return result


func activate_context(context_id: StringName, priority: int = -1, source: StringName = &"") -> ZerkovInputContextToken:
	if not _valid_context(context_id) or String(source).length() > MAX_CONTEXT_SOURCE_LENGTH \
			or _runtime == null or (_contexts.size() >= MAX_CONTEXTS and not _contexts.has(context_id)):
		return null
	if _contexts.has(context_id):
		var existing: Dictionary = _contexts[context_id]
		var existing_token := existing.get("token") as ZerkovInputContextToken
		if existing_token != null and existing_token.is_active():
			return existing_token
		_release_context_entry(context_id)
	var resolved_priority := priority if priority >= 0 else _default_priority(context_id)
	_next_generation += 1
	var handle := _runtime.push_context(context_id, resolved_priority, 0)
	if handle == null:
		return null
	var token := CONTEXT_TOKEN.new() as ZerkovInputContextToken
	token.configure(self, context_id, _next_generation, resolved_priority, source)
	_contexts[context_id] = {
		"handle": handle,
		"token": token,
		"priority": resolved_priority,
		"generation": _next_generation,
		"source": source,
		"manual_suspended": false,
	}
	_apply_context_priority()
	_publish_contexts()
	return token


func release_context_token(token: ZerkovInputContextToken) -> bool:
	if token == null or not _contexts.has(token.context_id):
		return false
	var entry: Dictionary = _contexts[token.context_id]
	if int(entry.get("generation", -1)) != token.generation or entry.get("token") != token:
		return false
	_release_context_entry(token.context_id)
	_apply_context_priority()
	_publish_contexts()
	return true


func is_context_token_active(token: ZerkovInputContextToken) -> bool:
	if token == null or not _contexts.has(token.context_id):
		return false
	var entry: Dictionary = _contexts[token.context_id]
	var handle := entry.get("handle") as CommonUIContextHandle
	return entry.get("token") == token and int(entry.get("generation", -1)) == token.generation and handle != null \
			and handle.is_active()


func set_context_suspended(context_id: StringName, suspended: bool) -> bool:
	if not _contexts.has(context_id):
		return false
	var entry: Dictionary = _contexts[context_id]
	entry["manual_suspended"] = suspended
	_contexts[context_id] = entry
	_apply_context_priority()
	_publish_contexts()
	return true


func context_snapshot() -> Array:
	var result: Array[Dictionary] = []
	for context_id_variant in _contexts.keys():
		var context_id: StringName = context_id_variant
		var entry: Dictionary = _contexts[context_id]
		var handle := entry.get("handle") as CommonUIContextHandle
		result.append({
			"context": String(context_id),
			"priority": int(entry.get("priority", 0)),
			"generation": int(entry.get("generation", 0)),
			"source": String(entry.get("source", &"")),
			"active": handle != null and handle.is_active(),
			"suspended": handle != null and handle.is_suspended(),
		})
	result.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		if int(left["priority"]) != int(right["priority"]):
			return int(left["priority"]) > int(right["priority"])
		return str(left["context"]) < str(right["context"])
	)
	return result


func transition_for_route(route: String, role: String) -> void:
	if role == "hud":
		_activate_role(ACTIONS.GAMEPLAY_CONTEXT, ACTIONS.UI_CONTEXT, route)
	else:
		_activate_role(ACTIONS.UI_CONTEXT, ACTIONS.GAMEPLAY_CONTEXT, route)


func activate_modal(source: StringName = &"modal") -> ZerkovInputContextToken:
	return activate_context(ACTIONS.MODAL_CONTEXT, MODAL_PRIORITY, source)


func activate_developer(source: StringName = &"developer") -> ZerkovInputContextToken:
	return activate_context(ACTIONS.DEVELOPER_CONTEXT, DEVELOPER_PRIORITY, source)


func persistence_error_state() -> String:
	return last_persistence_error


func _activate_role(active_id: StringName, lower_id: StringName, source: String) -> void:
	if not _contexts.has(active_id):
		activate_context(active_id, -1, StringName(source))
	if _contexts.has(lower_id):
		release_context_token((_contexts[lower_id].get("token") as ZerkovInputContextToken))


func _release_context_entry(context_id: StringName) -> void:
	if not _contexts.has(context_id):
		return
	var entry: Dictionary = _contexts[context_id]
	var handle := entry.get("handle") as CommonUIContextHandle
	if handle != null:
		handle.release()
	_contexts.erase(context_id)


func _apply_context_priority() -> void:
	var active: Array[Dictionary] = []
	for context_id_variant in _contexts.keys():
		var context_id: StringName = context_id_variant
		var entry: Dictionary = _contexts[context_id]
		active.append({"id": context_id, "priority": int(entry.get("priority", 0)), "entry": entry})
	active.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		if int(left["priority"]) != int(right["priority"]):
			return int(left["priority"]) > int(right["priority"])
		return String(left["id"]) < String(right["id"])
	)
	for index in range(active.size()):
		var item: Dictionary = active[index]
		var entry: Dictionary = item["entry"]
		var handle := entry.get("handle") as CommonUIContextHandle
		if handle == null:
			continue
		var should_suspend := bool(entry.get("manual_suspended", false)) or index > 0
		handle.set_suspended(should_suspend)


func _publish_contexts() -> void:
	var snapshot := context_snapshot()
	contexts_published.emit(snapshot.duplicate(true))


func _publish_bindings() -> void:
	if _registry == null:
		return
	var snapshot := active_bindings_snapshot()
	bindings_published.emit(snapshot.duplicate(true))


func _on_bindings_changed() -> void:
	_publish_bindings()


func _on_binding_error(message: String) -> void:
	last_persistence_error = message
	persistence_error.emit(message)


func _on_modality_changed(modality: int, device: int) -> void:
	modality_changed.emit(modality, device)
	_publish_bindings()


func _index_specs() -> void:
	_spec_by_id.clear()
	for spec_variant in _specs:
		var spec: Dictionary = spec_variant
		_spec_by_id[spec["id"] as StringName] = spec


func _validate_specs() -> String:
	if ACTIONS.glyph_metadata().size() > ACTIONS.MAX_GLYPH_IDS:
		return "Zerkov input catalog exceeds its bounded glyph metadata count."
	var seen: Dictionary = {}
	for spec_variant in _specs:
		var spec: Dictionary = spec_variant
		var action_id: StringName = spec.get("id", &"")
		if action_id == &"" or not String(action_id).begins_with("common_ui/"):
			return "Zerkov input catalog contains an invalid action identifier."
		if seen.has(action_id):
			return "Zerkov input catalog contains a duplicate action identifier."
		seen[action_id] = true
		var bindings: Array = spec.get("bindings", [])
		if bindings.is_empty() or bindings.size() > ACTIONS.MAX_BINDINGS_PER_ACTION:
			return "Zerkov input catalog contains an invalid binding count."
		if spec.get("context", &"") not in [ACTIONS.GAMEPLAY_CONTEXT, ACTIONS.UI_CONTEXT]:
			return "Zerkov input catalog contains an invalid input context."
		for binding_variant in bindings:
			var binding: Dictionary = binding_variant
			if not ACTIONS.has_glyph(binding.get("glyph", &"")):
				return "Zerkov input catalog contains unknown glyph metadata."
	return ""


func _validate_candidate(action_id: StringName, slot: int, candidate: CommonUIBinding) -> Dictionary:
	if not _spec_by_id.has(action_id):
		return {"ok": false, "error": "Unknown or forged action identifier."}
	if not _valid_slot(slot):
		return {"ok": false, "error": "Binding slot is outside the supported bound."}
	if candidate == null or not candidate.is_valid_binding():
		return {"ok": false, "error": "Candidate binding is missing or unusable."}
	var clone := _clone_binding(candidate)
	if clone == null or not clone.is_valid_binding():
		return {"ok": false, "error": "Candidate binding could not be detached safely."}
	clone.set_slot(slot)
	if clone.get_code() < 0 or clone.get_code() > 2048:
		return {"ok": false, "error": "Candidate binding code exceeds the supported bound."}
	var glyph := clone.get_glyph_id()
	if glyph == &"":
		clone.set_glyph_id(_fallback_glyph_for_kind(clone.get_device_kind()))
	elif not ACTIONS.has_glyph(glyph):
		return {"ok": false, "error": "Candidate glyph metadata is unknown or forged."}
	return {"ok": true, "binding": clone}


func _fallback_glyph_for_kind(kind: int) -> StringName:
	match kind:
		CommonUIBinding.DEVICE_KEYBOARD: return &"glyph_unknown"
		CommonUIBinding.DEVICE_MOUSE: return &"glyph_unknown"
		CommonUIBinding.DEVICE_GAMEPAD_BUTTON, CommonUIBinding.DEVICE_GAMEPAD_AXIS: return &"pad_generic"
	return &"glyph_unknown"


func _clone_binding(binding: CommonUIBinding) -> CommonUIBinding:
	if binding == null:
		return null
	var clone := CommonUIBinding.new()
	clone.set_device_kind(binding.get_device_kind())
	clone.set_slot(binding.get_slot())
	clone.set_code(binding.get_code())
	clone.set_axis_direction(binding.get_axis_direction())
	clone.set_dead_zone(binding.get_dead_zone())
	clone.set_shift_pressed(binding.is_shift_pressed())
	clone.set_ctrl_pressed(binding.is_ctrl_pressed())
	clone.set_alt_pressed(binding.is_alt_pressed())
	clone.set_meta_pressed(binding.is_meta_pressed())
	clone.set_glyph_id(binding.get_glyph_id())
	return clone


func _decorate_result(result: Dictionary, action_id: StringName, slot: int, request_id: StringName, replayed: bool) -> Dictionary:
	var detached := result.duplicate(true)
	detached["action"] = String(action_id)
	detached["slot"] = slot
	detached["request_id"] = String(request_id)
	detached["definition_version"] = definition_version
	detached["replayed"] = replayed
	return detached


func _request_fingerprint(operation: String, action_id: StringName, slot: int, candidate: CommonUIBinding, policy: int, confirmed: bool) -> String:
	var descriptor := ACTIONS.binding_descriptor(candidate, slot)
	return _canonical_json({
		"operation": operation,
		"action": String(action_id),
		"slot": slot,
		"candidate": descriptor,
		"policy": policy,
		"confirmed": confirmed,
	})


func _replayed_request(request_id: StringName, fingerprint: String) -> Dictionary:
	if request_id == &"" or not _request_history.has(String(request_id)):
		return {}
	var previous: Dictionary = _request_history[String(request_id)]
	if str(previous.get("fingerprint", "")) != fingerprint:
		return {"ok": false, "error": "request_id_reuse_conflict", "request_id": String(request_id), "replayed": false}
	var result: Dictionary = previous.get("result", {}).duplicate(true)
	result["replayed"] = true
	return result


func _remember_request(request_id: StringName, fingerprint: String, result: Dictionary) -> Dictionary:
	if request_id == &"":
		return result.duplicate(true)
	var key := String(request_id)
	if not _request_history.has(key):
		_request_order.append(key)
	_request_history[key] = {"fingerprint": fingerprint, "result": result.duplicate(true)}
	while _request_order.size() > MAX_REQUEST_HISTORY:
		var expired: String = _request_order.pop_front()
		_request_history.erase(expired)
	return result.duplicate(true)


func _valid_slot(slot: int) -> bool:
	return slot == CommonUIBinding.SLOT_PRIMARY or slot == CommonUIBinding.SLOT_SECONDARY


func _valid_policy(policy: int) -> bool:
	return policy == CommonInputBindingRegistry.CONFLICT_REJECT \
			or policy == CommonInputBindingRegistry.CONFLICT_REPLACE \
			or policy == CommonInputBindingRegistry.CONFLICT_ALLOW_DUPLICATE


func _valid_request_id(request_id: StringName) -> bool:
	return String(request_id).length() <= MAX_REQUEST_ID_LENGTH


func _valid_context(context_id: StringName) -> bool:
	return context_id in [ACTIONS.GAMEPLAY_CONTEXT, ACTIONS.UI_CONTEXT, ACTIONS.MODAL_CONTEXT, ACTIONS.DEVELOPER_CONTEXT]


func _default_priority(context_id: StringName) -> int:
	match context_id:
		ACTIONS.GAMEPLAY_CONTEXT: return GAMEPLAY_PRIORITY
		ACTIONS.UI_CONTEXT: return UI_PRIORITY
		ACTIONS.MODAL_CONTEXT: return MODAL_PRIORITY
		ACTIONS.DEVELOPER_CONTEXT: return DEVELOPER_PRIORITY
	return 0


func _fail(message: String) -> bool:
	last_error = message
	push_error(message)
	return false


func _canonical_json(value: Variant) -> String:
	if value is Dictionary:
		var keys: Array[String] = []
		for key in (value as Dictionary).keys():
			keys.append(str(key))
		keys.sort()
		var members: Array[String] = []
		for key in keys:
			members.append(JSON.stringify(key) + ":" + _canonical_json((value as Dictionary).get(key)))
		return "{" + ",".join(members) + "}"
	if value is Array:
		var values: Array[String] = []
		for item in value:
			values.append(_canonical_json(item))
		return "[" + ",".join(values) + "]"
	if value is StringName:
		return JSON.stringify(String(value))
	return JSON.stringify(value)
