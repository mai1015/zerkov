extends "res://ui/screens/bunker/bunker_actions.gd"

## Desktop bunker controller.
##
## The authored station layout this used to drive was a placeholder backdrop
## that bunker_hideout_screen replaced and then hid on every entry. Both the
## nodes and the code that styled them are gone; the production hideout view is
## the bunker. What remains is route state, scale-safe styles for the chrome
## that is still authored, and the compact reflow for the other bunker routes.

func build() -> void:
	reset_adaptive_layout()
	_bind_top_chrome()
	_route = str(app.current_route)
	if _route.is_empty():
		_route = "bunker"
	_ensure_state()
	if app.fixture_has("bunker_selected_station"):
		_selected_station = clampi(int(app.fixture_get("bunker_selected_station", _selected_station)), 1, 6)
	_install_scale_safe_styles()
	queue_adaptive_layout()


func _install_scale_safe_styles() -> void:
	for node in find_children("*", "Control", true, false):
		var control := node as Control
		if control is Panel:
			_wrap_style_override(control, "panel")
		elif control is Button:
			for style_name in ["normal", "hover", "pressed", "focus", "disabled"]:
				_wrap_style_override(control, style_name)


func _wrap_style_override(control: Control, style_name: StringName) -> void:
	if not control.has_theme_stylebox_override(style_name):
		return
	var style := control.get_theme_stylebox(style_name)
	if style is StyleBoxFlat:
		control.add_theme_stylebox_override(style_name, U.scale_safe(style))
