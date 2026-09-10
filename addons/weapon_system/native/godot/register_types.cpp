#include "godot/register_types.h"

#include "godot/weapon_definition_catalog.h"
#include "godot/weapon_network_bridge.h"
#include "godot/weapon_system_version.h"
#include "godot/weapon_authority.h"

#include "resources/ammunition_ballistic_profile_resource.h"
#include "resources/attachment_definition_resource.h"
#include "resources/hitscan_shot_profile_resource.h"
#include "resources/recoil_profile_resource.h"
#include "resources/weapon_attachment_slot_resource.h"
#include "resources/weapon_definition_resource.h"

#include <gdextension_interface.h>

#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

using namespace godot;

void initialize_weapon_system_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) return;

	// Authoring resources (native/resources/). Small per-array-element
	// Resources (WeaponAttachmentSlotResource) are registered before the
	// class that references them (WeaponDefinitionResource), matching
	// gameplay_abilities' register_types.cpp ordering.
	GDREGISTER_CLASS(HitscanShotProfileResource);
	GDREGISTER_CLASS(RecoilProfileResource);
	GDREGISTER_CLASS(AttachmentDefinitionResource);
	GDREGISTER_CLASS(AmmunitionBallisticProfileResource);
	GDREGISTER_CLASS(WeaponAttachmentSlotResource);
	GDREGISTER_CLASS(WeaponDefinitionResource);

	// Façade (native/godot/): the sealed-catalog boundary and the
	// authoritative runtime role.
	GDREGISTER_CLASS(WeaponDefinitionCatalog);
	GDREGISTER_CLASS(WeaponSystemVersion);
	GDREGISTER_CLASS(WeaponAuthority);
	// Optional protocol/networking bridge (tasks.md 7.5). Registered
	// additively; a game that never instances it is unaffected.
	GDREGISTER_CLASS(WeaponNetworkBridge);
}

void uninitialize_weapon_system_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) return;
}

extern "C" {

GDExtensionBool GDE_EXPORT weapon_system_library_init(
		GDExtensionInterfaceGetProcAddress p_get_proc_address,
		GDExtensionClassLibraryPtr p_library,
		GDExtensionInitialization *r_initialization) {
	godot::GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);
	init_obj.register_initializer(initialize_weapon_system_module);
	init_obj.register_terminator(uninitialize_weapon_system_module);
	init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
	return init_obj.init();
}
}
