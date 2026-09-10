class_name ZerkovCombatContent
extends RefCounted
## First-playable weapon and melee content.
##
## Weapon System owns the sealed AKM firearm definitions below.  Its V1
## catalog intentionally has no melee mechanism, so the machete is kept as a
## game-owned authoritative melee definition.  The two data sets share stable
## IDs and fixed units, but the machete is never fabricated as a
## WeaponDefinitionResource or registered with WeaponDefinitionCatalog.

const CONTENT_VERSION: int = 1

# Public game/content identities.  The inventory catalog owns the item records;
# these identifiers are the combat-side definitions those records point to.
const ITEM_AKM: StringName = &"zerkov.item.weapon.akm"
const ITEM_MACHETE: StringName = &"zerkov.item.weapon.machete"
const ITEM_AMMO_762X39: StringName = &"zerkov.item.ammo.caliber_762x39_standard"
const ITEM_MAGAZINE_AKM: StringName = &"zerkov.item.magazine.akm_30"

const WEAPON_AKM: StringName = &"zerkov.weapon.akm"
const WEAPON_MACHETE: StringName = &"zerkov.weapon.machete"
const MELEE_MACHETE: StringName = WEAPON_MACHETE
const MELEE_CONTENT_DOMAIN: String = "zerkov.combat.melee"
# Short aliases make the cross-domain identity hand-off explicit without
# introducing a second spelling for any canonical identifier.
const AKM_ID: StringName = WEAPON_AKM
const MACHETE_ID: StringName = MELEE_MACHETE

const SHOT_PROFILE_AKM: StringName = &"zerkov.shot.akm"
const RECOIL_PROFILE_AKM: StringName = &"zerkov.recoil.akm"
const AMMO_PROFILE_762X39_STANDARD: StringName = &"zerkov.item.ammo.762x39.standard"
const AMMO_762X39_STANDARD: StringName = AMMO_PROFILE_762X39_STANDARD
const AMMO_TRAIT_762X39: StringName = &"zerkov.trait.ammo.caliber_762x39"
const MAGAZINE_TRAIT_AKM: StringName = &"zerkov.trait.magazine.akm"
const ITEM_AMMO_762: StringName = ITEM_AMMO_762X39
const AMMO_PROFILE_762X39: StringName = AMMO_PROFILE_762X39_STANDARD
const AMMO_TRAIT_762: StringName = AMMO_TRAIT_762X39

const ATTACHMENT_RED_DOT: StringName = &"zerkov.attachment.red_dot"
const ATTACHMENT_MUZZLE_BRAKE: StringName = &"zerkov.attachment.muzzle_brake"
const ATTACHMENT_VERTICAL_GRIP: StringName = &"zerkov.attachment.vertical_grip"

const SLOT_AKM_OPTIC: StringName = &"zerkov.slot.akm.optic"
const SLOT_AKM_MUZZLE: StringName = &"zerkov.slot.akm.muzzle"
const SLOT_AKM_GRIP: StringName = &"zerkov.slot.akm.grip"

const AKM_CAPACITY: int = 30
const AKM_CADENCE_TICKS: int = 9
const AKM_RELOAD_TICKS: int = 72
const AKM_DAMAGE_MILLIUNITS: int = 42_000
const AKM_RANGE_MILLIUNITS: int = 120_000
const AKM_NOISE_RADIUS_MILLIUNITS: int = 85_000
const AKM_ACCURACY_MOA_MILLI: int = 3_500
const AKM_AIM_TOLERANCE_MICRORADIANS: int = 250_000
const AKM_ORIGIN_TOLERANCE_MILLIUNITS: int = 750

