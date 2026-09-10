class_name LtsDocumentPersistence
extends RefCounted

## Save/checkpoint and external-file coordination for a document model.
##
## This class deliberately knows nothing about ResourceSaver, EditorInterface,
## or a particular editor widget.  A workspace supplies a writer/loader
## callback for native Resources; headless tests can use dictionaries or the
## explicit JSON file helpers.  Semantic document data and editor layout data
## have separate payloads, fingerprints, dirty flags, and save checkpoints.

const Model := preload("res://addons/level_task_system/editor/document/lts_document_model.gd")

const DOCUMENT_SCHEMA_VERSION := 1
const LAYOUT_SCHEMA_VERSION := 1
const DECISION_RELOAD := "reload"
const DECISION_KEEP := "keep"
const DECISION_COMPARE := "compare"

signal state_changed(state: Dictionary)
signal save_completed(result: Dictionary)
signal external_change_detected(change: Dictionary)
signal reload_conflict_detected(conflict: Dictionary)

var _model: Object
var _history: Object
var _source_path := ""
var _layout_path := ""
var _workspace_id := "default"
var _writer: Variant = null
var _layout_writer: Variant = null
var _loader: Variant = null
var _json_file_mode := false

var _saved_semantic: Dictionary = {}
var _saved_semantic_fingerprint := ""
var _saved_layout_fingerprints: Dictionary = {}
var _disk_signature: Dictionary = {}
var _external_signature: Dictionary = {}
var _external_state: Dictionary = {}
var _last_external_change: Dictionary = {}
var _save_error: Dictionary = {}
var _layout_save_error: Dictionary = {}
var _conflict: Dictionary = {}
var _last_save_result: Dictionary = {}
var _workspace_layouts: Dictionary = {}


func _init(model: Object = null, source_path: String = "", history: Object = null) -> void:
	_model = model
	_history = history
	_source_path = source_path
	_layout_path = layout_path_for(source_path)
	establish_checkpoint()


func set_model(model: Object, reset_checkpoint: bool = true) -> void:
	_model = model
	if reset_checkpoint:
		establish_checkpoint()


func get_model() -> Object:
	return _model


func set_history(history: Object) -> void:
	_history = history


func get_history() -> Object:
	return _history


func set_source_path(path: String) -> void:
	_source_path = path
	_layout_path = layout_path_for(path)


func get_source_path() -> String:
	return _source_path


func set_layout_path(path: String) -> void:
	_layout_path = path


func get_layout_path() -> String:
	return _layout_path if not _layout_path.is_empty() else layout_path_for(_source_path)


func set_writer(writer: Variant) -> void:
	_writer = writer


func set_layout_writer(writer: Variant) -> void:
	_layout_writer = writer


func get_layout_writer() -> Variant:
	return _layout_writer


func set_loader(loader: Variant) -> void:
	_loader = loader


func set_json_file_mode(enabled: bool) -> void:
	_json_file_mode = enabled


func semantic_snapshot() -> Dictionary:
	if _model != null and _model.has_method("semantic_snapshot"):
		return _model.call("semantic_snapshot")
	return {"schema_version": Model.DOCUMENT_SCHEMA_VERSION, "documents": {}}


func layout_snapshot() -> Dictionary:
	if _model != null and _model.has_method("layout_snapshot"):
		return _model.call("layout_snapshot")
	return {"layout": {}, "selection": {}, "navigator": {}}


func semantic_fingerprint(snapshot: Dictionary = {}) -> String:
	var value := snapshot if not snapshot.is_empty() else semantic_snapshot()
	return canonical_json(value).sha256_text()


func layout_fingerprint(snapshot: Dictionary = {}) -> String:
	var value := snapshot if not snapshot.is_empty() else layout_snapshot()
	return canonical_json(value).sha256_text()


func current_runtime_fingerprint() -> String:
	return semantic_fingerprint()


func saved_runtime_fingerprint() -> String:
	return _saved_semantic_fingerprint


func is_dirty() -> bool:
	return semantic_fingerprint() != _saved_semantic_fingerprint


func is_semantic_dirty() -> bool:
	return is_dirty()


func is_layout_dirty(workspace_id: String = "") -> bool:
	var key := workspace_id if not workspace_id.is_empty() else _workspace_id
	capture_workspace_layout(key)
	if not _saved_layout_fingerprints.has(key):
		# An unseen workspace starts at its first captured layout, not at an
		# artificial dirty state.  `set_workspace_layout` installs an explicit
		# empty-layout baseline when callers intentionally seed a new workspace.
		if not _workspace_layouts.has(key):
			return false
		_saved_layout_fingerprints[key] = layout_fingerprint(_workspace_layouts[key])
	var baseline := String(_saved_layout_fingerprints.get(key, ""))
	return layout_fingerprint(_workspace_layouts.get(key, {})) != baseline


