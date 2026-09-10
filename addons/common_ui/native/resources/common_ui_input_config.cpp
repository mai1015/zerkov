#include "resources/common_ui_input_config.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/dictionary.hpp>

namespace godot {

void CommonUIInputConfig::set_actions(const TypedArray<CommonUIAction> &p_actions) {
	actions = p_actions;
	emit_changed();
}

void CommonUIInputConfig::set_input_policy(const Ref<CommonUIInputPolicy> &p_policy) {
	input_policy = p_policy;
	emit_changed();
}

void CommonUIInputConfig::set_device_profiles(const TypedArray<CommonUIDeviceProfile> &p_profiles) {
	device_profiles = p_profiles;
	emit_changed();
}

void CommonUIInputConfig::set_definition_version(int p_version) {
	definition_version = p_version < 1 ? 1 : p_version;
	emit_changed();
}

PackedStringArray CommonUIInputConfig::validate() const {
	PackedStringArray errors;
	// action name -> resource path of the first definition that claimed it.
	Dictionary claimed;

	for (int i = 0; i < actions.size(); ++i) {
		const Ref<CommonUIAction> action = actions[i];
		if (action.is_null()) {
			errors.push_back(vformat("Action slot %d is empty.", i));
			continue;
		}
		const String error = action->get_validation_error();
		if (!error.is_empty()) {
			errors.push_back(error);
			continue;
		}
		const String name = String(action->get_action_name());
		const String path = action->get_path().is_empty() ? vformat("<slot %d>", i) : action->get_path();
		if (claimed.has(name)) {
			// Both locations are reported; the registry never picks one.
			errors.push_back(vformat("Duplicate action identifier '%s' declared by '%s' and '%s'.",
					name, String(claimed[name]), path));
			continue;
		}
		claimed[name] = path;
	}

	Dictionary families;
	for (int i = 0; i < device_profiles.size(); ++i) {
		const Ref<CommonUIDeviceProfile> profile = device_profiles[i];
		if (profile.is_null()) {
			errors.push_back(vformat("Device profile slot %d is empty.", i));
			continue;
		}
		const String family = String(profile->get_family_id());
		if (family.is_empty()) {
			errors.push_back(vformat("Device profile at slot %d has no family identifier.", i));
			continue;
		}
		if (families.has(family)) {
			errors.push_back(vformat("Duplicate device profile family '%s'.", family));
			continue;
		}
		families[family] = true;
	}

	return errors;
}

Ref<CommonUIAction> CommonUIInputConfig::find_action(const StringName &p_action_name) const {
	for (int i = 0; i < actions.size(); ++i) {
		const Ref<CommonUIAction> action = actions[i];
		if (action.is_valid() && action->get_action_name() == p_action_name) {
			return action;
		}
	}
	return Ref<CommonUIAction>();
}

Ref<CommonUIDeviceProfile> CommonUIInputConfig::find_device_profile(const String &p_device_name) const {
	for (int i = 0; i < device_profiles.size(); ++i) {
		const Ref<CommonUIDeviceProfile> profile = device_profiles[i];
		if (profile.is_valid() && profile->matches_device_name(p_device_name)) {
			return profile;
		}
	}
	return Ref<CommonUIDeviceProfile>();
}

void CommonUIInputConfig::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_actions", "actions"), &CommonUIInputConfig::set_actions);
	ClassDB::bind_method(D_METHOD("get_actions"), &CommonUIInputConfig::get_actions);
	ClassDB::bind_method(D_METHOD("set_input_policy", "policy"), &CommonUIInputConfig::set_input_policy);
	ClassDB::bind_method(D_METHOD("get_input_policy"), &CommonUIInputConfig::get_input_policy);
	ClassDB::bind_method(D_METHOD("set_device_profiles", "profiles"),
			&CommonUIInputConfig::set_device_profiles);
	ClassDB::bind_method(D_METHOD("get_device_profiles"), &CommonUIInputConfig::get_device_profiles);
	ClassDB::bind_method(D_METHOD("set_definition_version", "version"),
			&CommonUIInputConfig::set_definition_version);
	ClassDB::bind_method(D_METHOD("get_definition_version"), &CommonUIInputConfig::get_definition_version);
	ClassDB::bind_method(D_METHOD("validate"), &CommonUIInputConfig::validate);
	ClassDB::bind_method(D_METHOD("find_action", "action_name"), &CommonUIInputConfig::find_action);
	ClassDB::bind_method(D_METHOD("find_device_profile", "device_name"),
			&CommonUIInputConfig::find_device_profile);

	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "actions", PROPERTY_HINT_ARRAY_TYPE,
						 vformat("%d/%d:CommonUIAction", Variant::OBJECT, PROPERTY_HINT_RESOURCE_TYPE)),
			"set_actions", "get_actions");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "input_policy", PROPERTY_HINT_RESOURCE_TYPE,
						 "CommonUIInputPolicy"),
			"set_input_policy", "get_input_policy");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "device_profiles", PROPERTY_HINT_ARRAY_TYPE,
						 vformat("%d/%d:CommonUIDeviceProfile", Variant::OBJECT, PROPERTY_HINT_RESOURCE_TYPE)),
			"set_device_profiles", "get_device_profiles");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "definition_version"), "set_definition_version",
			"get_definition_version");
}

} // namespace godot
