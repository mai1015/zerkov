@tool
class_name LtsConversationPreview
extends PanelContainer

## Chat-style editor preview for one immutable conversation definition.
##
## The control is a projection over LtsConversationPreviewModel.  It owns no
## authored fields and never reaches into a task/conversation authority.  The
## right column makes condition dependencies and synthetic variables visible;
## the lower trace remains bounded and deterministic for simulator evidence.

const PreviewModel := preload("res://addons/level_task_system/editor/simulation/lts_conversation_preview_model.gd")
const ComponentTheme := preload("res://addons/level_task_system/editor/components/lts_component_theme.gd")
const ComponentState := preload("res://addons/level_task_system/editor/components/lts_component_state.gd")

signal preview_changed(frame: Dictionary)
signal choice_selected(choice_identifier: String, result: Dictionary)
signal line_continued(result: Dictionary)
signal action_acknowledged(result: Dictionary)
signal restart_requested(entry_label: String)
signal trace_changed(records: Array)
signal native_unavailable(diagnostic: Dictionary)

var _model: LtsConversationPreviewModel
var _built := false
var _native_extension_available := true
var _bound_source: Variant = null
var _bound_facts: Variant = {}
var _bound_entry_label := ""
var _refreshing := false

var _title_label: Label
var _status_label: Label
var _revision_label: Label
var _restart_button: Button
var _body: HSplitContainer
var _chat_panel: PanelContainer
var _chat_scroll: ScrollContainer
var _chat_column: VBoxContainer
var _inspector_panel: PanelContainer
var _inspector_column: VBoxContainer
var _condition_column: VBoxContainer
var _variable_column: VBoxContainer
var _trace_panel: PanelContainer
var _trace_label: Label
var _unavailable_panel: PanelContainer
var _unavailable_title: Label
var _unavailable_message: Label
var _unavailable_details: Label
var _error_panel: PanelContainer
var _error_label: Label


func _init() -> void:
	theme_type_variation = &"LevelTaskDrawer"
	focus_mode = Control.FOCUS_ALL
	_model = PreviewModel.new()
	_model.frame_changed.connect(_on_model_frame_changed)
	_model.trace_changed.connect(_on_model_trace_changed)
	_model.state_changed.connect(_on_model_state_changed)
	_model.error_raised.connect(_on_model_error)


func _ready() -> void:
	if _built:
		return
	_built = true
	ComponentTheme.inherit_editor_theme(self)
	_build()
	_refresh()


## Bind and start an isolated preview.  `native_extension_available` is
## explicit so a missing extension never looks like a partially working editor
## surface.  Canonical dictionaries/resources are copied by the model.
func bind_conversation(
		source: Variant,
		facts: Variant = {},
		entry_label: String = "",
		native_extension_available: bool = true
) -> Dictionary:
	_bound_source = source
	_bound_facts = facts.duplicate(true) if facts is Array or facts is Dictionary else facts
	_bound_entry_label = entry_label
	_native_extension_available = native_extension_available
	_model.set_native_extension_available(native_extension_available)
	if not native_extension_available:
		_show_unavailable()
		return {"ok": false, "error": _model.get_diagnostic(), "status": get_status()}
	var configured := _model.bind_definition(source, facts, entry_label)
	if not bool(configured.get("ok", false)):
		_refresh()
		return configured
	var started := _model.start("editor.preview.conversation", "editor.preview", entry_label)
	_refresh()
	return started


func open_conversation(source: Variant, facts: Variant = {}, entry_label: String = "", native_extension_available: bool = true) -> Dictionary:
	return bind_conversation(source, facts, entry_label, native_extension_available)


func set_definition(source: Variant, facts: Variant = {}, entry_label: String = "") -> Dictionary:
	_bound_source = source
	_bound_facts = facts.duplicate(true) if facts is Array or facts is Dictionary else facts
	_bound_entry_label = entry_label
	var result := _model.bind_definition(source, facts, entry_label)
	_refresh()
	return result


func set_native_extension_available(available: bool) -> void:
	_native_extension_available = available
	_model.set_native_extension_available(available)
	_refresh()
	if not available:
		native_unavailable.emit(_model.get_diagnostic())


func is_native_extension_available() -> bool:
	return _native_extension_available


func get_model() -> LtsConversationPreviewModel:
	return _model


func get_preview_model() -> LtsConversationPreviewModel:
	return _model


