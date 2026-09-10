class_name LtsLiveRuntimeDebuggerModel
extends RefCounted

## Pure, EditorInterface-free projection for a live task-runtime feed.
##
## The native runtime deliberately does not expose TaskGraphInstance methods to
## Godot.  A host therefore publishes a recipient-safe plain-data envelope and
## this model becomes the only boundary the editor consumes.  The model never
## receives a runtime object, never stores a callable, and never constructs an
## authority command.  Unknown fields are ignored; private request parameters,
## fact values, event values, and responses are not part of the projection.

const FEED_SCHEMA_VERSION := 1

const MAX_INSTANCES := 256
const MAX_TRACE_RECORDS := 1024
const MAX_NODE_SUMMARIES_PER_INSTANCE := 256
const MAX_PENDING_REQUESTS_PER_INSTANCE := 64
const MAX_IDENTIFIER_BYTES := 128
const MAX_STRING_BYTES := 256

const STATE_READY: StringName = &"ready"
const STATE_EMPTY: StringName = &"empty"
const STATE_LOADING: StringName = &"loading"
const STATE_DEGRADED: StringName = &"degraded"
const STATE_ERROR: StringName = &"error"

const STATUS_ALL := "all"

const GRAPH_STATUSES: PackedStringArray = [
	"invalid", "running", "succeeded", "failed", "cancelled", "stalled",
]

const TRACE_KINDS: PackedStringArray = [
	"event_accepted",
	"fact_snapshot_accepted",
	"node_activated",
	"node_counter_changed",
	"node_completed",
	"edge_traversed",
	"request_emitted",
	"request_resolved",
	"request_duplicate",
	"graph_status_changed",
]

const REQUEST_KINDS: PackedStringArray = [
	"action", "reward", "conversation", "level_transition",
]

const NODE_STATES: PackedStringArray = [
	"inactive", "active", "pending", "completed", "failed",
]

const _UNSAFE_FEED_KEYS: PackedStringArray = [
	"authority", "runtime", "runtime_object", "instance_object", "owner_object",
	"callable", "commands", "command", "mutation", "mutations", "rpc",
	"facts", "fact_snapshot", "event_payload", "request_parameters", "parameters",
	"response", "responses", "raw_snapshot", "snapshot_bytes", "save_snapshot",
]

var _limits: Dictionary = {}
var _available := true
var _state: StringName = STATE_EMPTY
var _diagnostic: Dictionary = {}
var _feed_metadata: Dictionary = {}
var _instances: Dictionary = {}
var _trace_records: Array[Dictionary] = []
var _trace_truncated := false
var _selected_instance_identifier := ""
var _selected_trace_key := ""
var _filter_query := ""
var _status_filter := STATUS_ALL


func _init(p_limits: Dictionary = {}) -> void:
	_limits = _normalize_limits(p_limits)


## Returns the host-feed caps actually used by this model.  Values are copies so
## callers cannot alter the model's bounds through a returned Dictionary.
func get_limits() -> Dictionary:
	return _limits.duplicate(true)


## A debugger is an observation surface even when the feed is degraded.
func is_read_only() -> bool:
	return true


func has_authority_controls() -> bool:
	return false


func get_authority_actions() -> Array:
	return []


## The model intentionally has no runtime mutation methods.  This explicit
## capability report gives callers a safe way to assert that fact without
## inspecting implementation details.
func get_mutation_commands() -> Array:
	return []


func get_state() -> StringName:
	return _state


func get_state_label() -> String:
	match _state:
		STATE_READY:
			return "Live feed connected"
		STATE_EMPTY:
			return "No runtime activity"
		STATE_LOADING:
			return "Waiting for live runtime feed"
		STATE_DEGRADED:
			return "Live runtime unavailable"
		STATE_ERROR:
			return "Live runtime feed rejected"
	return "Live runtime observation"


func get_diagnostic() -> Dictionary:
	return _diagnostic.duplicate(true)


func set_available(p_available: bool, p_reason: String = "") -> Dictionary:
	_available = p_available
	if _available:
		_diagnostic = {}
		_state = STATE_READY if not _instances.is_empty() else STATE_EMPTY
		return _result(true)
	_diagnostic = _diagnostic_value(
		"LTS-LIVE-001",
		p_reason if not p_reason.is_empty() else "The host has not exposed a compatible live runtime feed.",
		"live_runtime"
	)
	_state = STATE_DEGRADED
	return _result(false, _diagnostic)


func is_available() -> bool:
	return _available


func set_loading(p_loading: bool) -> Dictionary:
	if not _available:
		return _result(false, _diagnostic)
	if p_loading:
		_state = STATE_LOADING
	else:
		_state = STATE_READY if not _instances.is_empty() else STATE_EMPTY
	return _result(true)


func clear() -> Dictionary:
	_instances.clear()
	_trace_records.clear()
	_feed_metadata.clear()
	_trace_truncated = false
	_selected_instance_identifier = ""
	_selected_trace_key = ""
	_diagnostic = {}
	_state = STATE_EMPTY if _available else STATE_DEGRADED
	return _result(true)


