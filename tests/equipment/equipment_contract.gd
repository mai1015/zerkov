extends SceneTree
## Real native inventory / existing bridge / strict intents. Fixture construction
## is limited to this unit test; the separate application test uses New Game UI.
const C = ZerkovInventoryCatalog
const PRIMARY = EquippedItemReconciler.SLOT_PRIMARY
const MELEE = EquippedItemReconciler.SLOT_MELEE
var checks: int = 0
var failures: int = 0
var owner: RaidInventoryOwner
var bridge: InventoryProjectionBridge
var adapter: InventoryIntentAdapter
var controller: InventoryEquipmentController
var admission: ZSessionAdmission
var identity: OfflineInventoryIdentity
var reconciler: EquippedItemReconciler
var serial: int = 100

func _initialize() -> void:
	run.call_deferred()

func check(ok: bool, label: String) -> bool:
	checks += 1
	if not ok:
		failures += 1
		push_error("EQUIPMENT_CONTRACT: " + label)
	return ok

func run() -> void:
	root.size = Vector2i(1920, 1080)
	owner = RaidInventoryOwner.new(); root.add_child(owner)
	if not check(owner.configure() and LocalCampaignContent.equip_starter(owner), "native owner and explicit starter fixture"):
		finish(); return
	var raid_id := ZRaidId.from_parts(PackedStringArray(["equipment", "contract"]))
	admission = SessionCoordinator.new().open_offline(raid_id, &"equipmentcontract")
	identity = OfflineInventoryIdentity.new()
	check(identity.configure(admission, owner, 720009), "exact offline identity")
	bridge = InventoryProjectionBridge.new(); root.add_child(bridge)
	check(bridge.bind_owner(owner, owner.generation()), "real snapshot bridge")
	adapter = InventoryIntentAdapter.new()
	check(adapter.configure(owner, admission, identity, ZInventoryWorldPolicyPort.new(), 3_000_000), "real equipment intent adapter")
	controller = InventoryEquipmentController.new()
	if not check(controller.bind(owner, bridge, adapter, admission), "controller bound: " + String(controller.last_error)):
		finish(); return
	reconciler = EquippedItemReconciler.new(); root.add_child(reconciler)
	check(reconciler.bind_owner(owner, bridge, admission, owner.generation(), bridge.scope_generation(&"raid")), "existing equipment reconciler")
	var initial := controller.equipment_view()
	check(initial.available and initial.slots.size() == 4, "all four canonical slots, including empty")
	check(initial.is_read_only() and initial.slots.is_read_only(), "immutable projection envelope")
	for row: Dictionary in initial.slots:
		check(row.is_read_only() and row.item.is_read_only(), "immutable slot and item records")
	var akm := equipment(PRIMARY)
	var machete := equipment(MELEE)
	check(akm.definition_id == String(C.ITEM_AKM) and machete.definition_id == String(C.ITEM_MACHETE), "actual native primary and melee identities")
	check(equipment(&"zerkov.slot.rig").is_empty() and equipment(&"zerkov.slot.backpack").is_empty(), "no fabricated rig or backpack gear")
	check(controller.grid_size(&"secure") == Vector2i(3, 2), "secure grid canonical dimensions")
	var secure := controller.items_for(&"secure")
	check(secure.size() == 1 and secure[0].definition_id == String(C.ITEM_SPLINT) and secure[0].quantity == 2, "real secure contents")
	check(not controller.mutation_available(&"stash"), "stash remains read only")
	var before := canonical()
	var bad := controller.submit_equip(&"secure", secure[0], PRIMARY)
	check(not bad.accepted and canonical() == before, "incompatible splint rejected without mutation")
	bad = controller.submit_equip(&"secure", controller.items_for(&"secure")[0], &"zerkov.slot.injected")
	check(not bad.accepted and bad.reason == &"equipment_slot_unknown" and canonical() == before, "unknown dotted slot rejected by declaration")
	var unequip := controller.submit_unequip(akm)
	check(unequip.accepted and equipment(PRIMARY).is_empty(), "native unequip -> confirmed empty primary")
	check(equipment(MELEE).item_id == machete.item_id, "other slot unchanged")
	var stale := controller.submit_unequip(akm)
	check(not stale.accepted and stale.reason == controller.REASON_STALE_DRAG_TARGET, "old equipment gesture rejected")
	var pack_akm := find_item(controller.items_for(&"backpack"), akm.item_id)
	check(not pack_akm.is_empty() and pack_akm.location.kind == "spatial", "same item auto-placed in backpack")
	before = canonical()
	bad = controller.submit_equip(&"backpack", pack_akm, MELEE)
	check(not bad.accepted and canonical() == before, "wrong occupied melee slot leaves both items coherent")
	var equip := controller.submit_equip(&"backpack", pack_akm, PRIMARY)
	check(equip.accepted and equipment(PRIMARY).item_id == akm.item_id, "native equip -> same canonical item")
	check(find_item(controller.items_for(&"backpack"), akm.item_id).is_empty(), "single location, not duplicated")
	var replay_request := ZRequestId.parse(String(equip.request_id))
	check(adapter.receipt_for_request(replay_request).accepted, "product receipt retained")
	before = canonical()
	var raw := intent(InventoryIntentAdapter.INTENT_KIND_UNEQUIP, akm.item_id,
		{"kind":"spatial", "container":controller.descriptor(&"backpack").container_id, "x":0,"y":0,"rotated":false})
	var accepted := adapter.submit_intent(raw)
	check(accepted.accepted and canonical() != before, "strict unequip intent executes")
	before = canonical()
	var replay := adapter.submit_intent(raw)
	check(replay.accepted and replay.replayed and canonical() == before, "identical request exactly once")
	var conflict := raw.snapshot(); conflict.payload.destination_location.x = 1
	check(not adapter.submit_intent(conflict).accepted and canonical() == before, "conflicting retry no mutation")
	var stale_revision := intent(InventoryIntentAdapter.INTENT_KIND_EQUIP, akm.item_id,
		{"kind":"slot","container":controller.descriptor(&"equipment").container_id,"slot_identifier":String(PRIMARY)})
	stale_revision.payload.expected_revision -= 1
	check(adapter.submit_intent(stale_revision).reason == &"inventory_revision_stale" and canonical() == before, "stale revision rejected")
	var wrong_container := intent(InventoryIntentAdapter.INTENT_KIND_EQUIP, akm.item_id,
		{"kind":"slot","container":controller.descriptor(&"pockets").container_id,"slot_identifier":String(PRIMARY)})
	check(adapter.submit_intent(wrong_container).reason == &"equipment_slot_unknown" and canonical() == before, "valid slot name in wrong container rejected")
	var wrong_generation := intent(InventoryIntentAdapter.INTENT_KIND_EQUIP, akm.item_id,
		{"kind":"slot","container":controller.descriptor(&"equipment").container_id,"slot_identifier":String(PRIMARY)})
	wrong_generation.generation += 1
	check(adapter.submit_intent(wrong_generation).reason == &"stale_generation" and canonical() == before, "stale generation rejected")
	for kind: StringName in [InventoryIntentAdapter.INTENT_KIND_EQUIP, InventoryIntentAdapter.INTENT_KIND_UNEQUIP]:
		var malformed := intent(kind, akm.item_id, {"kind":"slot","container":controller.descriptor(&"equipment").container_id,"slot_identifier":String(PRIMARY)})
		malformed.payload["unexpected"] = true
		check(adapter.submit_intent(malformed).reason == &"payload_schema_invalid" and canonical() == before, "equipment schema exact keys")
	var current := find_item(controller.items_for(&"backpack"), akm.item_id)
	check(controller.submit_equip(&"backpack", current, PRIMARY).accepted, "re-equip before persistence")
	var saved := owner.raid_authority().make_persistence_record(owner.raid_player_inventory_id)
	var restored := InventoryAuthority.new(); restored.set_catalog(owner.catalog())
	check(restored.apply_persistence_record(saved).ok, "canonical equipment record restores")
	check(restored.snapshot(owner.raid_player_inventory_id).canonical_bytes() == canonical(), "persistence exact bytes")
	restored.free()
	var old := equipment(PRIMARY)
	owner.teardown(owner.generation())
	check(not controller.equipment_view().available and controller.equipment_view().slots.is_empty(), "teardown clears equipment projection")
	check(not controller.submit_unequip(old).accepted, "late equipment input cannot mutate disposed authority")
	finish()

