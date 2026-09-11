extends "res://ui/screens/raid/raid_screen.gd"

## Authored solo-summary controller.
##
## The desktop results surface is authored in summary_solo.tscn.  This script
## keeps the insurance state and the three summary actions live while retaining
## raid.gd's compact summary layout and focus behavior.

func build() -> void:
	var layout_was_applied := _adaptive_applied
	reset_adaptive_layout()
	_sync_mock_state()
	if get_node_or_null("MetricLoot") == null:
		if _layout_snapshot != null: _layout_snapshot.restore(self)
	_install_valid_styles()
	_bind_dynamic_state()
	_wire_actions()
	queue_adaptive_layout()
	# A compact tab change retains content and reflows its temporary hosts.
	# Restore the default if the previously focused tab is no longer eligible.
	if layout_was_applied and is_routing_active():
		call_deferred("restore_focus")


func _bind_dynamic_state() -> void:
	var insured: bool = bool(_state_get("raid_loadout_insured", false))
	var insurance: Button = get_node("Reinsure") as Button
	insurance.text = "LOADOUT INSURED" if insured else "RE-INSURE LOADOUT · $ 340"
	insurance.disabled = insured
	mark_feature_action(insurance, FEATURE_INSURANCE)


func _install_valid_styles() -> void:
	var dark_panel := Color(0.027, 0.035, 0.035, 0.72)
	var light_border := Color(1.0, 1.0, 1.0, 0.14)
	for metric in ["MetricLoot", "MetricXP", "MetricKills", "MetricDamage"]:
		_set_panel_style(get_node(metric) as Panel, dark_panel, light_border)
	for index in range(9):
		_set_panel_style(get_node("LootItem%02d" % index) as Panel, Color(1.0, 1.0, 1.0, 0.04), light_border)
	for index in range(2):
		_set_panel_style(get_node("LootBadge%02d" % index) as Panel, Color.TRANSPARENT, ORANGE)
	for index in range(2):
		_set_panel_style(get_node("UsedItem%02d" % index) as Panel, Color(1.0, 1.0, 1.0, 0.04), light_border)
	_set_panel_style(get_node("XPPanel") as Panel, dark_panel, light_border)
	for skill in ["Endurance", "Vitality", "Attention"]:
		_set_panel_style(get_node("Skill" + skill) as Panel, dark_panel, light_border)
	_set_panel_style(get_node("TaskPanel") as Panel, Color(0.90, 0.58, 0.18, 0.08), Color(0.90, 0.58, 0.18, 0.50))
	_set_panel_style(get_node("HealthPanel") as Panel, dark_panel, light_border)
	_set_summary_button(get_node("TurnInTask") as Button, false)
	_set_summary_button(get_node("Reinsure") as Button, false)
	_set_summary_button(get_node("BackBunker") as Button, true)


func _set_panel_style(panel: Panel, fill: Color, border: Color) -> void:
	if panel != null:
		panel.add_theme_stylebox_override("panel", _style(fill, border, 1))


func _set_summary_button(button: Button, primary: bool) -> void:
	if button == null:
		return
	button.add_theme_color_override("font_color", BG if primary else SOFT)
	button.add_theme_color_override("font_hover_color", BG if primary else TEXT)
	button.add_theme_color_override("font_pressed_color", BG)
	button.add_theme_stylebox_override("normal", _style(ORANGE if primary else Color.TRANSPARENT, ORANGE if primary else Color(1.0, 1.0, 1.0, 0.20), 1))
	button.add_theme_stylebox_override("hover", _style(HOVER_ORANGE if primary else Color(1.0, 1.0, 1.0, 0.04), HOVER_ORANGE if primary else TEXT, 1))
	button.add_theme_stylebox_override("pressed", _style(ORANGE if primary else Color(1.0, 1.0, 1.0, 0.10), ORANGE, 1))
	button.add_theme_stylebox_override("focus", _style(Color.TRANSPARENT, ORANGE, 1))


func _wire_actions() -> void:
	_wire_button(get_node("TurnInTask") as Button, Callable(self, "_on_task"))
	_wire_button(get_node("Reinsure") as Button, Callable(self, "_on_reinsure"))
	_wire_button(get_node("BackBunker") as Button, Callable(self, "_on_back_bunker"))


func _wire_button(button: Button, callback: Callable) -> void:
	if button == null or not callback.is_valid():
		return
	if not button.pressed.is_connected(callback):
		button.pressed.connect(callback)
