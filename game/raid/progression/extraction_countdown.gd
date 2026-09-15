class_name ExtractionCountdown
extends RefCounted
## Canonical-tick policy, not a second clock. Death and timeout win over a
## same-tick extraction completion. Leaving range, losing eligibility, damage
## or cancel interrupts; interruption wins over a same-tick start request.
var _duration: int = 0
var _limit: int = 0
var _last_tick: int = 0
var _started: int = -1
var _outcome: String = ""
var _interruption: String = ""

func configure(duration_ticks: int, raid_limit_ticks: int) -> bool:
	if _duration != 0 or duration_ticks < 1 or raid_limit_ticks < duration_ticks \
		or raid_limit_ticks > 2_147_483_647: return false
	_duration = duration_ticks
	_limit = raid_limit_ticks
	return true

func advance(tick: int, alive: bool, eligible: bool, inside: bool,
	damaged: bool, start_requested: bool, cancel_requested: bool) -> Dictionary:
	if _duration == 0 or tick != _last_tick + 1 or not _outcome.is_empty():
		return {"ok": false, "reason": &"extraction_tick_invalid_or_terminal"}
	_last_tick = tick
	_interruption = ""
	if not alive: _outcome = "dead"
	elif tick >= _limit: _outcome = "timeout"
	elif cancel_requested or damaged or not eligible or not inside:
		if _started >= 0:
			_interruption = "cancelled" if cancel_requested else ("damaged" if damaged else ("ineligible" if not eligible else "left_zone"))
		_started = -1
	elif _started >= 0 and tick - _started >= _duration:
		_outcome = "extracted"
	elif _started < 0 and start_requested:
		_started = tick
	return snapshot()

func snapshot() -> Dictionary:
	var remaining: int = maxi(0, _limit - _last_tick)
	@warning_ignore("integer_division")
	var seconds: int = (remaining + RaidClock.TICK_RATE - 1) / RaidClock.TICK_RATE
	@warning_ignore("integer_division")
	var minutes: int = seconds / 60
	return RaidProgressionValues.freeze({"ok": true, "tick": _last_tick, "outcome": _outcome,
		"counting": _started >= 0 and _outcome.is_empty(), "started_tick": _started,
		"countdown_remaining": maxi(0, _duration - (_last_tick - _started)) if _started >= 0 else _duration,
		"remaining_ticks": remaining, "clock_text": "%02d:%02d" % [minutes, seconds % 60],
		"interruption": _interruption, "deadline_tick": _limit})
