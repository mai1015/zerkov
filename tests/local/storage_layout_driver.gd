extends RefCounted
## Real campaign input and real native inventory. The gear-equipped and legacy
## cases explicitly insert test equipment into this isolated test profile only.
var h
var game: LocalGame
var serial := 8000
var fixture_serial := 2_000_000
const C = preload("res://game/content/zerkov_inventory_catalog.gd")

func run(harness, initial: Dictionary) -> bool:
	h = harness; game = h._game
	await h.key(KEY_I)
	if not h.route("inventory"): return false
	var screen: Control = game._ui.screen
	var controller: LocalInventoryController = game._character.inventory_controller()
	var owner := game._home
	var native := owner.raid_authority()
	var id := owner.raid_player_inventory_id
	check(controller.grid_size(&"rig") == Vector2i.ZERO and controller.grid_size(&"backpack") == Vector2i.ZERO, "empty named gear slots provide no visible capacity")
	check(not node("RigGrid").is_visible_in_tree() and not node("PackGrid").is_visible_in_tree(), "no rig/backpack means no grid")
	check(controller.storage_state(&"secure").equipped and controller.grid_size(&"secure") == Vector2i(2, 3), "new operator starts with equipped 2x3 secure container")
	check(screen._secure_grid.is_visible_in_tree() and screen._secure_grid.grid_columns == 2 and screen._secure_grid.grid_rows == 3, "starter secure grid is visible at canonical size")
	var scroll := screen.get_node("InventoryContent/StorageScroll") as ScrollContainer
	check(node("PocketsGrid").get_parent() == scroll.get_child(0) and screen._secure_grid.get_parent() == scroll.get_child(0), "pockets and secure share one scroll content")
	for name: String in ["DesktopPocketsScroll", "DesktopRigScroll", "DesktopPackScroll"]:
		check(not node(name).is_visible_in_tree(), "retired nested scroll hidden: " + name)
	check_original_quick_use(screen)
	var retained_rig := node("RigGrid").get_instance_id()
	for _i in range(3):
		screen._refresh_body()
		screen.queue_adaptive_layout()
		await h.settle()
		node("RigGrid").show(); node("PackGrid").show()
		check(not node("RigGrid").visible and not node("PackGrid").visible, "reflow cannot reveal nonexistent storage cells")
		check(node("RigGrid").get_instance_id() == retained_rig, "same authored grid retained, not replaced by another grid")
		check_original_quick_use(screen)
	check(absf(node("CharacterColumn").position.y - 261) < 1, "character content centered independently of secure storage")
	await h.capture("02-no-rig-no-pack.png")
	if h._run_mode == "continue":
		check(h._store.load_profile().fingerprint == initial.fingerprint, "Continue changes no stored profile")
		return h.failures == 0
	var raw_before: PackedByteArray = native.snapshot(id).canonical_bytes()
	var pockets := LocalCampaignContent.container_id(native.snapshot(id), C.CONTAINER_POCKETS)
	var pack := LocalCampaignContent.container_id(native.snapshot(id), C.CONTAINER_BACKPACK)
	var ammo: Dictionary = controller.items_for(&"pockets")[0]
	var denied := raw_move(int(ammo.item_id), pack, Vector2i.ZERO)
	check(not denied.accepted and denied.reason == &"storage_not_equipped", "raw admission cannot use hidden backpack")
	check(raw_before == native.snapshot(id).canonical_bytes(), "rejected hidden destination has zero mutation")
	var replay := game._character_binding._adapter.receipt_for_request(ZRequestId.parse(String(denied.request_id)))
	check(not replay.accepted and replay.reason == &"storage_not_equipped", "rejection is retained by existing receipt owner")
	# Rig/backpack fixtures only; the secure provider is real starter gear. IDs are allocated natively.
	var equipment := LocalCampaignContent.container_id(native.snapshot(id), C.CONTAINER_EQUIPMENT)
	var fixture_ids: Array[int] = []
	for entry: Array in [[C.ITEM_RIG_BASIC, "zerkov.slot.rig"], [C.ITEM_BACKPACK_DAYPACK, "zerkov.slot.backpack"]]:
		var result: Dictionary = native.insert_item(id, String(entry[0]), 1, {"kind":"slot", "container":equipment, "slot_identifier":entry[1]}, 7200001, fixture_command())
		check(result.get("accepted", false), "native equipment fixture inserted")
		for item: Dictionary in native.snapshot(id).get_items():
			if String(item.item_definition_identifier) == String(entry[0]): fixture_ids.append(int(item.id))
	await h.settle()
	check(controller.grid_size(&"rig") == Vector2i(6,3) and controller.grid_size(&"backpack") == Vector2i(8,5), "equipped item types select canonical storage dimensions")
	check(node("RigGrid").is_visible_in_tree() and node("PackGrid").is_visible_in_tree(), "equipped grids visible")
	check(node("RigGrid").get_parent() == node("PackGrid").get_parent() and node("PackGrid").get_parent() == screen._secure_grid.get_parent(), "all loadout grids have same scroll owner")
	check(screen._secure_grid.position.y > node("PackGrid").position.y + node("PackGrid").size.y, "secure is last, not beside character")
	# The retained equipment button still works after joining the scroll owner.
	if not await h.click("InventoryContent/StorageScroll/StorageContent/RigSwap"): return false
	check(not controller.storage_state(&"rig").equipped and not node("RigGrid").is_visible_in_tree(), "actual rig unequip removes its grid")
	var rig_item: Dictionary = {}
	for item: Dictionary in controller.items_for(&"backpack"):
		if item.definition_id == String(C.ITEM_RIG_BASIC): rig_item = item
	if not check(not rig_item.is_empty(), "unequipped rig remains a real backpack item"): return false
	check(controller.submit_equip(&"backpack", rig_item, &"zerkov.slot.rig").accepted, "same native rig restores its capacity on equip")
	await h.settle()
	check(controller.storage_state(&"rig").equipped and node("RigGrid").is_visible_in_tree(), "reequipped rig grid restored without duplication")
	# Secure is an equipped provider too. A filled container cannot be removed;
	# once emptied, removing it hides/protects the root and re-equipping the same
	# canonical item restores access without manufacturing a new container.
	var secure_slot: Dictionary = {}
	for slot: Dictionary in controller.equipment_view().slots:
		if slot.slot_id == "zerkov.slot.secure": secure_slot = slot.item
	if not check(secure_slot.definition_id == String(C.ITEM_SECURE_CONTAINER_BASIC), "starter secure provider occupies named slot"): return false
	var secure_root := LocalCampaignContent.container_id(native.snapshot(id), C.CONTAINER_SECURE)
	var secure_before: PackedByteArray = native.snapshot(id).canonical_bytes()
	var secure_rejected := raw_move(int(secure_slot.item_id), pockets, Vector2i(2, 0), true)
	check(not secure_rejected.accepted and secure_rejected.reason == &"empty_storage_before_unequip" and secure_before == native.snapshot(id).canonical_bytes(), "filled secure provider cannot orphan protected contents")
	var protected_item: Dictionary = controller.items_for(&"secure")[0]
	check(controller.submit_drop(&"secure", &"backpack", protected_item, Vector2i.ZERO).accepted, "secure contents can be deliberately moved to ordinary storage before swap")
	await h.settle()
	secure_slot = {}
	for slot: Dictionary in controller.equipment_view().slots:
		if slot.slot_id == "zerkov.slot.secure": secure_slot = slot.item
	check(controller.submit_unequip(secure_slot, &"backpack", Vector2i(2, 0)).accepted, "empty secure provider can be unequipped explicitly")
	await h.settle()
	check(not controller.storage_state(&"secure").equipped and controller.grid_size(&"secure") == Vector2i.ZERO and not screen._secure_grid.is_visible_in_tree(), "no secure provider means no protected grid")
	secure_before = native.snapshot(id).canonical_bytes()
	secure_rejected = raw_move(int(ammo.item_id), secure_root, Vector2i.ZERO)
	check(not secure_rejected.accepted and secure_rejected.reason == &"storage_not_equipped" and secure_before == native.snapshot(id).canonical_bytes(), "hidden secure root rejects current-epoch admission")
	var stored_secure: Dictionary = {}
	for item: Dictionary in controller.items_for(&"backpack"):
		if item.definition_id == String(C.ITEM_SECURE_CONTAINER_BASIC): stored_secure = item
	check(controller.submit_equip(&"backpack", stored_secure, &"zerkov.slot.secure").accepted, "same secure provider re-equips from ordinary storage")
	await h.settle()
	protected_item = {}
	for item: Dictionary in controller.items_for(&"backpack"):
		if item.definition_id == String(C.ITEM_SPLINT): protected_item = item
	check(controller.submit_drop(&"backpack", &"secure", protected_item, Vector2i.ZERO).accepted, "re-equipped secure container accepts explicit protected item")
	await h.settle()
	check(controller.storage_state(&"secure").equipped and controller.grid_size(&"secure") == Vector2i(2, 3) and screen._secure_grid.is_visible_in_tree(), "secure grid restores only with its provider")
	var own_position := node("CharacterColumn").position
	await h.capture("03-equipped-native-fixture.png")
	var wheel := InputEventMouseButton.new()
	wheel.position = scroll.get_global_rect().get_center()
	wheel.button_index = MOUSE_BUTTON_WHEEL_DOWN
	wheel.pressed = true
	for i in range(45): h.root.push_input(wheel)
	await h.settle()
	check(scroll.scroll_vertical > 0, "physical wheel scrolls the entire section")
	check(node("CharacterColumn").position == own_position, "character stays fixed while storage scrolls")
	check(screen._secure_grid.get_global_rect().end.y <= scroll.get_global_rect().end.y + 1, "secure reachable at bottom")
	await h.capture("04-secure-at-scroll-bottom.png")
	ammo = controller.items_for(&"pockets")[0]
	check(controller.submit_drop(&"pockets", &"backpack", ammo, Vector2i.ZERO).accepted, "equipped pack accepts real item")
	await h.settle()
	var pack_item: Dictionary = {}
	for slot: Dictionary in controller.equipment_view().slots:
		if slot.slot_id == "zerkov.slot.backpack": pack_item = slot.item
	var before: PackedByteArray = native.snapshot(id).canonical_bytes()
	var rejected := raw_move(int(pack_item.item_id), LocalCampaignContent.container_id(native.snapshot(id), C.CONTAINER_RIG), Vector2i.ZERO, true)
	check(not rejected.accepted and rejected.reason == &"empty_storage_before_unequip" and before == native.snapshot(id).canonical_bytes(), "filled provider cannot leave orphaned storage")
	rejected = raw_quick(int(pack_item.item_id))
	check(not rejected.accepted and rejected.reason == &"empty_storage_before_unequip" and before == native.snapshot(id).canonical_bytes(), "automatic transfer cannot detach a filled provider")
	var carried: Dictionary = controller.items_for(&"backpack")[0]
	check(controller.submit_drop(&"backpack", &"pockets", carried, Vector2i.ZERO).accepted, "move back out without changing identity")
	await h.settle()
	before = native.snapshot(id).canonical_bytes()
	rejected = raw_quick(int(pack_item.item_id))
	check(not rejected.accepted and rejected.reason == &"storage_provider_requires_explicit_move" and before == native.snapshot(id).canonical_bytes(), "automatic transfer cannot select its own provider root")
	# Declared old-save fixture: preserve both unassigned roots without drawing
	# either grid. Recover through actual buttons and the normal intent owner.
	for fixture: int in fixture_ids: check(native.remove_item(id, fixture, 7200001, fixture_command()).accepted, "remove only test fixture gear")
	var rig := LocalCampaignContent.container_id(native.snapshot(id), C.CONTAINER_RIG)
	for entry: Array in [[C.ITEM_BOLTS, rig], [C.ITEM_DUCT_TAPE, pack]]:
		check(native.insert_item(id, String(entry[0]), 1, {"kind":"spatial", "container":entry[1], "x":0,"y":0,"rotated":false}, 7200001, fixture_command()).accepted, "declared legacy-root fixture inserted")
	await h.settle()
	for entry: Array in [[&"rig", "Rig"], [&"backpack", "Pack"]]:
		check(controller.storage_state(entry[0]).recovery_count == 1 and not node(entry[1]+"Grid").is_visible_in_tree(), "legacy items never create a grid without equipment")
		check(controller.grid_size(entry[0]) == Vector2i.ZERO, "legacy contents grant no displayed capacity")
		node(entry[1]+"Grid").show()
		check(not node(entry[1]+"Grid").visible, "reflow cannot resurrect legacy-root grid")
	await h.capture("04b-legacy-items-no-grid.png")
	for entry: Array in [[&"rig", "Rig"], [&"backpack", "Pack"]]:
		var legacy: Dictionary = controller.items_for(entry[0])[0]
		var button := screen.get_node("InventoryContent/StorageScroll/StorageContent/" + entry[1] + "Recovery_" + str(legacy.item_id)) as Button
		if not await h.click(String(screen.get_path_to(button))): return false
		check(controller.storage_state(entry[0]).recovery_count == 0, "actual button recovers legacy identity without exposing cells")
		var saved_bytes: PackedByteArray = native.snapshot(id).canonical_bytes()
		check(not controller.recover_unassigned(entry[0], legacy).accepted and saved_bytes == native.snapshot(id).canonical_bytes(), "stale recovery does not repeat or invent an item")
		check(native.remove_item(id, int(legacy.item_id), 7200001, fixture_command()).accepted, "remove only explicit old-save fixture")
	await h.settle()
	check(game._campaign.save_home(owner), "save real resulting profile through campaign")
	await h.key(KEY_ESCAPE)
	if not h.route("bunker"): return false
	await h.key(KEY_M)
	if not h.route("maps") or not await h.click("Deploy") or not h.route("hud"): return false
	var hud_bar := game._ui.screen.get_node("QuickUse") as Control
	check(hud_bar.is_visible_in_tree() and hud_bar.get_global_rect().end.y == 1066, "same authored Quick Use row visible during actual raid")
	check(not game._ui.feedback.toast_label.get_global_rect().intersects(hud_bar.get_global_rect()), "toast and quick access do not overlap")
	for name: String in ["PrimarySlot", "SecondarySlot", "MeleeSlot"]:
		check(not game._ui.screen.get_node("WeaponGroup/" + name).is_visible_in_tree(), "unbound numeric HUD sample removed: " + name)
	check_original_quick_use(game._ui.screen)
	await h.capture("05-raid-quick-access.png")
	await h.key(KEY_I)
	if not h.route("inventory"): return false
	check(not node("RigGrid").is_visible_in_tree() and not node("PackGrid").is_visible_in_tree(), "same gear-dependent storage in raid")
	var raid_screen: Control = game._ui.screen
	var raid_controller: LocalInventoryController = game._character.inventory_controller()
	check(raid_screen._secure_grid.is_visible_in_tree() and raid_controller.grid_size(&"secure") == Vector2i(2, 3), "equipped starter secure container persists into raid Character")
	check_original_quick_use(game._ui.screen)
	await h.capture("06-raid-character.png")
	# End through the real root and recover interruption on next campaign open;
	# use actual abandonment, not a fabricated save result.
	await h.key(KEY_ESCAPE)
	if not h.route("hud"): return false
	await h.key(KEY_ESCAPE)
	if not h.route("pause") or not await h.click("ActionsPanel/SaveQuitRow/Hit"): return false
	var modal: Control = game._ui.modal
	if not check(is_instance_valid(modal), "abandonment asks for confirmation"): return false
	var confirm: Button
	for button: Node in modal.find_children("*", "Button", true, false):
		if button is Button and not button.text.to_upper().contains("CANCEL"): confirm = button
	if not check(confirm != null, "confirmation button available"): return false
	for down: bool in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = confirm.get_global_rect().get_center()
		event.button_index = MOUSE_BUTTON_LEFT; event.pressed = down
		h.root.push_input(event)
	await h.settle()
	if not h.route("summary_solo") or not await h.click("BackBunker") or not h.route("bunker"): return false
	return h.failures == 0