# Machete values are game-owned combat values.  Distances/damage use the
# Weapon System's integer milliunit vocabulary so the later melee authority can
# cross the same ZWorldUnits boundary without floats.  Time is authoritative
# 60 Hz ticks, not animation time.
const MACHETE_DAMAGE_MILLIUNITS: int = 55_000
const MACHETE_REACH_MILLIUNITS: int = 1_750
const MACHETE_SWEEP_RADIUS_MILLIUNITS: int = 350
const MACHETE_WINDUP_TICKS: int = 10
const MACHETE_ACTIVE_TICKS: int = 3
const MACHETE_RECOVERY_TICKS: int = 18
const MACHETE_STAMINA_COST_MICROUNITS: int = 175_000
const MACHETE_MAX_TARGETS: int = 1

# Game-owned melee validation uses the same conservative numeric envelope as
# the vendored weapon authority where the units overlap.  These limits keep a
# future content edit from smuggling an unbounded integer into the later melee
# authority while leaving the native WeaponDefinitionCatalog as the source of
# truth for firearm limits.
const MAX_MELEE_DAMAGE_MILLIUNITS: int = 1_000_000_000
const MAX_MELEE_WORLD_MILLIUNITS: int = 1_000_000_000
const MAX_MELEE_TICK_DURATION: int = 3_600_000
const MAX_MELEE_STAMINA_COST_MICROUNITS: int = 1_000_000_000
const MAX_MELEE_TARGETS: int = 1

const FIRST_PLAYABLE_ATTACHMENT_IDS: PackedStringArray = [
	ATTACHMENT_RED_DOT,
	ATTACHMENT_MUZZLE_BRAKE,
	ATTACHMENT_VERTICAL_GRIP,
]


## Returns the mutable editor-facing Resources used to build the native catalog.
## The returned arrays are intentionally not themselves authoritative; callers
## must use validate_resource_bundle() and build_sealed_content().
static func build_resource_bundle() -> Dictionary:
	var shot_profiles: Array[HitscanShotProfileResource] = [_akm_shot_profile()]
	var recoil_profiles: Array[RecoilProfileResource] = [_akm_recoil_profile()]
	var attachments: Array[AttachmentDefinitionResource] = _attachments()
	var ammo_profiles: Array[AmmunitionBallisticProfileResource] = [_762x39_ammo_profile()]
	var weapons: Array[WeaponDefinitionResource] = [_akm_weapon_definition()]
	var melee_weapons: Array[Dictionary] = [_machete_definition()]
	return {
		"shot_profiles": shot_profiles,
		"recoil_profiles": recoil_profiles,
		"attachments": attachments,
		"ammo_profiles": ammo_profiles,
		"weapons": weapons,
		"melee_weapons": melee_weapons,
	}


## Alias kept deliberately small for callers that use the inventory catalog's
## build_resource naming convention.
static func build_resource() -> Dictionary:
	return build_resource_bundle()


## Runs the add-on's native scratch-catalog validation without mutating a live
## catalog.  This is the editor/CI preflight for the subsequent register/seal
## path and returns the native {ok, findings, truncated, fingerprint} shape.
static func validate_resource_bundle() -> Dictionary:
	var shot_profiles: Array[HitscanShotProfileResource] = [_akm_shot_profile()]
	var recoil_profiles: Array[RecoilProfileResource] = [_akm_recoil_profile()]
	var attachments: Array[AttachmentDefinitionResource] = _attachments()
	var ammo_profiles: Array[AmmunitionBallisticProfileResource] = [_762x39_ammo_profile()]
	var weapons: Array[WeaponDefinitionResource] = [_akm_weapon_definition()]
	var native_report: Dictionary = WeaponDefinitionCatalog.validate_catalog(
		shot_profiles,
		recoil_profiles,
		attachments,
		ammo_profiles,
		weapons,
	)
	var melee_report: Dictionary = _validate_melee_definitions([_machete_definition()])
	native_report["melee"] = melee_report
	native_report["ok"] = bool(native_report.get("ok", false)) and bool(melee_report.get("ok", false))
	return native_report


