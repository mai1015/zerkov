class_name GameplayDefinitionValidation
extends RefCounted

## Editor-side helper that loads every gameplay-ability definition [Resource]
## (.tres) under a directory, classifies it by native type, and runs
## [GameplayDefinitionValidator] over the whole set in one pass.
##
## Modeled on [code]addons/common_ui/diagnostics/common_ui_action_validator.gd[/code]:
## static entry points, a findings array of
## [code]{severity, resource_path, field, code, message}[/code] dictionaries,
## and small [code]is_ok[/code]/[code]format[/code] convenience wrappers. The
## real validation work happens in the native [GameplayDefinitionValidator]
## (native/godot/gameplay_definition_validator.h), which runs the
## engine-independent core's own registries and validators -- this script
## only discovers and classifies the resources on disk.
##
## Usage (editor script, a plugin menu item, or a headless
## [code]godot --headless --script ...[/code] CI step):
## [codeblock]
## var findings := GameplayDefinitionValidation.validate_directory(
##     "res://addons/gameplay_abilities/resources/")
## if not GameplayDefinitionValidation.is_ok(findings):
##     push_error(GameplayDefinitionValidation.format(findings))
## [/codeblock]

const SEVERITY_ERROR := &"error"


## Scans [param p_directory] recursively for [code].tres[/code] files,
## classifies each by native resource type, and validates the whole set in
## one [GameplayDefinitionValidator.validate] call. Returns
## [code]{validator, findings}[/code] so callers that need the manifest
## fields (see [method validate_directory_with_manifest]) don't have to
## re-scan/re-validate the directory a second time. Shared by
## [method validate_directory] and [method validate_directory_with_manifest]
## below -- keep both in sync with this helper rather than duplicating the
## scan loop.
static func _run_validation(p_directory: String) -> Dictionary:
	var tags: Array[GameplayTagDefinition] = []
	var attributes: Array[GameplayAttributeDefinition] = []
	var effects: Array[GameplayEffectDefinition] = []
	var cues: Array[GameplayCueDefinition] = []
	var tag_queries: Array[GameplayTagQueryResource] = []
	var target_schemas: Array[GameplayTargetDataSchema] = []

	for path in _find_tres_files(p_directory):
		var resource: Resource = load(path)
		if resource == null:
			continue
		if resource is GameplayTagDefinition:
			tags.append(resource)
		elif resource is GameplayAttributeDefinition:
			attributes.append(resource)
		elif resource is GameplayEffectDefinition:
			effects.append(resource)
		elif resource is GameplayCueDefinition:
			cues.append(resource)
		elif resource is GameplayTagQueryResource:
			tag_queries.append(resource)
		elif resource is GameplayTargetDataSchema:
			target_schemas.append(resource)

	var validator := GameplayDefinitionValidator.new()
	var findings: Array[Dictionary] = []
	findings.assign(validator.validate(tags, attributes, effects, cues, tag_queries, target_schemas))

	return {"validator": validator, "findings": findings}


## Scans [param p_directory] recursively for [code].tres[/code] files,
## classifies each by native resource type, and validates the whole set in
## one [GameplayDefinitionValidator.validate] call. Prints a bounded report
## (and the resulting content-manifest fingerprint on success) unless
## [param p_quiet] is true. Returns the raw findings array.
static func validate_directory(p_directory: String, p_quiet := false) -> Array[Dictionary]:
	var result := _run_validation(p_directory)
	var validator: GameplayDefinitionValidator = result["validator"]
	var findings: Array[Dictionary] = result["findings"]

	if not p_quiet:
		print(format(findings))
		if validator.get_last_manifest_ok():
			print("Content manifest: fingerprint=%d entries=%d tick_rate=%d" % [
				validator.get_last_manifest_fingerprint(),
				validator.get_last_manifest_entry_count(),
				validator.get_last_manifest_tick_rate(),
			])

	return findings


## Same as [method validate_directory], but also returns the resulting
## content-manifest fields -- meaningful only when [code]manifest_ok[/code]
## is true -- for callers, like the editor dashboard, that need the
## fingerprint/entry-count/tick-rate without re-scanning and re-validating
## the directory a second time. Returns
## [code]{findings, manifest_ok, fingerprint, entry_count, tick_rate}[/code];
## never prints anything (unlike [method validate_directory]).
static func validate_directory_with_manifest(p_directory: String) -> Dictionary:
	var result := _run_validation(p_directory)
	var validator: GameplayDefinitionValidator = result["validator"]
	return {
		"findings": result["findings"],
		"manifest_ok": validator.get_last_manifest_ok(),
		"fingerprint": validator.get_last_manifest_fingerprint(),
		"entry_count": validator.get_last_manifest_entry_count(),
		"tick_rate": validator.get_last_manifest_tick_rate(),
	}


## Recursively collects every [code].tres[/code] path beneath [param p_directory].
## Returns an empty result rather than erroring when the directory is missing,
## so a not-yet-authored resources folder is a bounded no-op, not a crash.
static func _find_tres_files(p_directory: String) -> PackedStringArray:
	var results := PackedStringArray()
	var dir := DirAccess.open(p_directory)
	if dir == null:
		return results
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if not entry.begins_with("."):
			var full_path := p_directory.path_join(entry)
			if dir.current_is_dir():
				results.append_array(_find_tres_files(full_path))
			elif entry.ends_with(".tres"):
				results.append(full_path)
		entry = dir.get_next()
	dir.list_dir_end()
	return results


## Same shape as [method validate_directory_with_manifest], but validates one
## already-loaded [GameplayDefinitionCatalog] resource directly via
## [method GameplayDefinitionValidator.validate_catalog] (task 1.5) instead
## of scanning a directory -- the dashboard's catalog-centric "Catalog" tab
## (tasks.md 2.1) uses this; [method validate_directory_with_manifest]
## remains unchanged for the legacy directory-scan path/tests that still
## exercise it. A null [param p_catalog] (nothing selected yet) is a bounded
## "no findings, no manifest" result rather than an error.
static func validate_catalog_resource(p_catalog: GameplayDefinitionCatalog) -> Dictionary:
	var findings: Array[Dictionary] = []
	if p_catalog == null:
		return {"findings": findings, "manifest_ok": false, "fingerprint": 0, "entry_count": 0, "tick_rate": 0}
	var validator := GameplayDefinitionValidator.new()
	findings.assign(validator.validate_catalog(p_catalog))
	return {
		"findings": findings,
		"manifest_ok": validator.get_last_manifest_ok(),
		"fingerprint": validator.get_last_manifest_fingerprint(),
		"entry_count": validator.get_last_manifest_entry_count(),
		"tick_rate": validator.get_last_manifest_tick_rate(),
	}


## True when no finding has [constant SEVERITY_ERROR] severity.
static func is_ok(findings: Array[Dictionary]) -> bool:
	for finding in findings:
		if finding["severity"] == SEVERITY_ERROR:
			return false
	return true


## A one-line-per-finding bounded report suitable for logs or CI output.
static func format(findings: Array[Dictionary]) -> String:
	if findings.is_empty():
		return "GameplayAbilities definition validation: OK"
	var lines := PackedStringArray()
	for finding in findings:
		var path: String = finding.get("resource_path", "")
		var field: String = finding.get("field", "")
		var location := path
		if not field.is_empty():
			location = "%s:%s" % [location, field] if not location.is_empty() else field
		lines.append("[%s] (%s) %s: %s" % [
			String(finding["severity"]).to_upper(), finding["code"], location, finding["message"],
		])
	return "\n".join(lines)