func has_unsaved_changes() -> bool:
	return is_dirty() or is_layout_dirty()


func is_at_save_checkpoint() -> bool:
	return not is_dirty()


func establish_checkpoint(disk_signature: Variant = null) -> Dictionary:
	_saved_semantic = semantic_snapshot()
	_saved_semantic_fingerprint = semantic_fingerprint(_saved_semantic)
	_save_error.clear()
	_conflict.clear()
	_external_state.clear()
	_external_signature.clear()
	_last_external_change.clear()
	_workspace_layouts.clear()
	_saved_layout_fingerprints.clear()
	if disk_signature == null:
		if not _source_path.is_empty() and FileAccess.file_exists(_source_path):
			_disk_signature = file_signature(_source_path)
		else:
			_disk_signature = {}
	else:
		_disk_signature = _normalize_signature(disk_signature)
	var layout := layout_snapshot()
	_workspace_layouts[_workspace_id] = layout.duplicate(true)
	_saved_layout_fingerprints[_workspace_id] = layout_fingerprint(layout)
	return get_state()


func mark_saved(disk_signature: Variant = null) -> Dictionary:
	_saved_semantic = semantic_snapshot()
	_saved_semantic_fingerprint = semantic_fingerprint(_saved_semantic)
	_save_error.clear()
	if disk_signature == null:
		if not _source_path.is_empty() and FileAccess.file_exists(_source_path):
			_disk_signature = file_signature(_source_path)
		else:
			# Writer adapters are allowed to return only success.  Keep a stable
			# content signature in that case instead of retaining a pre-save disk
			# signature that would make the next observation look stale.
			_disk_signature = {"fingerprint": _saved_semantic_fingerprint}
	else:
		_disk_signature = _normalize_signature(disk_signature)
	return _emit_state()


func mark_save_checkpoint(disk_signature: Variant = null) -> Dictionary:
	return mark_saved(disk_signature)


func get_saved_semantic_snapshot() -> Dictionary:
	return _saved_semantic.duplicate(true)


func get_save_error() -> Dictionary:
	return _save_error.duplicate(true)


func last_save_error() -> Dictionary:
	return get_save_error()


func clear_save_error() -> void:
	_save_error.clear()
	_emit_state()


func get_last_save_result() -> Dictionary:
	return _last_save_result.duplicate(true)


## Canonical resource payload.  Layout, selection, navigator, and source path
## are intentionally absent so editor-only changes cannot alter runtime data.
func document_payload() -> Dictionary:
	var semantic := semantic_snapshot()
	return {
		"schema_version": DOCUMENT_SCHEMA_VERSION,
		"kind": "level_task_system_document",
		"semantic": semantic,
		"semantic_fingerprint": semantic_fingerprint(semantic),
	}


func serialize_document() -> Dictionary:
	return document_payload()


func serialize_document_json() -> String:
	return canonical_json(document_payload())


static func encode_document(snapshot: Dictionary) -> Dictionary:
	var semantic := _extract_semantic_static(snapshot)
	return {
		"schema_version": DOCUMENT_SCHEMA_VERSION,
		"kind": "level_task_system_document",
		"semantic": semantic,
		"semantic_fingerprint": canonical_json(semantic).sha256_text(),
	}


static func decode_document(source: Variant) -> Dictionary:
	var value = source
	if source is String:
		value = JSON.parse_string(source)
	if not value is Dictionary:
		return {"ok": false, "error": {"code": "LTS-PERSIST-001", "path": "document", "severity": "error", "message": "Document payload is not an object"}}
	var semantic := _extract_semantic_static(value)
	if semantic.is_empty() or not semantic.has("documents"):
		return {"ok": false, "error": {"code": "LTS-PERSIST-002", "path": "document.semantic", "severity": "error", "message": "Document payload has no semantic documents"}}
	return {"ok": true, "schema_version": int(value.get("schema_version", DOCUMENT_SCHEMA_VERSION)), "semantic": semantic, "payload": value.duplicate(true)}


func round_trip_document() -> Dictionary:
	return decode_document(serialize_document_json())