## Consume a complete bounded recipient-safe feed.  The default mode replaces
## the current projection.  A host may set `append=true` (or mode="append")
## for an incremental stream; records are still deduplicated and capped.
##
## Accepted envelope fields are deliberately small:
##   schema_version, recipient_safe/authorized, source_revision, source_tick,
##   instances/instance_summaries, trace_records/trace, truncated.
## Each instance is itself a summary projection; nested trace_records are
## accepted as a convenience and normalized through the same whitelist.
func ingest(p_feed: Variant) -> Dictionary:
	if not _available:
		return _result(false, _diagnostic)
	if not p_feed is Dictionary:
		return _reject("LTS-LIVE-002", "Live feed envelope must be a Dictionary.", "live_runtime.feed")
	var feed: Dictionary = p_feed
	var envelope_check := _validate_envelope_marker(feed)
	if not envelope_check.get("ok", false):
		return envelope_check
	var schema_version := int(feed.get("schema_version", FEED_SCHEMA_VERSION))
	if schema_version != FEED_SCHEMA_VERSION:
		return _reject(
			"LTS-LIVE-003",
			"Live feed schema version %d is not supported; expected %d." % [schema_version, FEED_SCHEMA_VERSION],
			"live_runtime.schema_version"
		)
	var raw_instances: Array = _array_from_keys(feed, ["instances", "instance_summaries", "summaries"])
	var raw_traces: Array = _array_from_keys(feed, ["trace_records", "trace", "records"])
	if raw_instances.size() > int(_limits.max_instances) * 4:
		return _reject("LTS-LIVE-004", "Live feed contains too many instance summaries.", "live_runtime.instances")
	if raw_traces.size() > int(_limits.max_trace_records) * 4:
		return _reject("LTS-LIVE-005", "Live feed contains too many trace records.", "live_runtime.trace_records")

	var sanitized_instances: Array[Dictionary] = []
	var rejected_instances := 0
	for raw_value in raw_instances:
		if not raw_value is Dictionary:
			rejected_instances += 1
			continue
		var summary := _sanitize_instance_summary(raw_value)
		if summary.is_empty():
			rejected_instances += 1
			continue
		sanitized_instances.append(summary)
		# Nested records are bounded by the same global feed cap.  The source
		# record is copied only as scalar data, never retained as a live object.
		var nested_trace: Array = _array_from_keys(raw_value, ["trace_records", "trace"])
		for nested_value in nested_trace:
			if not nested_value is Dictionary:
				continue
			var nested_copy: Dictionary = nested_value.duplicate(true)
			nested_copy["instance_identifier"] = String(summary.get("instance_identifier", ""))
			raw_traces.append(nested_copy)

	if raw_traces.size() > int(_limits.max_trace_records) * 4:
		return _reject("LTS-LIVE-005", "Live feed contains too many trace records.", "live_runtime.trace_records")

	var candidate_ids: Dictionary = {}
	for summary in sanitized_instances:
		var identifier := String(summary.get("instance_identifier", ""))
		if not identifier.is_empty():
			candidate_ids[identifier] = true
	var fallback_instance := ""
	if candidate_ids.size() == 1:
		fallback_instance = String(candidate_ids.keys()[0])

	var sanitized_traces: Array[Dictionary] = []
	var rejected_traces := 0
	for raw_trace_value in raw_traces:
		if not raw_trace_value is Dictionary:
			rejected_traces += 1
			continue
		var trace := _sanitize_trace_record(raw_trace_value, fallback_instance)
		if trace.is_empty():
			rejected_traces += 1
			continue
		sanitized_traces.append(trace)

	var replace_feed := not bool(feed.get("append", false)) and String(feed.get("mode", "replace")) != "append"
	if replace_feed:
		_instances = _select_canonical_instances(sanitized_instances)
		var retained_traces := _trace_records_for_instances(sanitized_traces, _instances)
		_trace_records = _bounded_trace_records(retained_traces)
		_trace_truncated = bool(feed.get("truncated", false)) or bool(feed.get("trace_truncated", false)) \
				or retained_traces.size() < sanitized_traces.size() or sanitized_traces.size() > _trace_records.size()
	else:
		_merge_instances(sanitized_instances)
		_merge_trace_records(sanitized_traces)
		_trace_truncated = _trace_truncated or bool(feed.get("truncated", false)) \
				or bool(feed.get("trace_truncated", false))
	_feed_metadata = _sanitize_feed_metadata(feed)
	if rejected_instances > 0 or rejected_traces > 0:
		_feed_metadata["rejected_instance_count"] = rejected_instances
		_feed_metadata["rejected_trace_count"] = rejected_traces
		_feed_metadata["partial"] = true
	if _instances.is_empty():
		_state = STATE_EMPTY
	else:
		_state = STATE_READY
	_diagnostic = {}
	_reconcile_selection()
	return _result(true)


