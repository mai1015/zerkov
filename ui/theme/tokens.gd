class_name ZKit
extends RefCounted

const PixelStyle = preload("res://ui/theme/pixel_style.gd")
const ZerkovButtonScene = preload("res://ui/components/controls/zerkov_button.tscn")
const ThemeAdapter = preload("res://ui/theme/theme_adapter.gd")
const AuthoredTheme = preload("res://ui/theme/zerkov_theme.tres")

const BG = Color("0a0b0a")
const PANEL = Color("0e100f")
const CANVAS = Color("141414")
const DARK = Color(0.027, 0.035, 0.035, 0.85)
const TEXT = Color("e6e8e3")
const MUTED = Color("8b918a")
const SOFT = Color("b7bcb4")
const BORDER = Color("2a2a2a")
const LINE = Color(1, 1, 1, 0.12)
const SUBTLE = Color(1, 1, 1, 0.08)
const ACCENT = Color("e8962e")
const HOVER = Color("f2b15a")
const GREEN = Color("5fd36b")
const RED = Color("d9483b")
const YELLOW = Color("e9d35a")
const BLUE = Color("4c8dff")

static var shared_theme: Theme
static var fonts: Dictionary = {}

static func font(mono: bool = false, bold: bool = false) -> Font:
	var filename = ("IBMPlexMono-" if mono else "ChakraPetch-") + ("SemiBold.ttf" if bold else "Regular.ttf")
	if not fonts.has(filename):
		var path = "res://assets/fonts/" + filename
		fonts[filename] = load(path) if ResourceLoader.exists(path) else ThemeDB.fallback_font
	return fonts[filename]

static func tracked_font(mono: bool = false, bold: bool = true, spacing: int = 2) -> FontVariation:
	var key = "tracked_%s_%s_%s" % [mono, bold, spacing]
	if not fonts.has(key):
		var variation = FontVariation.new()
		variation.base_font = font(mono, bold)
		variation.spacing_glyph = spacing
		fonts[key] = variation
	return fonts[key]

static func scale_safe(source: StyleBoxFlat) -> StyleBox:
	return ThemeAdapter.scale_safe(source)

static func style(color: Color, border: Color = Color.TRANSPARENT, width: int = 1) -> StyleBox:
	var s = StyleBoxFlat.new()
	s.bg_color = color
	s.border_color = border
	s.set_border_width_all(width)
	s.content_margin_left = 12
	s.content_margin_right = 12
	s.content_margin_top = 4
	s.content_margin_bottom = 4
	return scale_safe(s)

static func make_theme() -> Theme:
	return ThemeAdapter.adapt_theme(AuthoredTheme)

static func place(control: Control, bounds: Rect2) -> void:
	control.position = bounds.position
	control.size = bounds.size

static func label(parent: Node, content: String, bounds: Rect2, font_size: int = 14, color: Color = TEXT, mono: bool = false) -> Label:
	var node = Label.new()
	node.text = content
	node.add_theme_font_override("font", font(mono))
	node.add_theme_font_size_override("font_size", font_size)
	node.add_theme_color_override("font_color", color)
	node.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	place(node, bounds)
	parent.add_child(node)
	return node

static func button(parent: Node, content: String, bounds: Rect2, callback: Callable, primary: bool = false) -> Button:
	var node := ZerkovButtonScene.instantiate() as ZerkovButton
	node.text = content
	node.variant = "primary" if primary else "secondary"
	place(node, bounds)
	if callback.is_valid():
		node.triggered.connect(callback)
	parent.add_child(node)
	return node
