@tool
class_name ZThemeAdapter
extends RefCounted

const PixelStyle = preload("res://ui/theme/pixel_style.gd")
static var _themes: Dictionary = {}

static func scale_safe(source: StyleBox) -> StyleBox:
	if not source is StyleBoxFlat or source.border_color.a <= 0.0 or Engine.is_editor_hint():
		return source
	var adapted := PixelStyle.new()
	adapted.configure(source)
	return adapted

static func adapt_theme(source: Theme) -> Theme:
	if source == null or Engine.is_editor_hint():
		return source
	if not _themes.has(source):
		var result := source.duplicate() as Theme
		for type in result.get_type_list():
			for item in result.get_stylebox_list(type):
				result.set_stylebox(item, type, scale_safe(result.get_stylebox(item, type)))
		_themes[source] = result
	return _themes[source]

static func apply_controls(root: Control) -> void:
	adapt_control(root)
	for node in root.find_children("*", "Control", true, false):
		adapt_control(node)

static func adapt_control(control: Control) -> void:
	for item in [&"panel", &"normal", &"hover", &"pressed", &"focus", &"disabled", &"read_only", &"background", &"fill"]:
		if control.has_theme_stylebox_override(item):
			control.add_theme_stylebox_override(item, scale_safe(control.get_theme_stylebox(item)))
