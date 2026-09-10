extends "res://ui/core/screen.gd"

const KIT = preload("res://ui/theme/tokens.gd")

## Shared raid-screen runtime.
##
## Raid-family scenes own their authored UI hierarchy. This script retains the
## shared mock state, input, animation, and compact reflow behavior.

const W: float = 1920.0
const H: float = 1080.0

const BG: Color = Color("#0a0b0a")
const TEXT: Color = Color("#e6e8e3")
const MUTED: Color = Color("#8b918a")
const SOFT: Color = Color("#b7bcb4")
const LINE: Color = Color(1.0, 1.0, 1.0, 0.12)
const ORANGE: Color = Color("#e8962e")
const HOVER_ORANGE: Color = Color("#f2b15a")
const GREEN: Color = Color("#5fd36b")
const RED: Color = Color("#d9483b")
const YELLOW: Color = Color("#e9d35a")
const BLUE: Color = Color("#4c8dff")

const ASSET_BG: String = "res://assets/handoff/bg_raid_frame.png"

var _low_health: bool = false
var _reload_active: bool = false
var _reload_progress: float = 0.0
var _blink_time: float = 0.0
var _ring_nodes: Array = []
var _blink_nodes: Array = []
var _ready_squad: bool = false
var _idle_time: float = 0.0
var _fade_groups: Array[Control] = []
var _crosshair: Control
var _shot_time: float = 0.0
var _squad_countdown: Label
var _squad_started: float = -1.0
var _ready_elapsed: float = 0.0


func layout_compact(view: Vector2) -> void:
	var route = _route()
	if route in ["hud", "hud_coop"]:
		_layout_compact_hud(view)
	elif route.begins_with("summary"):
		_layout_compact_summary(view, route == "summary_squad")
	else:
		_layout_compact_detail(view)


func _layout_compact_hud(view: Vector2) -> void:
	var safe = clampf(24.0 + float(_state_get("hud_safe_zone", 56.0)) - 56.0, 16.0, 96.0)
	for child in get_children():
		if not child is Control:
			continue
		if child is TextureRect and child.size.x >= W:
			if child.texture.resource_path == ASSET_BG:
				# The supplied frame includes gray editor margins around its
				# 640×360 play area. Crop those pixels before fitting the HUD.
				var frame = AtlasTexture.new()
				frame.atlas = child.texture
				frame.region = Rect2(3, 3, 640, 360)
				child.texture = frame
			child.position = Vector2.ZERO
			child.size = view
		elif child.has_meta("hud_anchor"):
			var anchor: Vector2 = child.get_meta("hud_anchor")
			if anchor == Vector2(1864, 36):
				for marker in child.get_children():
					if marker is Label and marker.text in ["LOOT", "KILL", "TASK"]:
						ZLayoutSnapshot.layout_value(marker, "theme_override_font_sizes/font_size", 11)
						ZLayoutSnapshot.layout_value(marker, "theme_override_colors/font_color", SOFT)
						ZLayoutSnapshot.layout_value(marker, "theme_override_colors/font_outline_color", Color.BLACK)
						ZLayoutSnapshot.layout_value(marker, "theme_override_constants/outline_size", 2)
			var target = anchor * view / Vector2(W, H)
			if anchor.x <= 56:
				target.x = safe
			elif anchor.x >= 1800:
				target.x = view.x - safe
				var right_edge = anchor.x
				for node in child.get_children():
					if node is Control:
						right_edge = maxf(right_edge, node.position.x + node.size.x)
				target.x -= (right_edge - anchor.x) * child.scale.x
			if anchor.y >= 1000:
				target.y = view.y - safe
			elif anchor.y <= 36:
				target.y = maxf(16.0, 24.0 + (safe - 24.0) * 0.65)
			# The feed gets its own row when three top groups cannot fit.
			if anchor.x >= 1800 and anchor.y <= 36 and view.x < 1200:
				target.y += 112.0 * child.scale.y
			if anchor.x >= 1800 and anchor.y >= 1000 and _low_health and 655.0 * child.scale.x > view.x - safe * 2.0:
				target.y -= 160.0 * child.scale.y
			child.position = target - anchor
			if anchor == Vector2(1146, 642):
				for tag in child.get_children():
					if tag is Label and tag.position.x < 100:
						tag.reparent(self)
						tag.position = Vector2(16, view.y * 0.5)
		else:
			# Overhead reload and empty-mag prompts track the world center.
			child.position += view * 0.5 - Vector2(W, H) * 0.5


