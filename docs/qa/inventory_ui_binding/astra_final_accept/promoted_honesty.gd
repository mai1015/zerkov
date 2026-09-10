extends "res://docs/qa/inventory_ui_binding/astra_final_accept/capture.gd"

## Committed regression evidence for the two presentation-honesty P2 repairs.
## This probe keeps the live authority empty, captures the retained gear panel
## at every required native size, then explicitly returns to fixture preview.
## It never writes icon metadata into a native snapshot and writes only to the
## separate repair_honesty evidence directory.

const HONESTY_OUTPUT := "res://docs/qa/inventory_ui_binding/astra_final_accept/promoted_honesty"
const PLACEHOLDER_ICON := "res://assets/handoff/item_box.png"
const ENCRYPTED_DRIVE := "zerkov.item.valuable.encrypted_drive"
const GOLD_WATCH := "zerkov.item.valuable.gold_watch"

var honesty_records: Array[Dictionary] = []


func _teardown_runtime() -> void:
	# Keep teardown assertion-free so a failing check cannot leave a graphical
	# Godot process or a previous owner/bridge alive for the next resolution.
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
	await settle(3)


func _visible_rect_after_clipping(control: Control) -> Rect2:
	if control == null or not control.is_visible_in_tree():
		return Rect2()
	var visible_rect := control.get_global_rect()
	var ancestor: Node = control
	while ancestor is Control:
		var current := ancestor as Control
		if current.clip_contents:
			visible_rect = visible_rect.intersection(current.get_global_rect())
			if visible_rect.size.x <= 0.0 or visible_rect.size.y <= 0.0:
				return Rect2()
		ancestor = current.get_parent()
	var viewport_rect := Rect2(Vector2.ZERO, Vector2(root.size))
	visible_rect = visible_rect.intersection(viewport_rect)
	return visible_rect if visible_rect.size.x > 0.0 and visible_rect.size.y > 0.0 else Rect2()


func _label_is_visually_reachable(label: Label) -> bool:
	var visible_rect := _visible_rect_after_clipping(label)
	return visible_rect.size.x > 0.0 and visible_rect.size.y > 0.0


func _visible_labels(parent: Node) -> Array[String]:
	var labels: Array[String] = []
	if parent == null:
		return labels
	for value in parent.find_children("*", "Label", true, false):
		var label := value as Label
		if label != null and _label_is_visually_reachable(label) and not str(label.text).is_empty():
			labels.append(str(label.text))
	return labels


func _visible_character_labels() -> Array[String]:
	return _visible_labels(screen._node("CharacterColumn"))


func _visible_surface_labels() -> Array[String]:
	return _visible_labels(screen._surface)


