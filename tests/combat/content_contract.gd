extends SceneTree
## Run with:
## godot --headless --path . --script res://tests/combat/content_contract.gd

var checks: int = 0
var failures: int = 0


func _initialize() -> void:
	call_deferred("run")


func check(condition: bool, message: String) -> void:
	checks += 1
	if condition:
		return
	failures += 1
	push_error("COMBAT_CONTENT_CONTRACT: " + message)


func run() -> void:
	check(ClassDB.class_exists(&"WeaponDefinitionCatalog"), "native catalog class is registered")
	check(ClassDB.class_exists(&"WeaponAuthority"), "native weapon authority class is registered")
	check(ClassDB.class_exists(&"HitscanShotProfileResource"), "native shot Resource is registered")
	check(ClassDB.class_exists(&"RecoilProfileResource"), "native recoil Resource is registered")
	check(ClassDB.class_exists(&"AttachmentDefinitionResource"), "native attachment Resource is registered")
	check(ClassDB.class_exists(&"AmmunitionBallisticProfileResource"), "native ammo Resource is registered")
	check(ClassDB.class_exists(&"WeaponDefinitionResource"), "native weapon Resource is registered")

	var bundle: Dictionary = ZerkovCombatContent.build_resource_bundle()
	var shot_profiles: Array = bundle.get("shot_profiles", [])
	var recoil_profiles: Array = bundle.get("recoil_profiles", [])
	var attachments: Array = bundle.get("attachments", [])
	var ammo_profiles: Array = bundle.get("ammo_profiles", [])
	var weapons: Array = bundle.get("weapons", [])
	var melee_weapons: Array = bundle.get("melee_weapons", [])
	check(shot_profiles.size() == 1, "one AKM hitscan shot profile is authored")
	check(recoil_profiles.size() == 1, "one AKM recoil profile is authored")
	check(attachments.size() == 3, "minimal optic, muzzle, and grip set is authored")
	check(ammo_profiles.size() == 1, "one standard 7.62x39 ballistic profile is authored")
	check(weapons.size() == 1, "one AKM firearm definition is authored")
	check(melee_weapons.size() == 1, "one machete melee definition is authored")
	check(ZerkovCombatContent.ITEM_AKM == ZerkovInventoryCatalog.ITEM_AKM,
		"combat AKM item identity agrees with the inventory catalog")
	check(ZerkovCombatContent.ITEM_MACHETE == ZerkovInventoryCatalog.ITEM_MACHETE,
		"combat machete item identity agrees with the inventory catalog")
	check(ZerkovCombatContent.ITEM_AMMO_762X39 == ZerkovInventoryCatalog.ITEM_AMMO_762,
		"combat ammunition item identity agrees with the inventory catalog")
	check(ZerkovCombatContent.ITEM_MAGAZINE_AKM == ZerkovInventoryCatalog.ITEM_MAGAZINE_AKM,
		"combat magazine item identity agrees with the inventory catalog")
	check(ZerkovCombatContent.AMMO_TRAIT_762X39 == ZerkovInventoryCatalog.TRAIT_AMMO_762,
		"combat ammunition trait agrees with the inventory catalog")
	check(ZerkovCombatContent.MAGAZINE_TRAIT_AKM == ZerkovInventoryCatalog.TRAIT_MAGAZINE_AKM,
		"combat magazine trait agrees with the inventory catalog")

	var shot := shot_profiles[0] as HitscanShotProfileResource
	var recoil := recoil_profiles[0] as RecoilProfileResource
	var ammo := ammo_profiles[0] as AmmunitionBallisticProfileResource
	var akm := weapons[0] as WeaponDefinitionResource
	check(shot != null and shot.identifier == ZerkovCombatContent.SHOT_PROFILE_AKM,
		"AKM shot identifier is stable")
	check(shot != null and shot.damage_milliunits == ZerkovCombatContent.AKM_DAMAGE_MILLIUNITS,
		"AKM shot damage uses fixed milliunits")
	check(shot != null and shot.range_milliunits == ZerkovCombatContent.AKM_RANGE_MILLIUNITS,
		"AKM shot range uses fixed milliunits")
	check(recoil != null and recoil.identifier == ZerkovCombatContent.RECOIL_PROFILE_AKM,
		"AKM recoil identifier is stable")
	check(recoil != null and recoil.max_vertical_offset_nrad >= recoil.vertical_kick_nrad,
		"AKM vertical recoil cap contains one kick")
	check(recoil != null and recoil.max_horizontal_offset_nrad >= maxi(
		absi(recoil.horizontal_kick_min_nrad), absi(recoil.horizontal_kick_max_nrad)),
		"AKM horizontal recoil cap contains one kick")
	check(ammo != null and ammo.identifier == ZerkovCombatContent.AMMO_PROFILE_762X39_STANDARD,
		"7.62x39 ballistic profile identifier is stable")
	check(ammo != null and ammo.ammunition_trait == ZerkovCombatContent.AMMO_TRAIT_762X39,
		"7.62x39 weapon trait agrees with ballistic profile trait")
	check(akm != null and akm.identifier == ZerkovCombatContent.WEAPON_AKM,
		"AKM weapon identifier is stable")
	check(akm != null and akm.mechanism == WeaponDefinitionResource.MECHANISM_HITSCAN_2D,
		"AKM uses the supported hitscan mechanism")
	check(akm != null and akm.fire_mode == WeaponDefinitionResource.FIRE_MODE_SEMI_AUTO,
		"AKM uses the supported semi-auto fire mode")
	check(akm != null and akm.capacity == ZerkovCombatContent.AKM_CAPACITY,
		"AKM capacity is bounded and deterministic")
	check(akm != null and akm.cadence_ticks > 0 and akm.reload_ticks > 0,
		"AKM cadence and reload are positive authority ticks")
	check(akm != null and akm.attachment_slots.size() == 3,
		"AKM declares exactly the minimal flat attachment slots")
	var akm_range := ZWorldUnits.weapon_to_godot(Vector2i(
		ZerkovCombatContent.AKM_RANGE_MILLIUNITS, 0))
	check(akm_range.ok and is_equal_approx(akm_range.vector2_value.x, 120.0 * 32.0),
		"AKM range crosses ZWorldUnits as 120 canonical world units")
	var akm_damage := ZWorldUnits.weapon_damage_to_ability(
		ZerkovCombatContent.AKM_DAMAGE_MILLIUNITS)
	check(akm_damage.ok and akm_damage.integer_value == 42_000_000,
		"AKM damage crosses ZWorldUnits as 42 Gameplay Abilities whole units")

	var native_report: Dictionary = ZerkovCombatContent.validate_resource_bundle()
	check(bool(native_report.get("ok", false)), "native scratch validation accepts all first-playable content")
	check((native_report.get("findings", []) as Array).is_empty(), "native validation findings are empty")
	check(int(native_report.get("truncated_count", 0)) == 0, "native validation diagnostics are not truncated")
	check(int(native_report.get("fingerprint", 0)) != 0, "native validation produces a content fingerprint")
	var melee_report: Dictionary = native_report.get("melee", {})
	check(bool(melee_report.get("ok", false)), "game-owned melee validation accepts the machete")
	check((melee_report.get("findings", []) as Array).is_empty(), "machete validation findings are empty")

	var sealed_content: Dictionary = ZerkovCombatContent.build_sealed_content()
	check(bool(sealed_content.get("ok", false)), "native registration and seal succeed")
	var catalog := sealed_content.get("catalog") as WeaponDefinitionCatalog
	check(catalog != null and catalog.is_sealed(), "returned catalog is sealed")
	if catalog != null:
		check(catalog.shot_profile_count() == 1, "sealed catalog has one shot profile")
		check(catalog.recoil_profile_count() == 1, "sealed catalog has one recoil profile")
		check(catalog.attachment_count() == 3, "sealed catalog has three attachments")
		check(catalog.ammo_profile_count() == 1, "sealed catalog has one ammo profile")
		check(catalog.weapon_count() == 1, "sealed catalog has one firearm")
		var sealed_fingerprint := catalog.fingerprint()
		var sealed_resources: Dictionary = sealed_content.get("resources", {})
		var mutable_shot := (sealed_resources.get("shot_profiles", []) as Array)[0] as HitscanShotProfileResource
		if mutable_shot != null:
			mutable_shot.damage_milliunits = 1
		check(catalog.fingerprint() == sealed_fingerprint,
			"mutating an authoring Resource cannot change the sealed fingerprint")
		check(sealed_fingerprint == int(native_report.get("fingerprint", 0)),
			"registration/seal fingerprint matches native scratch validation")

	var melee: Dictionary = melee_weapons[0]
	check(str(melee.get("identifier", "")) == String(ZerkovCombatContent.MELEE_MACHETE),
		"machete has its own stable game-owned identifier")
	check(str(melee.get("item_identifier", "")) == String(ZerkovCombatContent.ITEM_MACHETE),
		"machete links to its inventory item identity")
	check(bool(melee.get("authoritative", false)), "machete is authoritative data")
	check(not bool(melee.get("weapon_system_owned", true)),
		"machete is explicitly outside Weapon System ownership")
	check(not melee.has("mechanism"), "machete does not fabricate an unsupported Weapon System mechanism")
	check(int(melee.get("windup_ticks", 0)) > 0 and int(melee.get("active_ticks", 0)) > 0
		and int(melee.get("recovery_ticks", 0)) > int(melee.get("active_ticks", 0)),
		"machete timing is positive and recovery follows active window")
	check(int(melee.get("reach_milliunits", 0)) > 0 and int(melee.get("damage_milliunits", 0)) > 0,
		"machete reach and damage use positive fixed milliunits")
	check(int(melee.get("max_targets", 0)) == 1, "machete has a bounded single-target consequence")
	var machete_reach := ZWorldUnits.weapon_to_godot(Vector2i(
		int(melee.get("reach_milliunits", 0)), 0))
	check(machete_reach.ok and is_equal_approx(machete_reach.vector2_value.x, 56.0),
		"machete reach crosses ZWorldUnits as 1.75 canonical world units")
	var machete_damage := ZWorldUnits.weapon_damage_to_ability(
		int(melee.get("damage_milliunits", 0)))
	check(machete_damage.ok and machete_damage.integer_value == 55_000_000,
		"machete damage crosses ZWorldUnits as 55 Gameplay Abilities whole units")

	var runtime: Dictionary = ZerkovCombatContent.build_runtime_configuration()
	check(runtime.has("shot_profiles") and runtime.has("weapons") and runtime.has("recoil_profiles")
		and runtime.has("attachments") and runtime.has("ammo_profiles"),
		"live authority Dictionary configuration exposes all five native arrays")
	_check_resource_runtime_parity(shot, recoil, ammo, akm, attachments, runtime)
	var authority := WeaponAuthority.new()
	get_root().add_child(authority)
	var configured: Dictionary = authority.configure(
		runtime["shot_profiles"],
		runtime["weapons"],
		runtime["recoil_profiles"],
		runtime["attachments"],
		runtime["ammo_profiles"],
	)
	check(bool(configured.get("ok", false)), "live WeaponAuthority accepts the authored configuration")
	# configure() seals a native copy. Mutating every caller-owned Dictionary
	# family afterward must not change instance creation or attachment rules.
	(runtime["shot_profiles"][0] as Dictionary)["damage_milliunits"] = 1
	(runtime["weapons"][0] as Dictionary)["capacity"] = 1
	(runtime["ammo_profiles"][0] as Dictionary)["ammunition_trait"] = "zerkov.trait.ammo.invalid"
	(runtime["attachments"][0] as Dictionary)["compatible_slot_kinds_mask"] = 0
	var created: Dictionary = authority.create_weapon(
		"zerkov.test.weapon.akm",
		ZerkovCombatContent.WEAPON_AKM,
		ZerkovCombatContent.CONTENT_VERSION,
		ZerkovCombatContent.AKM_CAPACITY,
		{"id": String(ZerkovCombatContent.AMMO_PROFILE_762X39_STANDARD), "version": 1},
	)
	check(bool(created.get("ok", false)), "AKM instance accepts the authored ballistic profile")
	var state: Dictionary = authority.snapshot("zerkov.test.weapon.akm")
	check(state.get("definition_id", StringName()) == ZerkovCombatContent.WEAPON_AKM,
		"live snapshot preserves the stable AKM definition identity")
	var attachments_result: Dictionary = authority.configure_attachments({
		"command_id": "zerkov.test.attachments.akm",
		"sequence": 1,
		"instance_id": "zerkov.test.weapon.akm",
		"expected_revision": int(state.get("revision", -1)),
		"tick": 0,
		"desired_loadout": [
			{
				"slot_id": String(ZerkovCombatContent.SLOT_AKM_OPTIC),
				"attachment_id": String(ZerkovCombatContent.ATTACHMENT_RED_DOT),
				"attachment_version": 1,
			},
			{
				"slot_id": String(ZerkovCombatContent.SLOT_AKM_MUZZLE),
				"attachment_id": String(ZerkovCombatContent.ATTACHMENT_MUZZLE_BRAKE),
				"attachment_version": 1,
			},
			{
				"slot_id": String(ZerkovCombatContent.SLOT_AKM_GRIP),
				"attachment_id": String(ZerkovCombatContent.ATTACHMENT_VERTICAL_GRIP),
				"attachment_version": 1,
			},
		],
	})
	check(bool(attachments_result.get("accepted", false)), "minimal attachment loadout is accepted atomically")
	check(int(authority.snapshot("zerkov.test.weapon.akm").get("loaded_rounds", -1))
		== ZerkovCombatContent.AKM_CAPACITY,
		"post-configure Dictionary mutation cannot alter sealed capacity or ammunition content")

	var attached_state: Dictionary = authority.snapshot("zerkov.test.weapon.akm")
	var incompatible_result: Dictionary = authority.configure_attachments({
		"command_id": "zerkov.test.attachments.incompatible",
		"sequence": 2,
		"instance_id": "zerkov.test.weapon.akm",
		"expected_revision": int(attached_state.get("revision", -1)),
		"tick": 0,
		"desired_loadout": [{
			"slot_id": String(ZerkovCombatContent.SLOT_AKM_MUZZLE),
			"attachment_id": String(ZerkovCombatContent.ATTACHMENT_RED_DOT),
			"attachment_version": 1,
		}],
	})
	check(not bool(incompatible_result.get("accepted", false)),
		"an optic is rejected from the AKM muzzle slot")
	var rejected_state: Dictionary = authority.snapshot("zerkov.test.weapon.akm")
	check(int(rejected_state.get("revision", -1)) == int(attached_state.get("revision", -2)),
		"incompatible attachment rejection does not advance mechanical revision")
	check(rejected_state.get("attachment_loadout", []) == attached_state.get("attachment_loadout", []),
		"incompatible attachment rejection preserves the complete prior loadout")

	var convenience_authority := WeaponAuthority.new()
	get_root().add_child(convenience_authority)
	check(bool(ZerkovCombatContent.configure_authority(convenience_authority).get("ok", false)),
		"combat content convenience API configures a separate live authority")

	print("COMBAT_CONTENT_RESULT checks=", checks, " failures=", failures,
		" weapon_count=", catalog.weapon_count() if catalog != null else 0)
	quit(0 if failures == 0 else 1)


