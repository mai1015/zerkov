extends SceneTree
## Task 4.7b contract: the retained UI can bind to confirmed inventory
## projections, carries scoped native identities through drag data, and emits
## only strict adapter intents. Fixture app.state remains untouched in live
## mode and unavailable cross-authority actions fail closed.

const Controller = preload("res://game/inventory/presentation/inventory_presentation_controller.gd")
const Bridge = preload("res://game/inventory/presentation/inventory_projection_bridge.gd")
const Adapter = preload("res://game/inventory/inventory_intent_adapter.gd")
const Catalog = preload("res://game/content/zerkov_inventory_catalog.gd")

const MAX_TRANSFER_DISTANCE_RAW := 2_000_000
const FIRST_PLAYABLE_SIZE := Vector2i(1920, 1080)


class BindingIdentityPort extends ZInventoryIdentityPort:
	var session_key := ""
	var actor_key := ""
	var epoch := 0
	var generation := 0
	var native_actor := 0
	var owned: Dictionary = {}

	func native_actor_id(session: ZSessionId, actor: ZEntityId, p_epoch: int, p_generation: int) -> int:
		if session == null or actor == null:
			return 0
		return native_actor if session.canonical_key() == session_key and actor.canonical_key() == actor_key and p_epoch == epoch and p_generation == generation else 0

	func actor_owns_inventory(session: ZSessionId, actor: ZEntityId, inventory_id: int, p_epoch: int, p_generation: int) -> bool:
		return native_actor_id(session, actor, p_epoch, p_generation) == native_actor and owned.get(inventory_id, false)


class BindingWorldPolicyPort extends ZInventoryWorldPolicyPort:
	var actor_key := ""
	var generation := 0
	var world_ids: Dictionary = {}

	func is_world_inventory(actor: ZEntityId, inventory_id: int, p_generation: int) -> bool:
		return _matches(actor, p_generation) and world_ids.get(inventory_id, false)

	func authoritative_distance_raw(actor: ZEntityId, inventory_id: int, p_generation: int) -> int:
		return 1_000_000 if is_world_inventory(actor, inventory_id, p_generation) else -1

	func is_currently_visible(actor: ZEntityId, inventory_id: int, p_generation: int) -> bool:
		return is_world_inventory(actor, inventory_id, p_generation)

	func access_state(actor: ZEntityId, inventory_id: int, p_generation: int) -> StringName:
		return ACCESS_OPEN if is_world_inventory(actor, inventory_id, p_generation) else ACCESS_UNAVAILABLE

	func allows_transfer(actor: ZEntityId, source_inventory_id: int, destination_inventory_id: int, item_id: int, p_generation: int) -> bool:
		return is_world_inventory(actor, source_inventory_id, p_generation) and destination_inventory_id > 0 and item_id > 0

	func _matches(actor: ZEntityId, p_generation: int) -> bool:
		return actor != null and actor.canonical_key() == actor_key and p_generation == generation


var checks := 0
var failures := 0
var owner: RaidInventoryOwner
var bridge: Bridge
var adapter: Adapter
var controller: Controller
var admission: ZSessionAdmission


func _initialize() -> void:
	call_deferred("run")


func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("INVENTORY_UI_BINDING_CONTRACT: " + message)


