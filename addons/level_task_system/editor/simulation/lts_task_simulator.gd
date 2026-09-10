class_name LtsTaskSimulator
extends RefCounted

## Headless editor simulator for one task graph instance.
##
## This class is intentionally free of EditorInterface, Control, Resource
## mutation, and game authority state.  It owns only a copied queue of typed
## synthetic inputs and a local native-runtime handle.  The native runtime is
## the source of truth for compilation, advancement, requests, statuses, and
## trace records.  When that binding is not registered, all runtime-mutating
## operations fail closed with a stable diagnostic.

const RuntimeBridge := preload("res://addons/level_task_system/editor/simulation/lts_task_runtime_bridge.gd")

const TRACE_SCHEMA_VERSION := 1
const TRACE_KIND := "level_task_system.simulation_trace"
const DOCUMENT_SCHEMA_VERSION := 1

const NATIVE_UNAVAILABLE_CODE := RuntimeBridge.NATIVE_UNAVAILABLE_CODE
const GRAPH_INVALID_CODE := "LTS-SIM-GRAPH-001"
const EVENT_INVALID_CODE := "LTS-SIM-EVENT-001"
const FACT_INVALID_CODE := "LTS-SIM-FACT-001"
const LIMIT_CODE := "LTS-SIM-LIMIT-001"
const RUNTIME_ERROR_CODE := "LTS-SIM-RUNTIME-001"
const NOT_STARTED_CODE := "LTS-SIM-RUNTIME-002"
const TRACE_ERROR_CODE := "LTS-SIM-TRACE-001"

const MAX_FACTS := 256
const MAX_QUEUED_EVENTS := 128
const MAX_EVENTS_PER_STEP := 128
const MAX_TRACE_RECORDS := 1024
const MAX_STEP_RECORDS := 1024
const MAX_DIAGNOSTICS := 16
const MAX_IDENTIFIER_BYTES := 128
const MAX_STRING_BYTES := 256
const MAX_VALUE_BYTES := 1024
const MAX_FILTERS_PER_EVENT := 16
const MAX_RUN_STEPS := 1024
const MAX_TRACE_BYTES := 1024 * 1024

const DEFAULT_LIMITS: Dictionary = {
	"max_facts_per_snapshot": 256,
	"max_events_per_advance": 128,
	"max_transitions_per_advance": 1024,
	"max_pending_requests": 64,
	"max_transition_records": 512,
	"max_state_change_records": 512,
	"max_trace_records": 1024,
	"max_resolved_request_records": 256,
	"request_timeout_ticks": 0,
}

const VALUE_TYPES: PackedStringArray = [
	"none", "boolean", "integer", "fixed", "string", "identifier", "bytes",
]

signal state_changed(state: Dictionary)
signal step_completed(result: Dictionary)
signal trace_changed(records: Array)

var _bridge: RefCounted
var _graph: Variant = null
var _compiled_graph: Variant = null
var _runtime: Variant = null
var _graph_identifier := ""
var _instance_identifier := "editor.simulation.instance"
var _scope_key := "editor.simulation"
var _limits: Dictionary = DEFAULT_LIMITS.duplicate(true)

var _facts: Dictionary = {}
var _queued_events: Array = []
var _trace: Array = []
var _steps: Array = []
var _diagnostics: Array = []
var _trace_keys: Dictionary = {}
var _runtime_state: Dictionary = {}
var _last_result: Dictionary = {}
var _availability: Dictionary = {}
var _started := false
var _tick := -1


func _init(bridge: Variant = null, graph: Variant = null, scope_key: String = "") -> void:
	_bridge = RuntimeBridge.new()
	if bridge != null:
		set_runtime_bridge(bridge)
	if not scope_key.is_empty():
		_scope_key = scope_key
	if graph != null:
		set_graph(graph)


## Install an explicit bridge or backend before starting.  Replacing a live
## runtime would make an editor trace ambiguous, so it is rejected while
## started.  A backend object is wrapped by LtsTaskRuntimeBridge.
func set_runtime_bridge(bridge: Variant) -> Dictionary:
	if _started:
		return _failure(RUNTIME_ERROR_CODE, "The runtime bridge cannot change while simulation is running.", "runtime_bridge")
	if bridge == null:
		_bridge = RuntimeBridge.new()
		_availability.clear()
		return _success({"bridge": "discovered"})
	if bridge is Object and bridge.get_script() == RuntimeBridge:
		_bridge = bridge
		_availability.clear()
		return _success({"bridge": "explicit"})
	if bridge is Callable or not bridge is Object:
		return _failure(RuntimeBridge.BRIDGE_BACKEND_CODE, "Runtime bridge must be an object, not a Callable or scalar.", "runtime_bridge")
	var candidate := RuntimeBridge.new()
	var configured := candidate.set_backend(bridge)
	if not bool(configured.get("ok", false)):
		_availability = configured.duplicate(true)
		return _failure_from_bridge(configured)
	_bridge = candidate
	_availability = configured.duplicate(true)
	return _success({"bridge": "backend", "backend": configured.get("backend", "")})


func set_runtime_backend(backend: Variant) -> Dictionary:
	return set_runtime_bridge(backend)


func set_native_runtime(backend: Variant) -> Dictionary:
	return set_runtime_bridge(backend)


func get_runtime_bridge() -> RefCounted:
	return _bridge


func runtime_availability() -> Dictionary:
	_availability = _bridge.availability().duplicate(true)
	return _availability.duplicate(true)


func native_runtime_available() -> bool:
	return bool(runtime_availability().get("available", false))