func _check_resource_runtime_parity(
	shot: HitscanShotProfileResource,
	recoil: RecoilProfileResource,
	ammo: AmmunitionBallisticProfileResource,
	akm: WeaponDefinitionResource,
	attachments: Array,
	runtime: Dictionary,
) -> void:
	var runtime_shot: Dictionary = runtime["shot_profiles"][0]
	check(runtime_shot == {
		"id": String(shot.identifier),
		"version": shot.version,
		"damage_milliunits": shot.damage_milliunits,
		"range_milliunits": shot.range_milliunits,
		"spread_microradians": shot.spread_microradians,
		"aim_tolerance_microradians": shot.aim_tolerance_microradians,
		"origin_tolerance_milliunits": shot.origin_tolerance_milliunits,
	}, "Resource and live AKM shot profiles have exact field parity")

	var runtime_recoil: Dictionary = runtime["recoil_profiles"][0]
	check(runtime_recoil == {
		"id": String(recoil.identifier),
		"version": recoil.version,
		"vertical_kick_nrad": recoil.vertical_kick_nrad,
		"horizontal_kick_min_nrad": recoil.horizontal_kick_min_nrad,
		"horizontal_kick_max_nrad": recoil.horizontal_kick_max_nrad,
		"recovery_per_tick_nrad": recoil.recovery_per_tick_nrad,
		"max_vertical_offset_nrad": recoil.max_vertical_offset_nrad,
		"max_horizontal_offset_nrad": recoil.max_horizontal_offset_nrad,
	}, "Resource and live AKM recoil profiles have exact field parity")

	var runtime_ammo: Dictionary = runtime["ammo_profiles"][0]
	check(runtime_ammo == {
		"id": String(ammo.identifier),
		"version": ammo.version,
		"ammunition_trait": String(ammo.ammunition_trait),
	}, "Resource and live ammunition profiles have exact field parity")

	var runtime_weapon: Dictionary = runtime["weapons"][0]
	check(not runtime_weapon.has("magazine_id") and not runtime_weapon.has("magazine_item_id"),
		"live Weapon System content does not fabricate a detachable-magazine identity")
	var resource_slots: Array[Dictionary] = []
	for slot_value in akm.attachment_slots:
		var slot := slot_value as WeaponAttachmentSlotResource
		resource_slots.append({
			"slot_id": String(slot.slot_id),
			"slot_kind": 1 << slot.slot_kind,
		})
	check(runtime_weapon == {
		"id": String(akm.identifier),
		"version": akm.version,
		"shot_profile_id": String(akm.shot_profile_id),
		"shot_profile_version": akm.shot_profile_version,
		"ammunition_trait": String(akm.ammunition_trait),
		"capacity": akm.capacity,
		"cadence_ticks": akm.cadence_ticks,
		"reload_ticks": akm.reload_ticks,
		"noise_radius_milliunits": akm.noise_radius_milliunits,
		"accuracy_moa_milli": akm.accuracy_moa_milli,
		"recoil_profile_id": String(akm.recoil_profile_id),
		"recoil_profile_version": akm.recoil_profile_version,
		"attachment_slots": resource_slots,
	}, "Resource and live AKM definitions have exact supported-field parity")

	var runtime_attachments: Array = runtime["attachments"]
	check(runtime_attachments.size() == attachments.size(),
		"Resource and live attachment definition counts agree")
	for index in range(mini(runtime_attachments.size(), attachments.size())):
		var resource_attachment := attachments[index] as AttachmentDefinitionResource
		var runtime_attachment: Dictionary = runtime_attachments[index]
		check(runtime_attachment == {
			"id": String(resource_attachment.identifier),
			"version": resource_attachment.version,
			"compatible_slot_kinds_mask": resource_attachment.compatible_slot_kinds_mask,
			"compatible_tags": resource_attachment.compatible_tags,
			"accuracy_modifier_ppm": resource_attachment.accuracy_modifier_ppm,
			"recoil_modifier_ppm": resource_attachment.recoil_modifier_ppm,
			"noise_modifier_ppm": resource_attachment.noise_modifier_ppm,
			"reload_duration_modifier_ppm": resource_attachment.reload_duration_modifier_ppm,
			"cadence_modifier_ppm": resource_attachment.cadence_modifier_ppm,
			"provided_slot_count": resource_attachment.provided_slot_count,
		}, "Resource and live attachment %d have exact field parity" % index)