## Builds and seals the native Resource catalog, retaining no mutable Resource
## references in the returned WeaponDefinitionCatalog.  The result dictionary
## is useful to a bootstrapper because it carries both registration evidence and
## the game-owned melee boundary.
static func build_sealed_content() -> Dictionary:
	var shot_profiles: Array[HitscanShotProfileResource] = [_akm_shot_profile()]
	var recoil_profiles: Array[RecoilProfileResource] = [_akm_recoil_profile()]
	var attachments: Array[AttachmentDefinitionResource] = _attachments()
	var ammo_profiles: Array[AmmunitionBallisticProfileResource] = [_762x39_ammo_profile()]
	var weapons: Array[WeaponDefinitionResource] = [_akm_weapon_definition()]
	var melee_weapons: Array[Dictionary] = [_machete_definition()]

	var validation: Dictionary = WeaponDefinitionCatalog.validate_catalog(
		shot_profiles,
		recoil_profiles,
		attachments,
		ammo_profiles,
		weapons,
	)
	var melee_validation: Dictionary = _validate_melee_definitions(melee_weapons)
	var catalog := WeaponDefinitionCatalog.new()
	var registration: Array[Dictionary] = []
	if bool(validation.get("ok", false)) and bool(melee_validation.get("ok", false)):
		registration.append(catalog.register_shot_profile(shot_profiles[0]))
		registration.append(catalog.register_recoil_profile(recoil_profiles[0]))
		for attachment in attachments:
			registration.append(catalog.register_attachment(attachment))
		registration.append(catalog.register_ballistic_profile(ammo_profiles[0]))
		registration.append(catalog.register_weapon(weapons[0]))
	else:
		# Keep the shape deterministic when a future edit fails preflight.  No
		# partially registered catalog is presented as sealed content.
		return {
			"ok": false,
			"catalog": null,
			"validation": validation,
			"melee_validation": melee_validation,
			"registration": registration,
			"seal": {},
			"resources": {
				"shot_profiles": shot_profiles,
				"recoil_profiles": recoil_profiles,
				"attachments": attachments,
				"ammo_profiles": ammo_profiles,
				"weapons": weapons,
				"melee_weapons": melee_weapons,
			},
		}

	var registration_ok := true
	for result in registration:
		if not bool(result.get("ok", false)):
			registration_ok = false
	var seal: Dictionary = catalog.seal() if registration_ok else {}
	var ok := registration_ok and bool(seal.get("ok", false)) and catalog.is_sealed()
	return {
		"ok": ok,
		"catalog": catalog if ok else null,
		"validation": validation,
		"melee_validation": melee_validation,
		"registration": registration,
		"seal": seal,
		"resources": {
			"shot_profiles": shot_profiles,
			"recoil_profiles": recoil_profiles,
			"attachments": attachments,
			"ammo_profiles": ammo_profiles,
			"weapons": weapons,
			"melee_weapons": melee_weapons,
		},
	}


## Convenience API for code that only needs the sealed native catalog.
static func build_sealed_catalog() -> WeaponDefinitionCatalog:
	var content: Dictionary = build_sealed_content()
	return content.get("catalog") as WeaponDefinitionCatalog


## Alias matching the inventory catalog's concise sealed-catalog factory name.
static func build_catalog() -> WeaponDefinitionCatalog:
	return build_sealed_catalog()


## Returns the five Dictionary arrays accepted by WeaponAuthority.configure().
## This repeats the native Resource values because the vendored add-on exposes
## two separate catalog owners and has no Resource-to-authority bridge yet.
static func build_runtime_configuration() -> Dictionary:
	return {
		"shot_profiles": [_runtime_akm_shot_profile()],
		"weapons": [_runtime_akm_weapon_definition()],
		"recoil_profiles": [_runtime_akm_recoil_profile()],
		"attachments": _runtime_attachments(),
		"ammo_profiles": [_runtime_762x39_ammo_profile()],
	}


