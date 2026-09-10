extends RefCounted

## Shared state vocabulary for the level/task editor component showcase.
##
## This is intentionally a data-only helper. It has no dependency on
## EditorInterface or Control, so document projections and headless fixtures
## can use it without constructing an editor surface.

const DEFAULT: StringName = &"default"
const HOVER: StringName = &"hover"
const ACTIVE: StringName = &"active"
const FOCUS: StringName = &"focus"
const DISABLED: StringName = &"disabled"
const LOADING: StringName = &"loading"
const EMPTY: StringName = &"empty"
const ERROR: StringName = &"error"

const ORDER: Array[StringName] = [
	DEFAULT,
	HOVER,
	ACTIVE,
	FOCUS,
	DISABLED,
	LOADING,
	EMPTY,
	ERROR,
]

const LABELS: Dictionary = {
	DEFAULT: "Default",
	HOVER: "Hover",
	ACTIVE: "Active",
	FOCUS: "Focus",
	DISABLED: "Disabled",
	LOADING: "Loading",
	EMPTY: "Empty",
	ERROR: "Error",
}

## EditorIcons names are data, not rendered glyphs. Components resolve these
## names through the active editor theme and fall back to another editor icon
## when a theme revision does not expose the preferred metaphor.
const ICONS: Dictionary = {
	DEFAULT: &"Node",
	HOVER: &"Search",
	ACTIVE: &"Check",
	FOCUS: &"Edit",
	DISABLED: &"Lock",
	LOADING: &"Progress1",
	EMPTY: &"Folder",
	ERROR: &"Error",
}


static func all_states() -> Array[StringName]:
	return ORDER.duplicate()


static func normalize(value: Variant) -> StringName:
	var candidate := StringName(str(value))
	if ORDER.has(candidate):
		return candidate
	return DEFAULT


static func label(value: Variant) -> String:
	return String(LABELS.get(normalize(value), LABELS[DEFAULT]))


static func icon_name(value: Variant) -> StringName:
	return StringName(ICONS.get(normalize(value), ICONS[DEFAULT]))


static func is_blocked(value: Variant) -> bool:
	var state := normalize(value)
	return state == DISABLED or state == LOADING


static func is_content_state(value: Variant) -> bool:
	var state := normalize(value)
	return state == LOADING or state == EMPTY or state == ERROR


static func state_index(value: Variant) -> int:
	return ORDER.find(normalize(value))


static func has_complete_matrix(states: Array) -> bool:
	var seen: Dictionary = {}
	for value in states:
		seen[normalize(value)] = true
	for state in ORDER:
		if not seen.has(state):
			return false
	return true