func restart_from_entry(entry_label: String = "") -> Dictionary:
	var result := _model.restart_from_entry(entry_label)
	if bool(result.get("ok", false)):
		restart_requested.emit(entry_label if not entry_label.is_empty() else String(_model.get_status().get("entry_label", "")))
	_refresh()
	return result


func restart(entry_label: String = "") -> Dictionary:
	return restart_from_entry(entry_label)


func set_facts(facts: Variant) -> Dictionary:
	_bound_facts = facts.duplicate(true) if facts is Array or facts is Dictionary else facts
	var result := _model.set_facts(facts)
	_refresh()
	return result


func update_facts(facts: Variant) -> Dictionary:
	return set_facts(facts)


func inspect_variables(query: String = "") -> Array:
	return _model.inspect_variables(query)


func get_variable_inspection(query: String = "") -> Dictionary:
	return _model.get_variable_inspection(query)


func get_condition_visibility() -> Array:
	return _model.get_condition_visibility()


func select_choice(choice_identifier: String, frame_revision: int = -1) -> Dictionary:
	var result := _model.select_choice(choice_identifier, frame_revision)
	choice_selected.emit(choice_identifier, result.duplicate(true))
	_refresh()
	return result


func choose(choice_identifier: String, frame_revision: int = -1) -> Dictionary:
	return select_choice(choice_identifier, frame_revision)


func continue_line(frame_revision: int = -1) -> Dictionary:
	var result := _model.continue_line(frame_revision)
	line_continued.emit(result.duplicate(true))
	_refresh()
	return result


func advance_line(frame_revision: int = -1) -> Dictionary:
	return continue_line(frame_revision)


func acknowledge_action(request_identifier: String, success: bool, response: Variant = null) -> Dictionary:
	var result := _model.acknowledge_action(request_identifier, success, response)
	action_acknowledged.emit(result.duplicate(true))
	_refresh()
	return result


func get_frame() -> Dictionary:
	return _model.get_frame()


func current_frame() -> Dictionary:
	return get_frame()


func get_transcript() -> Array:
	return _model.get_transcript()


func get_trace() -> Array:
	return _model.get_trace()


func export_trace() -> Dictionary:
	return _model.export_trace()


func export_trace_json() -> String:
	return _model.export_trace_json()


func get_status() -> Dictionary:
	var status := _model.get_status()
	status["ui_built"] = _built
	status["chat_style"] = true
	status["read_only_definition"] = true
	return status


func get_chat_projection() -> Dictionary:
	return {
		"frame": get_frame(),
		"transcript": get_transcript(),
		"condition_visibility": get_condition_visibility(),
		"variables": inspect_variables(),
		"trace": get_trace(),
		"status": get_status(),
	}


func _build() -> void:
	if not _built and not is_inside_tree():
		return
	if _title_label != null:
		return
	var root := VBoxContainer.new()
	root.name = "ConversationPreviewColumn"
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(root)

	var header := HBoxContainer.new()
	header.name = "PreviewHeader"
	root.add_child(header)
	_title_label = Label.new()
	_title_label.name = "PreviewTitle"
	_title_label.text = "Conversation preview"
	_title_label.tooltip_text = "Isolated chat-style preview over the production conversation semantics"
	_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(_title_label)
	_status_label = Label.new()
	_status_label.name = "PreviewStatus"
	header.add_child(_status_label)
	_revision_label = Label.new()
	_revision_label.name = "FrameRevision"
	_revision_label.tooltip_text = "Current frame revision; choice input is rejected when stale"
	header.add_child(_revision_label)
	_restart_button = Button.new()
	_restart_button.name = "RestartFromEntry"
	_restart_button.text = "Restart"
	_restart_button.tooltip_text = "Restart this isolated preview from the selected entry label"
	_restart_button.icon = ComponentTheme.resolve_icon(_restart_button, [&"Reload", &"Refresh"], &"Reload")
	_restart_button.focus_mode = Control.FOCUS_ALL
	_restart_button.pressed.connect(func() -> void: restart_from_entry())
	header.add_child(_restart_button)

	var separator := HSeparator.new()
	separator.name = "PreviewHeaderSeparator"
	root.add_child(separator)

	_unavailable_panel = _build_unavailable_panel()
	root.add_child(_unavailable_panel)
	_error_panel = _build_error_panel()
	root.add_child(_error_panel)

	_body = HSplitContainer.new()
	_body.name = "PreviewBody"
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(_body)
	_chat_panel = _build_chat_panel()
	_body.add_child(_chat_panel)
	_inspector_panel = _build_inspector_panel()
	_body.add_child(_inspector_panel)

	_trace_panel = PanelContainer.new()
	_trace_panel.name = "PreviewTraceDrawer"
	_trace_panel.theme_type_variation = &"LevelTaskDrawer"
	var trace_column := VBoxContainer.new()
	trace_column.name = "TraceColumn"
	_trace_panel.add_child(trace_column)
	var trace_heading := Label.new()
	trace_heading.name = "TraceHeading"
	trace_heading.text = "Simulator trace"
	trace_heading.tooltip_text = "Bounded deterministic path for this isolated preview"
	trace_column.add_child(trace_heading)
	_trace_label = Label.new()
	_trace_label.name = "TraceRecords"
	_trace_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_trace_label.text = "No runtime activity"
	_trace_label.tooltip_text = "No runtime activity"
	trace_column.add_child(_trace_label)
	root.add_child(_trace_panel)


