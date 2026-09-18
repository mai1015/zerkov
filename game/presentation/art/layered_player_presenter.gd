class_name ZLayeredPlayerPresenter
extends Node2D
## A bounded set of Sprite2D layers. Input is a detached compiled art manifest
## and ZPlayerAnimationState snapshot, never a live authority/domain handle.
## Configure explicitly; missing sources leave the previous binding unchanged.
## This node has no process callback and never advances simulation or animation.

const MAX_LAYERS: int = 8
const MAX_FRAMES: int = 128
var _clips: Dictionary = {}
var _sources: Dictionary = {}
var _textures: Dictionary = {}
var _layers: Array[Sprite2D] = []
var _generation: int = 0
var _tick: int = -1
var _sequence: int = -1
var _binding: bool = false


func configure(manifest: Dictionary, textures: Dictionary, generation: int) -> bool:
	if _binding or generation <= _generation or generation > 2147483647:
		return false
	if not manifest.get("clips") is Dictionary or not manifest.get("sources") is Dictionary:
		return false
	if not _whole(manifest.get("schema_version"), 1, 1) or manifest["sources"].size() > 128:
		return false
	var clips: Dictionary = manifest["clips"].duplicate(true)
	var sources: Dictionary = manifest["sources"].duplicate(true)
	if clips.is_empty() or clips.size() > 5:
		return false
	var selected: Dictionary = {}
	for clip_name: Variant in clips:
		if not clip_name is String or clip_name not in ["idle", "walk", "attack", "grenade", "death"] or not clips[clip_name] is Dictionary:
			return false
		var clip: Dictionary = clips[clip_name]
		if not clip.get("layers") is Array or not _pair(clip.get("pivot"), false):
			return false
		var ids: Array = clip["layers"]
		if ids.is_empty() or ids.size() > MAX_LAYERS:
			return false
		var seen: Dictionary = {}
		var count: int = -1
		var frame_size := Vector2i.ZERO
		for id: Variant in ids:
			if not id is String or seen.has(id) or not sources.get(id) is Dictionary:
				return false
			seen[id] = true
			var source: Dictionary = sources[id]
			if not source.get("filter") is String or source["filter"] != "nearest" or not textures.get(id) is Texture2D:
				return false
			var texture: Texture2D = textures[id]
			if not source.get("regions") is Array:
				return false
			var regions: Array = source["regions"]
			if regions.is_empty() or regions.size() > MAX_FRAMES or (count >= 0 and count != regions.size()):
				return false
			count = regions.size()
			for region: Variant in regions:
				if not region is Dictionary or not region.get("rect") is Array:
					return false
				var rect: Array = region["rect"]
				if rect.size() != 4:
					return false
				for component: Variant in rect:
					if not _whole(component, 0, 4096):
						return false
				if rect[2] <= 0 or rect[3] <= 0 or rect[0] + rect[2] > texture.get_width() or rect[1] + rect[3] > texture.get_height():
					return false
				var dimensions := Vector2i(int(rect[2]), int(rect[3]))
				if frame_size != Vector2i.ZERO and frame_size != dimensions:
					return false
				frame_size = dimensions
				if clip["pivot"][0] > rect[2] or clip["pivot"][1] > rect[3]:
					return false
			selected[id] = texture
		if not _whole(clip.get("frame_count"), 1, MAX_FRAMES) or int(clip["frame_count"]) != count:
			return false
	_binding = true
	# Fixed pool: never create sprites while sampling a frame.
	if _layers.is_empty():
		for index: int in range(MAX_LAYERS):
			var sprite := Sprite2D.new()
			sprite.name = "ArtLayer%d" % index
			sprite.centered = false
			sprite.region_enabled = true
			sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
			sprite.visible = false
			_layers.append(sprite)
			add_child(sprite)
	_clips = clips
	_sources = sources
	_textures = selected
	_generation = generation
	_tick = -1
	_sequence = -1
	for sprite: Sprite2D in _layers:
		sprite.visible = false
		sprite.texture = null
	_binding = false
	return true


func present(sample: Dictionary, face_left: bool = false, hidden_sources: PackedStringArray = PackedStringArray()) -> bool:
	if _binding or _clips.is_empty():
		return false
	for field: String in ["generation", "tick", "sequence", "frame"]:
		if typeof(sample.get(field)) != TYPE_INT:
			return false
	if sample["generation"] != _generation:
		return false
	if not _whole(sample["tick"], 0, 2147483647) or not _whole(sample["sequence"], 0, 2147483647):
		return false
	if sample["tick"] < _tick or sample["sequence"] < _sequence:
		return false
	var clip_name: Variant = sample.get("state")
	if not clip_name is String or not _clips.has(clip_name):
		return false
	var clip: Dictionary = _clips[clip_name]
	var frame: int = sample["frame"]
	if frame < 0 or frame >= int(clip["frame_count"]):
		return false
	for id: String in hidden_sources:
		if not _sources.has(id): return false
	var ids: Array = clip["layers"]
	for i: int in range(_layers.size()):
		var sprite: Sprite2D = _layers[i]
		sprite.visible = i < ids.size() and not hidden_sources.has(ids[i])
		if not sprite.visible:
			continue
		var id: String = ids[i]
		var rect: Array = _sources[id]["regions"][frame]["rect"]
		sprite.texture = _textures[id]
		sprite.region_rect = Rect2(rect[0], rect[1], rect[2], rect[3])
		var pivot: Array = clip["pivot"]
		sprite.position = Vector2(-pivot[0], -pivot[1])
		sprite.scale.x = -1.0 if face_left else 1.0
		if face_left:
			sprite.position.x = float(pivot[0])
	_tick = sample["tick"]
	_sequence = sample["sequence"]
	return true


func release() -> void:
	if _binding:
		return
	_clips.clear()
	_sources.clear()
	_textures.clear()
	for sprite: Sprite2D in _layers:
		sprite.visible = false
		sprite.texture = null


static func _whole(value: Variant, minimum: int, maximum: int) -> bool:
	if typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT:
		return false
	return is_finite(float(value)) and float(value) == floor(float(value)) and value >= minimum and value <= maximum


static func _pair(value: Variant, positive: bool) -> bool:
	if not value is Array or value.size() != 2:
		return false
	return _whole(value[0], 1 if positive else 0, 4096) and _whole(value[1], 1 if positive else 0, 4096)
