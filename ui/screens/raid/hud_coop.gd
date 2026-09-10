extends "res://ui/screens/raid/raid_screen.gd"

## Authored co-op raid HUD controller.
##
## The desktop co-op hierarchy lives in hud_coop.tscn. This controller binds
## the shared mock raid state and co-op-only squad markers to those authored
## nodes while leaving inherited compact layout and input behavior intact.

const CROSSHAIR_COLORS: Dictionary = {
	"WHITE": TEXT,
	"GREEN": GREEN,
	"BLUE": BLUE,
	"ORANGE": ORANGE,
	"RED": RED,
	"YELLOW": YELLOW,
}

func build() -> void:
	reset_adaptive_layout()
	_sync_mock_state()
	_ring_nodes.clear()
	_blink_nodes.clear()
	_fade_groups.clear()
	_squad_countdown = null
	_reset_desktop_positions()
	_bind_squad()
	_bind_timer()
	_bind_feed()
	_bind_teammate()
	_bind_vitals()
	_bind_weapon()
	_bind_crosshair()
	_bind_overlays()
	queue_adaptive_layout()


func _reset_desktop_positions() -> void:
	var frame := get_node_or_null("BackgroundFrame") as TextureRect
	if frame != null:
		frame.position = Vector2(-30, -16)
		frame.size = Vector2(1980, 1113)
	var atmosphere := get_node_or_null("Atmosphere") as TextureRect
	if atmosphere != null:
		atmosphere.position = Vector2.ZERO
		atmosphere.size = Vector2(W, H)
	for path in ["ReloadOverlay", "EmptyMagOverlay"]:
		var overlay := get_node_or_null(path) as Control
		if overlay != null:
			overlay.position = Vector2.ZERO
	var remote := get_node_or_null("RemoteSquadLabel") as Label
	var teammate := get_node_or_null("TeammateGroup") as Control
	if remote != null and teammate != null and remote.get_parent() != teammate:
		remote.reparent(teammate)
	remote = get_node_or_null("TeammateGroup/RemoteSquadLabel") as Label
	if remote != null:
		remote.position = Vector2(24, 540)


func _configure_group(path: String, anchor: Vector2, safe_direction: Vector2, fades: bool = false, visible: bool = true) -> Control:
	var group := get_node_or_null(path) as Control
	if group == null:
		return null
	group.set_meta("hud_anchor", anchor)
	group.pivot_offset = anchor
	group.scale = Vector2.ONE * clampf(float(_state_get("hud_scale", 100.0)) / 100.0, 0.7, 1.4)
	group.position = safe_direction * (float(_state_get("hud_safe_zone", 56.0)) - 56.0)
	group.modulate.a = clampf(float(_state_get("hud_opacity", 90.0)) / 100.0, 0.2, 1.0)
	group.visible = visible
	if fades and visible:
		_fade_groups.append(group)
	return group


func _bind_squad() -> void:
	var enabled := _setting_bool("hud_squad_tags", true)
	var group := _configure_group("SquadGroup", Vector2(56, 36), Vector2(1, 0.65), false, enabled)
	if group == null:
		return
	var title := get_node("SquadGroup/SquadTitle") as Label
	title.text = "SQUAD · 3 / 4" if enabled else ""
	var names: Array[String] = ["KEVIN_J", "OYO_TRPLE", "OAK_JHONSON"]
	var name_paths: Array[String] = ["KevinRow/Name", "OyoRow/Name", "OakRow/Name"]
	var row_paths: Array[String] = ["KevinRow", "OyoRow", "OakRow"]
	for i in range(name_paths.size()):
		var row := get_node("SquadGroup/%s" % row_paths[i]) as Control
		row.visible = enabled
		row.modulate.a = 1.0 if i == 0 else 0.8
		var name_label := get_node("SquadGroup/%s" % name_paths[i]) as Label
		name_label.text = names[i] if enabled else ""
	var KevinHealth := get_node("SquadGroup/KevinRow/Health") as ColorRect
	var KevinDot := get_node("SquadGroup/KevinRow/Dot") as ColorRect
	var OyoHealth := get_node("SquadGroup/OyoRow/Health") as ColorRect
	var OyoDot := get_node("SquadGroup/OyoRow/Dot") as ColorRect
	var OakHealth := get_node("SquadGroup/OakRow/Health") as ColorRect
	var OakDot := get_node("SquadGroup/OakRow/Dot") as ColorRect
	KevinHealth.visible = enabled
	KevinDot.visible = enabled
	OyoHealth.visible = enabled
	OyoDot.visible = enabled
	OakHealth.visible = enabled
	OakDot.visible = enabled
	for path in ["KevinRow/SpeakerWave1", "KevinRow/SpeakerWave2", "KevinRow/SpeakerWave3", "KevinRow/SpeakerWave4", "KevinRow/SpeakerWave5"]:
		var speaker_part := get_node_or_null("SquadGroup/%s" % path) as ColorRect
		if speaker_part != null:
			speaker_part.visible = enabled


