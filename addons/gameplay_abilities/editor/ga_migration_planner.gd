class_name GAMigrationPlanner
extends RefCounted

## Pure preview/plan logic for the "migrate legacy component arrays into a
## catalog" command (tasks.md 2.6, design.md "Migration", spec.md "Author
## accepts a migration preview"). Never touches EditorInterface/
## EditorUndoRedoManager itself -- the dashboard glue reads each candidate
## [GameplayAbilityComponent]'s five Resource-typed legacy arrays into the
## plain `source` Dictionary shape this class consumes:
## [code]{label, component, tag_definitions, attribute_definitions,
## effect_definitions, cue_definitions, target_data_schemas,
## has_legacy_abilities}[/code]
## so tests/gameplay_abilities/smoke/test_migration_planner.gd can build
## fake sources without a live scene tree. `component` is only read back by
## [method plan_apply] (to know what to clear); [method preview] never
## touches it.
##
## `ability_definitions` is deliberately NOT migrated: on
## [GameplayAbilityComponent] it is a plain `Array[Dictionary]` (see that
## class's own header comment), not a `TypedArray[GameplayAbilityDefinition]`
## -- there is no authored ability Resource sitting in the legacy array to
## copy, and reconstructing one from its Dictionary shape would require a
## Dictionary -> Resource reverse of `GameplayAbilityDefinitionBridge` that
## does not exist and is out of this task's edit scope (native/ is frozen
## here). A source with populated `ability_definitions` is instead surfaced
## via `unmigratable_ability_sources` in the preview -- see [method preview]
## -- so the author is told rather than silently left with an un-migrated
## field the "Accept" action does not clear.

const KIND_TAG := "tag"
const KIND_ATTRIBUTE := "attribute"
const KIND_EFFECT := "effect"
const KIND_CUE := "cue"
const KIND_TARGET_SCHEMA := "target_schema"

const KIND_ORDER: PackedStringArray = [KIND_TAG, KIND_ATTRIBUTE, KIND_EFFECT, KIND_CUE, KIND_TARGET_SCHEMA]

## Property name shared verbatim by [GameplayAbilityComponent] (the legacy
## source array) and [GameplayDefinitionCatalog] (the migration target
## collection) for each kind -- both sides happen to use identical spelling
## (`tag_definitions`, `attribute_definitions`, ...), which is what lets
## [method plan_apply] use one name per kind for both the source-clear edit
## and the catalog-append edit.
const PROPERTY_NAME := {
	KIND_TAG: "tag_definitions",
	KIND_ATTRIBUTE: "attribute_definitions",
	KIND_EFFECT: "effect_definitions",
	KIND_CUE: "cue_definitions",
	KIND_TARGET_SCHEMA: "target_data_schemas",
}

const CATALOG_GETTER := {
	KIND_TAG: "get_tag_definitions",
	KIND_ATTRIBUTE: "get_attribute_definitions",
	KIND_EFFECT: "get_effect_definitions",
	KIND_CUE: "get_cue_definitions",
	KIND_TARGET_SCHEMA: "get_target_data_schemas",
}


static func _catalog_identifiers(catalog: Resource, kind: String) -> PackedStringArray:
	var result := PackedStringArray()
	if catalog == null:
		return result
	var getter: String = CATALOG_GETTER[kind]
	if not catalog.has_method(getter):
		return result
	for entry in catalog.call(getter):
		if entry != null and entry.has_method("get_identifier"):
			result.append(String(entry.call("get_identifier")))
	return result


