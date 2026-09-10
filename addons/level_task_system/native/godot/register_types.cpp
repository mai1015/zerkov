#include "godot/register_types.h"

#include "godot/level_task_system_version.h"
#include "godot/lts_level_binding_node.h"
#include "godot/lts_runtime_bridge.h"
#include "resources/level_task_definition_resources.h"
#include "resources/lts_level_binding_resource.h"

#include <gdextension_interface.h>

#include <godot_cpp/godot.hpp>

using namespace godot;

void initialize_level_task_system_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}

	// Keep the version façade registered first and independently of the
	// definition/runtime resources that subsequent tasks add.  This gives
	// editor and load smoke tests a stable compatibility probe even when a
	// project is running in the degraded native-extension state.
	GDREGISTER_CLASS(LevelTaskSystemVersion);
	GDREGISTER_CLASS(LevelTaskRuntimeBridge);

	// Leaf value Resources must be registered before the aggregate Resources
	// that reference them in typed arrays and inspector hints.
	GDREGISTER_CLASS(LevelTaskValue);
	GDREGISTER_CLASS(LevelTaskFactPredicate);
	GDREGISTER_CLASS(LevelTaskLocalizedParameter);
	GDREGISTER_CLASS(LevelTaskPortDefinition);
	GDREGISTER_CLASS(LevelTaskNodeDefinition);
	GDREGISTER_CLASS(LevelTaskEdgeDefinition);
	GDREGISTER_CLASS(LevelTaskGraphDefinition);
	GDREGISTER_CLASS(LevelTaskLevelAnchorDefinition);
	GDREGISTER_CLASS(LevelTaskLevelExitDefinition);
	GDREGISTER_CLASS(LevelTaskLevelDefinition);
	GDREGISTER_CLASS(LevelTaskConversationChoiceDefinition);
	GDREGISTER_CLASS(LevelTaskConversationStepDefinition);
	GDREGISTER_CLASS(LevelTaskSpeakerDefinition);
	GDREGISTER_CLASS(LevelTaskConversationDefinition);
	GDREGISTER_CLASS(LevelTaskProviderDeclaration);

	// Scene binding stays explicitly host-owned: an anchor value Resource is
	// registered before the Node that exposes a typed array of those values.
	GDREGISTER_CLASS(LevelTaskLevelAnchorBinding);
	GDREGISTER_CLASS(LevelTaskLevelBinding);
}

void uninitialize_level_task_system_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
}

extern "C" {

// Entry point named in addons/level_task_system/level_task_system.gdextension.
GDExtensionBool GDE_EXPORT level_task_system_library_init(
		GDExtensionInterfaceGetProcAddress p_get_proc_address,
		GDExtensionClassLibraryPtr p_library,
		GDExtensionInitialization *r_initialization) {
	godot::GDExtensionBinding::InitObject init_obj(
			p_get_proc_address, p_library, r_initialization);

	init_obj.register_initializer(initialize_level_task_system_module);
	init_obj.register_terminator(uninitialize_level_task_system_module);
	init_obj.set_minimum_library_initialization_level(
			MODULE_INITIALIZATION_LEVEL_SCENE);

	return init_obj.init();
}
}