func consume(p_feed: Variant) -> Dictionary:
	return ingest(p_feed)


func apply_feed(p_feed: Variant) -> Dictionary:
	return ingest(p_feed)


func set_feed(p_feed: Variant) -> Dictionary:
	return ingest(p_feed)


func set_filter(p_query: String) -> Dictionary:
	_filter_query = p_query.strip_edges().to_lower()
	_reconcile_selection()
	return _result(true)


func set_query(p_query: String) -> Dictionary:
	return set_filter(p_query)


func get_filter_query() -> String:
	return _filter_query


func set_status_filter(p_status: String) -> Dictionary:
	var normalized := _normalize_graph_status(p_status)
	if p_status.strip_edges().is_empty() or p_status.to_lower().strip_edges() == STATUS_ALL:
		normalized = STATUS_ALL
	if normalized != STATUS_ALL and not GRAPH_STATUSES.has(normalized):
		return _reject("LTS-LIVE-006", "Unknown runtime status filter '%s'." % p_status, "live_runtime.filter.status")
	_status_filter = normalized
	_reconcile_selection()
	return _result(true)


func get_status_filter() -> String:
	return _status_filter


func get_instance_identifiers() -> PackedStringArray:
	var result := PackedStringArray()
	for identifier in _filtered_instance_identifiers():
		result.append(identifier)
	return result


func get_instance_summaries() -> Array:
	var result: Array = []
	for identifier in _filtered_instance_identifiers():
		result.append(_instances[identifier].duplicate(true))
	return result


func get_instances() -> Array:
	return get_instance_summaries()


func get_visible_instances() -> Array:
	return get_instance_summaries()


func get_all_trace_records() -> Array:
	var result: Array = []
	for trace in _trace_records:
		result.append(trace.duplicate(true))
	return result


func get_trace_records() -> Array:
	var result: Array = []
	var visible_ids: Dictionary = {}
	for identifier in _filtered_instance_identifiers():
		visible_ids[identifier] = true
	for trace in _trace_records:
		var instance_identifier := String(trace.get("instance_identifier", ""))
		if not instance_identifier.is_empty() and not visible_ids.has(instance_identifier):
			continue
		if not _matches_query(trace, instance_identifier):
			continue
		result.append(trace.duplicate(true))
	return result


func get_visible_trace_records() -> Array:
	return get_trace_records()


func get_instance_trace_records(p_instance_identifier: String) -> Array:
	var result: Array = []
	for trace in get_trace_records():
		if String(trace.get("instance_identifier", "")) == p_instance_identifier:
			result.append(trace)
	return result


func get_visible_traces() -> Array:
	return get_trace_records()


func select_instance(p_identifier: String) -> Dictionary:
	var identifier := p_identifier.strip_edges()
	if not _instances.has(identifier):
		return _reject("LTS-LIVE-007", "The requested runtime instance is not present in the feed.", "live_runtime.selection.instance")
	if not _filtered_instance_identifiers().has(identifier):
		return _reject("LTS-LIVE-008", "The requested runtime instance is hidden by the active filter.", "live_runtime.selection.instance")
	_selected_instance_identifier = identifier
	_selected_trace_key = ""
	_reconcile_selection()
	return _result(true)


func clear_selection() -> Dictionary:
	_selected_instance_identifier = ""
	_selected_trace_key = ""
	return _result(true)


func get_selected_instance_identifier() -> String:
	return _selected_instance_identifier


func get_selected_instance_summary() -> Dictionary:
	if not _instances.has(_selected_instance_identifier):
		return {}
	return _instances[_selected_instance_identifier].duplicate(true)


## Select a visible trace by its filtered index or by the stable trace key.
func select_trace(p_selection: Variant) -> Dictionary:
	var visible := get_trace_records()
	var selected: Dictionary = {}
	if p_selection is Dictionary:
		var requested_key := _trace_key(p_selection)
		for trace in visible:
			if _trace_key(trace) == requested_key:
				selected = trace
				break
	elif p_selection is String or p_selection is StringName:
		var requested_string := String(p_selection)
		for trace in visible:
			if _trace_key(trace) == requested_string:
				selected = trace
				break
	else:
		var index := int(p_selection)
		if index >= 0 and index < visible.size():
			selected = visible[index]
	if selected.is_empty():
		return _reject("LTS-LIVE-009", "The requested trace record is not visible.", "live_runtime.selection.trace")
	_selected_trace_key = _trace_key(selected)
	var trace_instance := String(selected.get("instance_identifier", ""))
	if not trace_instance.is_empty() and _instances.has(trace_instance):
		_selected_instance_identifier = trace_instance
	return _result(true)


func clear_trace_selection() -> Dictionary:
	_selected_trace_key = ""
	return _result(true)


func get_selected_trace_key() -> String:
	return _selected_trace_key


func get_selected_trace() -> Dictionary:
	if _selected_trace_key.is_empty():
		return {}
	for trace in get_trace_records():
		if _trace_key(trace) == _selected_trace_key:
			return trace
	return {}