## Builds the migration preview for [param sources] against [param catalog].
## Returns:
## [codeblock]
## {
##   per_kind: { kind: {
##       unique:     [{identifier, resource, source_label}],
##       duplicates: [{identifier, source_labels: PackedStringArray}],
##       collisions: [{identifier, source_label}],
##   } },
##   fields_to_clear: [{source_label, property, kind}],
##   unmigratable_ability_sources: PackedStringArray,
##   has_any_change: bool,
## }
## [/codeblock]
## `unique` is exactly what [method plan_apply] copies into the catalog.
## `collisions` (an identifier already present in the catalog) and every
## occurrence past the first within a `duplicates` group are never copied --
## the preview lists them so the author can resolve/rename before or after
## accepting, matching design.md's "duplicates, identifier collisions" preview
## requirement.
static func preview(sources: Array, catalog: Resource) -> Dictionary:
	var per_kind: Dictionary = {}
	var fields_to_clear: Array = []
	var has_any_change := false

	for kind in KIND_ORDER:
		var seen: Dictionary = {} # identifier -> {resource, source_label} of the FIRST occurrence
		var duplicate_labels: Dictionary = {} # identifier -> PackedStringArray of every source label that declared it
		var catalog_identifiers := _catalog_identifiers(catalog, kind)
		var property: String = PROPERTY_NAME[kind]

		for source in sources:
			var entries: Array = source.get(property, [])
			if not entries.is_empty():
				fields_to_clear.append({"source_label": source.get("label", ""), "property": property, "kind": kind})
			for entry in entries:
				if entry == null or not entry.has_method("get_identifier"):
					continue
				var identifier := String(entry.call("get_identifier"))
				if identifier.is_empty():
					continue
				if seen.has(identifier):
					if not duplicate_labels.has(identifier):
						duplicate_labels[identifier] = PackedStringArray([seen[identifier]["source_label"]])
					var labels: PackedStringArray = duplicate_labels[identifier]
					labels.append(source.get("label", ""))
					duplicate_labels[identifier] = labels
				else:
					seen[identifier] = {"resource": entry, "source_label": source.get("label", "")}

		var unique: Array = []
		var collisions: Array = []
		var duplicates: Array = []
		for identifier in seen:
			if duplicate_labels.has(identifier):
				duplicates.append({"identifier": identifier, "source_labels": duplicate_labels[identifier]})
			elif catalog_identifiers.has(identifier):
				collisions.append({"identifier": identifier, "source_label": seen[identifier]["source_label"]})
			else:
				unique.append({
					"identifier": identifier, "resource": seen[identifier]["resource"],
					"source_label": seen[identifier]["source_label"],
				})

		if not unique.is_empty():
			has_any_change = true
		per_kind[kind] = {"unique": unique, "duplicates": duplicates, "collisions": collisions}

	var unmigratable: PackedStringArray = []
	for source in sources:
		if bool(source.get("has_legacy_abilities", false)):
			unmigratable.append(String(source.get("label", "")))

	return {
		"per_kind": per_kind,
		"fields_to_clear": fields_to_clear,
		"unmigratable_ability_sources": unmigratable,
		"has_any_change": has_any_change,
	}


static func _find_source_component(sources: Array, label: String) -> Object:
	for source in sources:
		if String(source.get("label", "")) == label:
			return source.get("component")
	return null


## Builds the full edit list for accepting [param p_preview] (task 2.6
## "copy unique legacy component-array definitions into the selected
## catalog and clear migrated component fields in one undoable action").
## Returns edits in the SAME {resource, property, old_value, new_value}
## shape [method GARewritePlanner.apply_with_undo_redo] already applies, so
## the dashboard's migration "Accept" action and its rename/delete actions
## share one undo/redo application helper.
static func plan_apply(p_preview: Dictionary, catalog: Resource, sources: Array) -> Array:
	var edits: Array = []

	for kind in KIND_ORDER:
		var unique: Array = p_preview["per_kind"][kind]["unique"]
		if unique.is_empty():
			continue
		var getter: String = CATALOG_GETTER[kind]
		var old_array: Array = catalog.call(getter)
		var new_array := old_array.duplicate()
		for item in unique:
			new_array.append(item["resource"])
		edits.append({"resource": catalog, "property": PROPERTY_NAME[kind], "old_value": old_array, "new_value": new_array})

	for field in p_preview["fields_to_clear"]:
		var component: Object = _find_source_component(sources, String(field["source_label"]))
		if component == null:
			continue
		var property: String = field["property"]
		edits.append({"resource": component, "property": property, "old_value": component.get(property), "new_value": []})

	return edits
