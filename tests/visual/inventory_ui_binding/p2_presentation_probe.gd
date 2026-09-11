extends "res://tests/visual/inventory_ui_binding/capture.gd"
## HISTORICAL / DEFERRED presentation packet across smaller outputs; current
## first-playable verification MUST NOT invoke or regenerate this source.

## Bounded repair evidence for the remaining Astra P2 findings.  This probe
## writes only to the repair evidence directory; the rejected Astra gate
## report/captures remain untouched.

func _initialize() -> void:
	push_error("DEFERRED_DISPLAY_SUITE: p2_presentation_probe is historical; reopen only through task 11.8 or an approved display-support proposal")
	quit(2)

const REPAIR_OUTPUT := "res://docs/qa/inventory_ui_binding/repair_p2"
var repair_records: Array[Dictionary] = []


func _teardown_runtime() -> void:
	# Keep this path non-asserting: a failed check must still release every
	# per-resolution node/binding before the next capture or final quit.
	if app != null and is_instance_valid(app):
		app.queue_free()
	if controller != null and is_instance_valid(controller):
		controller.unbind()
	if owner != null and is_instance_valid(owner):
		owner.teardown(owner.generation())
		owner.queue_free()
	if bridge != null and is_instance_valid(bridge):
		bridge.queue_free()
	app = null
	screen = null
	controller = null
	owner = null
	bridge = null
	adapter = null
	admission = null
	await settle()