func get_feed_metadata() -> Dictionary:
	return _feed_metadata.duplicate(true)


func get_projection() -> Dictionary:
	var instances := get_instance_summaries()
	var traces := get_trace_records()
	var selected_instance := get_selected_instance_summary()
	var selected_trace := get_selected_trace()
	var state_label := get_state_label()
	var projection := {
		"ok": _state != STATE_ERROR and _state != STATE_DEGRADED,
		"state": String(_state),
		"state_label": state_label,
		"read_only": true,
		"is_read_only": true,
		"authority_controls": false,
		"instances": instances,
		"instance_summaries": instances.duplicate(true),
		"traces": traces,
		"trace_records": traces.duplicate(true),
		"selected_instance_identifier": _selected_instance_identifier,
		"selected_instance": selected_instance,
		"selected_trace_key": _selected_trace_key,
		"selected_trace": selected_trace,
		"filter_query": _filter_query,
		"status_filter": _status_filter,
		"feed_metadata": _feed_metadata.duplicate(true),
		"trace_truncated": _trace_truncated,
		"truncated": _trace_truncated,
		"diagnostic": _diagnostic.duplicate(true),
		"counts": {
			"instances": instances.size(),
			"total_instances": _instances.size(),
			"traces": traces.size(),
			"total_traces": _trace_records.size(),
		},
	}
	if _state == STATE_EMPTY:
		projection["empty"] = true
		projection["empty_message"] = "The host has not published a recipient-safe runtime summary or trace."
	else:
		projection["empty"] = false
	if _state == STATE_DEGRADED:
		projection["degraded"] = true
		projection["degraded_message"] = String(_diagnostic.get("message", "Live runtime observation is unavailable."))
	else:
		projection["degraded"] = false
	return projection


func get_selection() -> Dictionary:
	return {
		"instance_identifier": _selected_instance_identifier,
		"trace_key": _selected_trace_key,
		"instance": get_selected_instance_summary(),
		"trace": get_selected_trace(),
	}


## A short human-readable row summary for native Tree/ItemList controls.
static func instance_row_text(p_summary: Dictionary) -> String:
	var identifier := String(p_summary.get("instance_identifier", "(unknown instance)"))
	var graph := String(p_summary.get("graph_identifier", ""))
	var status := _display_word(String(p_summary.get("status", "invalid")))
	var revision := int(p_summary.get("revision", 0))
	var label := identifier
	if not graph.is_empty():
		label += "  ·  " + graph
	return "%s  [%s | rev %d]" % [label, status, revision]


static func trace_row_text(p_trace: Dictionary) -> String:
	var kind := _display_word(String(p_trace.get("kind", "trace")))
	var node := String(p_trace.get("node_identifier", ""))
	var event := String(p_trace.get("event_identifier", ""))
	var request := String(p_trace.get("request_identifier", ""))
	var outcome := String(p_trace.get("outcome_identifier", ""))
	var detail := node
	if detail.is_empty():
		detail = event
	if detail.is_empty():
		detail = request
	if detail.is_empty():
		detail = outcome
	if detail.is_empty():
		detail = "runtime state"
	return "rev %d · %s · %s" % [int(p_trace.get("revision", 0)), kind, detail]


static func status_label(p_status: String) -> String:
	return _display_word(p_status)


static func trace_kind_label(p_kind: String) -> String:
	return _display_word(p_kind)


func _validate_envelope_marker(p_feed: Dictionary) -> Dictionary:
	if p_feed.has("recipient_safe") and not bool(p_feed.get("recipient_safe")):
		return _reject("LTS-LIVE-010", "The host marked this runtime feed as not recipient-safe.", "live_runtime.recipient_safe")
	if p_feed.has("authorized") and not bool(p_feed.get("authorized")):
		return _reject("LTS-LIVE-011", "The host did not authorize this runtime observation feed.", "live_runtime.authorized")
	if p_feed.has("projection"):
		var projection_name := String(p_feed.get("projection", "")).to_lower()
		if projection_name in ["authority", "internal", "raw", "full"]:
			return _reject("LTS-LIVE-012", "Only recipient-safe runtime projections may be displayed.", "live_runtime.projection")
	for key in p_feed.keys():
		var key_name := String(key).to_lower()
		if _UNSAFE_FEED_KEYS.has(key_name):
			return _reject("LTS-LIVE-013", "The live feed contains an authority-only field and was rejected.", "live_runtime.%s" % key_name)
		if p_feed[key] is Object or p_feed[key] is Callable:
			return _reject("LTS-LIVE-014", "Live debugger feeds may contain only recipient-safe value data.", "live_runtime.%s" % key_name)
	return {"ok": true}


