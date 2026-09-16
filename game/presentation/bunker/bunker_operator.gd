class_name ZBunkerOperator
extends Node2D
## The player walking inside the bunker's 640x360 world.
##
## Presentation only. The bunker runs no raid authority, so nothing here moves
## authority-owned state, and the walk is not a raid actor: it exists so the
## hideout can be entered instead of only inspected.

const MANIFEST_PATH := "res://game/content/art/local_player_manifest.json"
## World pixels per second. The bunker is 640x360, so this crosses a room in
## roughly two seconds at the authored 3x output scale.
const SPEED: float = 42.0
const SECONDS_PER_FRAME: float = 0.12

var _presenter: ZLayeredPlayerPresenter
var _world: ZBunkerHideoutWorld
var _clip_frames: Dictionary = {}
var _face_left: bool = false
var _elapsed: float = 0.0
var _frame: int = 0
var _sequence: int = 0
var _state: String = "idle"

func configure(world: ZBunkerHideoutWorld, at: Vector2) -> bool:
	if world == null or _presenter != null:
		return false
	var value: Variant = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST_PATH))
	if not value is Dictionary:
		return false
	var manifest: Dictionary = value
	var textures: Dictionary = {}
	for key: String in manifest["sources"]:
		var source: Dictionary = manifest["sources"][key]
		# Same provenance check the raid performs before showing this artwork.
		if FileAccess.get_sha256(source["path"]) != source["sha256"]:
			return false
		var texture := load(source["path"]) as Texture2D
		if texture == null:
			return false
		textures[key] = texture
	for name: String in manifest["clips"]:
		_clip_frames[name] = int(manifest["clips"][name]["frame_count"])
	if not _clip_frames.has("idle") or not _clip_frames.has("walk"):
		return false
	_presenter = ZLayeredPlayerPresenter.new()
	add_child(_presenter)
	if not _presenter.configure(manifest, textures, 1):
		return false
	_world = world
	position = at
	return _publish()


## Walk one frame. Blocked axes are tested separately so a wall on one of them
## does not cancel motion along the other and leave the player stuck on a corner.
func walk(direction: Vector2, delta: float) -> void:
	if _world == null or _presenter == null:
		return
	var moving := not direction.is_zero_approx()
	if moving:
		if absf(direction.x) > 0.01:
			_face_left = direction.x < 0.0
		var motion := direction.normalized() * SPEED * delta
		if _world.is_walkable(position + Vector2(motion.x, 0.0)):
			position.x += motion.x
		if _world.is_walkable(position + Vector2(0.0, motion.y)):
			position.y += motion.y
	var state := "walk" if moving else "idle"
	if state != _state:
		_state = state
		_frame = 0
		_elapsed = 0.0
	_elapsed += delta
	while _elapsed >= SECONDS_PER_FRAME:
		_elapsed -= SECONDS_PER_FRAME
		_frame = (_frame + 1) % int(_clip_frames[_state])
	# Sorted against the props by feet, so a doorway or bench overlaps correctly.
	z_index = int(position.y)
	_publish()


func _publish() -> bool:
	_sequence += 1
	return _presenter.present({
		"generation": 1,
		"tick": _sequence,
		"sequence": _sequence,
		"frame": _frame,
		"state": _state,
	}, _face_left)


func release() -> void:
	if _presenter != null:
		_presenter.release()
