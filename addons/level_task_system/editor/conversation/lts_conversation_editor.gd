@tool
class_name LtsConversationEditor
extends PanelContainer

## Reusable conversation authoring panel.
##
## Timeline and structured-text controls are sibling projections of one
## LtsDocumentModel.  They receive fresh projections after every committed
## command and share the model's selection.  The text view is deliberately an
## outline/editor, not a free-form language parser, which makes switching
## modes lossless for IDs, branches, predicates, actions, and outcomes.

signal mode_changed(mode: String)
signal selection_changed(selection: Dictionary)
signal validation_changed(findings: Array)
signal command_intent_requested(intent_data: Dictionary)
signal command_applied(intent_data: Dictionary, result: Dictionary)
signal document_changed(projection: Dictionary)
signal dirty_state_changed(dirty: bool)
signal save_requested(conversation_identifier: String, document: Dictionary)
signal condition_edit_requested(step_identifier: String, choice_identifier: String)

const DocumentCommand := preload("res://addons/level_task_system/editor/document/lts_document_command.gd")
const DocumentModel := preload("res://addons/level_task_system/editor/document/lts_document_model.gd")
const DocumentHistory := preload("res://addons/level_task_system/editor/document/lts_document_history.gd")
const ConversationProjection := preload("res://addons/level_task_system/editor/conversation/lts_conversation_projection.gd")
const Intent := preload("res://addons/level_task_system/editor/conversation/lts_conversation_command_intent.gd")
const Timeline := preload("res://addons/level_task_system/editor/conversation/lts_conversation_timeline.gd")
const TextView := preload("res://addons/level_task_system/editor/conversation/lts_conversation_text_view.gd")
const ThemeHelper := preload("res://addons/level_task_system/editor/components/lts_component_theme.gd")

const MODE_TIMELINE := "timeline"
const MODE_TEXT := "text"
const MODE_ORDER: PackedStringArray = [MODE_TIMELINE, MODE_TEXT]

var _document_model: Object
var _history: Object
var _conversation_identifier := ""
var _mode := MODE_TIMELINE
var _projection: Dictionary = {}
var _external_findings: Array = []
var _saved_semantic_document: Dictionary = {}
var _built := false
var _updating_views := false
var _applying_command := false

var _heading: Label
var _resource_label: Label
var _status_label: Label
var _mode_tabs: TabContainer
var _timeline_view: LtsConversationTimeline
var _text_view: LtsConversationTextView
var _validate_button: Button
var _save_button: Button


func _init() -> void:
	theme_type_variation = &"LevelTaskDrawer"
	focus_mode = Control.FOCUS_ALL


func _ready() -> void:
	_built = true
	ThemeHelper.inherit_editor_theme(self)
	_build_shell()
	_render_projection()


## Bind an existing document model and conversation identifier.  The model is
## expected to implement get_document/apply_command/get_selection; a plain
## dictionary is accepted as a convenience for headless fixtures.
func bind_document(source: Variant, conversation_identifier: String, selection: Dictionary = {}) -> LtsConversationEditor:
	_document_model = _coerce_model(source, conversation_identifier)
	_conversation_identifier = conversation_identifier
	_history = DocumentHistory.new(_document_model)
	if _document_model != null and _document_model.has_method("get_selection") and selection.is_empty():
		selection = _document_model.call("get_selection")
	if not selection.is_empty():
		_set_selection_direct(selection)
	_saved_semantic_document = _semantic_document()
	_external_findings = []
	_refresh_projection()
	document_changed.emit(_projection.duplicate(true))
	return self


func set_document_model(model: Object, conversation_identifier: String) -> LtsConversationEditor:
	return bind_document(model, conversation_identifier)


func open_conversation(model: Object, conversation_identifier: String, selection: Dictionary = {}) -> LtsConversationEditor:
	return bind_document(model, conversation_identifier, selection)


func load_document(source: Variant, conversation_identifier: String) -> LtsConversationEditor:
	return bind_document(source, conversation_identifier)


func get_document_model() -> Object:
	return _document_model


func get_model() -> Object:
	return _document_model


func get_conversation_identifier() -> String:
	return _conversation_identifier


func get_mode() -> String:
	return _mode


