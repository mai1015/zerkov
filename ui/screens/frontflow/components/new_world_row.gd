@tool
class_name ZNewWorldRow
extends Panel

signal activated

@export var disabled: bool = false:
	set(value):
		disabled = value
		if get_node_or_null("Hit") != null: $Hit.disabled = value

func _ready() -> void:
	$Hit.disabled = disabled
	resized.connect(_layout)
	_layout()
	if not Engine.is_editor_hint():
		$Hit.triggered.connect(func() -> void: activated.emit())
		ZThemeAdapter.apply_controls(self)

func get_focus_target() -> Button:
	return $Hit

func _layout() -> void:
	$Hit.size = size
	$Label.size.x = size.x
