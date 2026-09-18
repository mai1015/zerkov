class_name LocalActorPresenter
extends Node2D
## Original layered body and held poses. Inputs are post-closeout value frames.
var _state := ZPlayerAnimationState.new()
var _layers := ZLayeredPlayerPresenter.new()
var _weapon: LocalWeaponPresenter
var _last_frame: Dictionary = {}
var _arm_sources := PackedStringArray()
var _sequence: int = 0
var _generation: int = 0
var _dead: bool = false
var _moving: bool = false

func configure(manifest: Dictionary, textures: Dictionary, generation: int, surfaces: Dictionary = {}) -> bool:
	if _generation != 0 or not _state.configure(manifest.get("clips", {}), generation): return false
	add_child(_layers)
	if not _layers.configure(manifest, textures, generation): return false
	for id: String in manifest.sources:
		if id.ends_with(".arms"): _arm_sources.append(id)
	_weapon = LocalWeaponPresenter.new()
	add_child(_weapon)
	if not _weapon.configure(generation, surfaces): return false
	_generation = generation
	return true

func present(pose: Vector2, velocity: Vector2, facing: Vector2, frame: Dictionary) -> bool:
	if _generation == 0 or frame.is_empty() or frame.get("generation") != _generation: return false
	if not _weapon._valid(frame) or not pose.is_finite() or not velocity.is_finite() or not facing.is_finite(): return false
	if not _last_frame.is_empty() and frame.tick <= _last_frame.tick: return frame == _last_frame
	if _dead and frame.health.alive: return false
	var tick: int = frame.tick
	if not _state.advance_to(tick): return false
	position = pose.round()
	if not _dead:
		var dead: bool = not frame.health.alive
		var moving: bool = velocity.length_squared() > 0.1
		if dead:
			if not _event("death", tick): return false
			_dead = true
		elif moving != _moving:
			_sequence += 1
			if not _state.consume({"generation":_generation,"sequence":_sequence,"tick":tick,
				"kind":"locomotion","moving":moving,"committed":true}): return false
			_moving = moving
	var sample: Dictionary = _state.snapshot().duplicate()
	# All six source body/arm frames share this one canonical melee sample.
	# Contact timing remains in the authority, never in the animation system.
	if not _dead and frame.get("melee", {}).get("phase", &"ready") != &"ready":
		sample.state = "attack"
		sample.frame = LocalWeaponPresenter.melee_frame(frame)
	sample.make_read_only()
	if not _weapon.present(pose, facing, frame, sample): return false
	var held := _weapon.snapshot()
	var hidden := _arm_sources if held.arms_overridden else PackedStringArray()
	# Both the original main-character sheets and supplied held AK face left.
	if not _layers.present(sample, not held.facing_left, hidden): return false
	_last_frame = frame
	return true

func release() -> void:
	_state.release()
	_layers.release()
	if _weapon != null: _weapon.release()
	_last_frame = {}
	_generation = 0

func _event(kind: String, tick: int) -> bool:
	_sequence += 1
	return _state.consume({"generation":_generation,"sequence":_sequence,"tick":tick,
		"kind":kind,"committed":true})