func _label_text_fits(label: Label) -> bool:
	if label == null:
		return false
	var font := label.get_theme_font("font")
	var font_size := label.get_theme_font_size("font_size")
	if font == null or font_size <= 0:
		return false
	return font.get_string_size(label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x <= label.size.x + 1.0


func _canonical_bytes(scope: StringName, inventory_id: int) -> PackedByteArray:
	var snapshot: InventorySnapshotResource = bridge.confirmed_snapshot(scope, inventory_id)
	return snapshot.canonical_bytes() if snapshot != null else PackedByteArray()


func _assert_no_presentation_fields(scope: StringName, inventory_id: int, source: String) -> void:
	var snapshot: InventorySnapshotResource = bridge.confirmed_snapshot(scope, inventory_id)
	check(snapshot != null, "canonical snapshot exists for " + source)
	if snapshot == null:
		return
	for raw_value in snapshot.get_items():
		if not raw_value is Dictionary:
			continue
		var raw: Dictionary = raw_value
		check(not raw.has("icon"), "canonical native row has no icon for " + source)
		check(not raw.has("icon_placeholder"), "canonical native row has no placeholder flag for " + source)
		check(not raw.has("icon_accessibility_label"), "canonical native row has no artwork accessibility fact for " + source)


func _assert_placeholder_artwork() -> void:
	check(ResourceLoader.exists(PLACEHOLDER_ICON), "neutral placeholder asset resolves")
	var crate_items := controller.items_for(&"crate")
	for definition in [ENCRYPTED_DRIVE, GOLD_WATCH]:
		var presentation: Dictionary = controller._presentation_for(definition)
		check(str(presentation.get("icon", "")) == PLACEHOLDER_ICON, "honest neutral mapping for " + definition)
		check(bool(presentation.get("icon_placeholder", false)), "placeholder flag is explicit for " + definition)
		check(str(presentation.get("icon_accessibility_label", "")).to_lower().contains("placeholder"), "placeholder accessibility label is explicit for " + definition)
		check(ResourceLoader.exists(str(presentation.get("icon", ""))), "placeholder mapping loads for " + definition)
		var projected := _find_definition(crate_items, definition)
		check(not projected.is_empty(), "fixture projects " + definition)
		if projected.is_empty():
			continue
		check(str(projected.get("name", "")) == ("Encrypted Drive" if definition == ENCRYPTED_DRIVE else "Gold Watch"), "stable item name is preserved for " + definition)
		check(int(projected.get("quantity", 0)) == 1, "stable item quantity is preserved for " + definition)
		check(bool(projected.get("icon_placeholder", false)), "projected placeholder flag is explicit for " + definition)
		check(str(projected.get("icon_accessibility_label", "")).to_lower().contains("placeholder"), "projected placeholder label is explicit for " + definition)
		check(str(projected.get("icon", "")) == PLACEHOLDER_ICON, "projected neutral icon is used for " + definition)

	var loot_grid := screen._grid_for_source("loot") as Control
	check(loot_grid != null, "loot grid exists for placeholder visual check")
	if loot_grid != null:
		for definition in [ENCRYPTED_DRIVE, GOLD_WATCH]:
			var projected := _find_definition(crate_items, definition)
			var slot := _slot_for_item(loot_grid, int(projected.get("item_id", 0)))
			check(slot != null, "placeholder item has a retained native slot for " + definition)
			if slot == null:
				continue
			check(str(slot._tag.text) == "PLACEHOLDER", "placeholder slot is visibly marked for " + definition)
			check(str(slot.tooltip_text).to_lower().contains("placeholder art"), "placeholder slot is accessibly marked for " + definition)


func _assert_live_fixture_honesty() -> Dictionary:
	var character := screen._node("CharacterColumn") as Control
	check(character != null and character.is_visible_in_tree(), "live gear column remains visible in the retained hierarchy")
	var labels := _visible_character_labels()
	var combined := " ".join(labels)
	for forbidden in ["24/30", "5/5", "M1911", "Pump shotgun", "AKM", "Machete", "7.62×39", ".45"]:
		check(not combined.contains(forbidden), "live empty authority does not claim fixture equipment " + forbidden)
	var gear_hint := character.get_node_or_null("GearHint") as Label if character != null else null
	check(gear_hint != null and str(gear_hint.text).contains("FIXTURE PREVIEW"), "live gear hint identifies fixture preview")
	check(gear_hint != null and str(gear_hint.text).contains("UNAVAILABLE"), "live gear hint identifies unavailable equipment")

	for slot_name in ["SlingSlot", "BackSlot", "LegStrapSlot", "HolsterSlot"]:
		var slot := character.get_node_or_null(slot_name) as Button if character != null else null
		check(slot != null and slot.disabled, "live equipment action is disabled for " + slot_name)
		if slot == null:
			continue
		check(str(slot.tooltip_text).to_lower().contains("unavailable"), "live equipment tooltip is unavailable for " + slot_name)
		if slot_name == "SlingSlot":
			check(not str(slot.tooltip_text).to_lower().contains("move"), "live sling tooltip has no move affordance")
			check(not str(slot.tooltip_text).to_lower().contains("rmb"), "live sling tooltip has no options affordance")

	var rig_title := screen._node("RigTitle") as Label
	var pack_title := screen._node("PackTitle") as Label
	check(rig_title != null and str(rig_title.text).contains("UNAVAILABLE"), "live rig copy is unavailable")
	check(pack_title != null and str(pack_title.text).contains("UNAVAILABLE"), "live backpack copy is unavailable")
	for swap_path in ["RigSwap", "PackSwap"]:
		var swap := screen._node(swap_path) as Button
		check(swap != null and swap.disabled, "live container action is disabled for " + swap_path)
		if swap != null:
			check(str(swap.text).contains("UNAVAILABLE"), "live container copy is unavailable for " + swap_path)
	var quick_title := screen._node("QuickUseTitle") as Label
	check(quick_title != null and str(quick_title.text).contains("UNAVAILABLE"), "live quick-use copy is unavailable")
	var quick_slot := screen._node("QuickSlot5") as Button
	check(quick_slot != null and quick_slot.disabled, "live quick-use action is disabled")
	for post_path in ["MoveLoot", "Reinsure", "SellJunk"]:
		var post_button := screen._node("PostRaidBar/" + post_path) as Button
		check(post_button != null and post_button.disabled, "live post-raid action is disabled for " + post_path)
		if post_button != null:
			check(str(post_button.text).contains("UNAVAILABLE"), "live post-raid copy is unavailable for " + post_path)
	return {"labels": labels, "gear_hint": gear_hint.text if gear_hint != null else ""}


func _assert_live_section_disclosures(dimensions: Vector2i) -> void:
	# Compact section buttons keep health/stats reachable on the same bound screen.
	# Their authored values remain fixture presentation until a domain projection
	# exists, so the disclosure must be a visible label inside the clipped section,
	# not only a tooltip or the inventory status bar.
	if dimensions != Vector2i(960, 540):
		return
	for section in ["health", "stats"]:
		screen._select_compact_section(section)
		await settle(8)
		var column := screen._node(("HealthColumn" if section == "health" else "StatsColumn")) as Control
		var notice := column.get_node_or_null("LiveFixtureNotice") as Label if column != null else null
		check(notice != null and notice.visible and notice.is_visible_in_tree(), "live compact " + section + " disclosure is visible")
		check(notice != null and str(notice.text).contains("FIXTURE PREVIEW"), "live compact " + section + " disclosure identifies fixture values")
		check(notice != null and _label_is_visually_reachable(notice), "live compact " + section + " disclosure intersects every clipping ancestor")
		var labels := _visible_labels(column)
		check(" ".join(labels).contains("FIXTURE PREVIEW"), "live compact " + section + " visible label collection includes disclosure")
		await _capture_honesty("live_" + section, dimensions, {"disclosure": notice.text if notice != null else "", "visible_labels": labels})
	screen._select_compact_section("gear")
	await settle(8)


func _assert_fixture_preview_restored() -> Dictionary:
	check(not screen._live_inventory_binding, "fixture mode is restored after live unbind")
	var visible_surface_labels := _visible_surface_labels()
	var visible_surface_text := " ".join(visible_surface_labels)
	check(visible_surface_text.contains("FIXTURE PREVIEW"), "fixture preview disclosure is visible after unbind")
	var character := screen._node("CharacterColumn") as Control
	check(character != null and character.is_visible_in_tree(), "fixture gear column remains visible")
	var sling := character.get_node_or_null("SlingSlot") as Button if character != null else null
	var detail := character.get_node_or_null("SlingSlot/SlingDetail") as Label if character != null else null
	check(sling != null and not sling.disabled, "fixture sling action is restored")
	check(detail != null and str(detail.text) == "AKM · 7.62×39 · 24/30", "fixture gear preview retains its authored detail")
	if sling != null:
		check(str(sling.tooltip_text).contains("move to stash"), "fixture sling tooltip is restored")
	var hint := character.get_node_or_null("GearHint") as Label if character != null else null
	check(hint != null and str(hint.text).contains("FIXTURE PREVIEW"), "fixture gear hint visibly discloses preview mode")
	check(hint != null and not hint.clip_text and hint.autowrap_mode == TextServer.AUTOWRAP_OFF, "fixture gear disclosure keeps bounded native label settings")
	check(hint == null or not str(hint.text).contains("LIVE EQUIPMENT UNAVAILABLE"), "fixture gear hint no longer claims live unavailability")
	check(hint == null or not str(hint.tooltip_text).to_lower().contains("live"), "fixture gear tooltip has no stale live authority claim")
	var status := screen._node("StashCompatible") as Label
	check(status != null and str(status.text) == "FIXTURE PREVIEW", "fixture stash status is bounded and explicit")
	if status != null:
		check(_label_text_fits(status), "fixture stash status fits its authored label width")
		check(not status.clip_text and status.autowrap_mode == TextServer.AUTOWRAP_OFF, "fixture stash status does not clip or wrap")
		check(str(status.tooltip_text).contains("FIXTURE PREVIEW"), "fixture stash status tooltip identifies preview mode")
		check(not str(status.tooltip_text).to_lower().contains("live"), "fixture stash status tooltip has no stale live authority claim")
	var compact_hint := screen._node("CompactWorkspace/InventoryHints") as Label
	check(compact_hint != null and str(compact_hint.text).contains("FIXTURE PREVIEW"), "fixture compact status visibly discloses preview mode")
	if compact_hint != null:
		check(not compact_hint.clip_text and compact_hint.autowrap_mode == TextServer.AUTOWRAP_OFF, "fixture compact status keeps bounded native label settings")
		check(str(compact_hint.tooltip_text).contains("FIXTURE PREVIEW"), "fixture compact tooltip identifies preview mode")
		check(not str(compact_hint.tooltip_text).to_lower().contains("live"), "fixture compact tooltip has no stale live authority claim")
	var rig_swap := screen._node("RigSwap") as Button
	var pack_swap := screen._node("PackSwap") as Button
	check(rig_swap != null and not rig_swap.disabled and not str(rig_swap.text).contains("UNAVAILABLE"), "fixture rig swap copy is restored")
	check(pack_swap != null and not pack_swap.disabled and not str(pack_swap.text).contains("UNAVAILABLE"), "fixture backpack swap copy is restored")
	var post_title := screen._node("PostRaidBar/Title") as Label
	check(post_title != null and str(post_title.text).contains("FIXTURE PREVIEW") and str(post_title.text).contains("SURVIVED"), "fixture post-raid title visibly discloses preview mode")
	check(post_title != null and _label_text_fits(post_title), "fixture post-raid disclosure fits its authored label width")
	check(post_title != null and _label_is_visually_reachable(post_title), "fixture post-raid disclosure is not hidden by an ancestor clip")
	return {"sling_detail": detail.text if detail != null else "", "gear_hint": hint.text if hint != null else "", "visible_surface_labels": visible_surface_labels, "status": status.text if status != null else "", "status_tooltip": status.tooltip_text if status != null else "", "compact_hint": compact_hint.text if compact_hint != null else ""}


func _capture_honesty(state: String, dimensions: Vector2i, extra: Dictionary = {}) -> void:
	# The mode-switch toast is not part of the honesty claim; hide it so the
	# compact capture leaves the retained gear labels and spacing visible.
	if app != null and app.toast_label != null:
		app.toast_label.hide()
	await settle(2)
	RenderingServer.force_draw(true)
	var image := root.get_texture().get_image()
	var file_name := "%dx%d_%s.png" % [dimensions.x, dimensions.y, state]
	check(image.get_size() == dimensions, "honesty capture matches output " + file_name)
	check(image.save_png(HONESTY_OUTPUT + "/" + file_name) == OK, "save honesty capture " + file_name)
	var record := {
		"image": file_name,
		"state": state,
		"dimensions": [dimensions.x, dimensions.y],
		"visible_character_labels": _visible_character_labels(),
		"visible_surface_labels": _visible_surface_labels(),
		"extra": extra,
	}
	honesty_records.append(record)
	print("ASTRA_HONESTY_CAPTURE ", file_name, " ", JSON.stringify(record))


func run() -> void:
	print("ASTRA_PRESENTATION_HONESTY_REPAIR_START")
	if DisplayServer.get_name() == "headless":
		push_error("presentation honesty evidence requires the graphical renderer")
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(HONESTY_OUTPUT))
	root.borderless = true
	root.position = Vector2i.ZERO
	for dimensions in [Vector2i(1920, 1080), Vector2i(1600, 900), Vector2i(1280, 720), Vector2i(960, 540)]:
		root.size = dimensions
		print("ASTRA_HONESTY_OUTPUT ", dimensions)
		setup_runtime()
		var player_snapshot: InventorySnapshotResource = bridge.confirmed_snapshot(&"raid", owner.raid_player_inventory_id)
		check(player_snapshot != null, "empty live player snapshot exists")
		check(player_snapshot != null and player_snapshot.get_items().is_empty(), "authoritative live player inventory is empty")
		var canonical_before := {
			"player": _canonical_bytes(&"raid", owner.raid_player_inventory_id),
			"crate": _canonical_bytes(&"raid", owner.world_crate_inventory_id),
			"corpse": _canonical_bytes(&"raid", owner.corpse_inventory_id),
			"profile": _canonical_bytes(&"profile", owner.profile_inventory_id),
		}
		_assert_no_presentation_fields(&"raid", owner.raid_player_inventory_id, "player")
		_assert_no_presentation_fields(&"raid", owner.world_crate_inventory_id, "crate")
		_assert_no_presentation_fields(&"raid", owner.corpse_inventory_id, "corpse")
		_assert_no_presentation_fields(&"profile", owner.profile_inventory_id, "profile")

		app = load("res://ui/main.tscn").instantiate()
		app.initial_route = "inventory"
		root.add_child(app)
		await settle(12)
		screen = app.screen
		screen._inventory_controller = controller
		check(screen.bind_inventory_runtime(owner, bridge, adapter, admission), "honesty screen binds")
		screen._set_loot_mode(true)
		if dimensions == Vector2i(960, 540):
			screen._select_compact_section("gear")
		await settle(10)
		_assert_placeholder_artwork()
		var live_extra := _assert_live_fixture_honesty()
		var live_title := screen._node("PostRaidBar/Title") as Label
		check(live_title != null and str(live_title.text).contains("LIVE INVENTORY"), "live empty screen retains explicit live title")
		await _capture_honesty("live_empty", dimensions, live_extra)
		await _assert_live_section_disclosures(dimensions)

		screen.unbind_inventory_runtime()
		if dimensions == Vector2i(960, 540):
			screen._select_compact_section("gear")
		await settle(8)
		var fixture_extra := _assert_fixture_preview_restored()
		await _capture_honesty("fixture_preview", dimensions, fixture_extra)

		check(_canonical_bytes(&"raid", owner.raid_player_inventory_id) == canonical_before["player"], "player canonical snapshot is unchanged")
		check(_canonical_bytes(&"raid", owner.world_crate_inventory_id) == canonical_before["crate"], "crate canonical snapshot is unchanged")
		check(_canonical_bytes(&"raid", owner.corpse_inventory_id) == canonical_before["corpse"], "corpse canonical snapshot is unchanged")
		check(_canonical_bytes(&"profile", owner.profile_inventory_id) == canonical_before["profile"], "profile canonical snapshot is unchanged")
		await _teardown_runtime()

	var report := {
		"engine": Engine.get_version_info(),
		"display": DisplayServer.get_name(),
		"checks": checks,
		"failures": failures,
		"human_approval": false,
		"records": honesty_records,
	}
	var file := FileAccess.open(HONESTY_OUTPUT + "/captures.json", FileAccess.WRITE)
	if file == null:
		push_error("presentation honesty repair evidence could not open captures.json")
		failures += 1
	else:
		file.store_string(JSON.stringify(report, "\t") + "\n")
		file.close()
	print("ASTRA_PRESENTATION_HONESTY_REPAIR_COMPLETE checks=%d failures=%d" % [checks, failures])
	quit(1 if failures > 0 else 0)
