extends "res://ui/screens/raid/raid_screen.gd"

## Authored squad-summary screen controller.
##
## The summary surface is authored in summary_squad.tscn. This controller
## binds stateful readiness/share controls and preserves raid.gd's compact
## section layout and countdown behavior.

func build() -> void:
	var layout_was_applied: bool = _adaptive_applied
	if not layout_was_applied:
		reset_adaptive_layout()
	if _squad_started < 0:
		_squad_started = Time.get_ticks_msec() / 1000.0
	_sync_mock_state()
	_ring_nodes.clear()
	_blink_nodes.clear()
	_fade_groups.clear()
	_crosshair = null
	_squad_countdown = find_child("SquadCountdown", true, false) as Label
	_bind_summary_state()
	_sync_summary_tabs()
	_wire_summary_actions()
	if not layout_was_applied:
		queue_adaptive_layout()

func _bind_summary_state() -> void:
	if _squad_countdown != null:
		var remaining: int = maxi(0, 42 - int((Time.get_ticks_msec() / 1000.0) - _squad_started))
		_squad_countdown.text = "Everyone's loot went to their own stash  |  Squad continues when all are READY · %d / 3 · 00:%02d auto" % [3 if _ready_squad else 2, remaining]

	var ready_badge: Panel = find_child("OakReadyBadge", true, false) as Panel
	var ready_label: Label = find_child("OakReadyStatus", true, false) as Label
	if ready_badge != null and ready_label != null:
		var state_color: Color = GREEN if _ready_squad else MUTED
		ready_badge.position = Vector2(370, 27) if _ready_squad else Vector2(344, 27)
		ready_badge.size = Vector2(54, 20) if _ready_squad else Vector2(80, 20)
		ready_badge.add_theme_stylebox_override("panel", _style(Color.TRANSPARENT, state_color, 1))
		ready_label.size = ready_badge.size
		ready_label.text = "READY" if _ready_squad else "REVIEWING"
		ready_label.add_theme_color_override("font_color", state_color)

	var share: Button = find_child("ShareLootButton", true, false) as Button
	if share != null:
		var shared: bool = bool(_state_get("raid_loot_shared", false))
		share.text = "LOOT SHARED" if shared else "SHARE LOOT"
		share.tooltip_text = share.text
		share.disabled = shared
		mark_feature_action(share, FEATURE_FRIENDS)

	var ready: Button = find_child("ReadyButton", true, false) as Button
	if ready != null:
		ready.text = "READY · BACK TO BUNKER" if _ready_squad else "ENTER   READY · BACK TO BUNKER"
		ready.tooltip_text = ready.text
		mark_feature_action(ready, FEATURE_FRIENDS)

func _wire_summary_actions() -> void:
	var my_details: Button = find_child("MyDetailsButton", true, false) as Button
	var share: Button = find_child("ShareLootButton", true, false) as Button
	var ready: Button = find_child("ReadyButton", true, false) as Button
	var details_callback := Callable(self, "_on_my_details")
	var share_callback := Callable(self, "_on_share_loot")
	var ready_callback := Callable(self, "_on_squad_ready")
	if my_details != null and not my_details.pressed.is_connected(details_callback):
		my_details.pressed.connect(details_callback)
	if share != null and not share.pressed.is_connected(share_callback):
		share.pressed.connect(share_callback)
	if ready != null and not ready.pressed.is_connected(ready_callback):
		ready.pressed.connect(ready_callback)

func _sync_summary_tabs() -> void:
	var active: int = clampi(int(_state_get("compact_summary_squad_tab", 0)), 0, 2)
	for index in range(3):
		var pane: ScrollContainer = get_node_or_null("RaidSummary%d" % index) as ScrollContainer
		if pane != null:
			pane.follow_focus = true
			pane.visible = index == active
		var tab: Button = get_node_or_null("RaidSummaryTab%d" % index) as Button
		if tab == null:
			continue
		var primary: bool = index == active
		tab.add_theme_color_override("font_color", BG if primary else SOFT)
		tab.add_theme_color_override("font_hover_color", BG if primary else TEXT)
		tab.add_theme_color_override("font_pressed_color", BG)
		tab.add_theme_stylebox_override("normal", _style(ORANGE if primary else Color.TRANSPARENT, ORANGE if primary else Color(1.0, 1.0, 1.0, 0.20), 1))
		tab.add_theme_stylebox_override("hover", _style(HOVER_ORANGE if primary else Color(1.0, 1.0, 1.0, 0.04), HOVER_ORANGE if primary else TEXT, 1))
		tab.add_theme_stylebox_override("pressed", _style(ORANGE if primary else Color(1.0, 1.0, 1.0, 0.10), ORANGE, 1))
		tab.add_theme_stylebox_override("focus", _style(Color.TRANSPARENT, ORANGE, 1))