func is_native_runtime_available() -> bool:
	return native_runtime_available()


func is_isolated() -> bool:
	return true


func is_started() -> bool:
	return _started


func is_running() -> bool:
	if not _started:
		return false
	var status = _runtime_state.get("graph_status", _runtime_state.get("status", "RUNNING"))
	if status is int:
		return int(status) == 1
	return _as_text(status).to_upper() == "RUNNING"


func get_graph() -> Variant:
	return _duplicate_input(_graph)


func get_graph_identifier() -> String:
	return _graph_identifier


func set_graph(graph: Variant) -> Dictionary:
	if _started:
		return _failure(RUNTIME_ERROR_CODE, "The graph cannot change while simulation is running.", "graph")
	if graph == null:
		_graph = null
		_compiled_graph = null
		_graph_identifier = ""
		return _success({"graph": null})
	if graph is Callable:
		return _failure(GRAPH_INVALID_CODE, "Task graph definitions cannot be Callables.", "graph")
	if not graph is Dictionary and not graph is Resource and not graph is Object:
		return _failure(GRAPH_INVALID_CODE, "Task graph must be a dictionary or a native definition Resource.", "graph")
	if graph is Object and not graph is Resource:
		return _failure(GRAPH_INVALID_CODE, "Task graph object is not a definition Resource.", "graph")
	_graph = _duplicate_input(graph)
	_graph_identifier = _read_graph_identifier(_graph)
	_compiled_graph = null
	return _success({"graph_identifier": _graph_identifier})


func set_graph_definition(graph: Variant) -> Dictionary:
	return set_graph(graph)


func load_graph(graph: Variant) -> Dictionary:
	return set_graph(graph)


func set_instance_identifier(identifier: String) -> Dictionary:
	if _started:
		return _failure(RUNTIME_ERROR_CODE, "The instance identifier cannot change while simulation is running.", "instance_identifier")
	var value := identifier.strip_edges()
	if value.is_empty() or not _bounded_text(value, MAX_IDENTIFIER_BYTES):
		return _failure(GRAPH_INVALID_CODE, "Instance identifier must be a bounded, non-empty identifier.", "instance_identifier")
	_instance_identifier = value
	return _success({"instance_identifier": _instance_identifier})


func get_instance_identifier() -> String:
	return _instance_identifier


func set_scope_key(scope_key: String) -> Dictionary:
	if _started:
		return _failure(RUNTIME_ERROR_CODE, "The scope key cannot change while simulation is running.", "scope_key")
	var value := scope_key.strip_edges()
	if value.is_empty() or not _bounded_text(value, MAX_IDENTIFIER_BYTES):
		return _failure(GRAPH_INVALID_CODE, "Scope key must be a bounded, non-empty identifier.", "scope_key")
	_scope_key = value
	return _success({"scope_key": _scope_key})


func get_scope_key() -> String:
	return _scope_key


func set_limits(limits: Dictionary) -> Dictionary:
	if _started:
		return _failure(RUNTIME_ERROR_CODE, "Runtime limits cannot change while simulation is running.", "limits")
	var candidate := _limits.duplicate(true)
	for key in limits:
		var name := _as_text(key)
		if not DEFAULT_LIMITS.has(name):
			return _failure(LIMIT_CODE, "Unknown runtime limit '%s'." % name, "limits.%s" % name)
		var raw = limits[key]
		if raw is bool or not raw is int or int(raw) < 0:
			return _failure(LIMIT_CODE, "Runtime limit '%s' must be a non-negative integer." % name, "limits.%s" % name)
		candidate[name] = int(raw)
	var error := _validate_limits(candidate)
	if not error.is_empty():
		return _failure(LIMIT_CODE, _as_text(error.get("message", "Runtime limit is invalid.")), _as_text(error.get("path", "limits")))
	_limits = candidate
	return _success({"limits": _limits.duplicate(true)})


func get_limits() -> Dictionary:
	return _limits.duplicate(true)


## Start the native instance.  Passing a graph to this overload is convenient
## for the command bar; callers may set_graph() first and call start().
func start(graph: Variant = null) -> Dictionary:
	if graph != null:
		var loaded := set_graph(graph)
		if not bool(loaded.get("ok", false)):
			return loaded
	if _started:
		return _success({"already_started": true, "state": get_state()})
	if _graph == null:
		return _failure(GRAPH_INVALID_CODE, "No task graph definition is loaded.", "graph")
	if _graph_identifier.is_empty():
		return _failure(GRAPH_INVALID_CODE, "Task graph has no stable identifier.", "graph.identifier")
	var availability: Dictionary = _bridge.availability()
	_availability = availability.duplicate(true)
	if not bool(availability.get("available", false)):
		_record_bridge_diagnostic(availability)
		return _failure_from_bridge(availability)
	var compiled_result: Dictionary = _bridge.compile_graph(_duplicate_input(_graph))
	if not bool(compiled_result.get("ok", false)):
		return _runtime_failure(compiled_result, "compile_graph")
	var compiled = compiled_result.get("compiled", _graph)
	var start_result: Dictionary = _bridge.start(
		_duplicate_input(compiled),
		_instance_identifier,
		_scope_key,
		_limits.duplicate(true),
	)
	if not bool(start_result.get("ok", false)):
		return _runtime_failure(start_result, "start")
	var runtime_value = start_result.get("runtime", null)
	if runtime_value == null and start_result.has("instance"):
		runtime_value = start_result.get("instance")
	if runtime_value == null:
		return _failure(RuntimeBridge.NATIVE_SURFACE_CODE, "Native start returned no runtime instance.", "runtime.start")
	_compiled_graph = _duplicate_input(compiled)
	_runtime = runtime_value
	_started = true
	_tick = -1
	_trace.clear()
	_steps.clear()
	_diagnostics.clear()
	_trace_keys.clear()
	_last_result.clear()
	_runtime_state = _state_from_result(start_result)
	_refresh_runtime_state()
	_consume_operation_result("start", start_result, [], _tick)
	return _success({
		"started": true,
		"compiled": bool(compiled_result.get("deferred", false)) == false,
		"result": _safe_for_export(start_result),
		"state": get_state(),
	})


