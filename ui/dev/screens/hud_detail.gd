extends "res://ui/screens/raid/raid_screen.gd"

## Authored HUD-detail review controller.
##
## The desktop review plate and its mitigation/status hierarchy live in
## hud_detail.tscn.  This controller only synchronizes the shared raid state,
## animation targets and visibility; raid.gd continues to own compact reflow
## and keyboard behavior.

func build() -> void:
	var compact_applied: bool = get_node_or_null("RaidDetail") != null
	if not compact_applied:
		reset_adaptive_layout()
	_sync_mock_state()
	_ring_nodes.clear()
	_blink_nodes.clear()
	_fade_groups.clear()
	var plate: Control = _detail_node("DetailPlate") as Control
	if plate == null:
		return
	if get_node_or_null("RaidDetail") == null:
		plate.position = Vector2(560, 380)
		plate.size = Vector2(800, 320)
		var hint: Label = _detail_node("DetailHint") as Label
		if hint != null:
			hint.position = Vector2(560, 720)
			hint.size = Vector2(800, 22)
	_bind_detail(plate)
	if not compact_applied:
		queue_adaptive_layout()


func _detail_node(node_name: String) -> Node:
	var direct := get_node_or_null(node_name)
	if direct != null:
		return direct
	return find_child(node_name, true, false)


func _bind_detail(plate: Control) -> void:
	var note: Label = plate.get_node("Note") as Label
	note.text = "HUD · BOTTOM-LEFT · 1:1 · DAMAGED STATE"
	var vitals: Control = plate.get_node("Vitals") as Control
	vitals.position = Vector2(0, -760)
	_bind_vitals(vitals)
	var ring: Control = plate.get_node("ReloadRing") as Control
	var connector: ColorRect = plate.get_node("ReloadConnector") as ColorRect
	var show_ring: bool = _reload_active
	ring.visible = show_ring
	connector.visible = show_ring
	if show_ring:
		ring.set("progress", _reload_progress)
		ring.call("set_progress", _reload_progress)
		_ring_nodes.append(ring)
	var hint: Label = _detail_node("DetailHint") as Label
	if hint != null:
		hint.text = "H  LOW HEALTH     R  RELOAD PREVIEW     X  EXTRACT"


func _bind_vitals(vitals: Control) -> void:
	# _build_hud_compact() deliberately uses the true fallback for this review
	# plate, so a fresh detail route shows its damaged-state specimen.
	var low: bool = bool(_state_get("raid_low_health", true))
	var origin: Vector2 = Vector2(56, 884 if low else 958)
	var player_name: Label = vitals.get_node("PlayerName") as Label
	player_name.position = origin
	player_name.text = "OAK JHONSON"
	_set_semibold(player_name)
	var readout: Label = vitals.get_node("HealthReadout") as Label
	readout.position = Vector2(origin.x + 250, origin.y)
	readout.text = "124 / 435" if low else "435 / 435"
	readout.add_theme_color_override("font_color", RED if low else TEXT)
	readout.visible = _setting_string("hud_health_readout", "BAR") == "BAR + NUMBER"
	if not readout.visible:
		readout.text = ""
	for index in range(7):
		var segment: ColorRect = vitals.get_node("HealthSegment%d" % (index + 1)) as ColorRect
		segment.position = Vector2(origin.x + float(index) * (342.0 / 7.0), origin.y + 24)
		segment.size = Vector2(342.0 / 7.0 - 2, 8)
		segment.color = RED if low and index < 2 else GREEN if not low and index < 7 else Color(0.0, 0.0, 0.0, 0.5)
	var health_track: ColorRect = vitals.get_node("HealthTrack") as ColorRect
	health_track.position = Vector2(origin.x, origin.y + 40)
	health_track.size = Vector2(340, 3)
	var health_fill: ColorRect = vitals.get_node("HealthFill") as ColorRect
	health_fill.position = Vector2(origin.x, origin.y + 40)
	health_fill.size = Vector2(163 if low else 265, 3)
	health_fill.color = SOFT
	_bind_vital_row(vitals, "Energy", origin + Vector2(0, 54), 0.64, YELLOW)
	_bind_vital_row(vitals, "Thirst", origin + Vector2(178, 54), 0.22, BLUE)
	var status_y: float = origin.y + 73
	_bind_status_chip(vitals, "Bleeding", Vector2(origin.x, status_y), RED, "BLEEDING", "−3/s", low)
	_bind_status_chip(vitals, "Fracture", Vector2(origin.x + 136, status_y), YELLOW, "FRACTURE", "", low)
	_bind_status_chip(vitals, "Dehydrated", Vector2(origin.x + 272, status_y), BLUE, "DEHYDRATED", "", low)
	var quick_key: Panel = vitals.get_node("QuickHealKey") as Panel
	var quick_title: Label = vitals.get_node("QuickHealTitle") as Label
	var quick_detail: Label = vitals.get_node("QuickHealDetail") as Label
	quick_key.position = Vector2(origin.x, status_y + 34)
	quick_title.position = Vector2(origin.x + 40, status_y + 27)
	quick_detail.position = Vector2(origin.x + 165, status_y + 27)
	quick_key.visible = low
	quick_title.visible = low
	quick_detail.visible = low
	(vitals.get_node("QuickHealKey/Key") as Label).text = "Y" if low else ""
	quick_title.text = "QUICK HEAL" if low else ""
	quick_detail.text = "Bandage ×2 · stops bleed · +40 HP" if low else ""


func _bind_vital_row(vitals: Control, prefix: String, origin: Vector2, value: float, color: Color) -> void:
	var icon: TextureRect = vitals.get_node("%sIcon" % prefix) as TextureRect
	var track: ColorRect = vitals.get_node("%sTrack" % prefix) as ColorRect
	var fill: ColorRect = vitals.get_node("%sFill" % prefix) as ColorRect
	icon.position = origin
	track.position = origin + Vector2(18, 5)
	track.size = Vector2(139, 3)
	fill.position = origin + Vector2(18, 5)
	fill.size = Vector2(139 * value, 3)
	fill.color = color


func _bind_status_chip(vitals: Control, prefix: String, origin: Vector2, color: Color, caption: String, suffix: String, enabled: bool) -> void:
	var chip: Panel = vitals.get_node("Status%s" % prefix) as Panel
	chip.position = origin
	chip.size = Vector2(126, 25)
	chip.modulate.a = 1.0
	(chip.get_node("Stripe") as ColorRect).color = color
	(chip.get_node("Icon") as Control).position = Vector2(9, 7)
	var caption_label: Label = chip.get_node("Caption") as Label
	caption_label.text = caption if enabled else ""
	caption_label.visible = enabled
	var suffix_label: Label = chip.get_node("Suffix") as Label
	suffix_label.text = suffix if enabled else ""
	suffix_label.visible = enabled and not suffix.is_empty()
	chip.visible = enabled
	if enabled and prefix == "Bleeding":
		_blink_nodes.append(chip)