func set_mode(mode: String) -> bool:
	var normalized := mode.strip_edges().to_lower()
	if normalized not in MODE_ORDER:
		return false
	if _mode == normalized:
		if _mode_tabs != null:
			_mode_tabs.current_tab = MODE_ORDER.find(_mode)
		return true
	_mode = normalized
	if _mode_tabs != null:
		_mode_tabs.current_tab = MODE_ORDER.find(_mode)
	mode_changed.emit(_mode)
	# No conversion or parser runs here.  Both views already project the same
	# canonical document and are refreshed by `_refresh_projection`.
	return true


func switch_mode(mode: String) -> bool:
	return set_mode(mode)


func toggle_mode() -> String:
	set_mode(MODE_TEXT if _mode == MODE_TIMELINE else MODE_TIMELINE)
	return _mode


func get_projection() -> Dictionary:
	return _projection.duplicate(true)


func get_canonical_document() -> Dictionary:
	return ConversationProjection.canonical_document(_document_model, _conversation_identifier)


func canonical_document() -> Dictionary:
	return get_canonical_document()


func get_timeline_projection() -> Dictionary:
	return _projection.get("timeline", {}).duplicate(true) if _projection.get("timeline", {}) is Dictionary else {}


func get_text_projection() -> Array:
	return _projection.get("text_outline", []).duplicate(true) if _projection.get("text_outline", []) is Array else []


func get_selection() -> Dictionary:
	if _document_model != null and _document_model.has_method("get_selection"):
		var selection = _document_model.call("get_selection")
		if selection is Dictionary:
			return selection.duplicate(true)
	return _projection.get("selection", {}).duplicate(true) if _projection.get("selection", {}) is Dictionary else {}


func select_step(step_identifier: String, field_path: String = "") -> Dictionary:
	return _select_element("step", step_identifier, field_path)


func select_line(step_identifier: String, field_path: String = "") -> Dictionary:
	return select_step(step_identifier, field_path)


func select_choice(step_identifier: String, choice_identifier: String, field_path: String = "") -> Dictionary:
	var path := field_path
	if path.is_empty():
		path = "steps.%s.choices.%s" % [step_identifier, choice_identifier]
	return _select_element("choice", choice_identifier, path)


func select_field(element_kind: String, element_identifier: String, field_path: String) -> Dictionary:
	return _select_element(element_kind, element_identifier, field_path)


## Apply an authoring intent through the document history seam.  The emitted
## intent remains inspectable by the main-screen shell, while this reusable
## panel provides a sensible default that commits it immediately.
func apply_intent(intent_source: Variant, action_name: String = "") -> Dictionary:
	var intent_data := _intent_data(intent_source)
	var command = _intent_command(intent_source)
	if command == null:
		return _failure("LTS-CONVERSATION-INTENT-002", "Intent has no document command", "conversation.intent")
	var name := action_name if not action_name.is_empty() else String(intent_data.get("description", "Edit conversation"))
	command_intent_requested.emit(intent_data.duplicate(true))
	var result := _execute_command(command, name)
	command_applied.emit(intent_data.duplicate(true), result.duplicate(true))
	if bool(result.get("ok", false)):
		_refresh_projection()
	return result


func request_intent(intent_source: Variant) -> Dictionary:
	var data := _intent_data(intent_source)
	command_intent_requested.emit(data.duplicate(true))
	return data


func apply_command(command: Variant, action_name: String = "Edit conversation") -> Dictionary:
	var intent_data := {
		"intent": "conversation.command",
		"document_identifier": _conversation_identifier,
		"description": action_name,
		"command": _command_data(command),
	}
	var result := _execute_command(command, action_name)
	command_applied.emit(intent_data, result.duplicate(true))
	if bool(result.get("ok", false)):
		_refresh_projection()
	return result


func undo() -> Dictionary:
	if _history == null or not _history.has_method("undo"):
		return _failure("LTS-CONVERSATION-HISTORY-001", "Conversation history is unavailable", "conversation.history")
	var result: Dictionary = _history.call("undo")
	if bool(result.get("ok", false)):
		_refresh_projection()
		command_applied.emit({"intent": "conversation.undo", "document_identifier": _conversation_identifier}, result.duplicate(true))
	return result


