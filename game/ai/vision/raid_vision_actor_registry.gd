class_name RaidVisionActorRegistry
extends RefCounted
## Task 6.2. Trusted, raid-owned actor/geometry input port, NOT an AI view.
## Stage after movement, apply inside the reserved Vision callback. The native
## owner never escapes that callback; this registry stores values only.

const MAX_ACTORS: int = 128
const MAX_OBSERVERS: int = 64
const MAX_IDENTITIES: int = 4096
const MAX_SEGMENTS: int = 128
const ACTOR_KEYS: Array = ["entity_id", "revision", "position_raw", "facing_raw", "archetype", "alive"]

var last_error: StringName = &""
var _generation: int = 0
var _tick: int = 0
var _released: bool = false
var _failed: bool = false
var _entities: Dictionary = {}
var _identity_map: Dictionary = {}
var _retired: Dictionary = {}
var _geometry_revision: int = 0
var _segments: Array = []
var _staged: Dictionary = {}
var _projections: Dictionary = {}
var _perception_profiles: Dictionary = {}


func configure(generation: int, scav: ZAIProfile = null, mutant: ZAIProfile = null) -> bool:
	if _generation != 0 or _released or generation < 1:
		return _reject(&"vision_actor_configuration_invalid")
	var scav_profile := ZAIProfile.scav() if scav == null else scav
	var mutant_profile := ZAIProfile.mutant() if mutant == null else mutant
	if not scav_profile.is_valid() or not mutant_profile.is_valid() \
		or scav_profile.archetype != "scav" or mutant_profile.archetype != "mutant":
		return _reject(&"vision_actor_profiles_invalid")
	_perception_profiles = ZAIValues.frozen({"scav": scav_profile.perception_record(),
		"mutant": mutant_profile.perception_record()})
	_generation = generation
	return true


func stage_frame(generation: int, tick: int, actors: Array,
	geometry_revision: int, segments: Array) -> bool:
	last_error = &""
	if not is_active(generation) or not _staged.is_empty() or tick != _tick + 1 \
		or tick >= ZAIValues.MAX_TICK:
		return _reject(&"vision_actor_frame_order_invalid")
	if actors.size() > MAX_ACTORS or geometry_revision < 1 \
		or geometry_revision < _geometry_revision or not _valid_segments(segments):
		return _reject(&"vision_actor_frame_invalid")
	var sorted_segments := segments.duplicate(true)
	sorted_segments.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.id < b.id)
	if geometry_revision == _geometry_revision and sorted_segments != _segments:
		return _reject(&"vision_geometry_revision_conflict")
	var incoming: Dictionary = {}
	var observer_count: int = 0
	for value: Variant in actors:
		if not _valid_actor(value) or incoming.has(value.entity_id):
			return _reject(&"vision_actor_invalid_or_duplicate")
		if _retired.has(value.entity_id):
			return _reject(&"vision_actor_identity_retired")
		if value.alive and value.archetype != "player":
			observer_count += 1
		incoming[value.entity_id] = value.duplicate(true)
	if observer_count > MAX_OBSERVERS:
		return _reject(&"vision_observer_capacity")
	var commands: Array = []
	var next_entities: Dictionary = {}
	var next_map := _identity_map.duplicate()
	var next_retired := _retired.duplicate()
	if geometry_revision > _geometry_revision:
		commands.append({"method": &"set_occluder_segments", "args": [sorted_segments, geometry_revision]})
	var old_keys := _entities.keys()
	old_keys.sort()
	for key: String in old_keys:
		var old: Dictionary = _entities[key]
		if not incoming.has(key) or not bool(incoming[key].alive):
			if old.actor.alive:
				if old.actor.archetype != "player":
					commands.append({"method": &"remove_observer", "args": [old.native_id]})
				commands.append({"method": &"remove_target", "args": [old.native_id]})
			if not incoming.has(key):
				next_retired[key] = true
	var keys := incoming.keys()
	keys.sort()
	for key: String in keys:
		var actor: Dictionary = incoming[key]
		var old: Dictionary = _entities.get(key, {})
		if not old.is_empty():
			if actor.revision == old.actor.revision and actor != old.actor:
				return _reject(&"vision_actor_revision_conflict")
			if actor.revision != old.actor.revision and actor.revision != old.actor.revision + 1:
				return _reject(&"vision_actor_revision_gap_or_regression")
			if actor.archetype != old.actor.archetype or (not old.actor.alive and actor.alive):
				return _reject(&"vision_actor_identity_changed")
		elif actor.revision != 1:
			return _reject(&"vision_actor_initial_revision")
		var native_id: int = int(old.get("native_id", 0))
		if native_id == 0:
			if next_map.size() >= MAX_IDENTITIES:
				return _reject(&"vision_identity_capacity")
			native_id = next_map.size() + 1
			next_map[native_id] = key
		var native_revision: int = int(old.get("native_revision", 0))
		var changed: bool = old.is_empty() or actor != old.actor
		if actor.alive and changed:
			native_revision += 1
			var target := _target(actor, native_id, native_revision)
			commands.append({"method": &"register_target" if old.is_empty() else &"update_target",
				"args": [target] if old.is_empty() else [target, native_revision - 1]})
			if actor.archetype != "player":
				var observer := _observer(actor, native_id, native_revision)
				commands.append({"method": &"register_observer" if old.is_empty() else &"update_observer",
					"args": [observer] if old.is_empty() else [observer, native_revision - 1]})
		next_entities[key] = {"actor": actor, "native_id": native_id, "native_revision": native_revision}
	_staged = {"tick": tick, "entities": next_entities, "identities": next_map,
		"retired": next_retired, "commands": commands, "geometry_revision": geometry_revision,
		"segments": sorted_segments}
	return true


