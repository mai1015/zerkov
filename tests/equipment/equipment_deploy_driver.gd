extends RefCounted
## Exercise production equipment-to-weapon and equipment-to-ability wiring from
## the actual deployed Character screen, not a separately configured fixture.
const C = preload("res://game/content/zerkov_equipment_ability_content.gd")

func run(driver: RefCounted, item_id: int) -> bool:
	var row: Dictionary = {}
	for candidate: Dictionary in driver.game._session.combat._rows:
		if candidate.actor_id.is_equal(driver.game._session.raid.admission().actor_id): row = candidate; break
	var component := row.get("component") as GameplayAbilityComponent
	var adapter := row.get("equipment_abilities") as InventoryAbilityAdapter
	if not driver.check(component != null and adapter != null, "production player owns an equipment-ability binding"): return false
	if not state(driver, component, true, 2, "persisted gear granted on deployment"): return false
	var weapon_key: String = driver.game._session.hud_model.confirmed_frame().weapon.instance_id
	if not await driver.click(driver.named("InventoryContent/CharacterColumn/SlingSlot")): return false
	if not driver.check(driver.gear(driver.PRIMARY).is_empty(), "deployed UI unequips actual primary"): return false
	if not state(driver, component, true, 2, "paused widget cannot directly revoke GAS"): return false
	await driver.key(KEY_ESCAPE)
	if not driver.route("hud") or not driver.check(driver.game.advance(), "canonical tick reconciles unequip"): return false
	if not state(driver, component, false, 1, "unequip revokes only the firearm equipment grant"): return false
	if not driver.check(not driver.game._session.hud_model.snapshot().has_weapon and adapter.current_sources().size() == 1,
		"weapon and ability projections agree after unequip"): return false
	var count: int = component.get_diagnostics().grant_count
	for _i in range(2):
		if not driver.check(driver.game.advance(), "unchanged equipment tick"): return false
	if not driver.check(component.get_diagnostics().grant_count == count and adapter.current_sources().size() == 1,
		"unchanged ticks do not duplicate equipment grants"): return false
	await driver.key(KEY_I)
	if not driver.route("inventory"): return false
	await driver.linger("Raid: unequip revokes the weapon and its equipment ability")
	var item: Control = driver.item_slot("backpack", String(ZerkovInventoryCatalog.ITEM_AKM))
	if not driver.check(item != null and item.get("item").item_id == item_id, "same deployed item remains in storage"): return false
	if not await driver.click(item) or not await driver.click(driver.named("InventoryContent/CharacterColumn/SlingSlot")): return false
	await driver.key(KEY_ESCAPE)
	if not driver.route("hud") or not driver.check(driver.game.advance(), "canonical tick reconciles re-equip"): return false
	if not state(driver, component, true, 2, "re-equip restores one firearm contributor"): return false
	if not driver.check(driver.game._session.hud_model.snapshot().has_weapon and adapter.current_sources().size() == 2
		and driver.game._session.hud_model.confirmed_frame().weapon.instance_id == weapon_key,
		"re-equip restores same weapon identity without duplicate abilities"): return false
	count = component.get_diagnostics().grant_count
	for _i in range(2):
		if not driver.check(driver.game.advance(), "unchanged re-equipped tick"): return false
	if not driver.check(component.get_diagnostics().grant_count == count, "same gear remains idempotent on later ticks"): return false
	await driver.key(KEY_I)
	if not driver.route("inventory"): return false
	await driver.linger("Raid: re-equip restores the same item, weapon and ability")
	return true

func state(driver: RefCounted, component: GameplayAbilityComponent, primary: bool, count: int, label: String) -> bool:
	return driver.check(component.has_tag_exact(String(C.TAG_AKM_EQUIPPED)) == primary
		and component.has_tag_exact(String(C.TAG_MACHETE_EQUIPPED))
		and is_equal_approx(component.get_attribute_current(String(C.ATTRIBUTE_READIED_WEAPON_COUNT)), float(count)), label)
