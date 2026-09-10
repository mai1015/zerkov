class_name GAPickerNavigation
extends RefCounted

## Pure list/search/index-arithmetic helpers shared by the flat/grouped
## attribute/effect/ability/cue/target-schema pickers and by [GAPickerPopup]'s
## keyboard navigation (tasks.md 2.2/2.3) -- no Tree/Control/InputEvent
## dependency, so tests/gameplay_abilities/smoke/test_tag_hierarchy_search.gd
## can drive it with plain integers, strings, and [enum Key] constants.

## Returns the new selected index after [param key] is pressed over a list
## of [param count] rows, currently at [param current] (-1 == no selection).
## An unrecognized key returns [param current] unchanged. An empty list
## (count <= 0) always yields -1.
static func move(current: int, count: int, key: Key) -> int:
	if count <= 0:
		return -1
	match key:
		KEY_DOWN:
			return 0 if current < 0 else mini(current + 1, count - 1)
		KEY_UP:
			return count - 1 if current < 0 else maxi(current - 1, 0)
		KEY_HOME:
			return 0
		KEY_END:
			return count - 1
		_:
			return current


## Case-insensitive substring filter over a flat identifier list, returned
## alphabetically sorted -- the non-hierarchical counterpart of
## [method GATagHierarchy.filter] for attribute/effect/ability/cue/
## target-schema pickers. A blank [param query] returns every identifier,
## still sorted.
static func filter_flat(identifiers: PackedStringArray, query: String) -> PackedStringArray:
	var needle := query.strip_edges().to_lower()
	var result := PackedStringArray()
	for raw_identifier in identifiers:
		var identifier := String(raw_identifier)
		if needle.is_empty() or identifier.to_lower().findn(needle) != -1:
			result.append(identifier)
	result.sort()
	return result


## Groups a flat, already-filtered identifier list by its first dotted
## segment (e.g. "effect.basic.attack_damage" groups under "effect") -- the
## shallow "flat/grouped" presentation design.md decision 2 calls for on
## every non-tag picker, as opposed to the tag picker's full recursive
## hierarchy ([GATagHierarchy]). Each group's identifier list is itself
## sorted.
static func group_by_first_segment(identifiers: PackedStringArray) -> Dictionary:
	var groups: Dictionary = {}
	for raw_identifier in identifiers:
		var identifier := String(raw_identifier)
		if identifier.is_empty():
			continue
		var first_segment := identifier.split(".")[0]
		if not groups.has(first_segment):
			groups[first_segment] = PackedStringArray()
		var bucket: PackedStringArray = groups[first_segment]
		bucket.append(identifier)
		groups[first_segment] = bucket
	for key in groups:
		var bucket: PackedStringArray = groups[key]
		bucket.sort()
		groups[key] = bucket
	return groups