## Called only by the trusted native owner inside its attested Vision phase.
## Native batches are not rollback transactions: any partial failure permanently
## invalidates this registry and must quarantine/dispose the owning Vision world.
func apply_staged(native: Object, generation: int, tick: int) -> bool:
	last_error = &""
	if not is_active(generation) or _staged.is_empty() or _staged.tick != tick or native == null:
		return _reject(&"vision_actor_frame_missing")
	if not _staged.get("commands") is Array or _staged.commands.size() > MAX_ACTORS * 4 + 1:
		return _fail(&"vision_native_commands_invalid")
	for command: Variant in _staged.commands:
		# Never expose arbitrary Object.call through retained command data. Even
		# a corrupted staged record cannot invoke add_child/call_deferred/etc.
		if not command is Dictionary or not ZAIValues.keys(command, ["method", "args"]) \
			or not command.args is Array or command.args.size() < 1 or command.args.size() > 2:
			return _fail(&"vision_native_command_invalid")
		var args: Array = command.args
		var result: Variant = {}
		match command.method:
			&"register_target", &"register_observer":
				if args.size() != 1 or not args[0] is Dictionary:
					return _fail(&"vision_native_command_invalid")
				result = native.call("register_target", args[0]) if command.method == &"register_target" else native.call("register_observer", args[0])
			&"update_target", &"update_observer":
				if args.size() != 2 or not args[0] is Dictionary or typeof(args[1]) != TYPE_INT:
					return _fail(&"vision_native_command_invalid")
				result = native.call("update_target", args[0], args[1]) if command.method == &"update_target" else native.call("update_observer", args[0], args[1])
			&"remove_target", &"remove_observer":
				if args.size() != 1 or typeof(args[0]) != TYPE_INT:
					return _fail(&"vision_native_command_invalid")
				result = native.call("remove_target", args[0]) if command.method == &"remove_target" else native.call("remove_observer", args[0])
			&"set_occluder_segments":
				if args.size() != 2 or not args[0] is Array or not _valid_segments(args[0]) or typeof(args[1]) != TYPE_INT:
					return _fail(&"vision_native_command_invalid")
				result = native.call("set_occluder_segments", args[0], args[1])
			_:
				return _fail(&"vision_native_method_forbidden")
		if not result is Dictionary or result.get("ok") != true:
			return _fail(&"vision_native_actor_command_failed")
	_entities = _staged.entities
	_identity_map = _staged.identities
	_retired = _staged.retired
	_geometry_revision = _staged.geometry_revision
	_segments = _staged.segments
	_tick = tick
	_staged = {}
	# Immediately invalidate removed observers, even between cadence evaluations.
	var retained := _projections.duplicate(true)
	for key: String in retained.keys():
		if not _entities.has(key) or not _entities[key].actor.alive:
			retained.erase(key)
	_projections = ZAIValues.frozen(retained)
	return true


func collect_projections(native: Object, generation: int, tick: int) -> bool:
	if not is_active(generation) or tick != _tick or native == null:
		return _reject(&"vision_projection_collection_invalid")
	var next: Dictionary = {}
	var keys := _entities.keys()
	keys.sort()
	for key: String in keys:
		var entry: Dictionary = _entities[key]
		if not entry.actor.alive or entry.actor.archetype == "player":
			continue
		# Fail collection before a malformed retained identity reaches a native API.
		# The owner must downgrade its successful advance and quarantine this batch.
		if not ZAIValues.integer(entry.get("native_id"), 1, MAX_IDENTITIES):
			return _fail(&"vision_projection_identity_invalid")
		var result: Variant = native.call("get_projection", entry.native_id)
		if not result is Dictionary:
			return _fail(&"vision_projection_shape_invalid")
		# NOT_FOUND before the first budgeted query is an unavailable projection,
		# never invented visibility. Other failures must not publish partial facts.
		if result.get("ok") != true:
			if result.get("code") == 2:  # Common Vision NOT_FOUND.
				continue
			return _fail(&"vision_native_projection_failed")
		if result.get("observer_id") != entry.native_id:
			return _fail(&"vision_projection_recipient_invalid")
		next[key] = result.duplicate(true)
	_projections = ZAIValues.frozen(next)
	return true


