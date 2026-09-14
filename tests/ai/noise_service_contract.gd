extends SceneTree
## Task 6.7: no native add-ons, rendering, audio server, or world scene required.
## godot --headless --path . --script res://tests/ai/noise_service_contract.gd

const U: int = ZWorldUnits.VISION_MICROUNITS_PER_WORLD_UNIT
const RAID := "zerkov.raid.noise.contract"
const SOURCE := "zerkov.entity.noise.source"
const LISTENER := "zerkov.entity.noise.listener"
const EVENT := "zerkov.consequence.noise.event"
var checks: int = 0
var failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_configuration_and_lifecycle()
	_categories_and_falloff()
	_admission_and_retry()
	_listener_validation()
	_private_historical_facts()
	_capacity_and_replay()
	_coordinate_extremes()
	print("NOISE_SERVICE_RESULT checks=", checks, " failures=", failures)
	quit(0 if failures == 0 else 1)


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("NOISE_SERVICE: " + message)


func _service(events: int = 64, listeners: int = 64, history: int = 8192) -> RaidNoiseService:
	var service := RaidNoiseService.new()
	_check(service.configure(RAID, 1, events, listeners, history), "configure service")
	return service


func _listener(key: String = LISTENER, position: Vector2i = Vector2i.ZERO,
		minimum: int = 1) -> Dictionary:
	return {"entity_id": key, "position_raw": position, "minimum_strength_milli": minimum}


func _emit(service: RaidNoiseService, key: String = EVENT, tick: int = 1,
		position: Vector2i = Vector2i.ZERO, category: StringName = &"gunshot",
		intensity: int = 1000, source: String = SOURCE, generation: int = 1,
		policy: StringName = RaidNoiseService.PROPAGATION) -> bool:
	return service.record_committed(generation, key, source, tick, position,
		category, intensity, policy)


func _configuration_and_lifecycle() -> void:
	var service := RaidNoiseService.new()
	_check(not _emit(service), "unconfigured ingress rejected")
	_check(not service.resolve_tick(1, 1, []), "unconfigured resolve rejected")
	_check(service.observations_for(1, LISTENER, 1).is_empty(), "no unconfigured facts")
	_check(not service.configure("bad", 1), "invalid raid identity")
	_check(not service.configure(RAID, 0), "invalid generation")
	_check(not service.configure(RAID, 1, 0), "zero event limit")
	_check(not service.configure(RAID, 1, 65), "hard event limit")
	_check(not service.configure(RAID, 1, 64, 65), "hard listener limit")
	_check(not service.configure(RAID, 1, 64, 64, 63), "history must fit one frame")
	_check(not service.configure(RAID, 1, 64, 64, 8193), "hard history limit")
	_check(service.configure(RAID, 1), "invalid configuration leaves retry possible")
	_check(not service.configure(RAID, 2), "cannot reconfigure active owner")
	_check(service.resolve_tick(1, 1, [_listener()]), "resolve empty tick")
	_check(service.observations_for(1, LISTENER, 2).is_empty(), "no audio-only facts")
	_check(not service.release(2), "wrong generation cannot release")
	_check(service.release(1) and service.release(1), "release is idempotent")
	_check(not _emit(service, EVENT, 2), "released owner rejects noise")
	_check(not service.resolve_tick(1, 2, []), "released owner rejects ticks")
	_check(service.observations_for(1, LISTENER, 2).is_empty(), "released owner rejects queries")
	_check(not service.configure(RAID, 2), "release requires fresh owner for new raid")


func _categories_and_falloff() -> void:
	for category: StringName in [&"gunshot", &"impact", &"sprint", &"interaction"]:
		var service := _service()
		var radius := RaidNoiseService.radius_for_category(category)
		_check(radius > 0 and _emit(service, EVENT, 1, Vector2i.ZERO, category),
			"supported category: " + String(category))
		var samples: Array = [_listener(),
			_listener(LISTENER + ".half", Vector2i(radius / 2, 0)),
			_listener(LISTENER + ".edge", Vector2i(radius, 0)),
			_listener(LISTENER + ".outside", Vector2i(radius + 1, 0)),
			_listener(SOURCE)]
		_check(service.resolve_tick(1, 1, samples), "resolve category")
		_check(service.observations_for(1, LISTENER, 2)[0].strength_milli == 1000,
			"coincident event has full intensity")
		_check(service.observations_for(1, LISTENER + ".half", 2)[0].strength_milli == 750,
			"squared-distance falloff at half radius")
		_check(service.observations_for(1, LISTENER + ".edge", 2).is_empty(), "radius exclusive")
		_check(service.observations_for(1, LISTENER + ".outside", 2).is_empty(), "outside inaudible")
		_check(service.observations_for(1, SOURCE, 2).is_empty(), "source does not hear itself")
	var service := _service()
	_check(_emit(service, EVENT, 1, Vector2i.ZERO, &"gunshot", 400), "reduced intensity")
	_check(service.resolve_tick(1, 1, [_listener(LISTENER, Vector2i(12 * U, 0), 300),
		_listener(LISTENER + ".quiet", Vector2i(12 * U, 0), 301)]), "threshold listeners")
	_check(service.observations_for(1, LISTENER, 2)[0].strength_milli == 300,
		"threshold is inclusive and scales intensity")
	_check(service.observations_for(1, LISTENER + ".quiet", 2).is_empty(), "threshold suppresses fact")