func start_instance(graph: Variant = null) -> Dictionary:
	return start(graph)


## Reset starts a fresh native instance from the same immutable graph.  Inputs
## and retained records are cleared by default so the exported trace has no
## hidden pre-reset history.  `preserve_inputs` is useful for a repeatable
## editor experiment and still copies the input queues before restarting.
func reset(preserve_inputs: bool = false) -> Dictionary:
	if _graph == null:
		_started = false
		_runtime = null
		_runtime_state.clear()
		_trace.clear()
		_steps.clear()
		_diagnostics.clear()
		_trace_keys.clear()
		return _failure(GRAPH_INVALID_CODE, "No task graph definition is loaded.", "graph")
	var facts_before := _facts.duplicate(true)
	var events_before := _queued_events.duplicate(true)
	_started = false
	_runtime = null
	_compiled_graph = null
	_runtime_state.clear()
	_last_result.clear()
	_tick = -1
	_trace.clear()
	_steps.clear()
	_diagnostics.clear()
	_trace_keys.clear()
	if preserve_inputs:
		_facts = facts_before
		_queued_events = events_before
	else:
		_facts.clear()
		_queued_events.clear()
	return start()


func reset_simulation(preserve_inputs: bool = false) -> Dictionary:
	return reset(preserve_inputs)


func stop() -> Dictionary:
	_started = false
	_runtime = null
	_compiled_graph = null
	_runtime_state.clear()
	_tick = -1
	return _success({"stopped": true, "state": get_state()})


## Set or replace one synthetic closed fact.  The overload accepts either a
## full fact dictionary or `(provider_identifier, fact_identifier, value)`.
func set_fact(fact_or_provider: Variant, fact_identifier: Variant = null, value: Variant = null) -> Dictionary:
	var source: Dictionary
	if fact_or_provider is Dictionary:
		source = fact_or_provider.duplicate(true)
	else:
		source = {
			"provider_identifier": String(fact_or_provider),
			"fact_identifier": String(fact_identifier) if fact_identifier != null else "",
			"value": value,
		}
	var normalized := _normalize_fact(source, "facts")
	if not bool(normalized.get("ok", false)):
		return normalized
	var record: Dictionary = normalized["fact"]
	var key := _fact_key(record)
	_facts[key] = record
	return _success({"fact": _safe_for_export(record), "facts": get_facts(), "state": get_state()})


func add_fact(fact_or_provider: Variant, fact_identifier: Variant = null, value: Variant = null) -> Dictionary:
	return set_fact(fact_or_provider, fact_identifier, value)


func set_facts(facts: Variant) -> Dictionary:
	if not facts is Array and not facts is Dictionary:
		return _failure(FACT_INVALID_CODE, "Synthetic facts must be an Array of fact records or a Dictionary.", "facts")
	var candidate: Dictionary = {}
	var values: Array = facts if facts is Array else []
	if facts is Dictionary:
		for key in facts:
			var raw = facts[key]
			if raw is Dictionary:
				var record: Dictionary = raw.duplicate(true)
				if not record.has("fact_identifier"):
					record["fact_identifier"] = _as_text(key)
				values.append(record)
			else:
				values.append({"fact_identifier": _as_text(key), "value": raw})
	if values.size() > MAX_FACTS:
		return _failure(LIMIT_CODE, "Synthetic fact count exceeds the simulator bound of %d." % MAX_FACTS, "facts")
	for index in range(values.size()):
		var normalized := _normalize_fact(values[index], "facts[%d]" % index)
		if not bool(normalized.get("ok", false)):
			return normalized
		var record: Dictionary = normalized["fact"]
		var key := _fact_key(record)
		if candidate.has(key):
			return _failure(FACT_INVALID_CODE, "Synthetic fact keys must be unique in one snapshot.", "facts[%d]" % index)
		candidate[key] = record
	_facts = candidate
	return _success({"facts": get_facts(), "state": get_state()})


func clear_facts() -> Dictionary:
	_facts.clear()
	return _success({"facts": [], "state": get_state()})


func get_facts() -> Array:
	var keys: Array = _facts.keys()
	keys.sort()
	var result: Array = []
	for key in keys:
		result.append(_safe_for_export(_facts[key]))
	return result


func inject_event(event_or_provider: Variant, event_identifier: Variant = null, value: Variant = null, amount: Variant = 1, sequence: Variant = 0) -> Dictionary:
	var source: Dictionary
	if event_or_provider is Dictionary:
		source = event_or_provider.duplicate(true)
	else:
		source = {
			"provider_identifier": String(event_or_provider),
			"event_identifier": String(event_identifier) if event_identifier != null else "",
			"value": value,
			"amount": amount,
			"sequence": sequence,
		}
	var normalized := _normalize_event(source, "events[%d]" % _queued_events.size())
	if not bool(normalized.get("ok", false)):
		return normalized
	if _queued_events.size() >= MAX_QUEUED_EVENTS:
		return _failure(LIMIT_CODE, "Queued synthetic event count exceeds the simulator bound of %d." % MAX_QUEUED_EVENTS, "events")
	_queued_events.append(normalized["event"])
	return _success({"event": _safe_for_export(normalized["event"]), "queued_events": get_queued_events(), "state": get_state()})