## Explicit save.  A writer may return bool, an error code, or a dictionary
## `{ok, error, signature}`.  A void callback is treated as success.  Failure
## never advances the save checkpoint, so retrying is safe and preserves the
## dirty marker and the failed context.
func save(writer: Variant = null) -> Dictionary:
	# Retain an explicitly supplied writer so a failed save can be retried
	# without requiring the caller to reconstruct its callback or adapter.
	if writer != null:
		_writer = writer
	var target = writer if writer != null else _writer
	var payload := document_payload()
	var io_result: Variant
	if target != null:
		io_result = _invoke_writer(target, payload)
	elif _json_file_mode and not _source_path.is_empty():
		io_result = _write_json_file(_source_path, payload)
	else:
		return _save_failure("LTS-PERSIST-003", "No document writer is configured", _source_path if not _source_path.is_empty() else "document")
	var normalized := _normalize_io_result(io_result, "save")
	if not bool(normalized.get("ok", false)):
		return _save_failure(String(normalized.get("code", "LTS-PERSIST-004")), String(normalized.get("message", "Document save failed")), String(normalized.get("path", _source_path)), normalized)
	var signature = normalized.get("signature", null)
	if signature == null and not _source_path.is_empty() and _json_file_mode and FileAccess.file_exists(_source_path):
		signature = file_signature(_source_path)
	mark_saved(signature)
	_last_save_result = {
		"ok": true,
		"saved": true,
		"path": _source_path,
		"payload": payload.duplicate(true),
		"semantic_fingerprint": _saved_semantic_fingerprint,
		"signature": _disk_signature.duplicate(true),
	}
	save_completed.emit(_last_save_result.duplicate(true))
	return _last_save_result.duplicate(true)


func save_with_writer(writer: Variant) -> Dictionary:
	return save(writer)


func retry_save() -> Dictionary:
	return save()


func save_to_path(path: String) -> Dictionary:
	if path.is_empty():
		return _save_failure("LTS-PERSIST-005", "Save path is empty", "document.path")
	var payload := document_payload()
	var io_result := _write_json_file(path, payload)
	var normalized := _normalize_io_result(io_result, "save")
	if not bool(normalized.get("ok", false)):
		return _save_failure(String(normalized.get("code", "LTS-PERSIST-006")), String(normalized.get("message", "Document save failed")), path, normalized)
	_source_path = path
	if _layout_path.is_empty():
		_layout_path = layout_path_for(path)
	mark_saved(normalized.get("signature", file_signature(path)))
	_last_save_result = {"ok": true, "saved": true, "path": path, "payload": payload.duplicate(true), "semantic_fingerprint": _saved_semantic_fingerprint, "signature": _disk_signature.duplicate(true)}
	save_completed.emit(_last_save_result.duplicate(true))
	return _last_save_result.duplicate(true)


## Observe a supplied signature (or the current source path) after another
## process has written the resource.  The local state is never overwritten by
## detection; the caller must make an explicit reload/keep/compare decision.
func observe_disk(signature_or_state: Variant = null, external_state: Dictionary = {}) -> Dictionary:
	var observed_signature: Dictionary
	var observed_state := external_state.duplicate(true)
	if signature_or_state == null:
		if not observed_state.is_empty():
			var supplied_semantic := _extract_semantic(observed_state)
			observed_signature = {"fingerprint": semantic_fingerprint(supplied_semantic)} if not supplied_semantic.is_empty() else {}
		else:
			observed_signature = file_signature(_source_path)
	elif signature_or_state is Dictionary and (signature_or_state.has("documents") or signature_or_state.has("semantic") or signature_or_state.has("state")):
		# A serialized document may also carry a fingerprint, mtime, or path;
		# semantic content is still authoritative for the conflict payload.
		observed_state = signature_or_state.duplicate(true)
		var semantic := _extract_semantic(observed_state)
		observed_signature = {"fingerprint": semantic_fingerprint(semantic)} if not semantic.is_empty() else {}
	else:
		observed_signature = _normalize_signature(signature_or_state)
	if observed_signature.is_empty():
		return {"ok": false, "detected": false, "error": {"code": "LTS-PERSIST-007", "path": _source_path, "severity": "error", "message": "External signature is unavailable"}, "state": get_state()}
	if _disk_signature.is_empty():
		_disk_signature = observed_signature.duplicate(true)
		return {"ok": true, "detected": false, "first_observation": true, "signature": observed_signature.duplicate(true), "state": get_state()}
	if _signatures_equal(_disk_signature, observed_signature):
		return {"ok": true, "detected": false, "signature": observed_signature.duplicate(true), "state": get_state()}
	_external_signature = observed_signature.duplicate(true)
	_external_state = observed_state
	_last_external_change = {
		"detected": true,
		"source_path": _source_path,
		"previous_signature": _disk_signature.duplicate(true),
		"signature": observed_signature.duplicate(true),
		"dirty": is_dirty(),
		"external_state": observed_state.duplicate(true),
	}
	_conflict = {
		"required": true,
		"kind": "reload_conflict" if is_dirty() else "external_change",
		"choices": [DECISION_RELOAD, DECISION_KEEP, DECISION_COMPARE],
		"local_semantic": semantic_snapshot(),
		"external_semantic": _extract_semantic(observed_state),
		"change": _last_external_change.duplicate(true),
	}
	external_change_detected.emit(_last_external_change.duplicate(true))
	reload_conflict_detected.emit(_conflict.duplicate(true))
	_emit_state()
	return {"ok": true, "detected": true, "conflict": _conflict.duplicate(true), "state": get_state()}