func fixture_command() -> int:
	fixture_serial += 1
	return fixture_serial

func node(path: String) -> Control:
	return game._ui.screen._node(path)

func check(ok: bool, detail: String) -> bool:
	return h.check(ok, "STORAGE: " + detail)

func raw_move(item: int, destination: int, cell: Vector2i, unequip: bool = false) -> Dictionary:
	serial += 1
	var admission := game._home_admission
	var intent := ZRaidIntent.new()
	intent.request_id = ZRequestId.from_parts(PackedStringArray(["storage", "r"+str(serial)]))
	intent.session_id = admission.session_id; intent.actor_id = admission.actor_id
	intent.authority_epoch = admission.authority_epoch; intent.generation = admission.generation
	intent.source = ZRaidIntent.Source.PLAYER; intent.kind = InventoryIntentAdapter.INTENT_KIND_UNEQUIP if unequip else InventoryIntentAdapter.INTENT_KIND_MOVE
	intent.target_tick = 1; intent.sequence = serial
	intent.payload = {"inventory_command_id":serial,"inventory_id":game._home.raid_player_inventory_id, "item_id":item,
		"destination_location":{"kind":"spatial","container":destination,"x":cell.x,"y":cell.y,"rotated":false},
		"expected_revision":game._home.raid_authority().inventory_revision(game._home.raid_player_inventory_id)}
	return game._character_binding._adapter.submit_intent(intent)