func redo() -> Dictionary:
	if _history == null or not _history.has_method("redo"):
		return _failure("LTS-CONVERSATION-HISTORY-002", "Conversation history is unavailable", "conversation.history")
	var result: Dictionary = _history.call("redo")
	if bool(result.get("ok", false)):
		_refresh_projection()
		command_applied.emit({"intent": "conversation.redo", "document_identifier": _conversation_identifier}, result.duplicate(true))
	return result


func can_undo() -> bool:
	return _history != null and _history.has_method("can_undo") and bool(_history.call("can_undo"))


func can_redo() -> bool:
	return _history != null and _history.has_method("can_redo") and bool(_history.call("can_redo"))


func set_undo_redo_manager(undo_redo: Object) -> void:
	if _history == null:
		_history = DocumentHistory.new(_document_model, undo_redo)
	elif _history.has_method("set_undo_redo"):
		_history.call("set_undo_redo", undo_redo)


func get_history() -> Object:
	return _history


func refresh() -> Dictionary:
	_refresh_projection()
	return _projection.duplicate(true)


func set_validation_findings(findings: Array) -> void:
	_external_findings = findings.duplicate(true)
	_refresh_projection()


func set_findings(findings: Array) -> void:
	set_validation_findings(findings)


func get_validation_findings() -> Array:
	return _projection.get("findings", []).duplicate(true) if _projection.get("findings", []) is Array else []


func validate_document() -> Array:
	# Rebuild every projection together so a validation request cannot leave the
	# timeline's per-step findings stale while the top-level hook is updated.
	var selection := get_selection()
	_projection = ConversationProjection.project(_document_model, _conversation_identifier, selection, _external_findings)
	var findings: Array = _projection.get("findings", []) if _projection.get("findings", []) is Array else []
	if _built:
		_render_projection()
	else:
		validation_changed.emit(findings.duplicate(true))
	document_changed.emit(_projection.duplicate(true))
	_update_dirty_state()
	return findings


func validate() -> Array:
	return validate_document()


func mark_saved() -> void:
	_saved_semantic_document = _semantic_document()
	_update_dirty_state()


func mark_clean() -> void:
	mark_saved()


func is_dirty() -> bool:
	return _semantic_document() != _saved_semantic_document


func request_save() -> void:
	save_requested.emit(_conversation_identifier, get_canonical_document())


func save() -> void:
	request_save()


func get_status() -> Dictionary:
	var findings := get_validation_findings()
	var counts := {"error": 0, "warning": 0, "info": 0, "total": findings.size()}
	for finding_value in findings:
		if finding_value is Dictionary:
			var severity := String(finding_value.get("severity", "info"))
			if counts.has(severity): counts[severity] = int(counts[severity]) + 1
	return {
		"dirty": is_dirty(),
		"mode": _mode,
		"valid": int(counts["error"]) == 0,
		"findings": counts,
		"read_only": bool(_document_model != null and _document_model.has_method("is_read_only") and _document_model.call("is_read_only")),
	}


