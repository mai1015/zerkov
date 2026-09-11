extends "res://docs/qa/inventory_ui_binding/astra_final_accept/native_flow.gd"

func _initialize() -> void:
	push_error("DEFERRED_DISPLAY_SUITE: historical multi-resolution inventory QA is retired; reopen only through task 11.8 or an approved display-support proposal")
	quit(2)
	return

## Independent challenge beyond the sealed probes: actual clipped disclosure at
## every output, explicit native close during an accepted refresh, source removal.

func _visible_rect(control: Control) -> Rect2:
	if control == null or not control.is_visible_in_tree():
		return Rect2()
	var result := control.get_global_rect().intersection(screen.get_viewport_rect())
	var parent := control.get_parent()
	while parent != null:
		if parent is Control and parent.clip_contents:
			result = result.intersection(parent.get_global_rect())
		parent = parent.get_parent()
	return result

func _disclosures() -> void:
	for dimensions in [Vector2i(1920,1080),Vector2i(1600,900),Vector2i(1280,720),Vector2i(960,540)]:
		await _open_bound_runtime(dimensions, "%dx%d_section_challenge" % [dimensions.x,dimensions.y])
		var requests := adapter.tracked_request_count()
		var before := bridge.confirmed_snapshot(&"raid", owner.raid_player_inventory_id).canonical_bytes()
		for section in ["health", "stats"]:
			if dimensions.x == 960:
				await _native_click(screen._node("CompactWorkspace/Section_" + section))
			else:
				# Native desktop section activation navigates to a retained route with
				# a forced tab. Bind that route explicitly through the same public seam;
				# automatic product bootstrap binding belongs to a later task.
				await _native_click(screen._node("HealthTab" if section == "health" else "StatsTab"))
				screen = app.screen
				controller = Controller.new()
				screen._inventory_controller = controller
				check(screen.bind_inventory_runtime(owner,bridge,adapter,admission), "native " + section + " route binds the existing runtime")
				await settle(6)
			var column: Control = screen._node("HealthColumn" if section == "health" else "StatsColumn")
			var notice := column.get_node_or_null("LiveFixtureNotice") as Label
			var clipped := _visible_rect(notice)
			var width := notice.get_theme_font("font").get_string_size(notice.text,HORIZONTAL_ALIGNMENT_LEFT,-1,notice.get_theme_font_size("font_size")).x if notice != null else 0.0
			check(screen._live_inventory_binding and column.is_visible_in_tree(), "bound " + section + " is rendered at " + str(dimensions))
			check(notice != null and notice.text.contains("FIXTURE PREVIEW") and clipped.has_area(), "fixture disclosure intersects viewport and every clipping ancestor for " + section + " " + str(dimensions))
			check(notice != null and clipped.encloses(notice.get_global_rect()) and width <= notice.size.x, "complete disclosure fits its rendered label for " + section + " " + str(dimensions))
			await _capture_flow(section, {"notice":notice.text if notice != null else "", "clip":str(clipped), "label":str(notice.get_global_rect()) if notice != null else "", "text_width":width, "input":"native compact section click" if dimensions.x == 960 else "native route navigation plus explicit public runtime binding"})
		check(adapter.tracked_request_count() == requests and bridge.confirmed_snapshot(&"raid",owner.raid_player_inventory_id).canonical_bytes() == before, "section disclosure staging changes no inventory commands or bytes " + str(dimensions))
		await _teardown_flow_runtime()

func _close_and_remove() -> void:
	await _open_bound_runtime(Vector2i(960,540), "960x540_overlay_challenge")
	controller.set_loot_container(&"corpse")
	await _native_click(screen._node("CompactWorkspace/Section_stash"))
	await _native_click(screen._node("LootTab"))
	var bandage := _find_definition(controller.items_for(&"corpse"),str(Catalog.ITEM_BANDAGE))
	var bandage_id := int(bandage.item_id)
	var grid: Control = screen._node("StashGrid")
	await _native_click(_slot_for_item(grid,bandage_id))
	check(is_instance_valid(screen._tooltip) and _visible_rect(screen._tooltip).has_area(), "challenge opens the tooltip with an ordinary Bandage click")
	var close_button: Button
	for button in screen._tooltip.find_children("*", "Button", true, false):
		if button.text.contains("CLOSE"):
			close_button = button
	check(close_button != null, "tooltip exposes a real native close Button")
	if close_button != null:
		var point := close_button.get_global_rect().get_center()
		motion(point,Vector2.ZERO)
		pointer(point,true)
		await settle(1)
		# Genuine accepted command while native close has mouse capture. Its
		# synchronous refresh queues restoration with the tooltip still open.
		var ammo := _find_definition(controller.items_for(&"corpse"),str(Catalog.ITEM_AMMO_762))
		var receipt := controller.submit_drop(&"corpse",&"pockets",ammo,Vector2i.ZERO)
		check(receipt.accepted, "unrelated command commits between native close press and release")
		pointer(point,false)
		check(not is_instance_valid(screen._tooltip), "native close immediately dismisses the retained tooltip")
		await settle(8)
		check(not is_instance_valid(screen._tooltip) and screen._tip_item.is_empty(), "queued refresh cannot resurrect an explicitly closed tooltip")
		check(int(screen._selected_live_item.get("item_id",0)) == bandage_id, "explicit tooltip close preserves Bandage selection")
		await _capture_flow("closed_after_unrelated_receipt", {"receipt":receipt})
	await _native_click(_slot_for_item(grid,bandage_id))
	check(is_instance_valid(screen._tooltip) and _visible_rect(screen._tooltip).has_area(), "native inspection can reopen after explicit close")
	var latest := _find_item(controller.items_for(&"corpse"),bandage_id)
	var removal := controller.submit_quick(&"corpse",latest)
	await settle(8)
	check(removal.accepted and _find_item(controller.items_for(&"corpse"),bandage_id).is_empty(), "genuine accepted transfer removes the inspected item from its source")
	check(not is_instance_valid(screen._tooltip) and screen._tip_item.is_empty(), "removed-source tooltip closes and does not resurrect after deferred refresh")
	await _capture_flow("removed_source", {"receipt":removal,"selected":screen._selected_live_item})
	# A further unrelated accepted receipt must still leave the removed-source
	# overlay closed, independent of exactly how many refresh callbacks fired.
	var tape := _find_definition(controller.items_for(&"crate"),str(Catalog.ITEM_DUCT_TAPE))
	var another := controller.submit_quick(&"crate",tape)
	await settle(8)
	check(another.accepted, "later unrelated command is genuinely accepted")
	check(not is_instance_valid(screen._tooltip), "later accepted receipt cannot restore a stale overlay")
	await _capture_flow("later_receipt_still_closed", {"receipt":another})
	await _teardown_flow_runtime()

func run() -> void:
	root.borderless = true
	root.position = Vector2i.ZERO
	await _disclosures()
	await _close_and_remove()
	var file := FileAccess.open(FLOW_OUTPUT + "/overlay_and_sections_challenge.json", FileAccess.WRITE)
	file.store_string(JSON.stringify({"checks":checks,"failures":failures,"records":flow_records},"\t") + "\n")
	file.close()
	print("ASTRA_OVERLAY_SECTIONS_CHALLENGE_COMPLETE checks=%d failures=%d" % [checks,failures])
	quit(1 if failures > 0 else 0)
