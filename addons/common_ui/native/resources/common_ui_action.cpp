#include "resources/common_ui_action.h"

#include <godot_cpp/core/class_db.hpp>

namespace godot {

const char *CommonUIAction::ACTION_NAMESPACE = "common_ui/";

void CommonUIAction::set_action_name(const StringName &p_action_name) {
	action_name = p_action_name;
	emit_changed();
}

void CommonUIAction::set_display_name(const String &p_display_name) {
	display_name = p_display_name;
	emit_changed();
}

void CommonUIAction::set_conflict_context(const StringName &p_context) {
	conflict_context = p_context;
	emit_changed();
}

void CommonUIAction::set_default_bindings(const TypedArray<CommonUIBinding> &p_bindings) {
	default_bindings = p_bindings;
	emit_changed();
}

void CommonUIAction::set_hold_threshold(double p_seconds) {
	hold_threshold = p_seconds < 0.0 ? 0.0 : p_seconds;
	emit_changed();
}

void CommonUIAction::set_repeat_interval(double p_seconds) {
	repeat_interval = p_seconds < 0.0 ? 0.0 : p_seconds;
	emit_changed();
}

void CommonUIAction::set_repeat_enabled(bool p_enabled) {
	repeat_enabled = p_enabled;
	emit_changed();
}

void CommonUIAction::set_display_priority(int p_priority) {
	display_priority = p_priority;
	emit_changed();
}

void CommonUIAction::set_show_in_action_bar(bool p_show) {
	show_in_action_bar = p_show;
	emit_changed();
}

void CommonUIAction::set_protection(Protection p_protection) {
	protection = p_protection;
	emit_changed();
}

bool CommonUIAction::is_namespaced() const {
	return String(action_name).begins_with(ACTION_NAMESPACE);
}

String CommonUIAction::get_validation_error() const {
	if (String(action_name).is_empty()) {
		return "Action identifier is empty.";
	}
	if (!is_namespaced()) {
		return vformat("Action '%s' must start with '%s' so the registry never rewrites "
					   "unrelated project actions.",
				String(action_name), String(ACTION_NAMESPACE));
	}
	if (repeat_enabled && repeat_interval <= 0.0) {
		return vformat("Action '%s' enables repeat but has a non-positive repeat interval.",
				String(action_name));
	}
	bool primary_seen = false;
	bool secondary_seen = false;
	for (int i = 0; i < default_bindings.size(); ++i) {
		const Ref<CommonUIBinding> binding = default_bindings[i];
		if (binding.is_null()) {
			return vformat("Action '%s' has an empty binding at index %d.", String(action_name), i);
		}
		if (!binding->is_valid_binding()) {
			return vformat("Action '%s' has an unusable binding at index %d.",
					String(action_name), i);
		}
		// Two default bindings mapped to the same slot would otherwise silently
		// overwrite one another when the registry projects them (whichever is
		// declared last wins with no diagnostic at all).
		const bool is_secondary = binding->get_slot() == CommonUIBinding::SLOT_SECONDARY;
		bool &seen = is_secondary ? secondary_seen : primary_seen;
		if (seen) {
			return vformat("Action '%s' has more than one default binding mapped to the %s slot.",
					String(action_name), is_secondary ? "secondary" : "primary");
		}
		seen = true;
	}
	if (protection != PROTECTION_NONE && default_bindings.is_empty()) {
		return vformat("Protected action '%s' must declare at least one default binding.",
				String(action_name));
	}
	return String();
}

void CommonUIAction::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_action_name", "action_name"), &CommonUIAction::set_action_name);
	ClassDB::bind_method(D_METHOD("get_action_name"), &CommonUIAction::get_action_name);
	ClassDB::bind_method(D_METHOD("set_display_name", "display_name"), &CommonUIAction::set_display_name);
	ClassDB::bind_method(D_METHOD("get_display_name"), &CommonUIAction::get_display_name);
	ClassDB::bind_method(D_METHOD("set_conflict_context", "context"), &CommonUIAction::set_conflict_context);
	ClassDB::bind_method(D_METHOD("get_conflict_context"), &CommonUIAction::get_conflict_context);
	ClassDB::bind_method(D_METHOD("set_default_bindings", "bindings"), &CommonUIAction::set_default_bindings);
	ClassDB::bind_method(D_METHOD("get_default_bindings"), &CommonUIAction::get_default_bindings);
	ClassDB::bind_method(D_METHOD("set_hold_threshold", "seconds"), &CommonUIAction::set_hold_threshold);
	ClassDB::bind_method(D_METHOD("get_hold_threshold"), &CommonUIAction::get_hold_threshold);
	ClassDB::bind_method(D_METHOD("set_repeat_interval", "seconds"), &CommonUIAction::set_repeat_interval);
	ClassDB::bind_method(D_METHOD("get_repeat_interval"), &CommonUIAction::get_repeat_interval);
	ClassDB::bind_method(D_METHOD("set_repeat_enabled", "enabled"), &CommonUIAction::set_repeat_enabled);
	ClassDB::bind_method(D_METHOD("is_repeat_enabled"), &CommonUIAction::is_repeat_enabled);
	ClassDB::bind_method(D_METHOD("set_display_priority", "priority"), &CommonUIAction::set_display_priority);
	ClassDB::bind_method(D_METHOD("get_display_priority"), &CommonUIAction::get_display_priority);
	ClassDB::bind_method(D_METHOD("set_show_in_action_bar", "show"), &CommonUIAction::set_show_in_action_bar);
	ClassDB::bind_method(D_METHOD("is_shown_in_action_bar"), &CommonUIAction::is_shown_in_action_bar);
	ClassDB::bind_method(D_METHOD("set_protection", "protection"), &CommonUIAction::set_protection);
	ClassDB::bind_method(D_METHOD("get_protection"), &CommonUIAction::get_protection);
	ClassDB::bind_method(D_METHOD("is_namespaced"), &CommonUIAction::is_namespaced);
	ClassDB::bind_method(D_METHOD("get_validation_error"), &CommonUIAction::get_validation_error);

	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "action_name"), "set_action_name", "get_action_name");
	ADD_PROPERTY(PropertyInfo(Variant::STRING, "display_name"), "set_display_name", "get_display_name");
	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "conflict_context"), "set_conflict_context",
			"get_conflict_context");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "default_bindings", PROPERTY_HINT_ARRAY_TYPE,
						 vformat("%d/%d:CommonUIBinding", Variant::OBJECT, PROPERTY_HINT_RESOURCE_TYPE)),
			"set_default_bindings", "get_default_bindings");
	ADD_GROUP("Trigger", "");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "hold_threshold", PROPERTY_HINT_RANGE, "0.0,5.0,0.01,or_greater"),
			"set_hold_threshold", "get_hold_threshold");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "repeat_interval", PROPERTY_HINT_RANGE, "0.0,2.0,0.01,or_greater"),
			"set_repeat_interval", "get_repeat_interval");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "repeat_enabled"), "set_repeat_enabled", "is_repeat_enabled");
	ADD_GROUP("Presentation", "");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "display_priority"), "set_display_priority", "get_display_priority");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_in_action_bar"), "set_show_in_action_bar", "is_shown_in_action_bar");
	ADD_GROUP("", "");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "protection", PROPERTY_HINT_ENUM, "None,Required,Confirm"),
			"set_protection", "get_protection");

	BIND_ENUM_CONSTANT(PROTECTION_NONE);
	BIND_ENUM_CONSTANT(PROTECTION_REQUIRED);
	BIND_ENUM_CONSTANT(PROTECTION_CONFIRM);
}

} // namespace godot