func _label_text_fits(label: Label) -> bool:
	if label == null:
		return false
	var font := label.get_theme_font("font")
	var font_size := label.get_theme_font_size("font_size")
	if font == null or font_size <= 0:
		return false
	var measured := font.get_string_size(label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
	return measured.x <= label.size.x + 1.0


func _output_scale() -> Vector2:
	var logical_size := screen.get_viewport_rect().size
	if logical_size.x <= 0.0 or logical_size.y <= 0.0:
		return Vector2.ONE
	return Vector2(root.size) / logical_size


func _output_rect(control: Control) -> Rect2:
	if control == null:
		return Rect2(-1, -1, 0, 0)
	var scale := _output_scale()
	var logical_rect := control.get_global_rect()
	return Rect2(logical_rect.position * scale, logical_rect.size * scale)


func _status_bounds_are_safe() -> bool:
	var status := screen._node("StashCompatible") as Label
	var hint := screen._node("CompactWorkspace/InventoryHints") as Label
	var status_rect := status.get_global_rect() if status != null else Rect2(-1, -1, 0, 0)
	var viewport_rect := Rect2(Vector2.ZERO, Vector2(root.size))
	var status_pixel_rect := _output_rect(status)
	var status_inside := status != null and _label_text_fits(status) \
		and status_pixel_rect.position.x >= -1.0 and status_pixel_rect.end.x <= viewport_rect.size.x + 1.0 \
		and status_pixel_rect.position.y >= -1.0 and status_pixel_rect.end.y <= viewport_rect.size.y + 1.0
	var hint_inside := true
	if hint != null and hint.is_visible_in_tree():
		var hint_pixel_rect := _output_rect(hint)
		hint_inside = _label_text_fits(hint) \
			and hint_pixel_rect.position.x >= -1.0 and hint_pixel_rect.end.x <= viewport_rect.size.x + 1.0 \
			and hint_pixel_rect.position.y >= -1.0 and hint_pixel_rect.end.y <= viewport_rect.size.y + 1.0
	return status_inside and hint_inside


func _assert_projected_artwork() -> void:
	# Every first-playable definition has a presentation registry entry or the
	# safe existing fallback.  These paths are not native item facts.
	for definition_value in Catalog.FIRST_PLAYABLE_ITEM_IDS:
		var definition := str(definition_value)
		var presentation: Dictionary = controller._presentation_for(definition)
		check(ResourceLoader.exists(str(presentation.get("icon", ""))), "presentation icon resolves for " + definition)
		check(not presentation.get("icon", "") is Dictionary, "presentation icon remains a path for " + definition)

	for source in ["pockets", "rig", "backpack", "stash", "loot"]:
		var descriptor := controller.descriptor(StringName(source))
		var snapshot: InventorySnapshotResource = bridge.confirmed_snapshot(StringName(descriptor.scope), int(descriptor.inventory_id))
		if snapshot != null:
			for raw_value in snapshot.get_items():
				if raw_value is Dictionary:
					check(not (raw_value as Dictionary).has("icon"), "canonical native row has no presentation icon for " + source)
		var projected: Array = controller.items_for(StringName(source))
		var grid: Control = screen._grid_for_source(source)
		for item_value in projected:
			var item := item_value as Dictionary
			check(ResourceLoader.exists(str(item.get("icon", ""))), "projected icon resource exists for " + str(item.get("item_definition_identifier", "")))
		if grid != null:
			for slot in grid._slots:
				check(slot._icon != null and slot._icon.texture != null, "native live slot has loaded texture for " + str(slot.item.get("item_definition_identifier", "")))

	var unknown: Dictionary = controller._presentation_for("zerkov.item.unknown.repair_probe")
	check(ResourceLoader.exists(str(unknown.get("icon", ""))), "unknown definition uses an existing safe icon fallback")


func _repair_capture(state: String, dimensions: Vector2i, extra: Dictionary = {}) -> void:
	await settle()
	# SceneTree process frames do not guarantee that the viewport texture has
	# consumed the latest retained-control changes. Force the graphical server to
	# draw synchronously so the PNG and the geometry record describe the same
	# live state without an unbounded frame_post_draw await.
	await settle(2)
	RenderingServer.force_draw(true)
	var rendered := root.get_texture().get_image()
	var file_name := "%dx%d_%s.png" % [dimensions.x, dimensions.y, state]
	check(rendered.get_size() == dimensions, "repair capture matches output " + file_name)
	check(rendered.save_png(REPAIR_OUTPUT + "/" + file_name) == OK, "save repair capture " + file_name)
	var status := screen._node("StashCompatible") as Label
	var pockets := screen._node("PocketsGrid") as Control
	var rig_header := screen._node("RigContainer") as Control
	var record := {
		"image": file_name,
		"state": state,
		"dimensions": [dimensions.x, dimensions.y],
		"status": status.text if status != null else "",
		"status_tooltip": status.tooltip_text if status != null else "",
		"status_rect": str(status.get_global_rect()) if status != null else "",
		"status_fits": _status_bounds_are_safe(),
		"output_size": [root.size.x, root.size.y],
		"status_pixel_rect": str(_output_rect(status)),
		"pockets_rect": str(pockets.get_global_rect()) if pockets != null else "",
		"rig_header_rect": str(rig_header.get_global_rect()) if rig_header != null else "",
		"extra": extra,
	}
	repair_records.append(record)
	print("ASTRA_REPAIR_CAPTURE ", file_name, " ", JSON.stringify(record))


func _native_click(control: Control) -> void:
	if not is_instance_valid(control):
		check(false, "native tooltip regression target exists")
		return
	var position := control.get_global_rect().get_center()
	motion(position, Vector2.ZERO)
	pointer(position, true)
	await settle(1)
	pointer(position, false)
	await settle(5)


func _visible_overlay_rect(control: Control) -> Rect2:
	if control == null or not control.is_visible_in_tree():
		return Rect2()
	var rect := control.get_global_rect()
	var ancestor: Node = control
	while ancestor is Control:
		var current := ancestor as Control
		if current.clip_contents:
			rect = rect.intersection(current.get_global_rect())
			if rect.size.x <= 0.0 or rect.size.y <= 0.0:
				return Rect2()
		ancestor = current.get_parent()
	return rect.intersection(Rect2(Vector2.ZERO, Vector2(root.size)))


func _assert_compact_tooltip_refresh() -> void:
	# The selected Bandage click is native Godot input. The unrelated move is a
	# real production controller/adapter receipt so this covers the same accepted
	# projection refresh that previously hid the retained overlay.
	controller.set_loot_container(&"corpse")
	screen._set_loot_mode(true)
	screen._select_compact_section("stash")
	await settle(8)
	var loot_tab := screen._node("LootTab") as Control
	await _native_click(loot_tab)
	var grid := screen._node("StashGrid") as Control
	var bandage := _find_definition(controller.items_for(&"loot"), str(Catalog.ITEM_BANDAGE))
	var bandage_slot := _slot_for_item(grid, int(bandage.get("item_id", 0))) if not bandage.is_empty() else null
	await _native_click(bandage_slot)
	var selected_id := int(bandage.get("item_id", 0))
	check(selected_id > 0 and int(screen._selected_live_item.get("item_id", 0)) == selected_id, "native compact tooltip selection keeps Bandage identity")
	check(is_instance_valid(screen._tooltip) and screen._tooltip.is_visible_in_tree(), "native compact Bandage tooltip opens")
	check(_visible_overlay_rect(screen._tooltip).size.x > 0.0 and _visible_overlay_rect(screen._tooltip).size.y > 0.0, "native compact Bandage tooltip is on-screen")
	var focus: Control = root.gui_get_focus_owner()
	check(focus == bandage_slot, "native compact Bandage click retains slot focus")
	var ammo := _find_definition(controller.items_for(&"loot"), str(Catalog.ITEM_AMMO_762))
	var requests_before := adapter.tracked_request_count()
	var receipt := controller.submit_drop(&"loot", &"pockets", ammo, Vector2i.ZERO)
	await settle(8)
	check(receipt.accepted, "unrelated corpse ammo transfer is accepted by the production adapter")
	check(adapter.tracked_request_count() == requests_before + 1, "tooltip refresh receives exactly one adapter receipt")
	check(_find_definition(controller.items_for(&"loot"), str(Catalog.ITEM_AMMO_762)).is_empty(), "unrelated corpse ammo leaves the canonical loot projection")
	check(int(screen._selected_live_item.get("item_id", 0)) == selected_id, "Bandage selection survives unrelated canonical refresh")
	var tooltip_visible: bool = is_instance_valid(screen._tooltip) and screen._tooltip.is_visible_in_tree()
	check(tooltip_visible, "selected Bandage tooltip remains visibly open after receipt")
	check(_visible_overlay_rect(screen._tooltip).size.x > 0.0 and _visible_overlay_rect(screen._tooltip).size.y > 0.0, "selected Bandage tooltip remains bounded after receipt")
	if app != null and app.toast_label != null:
		app.toast_label.hide()
	await _repair_capture("compact_tooltip_after_receipt", Vector2i(960, 540), {"receipt": receipt, "selected_id": selected_id, "tooltip_visible": tooltip_visible})

	screen._close_tip()
	await settle(4)
	check(not is_instance_valid(screen._tooltip), "explicit tooltip close clears the retained overlay")
	var removed := controller.submit_quick(&"loot", bandage)
	await settle(8)
	check(removed.accepted, "selected Bandage removal is accepted by the production adapter")
	check(_find_definition(controller.items_for(&"loot"), str(Catalog.ITEM_BANDAGE)).is_empty(), "removed Bandage leaves the canonical loot projection")
	check(not is_instance_valid(screen._tooltip), "explicitly closed tooltip does not resurrect after item removal")
	check(int(screen._selected_live_item.get("item_id", 0)) != selected_id or screen._selected_live_source != "loot", "removed Bandage is no longer selected in its old source")


func run() -> void:
	print("ASTRA_REPAIR_P2_START")
	if DisplayServer.get_name() == "headless":
		push_error("P2 repair evidence requires the graphical renderer")
		quit(1)
		return
	root.borderless = true
	root.position = Vector2i.ZERO
	for dimensions in [Vector2i(1920, 1080), Vector2i(1600, 900), Vector2i(1280, 720), Vector2i(960, 540)]:
		root.size = dimensions
		print("ASTRA_REPAIR_P2_OUTPUT ", dimensions)
		setup_runtime()
		print("ASTRA_REPAIR_P2_RUNTIME_READY ", dimensions)
		var ammo := _find_stack_item(controller.items_for(&"corpse"))
		if dimensions != Vector2i(960, 540):
			check(controller.submit_drop(&"corpse", &"pockets", ammo, Vector2i.ZERO).accepted, "repair fixture seeds a live pocket item")
		else:
			check(not ammo.is_empty(), "compact tooltip fixture retains unrelated corpse ammo")
		app = load("res://ui/main.tscn").instantiate()
		app.initial_route = "inventory"
		root.add_child(app)
		await settle(10)
		print("ASTRA_REPAIR_P2_APP_READY ", dimensions)
		screen = app.screen
		screen._inventory_controller = controller
		check(screen.bind_inventory_runtime(owner, bridge, adapter, admission), "repair screen binds")
		print("ASTRA_REPAIR_P2_BOUND ", dimensions)
		screen._set_loot_mode(true)
		await settle(10)
		print("ASTRA_REPAIR_P2_LIVE_READY ", dimensions)
		_assert_projected_artwork()
		print("ASTRA_REPAIR_P2_ART_READY ", dimensions)
		check(_status_bounds_are_safe(), "ready status fits its retained hierarchy")
		print("ASTRA_REPAIR_P2_STATUS_READY ", dimensions)
		check(str(screen._node("StashCompatible").text).contains("PROFILE READ-ONLY"), "ready profile read-only status is concise and explicit")
		await _repair_capture("ready", dimensions, {"icons_checked": true})
		print("ASTRA_REPAIR_P2_CAPTURE_READY ", dimensions)

		var model := bridge.presentation_model(&"raid")
		var pending := bridge.begin_pending_intent(&"raid", &"move", {"inventory_id": owner.raid_player_inventory_id, "items": [1], "ghost_placement": {}}, owner.generation(), bridge.scope_generation(&"raid"))
		if pending > 0:
			model.apply_result({"accepted": false, "command_id": pending, "status": {"code": &"command_rejected", "reason": &"qa_stale_revision"}})
			await settle()
		check(str(app.toast_label.text).contains("REJECTED") and not str(app.toast_label.text).contains("_"), "rejection reason is human-readable and bounded")
		check(_status_bounds_are_safe(), "rejection keeps status bounds safe")
		await _repair_capture("rejected", dimensions, {"toast": app.toast_label.text})

		check(bridge.begin_resynchronization(&"raid", owner.generation(), bridge.scope_generation(&"raid")), "repair enters resynchronizing state")
		await settle(3)
		check(str(screen._node("StashCompatible").text).contains("MUTATIONS DISABLED") and str(screen._node("StashCompatible").text).contains("RESYNC"), "resynchronizing status is concise and explicit")
		check(_status_bounds_are_safe(), "resynchronizing status fits retained hierarchy")
		await _repair_capture("resynchronizing", dimensions)
		check(bridge.complete_resynchronization(&"raid", owner.generation(), bridge.scope_generation(&"raid")), "repair completes resynchronization before follow-up input")
		await settle(5)

		if dimensions == Vector2i(960, 540):
			var pockets: Control = screen._node("PocketsGrid")
			var rig_header: Control = screen._node("RigContainer")
			var overlap := pockets.get_global_rect().intersection(rig_header.get_global_rect())
			check(overlap.size == Vector2.ZERO, "repair compact pockets and rig do not overlap")
			await _repair_capture("compact_spacing", dimensions, {"overlap": str(overlap)})
			await _assert_compact_tooltip_refresh()

		bridge.release_binding()
		await settle(3)
		check(str(screen._node("StashCompatible").text).contains("MUTATIONS DISABLED") and str(screen._node("StashCompatible").text).contains("DISCONNECTED"), "disconnected status is concise and explicit")
		check(_status_bounds_are_safe(), "disconnected status fits retained hierarchy")
		await _repair_capture("disconnected", dimensions)

		# Each resolution is an isolated native runtime. Keeping an earlier app,
		# owner, or bridge alive can cover the next capture and conceal teardown or
		# leak failures behind the most recently added screen.
		await _teardown_runtime()

	var report := {"engine": Engine.get_version_info(), "display": DisplayServer.get_name(), "checks": checks, "failures": failures, "human_approval": false, "records": repair_records}
	var file := FileAccess.open(REPAIR_OUTPUT + "/captures.json", FileAccess.WRITE)
	if file == null:
		push_error("P2 repair evidence could not open captures.json")
		failures += 1
	else:
		file.store_string(JSON.stringify(report, "\t") + "\n")
		file.close()
	print("ASTRA_REPAIR_P2_COMPLETE checks=%d failures=%d" % [checks, failures])
	quit(1 if failures > 0 else 0)
