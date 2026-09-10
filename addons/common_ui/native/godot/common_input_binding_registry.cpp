#include "godot/common_input_binding_registry.h"

#include <godot_cpp/classes/dir_access.hpp>
#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/classes/input_map.hpp>
#include <godot_cpp/classes/json.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <cmath>
#include <cstdint>
#include <initializer_list>
#include <limits>
#include <unordered_set>
#include <utility>

namespace godot {

const int CommonInputBindingRegistry::OVERRIDE_FORMAT_VERSION = 2;
const char *CommonInputBindingRegistry::OVERRIDE_PATH = "user://common_ui_bindings.json";

namespace {

const char *TEMP_SUFFIX = ".tmp";
const char *BACKUP_SUFFIX = ".bak";

std::uint64_t binding_slot_key(cu::Id p_action, cu::BindingSlot p_slot) {
	return (static_cast<std::uint64_t>(p_action) << 8) |
			static_cast<std::uint64_t>(p_slot);
}

cu::BindingSlot to_core_slot(CommonInputBindingRegistry::Slot p_slot) {
	return p_slot == CommonInputBindingRegistry::SLOT_SECONDARY ? cu::BindingSlot::SECONDARY
																: cu::BindingSlot::PRIMARY;
}

cu::Protection to_core_protection(CommonUIAction::Protection p_protection) {
	switch (p_protection) {
		case CommonUIAction::PROTECTION_REQUIRED:
			return cu::Protection::REQUIRED;
		case CommonUIAction::PROTECTION_CONFIRM:
			return cu::Protection::CONFIRM;
		default:
			return cu::Protection::NONE;
	}
}

cu::ConflictPolicy to_core_policy(CommonInputBindingRegistry::ConflictPolicy p_policy) {
	switch (p_policy) {
		case CommonInputBindingRegistry::CONFLICT_REPLACE:
			return cu::ConflictPolicy::REPLACE;
		case CommonInputBindingRegistry::CONFLICT_ALLOW_DUPLICATE:
			return cu::ConflictPolicy::ALLOW_DUPLICATE;
		default:
			return cu::ConflictPolicy::REJECT;
	}
}

Dictionary binding_to_dictionary(const Ref<CommonUIBinding> &p_binding) {
	Dictionary result;
	if (p_binding.is_null()) {
		return result;
	}
	result["device_kind"] = static_cast<int>(p_binding->get_device_kind());
	result["code"] = p_binding->get_code();
	result["axis_direction"] = static_cast<int>(p_binding->get_axis_direction());
	result["dead_zone"] = p_binding->get_dead_zone();
	result["shift"] = p_binding->is_shift_pressed();
	result["ctrl"] = p_binding->is_ctrl_pressed();
	result["alt"] = p_binding->is_alt_pressed();
	result["meta"] = p_binding->is_meta_pressed();
	result["glyph"] = String(p_binding->get_glyph_id());
	return result;
}

bool has_exact_keys(const Dictionary &p_data, std::initializer_list<const char *> p_keys) {
	if (p_data.size() != static_cast<int64_t>(p_keys.size())) {
		return false;
	}
	for (const char *key : p_keys) {
		if (!p_data.has(key)) {
			return false;
		}
	}
	return true;
}

bool is_number(const Variant &p_value) {
	return p_value.get_type() == Variant::INT || p_value.get_type() == Variant::FLOAT;
}

// Godot's JSON parser represents JSON numbers as floats on some engine builds,
// even when their source token has no fractional part. Validate integer
// semantics rather than relying on the engine-side Variant representation.
bool parse_integer(const Variant &p_value, int64_t &r_value) {
	if (p_value.get_type() == Variant::INT) {
		const int64_t number = p_value;
		if (number < std::numeric_limits<int>::min() ||
				number > std::numeric_limits<int>::max()) {
			return false;
		}
		r_value = number;
		return true;
	}
	if (p_value.get_type() != Variant::FLOAT) {
		return false;
	}
	const double number = p_value;
	if (!std::isfinite(number) || std::trunc(number) != number ||
			number < std::numeric_limits<int>::min() ||
			number > std::numeric_limits<int>::max()) {
		return false;
	}
	r_value = static_cast<int64_t>(number);
	return true;
}

bool parse_binding_dictionary(const Dictionary &p_data, CommonUIBinding::Slot p_slot,
		Ref<CommonUIBinding> &r_binding) {
	if (!has_exact_keys(p_data,
				{ "device_kind", "code", "axis_direction", "dead_zone", "shift", "ctrl", "alt",
						"meta", "glyph" })) {
		return false;
	}

	const Variant device_kind_value = p_data.get("device_kind", Variant());
	const Variant code_value = p_data.get("code", Variant());
	const Variant axis_direction_value = p_data.get("axis_direction", Variant());
	const Variant dead_zone_value = p_data.get("dead_zone", Variant());
	const Variant shift_value = p_data.get("shift", Variant());
	const Variant ctrl_value = p_data.get("ctrl", Variant());
	const Variant alt_value = p_data.get("alt", Variant());
	const Variant meta_value = p_data.get("meta", Variant());
	const Variant glyph_value = p_data.get("glyph", Variant());
	int64_t device_kind_raw = 0;
	int64_t code_raw = 0;
	int64_t axis_direction_raw = 0;

	if (!parse_integer(device_kind_value, device_kind_raw) || !parse_integer(code_value, code_raw) ||
			!parse_integer(axis_direction_value, axis_direction_raw) || !is_number(dead_zone_value) ||
			shift_value.get_type() != Variant::BOOL || ctrl_value.get_type() != Variant::BOOL ||
			alt_value.get_type() != Variant::BOOL || meta_value.get_type() != Variant::BOOL ||
			glyph_value.get_type() != Variant::STRING) {
		return false;
	}

	const double dead_zone = dead_zone_value;
	if (device_kind_raw < CommonUIBinding::DEVICE_KEYBOARD ||
			device_kind_raw > CommonUIBinding::DEVICE_TOUCH ||
			code_raw < std::numeric_limits<int>::min() || code_raw > std::numeric_limits<int>::max() ||
			axis_direction_raw < CommonUIBinding::AXIS_DIRECTION_NONE ||
			axis_direction_raw > CommonUIBinding::AXIS_DIRECTION_NEGATIVE ||
			!std::isfinite(dead_zone) || dead_zone < 0.0 || dead_zone > 1.0) {
		return false;
	}

	const auto device_kind = static_cast<CommonUIBinding::DeviceKind>(device_kind_raw);
	const auto axis_direction =
			static_cast<CommonUIBinding::AxisDirection>(axis_direction_raw);
	if ((device_kind == CommonUIBinding::DEVICE_KEYBOARD ||
				device_kind == CommonUIBinding::DEVICE_MOUSE) &&
			code_raw <= 0) {
		return false;
	}
	if ((device_kind == CommonUIBinding::DEVICE_GAMEPAD_BUTTON ||
				device_kind == CommonUIBinding::DEVICE_GAMEPAD_AXIS ||
				device_kind == CommonUIBinding::DEVICE_TOUCH) &&
			code_raw < 0) {
		return false;
	}
	if (device_kind == CommonUIBinding::DEVICE_GAMEPAD_AXIS) {
		if (axis_direction == CommonUIBinding::AXIS_DIRECTION_NONE) {
			return false;
		}
	} else if (axis_direction != CommonUIBinding::AXIS_DIRECTION_NONE) {
		return false;
	}

	Ref<CommonUIBinding> binding;
	binding.instantiate();
	binding->set_device_kind(device_kind);
	binding->set_code(static_cast<int>(code_raw));
	binding->set_axis_direction(axis_direction);
	binding->set_dead_zone(static_cast<float>(dead_zone));
	binding->set_shift_pressed(shift_value);
	binding->set_ctrl_pressed(ctrl_value);
	binding->set_alt_pressed(alt_value);
	binding->set_meta_pressed(meta_value);
	binding->set_glyph_id(StringName(String(glyph_value)));
	binding->set_slot(p_slot);
	if (!binding->is_valid_binding()) {
		return false;
	}
	r_binding = binding;
	return true;
}

} // namespace

cu::Id CommonInputBindingRegistry::action_id(const StringName &p_action) const {
	const cu::Id *cached = action_id_cache.getptr(p_action);
	if (cached != nullptr) {
		return *cached;
	}
	return names.find(String(p_action).utf8().get_data());
}

StringName CommonInputBindingRegistry::action_name(cu::Id p_action) const {
	auto found = action_names.find(p_action);
	return found == action_names.end() ? StringName() : found->second;
}

cu::Id CommonInputBindingRegistry::signature_of(const Ref<CommonUIBinding> &p_binding) {
	if (p_binding.is_null() || !p_binding->is_valid_binding()) {
		return cu::INVALID_ID;
	}
	// Interning the physical identity is intentionally side-effect free with
	// respect to the accepted resource map. A candidate may reuse an existing
	// signature while changing presentation metadata such as its glyph or dead
	// zone; that resource is installed only after the transaction is accepted.
	return names.intern(p_binding->get_signature().utf8().get_data());
}

PackedStringArray CommonInputBindingRegistry::configure(const Ref<CommonUIInputConfig> &p_config) {
	PackedStringArray errors;
	if (p_config.is_null()) {
		errors.push_back("Input config is null.");
		return errors;
	}
	errors = p_config->validate();
	if (!errors.is_empty()) {
		// Nothing is applied from an invalid config; the previous set stays live.
		return errors;
	}

	config = p_config;
	set.clear_definitions();
	action_names.clear();
	action_id_cache.clear();
	default_bindings_by_slot.clear();
	override_bindings_by_slot.clear();

	const TypedArray<CommonUIAction> actions = p_config->get_actions();
	for (int i = 0; i < actions.size(); ++i) {
		const Ref<CommonUIAction> action = actions[i];
		const cu::Id id = names.intern(String(action->get_action_name()).utf8().get_data());
		action_names[id] = action->get_action_name();
		action_id_cache[action->get_action_name()] = id;

		cu::ActionDefinition definition;
		definition.action = id;
		definition.protection = to_core_protection(action->get_protection());
		// An empty conflict context interns to INVALID_ID, which the core treats
		// as global: it then conflicts with every action on the same binding.
		definition.context = names.intern(String(action->get_conflict_context()).utf8().get_data());

		const TypedArray<CommonUIBinding> defaults = action->get_default_bindings();
		for (int b = 0; b < defaults.size(); ++b) {
			const Ref<CommonUIBinding> binding = defaults[b];
			const int slot = binding->get_slot() == CommonUIBinding::SLOT_SECONDARY ? 1 : 0;
			const cu::Id signature = signature_of(binding);
			definition.defaults[slot].signature = signature;
			definition.defaults[slot].glyph =
					names.intern(String(binding->get_glyph_id()).utf8().get_data());
			// An unusable binding (or one whose signature happens to intern to
			// empty) must never claim an action slot in the resource projection.
			// Validation has already rejected such a config; keep this guard so
			// BindingRecord::is_bound() and the resource maps cannot diverge.
			if (signature != cu::INVALID_ID) {
				default_bindings_by_slot[binding_slot_key(
						id, static_cast<cu::BindingSlot>(slot))] = binding;
			}
		}
		set.define(definition);
	}

	project_to_input_map();
	return errors;
}

void CommonInputBindingRegistry::project_to_input_map() {
	InputMap *input_map = InputMap::get_singleton();

	// Remove only the actions this registry created; a project's own gameplay
	// actions are never touched.
	for (int i = 0; i < projected_actions.size(); ++i) {
		const StringName name = StringName(projected_actions[i]);
		if (input_map->has_action(name)) {
			input_map->erase_action(name);
		}
	}
	projected_actions.clear();

	for (cu::Id action : set.action_order()) {
		const StringName name = action_name(action);
		if (String(name).is_empty() || !String(name).begins_with(CommonUIAction::ACTION_NAMESPACE)) {
			continue;
		}
		if (!input_map->has_action(name)) {
			input_map->add_action(name);
		}
		input_map->action_erase_events(name);
		bool has_axis_binding = false;
		float action_dead_zone = 0.0f;

		for (int slot = 0; slot < cu::BINDING_SLOT_COUNT; ++slot) {
			const cu::BindingSlot binding_slot = static_cast<cu::BindingSlot>(slot);
			const cu::BindingRecord record = set.effective(action, binding_slot);
			if (!record.is_bound()) {
				continue;
			}
			const std::uint64_t key = binding_slot_key(action, binding_slot);
			auto override_binding = override_bindings_by_slot.find(key);
			auto default_binding = default_bindings_by_slot.find(key);
			const Ref<CommonUIBinding> binding = override_binding != override_bindings_by_slot.end()
					? override_binding->second
					: (default_binding != default_bindings_by_slot.end()
								? default_binding->second
								: Ref<CommonUIBinding>());
			if (binding.is_null()) {
				continue;
			}
			if (binding->get_device_kind() == CommonUIBinding::DEVICE_GAMEPAD_AXIS) {
				// InputMap exposes one dead zone per action rather than per event. UI
				// actions normally have one controller slot; if both slots are axes,
				// use the stricter value so neither can start below its configured
				// threshold.
				has_axis_binding = true;
				action_dead_zone = action_dead_zone < binding->get_dead_zone()
						? binding->get_dead_zone()
						: action_dead_zone;
			}
			const Ref<InputEvent> event = binding->to_input_event();
			if (event.is_valid()) {
				input_map->action_add_event(name, event);
			}
		}
		if (has_axis_binding) {
			input_map->action_set_deadzone(name, action_dead_zone);
		}
		projected_actions.push_back(String(name));
	}
}

Dictionary CommonInputBindingRegistry::to_result(const cu::BindingResult &p_result) const {
	Dictionary result;
	result["ok"] = p_result.ok;
	result["error"] = String::utf8(p_result.error.c_str());
	result["needs_confirmation"] = p_result.needs_confirmation;

	Array conflicts;
	for (const cu::Conflict &conflict : p_result.conflicts) {
		Dictionary entry;
		entry["action"] = action_name(conflict.action);
		entry["slot"] = static_cast<int>(conflict.slot);
		entry["protected"] = conflict.is_protected;
		conflicts.push_back(entry);
	}
	result["conflicts"] = conflicts;
	return result;
}

Dictionary CommonInputBindingRegistry::commit(const cu::BindingSet::Snapshot &p_before,
		const cu::BindingResult &p_result) {
	if (!p_result.ok) {
		return to_result(p_result);
	}
	// The in-memory change succeeded; persistence and projection must too, or
	// the whole transaction is rolled back.
	if (!save_overrides()) {
		set.restore(p_before);
		project_to_input_map();
		cu::BindingResult failure;
		failure.error = "Could not save binding overrides; the previous bindings remain active.";
		failure.conflicts = p_result.conflicts;
		emit_signal("binding_error", String::utf8(failure.error.c_str()));
		return to_result(failure);
	}
	project_to_input_map();
	emit_signal("bindings_changed");
	return to_result(p_result);
}

Dictionary CommonInputBindingRegistry::rebind(const StringName &p_action, Slot p_slot,
		const Ref<CommonUIBinding> &p_binding, ConflictPolicy p_policy, bool p_confirmed) {
	const cu::Id action = action_id(p_action);
	const cu::BindingSet::Snapshot before = set.snapshot();

	if (p_binding.is_valid() && !p_binding->is_valid_binding()) {
		cu::BindingResult failure;
		failure.error = "Candidate binding is not usable.";
		return to_result(failure);
	}

	const cu::Id signature = signature_of(p_binding);
	const cu::Id glyph = p_binding.is_valid()
			? names.intern(String(p_binding->get_glyph_id()).utf8().get_data())
			: cu::INVALID_ID;

	const cu::BindingResult result = set.rebind(action, to_core_slot(p_slot), signature, glyph,
			to_core_policy(p_policy), p_confirmed);
	if (!result.ok) {
		return to_result(result);
	}

	// Persistence needs the accepted resource in order to serialize the full
	// override. Keep it under the exact action slot; a signature may be shared
	// with resources that carry different presentation metadata. REPLACE also
	// clears each displaced slot's resource alongside its core override.
	const auto resources_before = override_bindings_by_slot;
	if (p_policy == CONFLICT_REPLACE) {
		for (const cu::Conflict &conflict : result.conflicts) {
			override_bindings_by_slot.erase(binding_slot_key(conflict.action, conflict.slot));
		}
	}
	override_bindings_by_slot[binding_slot_key(action, to_core_slot(p_slot))] = p_binding;

	const Dictionary committed = commit(before, result);
	if (!static_cast<bool>(committed.get("ok", false))) {
		override_bindings_by_slot = resources_before;
		// commit() already restored the core snapshot; repeat projection now that
		// its companion resource map has also been restored.
		project_to_input_map();
	}
	return committed;
}

Dictionary CommonInputBindingRegistry::clear_binding(const StringName &p_action, Slot p_slot,
		bool p_confirmed) {
	const cu::BindingSet::Snapshot before = set.snapshot();
	const cu::Id action = action_id(p_action);
	const cu::BindingSlot slot = to_core_slot(p_slot);
	const cu::BindingResult result = set.clear_binding(action, slot, p_confirmed);
	if (!result.ok) {
		return to_result(result);
	}
	const auto resources_before = override_bindings_by_slot;
	override_bindings_by_slot.erase(binding_slot_key(action, slot));
	const Dictionary committed = commit(before, result);
	if (!static_cast<bool>(committed.get("ok", false))) {
		override_bindings_by_slot = resources_before;
		project_to_input_map();
	}
	return committed;
}

Dictionary CommonInputBindingRegistry::restore_defaults() {
	const cu::BindingSet::Snapshot before = set.snapshot();
	const cu::BindingResult result = set.restore_defaults();
	if (!result.ok) {
		return to_result(result);
	}
	const auto resources_before = override_bindings_by_slot;
	override_bindings_by_slot.clear();
	const Dictionary committed = commit(before, result);
	if (!static_cast<bool>(committed.get("ok", false))) {
		override_bindings_by_slot = resources_before;
		project_to_input_map();
	}
	return committed;
}

Dictionary CommonInputBindingRegistry::restore_action_defaults(const StringName &p_action) {
	const cu::BindingSet::Snapshot before = set.snapshot();
	const cu::Id action = action_id(p_action);
	const cu::BindingResult result = set.restore_action_defaults(action);
	if (!result.ok) {
		return to_result(result);
	}
	const auto resources_before = override_bindings_by_slot;
	for (int slot = 0; slot < cu::BINDING_SLOT_COUNT; ++slot) {
		override_bindings_by_slot.erase(
				binding_slot_key(action, static_cast<cu::BindingSlot>(slot)));
	}
	const Dictionary committed = commit(before, result);
	if (!static_cast<bool>(committed.get("ok", false))) {
		override_bindings_by_slot = resources_before;
		project_to_input_map();
	}
	return committed;
}

Ref<CommonUIBinding> CommonInputBindingRegistry::get_effective_binding(const StringName &p_action,
		Slot p_slot) const {
	const cu::BindingRecord record = set.effective(action_id(p_action), to_core_slot(p_slot));
	if (!record.is_bound()) {
		return Ref<CommonUIBinding>();
	}
	const std::uint64_t key = binding_slot_key(action_id(p_action), to_core_slot(p_slot));
	auto override_binding = override_bindings_by_slot.find(key);
	if (override_binding != override_bindings_by_slot.end()) {
		return override_binding->second;
	}
	auto default_binding = default_bindings_by_slot.find(key);
	return default_binding == default_bindings_by_slot.end()
			? Ref<CommonUIBinding>()
			: default_binding->second;
}

Array CommonInputBindingRegistry::find_conflicts(const StringName &p_action, Slot p_slot,
		const Ref<CommonUIBinding> &p_binding) const {
	Array result;
	if (p_binding.is_null() || !p_binding->is_valid_binding()) {
		return result;
	}
	const cu::Id signature = names.find(p_binding->get_signature().utf8().get_data());
	if (signature == cu::INVALID_ID) {
		return result;
	}
	for (const cu::Conflict &conflict :
			set.find_conflicts(action_id(p_action), to_core_slot(p_slot), signature)) {
		Dictionary entry;
		entry["action"] = action_name(conflict.action);
		entry["slot"] = static_cast<int>(conflict.slot);
		entry["protected"] = conflict.is_protected;
		result.push_back(entry);
	}
	return result;
}

PackedStringArray CommonInputBindingRegistry::get_action_names() const {
	PackedStringArray result;
	for (cu::Id action : set.action_order()) {
		result.push_back(String(action_name(action)));
	}
	return result;
}

bool CommonInputBindingRegistry::has_action(const StringName &p_action) const {
	const cu::Id action = action_id(p_action);
	return action != cu::INVALID_ID && set.has_action(action);
}

StringName CommonInputBindingRegistry::resolve_glyph(const StringName &p_action, Slot p_slot,
		const String &p_device_name) const {
	const Ref<CommonUIBinding> binding = get_effective_binding(p_action, p_slot);
	if (binding.is_null()) {
		return StringName();
	}
	if (config.is_valid()) {
		const Ref<CommonUIDeviceProfile> profile = config->find_device_profile(p_device_name);
		if (profile.is_valid()) {
			return profile->resolve_glyph(binding);
		}
	}
	// No recognised family: the binding's own identifier is the generic fallback.
	return binding->get_glyph_id();
}

// ---------------------------------------------------------------------------
// Persistence
// ---------------------------------------------------------------------------

bool CommonInputBindingRegistry::save_overrides() {
	Dictionary document;
	document["format_version"] = OVERRIDE_FORMAT_VERSION;
	// 0 is a sentinel meaning "no config was loaded when this was saved"; a real
	// config's definition_version is always >= 1 (see
	// CommonUIInputConfig::set_definition_version()), so it can never collide.
	// load_overrides() below must use the exact same sentinel for the "no
	// config" case or the two can never agree.
	document["definition_version"] = config.is_valid() ? config->get_definition_version() : 0;

	Array entries;
	for (const cu::BindingOverride &entry : set.overrides()) {
		Dictionary item;
		item["action"] = String(action_name(entry.action));
		item["slot"] = static_cast<int>(entry.slot);
		item["cleared"] = entry.cleared;
		// The binding is stored in full: a signature alone cannot be turned back
		// into an InputEvent by a process that never loaded the same defaults.
		if (!entry.cleared) {
			auto binding = override_bindings_by_slot.find(binding_slot_key(entry.action, entry.slot));
			if (binding == override_bindings_by_slot.end() || binding->second.is_null()) {
				return false;
			}
			item["binding"] = binding_to_dictionary(binding->second);
		}
		entries.push_back(item);
	}
	document["overrides"] = entries;

	// Write beside the target and rename, so an interrupted save can never
	// leave a partially written authoritative file.
	const String temp_path = String(OVERRIDE_PATH) + TEMP_SUFFIX;
	const String backup_path = String(OVERRIDE_PATH) + BACKUP_SUFFIX;
	Ref<FileAccess> file = FileAccess::open(temp_path, FileAccess::WRITE);
	if (file.is_null()) {
		return false;
	}
	const bool stored = file->store_string(JSON::stringify(document, "\t"));
	file->flush();
	const Error write_error = file->get_error();
	file->close();
	if (!stored || write_error != OK) {
		DirAccess::remove_absolute(temp_path);
		return false;
	}

	Ref<DirAccess> dir = DirAccess::open("user://");
	if (dir.is_null()) {
		// Cannot even attempt the rename; do not leave the half-written temp
		// file behind to be mistaken for a real (if stale) save later.
		DirAccess::remove_absolute(temp_path);
		return false;
	}
	// Rename over the target directly. Deleting first would open a window where
	// neither file is authoritative, so an interrupted save could lose the last
	// good overrides.
	if (dir->rename(temp_path, OVERRIDE_PATH) == OK) {
		// A backup can remain only from an interrupted fallback transaction. The
		// newly installed target is complete, so that stale recovery copy is no
		// longer authoritative.
		if (dir->file_exists(backup_path)) {
			dir->remove(backup_path);
		}
		return true;
	}

	// Some platforms refuse to rename onto an existing file. Preserve the old
	// complete document as a backup before installing the staged document. At
	// every interruption point at least one complete candidate remains:
	//
	//   target + temp  -> backup + temp -> backup + target -> target
	//
	// A stale backup is safe to remove while the current target still exists.
	if (!dir->file_exists(OVERRIDE_PATH)) {
		// No last-good target exists. The in-memory transaction will roll back;
		// discard this uncommitted stage rather than applying it on a later boot.
		if (dir->file_exists(temp_path)) {
			dir->remove(temp_path);
		}
		return false;
	}
	if (dir->file_exists(backup_path) && dir->remove(backup_path) != OK) {
		if (dir->file_exists(temp_path)) {
			dir->remove(temp_path);
		}
		return false;
	}
	if (dir->rename(OVERRIDE_PATH, backup_path) != OK) {
		if (dir->file_exists(temp_path)) {
			dir->remove(temp_path);
		}
		return false;
	}
	if (dir->rename(temp_path, OVERRIDE_PATH) == OK) {
		// Failure to delete a stale backup does not invalidate the newly
		// installed target. load_overrides() will clean it after validating the
		// target on the next process start.
		if (dir->file_exists(backup_path)) {
			dir->remove(backup_path);
		}
		return true;
	}

	// Installation failed. Restore the old target when possible. If even that
	// rename fails, leave the backup in place; load_overrides() recognizes it as
	// the last complete document and never prefers the uncommitted temp file.
	if (dir->rename(backup_path, OVERRIDE_PATH) == OK &&
			dir->file_exists(temp_path)) {
		dir->remove(temp_path);
	}
	return false;
}

bool CommonInputBindingRegistry::load_overrides() {
	auto reject = [this](const String &p_message) {
		emit_signal("binding_error", p_message);
		return false;
	};

	const String target_path = OVERRIDE_PATH;
	const String temp_path = target_path + String(TEMP_SUFFIX);
	const String backup_path = target_path + String(BACKUP_SUFFIX);
	String load_path = target_path;
	if (!FileAccess::file_exists(target_path)) {
		// Recover the old complete document first after an interrupted fallback
		// transaction. A temp-only state can happen during the first save; it is
		// safe to adopt only when no previous target or backup exists.
		if (FileAccess::file_exists(backup_path)) {
			load_path = backup_path;
		} else if (FileAccess::file_exists(temp_path)) {
			load_path = temp_path;
		} else {
			// No file yet is not an error; defaults stay active.
			return true;
		}
	}
	if (!FileAccess::file_exists(load_path)) {
		// No file yet is not an error; defaults stay active.
		return true;
	}
	Ref<FileAccess> file = FileAccess::open(load_path, FileAccess::READ);
	if (file.is_null()) {
		return reject("Could not open the saved bindings; active bindings remain unchanged.");
	}
	const Variant parsed = JSON::parse_string(file->get_as_text());
	file->close();

	if (parsed.get_type() != Variant::DICTIONARY) {
		return reject("Saved bindings are malformed; active bindings remain unchanged.");
	}
	const Dictionary document = parsed;
	int64_t format_version = 0;
	int64_t definition_version = 0;
	if (!has_exact_keys(document, { "format_version", "definition_version", "overrides" }) ||
			!parse_integer(document.get("format_version", Variant()), format_version) ||
			!parse_integer(document.get("definition_version", Variant()), definition_version) ||
			document.get("overrides", Variant()).get_type() != Variant::ARRAY) {
		return reject("Saved bindings document fields are malformed; active bindings remain unchanged.");
	}

	if (format_version <= 0 || format_version > OVERRIDE_FORMAT_VERSION) {
		return reject("Saved bindings use an unsupported format version; active bindings remain unchanged.");
	}
	if (config.is_null()) {
		return reject("Saved bindings require an active input configuration; active bindings remain unchanged.");
	}
	const int expected_definition_version =
			config.is_valid() ? config->get_definition_version() : 0;
	if (definition_version != expected_definition_version) {
		return reject("Saved bindings target a different definition version; active bindings remain unchanged.");
	}

	// Stage the complete document in local containers. No live binding or
	// InputMap state changes until every record and core invariant has passed.
	std::vector<cu::BindingOverride> loaded;
	std::unordered_map<std::uint64_t, Ref<CommonUIBinding>> loaded_bindings;
	std::unordered_set<std::uint64_t> loaded_slots;
	const Array entries = document.get("overrides", Variant());
	const std::size_t maximum_entries = set.action_order().size() * cu::BINDING_SLOT_COUNT;
	if (static_cast<std::size_t>(entries.size()) > maximum_entries) {
		return reject("Saved bindings contain too many override entries; active bindings remain unchanged.");
	}
	loaded.reserve(entries.size());
	for (int i = 0; i < entries.size(); ++i) {
		if (entries[i].get_type() != Variant::DICTIONARY) {
			return reject(vformat("Saved binding entry %d is malformed; active bindings remain unchanged.", i));
		}
		const Dictionary item = entries[i];
		if (!item.has("cleared") || item.get("cleared", Variant()).get_type() != Variant::BOOL) {
			return reject(vformat("Saved binding entry %d is malformed; active bindings remain unchanged.", i));
		}
		const bool cleared = item.get("cleared", Variant());
		int64_t slot_raw = 0;
		if (!has_exact_keys(item,
					cleared ? std::initializer_list<const char *>{ "action", "slot", "cleared" }
							: std::initializer_list<const char *>{ "action", "slot", "cleared", "binding" }) ||
				item.get("action", Variant()).get_type() != Variant::STRING ||
				!parse_integer(item.get("slot", Variant()), slot_raw)) {
			return reject(vformat("Saved binding entry %d is malformed; active bindings remain unchanged.", i));
		}

		const String action_text = item.get("action", Variant());
		if (action_text.is_empty() ||
				(slot_raw != CommonInputBindingRegistry::SLOT_PRIMARY &&
						slot_raw != CommonInputBindingRegistry::SLOT_SECONDARY)) {
			return reject(vformat("Saved binding entry %d is invalid; active bindings remain unchanged.", i));
		}

		cu::BindingOverride entry;
		entry.action = action_id(StringName(action_text));
		if (entry.action == cu::INVALID_ID || !set.has_action(entry.action)) {
			return reject(vformat(
					"Saved binding entry %d references an unknown action; active bindings remain unchanged.", i));
		}
		const CommonUIBinding::Slot slot = static_cast<CommonUIBinding::Slot>(slot_raw);
		entry.slot = slot == CommonUIBinding::SLOT_SECONDARY ? cu::BindingSlot::SECONDARY
																 : cu::BindingSlot::PRIMARY;
		entry.cleared = cleared;

		const std::uint64_t slot_key = binding_slot_key(entry.action, entry.slot);
		if (!loaded_slots.insert(slot_key).second) {
			return reject(vformat(
					"Saved binding entry %d duplicates an action slot; active bindings remain unchanged.", i));
		}

		if (!entry.cleared) {
			if (item.get("binding", Variant()).get_type() != Variant::DICTIONARY) {
				return reject(vformat(
						"Saved binding entry %d has a malformed binding; active bindings remain unchanged.", i));
			}
			Ref<CommonUIBinding> binding;
			if (!parse_binding_dictionary(item.get("binding", Variant()), slot, binding)) {
				return reject(vformat(
						"Saved binding entry %d has an invalid binding; active bindings remain unchanged.", i));
			}
			entry.signature = signature_of(binding);
			if (entry.signature == cu::INVALID_ID) {
				return reject(vformat(
						"Saved binding entry %d has an invalid binding; active bindings remain unchanged.", i));
			}
			loaded_bindings[slot_key] = binding;
			entry.glyph = names.intern(String(binding->get_glyph_id()).utf8().get_data());
		}
		loaded.push_back(entry);
	}

	const cu::BindingSet::Snapshot before = set.snapshot();
	const std::vector<std::string> problems = set.load_overrides(loaded);
	if (!problems.empty()) {
		set.restore(before);
		return reject("Saved bindings violate the active action definitions; active bindings remain unchanged.");
	}
	override_bindings_by_slot = std::move(loaded_bindings);
	project_to_input_map();

	// Heal a crash-interrupted on-disk state only after the selected candidate
	// has passed the same strict validation as an ordinary target. If promotion
	// fails, the validated backup/temp remains available for the next load.
	Ref<DirAccess> recovery_dir = DirAccess::open("user://");
	if (recovery_dir.is_valid()) {
		if (load_path != target_path && !recovery_dir->file_exists(target_path) &&
				recovery_dir->rename(load_path, target_path) == OK) {
			load_path = target_path;
		}
		if (load_path == target_path) {
			if (recovery_dir->file_exists(backup_path)) {
				recovery_dir->remove(backup_path);
			}
			if (recovery_dir->file_exists(temp_path)) {
				recovery_dir->remove(temp_path);
			}
		}
	}
	emit_signal("bindings_changed");
	return true;
}

void CommonInputBindingRegistry::_bind_methods() {
	ClassDB::bind_method(D_METHOD("configure", "config"), &CommonInputBindingRegistry::configure);
	ClassDB::bind_method(D_METHOD("load_overrides"), &CommonInputBindingRegistry::load_overrides);
	ClassDB::bind_method(D_METHOD("save_overrides"), &CommonInputBindingRegistry::save_overrides);
	ClassDB::bind_method(D_METHOD("rebind", "action", "slot", "binding", "policy", "confirmed"),
			&CommonInputBindingRegistry::rebind, DEFVAL(CONFLICT_REJECT), DEFVAL(false));
	ClassDB::bind_method(D_METHOD("clear_binding", "action", "slot", "confirmed"),
			&CommonInputBindingRegistry::clear_binding, DEFVAL(false));
	ClassDB::bind_method(D_METHOD("restore_defaults"), &CommonInputBindingRegistry::restore_defaults);
	ClassDB::bind_method(D_METHOD("restore_action_defaults", "action"),
			&CommonInputBindingRegistry::restore_action_defaults);
	ClassDB::bind_method(D_METHOD("get_effective_binding", "action", "slot"),
			&CommonInputBindingRegistry::get_effective_binding);
	ClassDB::bind_method(D_METHOD("find_conflicts", "action", "slot", "binding"),
			&CommonInputBindingRegistry::find_conflicts);
	ClassDB::bind_method(D_METHOD("get_action_names"), &CommonInputBindingRegistry::get_action_names);
	ClassDB::bind_method(D_METHOD("has_action", "action"), &CommonInputBindingRegistry::has_action);
	ClassDB::bind_method(D_METHOD("resolve_glyph", "action", "slot", "device_name"),
			&CommonInputBindingRegistry::resolve_glyph, DEFVAL(String()));
	ClassDB::bind_method(D_METHOD("project_to_input_map"),
			&CommonInputBindingRegistry::project_to_input_map);

	ADD_SIGNAL(MethodInfo("bindings_changed"));
	ADD_SIGNAL(MethodInfo("binding_error", PropertyInfo(Variant::STRING, "message")));

	BIND_ENUM_CONSTANT(SLOT_PRIMARY);
	BIND_ENUM_CONSTANT(SLOT_SECONDARY);
	BIND_ENUM_CONSTANT(CONFLICT_REJECT);
	BIND_ENUM_CONSTANT(CONFLICT_REPLACE);
	BIND_ENUM_CONSTANT(CONFLICT_ALLOW_DUPLICATE);
}

} // namespace godot
