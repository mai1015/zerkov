class_name RaidAIRuntime
extends RefCounted
## Tasks 6.2-6.9 composition. Manually called in movement / AI / audit phases;
## owns no clock. Native perception is still owned by RaidVisionWorldOwner.

const MAX_AGENTS: int = 64
const HEARING_INBOX: int = 8
var last_error: StringName = &""
var _generation: int = 0
var _seed: int = 0
var _tick: int = 0
var _staged_tick: int = 0
var _noise_tick: int = 0
var _budget: int = MAX_AGENTS
var _world: RaidAIWorldPort
var _registry: RaidVisionActorRegistry
var _noise: RaidNoiseService
var _profiles: Dictionary = {}
var _actors: Dictionary = {}
var _brains: Dictionary = {}
var _adapters: Dictionary = {}
var _heard: Dictionary = {}
var _last_decision: Dictionary = {}
var _knowledge_summary: Dictionary = {}
var _rejected_actions: Dictionary = {}
var _rejected_paths: Dictionary = {}
var _failed: bool = false
var _released: bool = false
var _metrics: Dictionary = {}


func configure(raid_id: String, generation: int, seed: int, world: RaidAIWorldPort,
	registry: RaidVisionActorRegistry, scav: ZAIProfile, mutant: ZAIProfile,
	decision_budget: int = MAX_AGENTS) -> bool:
	if _generation != 0 or generation < 1 or world == null or not world.is_ready(generation) \
		or registry == null or not registry.is_active(generation) or scav == null or mutant == null \
		or not scav.is_valid() or not mutant.is_valid() or scav.archetype != "scav" or mutant.archetype != "mutant" \
		or decision_budget < 1 or decision_budget > MAX_AGENTS:
		return _reject(&"ai_runtime_configuration_invalid")
	_noise = RaidNoiseService.new()
	if not _noise.configure(raid_id, generation):
		return _reject(_noise.last_error)
	_generation = generation
	_seed = seed
	_world = world
	_registry = registry
	_profiles = {"scav": scav.duplicate(true), "mutant": mutant.duplicate(true)}
	_budget = decision_budget
	return true


## Driver registers this after the task-3 movement handler. Source frames are
## never handed to decisions: only own facts and recipient projections are.
func stage_after_movement(generation: int, tick: int) -> bool:
	if not _active(generation) or tick != _tick + 1 or _staged_tick >= tick:
		return _reject(&"ai_stage_order_invalid")
	var frame := _world.capture_vision_frame(generation, tick)
	if not ZAIValues.keys(frame, ["actors", "geometry_revision", "segments"]) \
		or not frame.actors is Array or not frame.segments is Array \
		or not ZAIValues.integer(frame.geometry_revision, 1, ZAIValues.MAX_TICK):
		return _fail(&"ai_world_frame_invalid")
	if not _registry.stage_frame(generation, tick, frame.actors, frame.geometry_revision, frame.segments):
		return _fail(_registry.last_error)
	_actors = {}
	for actor: Dictionary in frame.actors:
		if actor.archetype != "player":
			_actors[actor.entity_id] = actor.duplicate(true)
	if _actors.size() > MAX_AGENTS:
		return _fail(&"ai_agent_capacity")
	_staged_tick = tick
	return true