func queue_event(event_or_provider: Variant, event_identifier: Variant = null, value: Variant = null, amount: Variant = 1, sequence: Variant = 0) -> Dictionary:
	return inject_event(event_or_provider, event_identifier, value, amount, sequence)


func inject_events(events: Array) -> Dictionary:
	if events.size() > MAX_QUEUED_EVENTS - _queued_events.size():
		return _failure(LIMIT_CODE, "Queued synthetic events exceed the simulator bound of %d." % MAX_QUEUED_EVENTS, "events")
	var candidate: Array = []
	for index in range(events.size()):
		var normalized := _normalize_event(events[index], "events[%d]" % index)
		if not bool(normalized.get("ok", false)):
			return normalized
		candidate.append(normalized["event"])
	_queued_events.append_array(candidate)
	return _success({"queued_events": get_queued_events(), "state": get_state()})


func clear_events() -> Dictionary:
	_queued_events.clear()
	return _success({"queued_events": [], "state": get_state()})


func get_queued_events() -> Array:
	var result: Array = []
	for event in _queued_events:
		result.append(_safe_for_export(event))
	return result


## Advance exactly one event (or one empty tick when the queue is empty).  A
## dictionary/array passed as the first argument is treated as an explicit
## event input for ergonomic use from the drawer.
func step(tick: Variant = null, events: Variant = null) -> Dictionary:
	if tick is Dictionary or tick is Array:
		events = tick
		tick = null
	if not _started:
		return _failure(NOT_STARTED_CODE, "Start the isolated simulator before stepping.", "simulation.step")
	var next_tick := _next_tick(tick)
	if next_tick < 0:
		return _failure(EVENT_INVALID_CODE, "Simulation tick must be a non-negative integer.", "simulation.tick")
	var supplied_events: Array = []
	var consume_queued := events == null
	if consume_queued:
		if not _queued_events.is_empty():
			supplied_events.append(_queued_events[0].duplicate(true))
	else:
		var input_events: Array = events if events is Array else [events]
		if input_events.size() > MAX_EVENTS_PER_STEP:
			return _failure(LIMIT_CODE, "Step event count exceeds the simulator bound of %d." % MAX_EVENTS_PER_STEP, "events")
		for index in range(input_events.size()):
			var normalized := _normalize_event(input_events[index], "events[%d]" % index)
			if not bool(normalized.get("ok", false)):
				return normalized
			supplied_events.append(normalized["event"])
	var result: Dictionary = _bridge.advance(
		_runtime,
		_duplicate_input(supplied_events),
		_duplicate_input(get_facts()),
		next_tick,
	)
	if not bool(result.get("ok", false)):
		return _runtime_failure(result, "advance")
	if consume_queued and not _queued_events.is_empty():
		_queued_events.remove_at(0)
	_tick = next_tick
	var operation := _consume_operation_result("step", result, supplied_events, next_tick)
	var response := _success({
		"tick": _tick,
		"events": _safe_for_export(supplied_events),
		"result": _safe_for_export(result),
		"step": operation,
		"state": get_state(),
	})
	_last_result = response.duplicate(true)
	step_completed.emit(response.duplicate(true))
	return response


func step_simulation(tick: Variant = null, events: Variant = null) -> Dictionary:
	return step(tick, events)


## Run drains the queued event list, bounded by the native/runtime limit and a
## simulator-side maximum.  Empty queues are idle rather than an invitation to
## tick forever; external requests must be resolved explicitly.
func run(max_steps: int = -1) -> Dictionary:
	if not _started:
		return _failure(NOT_STARTED_CODE, "Start the isolated simulator before running.", "simulation.run")
	if max_steps == 0 or max_steps < -1:
		return _failure(LIMIT_CODE, "Run step bound must be -1 or a positive integer.", "simulation.max_steps")
	var bound := MAX_RUN_STEPS if max_steps < 0 else mini(max_steps, MAX_RUN_STEPS)
	var completed := 0
	while not _queued_events.is_empty() and completed < bound:
		var result := step()
		if not bool(result.get("ok", false)):
			return result
		completed += 1
	if not _queued_events.is_empty():
		return _failure(LIMIT_CODE, "Run stopped at the bounded step limit with events still queued.", "simulation.max_steps", {"completed": completed, "remaining_events": _queued_events.size()})
	return _success({
		"steps": completed,
		"idle": true,
		"state": get_state(),
	})


func run_until_idle(max_steps: int = -1) -> Dictionary:
	return run(max_steps)


func acknowledge_request(request_identifier: String, outcome_identifier: String = "", response: Variant = null, tick: Variant = null, expected_revision: int = -1) -> Dictionary:
	return _resolve_request("acknowledge", request_identifier, outcome_identifier, response, tick, expected_revision)


func reject_request(request_identifier: String, response: Variant = null, tick: Variant = null, expected_revision: int = -1) -> Dictionary:
	return _resolve_request("reject", request_identifier, "", response, tick, expected_revision)


func timeout_request(request_identifier: String, tick: Variant = null, expected_revision: int = -1) -> Dictionary:
	return _resolve_request("timeout", request_identifier, "", null, tick, expected_revision)