func _build_shell() -> void:
	var root := VBoxContainer.new()
	root.name = "ConversationAuthoringColumn"
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(root)
	var command_bar := HBoxContainer.new()
	command_bar.name = "ConversationCommandBar"
	root.add_child(command_bar)
	_heading = Label.new()
	_heading.name = "ConversationHeading"
	_heading.text = "Conversation authoring"
	_heading.tooltip_text = "Timeline and structured text projections of one canonical document"
	_heading.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	command_bar.add_child(_heading)
	_resource_label = Label.new()
	_resource_label.name = "ConversationResource"
	_resource_label.text = "No conversation selected"
	_resource_label.tooltip_text = _resource_label.text
	command_bar.add_child(_resource_label)
	_validate_button = Button.new()
	_validate_button.name = "Validate"
	_validate_button.text = "Validate"
	_validate_button.tooltip_text = "Validate this conversation definition"
	_validate_button.icon = ThemeHelper.resolve_icon(_validate_button, [&"Check", &"Validation"], &"Check")
	_validate_button.focus_mode = Control.FOCUS_ALL
	_validate_button.pressed.connect(validate_document)
	command_bar.add_child(_validate_button)
	_save_button = Button.new()
	_save_button.name = "Save"
	_save_button.text = "Save"
	_save_button.tooltip_text = "Save conversation definition"
	_save_button.icon = ThemeHelper.resolve_icon(_save_button, [&"Save"], &"Save")
	_save_button.focus_mode = Control.FOCUS_ALL
	_save_button.pressed.connect(request_save)
	command_bar.add_child(_save_button)
	_status_label = Label.new()
	_status_label.name = "ConversationStatus"
	_status_label.text = "No document"
	_status_label.tooltip_text = "Conversation validation and dirty status"
	command_bar.add_child(_status_label)
	var separator := HSeparator.new()
	separator.name = "CommandBarSeparator"
	root.add_child(separator)
	_mode_tabs = TabContainer.new()
	_mode_tabs.name = "ConversationModes"
	_mode_tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_mode_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_timeline_view = Timeline.new()
	_timeline_view.name = "Timeline"
	_timeline_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_timeline_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_text_view = TextView.new()
	_text_view.name = "StructuredText"
	_text_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_text_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_mode_tabs.add_child(_timeline_view)
	_mode_tabs.add_child(_text_view)
	_mode_tabs.set_tab_title(0, "Timeline")
	_mode_tabs.set_tab_title(1, "Structured text")
	_mode_tabs.current_tab = 0
	_mode_tabs.tab_changed.connect(_on_tab_changed)
	root.add_child(_mode_tabs)
	_timeline_view.step_selected.connect(_on_step_selected)
	_timeline_view.choice_selected.connect(_on_choice_selected)
	_timeline_view.command_intent_requested.connect(_on_child_intent)
	_timeline_view.add_step_requested.connect(_on_add_step_requested)
	_timeline_view.remove_step_requested.connect(_on_remove_step_requested)
	_timeline_view.add_choice_requested.connect(_on_add_choice_requested)
	_timeline_view.remove_choice_requested.connect(_on_remove_choice_requested)
	_text_view.step_selected.connect(_on_step_selected)
	_text_view.choice_selected.connect(_on_choice_selected)
	_text_view.command_intent_requested.connect(_on_child_intent)
	_text_view.condition_edit_requested.connect(_on_condition_edit_requested)


func _on_tab_changed(tab: int) -> void:
	var next_mode := MODE_ORDER[clampi(tab, 0, MODE_ORDER.size() - 1)]
	if _mode != next_mode:
		_mode = next_mode
		mode_changed.emit(_mode)


func _on_step_selected(step_identifier: String) -> void:
	select_step(step_identifier)


func _on_choice_selected(step_identifier: String, choice_identifier: String) -> void:
	select_choice(step_identifier, choice_identifier)


func _on_child_intent(intent_data: Dictionary) -> void:
	apply_intent(intent_data)


func _on_condition_edit_requested(step_identifier: String, choice_identifier: String) -> void:
	condition_edit_requested.emit(step_identifier, choice_identifier)


func _on_add_step_requested(step_kind: int) -> void:
	var identifier := _next_step_identifier(ConversationProjection.kind_name(step_kind))
	var step := _default_step(identifier, step_kind)
	apply_intent(Intent.add_step(_conversation_identifier, step), "Add conversation step")
	select_step(identifier)


func _on_remove_step_requested(step_identifier: String) -> void:
	apply_intent(Intent.remove_step(_conversation_identifier, step_identifier), "Remove conversation step")


func _on_add_choice_requested(step_identifier: String) -> void:
	var identifier := _next_choice_identifier(step_identifier)
	var choice := {"identifier": identifier, "label_key": "", "target_step_identifier": "", "conditions": []}
	apply_intent(Intent.add_choice(_conversation_identifier, step_identifier, choice), "Add conversation choice")
	select_choice(step_identifier, identifier)


func _on_remove_choice_requested(step_identifier: String, choice_identifier: String) -> void:
	apply_intent(Intent.remove_choice(_conversation_identifier, step_identifier, choice_identifier), "Remove conversation choice")


func _select_element(element_kind: String, element_identifier: String, field_path: String) -> Dictionary:
	var selection := {
		"resource_kind": "conversation",
		"resource_identifier": _conversation_identifier,
		"element_kind": element_kind,
		"element_identifier": element_identifier,
		"field_path": field_path,
	}
	var result := _execute_command(DocumentCommand.set_selection(selection), "Select conversation element")
	if bool(result.get("ok", false)):
		_refresh_projection()
	return result