func _build_chat_panel() -> PanelContainer:
	var panel := PanelContainer.new()
	panel.name = "ChatPreview"
	panel.theme_type_variation = &"LevelTaskDrawer"
	var column := VBoxContainer.new()
	column.name = "ChatColumn"
	panel.add_child(column)
	var heading := Label.new()
	heading.name = "ChatHeading"
	heading.text = "Conversation"
	heading.tooltip_text = "Render-neutral lines and currently available responses"
	column.add_child(heading)
	_chat_scroll = ScrollContainer.new()
	_chat_scroll.name = "ChatTranscriptScroll"
	_chat_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_chat_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_chat_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_chat_column = VBoxContainer.new()
	_chat_column.name = "ChatTranscript"
	_chat_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_chat_column.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_chat_scroll.add_child(_chat_column)
	column.add_child(_chat_scroll)
	return panel


func _build_inspector_panel() -> PanelContainer:
	var panel := PanelContainer.new()
	panel.name = "ConversationVariablesInspector"
	panel.theme_type_variation = &"LevelTaskDrawer"
	panel.custom_minimum_size = Vector2(240, 0)
	var scroll := ScrollContainer.new()
	scroll.name = "InspectorScroll"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_inspector_column = VBoxContainer.new()
	_inspector_column.name = "InspectorColumn"
	_inspector_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_inspector_column)
	panel.add_child(scroll)
	return panel


func _build_unavailable_panel() -> PanelContainer:
	var panel := PanelContainer.new()
	panel.name = "NativeUnavailable"
	panel.theme_type_variation = &"LevelTaskEmptyState"
	var column := VBoxContainer.new()
	column.name = "UnavailableColumn"
	panel.add_child(column)
	_unavailable_title = Label.new()
	_unavailable_title.name = "UnavailableTitle"
	_unavailable_title.text = "Native extension unavailable"
	_unavailable_title.tooltip_text = "Conversation preview is unavailable until the native extension is loaded"
	column.add_child(_unavailable_title)
	_unavailable_message = Label.new()
	_unavailable_message.name = "UnavailableMessage"
	_unavailable_message.text = "Preview is read-only and disabled. Build and load the Level Task System GDExtension."
	_unavailable_message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_unavailable_message)
	_unavailable_details = Label.new()
	_unavailable_details.name = "UnavailableDetails"
	column.add_child(_unavailable_details)
	return panel


func _build_error_panel() -> PanelContainer:
	var panel := PanelContainer.new()
	panel.name = "PreviewError"
	panel.theme_type_variation = &"LevelTaskEmptyState"
	_error_label = Label.new()
	_error_label.name = "PreviewErrorMessage"
	_error_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_error_label.tooltip_text = "Conversation preview diagnostic"
	panel.add_child(_error_label)
	return panel