func _resolve_request(operation: String, request_identifier: String, outcome_identifier: String, response: Variant, tick: Variant, expected_revision: int) -> Dictionary:
	if not _started:
		return _failure(NOT_STARTED_CODE, "Start the isolated simulator before resolving requests.", "simulation.%s" % operation)
	if request_identifier.strip_edges().is_empty() or not _bounded_text(request_identifier, MAX_IDENTIFIER_BYTES):
		return _failure(EVENT_INVALID_CODE, "Request identifier must be a bounded, non-empty identifier.", "request_identifier")
	var next_tick := _next_tick(tick)
	if next_tick < 0:
		return _failure(EVENT_INVALID_CODE, "Simulation tick must be a non-negative integer.", "simulation.tick")
	var typed_response := {"type": "none"}
	if response != null:
		var normalized_value := _normalize_typed_value(response, "response")
		if not bool(normalized_value.get("ok", false)):
			return normalized_value
		typed_response = normalized_value["value"]
	var result: Dictionary
	match operation:
		"acknowledge":
			result = _bridge.acknowledge_request(_runtime, request_identifier, outcome_identifier, typed_response, next_tick, expected_revision)
		"reject":
			result = _bridge.reject_request(_runtime, request_identifier, typed_response, next_tick, expected_revision)
		"timeout":
			result = _bridge.timeout_request(_runtime, request_identifier, next_tick, expected_revision)
		_:
			return _failure(RUNTIME_ERROR_CODE, "Unknown request resolution operation.", "simulation.%s" % operation)
	if not bool(result.get("ok", false)):
		return _runtime_failure(result, operation)
	_tick = next_tick
	var operation_record := _consume_operation_result(operation, result, [], next_tick)
	var response_result := _success({
		"tick": _tick,
		"request_identifier": request_identifier,
		"result": _safe_for_export(result),
		"step": operation_record,
		"state": get_state(),
	})
	_last_result = response_result.duplicate(true)
	step_completed.emit(response_result.duplicate(true))
	return response_result


func get_state() -> Dictionary:
	var result: Dictionary = _runtime_state.duplicate(true)
	result["schema_version"] = DOCUMENT_SCHEMA_VERSION
	result["isolated"] = true
	result["native_runtime_available"] = bool(_availability.get("available", false))
	result["production_runtime"] = bool(_availability.get("production", false))
	result["started"] = _started
	result["graph_identifier"] = _graph_identifier
	result["instance_identifier"] = _instance_identifier
	result["scope_key"] = _scope_key
	result["tick"] = _tick
	result["queued_event_count"] = _queued_events.size()
	result["fact_count"] = _facts.size()
	result["trace_count"] = _trace.size()
	result["step_count"] = _steps.size()
	result["trace_truncated"] = _trace.size() >= MAX_TRACE_RECORDS
	result["diagnostics"] = _safe_for_export(_diagnostics)
	return _safe_for_export(result)


func get_snapshot() -> Dictionary:
	return get_state()


func state() -> Dictionary:
	return get_state()


func get_last_result() -> Dictionary:
	return _last_result.duplicate(true)


func get_trace() -> Array:
	return _trace.duplicate(true)


func get_trace_records() -> Array:
	return get_trace()


func get_step_records() -> Array:
	return _steps.duplicate(true)


func get_diagnostics() -> Array:
	return _diagnostics.duplicate(true)


## Return a canonical, JSON-safe payload.  It contains no backend/runtime
## object and never includes wall-clock time, editor paths, or random IDs.
func trace_export_payload() -> Dictionary:
	return {
		"schema_version": TRACE_SCHEMA_VERSION,
		"kind": TRACE_KIND,
		"graph_identifier": _graph_identifier,
		"instance_identifier": _instance_identifier,
		"scope_key": _scope_key,
		"limits": _safe_for_export(_limits),
		"facts": get_facts(),
		"steps": _safe_for_export(_steps),
		"trace": get_trace(),
		"trace_truncated": _trace.size() >= MAX_TRACE_RECORDS,
		"final_state": get_state(),
		"diagnostics": _safe_for_export(_diagnostics),
	}


func export_trace_payload() -> Dictionary:
	return trace_export_payload()


func export_trace() -> String:
	return _canonical_json(trace_export_payload())


func export_trace_json() -> String:
	return export_trace()


func trace_json() -> String:
	return export_trace()


func export_trace_result() -> Dictionary:
	var json := export_trace()
	if json.to_utf8_buffer().size() > MAX_TRACE_BYTES:
		return _failure(TRACE_ERROR_CODE, "Trace export exceeds the bounded %d-byte payload limit." % MAX_TRACE_BYTES, "trace")
	return {
		"ok": true,
		"json": json,
		"digest": json.sha256_text(),
		"payload": trace_export_payload(),
	}


func export_trace_bytes() -> PackedByteArray:
	return export_trace().to_utf8_buffer()


func trace_digest() -> String:
	return export_trace().sha256_text()


func _consume_operation_result(operation: String, result: Dictionary, events: Array, tick: int) -> Dictionary:
	var trace_records := _trace_from_result(result)
	for record in trace_records:
		_append_trace_record(record)
	_runtime_state = _state_from_result(result)
	_refresh_runtime_state()
	var step_record := {
		"ordinal": _steps.size(),
		"operation": operation,
		"tick": tick,
		"events": _safe_for_export(events),
		"trace": _safe_for_export(trace_records),
		"result": _safe_for_export(_strip_runtime_handles(result)),
		"state": _safe_for_export(_runtime_state),
	}
	if _steps.size() >= MAX_STEP_RECORDS:
		_steps.pop_front()
	_steps.append(step_record)
	trace_changed.emit(get_trace())
	state_changed.emit(get_state())
	return _safe_for_export(step_record)