func check_external_change(signature_or_state: Variant = null, external_state: Dictionary = {}) -> Dictionary:
	return observe_disk(signature_or_state, external_state)


func poll_external_change() -> Dictionary:
	return observe_disk()


func has_external_change() -> bool:
	return bool(_conflict.get("required", false))


func get_external_change() -> Dictionary:
	return _last_external_change.duplicate(true)


func has_reload_conflict() -> bool:
	return String(_conflict.get("kind", "")) == "reload_conflict"


func get_reload_conflict() -> Dictionary:
	return _conflict.duplicate(true)


func decide_reload(decision: String, external_state: Dictionary = {}, external_signature: Variant = null) -> Dictionary:
	var choice := decision.strip_edges().to_lower()
	if not _conflict.get("required", false):
		return {"ok": false, "error": {"code": "LTS-PERSIST-008", "path": "reload", "severity": "error", "message": "There is no external change to resolve"}, "state": get_state()}
	if choice == DECISION_COMPARE:
		return compare_external(external_state)
	if choice != DECISION_RELOAD and choice != DECISION_KEEP:
		return {"ok": false, "error": {"code": "LTS-PERSIST-009", "path": "reload.decision", "severity": "error", "message": "Reload decision must be reload, keep, or compare"}, "state": get_state()}
	var signature := _normalize_signature(external_signature) if external_signature != null else _external_signature.duplicate(true)
	if choice == DECISION_KEEP:
		_disk_signature = signature
		_last_external_change["decision"] = DECISION_KEEP
		_last_external_change["acknowledged"] = true
		_conflict.clear()
		_external_state.clear()
		_external_signature.clear()
		_emit_state()
		return {"ok": true, "decision": DECISION_KEEP, "kept_local": true, "dirty": is_dirty(), "state": get_state()}
	var incoming := external_state.duplicate(true) if not external_state.is_empty() else _external_state.duplicate(true)
	if incoming.is_empty():
		var loaded := _invoke_loader(signature)
		if not bool(loaded.get("ok", false)):
			return _reload_failure(String(loaded.get("code", "LTS-PERSIST-010")), String(loaded.get("message", "External document could not be loaded")), loaded)
		incoming = loaded.get("state", loaded.get("semantic", {}))
	var semantic := _extract_semantic(incoming)
	if semantic.is_empty() or not semantic.has("documents"):
		return _reload_failure("LTS-PERSIST-011", "External document has no semantic documents", {"path": _source_path})
	if _model == null or not _model.has_method("load_semantic_snapshot"):
		return _reload_failure("LTS-PERSIST-012", "Document model cannot reload semantic data", {"path": "history.model"})
	var reloaded: Dictionary = _model.call("load_semantic_snapshot", semantic, true)
	if not bool(reloaded.get("ok", false)):
		return _reload_failure(String(reloaded.get("error", {}).get("code", "LTS-PERSIST-013")), String(reloaded.get("error", {}).get("message", "External reload failed")), reloaded)
	if _history != null:
		if _history.has_method("clear_local_history"):
			_history.call("clear_local_history")
		elif _history.has_method("clear"):
			_history.call("clear")
	_disk_signature = signature
	_saved_semantic = semantic_snapshot()
	_saved_semantic_fingerprint = semantic_fingerprint(_saved_semantic)
	_save_error.clear()
	_last_external_change["decision"] = DECISION_RELOAD
	_last_external_change["acknowledged"] = true
	_conflict.clear()
	_external_state.clear()
	_external_signature.clear()
	_emit_state()
	return {"ok": true, "decision": DECISION_RELOAD, "reloaded": true, "dirty": false, "state": get_state(), "document": reloaded}


func resolve_reload(decision: String, external_state: Dictionary = {}, external_signature: Variant = null) -> Dictionary:
	return decide_reload(decision, external_state, external_signature)


