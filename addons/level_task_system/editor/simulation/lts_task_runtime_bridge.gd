class_name LtsTaskRuntimeBridge
extends RefCounted

## Small, deliberately strict adapter around the native task runtime.
##
## The C++ task runtime is engine-independent and is not currently registered
## with ClassDB.  The editor simulator therefore probes for a future binding
## instead of reimplementing task advancement in GDScript.  A host may inject
## an adapter (or a test double) with the same closed-data contract.  No
## Callable, authority object, or scene node is accepted as a backend.

const NATIVE_UNAVAILABLE_CODE := "LTS-SIM-NATIVE-001"
const NATIVE_SURFACE_CODE := "LTS-SIM-NATIVE-002"
const BRIDGE_BACKEND_CODE := "LTS-SIM-BRIDGE-001"

const RUNTIME_CLASS_CANDIDATES: PackedStringArray = [
	"LevelTaskRuntimeBridge",
	"LevelTaskGraphRuntime",
	"LevelTaskGraphInstance",
	"LevelTaskRuntime",
	"LtsTaskGraphRuntime",
	"LtsTaskGraphInstance",
]

const START_METHODS: PackedStringArray = [
	"start",
	"start_instance",
	"create_instance",
]

const ADVANCE_METHODS: PackedStringArray = [
	"advance",
	"advance_instance",
	"step",
]

const ACKNOWLEDGE_METHODS: PackedStringArray = [
	"acknowledge_request",
	"acknowledge",
]

const REJECT_METHODS: PackedStringArray = [
	"reject_request",
	"reject",
]

const TIMEOUT_METHODS: PackedStringArray = [
	"timeout_request",
	"timeout",
]

const COMPILE_METHODS: PackedStringArray = [
	"compile_graph",
	"compile",
]

const STATE_METHODS: PackedStringArray = [
	"get_state",
	"state",
	"snapshot_state",
	"inspect",
]

var _backend: Object = null
var _backend_source := ""
var _last_availability: Dictionary = {}


func _init(backend: Variant = null) -> void:
	if backend != null:
		set_backend(backend)


## Install an explicit runtime binding.  This is intentionally a normal
## object seam rather than a global singleton so every simulator remains
## isolated from game authority and from other editor tabs.
func set_backend(backend: Variant) -> Dictionary:
	if backend == null:
		_backend = null
		_backend_source = ""
		_last_availability.clear()
		return _success({"backend": "none"})
	if backend is Callable or not backend is Object:
		_last_availability = _failure(
			BRIDGE_BACKEND_CODE,
			"Runtime backend must be an object exposing the native adapter methods.",
			"runtime_backend",
		)
		return _last_availability.duplicate(true)
	_backend = backend
	_backend_source = String(backend.get_class())
	_last_availability.clear()
	return availability()


func clear_backend() -> void:
	_backend = null
	_backend_source = ""
	_last_availability.clear()


func get_backend() -> Object:
	return _backend


## Returns a bounded diagnostic and never throws when the native runtime is
## absent.  A backend must implement only `start` and `advance`; compilation
## may be folded into `start` by a native binding, while explicit adapters can
## expose `compile_graph` for a separate validation pass.
func availability() -> Dictionary:
	if _backend != null:
		if _is_stateful_native_bridge(_backend):
			_last_availability = {"ok": true, "available": true, "production": true, "backend": _backend_source}
			return _last_availability.duplicate(true)
		var missing: Array[String] = []
		if not _has_any_method(_backend, START_METHODS):
			missing.append("start")
		if not _has_any_method(_backend, ADVANCE_METHODS):
			missing.append("advance")
		if not missing.is_empty():
			_last_availability = _failure(
				NATIVE_SURFACE_CODE,
				"Native task runtime binding is missing required methods: %s." % ", ".join(missing),
				"runtime_backend.%s" % _backend_source,
				{"backend": _backend_source, "missing_methods": missing},
			)
			return _last_availability.duplicate(true)
		if _backend.has_method("is_available") and not bool(_backend.call("is_available")):
			_last_availability = _failure(
				NATIVE_UNAVAILABLE_CODE,
				"Native task runtime binding is unavailable.",
				"native.level_task_runtime",
				{"backend": _backend_source},
			)
			return _last_availability.duplicate(true)
		_last_availability = {
			"ok": true,
			"available": true,
			"production": _backend_is_production(),
			"backend": _backend_source,
		}
		return _last_availability.duplicate(true)

	var discovered := _discover_native_backend()
	if discovered != null:
		_backend = discovered
		_backend_source = String(discovered.get_class())
		_last_availability = {
			"ok": true,
			"available": true,
			"production": true,
			"backend": _backend_source,
		}
		return _last_availability.duplicate(true)

	_last_availability = _failure(
		NATIVE_UNAVAILABLE_CODE,
		"Native task runtime is not registered with ClassDB; simulation is read-only.",
		"native.level_task_runtime",
		{
			"candidates": Array(RUNTIME_CLASS_CANDIDATES),
			"guidance": "Build and load the Level Task System runtime binding before simulating.",
		},
	)
	return _last_availability.duplicate(true)