func _bind_timer() -> void:
	_configure_group("TimerGroup", Vector2(960, 32), Vector2(0, 0.65))
	(get_node("TimerGroup/Timer") as Label).text = "32:14"
	(get_node("TimerGroup/Extract") as Label).text = "EXTRACT · RAIL BRIDGE · 340 m"


func _bind_feed() -> void:
	var mode := _setting_string("hud_loot_feed", "FULL")
	var group := _configure_group("FeedGroup", Vector2(1864, 36), Vector2(-1, 0.65), false, mode != "OFF")
	if group == null:
		return
	var loot := get_node("FeedGroup/LootText") as Label
	var loot_kind := get_node("FeedGroup/LootKind") as Label
	var kill := get_node("FeedGroup/KillText") as Label
	var kill_kind := get_node("FeedGroup/KillKind") as Label
	var task := get_node("FeedGroup/TaskText") as Label
	var task_kind := get_node("FeedGroup/TaskKind") as Label
	loot.visible = mode in ["FULL", "LOOT ONLY"]
	loot_kind.visible = loot.visible
	kill.visible = mode == "FULL"
	kill_kind.visible = kill.visible
	task.visible = mode == "FULL" and _setting_bool("hud_tracked_task", true)
	task_kind.visible = task.visible
	loot.text = "Car battery ×1" if loot.visible else ""
	loot_kind.text = "LOOT" if loot_kind.visible else ""
	kill.text = "Scav · 34 m · headshot" if kill.visible else ""
	kill_kind.text = "KILL" if kill_kind.visible else ""
	task.text = "Supply run 2/3" if task.visible else ""
	task_kind.text = "TASK" if task_kind.visible else ""


func _bind_teammate() -> void:
	var enabled := _setting_bool("hud_squad_tags", true)
	var group := _configure_group("TeammateGroup", Vector2(1146, 642), Vector2.ZERO, false, enabled)
	if group == null:
		return
	var sprite := get_node("TeammateGroup/TeammateSprite") as TextureRect
	var name_label := get_node("TeammateGroup/TeammateName") as Label
	var distance := get_node("TeammateGroup/TeammateDistance") as Label
	var track := get_node("TeammateGroup/HealthTrack") as ColorRect
	var health := get_node("TeammateGroup/Health") as ColorRect
	var remote := get_node("TeammateGroup/RemoteSquadLabel") as Label
	sprite.visible = enabled
	name_label.text = "KEVIN_J" if enabled else ""
	distance.text = "14 m" if enabled else ""
	track.visible = enabled
	health.visible = enabled
	remote.text = "◂ OYO_TRPLE · 140 m" if enabled else ""
	remote.visible = enabled
	for i in range(1, 6):
		var wave := get_node_or_null("TeammateGroup/SpeakerWave%d" % i) as ColorRect
		if wave != null:
			wave.visible = enabled


