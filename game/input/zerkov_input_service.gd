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
const MAX_CONTEXT_LEASES: int = 16
const PERSISTENCE_PATH: String = "user://common_ui_bindings.json"

# Priorities are project-owned capabilities, not an arbitrary caller-owned
# z-order.  A caller may request the default for a known context (or -1), but
# cannot manufacture a priority that outranks modal/developer routing.
const GAMEPLAY_PRIORITY: int = 0
const UI_PRIORITY: int = 50
const MODAL_PRIORITY: int = 100
const DEVELOPER_PRIORITY: int = 150
const MAX_PROJECT_PRIORITY: int = DEVELOPER_PRIORITY


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
var _next_capability: int = 0
var _route_tokens: Dictionary = {}


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
		if finding.get("severity") == CommonUIActionValidator.SEVERITY_WARNING \
				and not _is_allowed_framework_finding(finding):
			return _fail("Input configuration failed collision validation: " + str(finding.get("message", "")))

	# The runtime setter configures the native registry, loads the fixed
	# user:// document, and applies its InputMap projection.  Preflight the
	# selected candidate first.  If it is malformed/forged, a definition-version
	# sentinel makes the native load fail closed while preserving the same live
	# defaults; the real version is restored on the shared Resource immediately
	# after configuration.  InputMap is never read back as canonical state.
	var persistence_preflight := _validate_persistence_candidate_on_disk()
	var persistence_error := str(persistence_preflight.get("error", ""))
	var guard_persistence := not persistence_error.is_empty()
	if guard_persistence:
		_config.set_definition_version(_persistence_guard_version(persistence_preflight))
	_runtime.set_input_config(_config)
	if guard_persistence:
		_config.set_definition_version(definition_version)
	_registry = _runtime.get_binding_registry()
	if _registry == null:
		return _fail("CommonUI did not expose a binding registry after configuration.")
	if not _registry.binding_error.is_connected(_on_binding_error):
		_registry.binding_error.connect(_on_binding_error)
	if not _registry.bindings_changed.is_connected(_on_bindings_changed):
		_registry.bindings_changed.connect(_on_bindings_changed)
	if guard_persistence:
		_on_binding_error(persistence_error)
	else:
		# set_input_config performs the first load before the signal connection is
		# possible. A second load observes the selected valid candidate and keeps the
		# service's publication synchronized with the authoritative registry.
		if not _registry.load_overrides():
			return _fail("CommonUI could not reload the validated binding document.")
		last_persistence_error = ""
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
	if binding == null or _registry == null:
		return &"glyph_unbound"
	var device_name := _device_name_for_family(device_family)
	if device_family == &"":
		device_name = _runtime.get_active_device_name() if _runtime != null else ""
	var resolved := _registry.resolve_glyph(action_id, slot, device_name)
	# The native resolver is authoritative.  A missing metadata id is still
	# rendered deterministically, but is never replaced with a parallel game
	# resolver result (which could disagree for axes, triggers, sticks, or D-pad).
	if resolved != &"" and ACTIONS.has_glyph(resolved):
		return resolved
	return &"glyph_unknown"


func active_device_family() -> StringName:
	if _runtime == null:
		return ACTIONS.FAMILY_KEYBOARD_MOUSE
	return ACTIONS.family_for_device_name(_runtime.get_active_device_name())


func _device_name_for_family(family: StringName) -> String:
	match family:
		ACTIONS.FAMILY_XBOX: return "xbox"
		ACTIONS.FAMILY_PLAYSTATION: return "playstation"
		ACTIONS.FAMILY_SWITCH: return "switch"
		ACTIONS.FAMILY_GENERIC_GAMEPAD: return "generic gamepad"
		ACTIONS.FAMILY_UNKNOWN: return "unrecognised device"
	return ""


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


