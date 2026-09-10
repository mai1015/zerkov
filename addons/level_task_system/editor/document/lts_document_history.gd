class_name LtsDocumentHistory
extends RefCounted

## Reversible document command history for the Level Task System editor.
##
## The model remains editor-independent.  When a Godot UndoRedo-compatible
## object is supplied, every action is registered with it using do/undo method
## calls.  In a headless test (or a plain tool process) the same command and
## inverse dictionaries are kept in a small local stack.  Both paths execute
## the exact same model command, so tests do not need EditorInterface or a
## native EditorUndoRedoManager instance.

const Command := preload("res://addons/level_task_system/editor/document/lts_document_command.gd")
const Model := preload("res://addons/level_task_system/editor/document/lts_document_model.gd")

const MUTATION_SEMANTIC := Command.MUTATION_SEMANTIC
const MUTATION_LAYOUT := Command.MUTATION_LAYOUT
const MUTATION_MIXED := Command.MUTATION_MIXED

signal changed(result: Dictionary)
signal action_committed(result: Dictionary)

var _model: Object
var _backend: Object
var _entries: Array = []
var _cursor := 0
var _next_entry_id := 1
var _last_callback_result: Dictionary = {}
var _gesture: Dictionary = {}


func _init(model: Object = null, undo_redo: Object = null) -> void:
	_model = model
	_backend = undo_redo


func set_model(model: Object) -> void:
	_model = model
	clear_local_history()


func get_model() -> Object:
	return _model


func set_undo_redo(undo_redo: Object) -> void:
	_backend = undo_redo


func get_undo_redo() -> Object:
	return _backend


func has_godot_backend() -> bool:
	return _backend != null and _backend.has_method("create_action") and _backend.has_method("add_do_method") and _backend.has_method("add_undo_method") and _backend.has_method("commit_action")


func backend_name() -> String:
	if not has_godot_backend():
		return "local"
	if _backend.has_method("get_class"):
		return String(_backend.get_class())
	return "undo_redo"


## Apply one command and commit one undo action.  `action_name` is also shown
## by Godot's native history UI when a backend is connected.
func execute(command: Variant, action_name: String = "Edit document", options: Dictionary = {}) -> Dictionary:
	if _gesture.get("active", false):
		return _failure("LTS-HISTORY-001", "A coalesced action is active; finish or cancel it first", "history.gesture")
	var data := _command_data(command)
	if data.is_empty():
		return _failure("LTS-HISTORY-002", "Command is not serializable", "command")
	if _model == null or not _model.has_method("apply_command"):
		return _failure("LTS-HISTORY-003", "History has no document model", "history.model")
	var preview: Dictionary
	if _model.has_method("preview_command"):
		preview = _model.call("preview_command", data)
	else:
		# Keep compatibility with a minimal test double that only implements
		# apply_command.  In that case the command is applied before the action
		# is registered and its returned inverse is used.
		var applied: Dictionary = _model.call("apply_command", data)
		if not bool(applied.get("ok", false)):
			return applied
		preview = applied.duplicate(true)
		return _record_action(action_name, data, preview.get("inverse", {}), true, options, applied)
	if not bool(preview.get("ok", false)):
		return preview
	return _record_action(action_name, data, preview.get("inverse", {}), false, options, {})


func apply(command: Variant, action_name: String = "Edit document", options: Dictionary = {}) -> Dictionary:
	return execute(command, action_name, options)


func perform(command: Variant, action_name: String = "Edit document", options: Dictionary = {}) -> Dictionary:
	return execute(command, action_name, options)


func commit(command: Variant, action_name: String = "Edit document", options: Dictionary = {}) -> Dictionary:
	return execute(command, action_name, options)


