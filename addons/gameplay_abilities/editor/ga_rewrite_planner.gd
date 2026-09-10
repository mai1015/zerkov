class_name GARewritePlanner
extends RefCounted

## Turns a [GAUsageScanner] usage report into concrete rewrite edits for a
## rename or delete (tasks.md 2.5). Pure: builds a plain Array of
## {resource, property, old_value, new_value} edit descriptions. Applying
## them through [EditorUndoRedoManager] (or, in tests, a plain [UndoRedo] --
## both expose the identical `create_action`/`add_do_property`/
## `add_undo_property`/`commit_action` surface this class calls) is the only
## editor-touching part, isolated in [method apply_with_undo_redo] below, so
## the planning half stays headlessly testable, see
## tests/gameplay_abilities/smoke/test_rewrite_planner.gd.

## Builds the edit list that renames every SUPPORTED usage-report location
## (see [method GAUsageScanner.usage_report]'s `supported` array) from
## [param old_identifier] to [param new_identifier]. Scalar properties get
## the new identifier directly; packed-array entries get their one matched
## element replaced in place (array order/other elements untouched).
static func plan_rename(supported_locations: Array, new_identifier: String) -> Array:
	var edits: Array = []
	for location in supported_locations:
		var resource: Resource = location["resource"]
		var property: String = location["property"]
		if bool(location.get("is_array", false)):
			var index := int(location["index"])
			var old_array: PackedStringArray = resource.get(property)
			var new_array := old_array.duplicate()
			if index >= 0 and index < new_array.size():
				new_array[index] = new_identifier
			edits.append({"resource": resource, "property": property, "old_value": old_array, "new_value": new_array})
		else:
			var old_value = resource.get(property)
			var new_value = StringName(new_identifier) if typeof(old_value) == TYPE_STRING_NAME else new_identifier
			edits.append({"resource": resource, "property": property, "old_value": old_value, "new_value": new_value})
	return edits


## Builds the edit list that CLEARS every supported usage-report location --
## used before deleting a definition, since a delete has no replacement
## identifier to rewrite to. Scalar properties clear to an empty
## StringName/String (matching each property's own declared type); packed
## array entries remove their one matched element entirely rather than
## blanking it in place, so a cleared array never grows a stray empty entry.
static func plan_clear(supported_locations: Array) -> Array:
	var edits: Array = []
	for location in supported_locations:
		var resource: Resource = location["resource"]
		var property: String = location["property"]
		if bool(location.get("is_array", false)):
			var index := int(location["index"])
			var old_array: PackedStringArray = resource.get(property)
			var new_array := old_array.duplicate()
			if index >= 0 and index < new_array.size():
				new_array.remove_at(index)
			edits.append({"resource": resource, "property": property, "old_value": old_array, "new_value": new_array})
		else:
			var old_value = resource.get(property)
			var empty_value = StringName() if typeof(old_value) == TYPE_STRING_NAME else ""
			edits.append({"resource": resource, "property": property, "old_value": old_value, "new_value": empty_value})
	return edits


## Applies [param edits] through [param undo_redo] as ONE transaction named
## [param action_name] -- works identically with a real
## [EditorUndoRedoManager] (the dashboard) or a plain [UndoRedo] (tests: both
## classes bind the same `create_action`/`add_do_property`/
## `add_undo_property`/`commit_action` methods with the same effective
## semantics -- verified against this project's own built Godot 4.7 editor
## ClassDB). `commit` defaults to true so normal call sites do not have to
## remember it; a caller that wants to fold MORE edits into the same
## transaction before committing (e.g. the dashboard combining a delete's
## reference-clearing edits with removing the definition itself from the
## catalog array) passes false and commits once at the end.
static func apply_with_undo_redo(undo_redo: Object, action_name: String, edits: Array, commit: bool = true) -> void:
	undo_redo.create_action(action_name)
	for edit in edits:
		# Untyped Object, not Resource: GAMigrationPlanner's edits also
		# target a live GameplayAbilityComponent NODE (clearing its legacy
		# arrays), not just Resources.
		var target: Object = edit["resource"]
		var property: String = edit["property"]
		undo_redo.add_do_property(target, property, edit["new_value"])
		undo_redo.add_undo_property(target, property, edit["old_value"])
	if commit:
		undo_redo.commit_action()