func _sanitize_feed_metadata(p_feed: Dictionary) -> Dictionary:
	var metadata := {}
	for key in ["source_revision", "source_tick", "catalog_fingerprint", "definition_schema_version", "recipient_identifier", "audience"]:
		if not p_feed.has(key):
			continue
		var value = p_feed[key]
		if value is Object or value is Callable:
			continue
		if value is String or value is StringName:
			metadata[key] = _bounded_string(value, MAX_STRING_BYTES)
		elif value is int or value is float:
			metadata[key] = _bounded_uint(value)
		elif value is bool:
			metadata[key] = value
	return metadata


func _sanitize_instance_summary(p_raw: Dictionary) -> Dictionary:
	if p_raw.has("recipient_safe") and not bool(p_raw.get("recipient_safe")):
		return {}
	if p_raw.has("authorized") and not bool(p_raw.get("authorized")):
		return {}
	for key in p_raw.keys():
		var key_name := String(key).to_lower()
		if p_raw[key] is Object or p_raw[key] is Callable:
			return {}
		# Private fields inside a summary are omitted by the whitelist.  An
		# explicit authority object is rejected above at the envelope; an
		# object nested in this record still fails closed here.
		if _UNSAFE_FEED_KEYS.has(key_name):
			continue
	var identifier := _bounded_string(_first_value(p_raw, ["instance_identifier", "instance_id", "id"]), MAX_IDENTIFIER_BYTES)
	if identifier.is_empty():
		return {}
	var summary := {
		"instance_identifier": identifier,
		"graph_identifier": _bounded_string(_first_value(p_raw, ["graph_identifier", "graph_id", "task_graph_identifier"]), MAX_IDENTIFIER_BYTES),
		"scope_key": _bounded_string(_first_value(p_raw, ["scope_key", "host_scope_key", "scope"]), MAX_IDENTIFIER_BYTES),
		"definition_fingerprint": _bounded_identifier_value(_first_value(p_raw, ["definition_fingerprint", "fingerprint"])),
		"catalog_fingerprint": _bounded_identifier_value(_first_value(p_raw, ["catalog_fingerprint"])),
		"revision": _bounded_uint(_first_value(p_raw, ["revision", "instance_revision"])),
		"status": _normalize_graph_status(_first_value(p_raw, ["status", "graph_status", "state"])),
		"terminal_outcome": _bounded_string(_first_value(p_raw, ["terminal_outcome", "outcome", "terminal"]), MAX_IDENTIFIER_BYTES),
		"last_tick": _bounded_uint(_first_value(p_raw, ["last_tick", "tick"])),
		"trace_truncated": bool(p_raw.get("trace_truncated", p_raw.get("truncated", false))),
		"trace_count": _bounded_uint(_first_value(p_raw, ["trace_count", "retained_trace_count"])),
		"pending_request_count": _bounded_uint(_first_value(p_raw, ["pending_request_count"])),
	}
	var raw_nodes: Array = _array_from_keys(p_raw, ["node_states", "nodes", "node_summaries"])
	var nodes: Array[Dictionary] = []
	for raw_node in raw_nodes.slice(0, int(_limits.max_node_summaries_per_instance)):
		if not raw_node is Dictionary:
			continue
		var node := _sanitize_node_summary(raw_node)
		if not node.is_empty():
			nodes.append(node)
	nodes.sort_custom(_compare_node_summaries)
	summary["node_states"] = nodes
	summary["node_count"] = nodes.size()
	var raw_requests: Array = _array_from_keys(p_raw, ["pending_requests", "requests"])
	var requests: Array[Dictionary] = []
	for raw_request in raw_requests.slice(0, int(_limits.max_pending_requests_per_instance)):
		if not raw_request is Dictionary:
			continue
		var request := _sanitize_pending_request(raw_request)
		if not request.is_empty():
			requests.append(request)
	requests.sort_custom(_compare_pending_requests)
	summary["pending_requests"] = requests
	summary["pending_request_count"] = maxi(int(summary["pending_request_count"]), requests.size())
	return summary


func _sanitize_node_summary(p_raw: Dictionary) -> Dictionary:
	var identifier := _bounded_string(_first_value(p_raw, ["node_identifier", "node_id", "identifier", "id"]), MAX_IDENTIFIER_BYTES)
	if identifier.is_empty():
		return {}
	return {
		"node_identifier": identifier,
		"state": _normalize_node_state(_first_value(p_raw, ["state", "node_state"])),
		"counter": _bounded_uint(_first_value(p_raw, ["counter", "progress", "count"])),
		"request_generation": _bounded_uint(_first_value(p_raw, ["request_generation"])),
	}


func _sanitize_pending_request(p_raw: Dictionary) -> Dictionary:
	var identifier := _bounded_string(_first_value(p_raw, ["request_identifier", "request_id", "id"]), MAX_IDENTIFIER_BYTES)
	if identifier.is_empty():
		return {}
	var request := {
		"request_identifier": identifier,
		"kind": _normalize_request_kind(_first_value(p_raw, ["kind", "request_kind"])),
		"node_identifier": _bounded_string(_first_value(p_raw, ["node_identifier", "node_id"]), MAX_IDENTIFIER_BYTES),
		"created_revision": _bounded_uint(_first_value(p_raw, ["created_revision"])),
		"created_tick": _bounded_uint(_first_value(p_raw, ["created_tick"])),
		"has_timeout": bool(p_raw.get("has_timeout", false)),
		"timeout_tick": _bounded_uint(_first_value(p_raw, ["timeout_tick"])),
	}
	return request


