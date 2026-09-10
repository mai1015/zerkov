@tool
class_name LtsFindingsPanel
extends VBoxContainer

## Bounded, searchable findings surface. Activating a row emits a document
## navigation target; the owning workspace decides how to open and focus it.

signal finding_activated(target: Dictionary)

const FindingRow := preload("res://addons/level_task_system/editor/components/lts_finding_row.gd")
const FindingsStore := preload("res://addons/level_task_system/editor/validation/lts_findings_store.gd")

var _store
var _summary_label: Label
var _severity_filter: OptionButton
var _search: LineEdit
var _rows: VBoxContainer
var _empty_label: Label


func _init() -> void:
	name = "FindingsPanel"
	focus_mode = Control.FOCUS_ALL
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL


func _ready() -> void:
	if _rows == null:
		_build()
	if _store == null:
		set_store(FindingsStore.new())
	_refresh()


func set_store(store: Variant) -> void:
	if _store != null and _store.findings_changed.is_connected(_on_findings_changed):
		_store.findings_changed.disconnect(_on_findings_changed)
	_store = store
	if _store != null:
		_store.findings_changed.connect(_on_findings_changed)
	_refresh()


func get_store() -> Variant:
	return _store


func set_findings(findings: Array) -> void:
	if _store == null:
		set_store(FindingsStore.new())
	_store.replace_all(findings)


func focus_search() -> void:
	if _search != null:
		_search.grab_focus()


func _build() -> void:
	var command_row := HBoxContainer.new()
	command_row.name = "FindingCommands"
	add_child(command_row)
	_summary_label = Label.new()
	_summary_label.name = "FindingSummary"
	_summary_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	command_row.add_child(_summary_label)
	_severity_filter = OptionButton.new()
	_severity_filter.name = "SeverityFilter"
	_severity_filter.tooltip_text = "Filter findings by severity"
	_severity_filter.focus_mode = Control.FOCUS_ALL
	_severity_filter.add_item("All severities")
	_severity_filter.add_item("Errors")
	_severity_filter.add_item("Warnings")
	_severity_filter.add_item("Info")
	_severity_filter.item_selected.connect(_on_filter_changed)
	command_row.add_child(_severity_filter)
	_search = LineEdit.new()
	_search.name = "FindingSearch"
	_search.placeholder_text = "Filter by code, path, or message"
	_search.tooltip_text = "Search validation findings"
	_search.clear_button_enabled = true
	_search.focus_mode = Control.FOCUS_ALL
	_search.custom_minimum_size.x = 240.0
	_search.text_changed.connect(_on_search_changed)
	command_row.add_child(_search)
	var scroll := ScrollContainer.new()
	scroll.name = "FindingScroll"
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(scroll)
	_rows = VBoxContainer.new()
	_rows.name = "FindingRows"
	_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_rows)
	_empty_label = Label.new()
	_empty_label.name = "FindingEmptyState"
	_empty_label.text = "No findings match the current filter."
	_empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_empty_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_empty_label.custom_minimum_size.y = 48.0
	_rows.add_child(_empty_label)


func _refresh() -> void:
	if _rows == null or _summary_label == null:
		return
	for child in _rows.get_children():
		if child != _empty_label:
			child.queue_free()
	var findings: Array = []
	var summary := {"error": 0, "warning": 0, "info": 0, "total": 0}
	if _store != null:
		findings = _store.get_findings(_selected_severity(), _search.text if _search != null else "")
		summary = _store.get_summary()
	_summary_label.text = "%d findings — %d errors, %d warnings" % [summary.get("total", 0), summary.get("error", 0), summary.get("warning", 0)]
	_summary_label.tooltip_text = "%d informational findings" % summary.get("info", 0)
	_empty_label.visible = findings.is_empty()
	for finding_value in findings:
		if not finding_value is Dictionary:
			continue
		var finding: Dictionary = finding_value
		var row = FindingRow.new()
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var severity := String(finding.get("severity", "info")).capitalize()
		row.setup(severity, String(finding.get("code", "")), String(finding.get("path", "")), String(finding.get("message", "")))
		row.finding_activated.connect(_activate_finding.bind(finding.duplicate(true)))
		_rows.add_child(row)


func _selected_severity() -> String:
	if _severity_filter == null:
		return ""
	match _severity_filter.selected:
		1:
			return "error"
		2:
			return "warning"
		3:
			return "info"
	return ""


func _activate_finding(finding: Dictionary) -> void:
	finding_activated.emit({
		"resource_kind": String(finding.get("resource_kind", "")),
		"resource_identifier": String(finding.get("resource_identifier", "")),
		"element_kind": String(finding.get("element_kind", "")),
		"element_identifier": String(finding.get("element_identifier", "")),
		"field_path": String(finding.get("field_path", "")),
		"path": String(finding.get("path", "")),
	})


func _on_findings_changed(_summary: Dictionary) -> void:
	_refresh()


func _on_filter_changed(_index: int) -> void:
	_refresh()


func _on_search_changed(_value: String) -> void:
	_refresh()