func undo() -> Dictionary:
	if _gesture.get("active", false):
		return _failure("LTS-HISTORY-004", "A coalesced action is active; finish or cancel it first", "history.gesture")
	if _cursor <= 0 or _cursor > _entries.size():
		return _failure("LTS-HISTORY-005", "There is no document action to undo", "history.undo")
	var entry: Dictionary = _entries[_cursor - 1]
	var before_revision := _model_revision()
	_last_callback_result = {}
	if has_godot_backend() and _backend.has_method("has_undo") and bool(_backend.call("has_undo")):
		_backend.call("undo")
		if _model_revision() == before_revision:
			# A small fake backend may only record actions.  Keep semantics useful
			# in tests by applying the same inverse locally when it did not invoke
			# our callback.
			_last_callback_result = _apply_to_model(entry.get("inverse", {}))
		var result: Dictionary = _last_callback_result
		if not bool(result.get("ok", false)):
			return result
		_cursor = _entry_index(entry) # callback also updates this for real Godot
		_emit_changed(result)
		return _history_result(result, entry, "undo")
	var result := _apply_to_model(entry.get("inverse", {}))
	if not bool(result.get("ok", false)):
		return result
	_cursor -= 1
	_emit_changed(result)
	return _history_result(result, entry, "undo")


func redo() -> Dictionary:
	if _gesture.get("active", false):
		return _failure("LTS-HISTORY-006", "A coalesced action is active; finish or cancel it first", "history.gesture")
	if _cursor < 0 or _cursor >= _entries.size():
		return _failure("LTS-HISTORY-007", "There is no document action to redo", "history.redo")
	var entry: Dictionary = _entries[_cursor]
	var before_revision := _model_revision()
	_last_callback_result = {}
	if has_godot_backend() and _backend.has_method("has_redo") and bool(_backend.call("has_redo")):
		_backend.call("redo")
		if _model_revision() == before_revision:
			_last_callback_result = _apply_to_model(entry.get("command", {}))
		var result: Dictionary = _last_callback_result
		if not bool(result.get("ok", false)):
			return result
		_cursor = _entry_index(entry) + 1
		_emit_changed(result)
		return _history_result(result, entry, "redo")
	var result := _apply_to_model(entry.get("command", {}))
	if not bool(result.get("ok", false)):
		return result
	_cursor += 1
	_emit_changed(result)
	return _history_result(result, entry, "redo")


func can_undo() -> bool:
	return _cursor > 0 and _cursor <= _entries.size()


func can_redo() -> bool:
	return _cursor >= 0 and _cursor < _entries.size()


func history_size() -> int:
	return _entries.size()


func history_index() -> int:
	return _cursor


func get_history() -> Array:
	return _entries.duplicate(true)


func current_action_name() -> String:
	if _cursor <= 0 or _cursor > _entries.size():
		return ""
	return String(_entries[_cursor - 1].get("name", ""))


func clear_local_history() -> void:
	_entries.clear()
	_cursor = 0
	_gesture.clear()
	_last_callback_result.clear()


## Explicitly clear both local metadata and a connected backend.  This is
## intended for opening/reloading a document; callers should not use it for a
## normal edit because a shared EditorUndoRedoManager may contain other
## plugin actions.
func clear() -> void:
	if has_godot_backend() and _backend.has_method("clear_history"):
		_backend.call("clear_history")
	clear_local_history()


func mark_checkpoint() -> int:
	return _cursor


func is_at_checkpoint(checkpoint: int) -> bool:
	return _cursor == checkpoint


## Start a gesture such as moving one or more nodes.  Intermediate commands
## are applied to the model but are not registered as separate undo actions.
func begin_coalesced_action(action_name: String = "Edit document", gesture_key: String = "") -> Dictionary:
	if _gesture.get("active", false):
		return _failure("LTS-HISTORY-008", "Another coalesced action is already active", "history.gesture")
	if _model == null or not _model.has_method("snapshot"):
		return _failure("LTS-HISTORY-003", "History has no document model", "history.model")
	_gesture = {
		"active": true,
		"name": action_name,
		"key": gesture_key,
		"before": _model.call("snapshot"),
		"commands": [],
		"mutation": MUTATION_SEMANTIC,
	}
	return {"ok": true, "active": true, "gesture_key": gesture_key, "state": _model.call("snapshot")}


func begin_gesture(action_name: String = "Edit document", gesture_key: String = "") -> Dictionary:
	return begin_coalesced_action(action_name, gesture_key)