func intent(kind: StringName, item_id: int, location: Dictionary) -> ZRaidIntent:
	serial += 1
	var value := ZRaidIntent.new()
	value.request_id = ZRequestId.from_parts(PackedStringArray(["equipment", "r" + str(serial)]))
	value.session_id = admission.session_id; value.actor_id = admission.actor_id
	value.authority_epoch = admission.authority_epoch; value.generation = admission.generation
	value.source = ZRaidIntent.Source.PLAYER; value.kind = kind; value.target_tick = 1; value.sequence = serial
	value.payload = {"inventory_command_id":7_000_000 + serial,"inventory_id":owner.raid_player_inventory_id,
		"item_id":item_id,"destination_location":location,
		"expected_revision":owner.raid_authority().inventory_revision(owner.raid_player_inventory_id)}
	return value

func equipment(slot_id: StringName) -> Dictionary:
	for row: Dictionary in controller.equipment_view().slots:
		if StringName(row.slot_id) == slot_id: return row.item
	return {}

func find_item(items: Array[Dictionary], item_id: int) -> Dictionary:
	for item: Dictionary in items:
		if int(item.item_id) == item_id: return item
	return {}

func canonical() -> PackedByteArray:
	return owner.raid_authority().snapshot(owner.raid_player_inventory_id).canonical_bytes()

func finish() -> void:
	if reconciler != null: reconciler.release_binding()
	if controller != null: controller.unbind()
	if adapter != null and adapter.is_bound(): adapter.release_binding()
	if bridge != null: bridge.release_binding()
	if identity != null: identity.release()
	if owner != null and owner.is_current_generation(owner.generation()): owner.teardown(owner.generation())
	if reconciler != null: reconciler.free()
	if bridge != null: bridge.free()
	if owner != null: owner.free()
	print("EQUIPMENT_CONTRACT_RESULT checks=", checks, " failures=", failures)
	quit(0 if failures == 0 else 1)
