class_name ZCombatHudModel
extends RefCounted
## Confirmed combat values plus explicitly provisional feedback. Predicting an
## input NEVER decrements ammunition, heals a zone, or grants a hit/kill marker.
signal changed(view: Dictionary)
const MAX_PENDING: int = 64
const PREDICTION_TIMEOUT_TICKS: int = 120
const CORRECTION_VISIBLE_TICKS: int = 30
var _actor: String = ""
var _generation: int = 0
var _tick: int = 0
var _frame: Dictionary = {}
var _pending: Dictionary = {}
var _view: Dictionary = {}
var _released: bool = false
var _correction: String = ""
var _correction_until: int = 0

func configure(actor_id: String, generation: int) -> bool:
	if not _actor.is_empty() or ZEntityId.parse(actor_id) == null or generation < 1: return false
	_actor = actor_id
	_generation = generation
	return true

func predict(admission: Dictionary) -> bool:
	if _released or _generation == 0 or admission.get("admitted") != true \
		or admission.get("generation") != _generation or typeof(admission.get("request_id")) != TYPE_STRING \
		or _pending.size() >= MAX_PENDING: return false
	_pending[admission.request_id] = {"tick": _tick, "kind": admission.get("kind", "")}
	return true

func publish(frame: Dictionary) -> bool:
	if _released or not _valid(frame): return false
	if int(frame.tick) < _tick: return false
	if int(frame.tick) == _tick and not _frame.is_empty(): return frame == _frame
	_tick = int(frame.tick)
	_frame = _frozen(frame)
	for receipt: Dictionary in frame.receipts:
		if receipt.terminal:
			_pending.erase(receipt.request_id)
			if not receipt.committed:
				_correction = String(receipt.reason)
				_correction_until = _tick + CORRECTION_VISIBLE_TICKS
	for id: String in _pending.keys():
		if _tick - int(_pending[id].tick) > PREDICTION_TIMEOUT_TICKS:
			_pending.erase(id)
			_correction = "confirmation_unavailable"
			_correction_until = _tick + CORRECTION_VISIBLE_TICKS
	var hp: int = 0
	var max_hp: int = 0
	var bleed: bool = false
	var fracture: bool = false
	for zone: Dictionary in frame.health.body_parts:
		hp += int(zone.health_micros)
		max_hp += int(zone.max_health_micros)
		bleed = bleed or bool(zone.heavy_bleed)
		fracture = fracture or bool(zone.fractured)
	var weapon: Dictionary = frame.weapon
	var reloading: bool = weapon.get("phase") == "reloading"
	var reload: Dictionary = weapon.get("reload", {})
	var start_tick: int = int(reload.get("start_tick", _tick))
	var due_tick: int = int(reload.get("due_tick", _tick))
	var progress: float = clampf(float(_tick - start_tick) / maxi(1, due_tick - start_tick), 0.0, 1.0) if reloading else 0.0
	_view = _frozen({"available": true, "actor_id": _actor, "generation": _generation, "tick": _tick,
		"alive": frame.health.alive, "ammo": int(weapon.get("loaded_rounds", 0)),
		"has_weapon": not weapon.is_empty(), "reserve": int(frame.reserve_rounds),
		"has_melee": frame.get("melee_equipment", {}).get("definition_id") == "zerkov.weapon.machete",
		"health_micros": hp, "max_health_micros": max_hp,
		"health_ratio": float(hp) / maxi(1, max_hp), "body_parts": frame.health.body_parts,
		"stamina_ratio": clampf(float(frame.health.stamina_micros) / maxi(1, int(frame.health.max_stamina_micros)), 0.0, 1.0),
		"hydration_ratio": clampf(float(frame.health.hydration_micros) / 100_000_000.0, 0.0, 1.0),
		"bleeding": bleed, "fractured": fracture, "reloading": reloading, "reload_progress": progress,
		"pending_actions": _pending.size(), "correction": _correction if _tick <= _correction_until else "",
		"melee_phase": frame.melee.phase, "feedback": frame.feedback})
	changed.emit(_view)
	return true

func snapshot() -> Dictionary:
	return _view if not _view.is_empty() else _frozen({"available": false})

func confirmed_frame() -> Dictionary:
	return _frame

func release() -> void:
	_released = true
	_pending.clear()
	_frame = {}
	_view = _frozen({"available": false})
	changed.emit(_view)

func _valid(frame: Dictionary) -> bool:
	if frame.get("schema") != "zerkov.combat.frame.v1" or frame.get("actor_id") != _actor \
		or frame.get("generation") != _generation or typeof(frame.get("tick")) != TYPE_INT \
		or frame.tick < 1 or frame.get("available") != true \
		or not frame.get("health") is Dictionary or not frame.get("weapon") is Dictionary \
		or not frame.get("receipts") is Array or frame.receipts.size() > 1024 \
		or not frame.get("feedback") is Array or frame.feedback.size() > 128 \
		or typeof(frame.get("reserve_rounds")) != TYPE_INT or frame.reserve_rounds < 0 \
		or not frame.get("melee") is Dictionary or frame.melee.get("phase") not in [&"ready", &"windup", &"active", &"recovery"]:
		return false
	var h: Dictionary = frame.health
	if typeof(h.get("alive")) != TYPE_BOOL or not h.get("body_parts") is Array or h.body_parts.size() != 7:
		return false
	for field: String in ["stamina_micros", "max_stamina_micros", "hydration_micros"]:
		if typeof(h.get(field)) != TYPE_INT or h[field] < 0: return false
	for zone: Variant in h.body_parts:
		if not zone is Dictionary or typeof(zone.get("health_micros")) != TYPE_INT \
			or typeof(zone.get("max_health_micros")) != TYPE_INT or zone.health_micros < 0 \
			or zone.max_health_micros < 1 or zone.health_micros > zone.max_health_micros \
			or typeof(zone.get("heavy_bleed")) != TYPE_BOOL or typeof(zone.get("fractured")) != TYPE_BOOL:
			return false
	if not frame.weapon.is_empty():
		if typeof(frame.weapon.get("loaded_rounds")) != TYPE_INT or frame.weapon.loaded_rounds < 0 \
			or frame.weapon.get("phase") not in ["ready", "reloading"]: return false
		if frame.weapon.get("phase") == "reloading" and not frame.weapon.get("reload") is Dictionary: return false
	for receipt: Variant in frame.receipts:
		if not receipt is Dictionary or receipt.get("actor_id") != _actor or receipt.get("generation") != _generation \
			or typeof(receipt.get("terminal")) != TYPE_BOOL or typeof(receipt.get("committed")) != TYPE_BOOL \
			or typeof(receipt.get("request_id")) != TYPE_STRING or typeof(receipt.get("reason")) not in [TYPE_STRING, TYPE_STRING_NAME]: return false
	return true

static func _frozen(value: Dictionary) -> Dictionary:
	var copy := value.duplicate(true)
	ZMeleeTimeline._freeze(copy)
	return copy