func apply_coalesced(command: Variant) -> Dictionary:
	if not _gesture.get("active", false):
		return _failure("LTS-HISTORY-009", "No coalesced action is active", "history.gesture")
	var data := _command_data(command)
	if data.is_empty() or _model == null or not _model.has_method("apply_command"):
		return _failure("LTS-HISTORY-002", "Command is not serializable", "command")
	var result: Dictionary = _model.call("apply_command", data)
	if not bool(result.get("ok", false)):
		return result
	var commands: Array = _gesture.get("commands", [])
	commands.append(data.duplicate(true))
	_gesture["commands"] = commands
	var child: Object = _command_from_data(data)
	if child != null:
		var current_mutation := String(_gesture.get("mutation", MUTATION_SEMANTIC))
		if child.is_mixed() or (child.is_layout() and current_mutation == MUTATION_SEMANTIC and child.is_semantic()):
			_gesture["mutation"] = MUTATION_MIXED
		elif child.is_layout() and current_mutation == MUTATION_SEMANTIC:
			_gesture["mutation"] = MUTATION_LAYOUT
		elif child.is_semantic() and current_mutation == MUTATION_LAYOUT:
			_gesture["mutation"] = MUTATION_MIXED
	return result


func update_gesture(command: Variant) -> Dictionary:
	return apply_coalesced(command)


func end_coalesced_action(commit_action: bool = true) -> Dictionary:
	if not _gesture.get("active", false):
		return _failure("LTS-HISTORY-009", "No coalesced action is active", "history.gesture")
	var before: Dictionary = _gesture.get("before", {}).duplicate(true)
	var name := String(_gesture.get("name", "Edit document"))
	var mutation := String(_gesture.get("mutation", MUTATION_SEMANTIC))
	var commands: Array = _gesture.get("commands", [])
	var final_state: Dictionary = _model.call("snapshot") if _model != null and _model.has_method("snapshot") else {}
	_gesture.clear()
	if not commit_action:
		var restored := _apply_to_model(Command.restore_state(before, mutation).to_dict())
		if not bool(restored.get("ok", false)):
			return restored
		return {"ok": true, "applied": false, "cancelled": true, "state": _model.call("snapshot")}
	if commands.is_empty():
		return {"ok": true, "applied": false, "empty": true, "state": final_state}
	# A state transition is used as the coalesced action payload.  It makes the
	# gesture's first frame the exact inverse even when intermediate edits were
	# generated by dozens of pointer-move events.
	var forward: Dictionary = Command.restore_state(final_state, mutation).to_dict()
	var inverse: Dictionary = Command.restore_state(before, mutation).to_dict()
	return _record_action(name, forward, inverse, true, {}, {"ok": true, "applied": true, "state": final_state})


func end_gesture(commit_action: bool = true) -> Dictionary:
	return end_coalesced_action(commit_action)


func cancel_coalesced_action() -> Dictionary:
	return end_coalesced_action(false)


func cancel_gesture() -> Dictionary:
	return cancel_coalesced_action()


func begin_move(graph_identifier: String, node_identifiers: Array = [], action_name: String = "Move nodes") -> Dictionary:
	return begin_coalesced_action(action_name, "move:%s:%s" % [graph_identifier, ",".join(PackedStringArray(node_identifiers))])


func update_move(graph_identifier: String, positions: Dictionary) -> Dictionary:
	return apply_coalesced(Command.set_layout_batch("task_graph", graph_identifier, {"nodes": positions}))


func end_move(commit_action: bool = true) -> Dictionary:
	return end_coalesced_action(commit_action)


func copy_graph_fragment(graph_identifier: String, node_identifiers: Array = []) -> Dictionary:
	if _model == null or not _model.has_method("get_document"):
		return {}
	var graph: Dictionary = _model.call("get_document", "task_graph", graph_identifier)
	if graph.is_empty():
		return {}
	var selected: Dictionary = {}
	for value in node_identifiers:
		selected[String(value)] = true
	var nodes: Array = []
	for node in graph.get("nodes", []):
		if not node is Dictionary:
			continue
		var identifier := String(node.get("identifier", ""))
		if selected.is_empty() or selected.has(identifier):
			nodes.append(node.duplicate(true))
	var node_ids: Dictionary = {}
	for node in nodes:
		node_ids[String(node.get("identifier", ""))] = true
	var edges: Array = []
	for edge in graph.get("edges", []):
		if not edge is Dictionary:
			continue
		if node_ids.has(String(edge.get("from_node_identifier", ""))) and node_ids.has(String(edge.get("to_node_identifier", ""))):
			edges.append(edge.duplicate(true))
	var fragment := {"schema_version": 1, "nodes": nodes, "edges": edges, "layout": {"nodes": {}}}
	var graph_layout: Dictionary = _model.call("get_layout", "task_graph", graph_identifier) if _model.has_method("get_layout") else {}
	var layout_nodes: Dictionary = graph_layout.get("nodes", {})
	for node_id in node_ids:
		if layout_nodes.has(node_id):
			fragment["layout"]["nodes"][node_id] = layout_nodes[node_id].duplicate(true) if layout_nodes[node_id] is Dictionary else layout_nodes[node_id]
	return fragment


