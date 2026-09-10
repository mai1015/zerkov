#include "resources/gameplay_definition_catalog.h"

#include <godot_cpp/core/class_db.hpp>

namespace godot {

void GameplayDefinitionCatalog::set_tag_definitions(const TypedArray<GameplayTagDefinition> &p_tags) {
	tag_definitions = p_tags;
	emit_changed();
}

void GameplayDefinitionCatalog::set_attribute_definitions(const TypedArray<GameplayAttributeDefinition> &p_attributes) {
	attribute_definitions = p_attributes;
	emit_changed();
}

void GameplayDefinitionCatalog::set_effect_definitions(const TypedArray<GameplayEffectDefinition> &p_effects) {
	effect_definitions = p_effects;
	emit_changed();
}

void GameplayDefinitionCatalog::set_ability_definitions(const TypedArray<GameplayAbilityDefinition> &p_abilities) {
	ability_definitions = p_abilities;
	emit_changed();
}

void GameplayDefinitionCatalog::set_cue_definitions(const TypedArray<GameplayCueDefinition> &p_cues) {
	cue_definitions = p_cues;
	emit_changed();
}

void GameplayDefinitionCatalog::set_target_data_schemas(const TypedArray<GameplayTargetDataSchema> &p_schemas) {
	target_data_schemas = p_schemas;
	emit_changed();
}

void GameplayDefinitionCatalog::set_tag_reactions(const TypedArray<GameplayTagReactionDefinition> &p_reactions) {
	tag_reactions = p_reactions;
	emit_changed();
}

void GameplayDefinitionCatalog::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_tag_definitions", "tags"), &GameplayDefinitionCatalog::set_tag_definitions);
	ClassDB::bind_method(D_METHOD("get_tag_definitions"), &GameplayDefinitionCatalog::get_tag_definitions);
	ClassDB::bind_method(D_METHOD("set_attribute_definitions", "attributes"),
			&GameplayDefinitionCatalog::set_attribute_definitions);
	ClassDB::bind_method(D_METHOD("get_attribute_definitions"), &GameplayDefinitionCatalog::get_attribute_definitions);
	ClassDB::bind_method(D_METHOD("set_effect_definitions", "effects"), &GameplayDefinitionCatalog::set_effect_definitions);
	ClassDB::bind_method(D_METHOD("get_effect_definitions"), &GameplayDefinitionCatalog::get_effect_definitions);
	ClassDB::bind_method(D_METHOD("set_ability_definitions", "abilities"),
			&GameplayDefinitionCatalog::set_ability_definitions);
	ClassDB::bind_method(D_METHOD("get_ability_definitions"), &GameplayDefinitionCatalog::get_ability_definitions);
	ClassDB::bind_method(D_METHOD("set_cue_definitions", "cues"), &GameplayDefinitionCatalog::set_cue_definitions);
	ClassDB::bind_method(D_METHOD("get_cue_definitions"), &GameplayDefinitionCatalog::get_cue_definitions);
	ClassDB::bind_method(D_METHOD("set_target_data_schemas", "schemas"),
			&GameplayDefinitionCatalog::set_target_data_schemas);
	ClassDB::bind_method(D_METHOD("get_target_data_schemas"), &GameplayDefinitionCatalog::get_target_data_schemas);
	ClassDB::bind_method(D_METHOD("set_tag_reactions", "reactions"), &GameplayDefinitionCatalog::set_tag_reactions);
	ClassDB::bind_method(D_METHOD("get_tag_reactions"), &GameplayDefinitionCatalog::get_tag_reactions);

	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "tag_definitions", PROPERTY_HINT_ARRAY_TYPE,
						 vformat("%d/%d:GameplayTagDefinition", Variant::OBJECT, PROPERTY_HINT_RESOURCE_TYPE)),
			"set_tag_definitions", "get_tag_definitions");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "attribute_definitions", PROPERTY_HINT_ARRAY_TYPE,
						 vformat("%d/%d:GameplayAttributeDefinition", Variant::OBJECT, PROPERTY_HINT_RESOURCE_TYPE)),
			"set_attribute_definitions", "get_attribute_definitions");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "effect_definitions", PROPERTY_HINT_ARRAY_TYPE,
						 vformat("%d/%d:GameplayEffectDefinition", Variant::OBJECT, PROPERTY_HINT_RESOURCE_TYPE)),
			"set_effect_definitions", "get_effect_definitions");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "ability_definitions", PROPERTY_HINT_ARRAY_TYPE,
						 vformat("%d/%d:GameplayAbilityDefinition", Variant::OBJECT, PROPERTY_HINT_RESOURCE_TYPE)),
			"set_ability_definitions", "get_ability_definitions");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "cue_definitions", PROPERTY_HINT_ARRAY_TYPE,
						 vformat("%d/%d:GameplayCueDefinition", Variant::OBJECT, PROPERTY_HINT_RESOURCE_TYPE)),
			"set_cue_definitions", "get_cue_definitions");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "target_data_schemas", PROPERTY_HINT_ARRAY_TYPE,
						 vformat("%d/%d:GameplayTargetDataSchema", Variant::OBJECT, PROPERTY_HINT_RESOURCE_TYPE)),
			"set_target_data_schemas", "get_target_data_schemas");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "tag_reactions", PROPERTY_HINT_ARRAY_TYPE,
						 vformat("%d/%d:GameplayTagReactionDefinition", Variant::OBJECT, PROPERTY_HINT_RESOURCE_TYPE)),
			"set_tag_reactions", "get_tag_reactions");
}

} // namespace godot
