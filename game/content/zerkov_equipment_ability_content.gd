class_name ZerkovEquipmentAbilityContent
extends RefCounted
## Product-owned Gameplay Abilities content used by equipped inventory items.
##
## Inventory item definitions remain canonical in ZerkovInventoryCatalog. This
## catalog declares only the derived ability-side state which is present while
## an exact canonical weapon item is equipped. The passive definitions keep
## their executions active so REVOKE_CANCEL_ACTIVE removes their owned
## infinite effects, granted tags, and modifiers as one native ability
## lifecycle operation.

const ATTRIBUTE_READIED_WEAPON_COUNT: StringName = \
	&"zerkov.attribute.equipment.readied_weapon_count"

# Repeated stable identifiers deliberately avoid a script-class dependency
# cycle: ZerkovInventoryCatalog registers this file's mapping before seal.
const ITEM_AKM: StringName = &"zerkov.item.weapon.akm"
const ITEM_MACHETE: StringName = &"zerkov.item.weapon.machete"
const ITEM_RIG_BASIC: StringName = &"zerkov.item.gear.rig_basic"
const ITEM_BACKPACK_DAYPACK: StringName = &"zerkov.item.gear.backpack_daypack"
const ITEM_SECURE_CONTAINER_BASIC: StringName = &"zerkov.item.gear.secure_container_basic"

const ABILITY_AKM_EQUIPPED: StringName = &"zerkov.ability.equipment.akm_equipped"
const ABILITY_MACHETE_EQUIPPED: StringName = \
	&"zerkov.ability.equipment.machete_equipped"

const EFFECT_AKM_EQUIPPED: StringName = &"zerkov.effect.equipment.akm_equipped"
const EFFECT_MACHETE_EQUIPPED: StringName = \
	&"zerkov.effect.equipment.machete_equipped"

const TAG_AKM_EQUIPPED: StringName = &"zerkov.tag.equipment.akm_equipped"
const TAG_MACHETE_EQUIPPED: StringName = \
	&"zerkov.tag.equipment.machete_equipped"

const SLOT_PRIMARY: StringName = &"zerkov.slot.weapon_primary"
const SLOT_MELEE: StringName = &"zerkov.slot.weapon_melee"
const SLOT_RIG: StringName = &"zerkov.slot.rig"
const SLOT_BACKPACK: StringName = &"zerkov.slot.backpack"
const SLOT_SECURE: StringName = &"zerkov.slot.secure"
const INTEGRATION_MAPPING_ID: StringName = \
	&"zerkov.integration.inventory_equipment_abilities_v1"
const DECLARATION_SCHEMA_VERSION: int = 1
const FIXED_SCALE: int = 1_000_000
const MODIFIER_READY_COUNT_MICROS: int = FIXED_SCALE
const MAX_READIED_WEAPON_SOURCES: float = 64.0
const MAX_AUTHORITY_TICK: int = 9_007_199_254_740_000


static func build_definition_catalog() -> GameplayDefinitionCatalog:
	var catalog := GameplayDefinitionCatalog.new()
	catalog.tag_definitions = _tag_definitions()
	catalog.attribute_definitions = _attribute_definitions()
	catalog.effect_definitions = _effect_definitions()
	catalog.ability_definitions = _ability_definitions()
	return catalog


## Initializes only the attribute owned by this content family. It is safe to
## call during composition after a combined Gameplay Abilities catalog has
## configured the component. A matching existing base is an idempotent replay;
## a different base is rejected rather than silently reset.
static func initialize_component(
	component: GameplayAbilityComponent,
	tick: int = 0
) -> Dictionary:
	if component == null or not is_instance_valid(component) \
			or not component.is_configured() or component.is_torn_down() \
			or not component.is_owner_valid() or tick < 0 or tick > MAX_AUTHORITY_TICK:
		return {"accepted": false, "reason": &"ability_component_invalid"}
	if component.has_attribute(String(ATTRIBUTE_READIED_WEAPON_COUNT)):
		if component.get_attribute_base(String(ATTRIBUTE_READIED_WEAPON_COUNT)) != 0.0:
			return {"accepted": false, "reason": &"equipment_attribute_base_conflict"}
		return {"accepted": true, "replayed": true}
	var result: Dictionary = component.initialize_attribute(
		String(ATTRIBUTE_READIED_WEAPON_COUNT), true, 0.0, tick)
	var status := result.get("status", {}) as Dictionary
	return {
		"accepted": bool(status.get("ok", false)),
		"replayed": false,
		"reason": &"" if bool(status.get("ok", false)) \
			else &"equipment_attribute_initialization_failed",
		"status": status.duplicate(true),
	}