## Reload the fixed persistence candidate through the same game-owned
## validation gate used during installation.  Consumers must use this seam
## instead of calling the native registry directly so malformed or forged
## documents cannot bypass the catalog's bounds, glyph metadata, or collision
## policy.
func reload_overrides() -> bool:
	if _registry == null or _config == null:
		return false
	var preflight := _validate_persistence_candidate_on_disk()
	var error := str(preflight.get("error", ""))
	if not error.is_empty():
		_on_binding_error(error)
		return false
	var loaded := _registry.load_overrides()
	if not loaded and last_persistence_error.is_empty():
		_on_binding_error("Saved bindings could not be loaded; active bindings remain unchanged.")
	elif loaded:
		last_persistence_error = ""
	return loaded


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
	var reserved := _reserve_request(request_id, fingerprint)
	if not reserved.is_empty():
		return reserved
	var validation := _validate_candidate(action_id, slot, candidate)
	if not bool(validation.get("ok", false)):
		return _finalize_request(request_id, fingerprint, validation)
	var result := _registry.rebind(
		action_id,
		slot,
		validation["binding"] as CommonUIBinding,
		policy,
		confirmed
	)
	result = _decorate_result(result, action_id, slot, request_id, false)
	return _finalize_request(request_id, fingerprint, result)


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
	var reserved := _reserve_request(request_id, fingerprint)
	if not reserved.is_empty():
		return reserved
	var result := _registry.clear_binding(
		action_id,
		slot,
		confirmed
	)
	result = _decorate_result(result, action_id, slot, request_id, false)
	return _finalize_request(request_id, fingerprint, result)


func restore_defaults(request_id: StringName = &"") -> Dictionary:
	if not _valid_request_id(request_id):
		return {"ok": false, "error": "request_id_exceeds_bound", "replayed": false}
	if _registry == null:
		return {"ok": false, "error": "Input binding registry is unavailable.", "replayed": false}
	var fingerprint := "restore_defaults|" + String(request_id)
	var reserved := _reserve_request(request_id, fingerprint)
	if not reserved.is_empty():
		return reserved
	var result := _registry.restore_defaults()
	result = _decorate_result(result, &"", -1, request_id, false)
	return _finalize_request(request_id, fingerprint, result)


func restore_action_defaults(action_id: StringName, request_id: StringName = &"") -> Dictionary:
	if not _valid_request_id(request_id):
		return {"ok": false, "error": "request_id_exceeds_bound", "replayed": false}
	if not _spec_by_id.has(action_id):
		return {"ok": false, "error": "Unknown action.", "action": String(action_id)}
	if _registry == null:
		return {"ok": false, "error": "Input binding registry is unavailable.", "replayed": false}
	var fingerprint := "restore_action_defaults|" + String(action_id)
	var reserved := _reserve_request(request_id, fingerprint)
	if not reserved.is_empty():
		return reserved
	var result := _registry.restore_action_defaults(action_id)
	result = _decorate_result(result, action_id, -1, request_id, false)
	return _finalize_request(request_id, fingerprint, result)


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
			or _runtime == null or (_contexts.size() >= MAX_CONTEXTS and not _contexts.has(context_id)) \
			or not _valid_priority(context_id, priority) or _context_lease_count() >= MAX_CONTEXT_LEASES:
		return null
	var resolved_priority := priority if priority >= 0 else _default_priority(context_id)
	var entry: Dictionary
	if _contexts.has(context_id):
		entry = _contexts[context_id]
		if int(entry.get("priority", -1)) != resolved_priority:
			return null
	else:
		_next_generation += 1
		var handle := _runtime.push_context(context_id, resolved_priority, 0)
		if handle == null:
			return null
		entry = {
			"handle": handle,
			"priority": resolved_priority,
			"generation": _next_generation,
			"manual_suspended": false,
			"leases": {},
		}
	_next_capability += 1
	var token := CONTEXT_TOKEN.new() as ZerkovInputContextToken
	token.configure(self, context_id, int(entry["generation"]), resolved_priority, source, _next_capability)
	var leases: Dictionary = entry.get("leases", {})
	leases[_next_capability] = token
	entry["leases"] = leases
	_contexts[context_id] = entry
	_apply_context_priority()
	_publish_contexts()
	return token


