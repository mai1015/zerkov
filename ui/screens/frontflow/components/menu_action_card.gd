@tool
class_name ZMenuActionCard
extends Panel

## Reusable main-menu action row.
##
## The scene owns the shared geometry, typography, accent, and hit target. The
## exported values keep each menu entry configurable at its instance site,
## while the screen controller can still update the first row for world state.

const ACTIVE_TITLE_COLOR := Color(0.901961, 0.909804, 0.890196, 1)
const INACTIVE_TITLE_COLOR := Color(0.717647, 0.737255, 0.705882, 1)

signal activated

@export var card_title: String = "CONTINUE":
	set(value):
		card_title = value
		_sync()
@export_multiline var card_subtitle: String = "OAK'S BUNKER · Bunker LVL 3 · LVL 14 · 2 h ago":
	set(value):
		card_subtitle = value
		_sync()
@export var active_accent: bool = false:
	set(value):
		active_accent = value
		_sync()
@export var disabled: bool = false:
	set(value):
		disabled = value
		_sync()
@export var active_accent_style: StyleBox
@export var inactive_accent_style: StyleBox


func _ready() -> void:
	_sync()
	resized.connect(_layout)
	_layout()
	if not Engine.is_editor_hint():
		$Hit.triggered.connect(func() -> void: activated.emit())
		$Hit.focus_entered.connect(_sync)
		$Hit.focus_exited.connect(_sync)
		ZThemeAdapter.apply_controls(self)

func get_focus_target() -> Button:
	return $Hit

func _sync() -> void:
	if get_node_or_null("Hit") == null:
		return
	$Title.text = card_title
	$Subtitle.text = card_subtitle
	$Hit.disabled = disabled
	$Title.add_theme_color_override(
		"font_color", Color("8b918a") if disabled else (ACTIVE_TITLE_COLOR if active_accent or $Hit.has_focus() else INACTIVE_TITLE_COLOR)
	)
	$Accent.set_meta("active_accent", active_accent)
	var accent_style: StyleBox = active_accent_style if active_accent else inactive_accent_style
	if accent_style != null:
		$Accent.add_theme_stylebox_override("panel", accent_style)

func _layout() -> void:
	$Hit.size = size
	$Title.size.x = maxf(0, size.x - $Title.position.x - 6)
	$Subtitle.size.x = maxf(0, size.x - $Subtitle.position.x - 6)
