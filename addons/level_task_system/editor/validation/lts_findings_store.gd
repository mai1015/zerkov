class_name LtsFindingsStore
extends RefCounted

## Deterministic editor-facing store for full and incremental validation.

signal findings_changed(summary: Dictionary)
signal finding_activated(target: Dictionary)

const Validator := preload("res://addons/level_task_system/editor/validation/lts_document_validator.gd")

var _findings: Array = []


func replace_all(findings: Array) -> void:
	_findings = _normalized(findings)
	findings_changed.emit(Validator.summary(_findings))


func replace_for_paths(changed_paths: PackedStringArray, findings: Array) -> void:
	if changed_paths.is_empty():
		replace_all(findings)
		return
	var retained: Array = []
	for value in _findings:
		if not value is Dictionary or not _matches_paths(String(value.get("path", "")), changed_paths):
			retained.append(value)
	for value in findings:
		retained.append(value)
	_findings = _normalized(retained)
	findings_changed.emit(Validator.summary(_findings))


func validate_document(source: Variant, changed_paths: PackedStringArray = PackedStringArray()) -> Array:
	var fresh := Validator.validate(source, changed_paths)
	if changed_paths.is_empty():
		replace_all(fresh)
	else:
		replace_for_paths(changed_paths, fresh)
	return get_findings()


func get_findings(severity: String = "", query: String = "") -> Array:
	var result: Array = []
	var normalized_query := query.strip_edges().to_lower()
	var normalized_severity := severity.strip_edges().to_lower()
	for value in _findings:
		if not value is Dictionary:
			continue
		var finding: Dictionary = value
		if not normalized_severity.is_empty() and String(finding.get("severity", "")).to_lower() != normalized_severity:
			continue
		if not normalized_query.is_empty():
			var haystack := "%s %s %s %s" % [finding.get("code", ""), finding.get("path", ""), finding.get("message", ""), finding.get("severity", "")]
			if not haystack.to_lower().contains(normalized_query):
				continue
		result.append(finding.duplicate(true))
	return result


func get_summary() -> Dictionary:
	return Validator.summary(_findings)


func clear() -> void:
	replace_all([])


func activate(index: int, severity: String = "", query: String = "") -> Dictionary:
	var visible := get_findings(severity, query)
	if index < 0 or index >= visible.size():
		return {}
	var target := Validator.navigation_target(visible[index])
	finding_activated.emit(target)
	return target


static func _matches_paths(finding_path: String, paths: PackedStringArray) -> bool:
	for changed_path in paths:
		var path := String(changed_path)
		if path.is_empty() or finding_path == path or finding_path.begins_with(path + ".") or path.begins_with(finding_path + "."):
			return true
	return false


static func _normalized(findings: Array) -> Array:
	var by_identity: Dictionary = {}
	for value in findings:
		if not value is Dictionary:
			continue
		var finding: Dictionary = value.duplicate(true)
		var identity := "%s\u001f%s\u001f%s" % [finding.get("severity", "info"), finding.get("path", ""), finding.get("code", "")]
		by_identity[identity] = finding
	var result: Array = by_identity.values()
	Validator._sort_findings(result)
	return result