func check_original_quick_use(screen: Control) -> void:
	var bar := screen.get_node_or_null("QuickUse") as Control
	if not check(bar != null and bar.is_visible_in_tree(), "original Quick Use row mounted"): return
	check(screen.get_node_or_null("RaidQuickbar") == null, "no replacement action bar introduced")
	check(bar.get_meta("authored_source") == AuthoredQuickUse.SOURCE, "Character and HUD share original authored controls")
	check(bar.get_global_rect().end.y == 1066, "original item row pinned 14px above bottom")
	for key in range(5,9):
		var copies := screen.find_children("QuickSlot" + str(key), "Button", true, false)
		check(copies.size() == 1, "one original numeric item slot, not duplicate controls")
		if copies.size() != 1: continue
		var slot := copies[0] as Button
		check(slot.get_parent() == bar and slot.disabled and slot.get_node("Key").text == str(key), "original numbered slots retained without invented assignments")
		for name: String in ["Icon", "Count"]:
			var sample := slot.get_node_or_null(name) as CanvasItem
			check(sample == null or not sample.is_visible_in_tree(), "no sample quick-use item or count shown as live")


func raw_quick(item_id: int) -> Dictionary:
	serial += 1
	var admission := game._home_admission
	var intent := ZRaidIntent.new()
	intent.request_id = ZRequestId.from_parts(PackedStringArray(["storage", "r"+str(serial)]))
	intent.session_id = admission.session_id; intent.actor_id = admission.actor_id
	intent.authority_epoch = admission.authority_epoch; intent.generation = admission.generation
	intent.source = ZRaidIntent.Source.PLAYER; intent.kind = InventoryIntentAdapter.INTENT_KIND_QUICK_TRANSFER
	intent.target_tick = 1; intent.sequence = serial
	var id := game._home.raid_player_inventory_id
	var revision := game._home.raid_authority().inventory_revision(id)
	intent.payload = {"inventory_command_id":serial, "source_inventory_id":id, "destination_inventory_id":id,
		"item_id":item_id, "expected_source_revision":revision, "expected_destination_revision":revision}
	return game._character_binding._adapter.submit_intent(intent)
