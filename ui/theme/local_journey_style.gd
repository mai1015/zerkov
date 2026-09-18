class_name LocalJourneyStyle
extends RefCounted
## Shared styling only. No route, inventory or gameplay ownership.
const BG := Color("0c100d")
const PANEL := Color("151b15")
const LINE := Color("374136")
const TEXT := Color("e4e7dd")
const MUTED := Color("97a091")
const ACCENT := Color("c4ad79")
const DANGER := Color("db8976")
const BOLD = preload("res://assets/fonts/ChakraPetch-SemiBold.ttf")
const MONO = preload("res://assets/fonts/IBMPlexMono-Regular.ttf")

static func panel(fill: Color = PANEL, border: Color = LINE) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.border_color = border
	style.set_border_width_all(1)
	style.content_margin_left = 12
	style.content_margin_right = 12
	return style

static func button(control: Button, primary: bool = false) -> void:
	control.add_theme_font_override("font", MONO)
	control.add_theme_font_size_override("font_size", 14)
	control.add_theme_stylebox_override("normal", panel(ACCENT if primary else PANEL, ACCENT if primary else LINE))
	control.add_theme_stylebox_override("hover", panel(Color("dfba83") if primary else Color("29332f"), ACCENT))
	control.add_theme_stylebox_override("pressed", panel(Color("b78a50") if primary else Color("343b2f"), ACCENT))
	control.add_theme_stylebox_override("disabled", panel(Color("131a1b")))
	var focus := panel(Color.TRANSPARENT, TEXT)
	focus.set_border_width_all(2)
	control.add_theme_stylebox_override("focus", focus)
	for key: String in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		control.add_theme_color_override(key, BG if primary else TEXT)
	control.add_theme_color_override("font_disabled_color", MUTED)

static func apply_screen(root: Control) -> void:
	for node: Node in root.find_children("*", "Control", true, false):
		if node.get_parent().has_method("configure_local_sections"): continue
		if node is Panel:
			var name := String(node.name)
			if name.contains("Panel") or name.contains("Card") or name in ["Header", "BackdropBase", "BackgroundBase", "RegionCanvas", "ZoneDetailsBackdrop"]:
				node.add_theme_stylebox_override("panel", panel(BG if name == "BackdropBase" else PANEL))
		elif node is Button and not node.text.is_empty():
			button(node, String(node.name) in ["Deploy", "BackBunker"])
		elif node is Label:
			var old: Color = node.get_theme_color("font_color")
			if old.r > 0.65 and old.g > 0.38 and old.g < 0.78 and old.b < 0.4:
				node.add_theme_color_override("font_color", ACCENT)

## Global sections are tabs, not boxed page actions. Keep focus independently
## visible without making an unselected focused section look selected.
static func section_button(control: Button, selected: bool) -> void:
	control.add_theme_font_override("font", BOLD)
	control.add_theme_font_size_override("font_size", 16)
	for state: String in ["normal", "hover", "pressed", "disabled"]:
		var fill := Color(0.77, 0.68, 0.47, 0.07) if selected else Color.TRANSPARENT
		if state in ["hover", "pressed"]: fill = Color(0.77, 0.68, 0.47, 0.13)
		var style := panel(fill, ACCENT if selected else Color.TRANSPARENT)
		style.set_border_width_all(0)
		style.border_width_bottom = 2 if selected else 0
		control.add_theme_stylebox_override(state, style)
	var focus := panel(Color.TRANSPARENT, TEXT)
	focus.set_border_width_all(1)
	focus.expand_margin_left = -6
	focus.expand_margin_right = -6
	focus.expand_margin_top = -8
	focus.expand_margin_bottom = -8
	control.add_theme_stylebox_override("focus", focus)
	control.add_theme_color_override("font_color", TEXT if selected else MUTED)
	control.add_theme_color_override("font_hover_color", TEXT)
	control.add_theme_color_override("font_focus_color", TEXT)
	control.add_theme_color_override("font_pressed_color", TEXT)


static func apply_card(root: Control) -> void:
	if root is Panel: root.add_theme_stylebox_override("panel", panel())
	apply_screen(root)
	for node: Node in root.find_children("*", "ColorRect", true, false):
		if String(node.name).contains("Rule"): node.color = LINE
