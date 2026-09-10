extends "res://docs/qa/inventory_ui_binding/astra_final_accept/native_flow.gd"
## An unrelated canonical source revision must retain the selected tooltip.
func run() -> void:
	root.borderless = true
	root.position = Vector2i.ZERO
	await _open_bound_runtime(Vector2i(960, 540), "960x540_tooltip_refresh")
	controller.set_loot_container(&"corpse")
	await _native_click(screen._node("CompactWorkspace/Section_stash"))
	await _native_click(screen._node("LootTab"))
	var bandage := _find_definition(controller.items_for(&"corpse"), str(Catalog.ITEM_BANDAGE))
	var slot := _slot_for_item(screen._node("StashGrid"), int(bandage.item_id))
	await _native_click(slot)
	check(is_instance_valid(screen._tooltip) and screen._tooltip.is_visible_in_tree(), "native compact Bandage tooltip initially visible")
	await _capture_flow("before_unrelated_loot")
	# The controller submits a real canonical command; this simulates another
	# accepted input while the selected Bandage itself remains unchanged.
	var ammo := _find_definition(controller.items_for(&"corpse"), str(Catalog.ITEM_AMMO_762))
	var result := controller.submit_drop(&"corpse", &"pockets", ammo, Vector2i.ZERO)
	await settle(6)
	check(result.accepted and _find_item(controller.items_for(&"corpse"), int(ammo.item_id)).is_empty(), "unrelated ammunition loot commits through the production adapter")
	check(int(screen._selected_live_item.get("item_id", 0)) == int(bandage.item_id), "unchanged Bandage selection survives unrelated authoritative revision")
	check(is_instance_valid(screen._tooltip) and screen._tooltip.is_visible_in_tree(), "compact selected tooltip remains visibly open after unrelated authoritative revision")
	await _capture_flow("after_unrelated_loot", {"selected_item": screen._selected_live_item, "tooltip_exists": is_instance_valid(screen._tooltip), "tooltip_visible": screen._tooltip.is_visible_in_tree() if is_instance_valid(screen._tooltip) else false, "command": result})
	await _teardown_flow_runtime()
	var file := FileAccess.open(FLOW_OUTPUT + "/compact_tooltip_refresh.json", FileAccess.WRITE)
	file.store_string(JSON.stringify({"checks": checks, "failures": failures, "records": flow_records}, "\t") + "\n")
	file.close()
	print("ASTRA_COMPACT_TOOLTIP_REFRESH_COMPLETE checks=%d failures=%d" % [checks, failures])
	quit(1 if failures > 0 else 0)