func _layout_compact_detail(view: Vector2) -> void:
	var nodes: Array = []
	var bounds = Rect2()
	for child in get_children():
		if child is Control:
			nodes.append(child)
			bounds = child.get_rect() if nodes.size() == 1 else bounds.merge(child.get_rect())
	if nodes.is_empty():
		return
	var available = view - Vector2(48, 48)
	var scrollbar_space = 24.0 if bounds.size.y > available.y else 0.0
	var pane_size = Vector2(minf(bounds.size.x + scrollbar_space, available.x), minf(bounds.size.y, available.y))
	var content = ZAdaptive.pane(self, Rect2((view - pane_size) * 0.5, pane_size), bounds.size, "RaidDetail")
	ZAdaptive.move_nodes(nodes, content, bounds.position)


func _layout_compact_summary(view: Vector2, squad: bool) -> void:
	ZAdaptive.backdrop(self, view)
	for child in get_children():
		if child is TextureRect and child.size.x >= W:
			child.position = Vector2.ZERO
			child.size = view
	var sections: Array = []
	var labels: Array = []
	if squad:
		labels = ["SQUAD", "AWARDS & TIMELINE", "RAID STATS"]
		sections = [Rect2(48, 236, 1364, 724), Rect2(1432, 236, 440, 724), Rect2(1312, 50, 560, 80)]
	else:
		labels = ["LOOT", "TIMELINE", "PROGRESS", "RAID STATS"]
		sections = [Rect2(648, 236, 704, 724), Rect2(48, 236, 560, 724), Rect2(1392, 236, 480, 724), Rect2(1335, 50, 537, 80)]
	var panes: Array[Control] = []
	var pane_bounds = Rect2(24, 176, view.x - 48, view.y - 296)
	for i in range(sections.size()):
		var section: Rect2 = sections[i]
		var content_size = section.size
		if squad and i == 0:
			content_size = Vector2(898, 640)
		elif i == sections.size() - 1:
			content_size.y = 96
		elif not squad and i == 1:
			content_size.y = 304
		elif not squad and i == 2:
			content_size.y = 408
		var content = ZAdaptive.pane(self, pane_bounds, content_size, "RaidSummary%d" % i)
		var moved = ZAdaptive.move_group(self, "RaidSummary%d" % i, section.position, content)
		if squad and i == 0:
			for j in range(moved.size()):
				moved[j].position = Vector2((j % 2) * 457, (j / 2) * 324)
				moved[j].size.y = 300
		if squad and i == 1:
			# Remove reference-only whitespace before the loss notice.
			for node in moved:
				if node.position.y > 600:
					node.position.y = 444
			content.custom_minimum_size.y = 534
		panes.append(content.get_parent())
	var state_key = "compact_" + _route() + "_tab"
	var active = clampi(int(_state_get(state_key, 0)), 0, labels.size() - 1)
	for i in range(labels.size()):
		panes[i].visible = i == active
		var tab_index: int = i
		var tab = _button(self, labels[i], Rect2(24 + i * 192, 128, 184, 36), func():
			_state_set(state_key, tab_index)
			build(), i == active)
		tab.name = "RaidSummaryTab%d" % i
	for node in get_children():
		if not node is Control or node is ScrollContainer or node.name.begins_with("RaidSummaryTab"):
			continue
		if node is Button:
			node.position += Vector2(view.x - W + 24, view.y - H + 24)
		elif node.position.y >= 986:
			node.position = Vector2(24, view.y - 112)
			node.size = Vector2(view.x - 48, 40)
			if node is Label:
				node.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
				node.vertical_alignment = VERTICAL_ALIGNMENT_TOP
		elif node.position.x >= 48 and node.position.y >= 36 and node.position.y < 134:
			node.position -= Vector2(24, 20)
	_rule(self, 24, view.y - 120, view.x - 48)


