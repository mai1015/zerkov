extends "res://docs/qa/inventory_ui_binding/astra_final_accept/independent_surface_probe.gd"
## Check reachable non-inventory sections on the same live compact screen.
func run() -> void:
	root.borderless = true
	root.position = Vector2i.ZERO
	await _open_bound_runtime(Vector2i(960, 540), "960x540_live_sections")
	var original_screen := screen
	var requests := adapter.tracked_request_count()
	var before := bridge.confirmed_snapshot(&"raid", owner.raid_player_inventory_id).canonical_bytes()
	for section in ["health", "stats"]:
		await _native_click(screen._node("CompactWorkspace/Section_" + section))
		await create_timer(3.7).timeout
		check(screen == original_screen and screen._live_inventory_binding and screen._compact_section == section,
			"native " + section + " section is reachable on the same live bound screen")
		var labels := _visible_labels()
		var visible_copy := " ".join(labels).to_upper()
		var marked := visible_copy.contains("FIXTURE") or visible_copy.contains("PREVIEW") or visible_copy.contains("PROTOTYPE") or visible_copy.contains("MOCK")
		check(marked, "live compact " + section + " fixture values must carry a visible preview label")
		await _capture_flow(section, {"visible_labels": labels, "explicit_fixture_label": marked})
	check(adapter.tracked_request_count() == requests and bridge.confirmed_snapshot(&"raid", owner.raid_player_inventory_id).canonical_bytes() == before,
		"non-inventory section navigation changes no inventory command or canonical bytes")
	await _teardown_flow_runtime()
	var file := FileAccess.open(FLOW_OUTPUT + "/live_sections.json", FileAccess.WRITE)
	file.store_string(JSON.stringify({"checks": checks, "failures": failures, "records": flow_records}, "\t") + "\n")
	file.close()
	print("ASTRA_LIVE_SECTIONS_COMPLETE checks=%d failures=%d" % [checks, failures])
	quit(1 if failures > 0 else 0)