func release_context_token(token: ZerkovInputContextToken) -> bool:
	if token == null:
		return false
	# Do not trust caller-mutated context/generation/capability fields to locate
	# the lease. The service owns the identity relation and scans the bounded
	# lease table for the exact token object, so a forged or edited capability
	# cannot release a peer or a replacement context.
	var found_context: StringName = &""
	var found_capability: int = 0
	var found_entry: Dictionary = {}
	for context_id_variant in _contexts.keys():
		var context_id: StringName = context_id_variant
		var candidate_entry: Dictionary = _contexts[context_id]
		var candidate_leases: Dictionary = candidate_entry.get("leases", {})
		for capability_variant in candidate_leases.keys():
			var capability_id := int(capability_variant)
			if candidate_leases[capability_id] != token:
				continue
			found_context = context_id
			found_capability = capability_id
			found_entry = candidate_entry
			break
		if found_capability != 0:
			break
	if found_capability == 0:
		return false
	var leases: Dictionary = found_entry.get("leases", {})
	leases.erase(found_capability)
	token._invalidate()
	found_entry["leases"] = leases
	if leases.is_empty():
		var handle := found_entry.get("handle") as CommonUIContextHandle
		if handle != null:
			handle.release()
		_contexts.erase(found_context)
		for route_context_variant in _route_tokens.keys():
			if route_context_variant == found_context:
				_route_tokens.erase(route_context_variant)
	else:
		_contexts[found_context] = found_entry
	_apply_context_priority()
	_publish_contexts()
	return true