func reload_from_state(external_state: Dictionary, external_signature: Variant = null) -> Dictionary:
	if not _conflict.get("required", false):
		# Explicit reload from a caller-provided source is also useful on open.
		_external_state = external_state.duplicate(true)
		_external_signature = _normalize_signature(external_signature)
		_conflict = {"required": true, "kind": "external_change", "choices": [DECISION_RELOAD, DECISION_KEEP, DECISION_COMPARE]}
	return decide_reload(DECISION_RELOAD, external_state, external_signature)


func compare_external(external_state: Dictionary = {}) -> Dictionary:
	var incoming := external_state.duplicate(true) if not external_state.is_empty() else _external_state.duplicate(true)
	var semantic := _extract_semantic(incoming)
	if semantic.is_empty():
		return {"ok": false, "comparison_available": false, "error": {"code": "LTS-PERSIST-014", "path": "reload.compare", "severity": "error", "message": "External semantic state is unavailable"}, "state": get_state()}
	var local := semantic_snapshot()
	var changes := _diff_values(local, semantic, "")
	return {
		"ok": true,
		"comparison_available": true,
		"same": changes.is_empty(),
		"changes": changes,
		"local": local,
		"external": semantic,
		"state": get_state(),
	}


## Layout is persisted separately from runtime definitions and keyed by a
## workspace identifier.  Loading a layout never changes the semantic
## fingerprint or save checkpoint.
func current_workspace_id() -> String:
	return _workspace_id


func set_workspace(workspace_id: String, apply_layout: bool = true) -> Dictionary:
	if workspace_id.is_empty():
		workspace_id = "default"
	capture_workspace_layout(_workspace_id)
	var has_saved_layout := _workspace_layouts.has(workspace_id)
	_workspace_id = workspace_id
	if not has_saved_layout:
		_workspace_layouts[_workspace_id] = _empty_layout_snapshot()
		_saved_layout_fingerprints[_workspace_id] = layout_fingerprint(_workspace_layouts[_workspace_id])
	var selected: Dictionary = _workspace_layouts.get(_workspace_id, {}).duplicate(true)
	if apply_layout and _model != null and _model.has_method("load_layout_snapshot"):
		_model.call("load_layout_snapshot", selected)
	return {"ok": true, "workspace_id": _workspace_id, "layout": selected, "state": get_state()}


func capture_workspace_layout(workspace_id: String = "") -> Dictionary:
	var key := workspace_id if not workspace_id.is_empty() else _workspace_id
	if key == _workspace_id:
		_workspace_layouts[key] = layout_snapshot().duplicate(true)
	return _workspace_layouts.get(key, {}).duplicate(true)


func get_workspace_layout(workspace_id: String = "") -> Dictionary:
	var key := workspace_id if not workspace_id.is_empty() else _workspace_id
	return capture_workspace_layout(key)


func set_workspace_layout(workspace_id: String, layout: Dictionary, apply_layout: bool = true) -> Dictionary:
	var key := workspace_id if not workspace_id.is_empty() else "default"
	if not _saved_layout_fingerprints.has(key):
		_saved_layout_fingerprints[key] = layout_fingerprint(_empty_layout_snapshot())
	_workspace_layouts[key] = _normalize_layout_snapshot(layout)
	if key == _workspace_id and apply_layout and _model != null and _model.has_method("load_layout_snapshot"):
		_model.call("load_layout_snapshot", _workspace_layouts[key])
		_workspace_layouts[key] = layout_snapshot().duplicate(true)
	return {"ok": true, "workspace_id": key, "layout": _workspace_layouts[key].duplicate(true), "layout_dirty": is_layout_dirty(key), "state": get_state()}


func is_workspace_layout_dirty(workspace_id: String = "") -> bool:
	return is_layout_dirty(workspace_id)


func layout_payload(workspace_id: String = "") -> Dictionary:
	var key := workspace_id if not workspace_id.is_empty() else _workspace_id
	capture_workspace_layout(key)
	return {
		"schema_version": LAYOUT_SCHEMA_VERSION,
		"kind": "level_task_system_editor_layout",
		"workspace_id": key,
		"active_workspace": _workspace_id,
		"workspaces": _workspace_layouts.duplicate(true),
		"layout": _workspace_layouts.get(key, {}).duplicate(true),
	}


func serialize_layout(workspace_id: String = "") -> Dictionary:
	return layout_payload(workspace_id)