func _refresh() -> void:
	if not _built or _refreshing:
		return
	_refreshing = true
	if _unavailable_panel == null:
		_refreshing = false
		return
	var status := _model.get_status()
	var unavailable := not _native_extension_available or bool(status.get("unavailable", false))
	_unavailable_panel.visible = unavailable
	_body.visible = not unavailable
	_trace_panel.visible = not unavailable
	_error_panel.visible = false
	if unavailable:
		var diagnostic: Dictionary = _model.get_diagnostic()
		_unavailable_details.text = "%s · %s" % [String(diagnostic.get("code", "LTS-CONVERSATION-PREVIEW-NATIVE-001")), String(diagnostic.get("path", "conversation.native_extension"))]
		_unavailable_details.tooltip_text = _unavailable_details.text
		_status_label.text = "Unavailable"
		_status_label.tooltip_text = "Native extension unavailable"
		ComponentTheme.apply_state_text(_status_label, ComponentState.ERROR, _status_label.text)
		_restart_button.disabled = true
		_refreshing = false
		return
	var error: Dictionary = status.get("last_error", {}) if status.get("last_error", {}) is Dictionary else {}
	if not error.is_empty() and String(status.get("state", "")) == PreviewModel.STATE_ERROR:
		_error_panel.visible = true
		_error_label.text = "Error %s · %s\n%s" % [String(error.get("code", "LTS-CONVERSATION-PREVIEW")), String(error.get("path", "conversation")), String(error.get("message", "Conversation preview is not available."))]
		_error_label.tooltip_text = _error_label.text
		_status_label.text = "Error"
		ComponentTheme.apply_state_text(_status_label, ComponentState.ERROR, _status_label.text)
	else:
		_status_label.text = String(status.get("state", "inactive")).capitalize()
		_status_label.tooltip_text = "Preview state: %s" % String(status.get("state", "inactive"))
		ComponentTheme.apply_state_text(_status_label, ComponentState.ACTIVE if bool(status.get("started", false)) else ComponentState.DEFAULT, _status_label.text)
	_revision_label.text = "Revision %d" % int(status.get("frame_revision", 0))
	_revision_label.tooltip_text = "Current frame revision %d" % int(status.get("frame_revision", 0))
	_restart_button.disabled = not bool(status.get("configured", false))
	_render_chat()
	_render_inspector()
	_render_trace()
	_refreshing = false


func _render_chat() -> void:
	if _chat_column == null:
		return
	_clear_children(_chat_column)
	var transcript := _model.get_transcript()
	var current_frame := _model.get_frame()
	var status := _model.get_status()
	if transcript.is_empty():
		var empty := Label.new()
		empty.name = "ChatEmpty"
		empty.text = "Start the preview to see conversation lines and choices."
		empty.tooltip_text = empty.text
		_chat_column.add_child(empty)
		return
	for record_value in transcript:
		if not record_value is Dictionary:
			continue
		var record: Dictionary = record_value
		match String(record.get("type", "")):
			"line":
				_render_line_record(record, current_frame, status)
			"choice_prompt":
				_render_choice_record(record, current_frame, status)
			"choice_selected":
				_render_small_message("Selected response: %s" % String(record.get("label_key", record.get("choice_identifier", "choice"))), "Choice %s" % String(record.get("choice_identifier", "")))
			"action_request":
				_render_action_record(record, current_frame, status)
			"outcome":
				_render_small_message("Outcome: %s" % String(record.get("outcome_identifier", "")), "Terminal outcome")
		_chat_scroll.call_deferred("set_v_scroll", int(_chat_scroll.get_v_scroll_bar().max_value))


func _render_line_record(record: Dictionary, current_frame: Dictionary, status: Dictionary) -> void:
	var card := PanelContainer.new()
	card.name = "Line_%s" % _safe_name(String(record.get("step_identifier", "line")))
	card.theme_type_variation = &"LevelTaskGraphNode"
	var column := VBoxContainer.new()
	card.add_child(column)
	var speaker := Label.new()
	speaker.name = "Speaker"
	speaker.text = String(record.get("speaker_identifier", "Speaker"))
	speaker.tooltip_text = speaker.text
	column.add_child(speaker)
	var body := Label.new()
	body.name = "LocalizedLineKey"
	body.text = String(record.get("line_key", ""))
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.tooltip_text = "Localization key (host resolves translated text): %s" % body.text
	column.add_child(body)
	var is_current := String(current_frame.get("step_identifier", "")) == String(record.get("step_identifier", "")) and int(current_frame.get("revision", current_frame.get("frame_revision", -1))) == int(record.get("frame_revision", -2)) and String(status.get("state", "")) == PreviewModel.STATE_LINE
	if is_current:
		var continue_button := Button.new()
		continue_button.name = "ContinueLine"
		continue_button.text = "Continue"
		continue_button.tooltip_text = "Advance this line at frame revision %d" % int(current_frame.get("frame_revision", current_frame.get("revision", 0)))
		continue_button.icon = ComponentTheme.resolve_icon(continue_button, [&"ArrowRight", &"Play"], &"Node")
		continue_button.focus_mode = Control.FOCUS_ALL
		continue_button.pressed.connect(func() -> void: continue_line(int(current_frame.get("frame_revision", current_frame.get("revision", 0)))))
		column.add_child(continue_button)
	_chat_column.add_child(card)