func decide(generation: int, tick: int) -> bool:
	if not _active(generation) or tick != _tick + 1 or _staged_tick != tick or _noise_tick != tick - 1 \
		or _registry.diagnostics().tick != tick:
		return _reject(&"ai_decision_order_invalid")
	var keys := _actors.keys()
	keys.sort()
	for key: String in _brains.keys():
		if not _actors.has(key):
			_remove(key)
	var own_frames: Dictionary = {}
	var knowledge_frames: Dictionary = {}
	for key: String in keys:
		var actor: Dictionary = _actors[key]
		if not _brains.has(key):
			var brain := ZAIAgent.new()
			var profile: ZAIProfile = _profiles[actor.archetype]
			var adapter := VisionAIAdapter.new()
			if not brain.configure(generation, key, profile, _seed, _world.patrol_points(key), _world.cover_points(key)) \
				or not adapter.configure(generation, key, _registry.native_id_for(generation, key)):
				return _fail(&"ai_actor_configuration_failed")
			_brains[key] = brain
			_adapters[key] = adapter
			_heard[key] = []
			_last_decision[key] = 0
		var own := _world.self_state(generation, tick, key)
		if not ZAIAgent.valid_self(own) or own.entity_id != key \
			or own.position_raw != actor.position_raw or own.alive != actor.alive:
			return _fail(&"ai_self_frame_mismatch")
		own_frames[key] = own
		var knowledge: Dictionary = _adapters[key].consume(generation, tick,
			_registry.projection_for(generation, key), _registry, _profiles[actor.archetype])
		if knowledge.get("ok") != true:
			return _fail(&"ai_knowledge_invalid")
		knowledge_frames[key] = knowledge
		var knowledge_state: String = "unknown"
		for fact: Dictionary in knowledge.facts:
			if fact.kind == &"visible":
				knowledge_state = "visible"
				break
			knowledge_state = "remembered"
		_knowledge_summary[key] = {"state": knowledge_state, "completed_tick": knowledge.completed_tick, "fresh": knowledge.fresh}
		var inbox: Array = _heard[key]
		for fact: Dictionary in _noise.observations_for(generation, key, tick):
			inbox.append(fact)
		inbox.sort_custom(_hearing_before)
		if inbox.size() > HEARING_INBOX:
			inbox.resize(HEARING_INBOX)
		_heard[key] = inbox
	# Oldest decision first, then stable identity: bounded deterministic fairness.
	keys.sort_custom(func(a: String, b: String) -> bool:
		return int(_last_decision[a]) < int(_last_decision[b]) \
			or (_last_decision[a] == _last_decision[b] and a < b))
	var selected: Array = []
	var alive_decisions: int = 0
	for key: String in keys:
		if not own_frames[key].alive or alive_decisions < _budget:
			selected.append(key)
			if own_frames[key].alive:
				alive_decisions += 1
	selected.sort()  # Intent order is stable independently of dictionary order.
	var outputs: Array = []
	for key: String in selected:
		var path: Dictionary = _rejected_paths[key] if _rejected_paths.has(key) else _world.poll_path_result(generation, tick, key)
		_rejected_paths.erase(key)
		var receipts := _world.take_action_results(generation, tick, key).duplicate(true)
		receipts.append_array(_rejected_actions.get(key, []))
		_rejected_actions.erase(key)
		var result: Dictionary = _brains[key].step(generation, tick, own_frames[key], knowledge_frames[key], _heard[key], path, receipts)
		if result.get("ok") != true:
			return _fail(&"ai_decision_failed")
		_heard[key] = []
		_last_decision[key] = tick
		outputs.append(result)
	var action_count: int = 0
	var rejection_count: int = 0
	for output: Dictionary in outputs:
		var key: String = output.actor_id
		if not output.path_request.is_empty() and not _world.submit_path_request(output.path_request):
			var request: Dictionary = output.path_request
			_rejected_paths[key] = {"request_id": request.request_id, "generation": generation,
				"actor_id": key, "resolved_tick": tick, "navigation_revision": request.navigation_revision,
				"ok": false, "points": []}
		for action: Dictionary in output.actions:
			action_count += 1
			var admission := _world.submit_action_request(action)
			if typeof(admission.get("admitted")) != TYPE_BOOL:
				return _fail(&"ai_intent_admission_invalid")
			if not admission.admitted:
				rejection_count += 1
				if action.kind in [&"fire", &"reload", &"melee"]:
					if not _rejected_actions.has(key):
						_rejected_actions[key] = []
					_rejected_actions[key].append({"request_id": action.request_id, "generation": generation,
						"actor_id": key, "resolved_tick": tick, "accepted": false})
	_tick = tick
	_metrics = {"tick": tick, "agents": keys.size(), "decisions": selected.size(),
		"deferred": keys.size() - selected.size(), "decision_budget": _budget,
		"actions": action_count, "admission_rejections": rejection_count}
	return true


