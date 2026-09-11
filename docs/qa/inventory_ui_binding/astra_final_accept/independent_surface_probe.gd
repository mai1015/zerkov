extends "res://docs/qa/inventory_ui_binding/astra_final_accept/native_flow.gd"

func _initialize() -> void:
	push_error("DEFERRED_DISPLAY_SUITE: historical multi-resolution inventory QA is retired; reopen only through task 11.8 or an approved display-support proposal")
	quit(2)
	return

## Fresh final-gate probe: native compact gear reach plus an explicit fixture label.

func _visible_labels() -> Array[String]:
	var labels: Array[String] = []
	for node in screen.find_children("*", "Label", true, false):
		var label := node as Label
		if label == null or not label.is_visible_in_tree():
			continue
		var visible_rect := label.get_global_rect().intersection(screen.get_viewport_rect())
		var ancestor := label.get_parent()
		while ancestor != null:
			if ancestor is Control and (ancestor as Control).clip_contents:
				visible_rect = visible_rect.intersection((ancestor as Control).get_global_rect())
			ancestor = ancestor.get_parent()
		if visible_rect.has_area():
			labels.append(label.text)
	return labels

func run() -> void:
	root.borderless = true
	root.position = Vector2i.ZERO
	for dimensions in [Vector2i(1920,1080),Vector2i(1600,900),Vector2i(1280,720),Vector2i(960,540)]:
		await _open_bound_runtime(dimensions, "%dx%d_independent_surface" % [dimensions.x, dimensions.y])
		check(app.ui_layout_mode == "auto" and screen._adaptive_applied == (dimensions.x == 960), "independent exact auto layout " + str(dimensions))
		var snapshot: InventorySnapshotResource = bridge.confirmed_snapshot(&"raid", owner.raid_player_inventory_id)
		check(snapshot.get_items().is_empty(), "independent authority has no player equipment")
		if dimensions.x == 960:
			await _native_click(screen._node("CompactWorkspace/Section_gear"))
			var gear_scroll := screen._node("CompactWorkspace/CharacterScroll") as ScrollContainer
			while gear_scroll.scroll_vertical < 260:
				var before := gear_scroll.scroll_vertical
				_native_wheel(gear_scroll.get_global_rect().get_center(), MOUSE_BUTTON_WHEEL_DOWN)
				await settle(2)
				if gear_scroll.scroll_vertical == before:
					break
		var live_labels := _visible_labels()
		check(" ".join(live_labels).contains("FIXTURE · LIVE UNAVAILABLE"), "live unavailable weapon marker is actually visible inside native clipping " + str(dimensions))
		await _capture_flow("live_gear_labels", {"visible_labels": live_labels, "player_items": snapshot.get_items()})
		screen.unbind_inventory_runtime()
		if dimensions.x == 960:
			await _native_click(screen._node("CompactWorkspace/Section_gear"))
		await settle(6)
		app.toast_label.hide()
		var fixture_labels := _visible_labels()
		var fixture_text := " ".join(fixture_labels).to_upper()
		var explicitly_labeled := fixture_text.contains("FIXTURE") or fixture_text.contains("PREVIEW") or fixture_text.contains("PROTOTYPE") or fixture_text.contains("MOCK")
		check(explicitly_labeled, "fixture preview must carry a visible fixture/prototype label after explicit unbind " + str(dimensions))
		await _capture_flow("fixture_label_gate", {"visible_labels": fixture_labels, "explicitly_labeled": explicitly_labeled})
		await _teardown_flow_runtime()
	var file := FileAccess.open(FLOW_OUTPUT + "/independent_surface.json", FileAccess.WRITE)
	file.store_string(JSON.stringify({"checks": checks, "failures": failures, "records": flow_records}, "\t") + "\n")
	file.close()
	print("ASTRA_INDEPENDENT_SURFACE_COMPLETE checks=%d failures=%d" % [checks,failures])
	quit(1 if failures > 0 else 0)