func _append_trace_record(record: Variant) -> void:
	var normalized := _safe_for_export(record)
	if not normalized is Dictionary:
		_record_diagnostic(TRACE_ERROR_CODE, "Native trace record is not a dictionary; it was omitted.", "trace")
		return
	# Native results normally contain a delta.  If an adapter returns a
	# cumulative trace, only records with an explicit revision/ordinal pair can
	# be recognized safely; identical records without that pair are retained as
	# separate activity because repeated runtime events are meaningful.
	if normalized.has("revision") and normalized.has("ordinal"):
		var key := "%s|%s" % [str(normalized.get("revision", "")), str(normalized.get("ordinal", ""))]
		if _trace_keys.has(key):
			return
		_trace_keys[key] = true
	if _trace.size() >= MAX_TRACE_RECORDS:
		_trace.pop_front()
	_trace.append(normalized)


func _trace_from_result(result: Dictionary) -> Array:
	var value = result.get("trace", result.get("trace_records", []))
	return value.duplicate(true) if value is Array else []


func _state_from_result(result: Dictionary) -> Dictionary:
	var value = result.get("state", result.get("runtime_state", {}))
	if value is Dictionary:
		return _safe_for_export(value)
	if _runtime is Dictionary:
		return _safe_for_export(_runtime)
	return _runtime_state.duplicate(true)


func _refresh_runtime_state() -> void:
	if _runtime != null and _bridge.is_available():
		var inspected: Dictionary = _bridge.inspect(_runtime)
		if bool(inspected.get("ok", false)) and inspected.get("state", {}) is Dictionary and not inspected.get("state", {}).is_empty():
			_runtime_state = _safe_for_export(inspected.get("state", {}))


func _strip_runtime_handles(result: Dictionary) -> Dictionary:
	var copy := {}
	for key in result:
		var name := _as_text(key)
		if name in ["runtime", "instance", "compiled", "backend"]:
			continue
		copy[name] = result[key]
	return copy


func _runtime_failure(result: Dictionary, operation: String) -> Dictionary:
	var error = result.get("error", {})
	if not error is Dictionary:
		error = {
			"code": RUNTIME_ERROR_CODE,
			"path": "runtime.%s" % operation,
			"severity": "error",
			"message": "Native task runtime rejected the %s operation." % operation,
		}
	_record_diagnostic(_as_text(error.get("code", RUNTIME_ERROR_CODE)), _as_text(error.get("message", "Native runtime rejected the operation.")), _as_text(error.get("path", "runtime.%s" % operation)), error.get("details", {}))
	return {"ok": false, "error": _safe_for_export(error), "state": get_state()}


func _failure_from_bridge(result: Dictionary) -> Dictionary:
	var error = result.get("error", {})
	if not error is Dictionary:
		error = {
			"code": RuntimeBridge.NATIVE_UNAVAILABLE_CODE,
			"path": "native.level_task_runtime",
			"severity": "error",
			"message": "Native task runtime is unavailable.",
		}
	return {"ok": false, "error": _safe_for_export(error), "state": get_state()}


func _record_bridge_diagnostic(result: Dictionary) -> void:
	var error = result.get("error", {})
	if error is Dictionary:
		_record_diagnostic(_as_text(error.get("code", RuntimeBridge.NATIVE_UNAVAILABLE_CODE)), _as_text(error.get("message", "Native task runtime is unavailable.")), _as_text(error.get("path", "native.level_task_runtime")), error.get("details", {}))


func _record_diagnostic(code: String, message: String, path: String, details: Variant = {}) -> void:
	var finding := {
		"code": code,
		"path": path,
		"severity": "error",
		"message": message,
		"details": _safe_for_export(details),
	}
	for existing in _diagnostics:
		if existing is Dictionary and _as_text(existing.get("code", "")) == code and _as_text(existing.get("path", "")) == path:
			return
	if _diagnostics.size() >= MAX_DIAGNOSTICS:
		return
	_diagnostics.append(finding)


func _normalize_fact(source: Variant, path: String) -> Dictionary:
	if not source is Dictionary:
		return _failure(FACT_INVALID_CODE, "Synthetic fact must be a dictionary record.", path)
	var provider := _as_text(source.get("provider_identifier", source.get("provider", "")))
	var fact_identifier := _as_text(source.get("fact_identifier", source.get("identifier", source.get("fact", ""))))
	if not _bounded_text(provider, MAX_IDENTIFIER_BYTES) or provider.is_empty():
		return _failure(FACT_INVALID_CODE, "Fact provider identifier is missing or exceeds the byte bound.", path + ".provider_identifier")
	if not _bounded_text(fact_identifier, MAX_IDENTIFIER_BYTES) or fact_identifier.is_empty():
		return _failure(FACT_INVALID_CODE, "Fact identifier is missing or exceeds the byte bound.", path + ".fact_identifier")
	var raw_value = source.get("value", null)
	if raw_value == null and source.has("type"):
		raw_value = source
	var normalized_value := _normalize_typed_value(raw_value, path + ".value")
	if not bool(normalized_value.get("ok", false)):
		return normalized_value
	return {
		"ok": true,
		"fact": {
			"provider_identifier": provider,
			"fact_identifier": fact_identifier,
			"value": normalized_value["value"],
		},
	}