func _admission_and_retry() -> void:
	var service := _service()
	_check(not _emit(service, "bad"), "invalid event identity")
	_check(not _emit(service, EVENT, 1, Vector2i.ZERO, &"gunshot", 1000, "bad"), "invalid source")
	_check(not _emit(service, EVENT, 0), "zero tick")
	_check(not _emit(service, EVENT, 2), "future tick")
	_check(not _emit(service, EVENT, RaidNoiseService.MAX_TICK), "reserve room for decision tick")
	_check(not _emit(service, EVENT, 1, Vector2i.ZERO, &"cosmetic"), "cosmetic audio is not noise")
	_check(not _emit(service, EVENT, 1, Vector2i.ZERO, &"gunshot", 0), "zero intensity")
	_check(not _emit(service, EVENT, 1, Vector2i.ZERO, &"gunshot", 1001), "intensity cap")
	_check(not _emit(service, EVENT, 1, Vector2i.ZERO, &"gunshot", 1000, SOURCE, 2), "stale generation")
	_check(not _emit(service, EVENT, 1, Vector2i.ZERO, &"gunshot", 1000, SOURCE, 1, &"vision"),
		"unknown propagation rejected")
	_check(service.diagnostics().history_events == 0, "bad events reserve no history")
	_check(_emit(service) and _emit(service), "identical retry accepted")
	_check(service.diagnostics().pending_events == 1, "retry does not duplicate")
	_check(not _emit(service, EVENT, 1, Vector2i(1, 0)), "changed origin conflicts")
	_check(not _emit(service, EVENT, 1, Vector2i.ZERO, &"impact"), "changed category conflicts")
	_check(service.resolve_tick(1, 1, [_listener()]), "resolve accepted event")
	_check(_emit(service), "past exact retry is a no-op")
	_check(service.diagnostics().pending_events == 0, "retry does not re-emit")
	_check(not _emit(service, EVENT + ".late", 1), "new past event rejected")
	_check(service.observations_for(1, LISTENER, 1).is_empty(), "not visible to same-tick AI")
	_check(service.observations_for(2, LISTENER, 2).is_empty(), "wrong query generation")
	_check(service.observations_for(1, LISTENER, 2).size() == 1, "one next-tick observation")
	_check(service.resolve_tick(1, 2, [_listener()]), "advance quiet tick")
	_check(service.observations_for(1, LISTENER, 2).is_empty(), "stale decision tick rejected")
	_check(service.observations_for(1, LISTENER, 3).is_empty(), "facts expire after one decision tick")


func _listener_validation() -> void:
	var service := _service()
	_check(_emit(service), "pending event for listener rejection tests")
	var wrong: Array = [null, 1, {}, _listener("bad"), _listener(LISTENER, Vector2i.ZERO, 0)]
	var float_position := _listener()
	float_position.position_raw = Vector2.ZERO
	wrong.append(float_position)
	var bool_threshold := _listener()
	bool_threshold.minimum_strength_milli = true
	wrong.append(bool_threshold)
	var extra := _listener()
	extra.hidden_target = SOURCE
	wrong.append(extra)
	for row: Variant in wrong:
		_check(not service.resolve_tick(1, 1, [row]), "invalid listener rejected")
		_check(service.diagnostics().pending_events == 1 and service.diagnostics().resolved_tick == 0,
			"bad listener does not consume events or tick")
	_check(not service.resolve_tick(1, 1, [_listener(), _listener()]), "duplicate listener")
	_check(not service.resolve_tick(2, 1, [_listener()]), "wrong resolve generation")
	_check(not service.resolve_tick(1, 2, [_listener()]), "skip resolve tick")
	_check(service.resolve_tick(1, 1, [_listener()]), "repair listeners and resolve")
	_check(not service.resolve_tick(1, 1, [_listener()]), "cannot resolve twice")
	_check(service.observations_for(1, "bad", 2).is_empty(), "bad listener query")