func projection_for(generation: int, entity_id: String) -> Dictionary:
	if not is_active(generation):
		return {}
	return _projections.get(entity_id, {})


## Frozen at configure; mutating a caller's Resource cannot retune a live raid.
func perception_for(generation: int, archetype: String) -> Dictionary:
	return _perception_profiles.get(archetype, {}) if is_active(generation) else {}


func matches_perception(generation: int, scav: ZAIProfile, mutant: ZAIProfile) -> bool:
	return is_active(generation) and scav != null and mutant != null \
		and scav.is_valid() and mutant.is_valid() \
		and perception_for(generation, "scav") == scav.perception_record() \
		and perception_for(generation, "mutant") == mutant.perception_record()


func entity_for_native_id(generation: int, native_id: int) -> String:
	return String(_identity_map.get(native_id, "")) if is_active(generation) else ""


func native_id_for(generation: int, entity_id: String) -> int:
	return int(_entities.get(entity_id, {}).get("native_id", 0)) if is_active(generation) else 0


func is_active(generation: int) -> bool:
	return _generation > 0 and generation == _generation and not _released and not _failed


func release(generation: int) -> bool:
	if generation != _generation or _generation == 0:
		return _reject(&"vision_actor_generation_invalid")
	_released = true
	_staged.clear()
	_entities.clear()
	_identity_map.clear()
	_retired.clear()
	_projections = {}
	return true


func diagnostics() -> Dictionary:
	return ZAIValues.frozen({"generation": _generation, "tick": _tick,
		"actors": _entities.size(), "identities": _identity_map.size(),
		"staged_tick": int(_staged.get("tick", 0)), "staged_frame_required_every_tick": true,
		"geometry_revision": _geometry_revision, "failed": _failed, "released": _released})


static func _valid_actor(value: Variant) -> bool:
	if not value is Dictionary or not ZAIValues.keys(value, ACTOR_KEYS):
		return false
	return ZAIValues.entity(value.entity_id) and ZAIValues.integer(value.revision, 1, ZAIValues.MAX_TICK - 1) \
		and ZAIValues.position(value.position_raw) and ZAIValues.position(value.facing_raw) \
		and value.facing_raw != Vector2i.ZERO and typeof(value.alive) == TYPE_BOOL \
		and typeof(value.archetype) == TYPE_STRING and value.archetype in ["player", "scav", "mutant"] \
		and absi(int(value.position_raw.y)) <= ZAIValues.LIMIT - 250_000


static func _valid_segments(segments: Array) -> bool:
	if segments.size() > MAX_SEGMENTS:
		return false
	var ids: Dictionary = {}
	for item: Variant in segments:
		if not item is Dictionary or not ZAIValues.keys(item, ["id", "a", "b", "mask", "two_sided"]) \
			or not ZAIValues.integer(item.id, 1, ZAIValues.MAX_TICK) or ids.has(item.id) \
			or not ZAIValues.point(item.a) or not ZAIValues.point(item.b) or item.a == item.b \
			or not ZAIValues.integer(item.mask, 1, 3) or item.two_sided != true:
			return false
		ids[item.id] = true
	return true


static func _target(actor: Dictionary, native_id: int, revision: int) -> Dictionary:
	var mask: int = {"player": 1, "scav": 2, "mutant": 4}[actor.archetype]
	return {"id": native_id, "position": ZAIValues.encode_point(actor.position_raw),
		"mask": mask, "sample_policy": 0, "sample_offsets": [
			{"x": 0, "y": 0}, {"x": 0, "y": -250000}, {"x": 0, "y": 250000}],
		"revision": revision}


func _observer(actor: Dictionary, native_id: int, revision: int) -> Dictionary:
	var scav: bool = actor.archetype == "scav"
	var profile: Dictionary = _perception_profiles[actor.archetype]
	return {"id": native_id, "position": ZAIValues.encode_point(actor.position_raw),
		"facing": ZAIValues.encode_point(actor.facing_raw), "range": profile.sight_range_raw,
		"cone_cos_million": profile.cone_cos_million, "full_circle": false,
		"target_mask": 5 if scav else 3, "occluder_mask": 3,
		"memory_ticks": profile.memory_ticks, "priority": 0, "urgent": false, "revision": revision}


func _fail(reason: StringName) -> bool:
	_failed = true
	_projections = {}
	_staged = {}
	return _reject(reason)


func _reject(reason: StringName) -> bool:
	last_error = reason
	return false