func _normalize_event(source: Variant, path: String) -> Dictionary:
	if not source is Dictionary:
		return _failure(EVENT_INVALID_CODE, "Synthetic event must be a dictionary record.", path)
	var provider := _as_text(source.get("provider_identifier", source.get("provider", "")))
	var event_identifier := _as_text(source.get("event_identifier", source.get("identifier", source.get("event", ""))))
	if provider.is_empty() or not _bounded_text(provider, MAX_IDENTIFIER_BYTES):
		return _failure(EVENT_INVALID_CODE, "Event provider identifier is missing or exceeds the byte bound.", path + ".provider_identifier")
	if event_identifier.is_empty() or not _bounded_text(event_identifier, MAX_IDENTIFIER_BYTES):
		return _failure(EVENT_INVALID_CODE, "Event identifier is missing or exceeds the byte bound.", path + ".event_identifier")
	var event_scope := _as_text(source.get("scope_key", _scope_key))
	if event_scope != _scope_key:
		return _failure(EVENT_INVALID_CODE, "Synthetic event scope does not match the simulator scope.", path + ".scope_key")
	var sequence: Variant = source.get("sequence", 0)
	var amount: Variant = source.get("amount", 1)
	if sequence is bool or not sequence is int or int(sequence) < 0:
		return _failure(EVENT_INVALID_CODE, "Event sequence must be a non-negative integer (zero means implicit runtime ordering).", path + ".sequence")
	if amount is bool or not amount is int or int(amount) < 1:
		return _failure(EVENT_INVALID_CODE, "Event amount must be a positive integer.", path + ".amount")
	var raw_value = source.get("value", null)
	var normalized_value := _normalize_typed_value(raw_value, path + ".value")
	if not bool(normalized_value.get("ok", false)):
		return normalized_value
	var filters: Variant = source.get("filters", [])
	if not filters is Array or filters.size() > MAX_FILTERS_PER_EVENT:
		return _failure(EVENT_INVALID_CODE, "Event filters must be a bounded Array.", path + ".filters")
	var normalized_filters: Array = []
	for index in range(filters.size()):
		var predicate := _normalize_predicate(filters[index], "%s.filters[%d]" % [path, index])
		if not bool(predicate.get("ok", false)):
			return predicate
		normalized_filters.append(predicate["predicate"])
	return {
		"ok": true,
		"event": {
			"sequence": int(sequence),
			"provider_identifier": provider,
			"event_identifier": event_identifier,
			"scope_key": event_scope,
			"value": normalized_value["value"],
			"amount": int(amount),
			"filters": normalized_filters,
		},
	}


func _normalize_predicate(source: Variant, path: String) -> Dictionary:
	if not source is Dictionary:
		return _failure(EVENT_INVALID_CODE, "Event filter must be a dictionary predicate.", path)
	var provider := _as_text(source.get("provider_identifier", source.get("provider", "")))
	var fact_identifier := _as_text(source.get("fact_identifier", source.get("identifier", source.get("fact", ""))))
	var comparator := _as_text(source.get("comparator", "equal")).to_lower()
	if provider.is_empty() or fact_identifier.is_empty():
		return _failure(EVENT_INVALID_CODE, "Event filter provider and fact identifiers are required.", path)
	if comparator not in ["equal", "not_equal", "less", "less_or_equal", "greater", "greater_or_equal", "==", "!=", "<", "<=", ">", ">="]:
		return _failure(EVENT_INVALID_CODE, "Event filter comparator is not supported.", path + ".comparator")
	var normalized_value := _normalize_typed_value(source.get("expected", source.get("value", null)), path + ".expected")
	if not bool(normalized_value.get("ok", false)):
		return normalized_value
	return {
		"ok": true,
		"predicate": {
			"provider_identifier": provider,
			"fact_identifier": fact_identifier,
			"comparator": comparator,
			"expected": normalized_value["value"],
		},
	}


func _normalize_typed_value(source: Variant, path: String) -> Dictionary:
	if source == null:
		return {"ok": true, "value": {"type": "none"}}
	if source is Callable or source is Object:
		return _failure(FACT_INVALID_CODE, "Synthetic values cannot contain Objects or Callables.", path)
	var value_type := ""
	var payload: Variant = source
	if source is Dictionary:
		value_type = _as_text(source.get("type", "")).to_lower()
		if value_type.is_empty():
			return _failure(FACT_INVALID_CODE, "Typed synthetic values require a 'type' field.", path)
		payload = source.get("value", source.get("raw", null))
		if payload == null and value_type == "none":
			payload = null
	if value_type.is_empty():
		if source is bool:
			value_type = "boolean"
		elif source is int:
			value_type = "integer"
		elif source is String or source is StringName:
			value_type = "string"
		elif source is PackedByteArray:
			value_type = "bytes"
		else:
			return _failure(FACT_INVALID_CODE, "Synthetic values must use one of the closed typed value kinds.", path)
	if value_type == "bool":
		value_type = "boolean"
	if value_type == "int":
		value_type = "integer"
	if value_type not in VALUE_TYPES:
		return _failure(FACT_INVALID_CODE, "Synthetic value type '%s' is not supported." % value_type, path + ".type")
	if value_type == "none":
		return {"ok": true, "value": {"type": "none"}}
	if value_type == "boolean":
		if not payload is bool:
			return _failure(FACT_INVALID_CODE, "Boolean synthetic values require a bool payload.", path)
		return {"ok": true, "value": {"type": "boolean", "value": payload}}
	if value_type == "integer" or value_type == "fixed":
		if payload is bool or not payload is int:
			return _failure(FACT_INVALID_CODE, "Integer/fixed synthetic values require an integer payload.", path)
		return {"ok": true, "value": {"type": value_type, "value": int(payload)}}
	if value_type == "string" or value_type == "identifier":
		if not payload is String and not payload is StringName:
			return _failure(FACT_INVALID_CODE, "String/identifier synthetic values require text payloads.", path)
		var text_value := String(payload)
		var bound := MAX_IDENTIFIER_BYTES if value_type == "identifier" else MAX_STRING_BYTES
		if not _bounded_text(text_value, bound):
			return _failure(LIMIT_CODE, "Synthetic text value exceeds the byte bound of %d." % bound, path)
		return {"ok": true, "value": {"type": value_type, "value": text_value}}
	if value_type == "bytes":
		var bytes := PackedByteArray()
		if payload is PackedByteArray:
			bytes = payload
		elif payload is Array:
			if payload.size() > MAX_VALUE_BYTES:
				return _failure(LIMIT_CODE, "Synthetic bytes exceed the byte bound of %d." % MAX_VALUE_BYTES, path)
			for item in payload:
				if item is bool or not item is int or int(item) < 0 or int(item) > 255:
					return _failure(FACT_INVALID_CODE, "Synthetic byte arrays require values from 0 through 255.", path)
				bytes.append(int(item))
		else:
			return _failure(FACT_INVALID_CODE, "Bytes synthetic values require PackedByteArray or byte Array payloads.", path)
		if bytes.size() > MAX_VALUE_BYTES:
			return _failure(LIMIT_CODE, "Synthetic bytes exceed the byte bound of %d." % MAX_VALUE_BYTES, path)
		return {"ok": true, "value": {"type": "bytes", "value": bytes}}
	return _failure(FACT_INVALID_CODE, "Synthetic value could not be normalized.", path)


