class_name ZParallaxBackground
extends Panel

@export var overscan: Vector2 = Vector2(44.0, 30.0)
@export var travel: Vector2 = Vector2(24.0, 14.0)
@export_range(0.1, 20.0, 0.1) var response: float = 7.5

var _layers: Array[TextureRect] = []
var _depths: PackedFloat32Array = PackedFloat32Array()
var _offset: Vector2 = Vector2.ZERO
var _motion_enabled: bool = false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	for child in get_children():
		if child is TextureRect and child.has_meta("parallax_depth"):
			_layers.append(child)
			_depths.append(float(child.get_meta("parallax_depth")))
			child.mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(_sync_layer_bounds)
	_sync_layer_bounds()
	set_process(false)


func set_motion_enabled(enabled: bool) -> void:
	_motion_enabled = enabled
	set_process(enabled)
	if not enabled:
		_offset = Vector2.ZERO
		_apply_offset()


func _process(delta: float) -> void:
	if not _motion_enabled or size.x <= 0.0 or size.y <= 0.0:
		return
	var pointer: Vector2 = get_viewport().get_mouse_position()
	var normalized := Vector2(
		clampf(pointer.x / size.x * 2.0 - 1.0, -1.0, 1.0),
		clampf(pointer.y / size.y * 2.0 - 1.0, -1.0, 1.0)
	)
	var target := Vector2(-normalized.x * travel.x, -normalized.y * travel.y)
	var blend := 1.0 - exp(-response * delta)
	_offset = _offset.lerp(target, blend)
	_apply_offset()


func _sync_layer_bounds() -> void:
	for layer in _layers:
		layer.position = -overscan
		layer.size = size + overscan * 2.0
	_apply_offset()


func _apply_offset() -> void:
	for index in range(_layers.size()):
		if is_instance_valid(_layers[index]):
			_layers[index].position = (-overscan + _offset * _depths[index]).round()
