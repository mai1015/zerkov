#ifndef COMMON_INPUT_BINDING_REGISTRY_H
#define COMMON_INPUT_BINDING_REGISTRY_H

#include "core/cu_binding.h"
#include "core/cu_string_interner.h"
#include "resources/common_ui_input_config.h"

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/templates/hash_map.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>

#include <cstdint>
#include <unordered_map>

namespace godot {

// Owns the authoritative effective binding set and its projection into Godot's
// InputMap.
//
// Native action resources supply the defaults; a versioned user override store
// records only the differences. Every mutation is one transaction: validate,
// resolve conflicts, apply in memory, persist, project. If any step fails the
// previously active state is restored, including the InputMap projection.
class CommonInputBindingRegistry : public RefCounted {
	GDCLASS(CommonInputBindingRegistry, RefCounted)

public:
	enum Slot {
		SLOT_PRIMARY = 0,
		SLOT_SECONDARY = 1,
	};

	enum ConflictPolicy {
		// Change nothing and report every blocking action.
		CONFLICT_REJECT = 0,
		// Clear the conflicting bindings, unless that would unbind a protected action.
		CONFLICT_REPLACE = 1,
		// Let the same physical binding drive more than one action.
		CONFLICT_ALLOW_DUPLICATE = 2,
	};

	// Bumped when the persisted override layout changes.
	static const int OVERRIDE_FORMAT_VERSION;
	static const char *OVERRIDE_PATH;

	// Rebuilds the effective set from p_config's defaults and re-projects.
	// Returns the validation errors found in the config; a non-empty result
	// means nothing was applied.
	PackedStringArray configure(const Ref<CommonUIInputConfig> &p_config);

	// Reads user://, validates the complete document against the exact active
	// definition version, and re-projects only after the whole batch is accepted.
	// Any malformed, unknown, duplicate, or incompatible entry leaves the live
	// binding set and InputMap projection unchanged and reports `binding_error`.
	bool load_overrides();
	bool save_overrides();

	// One transaction. The returned Dictionary carries:
	//   ok (bool), error (String), needs_confirmation (bool),
	//   conflicts (Array[Dictionary] of {action, slot, protected})
	Dictionary rebind(const StringName &p_action, Slot p_slot, const Ref<CommonUIBinding> &p_binding,
			ConflictPolicy p_policy, bool p_confirmed);
	Dictionary clear_binding(const StringName &p_action, Slot p_slot, bool p_confirmed);
	Dictionary restore_defaults();
	Dictionary restore_action_defaults(const StringName &p_action);

	Ref<CommonUIBinding> get_effective_binding(const StringName &p_action, Slot p_slot) const;
	// Conflicts a candidate would cause, without applying it.
	Array find_conflicts(const StringName &p_action, Slot p_slot,
			const Ref<CommonUIBinding> &p_binding) const;
	PackedStringArray get_action_names() const;
	bool has_action(const StringName &p_action) const;

	// Logical glyph identifier for the effective binding under the active
	// device. Falls back to the profile's generic glyph, then to the binding's
	// own identifier, and finally to an empty name.
	StringName resolve_glyph(const StringName &p_action, Slot p_slot,
			const String &p_device_name) const;

	// Rewrites the namespaced InputMap actions from the effective set. Never
	// touches actions outside the framework namespace.
	void project_to_input_map();

protected:
	static void _bind_methods();

private:
	Dictionary to_result(const cu::BindingResult &p_result) const;
	// Commits an already-validated in-memory change, rolling back if
	// persistence fails.
	Dictionary commit(const cu::BindingSet::Snapshot &p_before, const cu::BindingResult &p_result);
	cu::Id signature_of(const Ref<CommonUIBinding> &p_binding);
	cu::Id action_id(const StringName &p_action) const;
	StringName action_name(cu::Id p_action) const;

	cu::StringInterner names;
	cu::BindingSet set;

	Ref<CommonUIInputConfig> config;
	std::unordered_map<cu::Id, StringName> action_names;
	// StringName -> action id, the reverse of action_names above. Checked by
	// action_id() before falling back to names.find(), so a per-frame lookup
	// (resolve_glyph() polled for an action-bar glyph, has_action(), ...) skips
	// the String -> utf8 -> std::string conversion that a StringInterner
	// lookup would otherwise redo every call. Rebuilt whenever configure()
	// rebuilds action_names, since a new config can rename or drop an action.
	HashMap<StringName, cu::Id> action_id_cache;
	// Binding resources belong to an action slot, not to a physical signature.
	// Distinct actions (or the two slots of one action) may legally share the
	// same signature while retaining different glyph and axis metadata.
	std::unordered_map<std::uint64_t, Ref<CommonUIBinding>> default_bindings_by_slot;
	std::unordered_map<std::uint64_t, Ref<CommonUIBinding>> override_bindings_by_slot;
	// Namespaced action names this registry created in InputMap, so it can
	// clean up exactly what it owns.
	PackedStringArray projected_actions;
};

} // namespace godot

VARIANT_ENUM_CAST(CommonInputBindingRegistry::Slot);
VARIANT_ENUM_CAST(CommonInputBindingRegistry::ConflictPolicy);

#endif // COMMON_INPUT_BINDING_REGISTRY_H