func _render_choice_record(record: Dictionary, current_frame: Dictionary, status: Dictionary) -> void:
	var card := PanelContainer.new()
	card.name = "Choice_%s" % _safe_name(String(record.get("step_identifier", "choice")))
	card.theme_type_variation = &"LevelTaskDrawer"
	var column := VBoxContainer.new()
	card.add_child(column)
	var heading := Label.new()
	heading.name = "ChoiceHeading"
	heading.text = "Choose a response"
	heading.tooltip_text = "Only choices visible under the current fact snapshot can be selected"
	column.add_child(heading)
	var is_current := String(current_frame.get("step_identifier", "")) == String(record.get("step_identifier", "")) and int(current_frame.get("revision", current_frame.get("frame_revision", -1))) == int(record.get("frame_revision", -2)) and String(status.get("state", "")) == PreviewModel.STATE_CHOICE
	var choices: Array = current_frame.get("available_choices", current_frame.get("choices", [])) if is_current else record.get("choices", [])
	if choices.is_empty():
		var empty := Label.new()
		empty.name = "NoAvailableChoices"
		empty.text = "No available choices for the current variables."
		empty.tooltip_text = empty.text
		column.add_child(empty)
	else:
		for choice_value in choices:
			if not choice_value is Dictionary:
				continue
			var choice: Dictionary = choice_value
			var button := Button.new()
			button.name = "Choice_%s" % _safe_name(String(choice.get("identifier", "choice")))
			button.text = String(choice.get("label_key", choice.get("identifier", "Choice")))
			button.tooltip_text = "Select %s" % String(choice.get("identifier", "choice"))
			button.icon = ComponentTheme.resolve_icon(button, [&"Branch", &"ArrowRight"], &"Node")
			button.focus_mode = Control.FOCUS_ALL
			button.disabled = not is_current
			var choice_identifier := String(choice.get("identifier", ""))
			var choice_revision := int(current_frame.get("frame_revision", current_frame.get("revision", record.get("frame_revision", 0))))
			button.pressed.connect(func() -> void: select_choice(choice_identifier, choice_revision))
			column.add_child(button)
	_chat_column.add_child(card)


func _render_action_record(record: Dictionary, current_frame: Dictionary, status: Dictionary) -> void:
	var card := PanelContainer.new()
	card.name = "Action_%s" % _safe_name(String(record.get("step_identifier", "action")))
	var column := VBoxContainer.new()
	card.add_child(column)
	var request: Dictionary = record.get("request", {}) if record.get("request", {}) is Dictionary else {}
	var label := Label.new()
	label.text = "Waiting for host action: %s" % String(request.get("provider_identifier", "provider"))
	label.tooltip_text = "Preview action requests are explicit; the editor does not invoke providers."
	column.add_child(label)
	var is_current := String(status.get("state", "")) == PreviewModel.STATE_WAITING_FOR_ACTION and String(current_frame.get("step_identifier", "")) == String(record.get("step_identifier", ""))
	if is_current:
		var actions := HBoxContainer.new()
		var success := Button.new()
		success.name = "AcknowledgeSuccess"
		success.text = "Acknowledge success"
		success.tooltip_text = "Follow the authored success branch"
		success.focus_mode = Control.FOCUS_ALL
		success.pressed.connect(func() -> void: acknowledge_action(String(request.get("request_identifier", "")), true))
		actions.add_child(success)
		var failure := Button.new()
		failure.name = "AcknowledgeFailure"
		failure.text = "Reject / failure"
		failure.tooltip_text = "Follow the authored failure branch"
		failure.focus_mode = Control.FOCUS_ALL
		failure.pressed.connect(func() -> void: acknowledge_action(String(request.get("request_identifier", "")), false))
		actions.add_child(failure)
		column.add_child(actions)
	_chat_column.add_child(card)


func _render_small_message(text: String, tooltip: String) -> void:
	var label := Label.new()
	label.name = "PreviewMessage"
	label.text = text
	label.tooltip_text = tooltip
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_chat_column.add_child(label)