func _bind_vitals() -> void:
	var group := _configure_group("VitalsGroup", Vector2(56, 1024), Vector2(1, -1), true)
	if group == null:
		return
	var origin := Vector2(56, 884 if _low_health else 958)
	var player_name := get_node("VitalsGroup/PlayerName") as Label
	player_name.position = origin
	player_name.text = "OAK JHONSON"
	_set_semibold(player_name)
	var readout := get_node("VitalsGroup/HealthReadout") as Label
	readout.position = Vector2(origin.x + 250, origin.y)
	readout.text = "124 / 435" if _low_health else "435 / 435"
	readout.add_theme_color_override("font_color", RED if _low_health else TEXT)
	readout.visible = _setting_string("hud_health_readout", "BAR") == "BAR + NUMBER"
	if not readout.visible:
		readout.text = ""
	for i in range(7):
		var segment := get_node("VitalsGroup/HealthSegment%d" % (i + 1)) as ColorRect
		segment.position = Vector2(origin.x + float(i) * (342.0 / 7.0), origin.y + 24)
		segment.size = Vector2(342.0 / 7.0 - 2, 8)
		segment.color = RED if _low_health and i < 2 else GREEN if not _low_health and i < 7 else Color(0.0, 0.0, 0.0, 0.5)
	var health_track := get_node("VitalsGroup/HealthTrack") as ColorRect
	health_track.position = Vector2(origin.x, origin.y + 40)
	health_track.size = Vector2(340, 3)
	var health_fill := get_node("VitalsGroup/HealthFill") as ColorRect
	health_fill.position = Vector2(origin.x, origin.y + 40)
	health_fill.size = Vector2(163 if _low_health else 265, 3)
	health_fill.color = SOFT
	_bind_vital_row("Energy", origin + Vector2(0, 54), 0.64, YELLOW)
	_bind_vital_row("Thirst", origin + Vector2(178, 54), 0.22, BLUE)
	var status_y := origin.y + 73
	var show_status := _low_health
	var icon_only := _setting_string("hud_status_icons", "ICON + LABEL") == "ICON"
	var chip_step := 42.0 if icon_only else 136.0
	_bind_status_chip("Bleeding", Vector2(origin.x, status_y), RED, "BLEEDING", "−3/s", show_status, icon_only)
	_bind_status_chip("Fracture", Vector2(origin.x + chip_step, status_y), YELLOW, "FRACTURE", "", show_status, icon_only)
	_bind_status_chip("Dehydrated", Vector2(origin.x + chip_step * 2, status_y), BLUE, "DEHYDRATED", "", show_status, icon_only)
	var quick_key := get_node("VitalsGroup/QuickHealKey") as Control
	var quick_title := get_node("VitalsGroup/QuickHealTitle") as Label
	var quick_detail := get_node("VitalsGroup/QuickHealDetail") as Label
	quick_key.position = Vector2(origin.x, status_y + 29)
	quick_title.position = Vector2(origin.x + 40, status_y + 27)
	quick_detail.position = Vector2(origin.x + 165, status_y + 27)
	quick_key.visible = show_status
	quick_title.visible = show_status
	quick_detail.visible = show_status
	(get_node("VitalsGroup/QuickHealKey/Key") as Label).text = "Y" if show_status else ""
	quick_title.text = "QUICK HEAL" if show_status else ""
	quick_detail.text = "Bandage ×2 · stops bleed · +40 HP" if show_status else ""


func _bind_vital_row(prefix: String, origin: Vector2, value: float, color: Color) -> void:
	var icon := get_node("VitalsGroup/%sIcon" % prefix) as TextureRect
	var track := get_node("VitalsGroup/%sTrack" % prefix) as ColorRect
	var fill := get_node("VitalsGroup/%sFill" % prefix) as ColorRect
	icon.position = origin
	track.position = origin + Vector2(18, 5)
	track.size = Vector2(139, 3)
	fill.position = origin + Vector2(18, 5)
	fill.size = Vector2(139 * value, 3)
	fill.color = color


func _bind_status_chip(prefix: String, origin: Vector2, color: Color, caption: String, suffix: String, enabled: bool, icon_only: bool) -> void:
	var chip := get_node("VitalsGroup/Status%s" % prefix) as Panel
	var stripe := chip.get_node("Stripe") as ColorRect
	var icon := chip.get_node("Icon") as Control
	var caption_label := chip.get_node("Caption") as Label
	var suffix_label := chip.get_node("Suffix") as Label
	chip.position = origin
	chip.size = Vector2(30 if icon_only else 126, 25)
	stripe.color = color
	icon.position = Vector2(9, 7)
	caption_label.text = caption if enabled and not icon_only else ""
	caption_label.visible = enabled and not icon_only
	suffix_label.text = suffix if enabled and not icon_only else ""
	suffix_label.visible = enabled and not icon_only and not suffix.is_empty()
	chip.visible = enabled
	chip.modulate.a = 1.0
	if enabled and prefix == "Bleeding":
		_blink_nodes.append(chip)


