#ifndef COMMON_UI_ACTION_H
#define COMMON_UI_ACTION_H

#include "resources/common_ui_binding.h"

#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/variant/string_name.hpp>
#include <godot_cpp/variant/typed_array.hpp>

namespace godot {

// Definition of one logical CommonUI action: its stable namespaced identifier,
// framework default bindings, trigger policy, display metadata, and protection
// policy.
class CommonUIAction : public Resource {
	GDCLASS(CommonUIAction, Resource)

public:
	enum Protection {
		// Freely rebindable and may be left unbound.
		PROTECTION_NONE = 0,
		// Must always keep at least one eligible binding.
		PROTECTION_REQUIRED = 1,
		// Must keep a binding and needs explicit confirmation to change.
		PROTECTION_CONFIRM = 2,
	};

	// Namespace every framework action lives under. The binding registry only
	// ever projects and rewrites InputMap actions with this prefix.
	static const char *ACTION_NAMESPACE;

	void set_action_name(const StringName &p_action_name);
	StringName get_action_name() const { return action_name; }

	void set_display_name(const String &p_display_name);
	String get_display_name() const { return display_name; }

	// Conflict group this action's bindings compete in. Two actions may share a
	// physical binding when their conflict contexts differ. An empty context
	// means global: the action conflicts with every action on the same binding.
	void set_conflict_context(const StringName &p_context);
	StringName get_conflict_context() const { return conflict_context; }

	void set_default_bindings(const TypedArray<CommonUIBinding> &p_bindings);
	TypedArray<CommonUIBinding> get_default_bindings() const { return default_bindings; }

	void set_hold_threshold(double p_seconds);
	double get_hold_threshold() const { return hold_threshold; }

	void set_repeat_interval(double p_seconds);
	double get_repeat_interval() const { return repeat_interval; }

	void set_repeat_enabled(bool p_enabled);
	bool is_repeat_enabled() const { return repeat_enabled; }

	void set_display_priority(int p_priority);
	int get_display_priority() const { return display_priority; }

	void set_show_in_action_bar(bool p_show);
	bool is_shown_in_action_bar() const { return show_in_action_bar; }

	void set_protection(Protection p_protection);
	Protection get_protection() const { return protection; }

	// True when the identifier is non-empty and lives in the framework
	// namespace, which is what makes it safe to project into InputMap.
	bool is_namespaced() const;

	// Human-readable reason the definition is unusable, or an empty string.
	String get_validation_error() const;

protected:
	static void _bind_methods();

private:
	StringName action_name;
	String display_name;
	StringName conflict_context;
	TypedArray<CommonUIBinding> default_bindings;
	double hold_threshold = 0.4;
	double repeat_interval = 0.1;
	bool repeat_enabled = false;
	int display_priority = 0;
	bool show_in_action_bar = true;
	Protection protection = PROTECTION_NONE;
};

} // namespace godot

VARIANT_ENUM_CAST(CommonUIAction::Protection);

#endif // COMMON_UI_ACTION_H