func _sanitize_trace_record(p_raw: Dictionary, p_fallback_instance: String = "") -> Dictionary:
	if p_raw.has("recipient_safe") and not bool(p_raw.get("recipient_safe")):
		return {}
	if p_raw.has("authorized") and not bool(p_raw.get("authorized")):
		return {}
	for key in p_raw.keys():
		if p_raw[key] is Object or p_raw[key] is Callable:
			return {}
	var instance_identifier := _bounded_string(_first_value(p_raw, ["instance_identifier", "instance_id"]), MAX_IDENTIFIER_BYTES)
	if instance_identifier.is_empty():
		instance_identifier = p_fallback_instance
	if instance_identifier.is_empty():
		return {}
	var kind := _normalize_trace_kind(_first_value(p_raw, ["kind", "trace_kind", "type"]))
	if kind.is_empty():
		return {}
	var trace := {
		"instance_identifier": instance_identifier,
		"revision": _bounded_uint(_first_value(p_raw, ["revision", "instance_revision"])),
		"ordinal": _bounded_uint(_first_value(p_raw, ["ordinal", "index"])),
		"kind": kind,
		"node_identifier": _bounded_string(_first_value(p_raw, ["node_identifier", "node_id"]), MAX_IDENTIFIER_BYTES),
		"request_identifier": _bounded_string(_first_value(p_raw, ["request_identifier", "request_id"]), MAX_IDENTIFIER_BYTES),
		"event_identifier": _bounded_string(_first_value(p_raw, ["event_identifier", "event_id"]), MAX_IDENTIFIER_BYTES),
		"outcome_identifier": _bounded_string(_first_value(p_raw, ["outcome_identifier", "outcome"]), MAX_IDENTIFIER_BYTES),
		"previous_state": _normalize_node_state(_first_value(p_raw, ["previous_state", "from_state"])),
		"current_state": _normalize_node_state(_first_value(p_raw, ["current_state", "to_state"])),
		"graph_status": _normalize_graph_status(_first_value(p_raw, ["graph_status", "status"])),
	}
	return trace


func _select_canonical_instances(p_summaries: Array[Dictionary]) -> Dictionary:
	var candidates := p_summaries.duplicate(true)
	candidates.sort_custom(_compare_instance_summaries)
	var result := {}
	for summary in candidates:
		var identifier := String(summary.get("instance_identifier", ""))
		if identifier.is_empty() or result.has(identifier):
			continue
		if result.size() >= int(_limits.max_instances):
			break
		result[identifier] = summary
	return result


func _merge_instances(p_summaries: Array[Dictionary]) -> void:
	var combined: Array[Dictionary] = []
	for identifier in _instances.keys():
		combined.append(_instances[identifier])
	combined.append_array(p_summaries)
	_instances = _select_canonical_instances(combined)


func _bounded_trace_records(p_records: Array[Dictionary]) -> Array[Dictionary]:
	var records := p_records.duplicate(true)
	records.sort_custom(_compare_trace_records)
	if records.size() > int(_limits.max_trace_records):
		return records.slice(records.size() - int(_limits.max_trace_records))
	return records


func _merge_trace_records(p_records: Array[Dictionary]) -> void:
	var accepted_records := _trace_records_for_instances(p_records, _instances)
	var combined: Array[Dictionary] = _trace_records.duplicate(true)
	combined.append_array(accepted_records)
	var deduplicated := {}
	for trace in combined:
		deduplicated[_trace_key(trace)] = trace
	var unique_records: Array[Dictionary] = []
	for value in deduplicated.values():
		if value is Dictionary:
			unique_records.append(value)
	_trace_records = _bounded_trace_records(unique_records)
	if combined.size() > _trace_records.size():
		_trace_truncated = true


func _trace_records_for_instances(p_records: Array[Dictionary], p_instances: Dictionary) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for record in p_records:
		var identifier := String(record.get("instance_identifier", ""))
		if identifier.is_empty() or not p_instances.has(identifier):
			continue
		result.append(record)
	return result


func _filtered_instance_identifiers() -> PackedStringArray:
	var identifiers := PackedStringArray()
	for identifier in _instances.keys():
		var summary: Dictionary = _instances[identifier]
		if _status_filter != STATUS_ALL and String(summary.get("status", "invalid")) != _status_filter:
			continue
		if not _matches_query(summary, String(identifier)) and not _instance_has_matching_trace(String(identifier)):
			continue
		identifiers.append(String(identifier))
	identifiers.sort()
	return identifiers


