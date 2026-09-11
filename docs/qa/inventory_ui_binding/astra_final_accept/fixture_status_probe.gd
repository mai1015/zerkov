extends "res://docs/qa/inventory_ui_binding/astra_final_accept/native_flow.gd"

func _initialize() -> void:
	push_error("DEFERRED_DISPLAY_SUITE: historical multi-resolution inventory QA is retired; reopen only through task 11.8 or an approved display-support proposal")
	quit(2)
	return

## Inspect restored fixture status bounds and its native accessibility tooltip.
func run() -> void:
	root.borderless = true
	root.position = Vector2i.ZERO
	for dimensions in [Vector2i(1920,1080),Vector2i(1600,900),Vector2i(1280,720),Vector2i(960,540)]:
		await _open_bound_runtime(dimensions, "%dx%d_fixture_status" % [dimensions.x,dimensions.y])
		screen.unbind_inventory_runtime()
		await settle(5)
		var label := screen._node("CompactWorkspace/InventoryHints" if dimensions.x == 960 else "StashCompatible") as Label
		var measured := label.get_theme_font("font").get_string_size(label.text,HORIZONTAL_ALIGNMENT_LEFT,-1,label.get_theme_font_size("font_size"))
		check(measured.x <= label.size.x, "restored fixture status must fit its visible label " + str(dimensions))
		check(not label.tooltip_text.to_upper().contains("LIVE"), "restored fixture status must not retain a live authority tooltip " + str(dimensions))
		await _capture_flow("status_after_unbind", {"text":label.text,"tooltip":label.tooltip_text,"label_width":label.size.x,"measured_width":measured.x,"clip_text":label.clip_text})
		await _teardown_flow_runtime()
	var file := FileAccess.open(FLOW_OUTPUT + "/fixture_status.json",FileAccess.WRITE)
	file.store_string(JSON.stringify({"checks":checks,"failures":failures,"records":flow_records},"\t") + "\n")
	file.close()
	print("ASTRA_FIXTURE_STATUS_COMPLETE checks=%d failures=%d" % [checks,failures])
	quit(1 if failures > 0 else 0)