func paste_graph_fragment(graph_identifier: String, fragment: Dictionary, position_offset: Variant = null, action_name: String = "Paste nodes") -> Dictionary:
	if _model == null or not _model.has_method("get_document"):
		return _failure("LTS-HISTORY-003", "History has no document model", "history.model")
	var graph: Dictionary = _model.call("get_document", "task_graph", graph_identifier)
	var existing_nodes: Array = []
	var existing_edges: Array = []
	for node in graph.get("nodes", []):
		if node is Dictionary:
			existing_nodes.append(String(node.get("identifier", "")))
	for edge in graph.get("edges", []):
		if edge is Dictionary:
			existing_edges.append(String(edge.get("identifier", "")))
	var resolved: Dictionary = Model.remap_fragment(fragment, existing_nodes, existing_edges)
	return execute(Command.paste_graph_fragment(graph_identifier, resolved, position_offset, "_copy", true), action_name)


func duplicate_nodes(graph_identifier: String, node_identifiers: Array, position_offset: Variant = null, action_name: String = "Duplicate nodes") -> Dictionary:
	var fragment := copy_graph_fragment(graph_identifier, node_identifiers)
	if fragment.is_empty():
		return _failure("LTS-HISTORY-010", "No nodes selected for duplication", "task_graph.%s.nodes" % graph_identifier)
	return paste_graph_fragment(graph_identifier, fragment, position_offset, action_name)


func delete_nodes(graph_identifier: String, node_identifiers: Array, action_name: String = "Delete nodes") -> Dictionary:
	return execute(Command.remove_task_nodes(graph_identifier, node_identifiers), action_name)


func auto_arrange(graph_identifier: String, positions: Dictionary, action_name: String = "Auto-arrange nodes") -> Dictionary:
	return execute(Command.auto_arrange(graph_identifier, positions), action_name)


func set_resource_reference(document_kind: String, document_identifier: String, field_path: Variant, referenced_identifier: String, action_name: String = "Update resource reference") -> Dictionary:
	return execute(Command.set_resource_reference(document_kind, document_identifier, field_path, referenced_identifier), action_name)


func _record_action(action_name: String, forward: Dictionary, inverse: Dictionary, already_applied: bool, options: Dictionary, applied_result: Dictionary) -> Dictionary:
	if _model == null:
		return _failure("LTS-HISTORY-003", "History has no document model", "history.model")
	if not forward is Dictionary or not inverse is Dictionary or forward.is_empty() or inverse.is_empty():
		return _failure("LTS-HISTORY-011", "A reversible action requires command and inverse data", "history.action")
	while _entries.size() > _cursor:
		_entries.pop_back()
	var entry_id := _next_entry_id
	_next_entry_id += 1
	var entry := {
		"id": entry_id,
		"name": action_name if not action_name.is_empty() else "Edit document",
		"command": forward.duplicate(true),
		"inverse": inverse.duplicate(true),
		"mutation": String(forward.get("mutation", Command.infer_mutation(String(forward.get("operation", ""))))),
	}
	_entries.append(entry)
	var entry_index := _entries.size() - 1
	var result: Dictionary = applied_result.duplicate(true)
	if has_godot_backend():
		var before_revision := _model_revision()
		_last_callback_result = {}
		_backend.call("create_action", String(entry["name"]))
		# Godot 4's UndoRedo API takes one Callable for each callback.  Binding
		# the serialized payload keeps this path compatible with both
		# UndoRedo and EditorUndoRedoManager while remaining headless-testable.
		var do_callable := Callable(self, "_history_apply").bind(forward.duplicate(true), entry_id, 1)
		var undo_callable := Callable(self, "_history_apply").bind(inverse.duplicate(true), entry_id, -1)
		_backend.add_do_method(do_callable)
		_backend.add_undo_method(undo_callable)
		_backend.call("commit_action")
		if not already_applied and _model_revision() == before_revision:
			# UndoRedo-compatible fakes are allowed to record an action without
			# executing commit_action; execute the command exactly once locally.
			_last_callback_result = _apply_to_model(forward)
		result = _last_callback_result if not _last_callback_result.is_empty() else {"ok": true, "applied": already_applied, "state": _model_snapshot()}
	else:
		if not already_applied:
			result = _apply_to_model(forward)
		else:
			if result.is_empty():
				result = {"ok": true, "applied": true, "state": _model_snapshot()}
	if not bool(result.get("ok", false)):
		_entries.remove_at(entry_index)
		_cursor = mini(_cursor, _entries.size())
		return result
	_cursor = entry_index + 1
	result["history_index"] = _cursor
	result["history_action_id"] = entry_id
	result["history_action_name"] = entry["name"]
	result["command"] = forward.duplicate(true)
	result["inverse"] = inverse.duplicate(true)
	result["mutation"] = entry["mutation"]
	result["backend"] = backend_name()
	result["state"] = _model_snapshot()
	_emit_changed(result)
	action_committed.emit(result)
	return result