func _process(delta: float) -> void:
	_blink_time += delta
	_idle_time += delta
	if _reload_active:
		_reload_progress += delta / 2.4
		if _reload_progress >= 1.0 and _route() != "reload":
			_reload_active = false
			_state_set("raid_reloading", false)
			_state_set("raid_ammo", 30)
			_idle_time = 0.0
			build()
		elif _route() == "reload":
			_reload_progress = fmod(_reload_progress, 1.0)
		for ring_value in _ring_nodes:
			if is_instance_valid(ring_value):
				ring_value.set_progress(_reload_progress)
	var blink_on: bool = fmod(_blink_time, 1.0) < 0.52
	for blink_value in _blink_nodes:
		if is_instance_valid(blink_value):
			blink_value.modulate.a = 1.0 if blink_on else 0.36
	var fade_mode = _setting_string("hud_idle_fade", "3 S")
	var fade_after = 3.0 if fade_mode == "3 S" else 6.0
	var target_alpha = 0.35 if fade_mode != "OFF" and _idle_time > fade_after and not _low_health and not _reload_active else 1.0
	for group in _fade_groups:
		group.modulate.a = move_toward(group.modulate.a, float(_state_get("hud_opacity", 90.0)) / 100.0 * target_alpha, delta * 2)
	_shot_time = maxf(0, _shot_time - delta)
	if is_instance_valid(_crosshair):
		_crosshair.spread = _shot_time * 20 if _setting_bool("hud_dynamic_spread", true) else 0.0
		_crosshair.hit = _shot_time > 0 and _setting_string("hud_hit_marker", "ON") != "OFF" and (_setting_string("hud_hit_marker", "ON") != "KILL ONLY" or _crosshair.kill)
		_crosshair.queue_redraw()
	if _route() == "summary_squad":
		var remaining = maxi(0, 42 - int((Time.get_ticks_msec() / 1000.0) - _squad_started))
		if is_instance_valid(_squad_countdown):
			_squad_countdown.text = "Everyone's loot went to their own stash  |  Squad continues when all are READY · %d / 3 · 00:%02d auto" % [3 if _ready_squad else 2, remaining]
		if _ready_squad:
			_ready_elapsed += delta
		if remaining == 0 or _ready_elapsed >= 1.2:
			_state_set("squad_ready", false)
			_navigate("bunker")


func _unhandled_input(event: InputEvent) -> void:
	if not accepts_input(): return
	var viewport = get_viewport()
	if event is InputEventMouseMotion or event.is_pressed():
		_idle_time = 0.0
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT and _route() in ["hud", "hud_coop"]:
		if not _reload_active:
			var ammo = int(_state_get("raid_ammo", 24))
			if ammo > 0:
				_state_set("raid_ammo", ammo - 1)
				_shot_time = 0.3
				build()
				_crosshair.kill = (ammo - 1) % 3 == 0
		viewport.set_input_as_handled()
		return
	if not event is InputEventKey:
		return
	var key_event: InputEventKey = event as InputEventKey
	if not key_event.pressed or key_event.echo:
		return
	var route: String = _route()
	if key_event.keycode == KEY_H and route.begins_with("hud"):
		_low_health = not _low_health
		_state_set("raid_low_health", _low_health)
		build()
		viewport.set_input_as_handled()
	elif key_event.keycode == KEY_R and route.begins_with("hud"):
		_reload_active = true
		_reload_progress = 0.0
		_state_set("raid_reloading", _reload_active)
		build()
		viewport.set_input_as_handled()
	elif key_event.keycode == KEY_X and route.begins_with("hud"):
		_navigate("summary_squad" if route == "hud_coop" else "summary_solo")
		viewport.set_input_as_handled()
	elif key_event.keycode == KEY_Y and route.begins_with("hud"):
		_state_set("raid_low_health", false)
		build()
		_toast("Quick heal · bandage applied")
		viewport.set_input_as_handled()
	elif key_event.keycode == KEY_ESCAPE and route.begins_with("summary"):
		_navigate("bunker")
		viewport.set_input_as_handled()


func _sync_mock_state() -> void:
	_low_health = bool(_state_get("raid_low_health", false))
	_reload_active = bool(_state_get("raid_reloading", false))
	_ready_squad = bool(_state_get("squad_ready", false))


func _route() -> String:
	var main: ZUIContext = _main()
	if main != null:
		var current: Variant = main.get("current_route")
		if current != null and str(current) != "":
			return str(current)
	var scene_route: Variant = get_meta("screen_route", "hud")
	if scene_route != null and str(scene_route) != "":
		return str(scene_route)
	return "hud"


func _main() -> ZUIContext:
	return app


func _state_get(key: String, fallback: Variant) -> Variant:
	var main: ZUIContext = _main()
	if main == null:
		return fallback
	var value: Variant = main.get("state")
	if value is Dictionary:
		return (value as Dictionary).get(key, fallback)
	return fallback


func _state_set(key: String, value: Variant) -> void:
	var main: ZUIContext = _main()
	if main == null:
		return
	var state_value: Variant = main.get("state")
	if state_value is Dictionary:
		(state_value as Dictionary)[key] = value