func is_available() -> bool:
	return bool(availability().get("available", false))


func is_production_backend() -> bool:
	availability()
	return _backend_is_production()


func get_diagnostic() -> Dictionary:
	if _last_availability.is_empty():
		availability()
	if bool(_last_availability.get("available", false)):
		return {}
	return _last_availability.get("error", _last_availability).duplicate(true)


## Compile when the binding exposes that operation.  If it does not, `start`
## remains the native compile-and-start boundary.  Passing the authored graph
## through untouched keeps editor layout metadata outside runtime ownership.
func compile_graph(graph: Variant) -> Dictionary:
	var ready := _require_available()
	if not bool(ready.get("ok", false)):
		return ready
	if _is_stateful_native_bridge(_backend):
		if not graph is Dictionary:
			return _failure(NATIVE_SURFACE_CODE, "Native task graph input must be a Dictionary.", "runtime.compile_task_graph")
		var result := _normalize_call(_backend.call("compile_task_graph", graph), "")
		if bool(result.get("ok", false)):
			result["compiled"] = graph.duplicate(true)
		return result
	var method := _first_method(_backend, COMPILE_METHODS)
	if method.is_empty():
		return {"ok": true, "compiled": graph, "deferred": true}
	return _normalize_call(_backend.callv(method, [graph]), "compiled")


func start(compiled_graph: Variant, instance_identifier: String, scope_key: String, limits: Dictionary = {}) -> Dictionary:
	var ready := _require_available()
	if not bool(ready.get("ok", false)):
		return ready
	if _is_stateful_native_bridge(_backend):
		if not compiled_graph is Dictionary:
			return _failure(NATIVE_SURFACE_CODE, "Native task graph input must be a Dictionary.", "runtime.start_task_graph")
		var result := _stateful_native_result(_backend.call("start_task_graph", compiled_graph, instance_identifier, scope_key, {}))
		if bool(result.get("ok", false)):
			result["runtime"] = _backend
			result["limits"] = limits.duplicate(true)
		return result
	var method := _first_method(_backend, START_METHODS)
	if method.is_empty():
		return _failure(NATIVE_SURFACE_CODE, "Native task runtime has no start method.", "runtime.start")
	return _normalize_call(
		_backend.callv(method, [compiled_graph, instance_identifier, scope_key, limits]),
		"runtime",
	)


func advance(runtime: Variant, events: Array, facts: Array, tick: int) -> Dictionary:
	var ready := _require_available()
	if not bool(ready.get("ok", false)):
		return ready
	if _is_stateful_native_bridge(_backend):
		var facts_result := _normalize_call(_backend.call("set_task_facts", {"facts": facts.duplicate(true)}), "")
		if not bool(facts_result.get("ok", false)):
			return facts_result
		for event_value in events:
			if not event_value is Dictionary:
				return _failure(NATIVE_SURFACE_CODE, "Native task event must be a Dictionary.", "runtime.inject_task_event")
			var event_result := _normalize_call(_backend.call("inject_task_event", event_value), "")
			if not bool(event_result.get("ok", false)):
				return event_result
		return _stateful_native_result(_backend.call("step_task", tick))
	var method := _first_method(_backend, ADVANCE_METHODS)
	if method.is_empty():
		return _failure(NATIVE_SURFACE_CODE, "Native task runtime has no advance method.", "runtime.advance")
	return _normalize_call(_backend.callv(method, [runtime, events, facts, tick]), "")


func acknowledge_request(
		runtime: Variant,
		request_identifier: String,
		outcome_identifier: String,
		response: Variant,
		tick: int,
		expected_revision: int = -1
) -> Dictionary:
	if _is_stateful_native_bridge(_backend):
		var response_dictionary: Dictionary = response if response is Dictionary else {}
		return _stateful_native_result(_backend.call("acknowledge_task_request", request_identifier, outcome_identifier, response_dictionary))
	return _request_resolution(
		ACKNOWLEDGE_METHODS,
		[runtime, request_identifier, outcome_identifier, response, tick, expected_revision],
		"runtime.acknowledge_request",
	)


func reject_request(
		runtime: Variant,
		request_identifier: String,
		response: Variant,
		tick: int,
		expected_revision: int = -1
) -> Dictionary:
	if _is_stateful_native_bridge(_backend):
		var response_dictionary: Dictionary = response if response is Dictionary else {}
		return _stateful_native_result(_backend.call("reject_task_request", request_identifier, response_dictionary))
	return _request_resolution(
		REJECT_METHODS,
		[runtime, request_identifier, response, tick, expected_revision],
		"runtime.reject_request",
	)


