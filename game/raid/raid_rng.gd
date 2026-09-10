class_name ZRaidRng
extends RefCounted
## Small explicit deterministic RNG for authority fixtures and domain streams.

const MODULUS: int = 2_147_483_647
const MULTIPLIER: int = 48_271

var state: int = 1
var _sealed: bool = false


func _init(seed: int = 1) -> void:
	reset(seed)


func reset(seed: int) -> void:
	if _sealed:
		return
	var normalized := seed % (MODULUS - 1)
	if normalized < 0:
		normalized = -normalized
	state = normalized + 1


func next_int(max_exclusive: int) -> int:
	if _sealed or max_exclusive <= 0:
		return 0
	state = (state * MULTIPLIER) % MODULUS
	return state % max_exclusive


func seal() -> void:
	_sealed = true


func is_sealed() -> bool:
	return _sealed