## Configures a caller-owned live authority from the same values that passed the
## Resource catalog preflight.  This is startup setup only; configure() replaces
## the authority's prior catalog and live instances by add-on contract.
static func configure_authority(authority: WeaponAuthority) -> Dictionary:
	if authority == null:
		return {"ok": false, "message": "WeaponAuthority is null."}
	var runtime: Dictionary = build_runtime_configuration()
	return authority.configure(
		runtime["shot_profiles"],
		runtime["weapons"],
		runtime["recoil_profiles"],
		runtime["attachments"],
		runtime["ammo_profiles"],
	)


## Returns the one authoritative melee definition.  It is intentionally a
## plain game-owned dictionary rather than a WeaponDefinitionResource: the
## Weapon System V1 vocabulary has no melee mechanism and rejects projectile or
## automatic/deferred mechanism values at catalog validation time.
static func melee_definitions() -> Array[Dictionary]:
	return [_machete_definition()]


static func validate_melee_content() -> Dictionary:
	return _validate_melee_definitions(melee_definitions())


static func _akm_shot_profile() -> HitscanShotProfileResource:
	var profile := HitscanShotProfileResource.new()
	profile.identifier = SHOT_PROFILE_AKM
	profile.version = CONTENT_VERSION
	profile.damage_milliunits = AKM_DAMAGE_MILLIUNITS
	profile.range_milliunits = AKM_RANGE_MILLIUNITS
	# Legacy field retained for the façade; authoritative dispersion uses the
	# weapon's integer accuracy_moa_milli field instead.
	profile.spread_microradians = 0
	profile.aim_tolerance_microradians = AKM_AIM_TOLERANCE_MICRORADIANS
	profile.origin_tolerance_milliunits = AKM_ORIGIN_TOLERANCE_MILLIUNITS
	return profile


static func _akm_recoil_profile() -> RecoilProfileResource:
	var profile := RecoilProfileResource.new()
	profile.identifier = RECOIL_PROFILE_AKM
	profile.version = CONTENT_VERSION
	profile.vertical_kick_nrad = 4_800_000
	profile.horizontal_kick_min_nrad = -1_800_000
	profile.horizontal_kick_max_nrad = 1_800_000
	profile.recovery_per_tick_nrad = 550_000
	profile.max_vertical_offset_nrad = 24_000_000
	profile.max_horizontal_offset_nrad = 12_000_000
	return profile


static func _762x39_ammo_profile() -> AmmunitionBallisticProfileResource:
	var profile := AmmunitionBallisticProfileResource.new()
	profile.identifier = AMMO_PROFILE_762X39_STANDARD
	profile.version = CONTENT_VERSION
	profile.ammunition_trait = AMMO_TRAIT_762X39
	return profile


static func _akm_weapon_definition() -> WeaponDefinitionResource:
	var weapon := WeaponDefinitionResource.new()
	weapon.identifier = WEAPON_AKM
	weapon.version = CONTENT_VERSION
	weapon.mechanism = WeaponDefinitionResource.MECHANISM_HITSCAN_2D
	weapon.fire_mode = WeaponDefinitionResource.FIRE_MODE_SEMI_AUTO
	weapon.shot_profile_id = SHOT_PROFILE_AKM
	weapon.shot_profile_version = CONTENT_VERSION
	weapon.ammunition_trait = AMMO_TRAIT_762X39
	weapon.capacity = AKM_CAPACITY
	weapon.cadence_ticks = AKM_CADENCE_TICKS
	weapon.reload_ticks = AKM_RELOAD_TICKS
	weapon.noise_radius_milliunits = AKM_NOISE_RADIUS_MILLIUNITS
	weapon.accuracy_moa_milli = AKM_ACCURACY_MOA_MILLI
	weapon.recoil_profile_id = RECOIL_PROFILE_AKM
	weapon.recoil_profile_version = CONTENT_VERSION
	var slots: Array[WeaponAttachmentSlotResource] = [
		_slot(SLOT_AKM_OPTIC, WeaponAttachmentSlotResource.SLOT_KIND_OPTIC),
		_slot(SLOT_AKM_MUZZLE, WeaponAttachmentSlotResource.SLOT_KIND_MUZZLE),
		_slot(SLOT_AKM_GRIP, WeaponAttachmentSlotResource.SLOT_KIND_GRIP),
	]
	weapon.attachment_slots = slots
	return weapon