func timeout_request(runtime: Variant, request_identifier: String, tick: int, expected_revision: int = -1) -> Dictionary:
	if _is_stateful_native_bridge(_backend):
		return _stateful_native_result(_backend.call("timeout_task_request", request_identifier))
	return _request_resolution(
		TIMEOUT_METHODS,
		[runtime, request_identifier, tick, expected_revision],
		"runtime.timeout_request",
	)


## Optional read-only state projection.  It is not required for correctness;
## the operation result itself is authoritative when this method is absent.
func inspect(runtime: Variant) -> Dictionary:
	var ready := _require_available()
	if not bool(ready.get("ok", false)):
		return ready
	if _is_stateful_native_bridge(_backend):
		return {"ok": true, "state": _backend.call("get_task_summary"), "trace": _backend.call("get_task_trace")}
	if runtime is Dictionary:
		return {"ok": true, "state": runtime.duplicate(true)}
	var method := _first_method(_backend, STATE_METHODS)
	if method.is_empty():
		return {"ok": true, "state": {}}
	return _normalize_call(_backend.callv(method, [runtime]), "state")


func _request_resolution(methods: PackedStringArray, args: Array, path: String) -> Dictionary:
	var ready := _require_available()
	if not bool(ready.get("ok", false)):
		return ready
	var method := _first_method(_backend, methods)
	if method.is_empty():
		return _failure(NATIVE_SURFACE_CODE, "Native task runtime does not expose this request operation.", path)
	return _normalize_call(_backend.callv(method, args), "")


func _require_available() -> Dictionary:
	var result := availability()
	if bool(result.get("available", false)):
		return {"ok": true}
	return result


func _discover_native_backend() -> Object:
	for class_name_value in RUNTIME_CLASS_CANDIDATES:
		var runtime_class_name := StringName(class_name_value)
		if not ClassDB.class_exists(runtime_class_name):
			continue
		var candidate: Object = ClassDB.instantiate(runtime_class_name)
		if candidate == null:
			continue
		if _is_stateful_native_bridge(candidate) or (_has_any_method(candidate, START_METHODS) and _has_any_method(candidate, ADVANCE_METHODS)):
			return candidate
		candidate.free()
	return null


func _backend_is_production() -> bool:
	if _backend == null:
		return false
	if _backend.has_method("is_production_backend"):
		return bool(_backend.call("is_production_backend"))
	if _backend.has_method("is_test_backend"):
		return not bool(_backend.call("is_test_backend"))
	if _is_stateful_native_bridge(_backend):
		return true
	return false


func _is_stateful_native_bridge(target: Object) -> bool:
	return target != null \
		and target.has_method("compile_task_graph") \
		and target.has_method("start_task_graph") \
		and target.has_method("step_task") \
		and target.has_method("get_task_summary")


func _stateful_native_result(raw: Variant) -> Dictionary:
	var result := _normalize_call(raw, "")
	if bool(result.get("ok", false)):
		result["state"] = _backend.call("get_task_summary")
		result["trace"] = _backend.call("get_task_trace")
	return result


func _has_any_method(target: Object, methods: PackedStringArray) -> bool:
	return not _first_method(target, methods).is_empty()


func _first_method(target: Object, methods: PackedStringArray) -> String:
	if target == null:
		return ""
	for method in methods:
		if target.has_method(method):
			return method
	return ""


func _normalize_call(raw: Variant, default_key: String) -> Dictionary:
	if raw is Dictionary:
		var result: Dictionary = raw.duplicate(true)
		if not result.has("ok"):
			result["ok"] = not result.has("error")
		if bool(result.get("ok", false)) and not default_key.is_empty() and not result.has(default_key):
			# A backend is allowed to return the runtime/state object directly.
			result[default_key] = raw.duplicate(true)
		return result
	if raw is Object:
		return {"ok": true, default_key: raw} if not default_key.is_empty() else {"ok": true}
	if raw is bool:
		return {"ok": raw}
	return {"ok": true, default_key: raw} if not default_key.is_empty() else {"ok": true, "value": raw}


func _success(details: Dictionary = {}) -> Dictionary:
	var result := {"ok": true}
	for key in details:
		result[key] = details[key]
	return result


func _failure(code: String, message: String, path: String, details: Dictionary = {}) -> Dictionary:
	return {
		"ok": false,
		"available": false,
		"error": {
			"code": code,
			"path": path,
			"severity": "error",
			"message": message,
			"details": details.duplicate(true),
		},
	}