func save_layout(writer: Variant = null, workspace_id: String = "") -> Dictionary:
	var key := workspace_id if not workspace_id.is_empty() else _workspace_id
	capture_workspace_layout(key)
	var payload := layout_payload(key)
	if writer != null:
		_layout_writer = writer
	var target = writer if writer != null else _layout_writer
	if target == null and _writer != null:
		# A single writer may optionally understand the `kind` field.  An
		# explicit layout path is preferred when one was supplied.
		target = _writer
	var io_result: Variant
	if target != null:
		io_result = _invoke_writer(target, payload)
	elif not get_layout_path().is_empty():
		io_result = _write_json_file(get_layout_path(), payload)
	else:
		return _layout_save_failure("LTS-PERSIST-015", "No editor-layout writer is configured", "layout")
	var normalized := _normalize_io_result(io_result, "layout_save")
	if not bool(normalized.get("ok", false)):
		return _layout_save_failure(String(normalized.get("code", "LTS-PERSIST-016")), String(normalized.get("message", "Editor layout save failed")), String(normalized.get("path", get_layout_path())), normalized)
	_saved_layout_fingerprints[key] = layout_fingerprint(_workspace_layouts.get(key, {}))
	_layout_save_error.clear()
	var result := {"ok": true, "saved": true, "workspace_id": key, "path": get_layout_path(), "payload": payload.duplicate(true), "layout_fingerprint": _saved_layout_fingerprints[key]}
	_emit_state()
	return result


func save_layout_to_path(path: String, workspace_id: String = "") -> Dictionary:
	if path.is_empty():
		return _layout_save_failure("LTS-PERSIST-026", "Editor-layout path is empty", "layout.path")
	_layout_path = path
	var key := workspace_id if not workspace_id.is_empty() else _workspace_id
	capture_workspace_layout(key)
	var payload := layout_payload(key)
	var normalized := _normalize_io_result(_write_json_file(path, payload), "layout_save")
	if not bool(normalized.get("ok", false)):
		return _layout_save_failure(String(normalized.get("code", "LTS-PERSIST-027")), String(normalized.get("message", "Editor layout save failed")), path, normalized)
	_saved_layout_fingerprints[key] = layout_fingerprint(_workspace_layouts.get(key, {}))
	_layout_save_error.clear()
	var result := {"ok": true, "saved": true, "workspace_id": key, "path": path, "payload": payload.duplicate(true), "layout_fingerprint": _saved_layout_fingerprints[key]}
	_emit_state()
	return result


func retry_layout_save() -> Dictionary:
	return save_layout()


func clear_layout_save_error() -> void:
	_layout_save_error.clear()
	_emit_state()


func load_layout(source: Variant, workspace_id: String = "", apply_layout: bool = true) -> Dictionary:
	var decoded = source
	if source is String:
		decoded = JSON.parse_string(source)
	if not decoded is Dictionary:
		return {"ok": false, "error": {"code": "LTS-PERSIST-017", "path": "layout", "severity": "error", "message": "Editor layout payload is not an object"}, "state": get_state()}
	var payload: Dictionary = decoded
	var workspaces = payload.get("workspaces", null)
	if workspaces is Dictionary:
		for key in workspaces:
			if workspaces[key] is Dictionary:
				_workspace_layouts[String(key)] = _normalize_layout_snapshot(workspaces[key])
	var key := workspace_id
	if key.is_empty():
		key = String(payload.get("workspace_id", _workspace_id))
	if key.is_empty():
		key = "default"
	var selected: Dictionary = _workspace_layouts.get(key, {}).duplicate(true)
	if selected.is_empty() and payload.get("layout", null) is Dictionary:
		selected = _normalize_layout_snapshot(payload["layout"])
		_workspace_layouts[key] = selected.duplicate(true)
	_workspace_id = key
	if apply_layout and not selected.is_empty() and _model != null and _model.has_method("load_layout_snapshot"):
		_model.call("load_layout_snapshot", selected)
	_saved_layout_fingerprints[key] = layout_fingerprint(selected)
	_layout_save_error.clear()
	return {"ok": true, "loaded": true, "workspace_id": key, "layout": selected, "state": get_state()}


func load_layout_from_path(path: String, workspace_id: String = "", apply_layout: bool = true) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"ok": false, "error": {"code": "LTS-PERSIST-018", "path": path, "severity": "error", "message": "Editor layout file does not exist"}, "state": get_state()}
	var text := FileAccess.get_file_as_string(path)
	var result := load_layout(text, workspace_id, apply_layout)
	if bool(result.get("ok", false)):
		_layout_path = path
	return result


func get_layout_save_error() -> Dictionary:
	return _layout_save_error.duplicate(true)


func get_state() -> Dictionary:
	var key := _workspace_id
	return {
		"source_path": _source_path,
		"layout_path": get_layout_path(),
		"workspace_id": key,
		"dirty": is_dirty(),
		"semantic_dirty": is_dirty(),
		"layout_dirty": is_layout_dirty(key),
		"has_unsaved_changes": has_unsaved_changes(),
		"semantic_fingerprint": semantic_fingerprint(),
		"saved_semantic_fingerprint": _saved_semantic_fingerprint,
		"runtime_fingerprint": semantic_fingerprint(),
		"save_error": _save_error.duplicate(true),
		"layout_save_error": _layout_save_error.duplicate(true),
		"external_change": _last_external_change.duplicate(true),
		"reload_conflict": _conflict.duplicate(true),
		"workspace_layouts": _workspace_layouts.duplicate(true),
	}