func resolve_noise(generation: int, tick: int) -> bool:
	if not _active(generation) or tick != _tick or tick != _noise_tick + 1:
		return _reject(&"ai_noise_order_invalid")
	var events := _world.take_committed_noise(generation, tick)
	if events.size() > RaidNoiseService.MAX_EVENTS_PER_TICK:
		return _fail(&"ai_noise_batch_capacity")
	for event: Variant in events:
		if not event is Dictionary or not ZAIValues.keys(event, ["event_id", "source_id", "tick", "position_raw", "category", "intensity_milli"]) \
			or typeof(event.event_id) != TYPE_STRING or typeof(event.source_id) != TYPE_STRING \
			or event.tick != tick or not ZAIValues.position(event.position_raw) \
			or typeof(event.category) not in [TYPE_STRING, TYPE_STRING_NAME] \
			or not ZAIValues.integer(event.intensity_milli, 1, 1000):
			return _fail(&"ai_committed_noise_invalid")
		if not _noise.record_committed(generation, event.event_id, event.source_id, tick,
			event.position_raw, event.category, event.intensity_milli):
			return _fail(_noise.last_error)
	var listeners: Array = []
	for key: String in _actors:
		var own := _world.self_state(generation, tick, key)
		if not ZAIAgent.valid_self(own) or own.entity_id != key:
			return _fail(&"ai_noise_listener_invalid")
		if own.alive:
			listeners.append({"entity_id": key, "position_raw": own.position_raw,
				"minimum_strength_milli": _profiles[_actors[key].archetype].hearing_threshold_milli})
	if not _noise.resolve_tick(generation, tick, listeners):
		return _fail(_noise.last_error)
	_noise_tick = tick
	return true


func debug_snapshot() -> Dictionary:
	var entries: Array = []
	var keys := _brains.keys()
	keys.sort()
	for key: String in keys:
		var entry: Dictionary = _brains[key].debug_snapshot().duplicate(true)
		entry["observer_position_raw"] = _actors[key].position_raw
		entry["observer_facing_raw"] = _actors[key].facing_raw
		entry["archetype"] = _actors[key].archetype
		entry["vision"] = _knowledge_summary.get(key, {})
		entries.append(entry)
	return ZAIValues.frozen({"diagnostic_only": true, "generation": _generation,
		"tick": _tick, "agents": entries, "budget": _metrics,
		"noise": _noise.diagnostics() if _noise != null else {}, "failed": _failed, "released": _released})


func release(generation: int) -> bool:
	if generation != _generation or _generation == 0:
		return _reject(&"ai_runtime_generation_invalid")
	for key: String in _brains.keys():
		_remove(key)
	_noise.release(generation)
	_released = true
	_world = null
	_registry = null
	_actors = {}
	return true


func _remove(key: String) -> void:
	_brains[key].release(_generation)
	_adapters[key].release(_generation)
	for table: Dictionary in [_brains, _adapters, _heard, _last_decision, _knowledge_summary, _rejected_actions, _rejected_paths]:
		table.erase(key)


static func _hearing_before(a: Dictionary, b: Dictionary) -> bool:
	return a.emitted_tick > b.emitted_tick or (a.emitted_tick == b.emitted_tick \
		and (a.strength_milli > b.strength_milli or (a.strength_milli == b.strength_milli and a.observation_id < b.observation_id)))


func _active(generation: int) -> bool:
	return _generation > 0 and generation == _generation and not _released and not _failed \
		and _world != null and _world.is_ready(generation) and _registry != null and _registry.is_active(generation)


func _fail(reason: StringName) -> bool:
	_failed = true
	return _reject(reason)


func _reject(reason: StringName) -> bool:
	last_error = reason
	return false