func _set_selection_direct(selection: Dictionary) -> void:
	if _document_model == null or not _document_model.has_method("apply_command"):
		return
	var result: Dictionary = _document_model.call("apply_command", DocumentCommand.set_selection(selection))
	if bool(result.get("ok", false)):
		_refresh_projection()


func _refresh_projection() -> void:
	if _document_model == null or _conversation_identifier.is_empty():
		_projection = {"identifier": _conversation_identifier, "selection": {}, "timeline": {"steps": [], "empty": true}, "text_outline": [], "findings": []}
		if _built:
			_render_projection()
		return
	var selection := get_selection()
	_projection = ConversationProjection.project(_document_model, _conversation_identifier, selection, _external_findings)
	if _built:
		_render_projection()
	document_changed.emit(_projection.duplicate(true))
	_update_dirty_state()


func _render_projection() -> void:
	if not _built or _timeline_view == null or _text_view == null:
		return
	_updating_views = true
	_resource_label.text = _conversation_identifier if not _conversation_identifier.is_empty() else "No conversation selected"
	_resource_label.tooltip_text = _resource_label.text
	var timeline_projection: Dictionary = _projection.get("timeline", {}).duplicate(true) if _projection.get("timeline", {}) is Dictionary else {}
	timeline_projection["identifier"] = _conversation_identifier
	# The document copy is still a projection only; the timeline emits a
	# command back to this editor and never writes it directly.
	timeline_projection["document"] = _projection.get("document", {}).duplicate(true)
	_timeline_view.set_projection(timeline_projection)
	_timeline_view.set_read_only(_is_read_only())
	# The text view receives the complete projection so it can preserve the
	# canonical document and structured metadata while rendering its rows.
	_text_view.set_projection(_projection)
	_text_view.set_read_only(_is_read_only())
	_update_status()
	_updating_views = false
	validation_changed.emit(_projection.get("findings", []).duplicate(true))
	selection_changed.emit(get_selection())


func _update_status() -> void:
	if _status_label == null:
		return
	var findings: Array = _projection.get("findings", []) if _projection.get("findings", []) is Array else []
	var errors := 0
	var warnings := 0
	for finding_value in findings:
		if finding_value is Dictionary:
			if String(finding_value.get("severity", "")) == "error": errors += 1
			elif String(finding_value.get("severity", "")) == "warning": warnings += 1
	var state := "Valid"
	if errors > 0:
		state = "%d errors" % errors
	elif warnings > 0:
		state = "%d warnings" % warnings
	if is_dirty():
		state += " · Unsaved"
	_status_label.text = state
	_status_label.tooltip_text = "%s findings · %s" % [findings.size(), _conversation_identifier]
	if _save_button != null:
		_save_button.disabled = _document_model == null or _conversation_identifier.is_empty() or _is_read_only()
	if _validate_button != null:
		_validate_button.disabled = _document_model == null or _conversation_identifier.is_empty()


func _update_dirty_state() -> void:
	var dirty := is_dirty()
	dirty_state_changed.emit(dirty)
	if _built:
		_update_status()


func _execute_command(command: Variant, action_name: String) -> Dictionary:
	if _applying_command:
		return _failure("LTS-CONVERSATION-COMMAND-001", "Conversation command is already being applied", "conversation.command")
	if _document_model == null or not _document_model.has_method("apply_command"):
		return _failure("LTS-CONVERSATION-COMMAND-002", "Conversation document model is not bound", "conversation.model")
	if _is_read_only():
		return _failure("LTS-CONVERSATION-COMMAND-003", "Conversation is read-only", "conversation.read_only")
	_applying_command = true
	var result: Dictionary
	if _history != null and _history.has_method("execute"):
		result = _history.call("execute", command, action_name)
	else:
		result = _document_model.call("apply_command", command)
	_applying_command = false
	return result


func _is_read_only() -> bool:
	if _document_model == null:
		return true
	if _document_model.has_method("can_mutate"):
		return not bool(_document_model.call("can_mutate"))
	if _document_model.has_method("is_read_only") and bool(_document_model.call("is_read_only")):
		return true
	return false