static func _slot(identifier: StringName, kind: int) -> WeaponAttachmentSlotResource:
	var slot := WeaponAttachmentSlotResource.new()
	slot.slot_id = identifier
	slot.slot_kind = kind
	return slot


static func _attachments() -> Array[AttachmentDefinitionResource]:
	return [
		_attachment(
			ATTACHMENT_RED_DOT,
			AttachmentDefinitionResource.SLOT_KIND_BIT_OPTIC,
			["zerkov.tag.optic", "zerkov.tag.akm"],
			-150_000,
			0,
			0,
			0,
			0,
		),
		_attachment(
			ATTACHMENT_MUZZLE_BRAKE,
			AttachmentDefinitionResource.SLOT_KIND_BIT_MUZZLE,
			["zerkov.tag.muzzle", "zerkov.tag.akm"],
			0,
			-200_000,
			-50_000,
			0,
			0,
		),
		_attachment(
			ATTACHMENT_VERTICAL_GRIP,
			AttachmentDefinitionResource.SLOT_KIND_BIT_GRIP,
			["zerkov.tag.grip", "zerkov.tag.akm"],
			0,
			-100_000,
			0,
			-50_000,
			0,
		),
	]


static func _attachment(
	identifier: StringName,
	compatible_slot_kinds_mask: int,
	compatible_tags: Array,
	accuracy_modifier_ppm: int,
	recoil_modifier_ppm: int,
	noise_modifier_ppm: int,
	reload_duration_modifier_ppm: int,
	cadence_modifier_ppm: int,
) -> AttachmentDefinitionResource:
	var attachment := AttachmentDefinitionResource.new()
	attachment.identifier = identifier
	attachment.version = CONTENT_VERSION
	attachment.compatible_slot_kinds_mask = compatible_slot_kinds_mask
	attachment.compatible_tags = PackedStringArray(compatible_tags)
	attachment.accuracy_modifier_ppm = accuracy_modifier_ppm
	attachment.recoil_modifier_ppm = recoil_modifier_ppm
	attachment.noise_modifier_ppm = noise_modifier_ppm
	attachment.reload_duration_modifier_ppm = reload_duration_modifier_ppm
	attachment.cadence_modifier_ppm = cadence_modifier_ppm
	attachment.provided_slot_count = 0
	return attachment


static func _machete_definition() -> Dictionary:
	return {
		"identifier": String(MELEE_MACHETE),
		"item_identifier": String(ITEM_MACHETE),
		"version": CONTENT_VERSION,
		"domain": MELEE_CONTENT_DOMAIN,
		"authoritative": true,
		"weapon_system_owned": false,
		"damage_milliunits": MACHETE_DAMAGE_MILLIUNITS,
		"reach_milliunits": MACHETE_REACH_MILLIUNITS,
		"sweep_radius_milliunits": MACHETE_SWEEP_RADIUS_MILLIUNITS,
		"windup_ticks": MACHETE_WINDUP_TICKS,
		"active_ticks": MACHETE_ACTIVE_TICKS,
		"recovery_ticks": MACHETE_RECOVERY_TICKS,
		"stamina_cost_microunits": MACHETE_STAMINA_COST_MICROUNITS,
		"max_targets": MACHETE_MAX_TARGETS,
		"cancel_before_active": true,
	}


