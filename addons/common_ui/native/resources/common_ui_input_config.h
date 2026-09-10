#ifndef COMMON_UI_INPUT_CONFIG_H
#define COMMON_UI_INPUT_CONFIG_H

#include "resources/common_ui_action.h"
#include "resources/common_ui_device_profile.h"
#include "resources/common_ui_input_policy.h"

#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/typed_array.hpp>

namespace godot {

// The complete set of framework action definitions, modality policy, and device
// profiles a project hands to CommonInputBindingRegistry.
class CommonUIInputConfig : public Resource {
	GDCLASS(CommonUIInputConfig, Resource)

public:
	void set_actions(const TypedArray<CommonUIAction> &p_actions);
	TypedArray<CommonUIAction> get_actions() const { return actions; }

	void set_input_policy(const Ref<CommonUIInputPolicy> &p_policy);
	Ref<CommonUIInputPolicy> get_input_policy() const { return input_policy; }

	void set_device_profiles(const TypedArray<CommonUIDeviceProfile> &p_profiles);
	TypedArray<CommonUIDeviceProfile> get_device_profiles() const { return device_profiles; }

	// Bumped whenever the definition set changes shape. Persisted overrides
	// record the version they were written against.
	void set_definition_version(int p_version);
	int get_definition_version() const { return definition_version; }

	// Every validation problem in the config, empty when it is usable. Duplicate
	// identifiers are reported with both resource paths rather than resolved
	// implicitly.
	PackedStringArray validate() const;

	Ref<CommonUIAction> find_action(const StringName &p_action_name) const;

	// The profile whose patterns match p_device_name, or null.
	Ref<CommonUIDeviceProfile> find_device_profile(const String &p_device_name) const;

protected:
	static void _bind_methods();

private:
	TypedArray<CommonUIAction> actions;
	Ref<CommonUIInputPolicy> input_policy;
	TypedArray<CommonUIDeviceProfile> device_profiles;
	int definition_version = 1;
};

} // namespace godot

#endif // COMMON_UI_INPUT_CONFIG_H