func is_context_token_active(token: ZerkovInputContextToken) -> bool:
	if token == null:
		return false
	for entry_variant in _contexts.values():
		var entry: Dictionary = entry_variant
		var handle := entry.get("handle") as CommonUIContextHandle
		if handle == null or not handle.is_active():
			continue
		for lease_variant in (entry.get("leases", {}) as Dictionary).values():
			if lease_variant == token:
				return true
	return false


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
		var leases: Dictionary = entry.get("leases", {})
		var sources: Array[String] = []
		for lease_variant in leases.values():
			var lease := lease_variant as ZerkovInputContextToken
			if lease != null:
				sources.append(String(lease.source))
		sources.sort()
		result.append({
			"context": String(context_id),
			"priority": int(entry.get("priority", 0)),
			"generation": int(entry.get("generation", 0)),
			"source": sources[0] if not sources.is_empty() else "",
			"lease_count": leases.size(),
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
	var active_token := _route_tokens.get(active_id, null) as ZerkovInputContextToken
	if active_token == null or not active_token.is_active():
		_route_tokens.erase(active_id)
		active_token = activate_context(active_id, -1, StringName("route/" + source))
		if active_token != null:
			_route_tokens[active_id] = active_token
	var lower_token := _route_tokens.get(lower_id, null) as ZerkovInputContextToken
	if lower_token != null:
		lower_token.release()
		_route_tokens.erase(lower_id)


func _release_context_entry(context_id: StringName) -> void:
	if not _contexts.has(context_id):
		return
	var entry: Dictionary = _contexts[context_id]
	var leases: Dictionary = entry.get("leases", {})
	for lease_variant in leases.values():
		var lease := lease_variant as ZerkovInputContextToken
		if lease != null:
			lease._invalidate()
	var handle := entry.get("handle") as CommonUIContextHandle
	if handle != null:
		handle.release()
	_contexts.erase(context_id)
	_route_tokens.erase(context_id)


func _context_lease_count() -> int:
	var count := 0
	for entry_variant in _contexts.values():
		var entry: Dictionary = entry_variant
		count += (entry.get("leases", {}) as Dictionary).size()
	return count


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
		var common_bindings: Array = spec.get("common_bindings", [])
		if common_bindings.is_empty() or common_bindings.size() > 2:
			return "Zerkov input catalog contains an invalid CommonUI projection count."
		if spec.get("context", &"") not in [ACTIONS.GAMEPLAY_CONTEXT, ACTIONS.UI_CONTEXT]:
			return "Zerkov input catalog contains an invalid input context."
		for binding_variant in bindings + common_bindings:
			if not binding_variant is Dictionary:
				return "Zerkov input catalog contains a malformed binding descriptor."
			var binding: Dictionary = binding_variant
			var typed := _binding_from_descriptor(binding)
			var binding_error := _validate_binding_values(typed, true)
			if not binding_error.is_empty():
				return "Zerkov input catalog contains an invalid default: " + binding_error
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
	var shape_error := _validate_binding_values(clone, false)
	if not shape_error.is_empty():
		return {"ok": false, "error": shape_error}
	var glyph := clone.get_glyph_id()
	if glyph == &"":
		clone.set_glyph_id(_fallback_glyph_for_kind(clone.get_device_kind()))
	elif not ACTIONS.has_glyph(glyph) or not _glyph_compatible(clone.get_device_kind(), glyph):
		return {"ok": false, "error": "Candidate glyph metadata is unknown, forged, or incompatible with its device kind."}
	var ui_collision := _ui_collision_owner(action_id, clone)
	if not ui_collision.is_empty():
		return {"ok": false, "error": ui_collision}
	return {"ok": true, "binding": clone}


func _binding_from_descriptor(descriptor: Dictionary) -> CommonUIBinding:
	var binding := CommonUIBinding.new()
	if not descriptor.has("device_kind") or not descriptor.has("code") \
			or not descriptor.has("axis_direction") or not descriptor.has("glyph"):
		return null
	binding.set_device_kind(int(descriptor.get("device_kind", -1)))
	binding.set_code(int(descriptor.get("code", -1)))
	binding.set_axis_direction(int(descriptor.get("axis_direction", -1)))
	binding.set_dead_zone(float(descriptor.get("dead_zone", 0.25)))
	binding.set_shift_pressed(bool(descriptor.get("shift", false)))
	binding.set_ctrl_pressed(bool(descriptor.get("ctrl", false)))
	binding.set_alt_pressed(bool(descriptor.get("alt", false)))
	binding.set_meta_pressed(bool(descriptor.get("meta", false)))
	binding.set_glyph_id(StringName(str(descriptor.get("glyph", ""))))
	return binding


func _validate_binding_values(binding: CommonUIBinding, require_glyph: bool) -> String:
	if binding == null:
		return "binding is missing."
	var kind := int(binding.get_device_kind())
	var code := int(binding.get_code())
	if kind < CommonUIBinding.DEVICE_KEYBOARD or kind > CommonUIBinding.DEVICE_TOUCH:
		return "device kind is outside the supported device-family bound."
	# Keyboard codes are Godot Key values, not ASCII-only values: special keys
	# use the high Key namespace (for example Escape/F24). Keep the signed
	# integer bound while validating each other device against its own range.
	match kind:
		CommonUIBinding.DEVICE_KEYBOARD:
			if code <= 0 or code > 2147483647:
				return "keyboard code is outside the Godot Key range."
		CommonUIBinding.DEVICE_MOUSE:
			if code <= 0 or code > 9:
				return "mouse button code is outside the Godot mouse-button range."
		CommonUIBinding.DEVICE_GAMEPAD_BUTTON:
			if code < 0 or code > 127:
				return "gamepad button code is outside the Godot joy-button range."
		CommonUIBinding.DEVICE_GAMEPAD_AXIS:
			if code < 0 or code > 31:
				return "gamepad axis code is outside the Godot joy-axis range."
			if binding.get_axis_direction() not in [CommonUIBinding.AXIS_DIRECTION_POSITIVE, CommonUIBinding.AXIS_DIRECTION_NEGATIVE]:
				return "gamepad axis bindings require a positive or negative direction."
		CommonUIBinding.DEVICE_TOUCH:
			if code < 0 or code > 31:
				return "touch index is outside the supported bound."
	if kind != CommonUIBinding.DEVICE_GAMEPAD_AXIS \
			and binding.get_axis_direction() != CommonUIBinding.AXIS_DIRECTION_NONE:
		return "only gamepad axes may declare an axis direction."
	var dead_zone := float(binding.get_dead_zone())
	if not is_finite(dead_zone) or dead_zone < 0.0 or dead_zone > 1.0:
		return "dead zone is outside the inclusive [0,1] bound."
	var glyph := binding.get_glyph_id()
	if require_glyph and (glyph == &"" or not ACTIONS.has_glyph(glyph)):
		return "default binding glyph metadata is unknown."
	if glyph != &"" and not ACTIONS.has_glyph(glyph):
		return "binding glyph metadata is unknown or forged."
	if glyph != &"" and not _glyph_compatible(kind, glyph):
		return "binding glyph metadata is incompatible with its device kind."
	return ""


func _glyph_compatible(device_kind: int, glyph: StringName) -> bool:
	var metadata: Variant = ACTIONS.glyph_metadata().get(glyph, {})
	if not metadata is Dictionary:
		return false
	var family := str((metadata as Dictionary).get("family", ""))
	match device_kind:
		CommonUIBinding.DEVICE_KEYBOARD:
			return family in ["keyboard", "generic"]
		CommonUIBinding.DEVICE_MOUSE:
			return family in ["mouse", "keyboard", "generic"]
		CommonUIBinding.DEVICE_GAMEPAD_BUTTON, CommonUIBinding.DEVICE_GAMEPAD_AXIS:
			return family in ["gamepad", "xbox", "playstation", "switch", "generic"]
		CommonUIBinding.DEVICE_TOUCH:
			return family == "generic"
	return false


func _is_allowed_framework_finding(finding: Dictionary) -> bool:
	# CommonUI's Confirm action intentionally shares Enter with Godot's
	# ui_accept focus action; the accepted navigation contract depends on that
	# framework convention. Every other warning (including a game action's
	# ui_* collision) is installation-fatal rather than silently discarded.
	var action_id: StringName = finding.get("action", &"") as StringName
	var message := str(finding.get("message", ""))
	return (action_id == ACTIONS.UI_CONFIRM and message.contains("'ui_accept'")) \
			or (action_id == ACTIONS.UI_BACK and message.contains("'ui_cancel'"))


func _validate_persistence_candidate_on_disk() -> Dictionary:
	var path := _persistence_candidate_path()
	if path.is_empty():
		return {"path": "", "error": ""}
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		return {"path": path, "error": "Saved bindings are empty or unreadable; active bindings remain unchanged."}
	var parsed: Variant = JSON.parse_string(bytes.get_string_from_utf8())
	if not parsed is Dictionary:
		return {"path": path, "error": "Saved bindings are malformed; active bindings remain unchanged."}
	var document: Dictionary = parsed
	if not _has_exact_keys(document, ["format_version", "definition_version", "overrides"]):
		return {"path": path, "error": "Saved bindings document fields are malformed; active bindings remain unchanged."}
	var format_value := _integer_value(document.get("format_version", null))
	var definition_value := _integer_value(document.get("definition_version", null))
	if not bool(format_value.get("ok", false)) or not bool(definition_value.get("ok", false)) \
			or typeof(document.get("overrides", null)) != TYPE_ARRAY:
		return {"path": path, "error": "Saved bindings document fields are malformed; active bindings remain unchanged."}
	var format_version := int(format_value["value"])
	if format_version <= 0 or format_version > persistence_format_version:
		return {"path": path, "error": "Saved bindings use an unsupported format version; active bindings remain unchanged."}
	if int(definition_value["value"]) != definition_version:
		return {"path": path, "error": "Saved bindings target a different definition version; active bindings remain unchanged."}

	var entries: Array = document["overrides"]
	if entries.size() > _specs.size() * 2:
		return {"path": path, "error": "Saved bindings contain too many override entries; active bindings remain unchanged."}
	var staged := _default_binding_matrix()
	var seen_slots: Dictionary = {}
	for index in range(entries.size()):
		var raw_entry: Variant = entries[index]
		if not raw_entry is Dictionary:
			return {"path": path, "error": "Saved binding entry %d is malformed; active bindings remain unchanged." % index}
		var entry: Dictionary = raw_entry
		var cleared_value: Variant = entry.get("cleared", null)
		if typeof(cleared_value) != TYPE_BOOL:
			return {"path": path, "error": "Saved binding entry %d is malformed; active bindings remain unchanged." % index}
		var cleared := bool(cleared_value)
		var expected_keys := ["action", "slot", "cleared"] if cleared \
				else ["action", "slot", "cleared", "binding"]
		if not _has_exact_keys(entry, expected_keys) or typeof(entry.get("action", null)) != TYPE_STRING:
			return {"path": path, "error": "Saved binding entry %d is malformed; active bindings remain unchanged." % index}
		var slot_value := _integer_value(entry.get("slot", null))
		if not bool(slot_value.get("ok", false)):
			return {"path": path, "error": "Saved binding entry %d is malformed; active bindings remain unchanged." % index}
		var slot := int(slot_value["value"])
		var action_id := StringName(str(entry.get("action", "")))
		if action_id == &"" or not _valid_slot(slot) or not _spec_by_id.has(action_id):
			return {"path": path, "error": "Saved binding entry %d references an unknown action or slot; active bindings remain unchanged." % index}
		var slot_key := _binding_matrix_key(action_id, slot)
		if seen_slots.has(slot_key):
			return {"path": path, "error": "Saved binding entry %d duplicates an action slot; active bindings remain unchanged." % index}
		seen_slots[slot_key] = true
		if cleared:
			staged[slot_key] = null
			continue
		var raw_binding: Variant = entry.get("binding", null)
		if not raw_binding is Dictionary:
			return {"path": path, "error": "Saved binding entry %d has a malformed binding; active bindings remain unchanged." % index}
		var binding_result := _binding_from_persistence_dictionary(raw_binding as Dictionary, slot)
		if not bool(binding_result.get("ok", false)):
			return {"path": path, "error": "Saved binding entry %d has an invalid binding: %s; active bindings remain unchanged." % [index, str(binding_result.get("error", "invalid"))]}
		var binding := binding_result["binding"] as CommonUIBinding
		var candidate_validation := _validate_candidate(action_id, slot, binding)
		if not bool(candidate_validation.get("ok", false)):
			return {"path": path, "error": "Saved binding entry %d is rejected: %s; active bindings remain unchanged." % [index, str(candidate_validation.get("error", "invalid"))]}
		staged[slot_key] = candidate_validation["binding"] as CommonUIBinding

	var protection_error := _validate_staged_protection(staged)
	if not protection_error.is_empty():
		return {"path": path, "error": protection_error + "; active bindings remain unchanged."}
	var collision_error := _validate_staged_collisions(staged)
	if not collision_error.is_empty():
		return {"path": path, "error": collision_error + "; active bindings remain unchanged."}
	return {"path": path, "error": ""}


func _persistence_candidate_path() -> String:
	# Match the native registry's fixed recovery precedence exactly. No caller
	# supplied path is ever opened or written by this service.
	for suffix in ["", ".bak", ".tmp"]:
		var candidate := PERSISTENCE_PATH + str(suffix)
		if FileAccess.file_exists(candidate):
			return candidate
	return ""


func _persistence_guard_version(preflight: Dictionary) -> int:
	# CommonUI's config Resource clamps versions to >=1. Choose a sentinel that
	# cannot equal the selected malformed candidate, even if an attacker forged a
	# different integer definition_version in that file.
	var guard := definition_version + 1
	var path := str(preflight.get("path", ""))
	if path.is_empty() or not FileAccess.file_exists(path):
		return guard
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if parsed is Dictionary:
		var raw_version: Variant = (parsed as Dictionary).get("definition_version", null)
		var parsed_version := _integer_value(raw_version)
		if bool(parsed_version.get("ok", false)) and int(parsed_version["value"]) == guard:
			guard += 1
	if guard < 1:
		guard = 1
	return guard


func _has_exact_keys(value: Dictionary, expected: Array) -> bool:
	if value.size() != expected.size():
		return false
	for key in expected:
		if not value.has(key):
			return false
	return true


func _integer_value(value: Variant) -> Dictionary:
	if typeof(value) == TYPE_INT:
		return {"ok": true, "value": int(value)}
	if typeof(value) != TYPE_FLOAT:
		return {"ok": false}
	var numeric := float(value)
	if not is_finite(numeric) or numeric != round(numeric) or numeric < -2147483648.0 or numeric > 2147483647.0:
		return {"ok": false}
	return {"ok": true, "value": int(numeric)}


func _binding_from_persistence_dictionary(data: Dictionary, slot: int) -> Dictionary:
	if not _has_exact_keys(data, ["device_kind", "code", "axis_direction", "dead_zone", "shift", "ctrl", "alt", "meta", "glyph"]):
		return {"ok": false, "error": "fields are malformed"}
	var dead_zone_value: Variant = data.get("dead_zone", null)
	if typeof(dead_zone_value) != TYPE_INT and typeof(dead_zone_value) != TYPE_FLOAT:
		return {"ok": false, "error": "dead zone is not numeric"}
	var dead_zone := float(dead_zone_value)
	# Validate the serialized value before CommonUIBinding's setter can clamp it;
	# otherwise a forged out-of-range document would be silently normalized into
	# an accepted binding instead of being rejected as malformed.
	if not is_finite(dead_zone) or dead_zone < 0.0 or dead_zone > 1.0:
		return {"ok": false, "error": "dead zone is outside the inclusive [0,1] bound"}
	for key in ["shift", "ctrl", "alt", "meta"]:
		if typeof(data.get(key, null)) != TYPE_BOOL:
			return {"ok": false, "error": "modifier field is not boolean"}
	if typeof(data.get("glyph", null)) != TYPE_STRING:
		return {"ok": false, "error": "glyph metadata is not a string"}
	var kind_value := _integer_value(data.get("device_kind", null))
	var code_value := _integer_value(data.get("code", null))
	var axis_value := _integer_value(data.get("axis_direction", null))
	if not bool(kind_value.get("ok", false)) or not bool(code_value.get("ok", false)) or not bool(axis_value.get("ok", false)):
		return {"ok": false, "error": "device code fields are not integral"}
	var glyph := StringName(str(data.get("glyph", "")))
	if glyph == &"" or not ACTIONS.has_glyph(glyph):
		return {"ok": false, "error": "glyph metadata is unknown or forged"}
	var binding := CommonUIBinding.new()
	binding.set_device_kind(int(kind_value["value"]))
	binding.set_code(int(code_value["value"]))
	binding.set_axis_direction(int(axis_value["value"]))
	binding.set_dead_zone(dead_zone)
	binding.set_shift_pressed(bool(data.get("shift", false)))
	binding.set_ctrl_pressed(bool(data.get("ctrl", false)))
	binding.set_alt_pressed(bool(data.get("alt", false)))
	binding.set_meta_pressed(bool(data.get("meta", false)))
	binding.set_glyph_id(glyph)
	binding.set_slot(slot)
	return {"ok": true, "binding": binding}


func _default_binding_matrix() -> Dictionary:
	var result: Dictionary = {}
	for spec_variant in _specs:
		var spec: Dictionary = spec_variant
		var action_id: StringName = spec["id"] as StringName
		result[_binding_matrix_key(action_id, CommonUIBinding.SLOT_PRIMARY)] = null
		result[_binding_matrix_key(action_id, CommonUIBinding.SLOT_SECONDARY)] = null
		var defaults: Array = spec.get("common_bindings", [])
		for index in range(mini(2, defaults.size())):
			var descriptor: Dictionary = defaults[index]
			result[_binding_matrix_key(action_id, CommonUIBinding.SLOT_PRIMARY if index == 0 else CommonUIBinding.SLOT_SECONDARY)] = _binding_from_descriptor(descriptor)
	return result


func _binding_matrix_key(action_id: StringName, slot: int) -> String:
	return String(action_id) + "|" + str(slot)


func _validate_staged_protection(staged: Dictionary) -> String:
	for spec_variant in _specs:
		var spec: Dictionary = spec_variant
		if int(spec.get("protection", CommonUIAction.PROTECTION_NONE)) == CommonUIAction.PROTECTION_NONE:
			continue
		var action_id: StringName = spec["id"] as StringName
		var primary: Variant = staged.get(_binding_matrix_key(action_id, CommonUIBinding.SLOT_PRIMARY), null)
		var secondary: Variant = staged.get(_binding_matrix_key(action_id, CommonUIBinding.SLOT_SECONDARY), null)
		if primary == null and secondary == null:
			return "Saved bindings would leave required action '%s' unbound" % action_id
	return ""


func _validate_staged_collisions(staged: Dictionary) -> String:
	var seen: Dictionary = {}
	for spec_variant in _specs:
		var spec: Dictionary = spec_variant
		var action_id: StringName = spec["id"] as StringName
		var context: StringName = spec.get("conflict_context", &"") as StringName
		for slot in [CommonUIBinding.SLOT_PRIMARY, CommonUIBinding.SLOT_SECONDARY]:
			var binding := staged.get(_binding_matrix_key(action_id, slot), null) as CommonUIBinding
			if binding == null:
				continue
			var signature := binding.get_signature()
			var prior_list: Array = seen.get(signature, [])
			for prior_variant in prior_list:
				var prior: Dictionary = prior_variant
				if _contexts_conflict(context, prior["context"] as StringName):
					return "Saved bindings conflict: '%s' slot %d and '%s' slot %d share '%s'" % [
						prior["action"], int(prior["slot"]), action_id, slot, signature]
			prior_list.append({"action": String(action_id), "slot": slot, "context": context})
			seen[signature] = prior_list
	return ""


func _contexts_conflict(left: StringName, right: StringName) -> bool:
	return left == &"" or right == &"" or left == right


func _ui_collision_owner(action_id: StringName, binding: CommonUIBinding) -> String:
	if binding == null or binding.get_device_kind() != CommonUIBinding.DEVICE_KEYBOARD:
		return ""
	# CommonUI Confirm/Enter is the only intentional framework overlap. Restrict
	# that exception to the authored unmodified Enter default; a caller cannot
	# use the framework action id to smuggle an arbitrary ui_* focus key into a
	# rebind.
	if action_id == ACTIONS.UI_CONFIRM and binding.get_code() == KEY_ENTER \
			and not binding.is_shift_pressed() and not binding.is_ctrl_pressed() \
			and not binding.is_alt_pressed() and not binding.is_meta_pressed():
		return ""
	for action in InputMap.get_actions():
		if not String(action).begins_with("ui_"):
			continue
		for event in InputMap.action_get_events(action):
			var key_event := event as InputEventKey
			if key_event == null:
				continue
			var code := int(key_event.physical_keycode if key_event.physical_keycode != 0 else key_event.keycode)
			if code == binding.get_code() \
					and key_event.shift_pressed == binding.is_shift_pressed() \
					and key_event.ctrl_pressed == binding.is_ctrl_pressed() \
					and key_event.alt_pressed == binding.is_alt_pressed() \
					and key_event.meta_pressed == binding.is_meta_pressed():
				return "Candidate key is already claimed by Godot built-in '%s'." % action
	return ""


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


func _reserve_request(request_id: StringName, fingerprint: String) -> Dictionary:
	if request_id == &"":
		return {}
	var key := String(request_id)
	if _request_history.has(key):
		var previous: Dictionary = _request_history[key]
		if str(previous.get("fingerprint", "")) != fingerprint:
			return {"ok": false, "error": "request_id_reuse_conflict", "request_id": key, "replayed": false}
		if bool(previous.get("reserved", false)):
			# Native registry mutations publish synchronously. A listener that
			# re-enters with the same id must see an in-flight reservation before
			# the outer mutation can commit, rather than nesting a second commit.
			return {"ok": false, "error": "request_id_in_flight", "request_id": key, "replayed": false}
		var result: Dictionary = previous.get("result", {}).duplicate(true)
		result["replayed"] = true
		return result
	while _request_order.size() >= MAX_REQUEST_HISTORY:
		var evicted := false
		for candidate_variant in _request_order:
			var candidate := str(candidate_variant)
			if not _request_history.has(candidate) or not bool(_request_history[candidate].get("reserved", false)):
				_request_order.erase(candidate)
				_request_history.erase(candidate)
				evicted = true
				break
		if not evicted:
			return {"ok": false, "error": "request_history_full", "request_id": key, "replayed": false}
	_request_order.append(key)
	_request_history[key] = {"fingerprint": fingerprint, "reserved": true, "result": {}}
	return {}


func _finalize_request(request_id: StringName, fingerprint: String, result: Dictionary) -> Dictionary:
	if request_id == &"":
		return result.duplicate(true)
	var key := String(request_id)
	_request_history[key] = {
		"fingerprint": fingerprint,
		"reserved": false,
		"result": result.duplicate(true),
	}
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


func _valid_priority(context_id: StringName, priority: int) -> bool:
	# -1 is the only caller-facing sentinel for the project-owned default. Do
	# not let arbitrary negative values smuggle a second priority convention
	# through the bounded context lease API.
	if priority == -1:
		return true
	if priority < 0:
		return false
	return priority <= MAX_PROJECT_PRIORITY and priority == _default_priority(context_id)


func _default_priority(context_id: StringName) -> int:
	match context_id:
		ACTIONS.GAMEPLAY_CONTEXT: return GAMEPLAY_PRIORITY
		ACTIONS.UI_CONTEXT: return UI_PRIORITY
		ACTIONS.MODAL_CONTEXT: return MODAL_PRIORITY
		ACTIONS.DEVELOPER_CONTEXT: return DEVELOPER_PRIORITY
	return 0


func _exit_tree() -> void:
	# Teardown owns every native handle, but each caller-owned token is also
	# invalidated so a retained capability cannot release a future service or
	# continue dispatch after its owner leaves the tree.
	var context_ids: Array = _contexts.keys()
	for context_id_variant in context_ids:
		_release_context_entry(context_id_variant as StringName)
	_contexts.clear()
	_route_tokens.clear()


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