## Detached, deterministic declarations consumed by InventoryAbilityAdapter.
## These are not inventory trait payloads: ability Resources belong to the
## game-owned cross-domain adapter/content layer, not the Inventory add-on.
static func equipment_declarations() -> Array[Dictionary]:
	return [
		_equipment_declaration(
			ITEM_AKM,
			SLOT_PRIMARY,
			ABILITY_AKM_EQUIPPED,
			EFFECT_AKM_EQUIPPED,
			TAG_AKM_EQUIPPED),
		_equipment_declaration(
			ITEM_MACHETE,
			SLOT_MELEE,
			ABILITY_MACHETE_EQUIPPED,
			EFFECT_MACHETE_EQUIPPED,
			TAG_MACHETE_EQUIPPED),
	]


static func declaration_for_item(item_definition_identifier: StringName) -> Dictionary:
	for declaration in equipment_declarations():
		if StringName(declaration.get("item_definition_identifier", &"")) \
				== item_definition_identifier:
			return declaration.duplicate(true)
	return {}


## Canonical equipment which is intentionally outside the first-playable
## Gameplay Abilities grant set. Their equipment/capacity role must not churn
## weapon ability specs.
static func no_grant_equipment_declarations() -> Array[Dictionary]:
	return [
		{
			"item_definition_identifier": String(ITEM_RIG_BASIC),
			"allowed_slots": [String(SLOT_RIG)],
			"reason": "no_gameplay_ability_grant",
		},
		{
			"item_definition_identifier": String(ITEM_BACKPACK_DAYPACK),
			"allowed_slots": [String(SLOT_BACKPACK)],
			"reason": "no_gameplay_ability_grant",
		},
		{
			"item_definition_identifier": String(ITEM_SECURE_CONTAINER_BASIC),
			"allowed_slots": [String(SLOT_SECURE)],
			"reason": "no_gameplay_ability_grant",
		},
	]


static func declaration_digest() -> String:
	return ZCanonicalValue.sha256(_canonical_mapping_record())


static func integration_mapping_bytes() -> PackedByteArray:
	var encoded := ZCanonicalValue.encode(_canonical_mapping_record())
	return encoded.to_utf8_buffer() if not encoded.is_empty() else PackedByteArray()


static func _canonical_mapping_record() -> Dictionary:
	# Keep this manifest payload inside ZCanonicalValue's deliberately small
	# grammar: plain strings, ordinary arrays, dictionaries, and fixed-point
	# integers. Runtime Resources may use StringName, PackedStringArray, and
	# floats, but none of those representations leak into this mapping.
	return {
		"schema_version": DECLARATION_SCHEMA_VERSION,
		"fixed_scale": FIXED_SCALE,
		"equipment_declarations": equipment_declarations(),
		"no_grant_equipment_declarations": no_grant_equipment_declarations(),
	}


static func _tag_definitions() -> Array[GameplayTagDefinition]:
	var result: Array[GameplayTagDefinition] = []
	for entry in [
		[TAG_AKM_EQUIPPED, "Canonical AKM equipment effect is active."],
		[TAG_MACHETE_EQUIPPED, "Canonical machete equipment effect is active."],
	]:
		var tag := GameplayTagDefinition.new()
		tag.identifier = entry[0]
		tag.description = entry[1]
		tag.source_label = "Zerkov equipment ability content"
		result.append(tag)
	return result


