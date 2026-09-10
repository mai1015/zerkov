#include "godot/register_types.h"

#include "godot/gameplay_ability_command_builder.h"
#include "godot/gameplay_ability_component.h"
#include "godot/gameplay_ability_network_bridge.h"
#include "godot/gameplay_ability_world_coordinator.h"
#include "godot/gameplay_target_value.h"
#include "godot/gameplay_ability_version.h"
#include "godot/gameplay_definition_validator.h"

#include "resources/gameplay_ability_definition.h"
#include "resources/gameplay_ability_task_request.h"
#include "resources/gameplay_ability_trigger.h"
#include "resources/gameplay_attribute_definition.h"
#include "resources/gameplay_cue_definition.h"
#include "resources/gameplay_definition_catalog.h"
#include "resources/gameplay_effect_definition.h"
#include "resources/gameplay_magnitude.h"
#include "resources/gameplay_modifier_declaration.h"
#include "resources/gameplay_network_policy.h"
#include "resources/gameplay_set_by_caller_field.h"
#include "resources/gameplay_stacking_policy.h"
#include "resources/gameplay_tag_definition.h"
#include "resources/gameplay_tag_operand.h"
#include "resources/gameplay_tag_query_resource.h"
#include "resources/gameplay_tag_reaction_definition.h"
#include "resources/gameplay_target_data_schema.h"

#include <gdextension_interface.h>

#include <godot_cpp/classes/project_settings.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

using namespace godot;

void initialize_gameplay_abilities_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}

	// Version and capability reporting. Registered first and unconditionally:
	// it has no dependencies on anything below, and the smoke test and the
	// handshake both need it available regardless of what else has landed.
	GDREGISTER_CLASS(GameplayAbilityVersion);

	// Resources
	// (Editor-visible tag/attribute/effect/ability/magnitude/stacking/query/cue/
	// target-data/network-policy Resource subclasses register here.)
	GDREGISTER_CLASS(GameplayTagDefinition);
	GDREGISTER_CLASS(GameplayTagOperand);
	GDREGISTER_CLASS(GameplayTagQueryResource);
	GDREGISTER_CLASS(GameplayAttributeDefinition);
	GDREGISTER_CLASS(GameplayMagnitude);
	GDREGISTER_CLASS(GameplayModifierDeclaration);
	GDREGISTER_CLASS(GameplaySetByCallerField);
	GDREGISTER_CLASS(GameplayStackingPolicy);
	GDREGISTER_CLASS(GameplayEffectDefinition);
	GDREGISTER_CLASS(GameplayCueDefinition);
	GDREGISTER_CLASS(GameplayTargetDataSchema);
	GDREGISTER_CLASS(GameplayAbilityTaskRequest);
	// Task 9.1 remainder: ability and network-policy definition resources.
	GDREGISTER_CLASS(GameplayAbilityTrigger);
	GDREGISTER_CLASS(GameplayAbilityDefinition);
	GDREGISTER_CLASS(GameplayNetworkPolicy);
	// Task 1.1: the project-wide definition catalog and its tag-reaction
	// collection member. GameplayTagReactionDefinition is registered before
	// GameplayDefinitionCatalog purely for readability (the catalog's own
	// `tag_reactions` property references it); ClassDB registration order
	// does not otherwise matter here.
	GDREGISTER_CLASS(GameplayTagReactionDefinition);
	GDREGISTER_CLASS(GameplayDefinitionCatalog);
	// Authoring-time validation (task 9.2): runs the core's own registries and
	// validators over the resources above and reports structured, bounded
	// findings. `validate()` itself still only covers tags/attributes/
	// effects/cues/tag-queries/target-schemas -- it has no
	// Array[GameplayAbilityDefinition] or GameplayNetworkPolicy parameter.
	// Ability definitions ARE fully validated, just via the separate
	// `GameplayDefinitionValidator.validate_prediction_eligibility_seam()`
	// call (task 8.1/9.1's wired seam; see authoring.md); network-policy
	// definitions have no validation path here at all.
	GDREGISTER_CLASS(GameplayDefinitionValidator);

	// Runtime nodes
	// (GameplayAbilityComponent, GameplayAbilityNetworkBridge, and their DTO/
	// handle RefCounted helpers register here.)
	// Task 6.10: the Callable-facing command-builder handle a script-authored
	// ability hook receives -- registered before the component so it is
	// available the instant a hook could theoretically run.
	GDREGISTER_CLASS(GameplayAbilityCommandBuilder);
	GDREGISTER_CLASS(GameplayTargetHit);
	GDREGISTER_CLASS(GameplayTargetValue);
	GDREGISTER_CLASS(GameplayValidatedTargetData);
	GDREGISTER_CLASS(GameplayAbilityComponent);
	GDREGISTER_CLASS(GameplayAbilityWorldCoordinator);
	GDREGISTER_CLASS(GameplayAbilityNetworkBridge);

	// Diagnostics
	// (Diagnostic inspector helper classes register here.)

	// Task 1.2: the project-wide default catalog setting
	// `GameplayAbilityComponent::configure()` resolves when a component
	// declares no explicit `definition_catalog` override (see that method's
	// resolution-order doc comment). Registered with `set_setting`/
	// `set_initial_value` rather than assigned unconditionally so an
	// already-saved project.godot value (a real catalog path) is never
	// clobbered back to empty on every engine start; `has_setting` guards the
	// one-time default. `add_property_info` gives the editor's Project
	// Settings dialog a file picker restricted to saved resource files,
	// exactly like this addon's own PROPERTY_HINT_FILE-free resource
	// reference fields elsewhere use PROPERTY_HINT_RESOURCE_TYPE -- a
	// top-level ProjectSettings entry has no equivalent object-typed hint, so
	// this uses PROPERTY_HINT_FILE with the addon's own resource extensions.
	const String default_catalog_setting = "gameplay_abilities/default_definition_catalog";
	ProjectSettings *project_settings = ProjectSettings::get_singleton();
	if (project_settings != nullptr) {
		if (!project_settings->has_setting(default_catalog_setting)) {
			project_settings->set_setting(default_catalog_setting, String());
		}
		project_settings->set_initial_value(default_catalog_setting, String());
		Dictionary property_info;
		property_info["name"] = default_catalog_setting;
		property_info["type"] = int(Variant::STRING);
		property_info["hint"] = PROPERTY_HINT_FILE;
		property_info["hint_string"] = "*.tres,*.res";
		project_settings->add_property_info(property_info);
	}
}

void uninitialize_gameplay_abilities_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
}

extern "C" {

// Entry point named in addons/gameplay_abilities/gameplay_abilities.gdextension.
GDExtensionBool GDE_EXPORT gameplay_abilities_library_init(GDExtensionInterfaceGetProcAddress p_get_proc_address,
		GDExtensionClassLibraryPtr p_library, GDExtensionInitialization *r_initialization) {
	godot::GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);

	init_obj.register_initializer(initialize_gameplay_abilities_module);
	init_obj.register_terminator(uninitialize_gameplay_abilities_module);
	init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);

	return init_obj.init();
}
}