func _render_inspector() -> void:
	if _inspector_column == null:
		return
	_clear_children(_inspector_column)
	var variables_heading := Label.new()
	variables_heading.name = "VariablesHeading"
	variables_heading.text = "Variables / facts"
	variables_heading.tooltip_text = "Synthetic facts used by condition evaluation"
	_inspector_column.add_child(variables_heading)
	_variable_column = VBoxContainer.new()
	_variable_column.name = "VariableInspection"
	_inspector_column.add_child(_variable_column)
	var variables := _model.inspect_variables()
	if variables.is_empty():
		var empty := Label.new()
		empty.name = "VariablesEmpty"
		empty.text = "No synthetic variables supplied. Missing facts remain false."
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_variable_column.add_child(empty)
	else:
		for row_value in variables:
			if not row_value is Dictionary:
				continue
			var row: Dictionary = row_value
			var label := Label.new()
			label.name = "Variable_%s" % _safe_name(String(row.get("key", "variable")))
			label.text = "%s = %s" % [String(row.get("key", "variable")), _display_value(row.get("value", null))]
			label.tooltip_text = label.text
			_variable_column.add_child(label)

	var conditions_heading := Label.new()
	conditions_heading.name = "ConditionsHeading"
	conditions_heading.text = "Condition visibility"
	conditions_heading.tooltip_text = "All authored choice conditions are shown, including hidden choices and their missing dependencies"
	_inspector_column.add_child(conditions_heading)
	_condition_column = VBoxContainer.new()
	_condition_column.name = "ConditionVisibility"
	_inspector_column.add_child(_condition_column)
	var visibility := _model.get_condition_visibility()
	if visibility.is_empty():
		var empty_conditions := Label.new()
		empty_conditions.name = "ConditionsEmpty"
		empty_conditions.text = "No conditions on the current frame."
		empty_conditions.tooltip_text = empty_conditions.text
		_condition_column.add_child(empty_conditions)
	else:
		for item_value in visibility:
			if not item_value is Dictionary:
				continue
			var item: Dictionary = item_value
			var visible := bool(item.get("visible", false))
			var row := Label.new()
			row.name = "Condition_%s" % _safe_name(String(item.get("owner_identifier", "condition")))
			var state_text := "Visible" if visible else "Hidden"
			row.text = "%s · %s · %s" % [state_text, String(item.get("owner_kind", "condition")).capitalize(), String(item.get("owner_identifier", ""))]
			var reason := String(item.get("reason", ""))
			row.tooltip_text = reason if not reason.is_empty() else row.text
			row.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			ComponentTheme.apply_state_text(row, ComponentState.ACTIVE if visible else ComponentState.DISABLED, row.text)
			_condition_column.add_child(row)
			if not reason.is_empty():
				var detail := Label.new()
				detail.name = "ConditionReason"
				detail.text = "  %s" % reason
				detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
				detail.tooltip_text = reason
				_condition_column.add_child(detail)


func _render_trace() -> void:
	if _trace_label == null:
		return
	var records := _model.get_trace()
	if records.is_empty():
		_trace_label.text = "No runtime activity"
		_trace_label.tooltip_text = _trace_label.text
		return
	var lines: PackedStringArray = []
	for record_value in records:
		if not record_value is Dictionary:
			continue
		var record: Dictionary = record_value
		var sequence := int(record.get("sequence", 0))
		var kind := String(record.get("type", "trace"))
		var step := String(record.get("step_identifier", ""))
		var choice := String(record.get("choice_identifier", ""))
		var suffix := ""
		if not choice.is_empty():
			suffix = " · choice=%s" % choice
		lines.append("#%d %s · %s%s" % [sequence, kind, step, suffix])
	_trace_label.text = "\n".join(lines)
	_trace_label.tooltip_text = _trace_label.text


func _show_unavailable() -> void:
	if not _built:
		return
	_refresh()


func _on_model_frame_changed(frame: Dictionary) -> void:
	preview_changed.emit(frame.duplicate(true))
	if _built:
		_refresh()


func _on_model_trace_changed(records: Array) -> void:
	trace_changed.emit(records.duplicate(true))
	if _built:
		_render_trace()


func _on_model_state_changed(_status: Dictionary) -> void:
	if _built:
		_refresh()


func _on_model_error(error: Dictionary) -> void:
	if _built and String(error.get("code", "")).begins_with("LTS-CONVERSATION-PREVIEW-NATIVE"):
		native_unavailable.emit(error.duplicate(true))


func _clear_children(parent: Node) -> void:
	if parent == null:
		return
	for child in parent.get_children():
		child.free()


func _safe_name(value: String) -> String:
	var result := value.replace(".", "_").replace(":", "_").replace("/", "_").replace(" ", "_")
	return result if not result.is_empty() else "item"


func _display_value(value: Variant) -> String:
	if value == null:
		return "<missing>"
	if value is Dictionary and value.has("type"):
		return JSON.stringify(value)
	if value is Array:
		return JSON.stringify(value)
	return str(value)
