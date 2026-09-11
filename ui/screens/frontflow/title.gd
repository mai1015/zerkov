extends "res://ui/screens/frontflow/frontflow_actions.gd"

## Authored title-screen controller.
##
## The complete desktop composition lives in title.tscn. This script keeps the
## inherited compact layout and shared title route behavior while avoiding the
## legacy runtime builder in frontflow.gd.

func build() -> void:
	reset_adaptive_layout()
	active_route = str(app.current_route)
	_install_scale_safe_styles()
	queue_adaptive_layout()


func _on_activated() -> void:
	super._on_activated()
	register_action(CommonUIDefaults.CONFIRM, _on_common_ui_continue)


func _on_common_ui_continue(event: Dictionary) -> int:
	if event.get("phase", -1) != CommonUIRuntime.PHASE_PRESSED:
		return CommonUIRuntime.ROUTE_UNHANDLED
	app.navigate("main_menu")
	return CommonUIRuntime.ROUTE_HANDLED


func _install_scale_safe_styles() -> void:
	for node in find_children("*", "Control", true, false):
		var control := node as Control
		if control is Panel:
			_wrap_style_override(control, "panel")


func _wrap_style_override(control: Control, style_name: StringName) -> void:
	if not control.has_theme_stylebox_override(style_name):
		return
	var style := control.get_theme_stylebox(style_name)
	if style is StyleBoxFlat:
		control.add_theme_stylebox_override(style_name, U.scale_safe(style))