func _intent_command(intent_source: Variant):
	if intent_source is Object and intent_source.has_method("to_command"):
		return intent_source.call("to_command")
	if intent_source is Dictionary:
		var data: Dictionary = intent_source
		var command_data = data.get("command", {})
		if command_data is Dictionary and not command_data.is_empty():
			return DocumentCommand.from_dict(command_data)
		if String(data.get("operation", "")) != "":
			return DocumentCommand.from_dict(data)
	return null


func _intent_data(intent_source: Variant) -> Dictionary:
	if intent_source is Object and intent_source.has_method("to_dict"):
		var data = intent_source.call("to_dict")
		return data.duplicate(true) if data is Dictionary else {}
	if intent_source is Dictionary:
		return intent_source.duplicate(true)
	return {}


func _command_data(command: Variant) -> Dictionary:
	if command is Object and command.has_method("to_dict"):
		var data = command.call("to_dict")
		return data.duplicate(true) if data is Dictionary else {}
	if command is Dictionary:
		return command.duplicate(true)
	return {}


func _coerce_model(source: Variant, identifier: String) -> Object:
	if source is Object:
		if source.has_method("get_document") or source.has_method("get_resource_document"):
			return source
		# Shells may hand the panel the native conversation Resource directly.
		# Project it once into the same document model used by headless tests;
		# views still never mutate that Resource themselves.
		if source is Resource:
			return DocumentModel.from_resource(source)
		return source
	if source is Dictionary:
		var data: Dictionary = source
		if data.has("documents"):
			return DocumentModel.new(data)
		if String(data.get("kind", "")) == "conversation":
			return DocumentModel.new({"documents": {"conversations": {identifier: data}}})
	return null


func _semantic_document() -> Dictionary:
	return _strip_editor_metadata(get_canonical_document())


func _strip_editor_metadata(value: Variant) -> Variant:
	if value is Array:
		var array: Array = []
		for item in value:
			array.append(_strip_editor_metadata(item))
		return array
	if value is Dictionary:
		var dictionary: Dictionary = {}
		for key in value:
			var name := String(key)
			if name in ["source_path", "resource_path", "layout", "editor_layout", "selection", "navigator"]:
				continue
			dictionary[name] = _strip_editor_metadata(value[key])
		return dictionary
	return value


func _next_step_identifier(kind: String) -> String:
	var base := "new_%s" % kind
	var candidate := base
	var index := 2
	var document := get_canonical_document()
	var used: Dictionary = {}
	for step_value in document.get("steps", []) if document.get("steps", []) is Array else []:
		if step_value is Dictionary:
			used[String(step_value.get("identifier", ""))] = true
	while used.has(candidate):
		candidate = "%s_%d" % [base, index]
		index += 1
	return candidate


func _next_choice_identifier(step_identifier: String) -> String:
	var base := "choice_%s" % step_identifier
	var candidate := base
	var index := 2
	var document := get_canonical_document()
	var used: Dictionary = {}
	for step_value in document.get("steps", []) if document.get("steps", []) is Array else []:
		if not step_value is Dictionary or String(step_value.get("identifier", "")) != step_identifier:
			continue
		for choice_value in step_value.get("choices", []) if step_value.get("choices", []) is Array else []:
			if choice_value is Dictionary: used[String(choice_value.get("identifier", ""))] = true
	while used.has(candidate):
		candidate = "%s_%d" % [base, index]
		index += 1
	return candidate


func _default_step(identifier: String, kind: int) -> Dictionary:
	return {
		"identifier": identifier,
		"kind": kind,
		"speaker_identifier": "",
		"line_key": "",
		"parameters": [],
		"next_step_identifier": "",
		"provider_identifier": "",
		"conditions": [],
		"true_step_identifier": "",
		"false_step_identifier": "",
		"success_step_identifier": "",
		"failure_step_identifier": "",
		"choices": [],
		"target_step_identifier": "",
		"outcome_identifier": "",
	}


func _failure(code: String, message: String, path: String) -> Dictionary:
	return {"ok": false, "applied": false, "error": {"code": code, "path": path, "severity": "error", "message": message}}
