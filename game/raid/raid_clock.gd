class_name RaidClock
extends RefCounted
## Fixed 60 Hz authority clock. No API accepts render-frame delta.

const TICK_RATE: int = 60
const MAX_CATCH_UP_TICKS_PER_DRAIN: int = 8
const MAX_PENDING_TICKS: int = 240

var current_tick: int = 0
var paused: bool = true
var pending_ticks: int = 0
var rejected_ticks: int = 0
var _sealed: bool = false


func reset(initial_tick: int = 0, start_paused: bool = true) -> bool:
	if _sealed or initial_tick < 0:
		return false
	current_tick = initial_tick
	pending_ticks = 0
	rejected_ticks = 0
	paused = start_paused
	return true


func resume() -> void:
	if _sealed:
		return
	paused = false


func pause() -> void:
	paused = true


func clear_pending() -> void:
	pending_ticks = 0


func request_ticks(count: int) -> int:
	if _sealed or count <= 0:
		return 0
	var accepted := mini(count, MAX_PENDING_TICKS - pending_ticks)
	pending_ticks += accepted
	rejected_ticks += count - accepted
	return accepted


func drain_catch_up(limit: int = MAX_CATCH_UP_TICKS_PER_DRAIN) -> PackedInt64Array:
	var advanced := PackedInt64Array()
	if _sealed or paused or limit <= 0:
		return advanced
	var count := mini(pending_ticks, mini(limit, MAX_CATCH_UP_TICKS_PER_DRAIN))
	for _index in count:
		current_tick += 1
		pending_ticks -= 1
		advanced.append(current_tick)
	return advanced


func step(count: int = 1) -> PackedInt64Array:
	var advanced := PackedInt64Array()
	if _sealed or not paused or count <= 0:
		return advanced
	var bounded_count := mini(count, MAX_CATCH_UP_TICKS_PER_DRAIN)
	for _index in bounded_count:
		current_tick += 1
		advanced.append(current_tick)
	return advanced


func seal() -> void:
	paused = true
	pending_ticks = 0
	_sealed = true


func is_sealed() -> bool:
	return _sealed
