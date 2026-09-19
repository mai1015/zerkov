class_name LocalActorPresenter
extends Node2D
## Normal-raid adapter for the existing layered presenter. Every state input is
## sampled after successful raid closeout. Never authorizes a gameplay outcome.
var _state := ZPlayerAnimationState.new()
var _layers := ZLayeredPlayerPresenter.new()
var _sequence: int = 0
var _generation: int = 0
var _dead: bool = false
var _moving: bool = false

func configure(manifest: Dictionary, textures: Dictionary, generation: int) -> bool:
	if _generation != 0 or not _state.configure(manifest.get("clips", {}), generation): return false
	add_child(_layers)
	if not _layers.configure(manifest, textures, generation): return false
	_generation = generation
	return true

func present(pose: Vector2, velocity: Vector2, facing: Vector2, frame: Dictionary) -> bool:
	if _generation == 0 or frame.is_empty() or frame.get("generation") != _generation: return false
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
		# Source contains a knife swing, not an approved AKM/machete alignment.
		# Only melee commitment invokes that provisional attack clip; shots must
		# never look like a melee swing or create animation-driven damage.
		for receipt: Dictionary in frame.receipts:
			if not _dead and receipt.kind == &"melee" and receipt.committed:
				if not _event("attack", tick): return false
	# The authored player frames face LEFT (mask, knife reach and throw trails
	# all point -x), so the horizontal mirror belongs to a right-facing actor.
	return _layers.present(_state.snapshot(), facing.x > 0.0)

func release() -> void:
	_state.release()
	_layers.release()

func _event(kind: String, tick: int) -> bool:
	_sequence += 1
	return _state.consume({"generation":_generation,"sequence":_sequence,"tick":tick,
		"kind":kind,"committed":true})