func status() -> Dictionary:
	return get_state()


func _emit_state() -> Dictionary:
	var value := get_state()
	state_changed.emit(value.duplicate(true))
	return value


func _empty_layout_snapshot() -> Dictionary:
	return {
		"layout": {
			"graphs": {},
			"conversations": {},
			"levels": {},
			"resources": {},
			"panes": {},
		},
		"selection": {
			"resource_kind": "",
			"resource_identifier": "",
			"element_kind": "",
			"element_identifier": "",
			"field_path": "",
		},
		"navigator": {
			"query": "",
			"path": "",
			"resource_kind": "",
			"resource_identifier": "",
		},
	}


func _normalize_layout_snapshot(source: Dictionary) -> Dictionary:
	var result := _empty_layout_snapshot()
	if source.has("layout") and source.get("layout") is Dictionary:
		result["layout"] = source["layout"].duplicate(true)
	else:
		result["layout"] = source.duplicate(true)
	if source.has("selection") and source.get("selection") is Dictionary:
		for key in result["selection"]:
			if source["selection"].has(key):
				result["selection"][key] = String(source["selection"][key])
	if source.has("navigator") and source.get("navigator") is Dictionary:
		for key in result["navigator"]:
			if source["navigator"].has(key):
				result["navigator"][key] = String(source["navigator"][key])
	return result


func _save_failure(code: String, message: String, path: String, details: Dictionary = {}) -> Dictionary:
	_save_error = {"code": code, "path": path, "severity": "error", "message": message, "retryable": true, "details": details.duplicate(true)}
	_last_save_result = {"ok": false, "saved": false, "error": _save_error.duplicate(true), "dirty": is_dirty(), "state": get_state()}
	save_completed.emit(_last_save_result.duplicate(true))
	_emit_state()
	return _last_save_result.duplicate(true)


func _layout_save_failure(code: String, message: String, path: String, details: Dictionary = {}) -> Dictionary:
	_layout_save_error = {"code": code, "path": path, "severity": "error", "message": message, "retryable": true, "details": details.duplicate(true)}
	var result := {"ok": false, "saved": false, "error": _layout_save_error.duplicate(true), "layout_dirty": is_layout_dirty(), "state": get_state()}
	_emit_state()
	return result


func _reload_failure(code: String, message: String, details: Dictionary = {}) -> Dictionary:
	var error := {"code": code, "path": _source_path, "severity": "error", "message": message, "retryable": true, "details": details.duplicate(true)}
	return {"ok": false, "reloaded": false, "error": error, "conflict": _conflict.duplicate(true), "state": get_state()}


func _invoke_writer(target: Variant, payload: Dictionary) -> Variant:
	if target is Callable:
		return target.call(payload.duplicate(true))
	if target is Object:
		for method_name in ["save_document", "write_document", "save", "write"]:
			if target.has_method(method_name):
				return target.call(method_name, payload.duplicate(true))
	return {"ok": false, "code": "LTS-PERSIST-019", "path": "writer", "message": "Configured writer is not callable"}


func _invoke_loader(signature: Dictionary) -> Dictionary:
	if _loader == null:
		return {"ok": false, "code": "LTS-PERSIST-020", "path": _source_path, "message": "No external document loader is configured"}
	var loaded: Variant
	if _loader is Callable:
		loaded = _loader.call(signature.duplicate(true))
	elif _loader is Object:
		for method_name in ["load_document", "read_document", "load", "read"]:
			if _loader.has_method(method_name):
				loaded = _loader.call(method_name, signature.duplicate(true))
				break
	if loaded is Dictionary:
		if loaded.has("ok"):
			return loaded
		return {"ok": true, "state": loaded}
	return {"ok": false, "code": "LTS-PERSIST-021", "path": _source_path, "message": "External loader returned no document"}


func _write_json_file(path: String, payload: Dictionary) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return {"ok": false, "code": "LTS-PERSIST-022", "path": path, "message": "Unable to open document path for writing"}
	file.store_string(canonical_json(payload))
	file.flush()
	file.close()
	return {"ok": true, "signature": file_signature(path)}