func _private_historical_facts() -> void:
	var service := _service()
	var origin := Vector2i(-1, U + 1)
	_check(_emit(service, EVENT, 1, origin), "negative-coordinate event")
	var listener := _listener(LISTENER, origin)
	_check(service.resolve_tick(1, 1, [listener]), "resolve private fact")
	var facts := service.observations_for(1, LISTENER, 2)
	var fact: Dictionary = facts[0]
	_check(facts.is_read_only() and fact.is_read_only(), "immutable publication")
	_check(fact.origin_min_raw == Vector2i(-U, U) and fact.origin_size_raw == Vector2i(U, U),
		"negative origin rounds down into historical uncertainty cell")
	_check(fact.observation_kind == &"audible" and fact.visual_confirmation == false,
		"hearing is not a visual confirmation")
	_check(fact.raid_id == RAID and fact.generation == 1 and fact.valid_for_tick == 2,
		"retained value carries owner and decision epoch")
	for hidden_field: String in ["source_key", "entity_id", "position_raw", "target", "health", "velocity"]:
		_check(not fact.has(hidden_field), "hidden field absent: " + hidden_field)
	listener.position_raw = Vector2i(100 * U, 100 * U)
	_check(service.observations_for(1, LISTENER, 2) == facts, "caller cannot move past observation")
	_check(service.resolve_tick(1, 2, []), "remove listener")
	_check(service.observations_for(1, LISTENER, 3).is_empty(), "removed listener has no fresh facts")
	_check(fact.origin_min_raw == Vector2i(-U, U), "retained snapshot remains historical")
	_check(service.diagnostics().is_read_only(), "diagnostics are read-only")


func _capacity_and_replay() -> void:
	var service := _service(1, 1, 1)
	_check(_emit(service), "last available history slot")
	_check(not _emit(service, EVENT + ".overflow"), "per-tick event bound")
	_check(_emit(service), "retry works at capacity")
	_check(not service.resolve_tick(1, 1, [_listener(), _listener(LISTENER + ".extra")]),
		"listener work bound")
	_check(service.resolve_tick(1, 1, [_listener()]), "full tick resolves")
	_check(not _emit(service, EVENT + ".next", 2), "history exhausted: explicit failure, no eviction")
	_check(service.last_error == &"noise_history_capacity_exhausted", "history exhaustion diagnostic")
	_check(service.diagnostics().pending_events == 0, "capacity rejection is atomic")
	var normal := _service()
	var reversed := _service()
	var listeners: Array = []
	for index in range(64):
		listeners.append(_listener(LISTENER + ".n%d" % index))
		_check(_emit(normal, EVENT + ".n%d" % index), "normal ordered event")
		_check(_emit(reversed, EVENT + ".n%d" % (63 - index)), "reverse ordered event")
	_check(normal.resolve_tick(1, 1, listeners), "maximum work frame")
	listeners.reverse()
	_check(reversed.resolve_tick(1, 1, listeners), "reverse work frame")
	_check(normal.diagnostics().pair_checks == 4096 and normal.diagnostics().pair_budget == 4096,
		"maximum pair work is 64x64")
	for row: Dictionary in listeners:
		_check(normal.observations_for(1, row.entity_id, 2) == reversed.observations_for(1, row.entity_id, 2),
			"same ordered facts independent of producer and listener insertion order")


func _coordinate_extremes() -> void:
	var service := _service()
	var limit := RaidNoiseService.COORDINATE_LIMIT
	_check(not _emit(service, EVENT, 1, Vector2i(limit + 1, 0)), "coordinate cap")
	_check(not _emit(service, EVENT, 1, Vector2i(-2_147_483_648, 0)), "int32 minimum rejected safely")
	_check(_emit(service, EVENT, 1, Vector2i(-limit, -limit)), "minimum supported position")
	_check(not service.resolve_tick(1, 1, [_listener(LISTENER, Vector2i(limit + 1, 0))]),
		"listener coordinate cap")
	_check(service.resolve_tick(1, 1, [_listener(LISTENER, Vector2i(limit, limit)),
		_listener(LISTENER + ".near", Vector2i(-limit, -limit))]), "extreme diagonal positions")
	_check(service.observations_for(1, LISTENER, 2).is_empty(), "64-bit subtraction prevents wrapped audibility")
	_check(service.observations_for(1, LISTENER + ".near", 2).size() == 1, "coincident extreme is audible")