func _history_apply(data: Dictionary, entry_id: int = -1, direction: int = 0) -> void:
	# A shared EditorUndoRedoManager can retain callbacks after this document is
	# reloaded and its local entries are reset.  Do not let a stale native action
	# mutate the newly loaded document when that callback is eventually invoked.
	if entry_id >= 0 and _entry_index_by_id(entry_id) < 0:
		_last_callback_result = {"ok": true, "applied": false, "stale": true, "history_action_id": entry_id}
		return
	_last_callback_result = _apply_to_model(data)
	if bool(_last_callback_result.get("ok", false)) and entry_id >= 0:
		var index := _entry_index_by_id(entry_id)
		if index >= 0:
			_cursor = index + 1 if direction >= 0 else index
		_emit_changed(_last_callback_result)


func _apply_to_model(data: Dictionary) -> Dictionary:
	if _model == null or not _model.has_method("apply_serialized_command") and not _model.has_method("apply_command"):
		return _failure("LTS-HISTORY-003", "History has no document model", "history.model")
	if _model.has_method("apply_serialized_command"):
		return _model.call("apply_serialized_command", data)
	return _model.call("apply_command", data)


func _model_snapshot() -> Dictionary:
	if _model != null and _model.has_method("snapshot"):
		return _model.call("snapshot")
	return {}


func _model_revision() -> int:
	if _model != null and _model.has_method("get_revision"):
		return int(_model.call("get_revision"))
	return int(_model_snapshot().get("revision", 0))


func _history_result(result: Dictionary, entry: Dictionary, direction: String) -> Dictionary:
	var output := result.duplicate(true)
	output["history_index"] = _cursor
	output["history_action_id"] = entry.get("id", -1)
	output["history_action_name"] = entry.get("name", "")
	output["history_direction"] = direction
	output["backend"] = backend_name()
	output["state"] = _model_snapshot()
	return output


func _emit_changed(result: Dictionary) -> void:
	changed.emit(result)


func _entry_index(entry: Dictionary) -> int:
	return _entry_index_by_id(int(entry.get("id", -1)))


func _entry_index_by_id(entry_id: int) -> int:
	for index in _entries.size():
		if int(_entries[index].get("id", -1)) == entry_id:
			return index
	return -1


func _command_data(command: Variant) -> Dictionary:
	if command is Dictionary:
		return command.duplicate(true)
	if command is Object and command.has_method("to_dict"):
		var data = command.call("to_dict")
		return data.duplicate(true) if data is Dictionary else {}
	return {}


func _command_from_data(data: Dictionary):
	if data.is_empty():
		return null
	return Command.from_dict(data)


func _failure(code: String, message: String, path: String) -> Dictionary:
	return {"ok": false, "applied": false, "error": {"code": code, "path": path, "severity": "error", "message": message}, "state": _model_snapshot()}