func run() -> void:
	owner = RaidInventoryOwner.new()
	owner.name = "InventoryUIBindingOwner"
	root.add_child(owner)
	check(owner.configure(), "owner configures")
	check(owner.materialize_loot_fixture(), "world loot materializes")

	var raid_id := ZRaidId.from_parts(PackedStringArray(["ui", "binding", "raid"]))
	var session_id := ZSessionId.from_parts(PackedStringArray(["ui", "binding", "session"]))
	var actor_id := ZEntityId.from_parts(PackedStringArray(["ui", "binding", "actor"]))
	var admission_request := ZSessionRequest.create_offline(
		ZRequestId.from_parts(PackedStringArray(["ui", "binding", "admission"])),
		raid_id,
		&"ui_binding_profile",
		&"player",
		7
	)
	admission = ZSessionAdmission.accept_local(admission_request, session_id, actor_id)
	check(admission.is_usable(), "admission is usable")

	var identity := BindingIdentityPort.new()
	identity.session_key = session_id.canonical_key()
	identity.actor_key = actor_id.canonical_key()
	identity.epoch = admission.authority_epoch
	identity.generation = admission.generation
	identity.native_actor = RaidInventoryOwner.FIXTURE_ACTOR_ID
	identity.owned[owner.raid_player_inventory_id] = true

	var world := BindingWorldPolicyPort.new()
	world.actor_key = actor_id.canonical_key()
	world.generation = admission.generation
	world.world_ids[owner.world_crate_inventory_id] = true
	world.world_ids[owner.corpse_inventory_id] = true

	adapter = Adapter.new()
	check(adapter.configure(owner, admission, identity, world, MAX_TRANSFER_DISTANCE_RAW), "adapter configures")
	bridge = Bridge.new()
	root.add_child(bridge)
	check(bridge.bind_owner(owner, owner.generation()), "bridge binds owner")
	controller = Controller.new()
	check(controller.bind(owner, bridge, adapter, admission), "controller binds explicit runtime dependencies")
	var foreign_admission := ZSessionAdmission.accept_local(
		admission_request,
		ZSessionId.from_parts(PackedStringArray(["ui", "binding", "foreign_session"])),
		ZEntityId.from_parts(PackedStringArray(["ui", "binding", "foreign_actor"]))
	)
	var foreign_controller := Controller.new()
	check(not foreign_controller.bind(owner, bridge, adapter, foreign_admission) and foreign_controller.last_error == Controller.REASON_ADAPTER_MISMATCH, "controller rejects an admission that does not exactly match the configured adapter")

	var pockets := controller.descriptor(&"pockets")
	var rig := controller.descriptor(&"rig")
	var pack := controller.descriptor(&"backpack")
	var stash := controller.descriptor(&"stash")
	var crate := controller.descriptor(&"crate")
	var corpse := controller.descriptor(&"corpse")
	check(pockets.available and rig.available and pack.available and stash.available and crate.available and corpse.available, "all confirmed canonical containers are available")
	check(controller.grid_size(&"pockets") == Vector2i(4, 2), "pockets uses canonical 4x2")
	check(controller.grid_size(&"rig") == Vector2i(6, 3), "rig uses canonical 6x3")
	check(controller.grid_size(&"backpack") == Vector2i(8, 5), "backpack uses canonical 8x5")
	check(controller.grid_size(&"stash") == Vector2i(12, 20), "stash uses canonical 12x20")
	check(controller.grid_size(&"crate") == Vector2i(8, 6), "crate uses canonical 8x6")
	check(controller.grid_size(&"corpse") == Vector2i(10, 8), "corpse uses canonical 10x8")
	check(stash.scope != pockets.scope and stash.inventory_id == pockets.inventory_id, "colliding native ids remain distinct by scope")
	var catalog_resource: InventoryCatalogResource = Catalog.build_resource()
	check(_catalog_container_size(catalog_resource, Catalog.CONTAINER_STASH) == controller.grid_size(&"stash"), "presentation dimensions come from the authored catalog resource")
	var catalog_bandage := _catalog_item(catalog_resource, Catalog.ITEM_BANDAGE)
	check(catalog_bandage != null and catalog_bandage.max_stack == 4 and not catalog_bandage.allow_rotation, "canonical stack and rotation facts remain catalog-owned")

	var crate_items := controller.items_for(&"crate")
	check(crate_items.size() == 4, "crate projection renders all authoritative items")
	var loot_item: Dictionary = crate_items[0] if not crate_items.is_empty() else {}
	check(loot_item.get("item_id", 0) is int and int(loot_item.get("item_id", 0)) > 0, "live item identity is native integer")
	check(not str(loot_item.get("item_id", "")).begins_with("loot_"), "fixture string identity never leaks")
	check(int(loot_item.get("container_id", 0)) == int(crate.container_id), "item carries canonical container identity")
	check(int(loot_item.get("scope_generation", 0)) == int(crate.scope_generation), "item carries scope generation")
	check(Vector2i(int(loot_item.get("base_width", 0)), int(loot_item.get("base_height", 0))) == Vector2i(2, 1) and bool(loot_item.get("rotatable", false)), "projected footprint and rotation match the canonical item definition")
	var projection_bytes := bridge.confirmed_snapshot(InventoryProjectionBridge.SCOPE_RAID, owner.world_crate_inventory_id).canonical_bytes()
	var mutated_view := loot_item.duplicate(true)
	mutated_view["x"] = 99
	(mutated_view["location"] as Dictionary)["x"] = 99
	check(int(_find_item(controller.items_for(&"crate"), int(loot_item.item_id)).get("x", -1)) == int(loot_item.x) and bridge.confirmed_snapshot(InventoryProjectionBridge.SCOPE_RAID, owner.world_crate_inventory_id).canonical_bytes() == projection_bytes, "mutating a presentation copy cannot alter the immutable confirmed snapshot")
	var quick_item: Dictionary = crate_items[1] if crate_items.size() > 1 else {}
	var quick_result := controller.submit_quick(&"crate", quick_item)
	check(quick_result.accepted, "quick transfer uses complete-only adapter routing")

	var requests_before_invalid := adapter.tracked_request_count()
	var invalid := controller.submit_drop(&"crate", &"pockets", loot_item, Vector2i(-1, 0))
	check(not invalid.accepted and invalid.reason == Controller.REASON_INVALID_DESTINATION, "invalid release returns stable reason without fallback")
	check(adapter.tracked_request_count() == requests_before_invalid, "invalid release submits no authority request")
	var forged_footprint := loot_item.duplicate(true)
	forged_footprint["width"] = 1
	forged_footprint["w"] = 1
	var forged_fit := controller.submit_drop(&"crate", &"pockets", forged_footprint, Vector2i(3, 0))
	check(not forged_fit.accepted and forged_fit.reason == Controller.REASON_INVALID_DESTINATION and adapter.tracked_request_count() == requests_before_invalid, "client footprint tampering cannot bypass canonical placement bounds")
	var forged_mapping := loot_item.duplicate(true)
	forged_mapping["mapping_key"] = "raid/foreign/identity"
	var forged_identity := controller.submit_drop(&"crate", &"pockets", forged_mapping, Vector2i(0, 0))
	check(not forged_identity.accepted and forged_identity.reason == Controller.REASON_STALE_DRAG_TARGET and adapter.tracked_request_count() == requests_before_invalid, "mapping identity mismatch fails closed before the adapter")
	var world_reposition := controller.submit_drop(&"crate", &"crate", loot_item, Vector2i(0, 1))
	check(not world_reposition.accepted and world_reposition.reason == Controller.REASON_WORLD_CONTAINER_READ_ONLY and adapter.tracked_request_count() == requests_before_invalid, "world container reposition fails closed before pending state or authority")
	var world_to_world := controller.submit_drop(&"crate", &"corpse", loot_item, Vector2i(8, 7))
	check(not world_to_world.accepted and world_to_world.reason == Controller.REASON_CROSS_AUTHORITY_UNAVAILABLE and adapter.tracked_request_count() == requests_before_invalid, "world-to-world transfer is outside the actor-owned loot destination seam")

	var loot_result := controller.submit_drop(&"crate", &"pockets", loot_item, Vector2i(0, 0))
	check(loot_result.accepted and controller.last_error == &"", "exact-coordinate loot intent is accepted and clears earlier rejection diagnostics")
	var pockets_items := controller.items_for(&"pockets")
	check(_find_item(pockets_items, int(loot_item.item_id)).get("x", -1) == 0, "confirmed projection keeps exact destination")

	var corpse_items := controller.items_for(&"corpse")
	var corpse_ammo: Dictionary = {}
	for item in corpse_items:
		if str(item.get("kind", "")) == "ammo":
			corpse_ammo = item
			break
	check(not corpse_ammo.is_empty(), "corpse exposes stackable ammo")
	var ammo_result := controller.submit_drop(&"corpse", &"pockets", corpse_ammo, Vector2i(2, 0))
	check(ammo_result.accepted, "corpse loot uses the same exact-coordinate path")
	var ammo := _find_definition(controller.items_for(&"pockets"), str(corpse_ammo.definition_id))
	check(int(ammo.get("quantity", 0)) == 60 and str(ammo.get("compatibility", "")) == "7.62x39", "authoritative quantity and presentation-only compatibility are rendered")

	var rotated := controller.submit_rotate(&"pockets", _find_item(controller.items_for(&"pockets"), int(loot_item.item_id)))
	check(rotated.accepted, "R rotation maps to the strict rotate intent")
	var fresh_controller := Controller.new()
	check(fresh_controller.bind(owner, bridge, adapter, admission), "a replacement controller can bind the same exact runtime seam")
	var fresh_rotatable := _find_rotatable(fresh_controller.items_for(&"pockets"))
	var fresh_requests := adapter.tracked_request_count()
	var fresh_rotate := fresh_controller.submit_rotate(&"pockets", fresh_rotatable)
	check(fresh_rotate.accepted and not fresh_rotate.replayed and adapter.tracked_request_count() == fresh_requests + 1, "fresh controller request ids cannot collide with the adapter replay ledger result=" + str(fresh_rotate) + " before=" + str(fresh_requests) + " after=" + str(adapter.tracked_request_count()))
	fresh_controller.unbind()

	var split := controller.submit_drop(&"pockets", &"pockets", ammo, Vector2i(3, 0), Controller.OP_SPLIT, 0, 10)
	check(split.accepted, "explicit bounded split quantity is accepted")
	var ammo_after_split := _find_definition(controller.items_for(&"pockets"), str(corpse_ammo.definition_id))
	check(controller.items_for(&"pockets").size() >= 3 and int(ammo_after_split.get("quantity", 0)) == 50, "split changes only after authoritative projection")
	var split_stack := _find_quantity(controller.items_for(&"pockets"), str(corpse_ammo.definition_id), 10)
	var merge_target := _find_quantity(controller.items_for(&"pockets"), str(corpse_ammo.definition_id), 50)
	if not split_stack.is_empty() and not merge_target.is_empty():
		var merge := controller.submit_drop(&"pockets", &"pockets", split_stack, Vector2i(int(merge_target.get("x", 0)), int(merge_target.get("y", 0))), Controller.OP_MERGE, int(merge_target.get("item_id", 0)))
		check(merge.accepted, "compatible occupied-cell drop maps to authoritative merge")
		check(_find_definition(controller.items_for(&"pockets"), str(corpse_ammo.definition_id)).get("quantity", 0) == 60, "merge preserves the authoritative target identity")
	else:
		check(false, "split exposes both authoritative stack identities for merge")

	var profile_cross := controller.submit_drop(&"stash", &"pockets", {}, Vector2i(0, 0))
	check(not profile_cross.accepted and profile_cross.reason == Controller.REASON_CROSS_AUTHORITY_UNAVAILABLE, "profile↔raid mutation is explicitly unavailable")
	var owned_quick_item := controller.items_for(&"pockets")[0] if not controller.items_for(&"pockets").is_empty() else {}
	var owned_quick_requests := adapter.tracked_request_count()
	var owned_quick := controller.submit_quick(&"pockets", owned_quick_item)
	check(not owned_quick.accepted and owned_quick.reason == Controller.REASON_CROSS_AUTHORITY_UNAVAILABLE and adapter.tracked_request_count() == owned_quick_requests, "player↔profile quick transfer is explicitly unavailable before the adapter")
	var quick_requests_before := adapter.tracked_request_count()
	var quick := controller.submit_quick(&"crate", loot_item)
	check(not quick.accepted and adapter.tracked_request_count() == quick_requests_before, "stale loot item cannot quick-transfer twice")

	# The retained screen binds explicitly after its fixture preview exists. Its
	# canonical grids and read-only controls must then be driven by the bridge,
	# while the preview dictionary remains byte-for-byte untouched.
	root.size = FIRST_PLAYABLE_SIZE
	var app: Control = load("res://ui/main.tscn").instantiate()
	root.add_child(app)
	await process_frame
	await process_frame
	app.navigate("inventory", false)
	await process_frame
	await process_frame
	var screen: Control = app.screen
	var fixture_before: Dictionary = (app.state.get("inventory_data", {}) as Dictionary).duplicate(true)
	var authored_stash_scroll := screen._grid_for_source("stash").get_parent() as ScrollContainer
	var authored_scroll_position := authored_stash_scroll.position if authored_stash_scroll != null else Vector2.ZERO
	var authored_scroll_size := authored_stash_scroll.size if authored_stash_scroll != null else Vector2.ZERO
	# Inject the same retained controller used by the direct seam checks. A
	# production screen has one controller lifetime; reusing it also preserves
	# its request serial across the retained-screen bind.
	screen._inventory_controller = controller
	check(screen.bind_inventory_runtime(owner, bridge, adapter, admission), "retained screen accepts explicit live binding")
	await process_frame
	check(screen._live_inventory_binding, "screen marks live binding active")
	check(screen._grid_for_source("pockets").grid_rows == 2, "screen renders live pockets at 4x2")
	check(screen._grid_for_source("rig").grid_rows == 3, "screen renders live rig at 6x3")
	check(screen._grid_for_source("backpack").grid_columns == 8, "screen renders live backpack at 8x5")
	check(screen._grid_for_source("stash").grid_columns == 12 and screen._grid_for_source("stash").grid_rows == 20, "screen renders live stash at 12x20")
	check(screen._grid_for_source("stash").get_parent().name == "DesktopStashScroll", "desktop stash keeps bounded authored scroll geometry")
	var live_stash_scroll := screen._grid_for_source("stash").get_parent() as ScrollContainer
	check(live_stash_scroll != null and live_stash_scroll.position.is_equal_approx(authored_scroll_position) and live_stash_scroll.size.is_equal_approx(authored_scroll_size), "canonical content dimensions do not drift the authored outer scroll geometry")
	check(screen._grid_for_source("stash").cell_size == 74 and screen._grid_for_source("stash").custom_minimum_size.is_equal_approx(Vector2(12 * 74, 20 * 74)), "live stash uses exact 74px canonical content inside the bounded scroll")
	check(not screen._grid_for_source("stash").mutation_enabled, "profile stash is visibly read-only in live mode")
	check(not screen._grid_for_source("pockets").quick_transfer_enabled and screen._grid_for_source("pockets").split_enabled and not screen._grid_for_source("stash").quick_transfer_enabled, "live grids expose operation-specific availability instead of implying profile transfer support")
	check(str(screen._node("StashCompatible").text).contains("PROFILE READ-ONLY"), "profile read-only state is identified")
	check(
		(screen._node("PostRaidBar/MoveLoot") as Button).disabled \
		and (screen._node("PostRaidBar/Reinsure") as Button).disabled \
		and (screen._node("PostRaidBar/SellJunk") as Button).disabled \
		and (screen._node("RigSwap") as Button).disabled \
		and (screen._node("PackSwap") as Button).disabled \
		and (screen._node("SortStash") as Button).disabled \
		and (screen._node("OrganizeStash") as Button).disabled,
		"bank, economy, swap, sort, and organize previews are explicitly unavailable in live mode"
	)
	var player_rotatable := _find_rotatable(screen._items_for("pockets"))
	var player_rotate_slot := _slot_for_item(screen._grid_for_source("pockets"), int(player_rotatable.get("item_id", 0)))
	check(player_rotate_slot != null, "live player projection exposes a rotatable native slot")
	if player_rotate_slot != null:
		player_rotate_slot._on_pressed()
		screen._close_tip()
		var player_rotated_before := bool(player_rotatable.get("rotated", false))
		var before_keyboard_rotate := adapter.tracked_request_count()
		var rotate_key := InputEventKey.new()
		rotate_key.keycode = KEY_R
		rotate_key.pressed = true
		screen._unhandled_input(rotate_key)
		await process_frame
		await process_frame
		var player_rotated_after := _find_item(controller.items_for(&"pockets"), int(player_rotatable.get("item_id", 0)))
		var selected_pockets_grid: Control = screen._grid_for_source("pockets")
		check(adapter.tracked_request_count() == before_keyboard_rotate + 1 and bool(player_rotated_after.get("rotated", player_rotated_before)) != player_rotated_before and str(app.toast_label.text) == "Inventory confirmed", "R keyboard input submits exactly one rotate intent and renders the confirmed orientation")
		check(int(screen._selected_live_item.get("item_id", 0)) == int(player_rotatable.get("item_id", 0)) and selected_pockets_grid.selected_id == str(player_rotatable.get("item_id", 0)), "selection survives the accepted projection refresh")
	var preview_fixture := (app.state.get("inventory_data", {}) as Dictionary).duplicate(true)
	var preview_requests := adapter.tracked_request_count()
	var preview_raid_revision := bridge.confirmed_revision(InventoryProjectionBridge.SCOPE_RAID, owner.raid_player_inventory_id)
	var preview_profile_revision := bridge.confirmed_revision(InventoryProjectionBridge.SCOPE_PROFILE, owner.profile_inventory_id)
	screen._bank_loot()
	screen._reinsure()
	screen._sell_junk()
	screen._swap_container("rig")
	screen._sort_stash()
	screen._organize_stash()
	screen._quick_heal()
	check(adapter.tracked_request_count() == preview_requests and bridge.confirmed_revision(InventoryProjectionBridge.SCOPE_RAID, owner.raid_player_inventory_id) == preview_raid_revision and bridge.confirmed_revision(InventoryProjectionBridge.SCOPE_PROFILE, owner.profile_inventory_id) == preview_profile_revision and (app.state.get("inventory_data", {}) as Dictionary) == preview_fixture, "guarded preview actions mutate neither canonical authority nor fixture state in live mode")
	var pockets_grid: Control = screen._grid_for_source("pockets")
	var rig_grid: Control = screen._grid_for_source("rig")
	var player_stack := _find_definition(screen._items_for("pockets"), str(corpse_ammo.definition_id))
	var player_stack_slot := _slot_for_item(pockets_grid, int(player_stack.get("item_id", 0)))
	var rig_split_cell := _find_empty_cell(rig_grid, player_stack)
	if player_stack_slot != null and rig_split_cell.x >= 0:
		var before_cross_split := adapter.tracked_request_count()
		var player_quantity := int(player_stack.get("quantity", 0))
		var cross_press := InputEventMouseButton.new()
		cross_press.button_index = MOUSE_BUTTON_LEFT
		cross_press.pressed = true
		cross_press.ctrl_pressed = true
		player_stack_slot._gui_input(cross_press)
		var cross_payload: Variant = player_stack_slot._get_drag_data(Vector2.ZERO)
		var cross_position := Vector2(rig_split_cell.x * 74 + 10, rig_split_cell.y * 74 + 10)
		rig_grid._drop_data(cross_position, cross_payload)
		var cross_release := InputEventMouseButton.new()
		cross_release.button_index = MOUSE_BUTTON_LEFT
		cross_release.pressed = false
		cross_release.ctrl_pressed = true
		player_stack_slot._gui_input(cross_release)
		check(is_instance_valid(screen._split_dialog) and screen._split_dialog == app.modal and screen._split_dialog is ZerkovDialog, "ctrl-drag split uses the CommonUI modal lifecycle")
		var modal_key := InputEventKey.new()
		modal_key.keycode = KEY_R
		modal_key.pressed = true
		screen._unhandled_input(modal_key)
		check(adapter.tracked_request_count() == before_cross_split, "modal-suspended keyboard input emits zero inventory intent")
		screen._cancel_split_quantity()
		await process_frame
		await process_frame
		check(adapter.tracked_request_count() == before_cross_split, "canceling split quantity emits zero inventory intent")
		# Repeat the exact native target release after cancellation, then confirm.
		rig_grid._drop_data(cross_position, cross_payload)
		check(is_instance_valid(screen._split_spin), "split can be retried after a canceled modal")
		var cross_quantity := mini(10, player_quantity - 1)
		if is_instance_valid(screen._split_spin):
			screen._split_spin.text = str(cross_quantity)
		screen._confirm_split_quantity()
		await process_frame
		await process_frame
		var rig_stack := _find_quantity(controller.items_for(&"rig"), str(corpse_ammo.definition_id), cross_quantity)
		check(adapter.tracked_request_count() == before_cross_split + 1 and int(rig_stack.get("x", -1)) == rig_split_cell.x and int(rig_stack.get("y", -1)) == rig_split_cell.y and str(app.toast_label.text) == "Inventory confirmed", "confirmed ctrl-drag split submits one intent to the exact destination container and cell with stable accepted feedback")
		screen._confirm_split_quantity()
		check(adapter.tracked_request_count() == before_cross_split + 1, "repeated split confirmation emits zero additional intent")
		var current_rig_grid: Control = screen._grid_for_source("rig")
		var current_pockets_grid: Control = screen._grid_for_source("pockets")
		var merge_source_slot := _slot_for_item(current_rig_grid, int(rig_stack.get("item_id", 0)))
		var merge_target_item := _find_definition(controller.items_for(&"pockets"), str(corpse_ammo.definition_id))
		var merge_target_slot := _slot_for_item(current_pockets_grid, int(merge_target_item.get("item_id", 0)))
		check(merge_source_slot != null and merge_target_slot != null, "compatible native merge exposes exact source and target slots")
		if merge_source_slot != null and merge_target_slot != null:
			var merge_target_id := int(merge_target_item.get("item_id", 0))
			var before_native_merge := adapter.tracked_request_count()
			var merge_payload: Variant = merge_source_slot._get_drag_data(Vector2.ZERO)
			var merge_position := merge_target_slot.position + Vector2(2, 2)
			current_pockets_grid._drop_data(merge_position, merge_payload)
			var merge_release := InputEventMouseButton.new()
			merge_release.button_index = MOUSE_BUTTON_LEFT
			merge_release.pressed = false
			merge_source_slot._gui_input(merge_release)
			await process_frame
			await process_frame
			var merged_target := _find_item(controller.items_for(&"pockets"), merge_target_id)
			check(adapter.tracked_request_count() == before_native_merge + 1 and int(merged_target.get("quantity", 0)) == player_quantity and _find_item(controller.items_for(&"rig"), int(rig_stack.get("item_id", 0))).is_empty() and str(app.toast_label.text) == "Inventory confirmed", "compatible occupied-cell release emits one merge intent and preserves the target identity")
	else:
		check(false, "cross-container split fixture exposes a stack slot and exact empty rig cell")
	screen._set_loot_mode(true)
	var loot_grid: Control = screen._grid_for_source("loot")
	var original_binding_token := int(loot_grid.binding_token)
	var live_loot: Array = screen._items_for("loot")
	check(live_loot.size() > 0, "live loot tab renders the selected raid container")
	check(loot_grid.quick_transfer_enabled and not loot_grid.split_enabled, "world loot advertises transfer but not actor-owned stack editing")
	check(loot_grid.get_parent().name == "DesktopStashScroll", "loot keeps the authored desktop scroll pane")
	var read_only_requests := adapter.tracked_request_count()
	var read_only_revision := bridge.confirmed_revision(InventoryProjectionBridge.SCOPE_RAID, owner.world_crate_inventory_id)
	var search: LineEdit = screen._node("StashSearch") as LineEdit
	check(search != null, "retained live screen exposes its native search field")
	if search != null:
		search.text = "no-such-item"
		search.caret_column = 4
		screen._on_search_changed("no-such-item")
		search.grab_focus()
		await process_frame
		var search_key := InputEventKey.new()
		search_key.keycode = KEY_R
		search_key.pressed = true
		screen._unhandled_input(search_key)
		check(adapter.tracked_request_count() == read_only_requests, "search-focused keyboard input emits zero inventory intent")
		search.release_focus()
	check(loot_grid.items.is_empty(), "no-match search renders an empty filtered view")
	check(loot_grid.occupancy_items.size() == live_loot.size(), "filtered-out items still occupy authoritative cells")
	check(search == null or search.caret_column == 4, "search caret remains presentation-local")
	screen._set_filter("not-a-category")
	check(loot_grid.items.is_empty() and loot_grid.occupancy_items.size() == live_loot.size(), "no-match filter does not erase inventory")
	if not live_loot.is_empty():
		var viewed_item: Dictionary = live_loot[0].duplicate(true)
		viewed_item["_binding_token"] = int(loot_grid.binding_token)
		screen._on_grid_hovered(viewed_item, true, loot_grid)
		screen._on_grid_selected(viewed_item, "loot")
		var tooltip_text := ""
		if is_instance_valid(screen._tooltip):
			for child in screen._tooltip.get_children():
				if child is Label:
					tooltip_text += str((child as Label).text) + "\n"
		check(tooltip_text.contains("LIVE") and tooltip_text.contains("CONFIRMED PROJECTION"), "live tooltip identifies confirmed projection")
		check(not tooltip_text.contains("$"), "live tooltip does not invent canonical price")
	screen._set_filter("all")
	if search != null:
		search.text = ""
		screen._on_search_changed("")
	check(adapter.tracked_request_count() == read_only_requests, "filter/search/hover/tooltip submit no authoritative commands")
	check(bridge.confirmed_revision(InventoryProjectionBridge.SCOPE_RAID, owner.world_crate_inventory_id) == read_only_revision, "filter/search/hover/tooltip advance no revision")
	screen._set_loot_mode(false)
	await process_frame
	await process_frame
	var desktop_stash_scroll: ScrollContainer = (screen._node("StashGrid").get_parent() as ScrollContainer)
	if desktop_stash_scroll != null:
		desktop_stash_scroll.scroll_vertical = 123
		await process_frame
		var assigned_scroll := desktop_stash_scroll.scroll_vertical
		screen._refresh_body()
		await process_frame
		await process_frame
		var retained_stash_grid: Control = screen._grid_for_source("stash")
		var retained_scroll: ScrollContainer = retained_stash_grid.get_parent() as ScrollContainer
		check(assigned_scroll == 123 and retained_scroll != null and retained_scroll.name == "DesktopStashScroll" and retained_scroll.scroll_vertical == assigned_scroll, "desktop scroll offset survives retained live refresh parent=" + (retained_scroll.name if retained_scroll != null else "null") + " offset=" + str(retained_scroll.scroll_vertical if retained_scroll != null else -1) + " assigned=" + str(assigned_scroll) + " viewport=" + str(root.get_viewport().size))
	var fixture_after_bind: Dictionary = (app.state.get("inventory_data", {}) as Dictionary).duplicate(true)
	screen._set_filter("guns")
	if search != null:
		search.text = "akm"
		search.caret_column = 2
		screen._on_search_changed("akm")
		search.grab_focus()
		await process_frame
	screen._set_loot_mode(true)
	screen._set_loot_mode(false)
	check(fixture_after_bind == (app.state.get("inventory_data", {}) as Dictionary), "filter/search/mode never mutate live fixture state")
	check(fixture_before == fixture_after_bind, "live bind never replaces fixture data")
	check(screen._current_filter == "guns" and screen._search_query == "akm" and (search == null or (search.text == "akm" and search.caret_column == 2 and search.get_viewport().gui_get_focus_owner() == search)), "live section changes retain filter, query, search focus, and caret")
	# Retention is the behavior under test above. Clear presentation-only filters
	# explicitly so the following native gesture probes are never conditional on
	# which item names happen to match the retained query.
	screen._set_filter("all")
	if search != null:
		search.text = ""
	screen._on_search_changed("")
	screen._set_loot_mode(true)
	var live_loot_grid: Control = screen._grid_for_source("loot")
	var live_loot_items: Array = screen._items_for("loot")
	var native_rejections := {"count": 0}
	live_loot_grid.drop_rejected.connect(func(_item: Dictionary, _source: String, _cell: Vector2i): native_rejections.count += 1)
	check(not live_loot_items.is_empty(), "native gesture fixture retains live loot after presentation-only filtering")
	if not live_loot_items.is_empty():
		var keyboard_slot := _slot_for_item(live_loot_grid, int(live_loot_items[0].get("item_id", 0)))
		check(keyboard_slot != null, "live item has a native focusable slot")
		if keyboard_slot != null:
			keyboard_slot.grab_focus()
			await process_frame
			keyboard_slot._on_pressed()
			check(int(screen._selected_live_item.get("item_id", 0)) == int(live_loot_items[0].item_id) and screen._selected_live_source == "loot", "focused native slot activates selection from keyboard/controller semantics")
			screen._close_tip()
			keyboard_slot.grab_focus()
			await process_frame
		var focus_before_release := live_loot_grid.get_viewport().gui_get_focus_owner()
		var native_payload := {"type": "inventory_item", "item": live_loot_items[0], "source": "loot", "item_id": live_loot_items[0].item_id}
		check(live_loot_grid._can_drop_data(Vector2(-4, -4), native_payload), "invalid native release is accepted for rejection dispatch")
		live_loot_grid._drop_data(Vector2(-4, -4), native_payload)
		check(native_rejections.count == 1 and focus_before_release != null and live_loot_grid.get_viewport().gui_get_focus_owner() == focus_before_release and str(app.toast_label.text).contains("Invalid release"), "invalid native release produces stable non-focus feedback count=" + str(native_rejections.count) + " focus_before=" + str(focus_before_release) + " focus_after=" + str(live_loot_grid.get_viewport().gui_get_focus_owner()) + " feedback=" + str(app.toast_label.text))
	var pair := _find_non_merge_pair(live_loot_items)
	if not pair.is_empty():
		var source_item: Dictionary = pair[0]
		var target_item: Dictionary = pair[1]
		var source_slot: Control = _slot_for_item(live_loot_grid, int(source_item.get("item_id", 0)))
		var target_slot: Control = _slot_for_item(live_loot_grid, int(target_item.get("item_id", 0)))
		check(source_slot != null and target_slot != null, "incompatible occupied-cell gesture has both native slots")
		if source_slot != null and target_slot != null:
			var before_native_drag := adapter.tracked_request_count()
			# Headless Godot does not synthesize the OS drag manager from
			# Input.parse_input_event. Exercise the same native slot/grid dispatch
			# seam directly: the slot builds drag data, the grid runs its real
			# _can_drop_data gate, and _drop_data emits the rejection feedback.
			var native_drag_payload: Variant = source_slot._get_drag_data(Vector2.ZERO)
			var occupied_target := target_slot.position + Vector2(2, 2)
			check(native_drag_payload is Dictionary and live_loot_grid._can_drop_data(occupied_target, native_drag_payload), "native drag dispatch accepts invalid release for feedback")
			live_loot_grid._drop_data(occupied_target, native_drag_payload)
			var invalid_release := InputEventMouseButton.new()
			invalid_release.button_index = MOUSE_BUTTON_LEFT
			invalid_release.pressed = false
			source_slot._gui_input(invalid_release)
			await process_frame
			check(native_rejections.count >= 2, "native drag release reaches rejection feedback when placement is invalid count=" + str(native_rejections.count) + " source=" + str(source_slot.global_position) + " target=" + str(target_slot.global_position))
			check(adapter.tracked_request_count() == before_native_drag, "invalid native drag submits no intent requests=" + str(adapter.tracked_request_count()) + " before=" + str(before_native_drag))
	else:
		check(false, "live loot fixture exposes an incompatible occupied-cell pair")
	var native_move_item := _find_non_stack_item(live_loot_items)
	var native_move_slot := _slot_for_item(live_loot_grid, int(native_move_item.get("item_id", 0)))
	var native_move_grid: Control = screen._grid_for_source("backpack")
	var native_move_cell := _find_empty_cell(native_move_grid, native_move_item) if native_move_grid != null else Vector2i(-1, -1)
	check(native_move_slot != null and native_move_grid != null and native_move_cell.x >= 0, "valid native loot drag exposes an exact player destination")
	if native_move_slot != null and native_move_grid != null and native_move_cell.x >= 0:
		native_move_slot._on_pressed()
		screen._close_tip()
		var before_native_move := adapter.tracked_request_count()
		var native_move_payload: Variant = native_move_slot._get_drag_data(Vector2.ZERO)
		var native_move_position := Vector2(native_move_cell.x * 74 + 10, native_move_cell.y * 74 + 10)
		check(native_move_grid._can_drop_data(native_move_position, native_move_payload), "valid native loot drag reaches the destination grid")
		native_move_grid._drop_data(native_move_position, native_move_payload)
		var native_move_release := InputEventMouseButton.new()
		native_move_release.button_index = MOUSE_BUTTON_LEFT
		native_move_release.pressed = false
		native_move_slot._gui_input(native_move_release)
		await process_frame
		await process_frame
		var native_moved := _find_item(controller.items_for(&"backpack"), int(native_move_item.get("item_id", 0)))
		check(adapter.tracked_request_count() == before_native_move + 1 and int(native_moved.get("x", -1)) == native_move_cell.x and int(native_moved.get("y", -1)) == native_move_cell.y and str(app.toast_label.text) == "Inventory confirmed", "native drag emits one exact placement intent and renders only the confirmed destination")
		var selected_grid_count := 0
		for selected_candidate in screen._grids:
			if is_instance_valid(selected_candidate) and not str(selected_candidate.selected_id).is_empty():
				selected_grid_count += 1
		check(screen._selected_live_source == "backpack" \
			and int(screen._selected_live_item.get("item_id", 0)) == int(native_move_item.item_id) \
			and native_move_grid.selected_id == str(native_move_item.item_id) \
			and selected_grid_count == 1,
			"selection follows a cross-inventory native drag to exactly one retained grid")
	var stack_item := _find_stack_item(live_loot_items)
	check(not stack_item.is_empty(), "live loot fixture exposes a stack for ctrl-drag arbitration")
	if not stack_item.is_empty():
		var stack_slot: Control = _slot_for_item(live_loot_grid, int(stack_item.get("item_id", 0)))
		var empty_cell := _find_empty_cell(live_loot_grid, stack_item)
		check(stack_slot != null and empty_cell.x >= 0, "ctrl-drag stack has a native slot and exact empty cell")
		if stack_slot != null and empty_cell.x >= 0:
			var before_split_drag := adapter.tracked_request_count()
			var ctrl_press := InputEventMouseButton.new()
			ctrl_press.button_index = MOUSE_BUTTON_LEFT
			ctrl_press.pressed = true
			ctrl_press.ctrl_pressed = true
			stack_slot._gui_input(ctrl_press)
			var split_payload: Variant = stack_slot._get_drag_data(Vector2.ZERO)
			check(split_payload is Dictionary and bool((split_payload as Dictionary).get("split", false)), "ctrl-drag marks the native payload as split")
			var empty_position := Vector2(empty_cell.x * 74 + 10, empty_cell.y * 74 + 10)
			check(live_loot_grid._can_drop_data(empty_position, split_payload), "ctrl-drag dispatch accepts a valid split destination")
			live_loot_grid._drop_data(empty_position, split_payload)
			var ctrl_release := InputEventMouseButton.new()
			ctrl_release.button_index = MOUSE_BUTTON_LEFT
			ctrl_release.pressed = false
			ctrl_release.ctrl_pressed = true
			stack_slot._gui_input(ctrl_release)
			await process_frame
			check(adapter.tracked_request_count() == before_split_drag and not is_instance_valid(screen._split_dialog) and str(app.toast_label.text).contains("world loot must transfer"), "world-loot ctrl-drag split fails closed before modal or authority request")
			screen._confirm_split_quantity()
			check(adapter.tracked_request_count() == before_split_drag, "confirm callback after unavailable split emits zero intent")
			# A grid rebuild cancels the native gesture. The late Ctrl-release
			# must not be reinterpreted as a quick transfer.
			var cancel_item: Dictionary = _find_stack_item(screen._items_for("loot"))
			if cancel_item.is_empty():
				cancel_item = stack_item.duplicate(true)
			var cancel_slot: Control = _slot_for_item(live_loot_grid, int(cancel_item.get("item_id", 0)))
			check(cancel_slot != null, "projection keeps a stack slot available for canceled-gesture arbitration")
			if cancel_slot != null:
				var before_canceled_release := adapter.tracked_request_count()
				var cancel_press := InputEventMouseButton.new()
				cancel_press.button_index = MOUSE_BUTTON_LEFT
				cancel_press.pressed = true
				cancel_press.ctrl_pressed = true
				cancel_slot._gui_input(cancel_press)
				cancel_slot._get_drag_data(Vector2.ZERO)
				# Exercise the same retained-slot reconciliation path that a
				# projection structure change uses. A same-size set_grid_size call
				# is intentionally a no-op and would not prove gesture cancellation.
				live_loot_grid._rebuild_slots()
				var cancel_release := InputEventMouseButton.new()
				cancel_release.button_index = MOUSE_BUTTON_LEFT
				cancel_release.pressed = false
				cancel_release.ctrl_pressed = true
				cancel_slot._gui_input(cancel_release)
				await process_frame
				check(adapter.tracked_request_count() == before_canceled_release, "canceled ctrl-drag submits zero requests")
	var gesture_quick_item := _find_stack_item(live_loot_items)
	if gesture_quick_item.is_empty() and not live_loot_items.is_empty():
		gesture_quick_item = live_loot_items[0]
	var quick_slot: Control = _slot_for_item(live_loot_grid, int(gesture_quick_item.get("item_id", 0)))
	check(quick_slot != null, "ctrl-click quick transfer has a current native slot")
	if quick_slot != null:
		var before_ctrl_click := adapter.tracked_request_count()
		var quick_press := InputEventMouseButton.new()
		quick_press.button_index = MOUSE_BUTTON_LEFT
		quick_press.pressed = true
		quick_press.ctrl_pressed = true
		quick_slot._gui_input(quick_press)
		check(adapter.tracked_request_count() == before_ctrl_click, "ctrl-click does not submit on press")
		var quick_release := InputEventMouseButton.new()
		quick_release.button_index = MOUSE_BUTTON_LEFT
		quick_release.pressed = false
		quick_release.ctrl_pressed = true
		quick_slot._gui_input(quick_release)
		var after_ctrl_click := adapter.tracked_request_count()
		quick_slot._gui_input(quick_release)
		check(adapter.tracked_request_count() == after_ctrl_click, "repeated ctrl-click release emits zero additional intent")
		await process_frame
		check(adapter.tracked_request_count() == before_ctrl_click + 1 and str(app.toast_label.text) == "Inventory confirmed", "ctrl-click submits one complete-only quick transfer with stable accepted feedback requests=" + str(adapter.tracked_request_count()) + " before=" + str(before_ctrl_click))
		var echo_key := InputEventKey.new()
		echo_key.keycode = KEY_R
		echo_key.pressed = true
		echo_key.echo = true
		screen._unhandled_input(echo_key)
		check(adapter.tracked_request_count() == before_ctrl_click + 1, "echoed keyboard input emits zero inventory intent")
	var projection_probe := _find_rotatable(controller.items_for(&"corpse"))
	var stale_drag_item := projection_probe.duplicate(true)
	if not projection_probe.is_empty():
		var raid_model := bridge.presentation_model(InventoryProjectionBridge.SCOPE_RAID)
		var probe_revision := bridge.confirmed_revision(InventoryProjectionBridge.SCOPE_RAID, owner.corpse_inventory_id)
		var pending_probe := bridge.begin_pending_intent(
			InventoryProjectionBridge.SCOPE_RAID,
			Controller.OP_MOVE,
			{"inventory_id": owner.corpse_inventory_id, "items": [int(projection_probe.item_id)], "ghost_placement": projection_probe.location},
			owner.generation(),
			bridge.scope_generation(InventoryProjectionBridge.SCOPE_RAID)
		)
		check(pending_probe > 0 and raid_model.item_state(owner.corpse_inventory_id, int(projection_probe.item_id)) == InventoryPresentationModel.STATE_PENDING, "pending UI state is distinct from confirmed projection")
		check(bridge.confirmed_revision(InventoryProjectionBridge.SCOPE_RAID, owner.corpse_inventory_id) == probe_revision, "pending UI state does not advance confirmed revision")
		var concurrent_one := owner.raid_authority().rotate_item(owner.corpse_inventory_id, int(projection_probe.item_id), not bool(projection_probe.rotated), RaidInventoryOwner.FIXTURE_ACTOR_ID, 8_801)
		var concurrent_two := owner.raid_authority().rotate_item(owner.corpse_inventory_id, int(projection_probe.item_id), bool(projection_probe.rotated), RaidInventoryOwner.FIXTURE_ACTOR_ID, 8_802)
		check(bool(concurrent_one.get("accepted", false)) and bool(concurrent_two.get("accepted", false)), "concurrent authoritative projections commit in order")
		check(raid_model.get_pending(pending_probe).is_empty() and raid_model.item_state(owner.corpse_inventory_id, int(projection_probe.item_id)) == InventoryPresentationModel.STATE_STALE_CORRECTED, "concurrent projection clears the reversible pending intent")
	else:
		check(false, "concurrent projection fixture exposes a rotatable authoritative item")
	var live_raid_scope_generation := bridge.scope_generation(InventoryProjectionBridge.SCOPE_RAID)
	check(bridge.begin_resynchronization(InventoryProjectionBridge.SCOPE_RAID, owner.generation(), live_raid_scope_generation), "resynchronization enters explicit loading state")
	await process_frame
	check(not controller.mutation_available(&"crate") and not screen._grid_for_source("loot").mutation_enabled, "resynchronizing state disables live mutation")
	check(str(screen._node("StashCompatible").text).contains("MUTATIONS DISABLED"), "resynchronizing state is visible")
	check(bridge.complete_resynchronization(InventoryProjectionBridge.SCOPE_RAID, owner.generation(), bridge.scope_generation(InventoryProjectionBridge.SCOPE_RAID)), "resynchronization restores the latest projection")
	await process_frame
	check(controller.mutation_available(&"crate"), "ready projection restores mutation availability")
	var stale_requests := adapter.tracked_request_count()
	bridge.release_binding()
	await process_frame
	check(not controller.is_bound() and not screen._grid_for_source("loot").mutation_enabled, "binding invalidation disables retained live controls")
	check(not controller.submit_quick(&"loot", stale_drag_item).accepted and adapter.tracked_request_count() == stale_requests, "stale callback/drag target submits nothing after disconnect")
	var recovered: bool = screen.bind_inventory_runtime(owner, bridge, adapter, admission)
	check(recovered, "retained screen can explicitly recover after disconnect error=" + str(controller.last_error) + " bridge=" + str(bridge.last_error) + " status=" + str(bridge.scope_status(InventoryProjectionBridge.SCOPE_RAID)))
	await process_frame
	check(controller.is_bound() and screen._live_inventory_binding, "rebind restores the production seam bound=" + str(controller.is_bound()) + " live=" + str(screen._live_inventory_binding) + " owner=" + str(owner.is_current_generation(owner.generation())) + " bridge=" + str(bridge.is_bound()) + " bridge_generation=" + str(bridge.owner_generation()) + " controller_error=" + str(controller.last_error))
	check(controller.get_signal_connection_list(&"projection_changed").size() == 1, "rebind does not accumulate controller signal callbacks")
	check(not controller.submit_quick(&"loot", stale_drag_item).accepted and adapter.tracked_request_count() == stale_requests, "pre-rebind drag target is rejected by scope generation")
	# Rebinding the bridge replaces InventoryPresentationModel, whose pending-id
	# counter starts at its reserved base again. The controller/adapter lifetime
	# survives this presentation replacement, so the first fresh command must not
	# alias an earlier native command in the adapter's replay ledger.
	var fresh_after_rebind: Dictionary = _find_rotatable(controller.items_for(&"rig"))
	if fresh_after_rebind.is_empty():
		fresh_after_rebind = _find_rotatable(controller.items_for(&"pockets"))
	var fresh_after_rebind_requests := adapter.tracked_request_count()
	var fresh_after_rebind_source := StringName(
		"rig" if not _find_item(controller.items_for(&"rig"), int(fresh_after_rebind.get("item_id", 0))).is_empty() else "pockets")
	var fresh_after_rebind_result := controller.submit_rotate(
		fresh_after_rebind_source, fresh_after_rebind)
	check(not fresh_after_rebind.is_empty() and fresh_after_rebind_result.accepted \
		and not fresh_after_rebind_result.replayed \
		and adapter.tracked_request_count() == fresh_after_rebind_requests + 1,
		"fresh post-rebind command cannot collide with a retired presentation model id result=" + str(fresh_after_rebind_result))
	check(int(fresh_after_rebind_result.get("command_id", 0)) \
		== int(fresh_after_rebind_result.get("ui_pending_command_id", -1)) \
		and int(fresh_after_rebind_result.get("command_id", 0)) >= Controller.PRODUCT_COMMAND_ID_BASE,
		"post-rebind pending identity remains the exact reserved native command id")
	var recreated_controller := Controller.new()
	check(recreated_controller.bind(owner, bridge, adapter, admission), "recreated screen controller binds the retained runtime")
	var recreated_item := _find_item(
		recreated_controller.items_for(fresh_after_rebind_source),
		int(fresh_after_rebind.get("item_id", 0)))
	var recreated_requests := adapter.tracked_request_count()
	var recreated_result := recreated_controller.submit_rotate(
		fresh_after_rebind_source, recreated_item)
	check(recreated_result.accepted and not recreated_result.replayed \
		and int(recreated_result.get("command_id", 0)) > int(fresh_after_rebind_result.get("command_id", 0)) \
		and adapter.tracked_request_count() == recreated_requests + 1,
		"a newly-created controller continues the product command namespace result=" + str(recreated_result))
	recreated_controller.unbind()
	var stale_callback_item: Dictionary = {}
	var rebound_loot_items: Array = screen._items_for("loot")
	if not rebound_loot_items.is_empty():
		stale_callback_item = (rebound_loot_items[0] as Dictionary).duplicate(true)
		stale_callback_item["_binding_token"] = original_binding_token
	var before_stale_callback := adapter.tracked_request_count()
	if not stale_callback_item.is_empty():
		screen._on_quick_move(stale_callback_item, "loot")
	check(adapter.tracked_request_count() == before_stale_callback, "pre-bind screen callback token cannot cross a rebind")
	# Current first-playable verification stays on the authored desktop path. The
	# retained compact layout remains production compatibility code, but this
	# active contract must not execute it or regenerate smaller evidence.
	screen.reflow(Vector2(FIRST_PLAYABLE_SIZE))
	await process_frame
	check(root.get_visible_rect().size.is_equal_approx(Vector2(FIRST_PLAYABLE_SIZE)) and screen._live_inventory_binding and not str((screen._node("PostRaidBar/Title") as Label).text).contains("$") and str((screen._node("RigTitle") as Label).text).contains("LIVE") and not str((screen._node("RigTitle") as Label).text).contains("Scav vest") and (screen._node("RigSwap") as Button).disabled, "exact first-playable live layout exposes no fixture economy or container claims")
	check(root.get_visible_rect().size.is_equal_approx(Vector2(FIRST_PLAYABLE_SIZE)) and not screen._adaptive_applied, "exact first-playable desktop layout retains the authored non-compact path")
	screen.unbind_inventory_runtime()
	check(not screen._live_inventory_binding and not (screen._node("RigSwap") as Button).disabled and not (screen._node("SortStash") as Button).disabled and screen._grid_for_source("stash").mutation_enabled, "explicit unbind restores fixture controls without retaining live-disabled state")
	app.queue_free()

	controller.unbind()
	check(not controller.is_bound(), "unbind clears callbacks and binding")
	owner.teardown(owner.generation())
	bridge.queue_free()
	owner.queue_free()
	await process_frame
	await process_frame
	print("INVENTORY_UI_BINDING_COMPLETE checks=%d failures=%d" % [checks, failures])
	quit(1 if failures > 0 else 0)