func _normalize_io_result(value: Variant, operation: String) -> Dictionary:
	if value is Dictionary:
		var result: Dictionary = value.duplicate(true)
		if not result.has("ok"):
			result["ok"] = true
		return result
	if value is bool:
		return {"ok": value, "code": "LTS-PERSIST-023" if not value else "", "message": "%s failed" % operation if not value else ""}
	if value is int:
		return {"ok": value == 0, "code": "LTS-PERSIST-024" if value != 0 else "", "message": "%s failed with code %d" % [operation, value] if value != 0 else ""}
	# A callback that does not return a value is a successful write by contract.
	if value == null:
		return {"ok": true}
	return {"ok": false, "code": "LTS-PERSIST-025", "message": "Writer returned an unsupported result"}


func _normalize_signature(value: Variant) -> Dictionary:
	if value is Dictionary:
		if value.has("signature"):
			return _normalize_signature(value["signature"])
		return value.duplicate(true)
	if value is String:
		return {"fingerprint": value}
	if value is int:
		return {"fingerprint": str(value)}
	return {}


func _signatures_equal(left: Dictionary, right: Dictionary) -> bool:
	return not left.is_empty() and not right.is_empty() and canonical_json(left) == canonical_json(right)


func _extract_semantic(source: Variant) -> Dictionary:
	return _extract_semantic_static(source)


static func _extract_semantic_static(source: Variant) -> Dictionary:
	if not source is Dictionary:
		return {}
	if source.has("state") and source.get("state") is Dictionary:
		var from_state := _extract_semantic_static(source["state"])
		if not from_state.is_empty():
			return from_state
	if source.has("semantic") and source.get("semantic") is Dictionary:
		return source["semantic"].duplicate(true)
	if source.has("documents") and source.get("documents") is Dictionary:
		return {"schema_version": int(source.get("schema_version", Model.DOCUMENT_SCHEMA_VERSION)), "documents": source["documents"].duplicate(true)}
	return {}


static func canonical_json(value: Variant) -> String:
	if value is Dictionary:
		var keys: Array = value.keys()
		keys.sort()
		var parts: Array = []
		for key in keys:
			parts.append(JSON.stringify(String(key)) + ":" + canonical_json(value[key]))
		return "{" + ",".join(PackedStringArray(parts)) + "}"
	if value is Array:
		var parts: Array = []
		for item in value:
			parts.append(canonical_json(item))
		return "[" + ",".join(PackedStringArray(parts)) + "]"
	if value is StringName:
		return JSON.stringify(String(value))
	if value is Vector2:
		return "[" + _number_json(value.x) + "," + _number_json(value.y) + "]"
	if value is Vector2i:
		return "[" + str(value.x) + "," + str(value.y) + "]"
	return JSON.stringify(value)


static func _number_json(value: float) -> String:
	return JSON.stringify(value)


static func file_signature(path: String) -> Dictionary:
	if path.is_empty() or not FileAccess.file_exists(path):
		return {"path": path, "exists": false}
	var bytes := FileAccess.get_file_as_bytes(path)
	var digest := bytes.hex_encode()
	return {
		"path": path,
		"exists": true,
		"size": bytes.size(),
		"mtime": FileAccess.get_modified_time(path),
		"hash": digest,
	}


static func layout_path_for(source_path: String) -> String:
	if source_path.is_empty():
		return ""
	return source_path + ".editor-layout.json"


static func _diff_values(before: Variant, after: Variant, path: String) -> Array:
	var changes: Array = []
	if before is Dictionary and after is Dictionary:
		var keys: Dictionary = {}
		for key in before:
			keys[String(key)] = true
		for key in after:
			keys[String(key)] = true
		var sorted_keys: Array = keys.keys()
		sorted_keys.sort()
		for key in sorted_keys:
			var child_path := String(key) if path.is_empty() else path + "." + String(key)
			if not before.has(key):
				changes.append({"path": child_path, "kind": "added", "before": null, "after": after[key]})
			elif not after.has(key):
				changes.append({"path": child_path, "kind": "removed", "before": before[key], "after": null})
			else:
				changes.append_array(_diff_values(before[key], after[key], child_path))
		return changes
	if before is Array and after is Array:
		var length: int = maxi(before.size(), after.size())
		for index in length:
			var child_path := "%s[%d]" % [path, index]
			if index >= before.size():
				changes.append({"path": child_path, "kind": "added", "before": null, "after": after[index]})
			elif index >= after.size():
				changes.append({"path": child_path, "kind": "removed", "before": before[index], "after": null})
			else:
				changes.append_array(_diff_values(before[index], after[index], child_path))
		return changes
	if canonical_json(before) != canonical_json(after):
		changes.append({"path": path, "kind": "changed", "before": before, "after": after})
	return changes