func _instance_has_matching_trace(p_instance_identifier: String) -> bool:
	if _filter_query.is_empty():
		return false
	for trace in _trace_records:
		if String(trace.get("instance_identifier", "")) != p_instance_identifier:
			continue
		if _matches_query(trace, p_instance_identifier):
			return true
	return false


func _matches_query(p_value: Dictionary, p_instance_identifier: String = "") -> bool:
	if _filter_query.is_empty():
		return true
	var haystack := p_instance_identifier.to_lower()
	for key in [
		"graph_identifier", "scope_key", "status", "terminal_outcome", "node_identifier",
		"request_identifier", "event_identifier", "outcome_identifier", "kind",
	]:
		if p_value.has(key):
			haystack += " " + String(p_value.get(key, "")).to_lower()
	return haystack.contains(_filter_query)


func _reconcile_selection() -> void:
	var visible := _filtered_instance_identifiers()
	if _selected_instance_identifier.is_empty() or not visible.has(_selected_instance_identifier):
		_selected_instance_identifier = String(visible[0]) if not visible.is_empty() else ""
	var selected_trace := get_selected_trace()
	if _selected_trace_key.is_empty() or selected_trace.is_empty():
		_selected_trace_key = ""
		var visible_traces := get_trace_records()
		if not visible_traces.is_empty() and not _selected_instance_identifier.is_empty():
			for trace in visible_traces:
				if String(trace.get("instance_identifier", "")) == _selected_instance_identifier:
					_selected_trace_key = _trace_key(trace)
					break


func _trace_key(p_trace: Dictionary) -> String:
	return "%s|%d|%d|%s|%s|%s" % [
		String(p_trace.get("instance_identifier", "")),
		int(p_trace.get("revision", 0)),
		int(p_trace.get("ordinal", 0)),
		String(p_trace.get("kind", "")),
		String(p_trace.get("node_identifier", "")),
		String(p_trace.get("request_identifier", p_trace.get("event_identifier", ""))) \
				+ "|" + String(p_trace.get("event_identifier", "")) \
				+ "|" + String(p_trace.get("outcome_identifier", "")),
	]


func _result(p_ok: bool, p_diagnostic: Dictionary = {}) -> Dictionary:
	var result := {"ok": p_ok, "state": String(_state), "read_only": true}
	if not p_diagnostic.is_empty():
		result["diagnostic"] = p_diagnostic.duplicate(true)
	return result


func _reject(p_code: String, p_message: String, p_path: String) -> Dictionary:
	_diagnostic = _diagnostic_value(p_code, p_message, p_path)
	_state = STATE_ERROR
	return _result(false, _diagnostic)


func _diagnostic_value(p_code: String, p_message: String, p_path: String) -> Dictionary:
	return {"code": p_code, "message": p_message, "path": p_path}


func _normalize_limits(p_input: Dictionary) -> Dictionary:
	var result := {
		"max_instances": MAX_INSTANCES,
		"max_trace_records": MAX_TRACE_RECORDS,
		"max_node_summaries_per_instance": MAX_NODE_SUMMARIES_PER_INSTANCE,
		"max_pending_requests_per_instance": MAX_PENDING_REQUESTS_PER_INSTANCE,
	}
	for key in result.keys():
		if not p_input.has(key):
			continue
		var candidate := int(p_input[key])
		if candidate > 0:
			result[key] = mini(candidate, int(_limit_cap_for(key)))
	return result


func _limit_cap_for(p_key: String) -> int:
	match p_key:
		"max_instances":
			return MAX_INSTANCES
		"max_trace_records":
			return MAX_TRACE_RECORDS
		"max_node_summaries_per_instance":
			return MAX_NODE_SUMMARIES_PER_INSTANCE
		"max_pending_requests_per_instance":
			return MAX_PENDING_REQUESTS_PER_INSTANCE
	return 1


func _array_from_keys(p_source: Dictionary, p_keys: Array) -> Array:
	for key in p_keys:
		if not p_source.has(key):
			continue
		var value = p_source[key]
		if value is Array:
			return value.duplicate(true)
		if value is Dictionary:
			# A map keyed by instance identifier is convenient for streams that
			# carry one trace list per recipient-safe instance.
			var flattened: Array = []
			for owner in value.keys().slice(0, int(_limits.max_instances)):
				var owned = value[owner]
				if owned is Array:
					for entry in owned.slice(0, int(_limits.max_trace_records)):
						if entry is Dictionary:
							var copy: Dictionary = entry.duplicate(true)
							if not copy.has("instance_identifier"):
								copy["instance_identifier"] = String(owner)
							flattened.append(copy)
			return flattened
	return []


func _first_value(p_source: Dictionary, p_keys: Array) -> Variant:
	for key in p_keys:
		if p_source.has(key):
			return p_source[key]
	return ""


func _bounded_string(p_value: Variant, p_limit: int) -> String:
	if p_value is Object or p_value is Callable or p_value is Dictionary or p_value is Array:
		return ""
	if p_value == null:
		return ""
	var candidate := String(p_value)
	if candidate.is_empty():
		return ""
	if candidate.to_utf8_buffer().size() <= p_limit:
		return candidate
	var result := ""
	for character in candidate:
		var next := result + character
		if next.to_utf8_buffer().size() > p_limit:
			break
		result = next
	return result