func _validate_limits(limits: Dictionary) -> Dictionary:
	for key in ["max_facts_per_snapshot", "max_events_per_advance", "max_pending_requests", "max_trace_records"]:
		if int(limits.get(key, 0)) <= 0:
			return {"path": "limits.%s" % key, "message": "Runtime limit '%s' must be positive." % key}
	if int(limits.get("max_facts_per_snapshot", MAX_FACTS)) > MAX_FACTS:
		return {"path": "limits.max_facts_per_snapshot", "message": "Fact limit exceeds the editor simulator bound."}
	if int(limits.get("max_events_per_advance", MAX_EVENTS_PER_STEP)) > MAX_EVENTS_PER_STEP:
		return {"path": "limits.max_events_per_advance", "message": "Event limit exceeds the editor simulator bound."}
	if int(limits.get("max_trace_records", MAX_TRACE_RECORDS)) > MAX_TRACE_RECORDS:
		return {"path": "limits.max_trace_records", "message": "Trace limit exceeds the editor simulator bound."}
	return {}


func _next_tick(requested: Variant) -> int:
	if requested == null:
		return _tick + 1
	if requested is bool or not requested is int:
		return -1
	var value := int(requested)
	if value < 0 or value <= _tick:
		return -1
	return value


func _fact_key(record: Dictionary) -> String:
	return String(record.get("provider_identifier", "")) + "|" + String(record.get("fact_identifier", ""))


func _read_graph_identifier(graph: Variant) -> String:
	if graph is Dictionary:
		return _as_text(graph.get("identifier", ""))
	if graph is Object:
		var value = graph.get("identifier")
		return _as_text(value)
	return ""


func _bounded_text(value: String, bound: int) -> bool:
	return value.to_utf8_buffer().size() <= bound


func _as_text(value: Variant) -> String:
	if value is StringName:
		return String(value)
	if value == null:
		return ""
	return str(value)


func _duplicate_input(value: Variant) -> Variant:
	if value is Dictionary or value is Array:
		return value.duplicate(true)
	if value is PackedStringArray or value is PackedByteArray:
		return value.duplicate()
	return value


func _safe_for_export(value: Variant) -> Variant:
	if value == null:
		return null
	if value is StringName:
		return String(value)
	if value is PackedByteArray:
		return {"type": "bytes", "hex": value.hex_encode()}
	if value is PackedStringArray:
		var strings: Array = []
		for item in value:
			strings.append(String(item))
		return strings
	if value is Dictionary:
		var result: Dictionary = {}
		for key in value:
			result[_as_text(key)] = _safe_for_export(value[key])
		return result
	if value is Array:
		var result: Array = []
		for item in value:
			result.append(_safe_for_export(item))
		return result
	if value is Object or value is Callable:
		return {"type": "opaque", "class": String(value.get_class()) if value is Object else "Callable"}
	return value


func _canonical_json(value: Variant) -> String:
	if value == null:
		return "null"
	if value is Dictionary:
		var keys: Array = value.keys()
		keys.sort()
		var parts: PackedStringArray = []
		for key in keys:
			parts.append(JSON.stringify(_as_text(key)) + ":" + _canonical_json(value[key]))
		return "{" + ",".join(parts) + "}"
	if value is Array:
		var array_parts: PackedStringArray = []
		for item in value:
			array_parts.append(_canonical_json(item))
		return "[" + ",".join(array_parts) + "]"
	if value is StringName:
		return JSON.stringify(String(value))
	if value is String:
		return JSON.stringify(value)
	if value is bool:
		return "true" if value else "false"
	if value is int:
		return str(value)
	return JSON.stringify(value)


func _success(details: Dictionary = {}) -> Dictionary:
	var result := {"ok": true}
	for key in details:
		result[key] = details[key]
	return result


func _failure(code: String, message: String, path: String, details: Dictionary = {}) -> Dictionary:
	_record_diagnostic(code, message, path, details)
	return {
		"ok": false,
		"error": {
			"code": code,
			"path": path,
			"severity": "error",
			"message": message,
			"details": _safe_for_export(details),
		},
		"state": get_state(),
	}
