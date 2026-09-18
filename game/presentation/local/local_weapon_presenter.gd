class_name LocalWeaponPresenter
extends Node2D
## A bounded, tick-sampled cosmetic layer. Inventory/Weapon/Health own every
## outcome. No input, process callback, raycast, ammunition or damage mutation.
## Existing inventory artwork is reused; these are not bespoke weapon frames.
const AKM: String = "zerkov.weapon.akm"
const MACHETE: String = "zerkov.weapon.machete"
const EFFECT_TICKS: int = 6
const MAX_EFFECTS: int = 8
const MAX_SEEN_SHOTS: int = 128
@export var akm_texture: Texture2D = preload("res://assets/handoff/gun_ak.png")
@export var machete_texture: Texture2D = preload("res://assets/handoff/gun_machete.png")
var _sprite: Sprite2D
var _generation: int = 0
var _actor: String = ""
var _tick: int = 0
var _released: bool = false
var _dead: bool = false
var _frame: Dictionary = {}
var _view: Dictionary = {}
var _effects: Array[Dictionary] = []
var _seen: Dictionary = {}
var _order: Array[String] = []
var _shot_count: int = 0
var _reload_progress: float = -1.0

func configure(generation: int) -> bool:
	if _generation != 0 or _released or generation < 1: return false
	_generation = generation
	_sprite = Sprite2D.new()
	_sprite.name = "HeldWeapon"
	_sprite.centered = false
	_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_sprite.visible = false
	add_child(_sprite)
	return true

func present(pose: Vector2, facing: Vector2, frame: Dictionary) -> bool:
	if _released or _generation == 0 or not _valid(frame) or not pose.is_finite() or not facing.is_finite(): return false
	if frame.tick < _tick: return false
	if frame.tick == _tick and not _frame.is_empty(): return frame == _frame
	if _dead and frame.health.alive: return false
	_actor = frame.actor_id
	_tick = frame.tick
	_frame = frame # Production closeout frames are already recursively immutable.
	_dead = not frame.health.alive
	var primary: Dictionary = frame.weapon
	var melee: Dictionary = frame.get("melee_equipment", {})
	var swinging: bool = frame.get("melee", {}).get("phase", &"ready") != &"ready"
	var primary_id: String = String(primary.get("instance_id", ""))
	var definition: String = String(primary.get("definition_id", ""))
	var held_id: String = primary_id
	if (primary.is_empty() or swinging) and String(melee.get("definition_id", "")) == MACHETE:
		definition = MACHETE
		held_id = String(melee.get("weapon_id", ""))
	var texture: Texture2D = akm_texture if definition == AKM else (machete_texture if definition == MACHETE else null)
	_sprite.visible = not _dead and not held_id.is_empty() and texture != null
	_sprite.texture = texture if _sprite.visible else null
	var direction: Vector2 = facing.normalized() if facing.length_squared() > 0.0 else Vector2.RIGHT
	var left: bool = direction.x < 0.0
	_sprite.position = Vector2(-5 if left else 5, -11)
	_sprite.offset = -Vector2(80, 43) if definition == AKM else -Vector2(114, 37)
	_sprite.scale = Vector2(-0.24, -0.24 if left else 0.24)
	_sprite.rotation = direction.angle()
	_reload_progress = -1.0
	if _sprite.visible and definition == AKM and primary.get("phase") == "reloading":
		var reload: Dictionary = primary.get("reload", {})
		_reload_progress = clampf(float(_tick - int(reload.get("start_tick", _tick))) / maxi(1, int(reload.get("due_tick", _tick)) - int(reload.get("start_tick", _tick))), 0.0, 1.0)
		_sprite.rotation += (-0.35 if left else 0.35)
	if _sprite.visible and definition == MACHETE and swinging:
		var swing: Dictionary = frame.melee.get("swing", {})
		var progress := clampf(float(_tick - int(swing.get("start_tick", _tick))) / maxi(1, int(swing.get("ready_tick", _tick)) - int(swing.get("start_tick", _tick))), 0.0, 1.0)
		_sprite.rotation += lerpf(-1.0, 1.0, progress) * (-1.0 if left else 1.0)
	# Retired/unequipped actors cannot retain a muzzle flash or impact marker.
	if _dead or primary.is_empty() or primary.get("definition_id") != AKM or akm_texture == null: _effects.clear()
	else:
		for i in range(_effects.size() - 1, -1, -1):
			if _tick >= int(_effects[i].event.tick) + EFFECT_TICKS or _effects[i].event.weapon_instance_id != primary_id:
				_effects.remove_at(i)
		for event: Dictionary in frame.feedback:
			if event.get("kind") != &"shot" or _seen.has(String(event.get("id", ""))): continue
			if not _valid_shot(event, primary_id): continue # Never invent feedback from a rejected input.
			_seen[String(event.id)] = true
			_order.append(String(event.id))
			if _order.size() > MAX_SEEN_SHOTS: _seen.erase(_order.pop_front())
			if _effects.size() == MAX_EFFECTS: _effects.pop_front()
			# Freeze the cosmetic muzzle anchor at this shot's actor pose.
			# Keep the authoritative resolver geometry untouched in the event.
			var effect := {"event": event, "muzzle_world": pose.round() + _sprite.transform * Vector2(-53, -11)}
			effect.make_read_only()
			_effects.append(effect)
			_shot_count += 1
	_view = {"generation": _generation, "actor_id": _actor, "tick": _tick,
		"visible": _sprite.visible, "held_instance_id": held_id if _sprite.visible else "",
		"held_definition": definition if _sprite.visible else "", "primary_instance_id": primary_id,
		"reloading": _reload_progress >= 0.0, "reload_progress": _reload_progress,
		"shot_count": _shot_count, "effect_count": _effects.size(), "alive": not _dead}
	_view.make_read_only()
	queue_redraw()
	return true