func _bind_weapon() -> void:
	var mode := _setting_string("hud_ammo_counter", "EXACT")
	var group := _configure_group("WeaponGroup", Vector2(1864, 1024), Vector2(-1, -1), true, mode != "OFF")
	if group == null:
		return
	var ammo := int(_state_get("raid_ammo", 24))
	var rough := mode == "ROUGH"
	var counter := get_node("WeaponGroup/AmmoCounter") as Label
	var reserve := get_node("WeaponGroup/AmmoReserve") as Label
	var rough_panel := get_node("WeaponGroup/RoughAmmoPanel") as Panel
	var rough_fill := get_node("WeaponGroup/RoughAmmoPanel/RoughAmmoFill") as ColorRect
	var weapon_name := get_node("WeaponGroup/WeaponName") as Label
	var fire_mode := get_node("WeaponGroup/FireMode") as Label
	var slot_labels: Array[Label] = [
		get_node("WeaponGroup/PrimarySlot") as Label,
		get_node("WeaponGroup/SecondarySlot") as Label,
		get_node("WeaponGroup/MeleeSlot") as Label,
	]
	var slot_icons: Array[TextureRect] = [
		get_node("WeaponGroup/PrimaryIcon") as TextureRect,
		get_node("WeaponGroup/SecondaryIcon") as TextureRect,
		get_node("WeaponGroup/MeleeIcon") as TextureRect,
	]
	var active := mode != "OFF"
	weapon_name.text = "AKM · 7.62×39" if active else ""
	fire_mode.text = "SEMI" if active else ""
	for i in range(slot_labels.size()):
		slot_labels[i].text = str(i + 1) if active else ""
		slot_labels[i].visible = active
		slot_icons[i].visible = active
	counter.visible = active and not rough
	reserve.visible = active and not rough
	rough_panel.visible = active and rough
	if rough:
		counter.text = ""
		reserve.text = ""
		rough_fill.position = Vector2(5, 5 + (1.0 - ammo / 30.0) * 39)
		rough_fill.size = Vector2(18, ammo / 30.0 * 39)
		rough_fill.color = MUTED if _reload_active else TEXT
	else:
		counter.text = ("--" if _reload_active else str(ammo)) if active else ""
		counter.add_theme_color_override("font_color", MUTED if _reload_active else RED if ammo == 0 else TEXT)
		reserve.text = "/ 90" if active else ""


func _bind_crosshair() -> void:
	var group := _configure_group("CrosshairGroup", Vector2(960, 540), Vector2.ZERO)
	if group == null:
		return
	var crosshair := get_node("CrosshairGroup/Crosshair") as Control
	crosshair.set("shape", _setting_string("hud_crosshair_shape", "CROSS"))
	crosshair.set("tint", CROSSHAIR_COLORS.get(_setting_string("hud_crosshair_color", "WHITE"), TEXT))
	crosshair.set("hit", false)
	crosshair.set("kill", false)
	_crosshair = crosshair


func _bind_overlays() -> void:
	var ring := get_node("ReloadOverlay/ReloadRing")
	var connector := get_node("ReloadOverlay/ReloadConnector") as ColorRect
	var empty := get_node("EmptyMagOverlay") as Control
	var show_ring := _reload_active and _setting_bool("hud_overhead_reload", true)
	var show_empty := not _reload_active and int(_state_get("raid_ammo", 24)) == 0 and _setting_bool("hud_overhead_reload", true)
	ring.visible = show_ring
	connector.visible = show_ring
	empty.visible = show_empty
	(get_node("EmptyMagOverlay/EmptyMagKey/Key") as Label).text = "R" if show_empty else ""
	(get_node("EmptyMagOverlay/MagEmpty") as Label).text = "MAG EMPTY" if show_empty else ""
	if show_ring:
		ring.set("progress", _reload_progress)
		ring.call("set_progress", _reload_progress)
		_ring_nodes.append(ring)
