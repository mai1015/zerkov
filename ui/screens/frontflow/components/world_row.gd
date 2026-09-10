@tool
class_name ZWorldRow
extends Panel

signal activated(world_id: String, index: int)

@export var world: Dictionary = {}:
	set(value):
		world = value.duplicate(true)
		_sync()
@export var index: int = 0:
	set(value):
		index = value
		_sync()
@export var selected: bool = false:
	set(value):
		selected = value
		_sync()
@export var disabled: bool = false:
	set(value):
		disabled = value
		_sync()
@export var selected_style: StyleBox
@export var normal_style: StyleBox

func _ready() -> void:
	_sync()
	resized.connect(_layout)
	_layout()
	if not Engine.is_editor_hint():
		$Hit.triggered.connect(func() -> void: activated.emit(str(world.get("id", index)), index))
		ZThemeAdapter.apply_controls(self)

func get_focus_target() -> Button:
	return $Hit

func _sync() -> void:
	if get_node_or_null("Hit") == null:
		return
	$Hit.disabled = disabled
	var style := selected_style if selected else normal_style
	if style != null:
		add_theme_stylebox_override("panel", ZThemeAdapter.scale_safe(style))
	$WorldName.text = str(world.get("name", "WORLD"))
	var difficulty := str(world.get("difficulty", "STANDARD"))
	$Difficulty.text = difficulty
	$Difficulty.add_theme_color_override("font_color", Color("d9483b") if difficulty == "HARDCORE" else Color("8b918a"))
	$Details.text = "%s   Character %s    %s    Last · %s" % [world.get("bunker", "LVL 1"), world.get("character", "LVL 1"), world.get("playtime", "0 h"), world.get("last", "never")]
	var cloud := str(world.get("cloud", "synced"))
	$Cloud.text = "cloud · " + cloud
	$Cloud.add_theme_color_override("font_color", Color("5fd36b") if cloud == "synced" else Color("e9d35a"))
	$Slot.text = "slot %d" % (index + 1)

func _layout() -> void:
	$Hit.size = size
	$Details.size.x = minf(440.0, maxf(0, size.x - 340.0))

func layout_for(width: float, compact: bool) -> void:
	size.x = width
	$Cloud.position.x = width - 174.0 if compact else 1074.0
	$Slot.position.x = width - 74.0 if compact else 1198.0