static func _runtime_akm_shot_profile() -> Dictionary:
	return {
		"id": String(SHOT_PROFILE_AKM),
		"version": CONTENT_VERSION,
		"damage_milliunits": AKM_DAMAGE_MILLIUNITS,
		"range_milliunits": AKM_RANGE_MILLIUNITS,
		"spread_microradians": 0,
		"aim_tolerance_microradians": AKM_AIM_TOLERANCE_MICRORADIANS,
		"origin_tolerance_milliunits": AKM_ORIGIN_TOLERANCE_MILLIUNITS,
	}


static func _runtime_akm_recoil_profile() -> Dictionary:
	return {
		"id": String(RECOIL_PROFILE_AKM),
		"version": CONTENT_VERSION,
		"vertical_kick_nrad": 4_800_000,
		"horizontal_kick_min_nrad": -1_800_000,
		"horizontal_kick_max_nrad": 1_800_000,
		"recovery_per_tick_nrad": 550_000,
		"max_vertical_offset_nrad": 24_000_000,
		"max_horizontal_offset_nrad": 12_000_000,
	}


static func _runtime_762x39_ammo_profile() -> Dictionary:
	return {
		"id": String(AMMO_PROFILE_762X39_STANDARD),
		"version": CONTENT_VERSION,
		"ammunition_trait": String(AMMO_TRAIT_762X39),
	}


static func _runtime_akm_weapon_definition() -> Dictionary:
	return {
		"id": String(WEAPON_AKM),
		"version": CONTENT_VERSION,
		"shot_profile_id": String(SHOT_PROFILE_AKM),
		"shot_profile_version": CONTENT_VERSION,
		"ammunition_trait": String(AMMO_TRAIT_762X39),
		"capacity": AKM_CAPACITY,
		"cadence_ticks": AKM_CADENCE_TICKS,
		"reload_ticks": AKM_RELOAD_TICKS,
		"noise_radius_milliunits": AKM_NOISE_RADIUS_MILLIUNITS,
		"accuracy_moa_milli": AKM_ACCURACY_MOA_MILLI,
		"recoil_profile_id": String(RECOIL_PROFILE_AKM),
		"recoil_profile_version": CONTENT_VERSION,
		"attachment_slots": [
			{"slot_id": String(SLOT_AKM_OPTIC), "slot_kind": 1},
			{"slot_id": String(SLOT_AKM_MUZZLE), "slot_kind": 2},
			{"slot_id": String(SLOT_AKM_GRIP), "slot_kind": 8},
		],
	}


static func _runtime_attachments() -> Array[Dictionary]:
	return [
		{
			"id": String(ATTACHMENT_RED_DOT),
			"version": CONTENT_VERSION,
			"compatible_slot_kinds_mask": 1,
			"compatible_tags": PackedStringArray(["zerkov.tag.optic", "zerkov.tag.akm"]),
			"accuracy_modifier_ppm": -150_000,
			"recoil_modifier_ppm": 0,
			"noise_modifier_ppm": 0,
			"reload_duration_modifier_ppm": 0,
			"cadence_modifier_ppm": 0,
			"provided_slot_count": 0,
		},
		{
			"id": String(ATTACHMENT_MUZZLE_BRAKE),
			"version": CONTENT_VERSION,
			"compatible_slot_kinds_mask": 2,
			"compatible_tags": PackedStringArray(["zerkov.tag.muzzle", "zerkov.tag.akm"]),
			"accuracy_modifier_ppm": 0,
			"recoil_modifier_ppm": -200_000,
			"noise_modifier_ppm": -50_000,
			"reload_duration_modifier_ppm": 0,
			"cadence_modifier_ppm": 0,
			"provided_slot_count": 0,
		},
		{
			"id": String(ATTACHMENT_VERTICAL_GRIP),
			"version": CONTENT_VERSION,
			"compatible_slot_kinds_mask": 8,
			"compatible_tags": PackedStringArray(["zerkov.tag.grip", "zerkov.tag.akm"]),
			"accuracy_modifier_ppm": 0,
			"recoil_modifier_ppm": -100_000,
			"noise_modifier_ppm": 0,
			"reload_duration_modifier_ppm": -50_000,
			"cadence_modifier_ppm": 0,
			"provided_slot_count": 0,
		},
	]


