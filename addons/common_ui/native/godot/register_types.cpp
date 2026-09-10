#include "godot/register_types.h"

#include "godot/common_input_binding_registry.h"
#include "godot/common_ui_handles.h"
#include "godot/common_ui_runtime.h"
#include "resources/common_ui_action.h"
#include "resources/common_ui_binding.h"
#include "resources/common_ui_device_profile.h"
#include "resources/common_ui_input_config.h"
#include "resources/common_ui_input_policy.h"

#include <gdextension_interface.h>

#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

using namespace godot;

void initialize_common_ui_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}

	// Configuration resources first: the runtime and handles reference them.
	GDREGISTER_CLASS(CommonUIBinding);
	GDREGISTER_CLASS(CommonUIAction);
	GDREGISTER_CLASS(CommonUIInputPolicy);
	GDREGISTER_CLASS(CommonUIDeviceProfile);
	GDREGISTER_CLASS(CommonUIInputConfig);

	GDREGISTER_CLASS(CommonInputBindingRegistry);
	GDREGISTER_CLASS(CommonUIActionHandle);
	GDREGISTER_CLASS(CommonUIContextHandle);
	GDREGISTER_CLASS(CommonUIRuntime);
}

void uninitialize_common_ui_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
}

extern "C" {

// Entry point named in addons/common_ui/common_ui.gdextension.
GDExtensionBool GDE_EXPORT common_ui_library_init(GDExtensionInterfaceGetProcAddress p_get_proc_address,
		GDExtensionClassLibraryPtr p_library, GDExtensionInitialization *r_initialization) {
	godot::GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);

	init_obj.register_initializer(initialize_common_ui_module);
	init_obj.register_terminator(uninitialize_common_ui_module);
	init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);

	return init_obj.init();
}
}