func snapshot() -> Dictionary:
	return _view

func release() -> void:
	_released = true
	if _sprite != null:
		_sprite.visible = false
		_sprite.texture = null
	_effects.clear()
	_seen.clear()
	_order.clear()
	_frame = {}
	_view = {}
	_view.make_read_only()
	_reload_progress = -1.0
	queue_redraw()

func _valid(frame: Dictionary) -> bool:
	if frame.get("generation") != _generation or typeof(frame.get("tick")) != TYPE_INT or frame.tick < 1 \
		or typeof(frame.get("actor_id")) != TYPE_STRING or frame.actor_id.is_empty() \
		or (not _actor.is_empty() and frame.actor_id != _actor) or not frame.get("health") is Dictionary \
		or typeof(frame.health.get("alive")) != TYPE_BOOL or not frame.get("weapon") is Dictionary \
		or not frame.get("feedback") is Array or frame.feedback.size() > 128 \
		or not frame.get("melee_equipment", {}) is Dictionary or not frame.get("melee", {}) is Dictionary:
		return false
	if not frame.weapon.is_empty():
		for key: String in ["instance_id", "definition_id"]:
			if typeof(frame.weapon.get(key)) != TYPE_STRING or frame.weapon[key].is_empty(): return false
		if frame.weapon.get("phase") not in ["ready", "reloading"]: return false
		if frame.weapon.get("phase") == "reloading" and not frame.weapon.get("reload") is Dictionary: return false
	for event: Variant in frame.feedback:
		if not event is Dictionary: return false
	return true

func _valid_shot(event: Dictionary, primary_id: String) -> bool:
	return event.get("tick") == _tick and event.get("actor_id") == _actor \
		and event.get("weapon_instance_id") == primary_id and event.get("weapon_id") == AKM \
		and typeof(event.get("id")) == TYPE_STRING and not event.id.is_empty() \
		and typeof(event.get("origin_raw")) == TYPE_VECTOR2I and typeof(event.get("target_raw")) == TYPE_VECTOR2I \
		and typeof(event.get("hit")) == TYPE_BOOL and typeof(event.get("blocked")) == TYPE_BOOL \
		and ZWorldUnits.canonical_to_godot(event.origin_raw).ok and ZWorldUnits.canonical_to_godot(event.target_raw).ok

func _draw() -> void:
	if _released or _dead: return
	for effect: Dictionary in _effects:
		var event: Dictionary = effect.event
		var origin_result := ZWorldUnits.canonical_to_godot(event.origin_raw)
		var target_result := ZWorldUnits.canonical_to_godot(event.target_raw)
		if not origin_result.ok or not target_result.ok: continue
		# Cosmetic emission starts at the artwork's shot-time barrel. The end
		# is still the first authoritative hit/obstruction, never a new query.
		# Suppress the trace if that obstruction is behind the visual barrel.
		var origin := to_local(origin_result.vector2_value)
		var target := to_local(target_result.vector2_value)
		var age: float = float(_tick - int(event.tick)) / EFFECT_TICKS
		var muzzle := to_local(effect.muzzle_world)
		if (target - muzzle).dot(target - origin) > 0.0:
			draw_line(muzzle, target, Color(1.0, 0.83, 0.47, 0.85 * (1.0 - age)), 1.0)
		draw_circle(muzzle, 2.7 * (1.0 - age), Color(1.0, 0.88, 0.57, 0.9))
		if event.hit or event.blocked:
			var color := Color(0.9, 0.35, 0.23, 1.0 - age) if event.get("damage_confirmed", false) else Color(0.95, 0.85, 0.65, 1.0 - age)
			draw_line(target - Vector2(2, 2), target + Vector2(2, 2), color, 1.0)
			draw_line(target - Vector2(-2, 2), target + Vector2(-2, 2), color, 1.0)
	if _sprite.visible and _reload_progress >= 0.0:
		draw_line(Vector2(-7, -4), Vector2(7, -4), Color(0.15, 0.17, 0.15), 2.0)
		draw_line(Vector2(-7, -4), Vector2(-7 + 14 * _reload_progress, -4), Color(0.87, 0.73, 0.43), 1.0)