static func _validate_melee_definitions(definitions: Array) -> Dictionary:
	var findings: Array[Dictionary] = []
	var seen: Dictionary = {}
	for index in range(definitions.size()):
		var definition: Dictionary = definitions[index]
		var identifier := str(definition.get("identifier", ""))
		if not _is_stable_identifier(identifier):
			findings.append({"index": index, "field": "identifier", "message": "invalid stable identifier"})
		if seen.has(identifier):
			findings.append({"index": index, "field": "identifier", "message": "duplicate identifier"})
		seen[identifier] = true
		for field in [
			"damage_milliunits",
			"reach_milliunits",
			"sweep_radius_milliunits",
			"windup_ticks",
			"active_ticks",
			"recovery_ticks",
			"stamina_cost_microunits",
			"max_targets",
		]:
			var value: Variant = definition.get(field, null)
			if typeof(value) != TYPE_INT or int(value) <= 0:
				findings.append({"index": index, "field": field, "message": "must be a positive integer"})
		var bounds := {
			"damage_milliunits": MAX_MELEE_DAMAGE_MILLIUNITS,
			"reach_milliunits": MAX_MELEE_WORLD_MILLIUNITS,
			"sweep_radius_milliunits": MAX_MELEE_WORLD_MILLIUNITS,
			"windup_ticks": MAX_MELEE_TICK_DURATION,
			"active_ticks": MAX_MELEE_TICK_DURATION,
			"recovery_ticks": MAX_MELEE_TICK_DURATION,
			"stamina_cost_microunits": MAX_MELEE_STAMINA_COST_MICROUNITS,
			"max_targets": MAX_MELEE_TARGETS,
		}
		for field in bounds:
			var value: Variant = definition.get(field, null)
			if typeof(value) == TYPE_INT and int(value) > int(bounds[field]):
				findings.append({"index": index, "field": field, "message": "exceeds fixed-unit bound"})
		if int(definition.get("active_ticks", 0)) > int(definition.get("recovery_ticks", 0)):
			findings.append({"index": index, "field": "active_ticks", "message": "active window exceeds recovery"})
		if int(definition.get("max_targets", 0)) != 1:
			findings.append({"index": index, "field": "max_targets", "message": "first-playable melee is single-target"})
		if bool(definition.get("weapon_system_owned", true)):
			findings.append({"index": index, "field": "weapon_system_owned", "message": "machete must remain game-owned"})
		if not bool(definition.get("authoritative", false)):
			findings.append({"index": index, "field": "authoritative", "message": "melee content must be authoritative"})
		if not _is_stable_identifier(str(definition.get("item_identifier", ""))):
			findings.append({"index": index, "field": "item_identifier", "message": "invalid stable item identifier"})
		if str(definition.get("domain", "")) != MELEE_CONTENT_DOMAIN:
			findings.append({"index": index, "field": "domain", "message": "unexpected melee content domain"})
	return {
		"ok": findings.is_empty(),
		"findings": findings,
	}


static func _is_stable_identifier(value: String) -> bool:
	if value.is_empty() or value.length() > 128:
		return false
	var segment_count := 1
	var previous_separator := false
	for index in value.length():
		var code := value.unicode_at(index)
		var is_separator := code == 46 or code == 45 or code == 58 # . - :
		if is_separator:
			if index == 0 or previous_separator:
				return false
			previous_separator = true
			segment_count += 1
			continue
		if not ((code >= 97 and code <= 122) or (code >= 48 and code <= 57) or code == 95):
			return false
		previous_separator = false
	return segment_count >= 2 and not previous_separator
