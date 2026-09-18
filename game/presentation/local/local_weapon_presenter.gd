class_name LocalWeaponPresenter
extends Node2D
## Original source art, sampled after raid closeout. No input, physics, damage,
## ammo mutation, collision query or animation callback has authority here.
const AKM: String = "zerkov.weapon.akm"
const MACHETE: String = "zerkov.weapon.machete"
const EFFECT_TICKS: int = 24
const FX_FRAME_TICKS: int = 3
const MAX_EFFECTS: int = 8
const MAX_SEEN_SHOTS: int = 128
const FX: SpriteFrames = preload("res://game/content/art/weapon_art/weapon_fx.tres")
const BLOOD: Array[Texture2D] = [
	preload("res://assets/original/fx/blood particles/part_1.png"),
	preload("res://assets/original/fx/blood particles/part_2.png"),
	preload("res://assets/original/fx/blood particles/part_3.png"),
	preload("res://assets/original/fx/blood particles/part_4.png"),
	preload("res://assets/original/fx/blood particles/part_5.png"),
	preload("res://assets/original/fx/blood particles/part_6.png"),
	preload("res://assets/original/fx/blood particles/part_7.png"),
	preload("res://assets/original/fx/blood particles/part_8.png"),
	preload("res://assets/original/fx/blood particles/part_9.png")]
@export var akm_art: ZHeldWeaponArt = preload("res://game/content/art/weapon_art/akm.tres")
@export var machete_art: ZHeldWeaponArt = preload("res://game/content/art/weapon_art/machete.tres")
var _sprite: Sprite2D
var _generation: int = 0
var _actor: String = ""
var _tick: int = 0
var _released: bool = false
var _dead: bool = false
var _frame: Dictionary = {}
var _view: Dictionary = {}
var _effects: Array[Dictionary] = []
var _surfaces: Dictionary = {}
var _seen: Dictionary = {}
var _order: Array[String] = []
var _shot_count: int = 0
var _reload_progress: float = -1.0

func configure(generation: int, surfaces: Dictionary = {}) -> bool:
	if _generation != 0 or _released or generation < 1: return false
	for id: Variant in surfaces:
		if not id is String or surfaces[id] not in ["wood", "metal", "concrete", "brick", "dust"]: return false
	_surfaces = surfaces.duplicate()
	_surfaces.make_read_only()
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_generation = generation
	_sprite = Sprite2D.new()
	_sprite.name = "HeldWeaponAndPose"
	_sprite.centered = false
	_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_sprite.visible = false
	add_child(_sprite)
	return true

func present(pose: Vector2, facing: Vector2, frame: Dictionary, body_sample: Dictionary = {}) -> bool:
	if _released or _generation == 0 or not _valid(frame) or not pose.is_finite() or not facing.is_finite(): return false
	if frame.tick < _tick: return false
	if frame.tick == _tick and not _frame.is_empty(): return frame == _frame
	if _dead and frame.health.alive: return false
	_actor = frame.actor_id
	_tick = frame.tick
	_frame = frame # Root closeout frames are recursively immutable.
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
	var art: ZHeldWeaponArt = akm_art if definition == AKM else (machete_art if definition == MACHETE else null)
	_sprite.visible = not _dead and not held_id.is_empty() and art != null and art.texture != null
	_sprite.texture = art.texture if _sprite.visible else null
	var direction: Vector2 = facing.normalized() if facing.length_squared() > 0.0 else Vector2.RIGHT
	if definition == MACHETE and swinging:
		var aim: Variant = frame.melee.get("swing", {}).get("aim_raw")
		if aim is Vector2i and aim != Vector2i.ZERO: direction = Vector2(aim).normalized()
	var left: bool = direction.x < 0.0
	var attack_frame: int = melee_frame(frame)
	if _sprite.visible:
		var anchor: Vector2 = art.shoulder
		if definition == MACHETE and swinging and art.attack_hand.size() == 6:
			anchor = art.attack_hand[attack_frame]
		else:
			var index: int = int(body_sample.get("frame", 0)) % 6
			# Exact torso-sheet Y offsets, not an independent animation clock.
			anchor.y += ([0, 1, 1, 0, 0, 1] if body_sample.get("state") == "walk" else [0, 0, 0, 1, 0, 0])[index]
		_sprite.position = Vector2(anchor.x if left else -anchor.x, anchor.y)
		_sprite.offset = -art.grip
		# Sources face LEFT. Reflect right-facing poses, then turn around the
		# authored shoulder/grip; vertical reflection keeps left aims upright.
		_sprite.scale = Vector2(-art.pixel_scale, -art.pixel_scale if left else art.pixel_scale)
		_sprite.rotation = direction.angle()
		if definition == MACHETE and swinging and art.attack_degrees.size() == 6:
			_sprite.rotation += deg_to_rad(art.attack_degrees[attack_frame]) * (-1.0 if left else 1.0)
	_reload_progress = -1.0
	if _sprite.visible and definition == AKM and primary.get("phase") == "reloading":
		var reload: Dictionary = primary.get("reload", {})
		_reload_progress = clampf(float(_tick - int(reload.get("start_tick", _tick))) / maxi(1, int(reload.get("due_tick", _tick)) - int(reload.get("start_tick", _tick))), 0.0, 1.0)
		_sprite.rotation += (-0.35 if left else 0.35)
	if _dead or primary.is_empty() or primary.get("definition_id") != AKM or akm_art == null or akm_art.texture == null:
		_effects.clear()
	else:
		for i in range(_effects.size() - 1, -1, -1):
			if _tick >= int(_effects[i].event.tick) + EFFECT_TICKS or _effects[i].event.weapon_instance_id != primary_id:
				_effects.remove_at(i)
		for event: Dictionary in frame.feedback:
			if event.get("kind") != &"shot" or _seen.has(String(event.get("id", ""))): continue
			if not _valid_shot(event, primary_id): continue
			_seen[String(event.id)] = true
			_order.append(String(event.id))
			if _order.size() > MAX_SEEN_SHOTS: _seen.erase(_order.pop_front())
			if _effects.size() == MAX_EFFECTS: _effects.pop_front()
			var effect := {"event": event,
				"muzzle_world": pose.round() + _sprite.transform * (akm_art.muzzle - akm_art.grip),
				"angle": direction.angle(), "left": left,
				"surface": String(_surfaces.get(String(event.get("obstruction_id", "")), "")) if event.blocked else ""}
			effect.make_read_only()
			_effects.append(effect)
			_shot_count += 1
	_view = {"generation": _generation, "actor_id": _actor, "tick": _tick,
		"visible": _sprite.visible, "held_instance_id": held_id if _sprite.visible else "",
		"held_definition": definition if _sprite.visible else "", "primary_instance_id": primary_id,
		"arms_overridden": _sprite.visible and art.includes_arms, "facing_left": left,
		"attack_frame": attack_frame, "source_profile": art.resource_path if _sprite.visible else "",
		"reloading": _reload_progress >= 0.0, "reload_progress": _reload_progress,
		"shot_count": _shot_count, "effect_count": _effects.size(), "alive": not _dead}
	_view.make_read_only()
	queue_redraw()
	return true