func _bounded_identifier_value(p_value: Variant) -> String:
	if p_value is int or p_value is float:
		return str(_bounded_uint(p_value))
	return _bounded_string(p_value, MAX_IDENTIFIER_BYTES)


func _bounded_uint(p_value: Variant) -> int:
	if p_value is bool or p_value == null:
		return 0
	if p_value is int or p_value is float:
		return maxi(0, mini(int(p_value), 9223372036854775807))
	if p_value is String or p_value is StringName:
		var parsed := String(p_value).to_int()
		return maxi(0, parsed)
	return 0


func _normalize_graph_status(p_value: Variant) -> String:
	if p_value is int or p_value is float:
		var index := int(p_value)
		return GRAPH_STATUSES[index] if index >= 0 and index < GRAPH_STATUSES.size() else "invalid"
	var normalized := String(p_value).to_lower().strip_edges().replace("-", "_").replace(" ", "_")
	return normalized if GRAPH_STATUSES.has(normalized) else "invalid"


func _normalize_node_state(p_value: Variant) -> String:
	if p_value is int or p_value is float:
		var index := int(p_value)
		return NODE_STATES[index] if index >= 0 and index < NODE_STATES.size() else "inactive"
	var normalized := String(p_value).to_lower().strip_edges().replace("-", "_").replace(" ", "_")
	return normalized if NODE_STATES.has(normalized) else "inactive"


func _normalize_trace_kind(p_value: Variant) -> String:
	if p_value is int or p_value is float:
		var index := int(p_value) - 1
		return TRACE_KINDS[index] if index >= 0 and index < TRACE_KINDS.size() else ""
	var normalized := String(p_value).to_lower().strip_edges().replace("-", "_").replace(" ", "_")
	if normalized.begins_with("task_trace_kind::"):
		normalized = normalized.trim_prefix("task_trace_kind::")
	return normalized if TRACE_KINDS.has(normalized) else ""


func _normalize_request_kind(p_value: Variant) -> String:
	if p_value is int or p_value is float:
		var index := int(p_value) - 1
		return REQUEST_KINDS[index] if index >= 0 and index < REQUEST_KINDS.size() else "action"
	var normalized := String(p_value).to_lower().strip_edges().replace("-", "_").replace(" ", "_")
	return normalized if REQUEST_KINDS.has(normalized) else "action"


static func _display_word(p_value: String) -> String:
	var parts := p_value.replace("-", "_").split("_")
	var words := PackedStringArray()
	for part in parts:
		if not part.is_empty():
			words.append(part.capitalize())
	return " ".join(words)


static func _compare_instance_summaries(a: Dictionary, b: Dictionary) -> bool:
	var a_id := String(a.get("instance_identifier", ""))
	var b_id := String(b.get("instance_identifier", ""))
	if a_id != b_id:
		return a_id < b_id
	var a_revision := int(a.get("revision", 0))
	var b_revision := int(b.get("revision", 0))
	if a_revision != b_revision:
		return a_revision > b_revision
	return String(a.get("status", "")) < String(b.get("status", ""))


static func _compare_node_summaries(a: Dictionary, b: Dictionary) -> bool:
	return String(a.get("node_identifier", "")) < String(b.get("node_identifier", ""))


static func _compare_pending_requests(a: Dictionary, b: Dictionary) -> bool:
	return String(a.get("request_identifier", "")) < String(b.get("request_identifier", ""))


static func _compare_trace_records(a: Dictionary, b: Dictionary) -> bool:
	var a_instance := String(a.get("instance_identifier", ""))
	var b_instance := String(b.get("instance_identifier", ""))
	if a_instance != b_instance:
		return a_instance < b_instance
	var a_revision := int(a.get("revision", 0))
	var b_revision := int(b.get("revision", 0))
	if a_revision != b_revision:
		return a_revision < b_revision
	var a_ordinal := int(a.get("ordinal", 0))
	var b_ordinal := int(b.get("ordinal", 0))
	if a_ordinal != b_ordinal:
		return a_ordinal < b_ordinal
	var a_kind := String(a.get("kind", ""))
	var b_kind := String(b.get("kind", ""))
	if a_kind != b_kind:
		return a_kind < b_kind
	var a_node := String(a.get("node_identifier", ""))
	var b_node := String(b.get("node_identifier", ""))
	if a_node != b_node:
		return a_node < b_node
	var a_request := String(a.get("request_identifier", ""))
	var b_request := String(b.get("request_identifier", ""))
	if a_request != b_request:
		return a_request < b_request
	var a_event := String(a.get("event_identifier", ""))
	var b_event := String(b.get("event_identifier", ""))
	if a_event != b_event:
		return a_event < b_event
	return String(a.get("outcome_identifier", "")) < String(b.get("outcome_identifier", ""))