func _setting_bool(key: String, fallback: bool) -> bool:
	var value: Variant = _state_get(key, fallback)
	if value is bool:
		return bool(value)
	return fallback


func _setting_string(key: String, fallback: String) -> String:
	var value: Variant = _state_get(key, fallback)
	return str(value) if value != null else fallback


func _navigate(route: String) -> void:
	var main: ZUIContext = _main()
	if main != null and main.has_method("navigate"):
		main.call("navigate", route)


func _style(fill: Color, border: Color = Color.TRANSPARENT, width: int = 0) -> StyleBox:
	var result: StyleBoxFlat = StyleBoxFlat.new()
	result.bg_color = fill
	result.border_color = border
	result.border_width_left = width
	result.border_width_top = width
	result.border_width_right = width
	result.border_width_bottom = width
	result.corner_radius_top_left = 0
	result.corner_radius_top_right = 0
	result.corner_radius_bottom_left = 0
	result.corner_radius_bottom_right = 0
	return U.scale_safe(result)


func _color(parent: Node, rect: Rect2, color: Color, ignore: bool = true) -> ColorRect:
	var shape: ColorRect = ColorRect.new()
	shape.position = rect.position
	shape.size = rect.size
	shape.color = color
	shape.mouse_filter = Control.MOUSE_FILTER_IGNORE if ignore else Control.MOUSE_FILTER_PASS
	parent.add_child(shape)
	return shape


func _set_semibold(label: Label, mono: bool = false, spacing: int = 2) -> void:
	label.add_theme_font_override("font", KIT.tracked_font(mono, true, spacing))


func _button(parent: Node, caption: String, rect: Rect2, callback: Callable, primary: bool = false) -> Button:
	var button: Button = Button.new()
	button.position = rect.position
	button.size = rect.size
	button.text = caption
	button.focus_mode = Control.FOCUS_ALL
	button.add_theme_font_size_override("font_size", 12)
	button.add_theme_font_override("font", KIT.tracked_font(false, true, 2))
	button.add_theme_color_override("font_color", BG if primary else SOFT)
	button.add_theme_color_override("font_hover_color", BG if primary else TEXT)
	button.add_theme_color_override("font_pressed_color", BG)
	button.add_theme_stylebox_override("normal", _style(ORANGE if primary else Color(0.0, 0.0, 0.0, 0.0), ORANGE if primary else Color(1.0, 1.0, 1.0, 0.20), 1))
	button.add_theme_stylebox_override("hover", _style(HOVER_ORANGE if primary else Color(1.0, 1.0, 1.0, 0.04), HOVER_ORANGE if primary else TEXT, 1))
	button.add_theme_stylebox_override("pressed", _style(ORANGE if primary else Color(1.0, 1.0, 1.0, 0.10), ORANGE, 1))
	button.add_theme_stylebox_override("focus", _style(Color(0.0, 0.0, 0.0, 0.0), ORANGE, 1))
	button.tooltip_text = caption
	if callback.is_valid():
		button.pressed.connect(callback)
	parent.add_child(button)
	return button


func _rule(parent: Node, x: float, y: float, width: float, color: Color = LINE) -> void:
	_color(parent, Rect2(x, y, width, 1), color)


func _on_task() -> void:
	_navigate("tasks")


func _on_reinsure() -> void:
	var main = _main()
	main.confirm("Re-insure loadout", "Re-insure this sample loadout for $ 340?", func():
		_state_set("raid_loadout_insured", true)
		_toast("Loadout re-insured · local preview")
		build())


func _on_back_bunker() -> void:
	_navigate("bunker")


func _on_my_details() -> void:
	_navigate("summary_solo")


func _on_share_loot() -> void:
	var main = _main()
	main.confirm("Share loot with OYO_TRPLE", "Send the sample bandage and 30 rounds from your take to OYO_TRPLE?", func():
		_state_set("raid_loot_shared", true)
		_toast("Bandage and 30 rounds shared with OYO_TRPLE · local preview")
		build())


func _on_squad_ready() -> void:
	_ready_squad = not _ready_squad
	_ready_elapsed = 0.0
	_state_set("squad_ready", _ready_squad)
	if _ready_squad:
		_toast("Ready · waiting for squad")
	build()


func _toast(message: String) -> void:
	var main: ZUIContext = _main()
	if main != null and main.has_method("toast"):
		main.call("toast", message)