func _find_non_merge_pair(items: Array) -> Array:
	for left_value in items:
		if not left_value is Dictionary:
			continue
		var left: Dictionary = left_value
		for right_value in items:
			if not right_value is Dictionary:
				continue
			var right: Dictionary = right_value
			if int(left.get("item_id", 0)) != int(right.get("item_id", 0)) and str(left.get("merge_key", "")) != str(right.get("merge_key", "")):
				return [left, right]
	return []


func _find_stack_item(items: Array) -> Dictionary:
	for value in items:
		if value is Dictionary and int((value as Dictionary).get("quantity", 1)) > 1:
			return value as Dictionary
	return {}


func _find_non_stack_item(items: Array) -> Dictionary:
	for value in items:
		if value is Dictionary and int((value as Dictionary).get("quantity", 1)) == 1:
			return value as Dictionary
	return {}


func _find_rotatable(items: Array) -> Dictionary:
	for value in items:
		if value is Dictionary and bool((value as Dictionary).get("rotatable", false)):
			return value as Dictionary
	return {}


func _slot_for_item(grid: Control, item_id: int) -> Control:
	for slot in grid.get("_slots"):
		if int(slot.item.get("item_id", 0)) == item_id:
			return slot
	return null


func _find_empty_cell(grid: Control, item: Dictionary) -> Vector2i:
	for y in range(int(grid.grid_rows)):
		for x in range(int(grid.grid_columns)):
			var cell := Vector2i(x, y)
			if cell == Vector2i(int(item.get("x", -1)), int(item.get("y", -1))):
				continue
			if grid.can_place(item, cell, str(item.get("item_id", item.get("id", "")))):
				return cell
	return Vector2i(-1, -1)


func _find_item(items: Array, item_id: int) -> Dictionary:
	for item in items:
		if int(item.get("item_id", 0)) == item_id:
			return item
	return {}


func _find_definition(items: Array, definition: String) -> Dictionary:
	for item in items:
		if str(item.get("definition_id", "")) == definition:
			return item
	return {}


func _find_quantity(items: Array, definition: String, quantity: int) -> Dictionary:
	for item in items:
		if str(item.get("definition_id", "")) == definition and int(item.get("quantity", 0)) == quantity:
			return item
	return {}


func _catalog_container_size(resource: InventoryCatalogResource, identifier: StringName) -> Vector2i:
	for value in resource.containers:
		var definition := value as InventoryContainerDefinition
		if definition != null and definition.identifier == identifier:
			return Vector2i(definition.grid_width, definition.grid_height)
	return Vector2i.ZERO


func _catalog_item(resource: InventoryCatalogResource, identifier: StringName) -> InventoryItemDefinition:
	for value in resource.items:
		var definition := value as InventoryItemDefinition
		if definition != null and definition.identifier == identifier:
			return definition
	return null