static func _attribute_definitions() -> Array[GameplayAttributeDefinition]:
	var attribute := GameplayAttributeDefinition.new()
	attribute.identifier = ATTRIBUTE_READIED_WEAPON_COUNT
	attribute.default_base = 0.0
	attribute.has_min = true
	attribute.min_value = 0.0
	attribute.has_max = true
	attribute.max_value = MAX_READIED_WEAPON_SOURCES
	attribute.display_name = "Readied weapon sources"
	return [attribute]


static func _effect_definitions() -> Array[GameplayEffectDefinition]:
	return [
		_effect(EFFECT_AKM_EQUIPPED, TAG_AKM_EQUIPPED),
		_effect(EFFECT_MACHETE_EQUIPPED, TAG_MACHETE_EQUIPPED),
	]


static func _effect(
	identifier: StringName,
	granted_tag: StringName
) -> GameplayEffectDefinition:
	var magnitude := GameplayMagnitude.new()
	magnitude.kind = GameplayMagnitude.KIND_CONSTANT
	magnitude.coefficient = float(MODIFIER_READY_COUNT_MICROS) / float(FIXED_SCALE)
	var modifier := GameplayModifierDeclaration.new()
	modifier.target_attribute = ATTRIBUTE_READIED_WEAPON_COUNT
	modifier.op = GameplayModifierDeclaration.OP_ADD
	modifier.magnitude = magnitude
	modifier.priority = 0
	var effect := GameplayEffectDefinition.new()
	effect.identifier = identifier
	effect.duration_policy = GameplayEffectDefinition.DURATION_INFINITE
	effect.modifiers = [modifier]
	effect.granted_tags = PackedStringArray([granted_tag])
	return effect


static func _ability_definitions() -> Array[GameplayAbilityDefinition]:
	return [
		_ability(ABILITY_AKM_EQUIPPED, EFFECT_AKM_EQUIPPED),
		_ability(ABILITY_MACHETE_EQUIPPED, EFFECT_MACHETE_EQUIPPED),
	]


static func _ability(
	identifier: StringName,
	effect_identifier: StringName
) -> GameplayAbilityDefinition:
	var ability := GameplayAbilityDefinition.new()
	ability.identifier = identifier
	ability.activation_policy = GameplayAbilityDefinition.ACTIVATION_PASSIVE_ON_GRANT
	ability.commit_effects = PackedStringArray([effect_identifier])
	ability.concurrency_policy = GameplayAbilityDefinition.CONCURRENCY_ALLOW_MULTIPLE
	ability.duplicate_grant_policy = GameplayAbilityDefinition.DUPLICATE_GRANT_MULTI_GRANT
	ability.revoke_policy = GameplayAbilityDefinition.REVOKE_CANCEL_ACTIVE
	ability.prediction_policy = GameplayAbilityDefinition.PREDICTION_NOT_PREDICTABLE
	ability.hook_binding = GameplayAbilityDefinition.HOOK_BINDING_NONE
	ability.auto_commit = true
	# The infinite effect must remain execution-owned. With true, the add-on
	# intentionally lets a commit effect outlive the execution and revoke has
	# no public effect-handle removal seam available to this adapter.
	ability.ends_on_commit = false
	return ability


static func _equipment_declaration(
	item_definition_identifier: StringName,
	slot_identifier: StringName,
	ability_identifier: StringName,
	effect_identifier: StringName,
	tag_identifier: StringName
) -> Dictionary:
	return {
		"schema_version": DECLARATION_SCHEMA_VERSION,
		"item_definition_identifier": String(item_definition_identifier),
		"allowed_slots": [String(slot_identifier)],
		"ability_grants": [{
			"ability_identifier": String(ability_identifier),
			"level": 1,
			"effect_identifiers": [String(effect_identifier)],
			"tag_identifiers": [String(tag_identifier)],
			"modifier_delta_micros": {
				String(ATTRIBUTE_READIED_WEAPON_COUNT): MODIFIER_READY_COUNT_MICROS,
			},
		}],
	}