static func melee_frame(frame: Dictionary) -> int:
	var melee: Dictionary = frame.get("melee", {})
	var swing: Dictionary = melee.get("swing", {})
	var tick: int = int(frame.get("tick", 0))
	match melee.get("phase", &"ready"):
		&"windup":
			var start: int = int(swing.get("start_tick", tick))
			return clampi(int(3.0 * (tick - start) / maxi(1, int(swing.get("active_tick", start + 10)) - start)), 0, 2)
		&"active": return 3
		&"recovery":
			var start: int = int(swing.get("recovery_tick", tick))
			return 4 + clampi(int(2.0 * (tick - start) / maxi(1, int(swing.get("ready_tick", start + 18)) - start)), 0, 1)
	return 0

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
	_surfaces = {}
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
		var target_result := ZWorldUnits.canonical_to_godot(event.target_raw)
		if not target_result.ok: continue
		var age: int = _tick - int(event.tick)
		@warning_ignore("integer_division")
		var index: int = age / FX_FRAME_TICKS
		var muzzle := to_local(effect.muzzle_world)
		var target := to_local(target_result.vector2_value)
		if index < FX.get_frame_count(&"muzzle"):
			draw_set_transform(muzzle, effect.angle, Vector2(-1, -1 if effect.left else 1))
			draw_texture(FX.get_frame_texture(&"muzzle", index), -Vector2(27, 12))
			draw_set_transform(Vector2.ZERO)
		# An authoritative clear miss does not create an impact at max range.
		if event.get("damage_confirmed", false) and event.hit:
			var t: float = float(age) / EFFECT_TICKS
			for i in range(5):
				var texture: Texture2D = BLOOD[(int(event.tick) + i) % BLOOD.size()]
				var velocity := Vector2(-6 + i * 3, -8 - (i % 3) * 3)
				var offset := velocity * t + Vector2(0, 12 * t * t)
				draw_texture(texture, target + offset - texture.get_size() * 0.5, Color(1, 1, 1, 1.0 - t))
		elif event.blocked and not effect.surface.is_empty() and FX.has_animation(effect.surface):
			if index < FX.get_frame_count(effect.surface):
				var texture: Texture2D = FX.get_frame_texture(effect.surface, index)
				draw_texture(texture, target - Vector2(texture.get_width() * 0.5, texture.get_height() - 4))
	if _sprite.visible and _reload_progress >= 0.0:
		draw_line(Vector2(-7, -4), Vector2(7, -4), Color(0.15, 0.17, 0.15), 2.0)
		draw_line(Vector2(-7, -4), Vector2(-7 + 14 * _reload_progress, -4), Color(0.87, 0.73, 0.43), 1.0)
