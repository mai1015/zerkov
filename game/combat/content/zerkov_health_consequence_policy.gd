class_name ZerkovHealthConsequencePolicy
extends RefCounted
## Task 5.6's deterministic injury, due-work, and treatment policy.
##
## Gameplay Abilities owns the effects themselves. This game-owned declaration
## decides which secondary transitions a committed amount evaluates, their
## stable order, and which inventory traits may pay for treatment.

const SCHEMA_VERSION: int = 1
const TREATMENT_BANDAGE: StringName = &"bandage"
const TREATMENT_SPLINT: StringName = &"splint"
const INJURY_HEAVY_BLEED: StringName = &"heavy_bleed"
const INJURY_FRACTURE: StringName = &"fracture"

const HEAVY_BLEED_THRESHOLD_MICROS: int = 25 * ZerkovHealthAbilityContent.FIXED_SCALE
const FRACTURE_THRESHOLD_MICROS: int = 35 * ZerkovHealthAbilityContent.FIXED_SCALE

const MEDICAL_CONTAINER_PRIORITY: Array[StringName] = [
	ZerkovInventoryCatalog.CONTAINER_POCKETS,
	ZerkovInventoryCatalog.CONTAINER_RIG,
	ZerkovInventoryCatalog.CONTAINER_BACKPACK,
	ZerkovInventoryCatalog.CONTAINER_SECURE,
]


static func zone_rules() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for zone_value in ZerkovHealthAbilityContent.body_zone_declarations():
		var zone := zone_value as Dictionary
		var zone_identifier := StringName(zone["zone_identifier"])
		var fracture_threshold := FRACTURE_THRESHOLD_MICROS \
			if zone_identifier == ZerkovHealthAbilityContent.ZONE_LEFT_ARM \
				or zone_identifier == ZerkovHealthAbilityContent.ZONE_RIGHT_ARM \
				or zone_identifier == ZerkovHealthAbilityContent.ZONE_LEFT_LEG \
				or zone_identifier == ZerkovHealthAbilityContent.ZONE_RIGHT_LEG \
			else 0
		result.append({
			"zone_identifier": String(zone_identifier),
			"heavy_bleed_min_damage_micros": HEAVY_BLEED_THRESHOLD_MICROS,
			"fracture_min_damage_micros": fracture_threshold,
			"lethal_at_zero": bool(zone["lethal_at_zero"]),
		})
	return result


static func zone_rule(zone_identifier: StringName) -> Dictionary:
	for rule in zone_rules():
		if StringName(rule["zone_identifier"]) == zone_identifier:
			return rule.duplicate(true)
	return {}


static func injuries_for_damage(
	zone_identifier: StringName,
	applied_damage_micros: int
) -> PackedStringArray:
	var result := PackedStringArray()
	var rule := zone_rule(zone_identifier)
	if rule.is_empty() or applied_damage_micros <= 0:
		return result
	if applied_damage_micros >= int(rule["heavy_bleed_min_damage_micros"]):
		result.append(String(INJURY_HEAVY_BLEED))
	var fracture_threshold := int(rule["fracture_min_damage_micros"])
	if fracture_threshold > 0 and applied_damage_micros >= fracture_threshold:
		result.append(String(INJURY_FRACTURE))
	return result


static func treatment_declaration(treatment: StringName) -> Dictionary:
	if treatment == TREATMENT_BANDAGE:
		return {
			"treatment": String(treatment),
			"item_identifier": String(ZerkovInventoryCatalog.ITEM_BANDAGE),
			"required_trait": String(ZerkovInventoryCatalog.TRAIT_MEDICAL_BANDAGE),
			"injury": String(INJURY_HEAVY_BLEED),
		}
	if treatment == TREATMENT_SPLINT:
		return {
			"treatment": String(treatment),
			"item_identifier": String(ZerkovInventoryCatalog.ITEM_SPLINT),
			"required_trait": String(ZerkovInventoryCatalog.TRAIT_MEDICAL_SPLINT),
			"injury": String(INJURY_FRACTURE),
		}
	return {}


static func declaration() -> Dictionary:
	var containers: Array[String] = []
	for container_identifier in MEDICAL_CONTAINER_PRIORITY:
		containers.append(String(container_identifier))
	return {
		"schema_version": SCHEMA_VERSION,
		"tick_rate": ZerkovHealthAbilityContent.TICK_RATE,
		"ordering": [
			"committed_hits_by_journal_sequence",
			"heavy_bleed_due_by_actor_zone_source",
			"treatments_by_intent_sequence_request",
			"component_advance_by_actor",
		],
		"same_tick_death_precedes_treatment": true,
		"injury_order": [String(INJURY_HEAVY_BLEED), String(INJURY_FRACTURE)],
		"zone_rules": zone_rules(),
		"medical_container_priority": containers,
		"treatments": [
			treatment_declaration(TREATMENT_BANDAGE),
			treatment_declaration(TREATMENT_SPLINT),
		],
	}


static func declaration_digest() -> String:
	return ZCanonicalValue.sha256(declaration())


static func validate() -> Dictionary:
	var findings := PackedStringArray()
	var rules := zone_rules()
	if rules.size() != ZerkovHealthAbilityContent.BODY_ZONE_IDS.size():
		findings.append("zone_rule_count_invalid")
	var seen: Dictionary = {}
	for rule in rules:
		var zone_identifier := String(rule.get("zone_identifier", ""))
		if seen.has(zone_identifier) \
				or not ZerkovHealthAbilityContent.BODY_ZONE_IDS.has(zone_identifier):
			findings.append("zone_rule_identity_invalid")
		seen[zone_identifier] = true
		if int(rule.get("heavy_bleed_min_damage_micros", 0)) <= 0 \
				or int(rule.get("fracture_min_damage_micros", -1)) < 0:
			findings.append("zone_rule_threshold_invalid")
	for treatment in [TREATMENT_BANDAGE, TREATMENT_SPLINT]:
		var medical := treatment_declaration(treatment)
		if medical.is_empty() \
				or not String(medical["item_identifier"]).begins_with("zerkov.item.") \
				or not String(medical["required_trait"]).begins_with("zerkov.trait."):
			findings.append("treatment_declaration_invalid")
	var digest := declaration_digest()
	if digest.length() != 64:
		findings.append("declaration_digest_invalid")
	return {
		"ok": findings.is_empty(),
		"findings": findings,
		"digest": digest,
	}
