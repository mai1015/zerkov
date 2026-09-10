@tool
class_name ActionBar
extends HBoxContainer

## Rebuilds itself from immutable active-action snapshots.
##
## The bar owns no routing or binding state: it reads a snapshot, orders it, and
## renders ordinary themed controls. Restyling never re-registers an action.

## Theme type variation applied to each entry's label.
@export var entry_theme_type: StringName = &"":
	set(value):
		entry_theme_type = value
		_restyle()

## Glyph assets handed to each entry's [InputGlyph].
@export var glyph_set: Dictionary = {}

@export var ui_user: int = 0

var _entries: Array[Control] = []
## True while a coalesced rebuild is already scheduled for this frame. A screen
## with ten buttons activating registers ten times, each firing
## active_actions_changed; without this, that is ten full rebuilds instead of
## one.
var _rebuild_pending := false


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	var runtime := _get_runtime()
	if runtime != null:
		runtime.active_actions_changed.connect(_on_active_actions_changed)
		runtime.input_modality_changed.connect(func(_m: int, _d: int) -> void: _queue_rebuild())
	rebuild()


func _get_runtime() -> CommonUIRuntime:
	# An absolute path is only resolvable while inside the tree; nodes that are
	# tearing down must not try to reach the autoload.
	if Engine.is_editor_hint() or not is_inside_tree():
		return null
	return get_node_or_null(^"/root/CommonUI") as CommonUIRuntime


func _on_active_actions_changed(changed_user: int) -> void:
	if changed_user == ui_user:
		_queue_rebuild()


## Coalesces same-frame rebuild requests into one: several registrations
## changing in the same frame (a whole screen's worth of buttons activating)
## each schedule this, but only the first actually queues the deferred call.
func _queue_rebuild() -> void:
	if _rebuild_pending:
		return
	_rebuild_pending = true
	_run_pending_rebuild.call_deferred()


func _run_pending_rebuild() -> void:
	_rebuild_pending = false
	rebuild()


## Rebuilds from the current snapshot. Entries are ordered by descending display
## priority, then by action identifier so the order is stable across rebuilds.
func rebuild() -> void:
	var runtime := _get_runtime()
	if runtime == null:
		return

	var snapshot: Array = runtime.get_active_actions(ui_user)
	var shown: Array[Dictionary] = []
	var seen := {}
	for entry in snapshot:
		if not entry.get("show_in_action_bar", true):
			continue
		var action: StringName = entry["action"]
		# One row per action even when several handlers registered it.
		if seen.has(action):
			continue
		seen[action] = true
		shown.append(entry)

	shown.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if a["display_priority"] != b["display_priority"]:
			return a["display_priority"] > b["display_priority"]
		return String(a["action"]) < String(b["action"]))

	_clear()
	for entry in shown:
		_entries.append(_build_entry(entry))


func _clear() -> void:
	# Freed immediately, not queue_free(): rebuild() adds the replacement
	# entries in this same call, and a deferred free would leave the old ones
	# in the tree alongside the new ones for one visible frame.
	for entry in _entries:
		if is_instance_valid(entry):
			entry.free()
	_entries.clear()


func _build_entry(entry: Dictionary) -> Control:
	var row := HBoxContainer.new()
	add_child(row)

	var glyph := InputGlyph.new()
	glyph.action = entry["action"]
	glyph.glyph_set = glyph_set
	row.add_child(glyph)

	var label := Label.new()
	label.text = _display_name(entry)
	if not String(entry_theme_type).is_empty():
		label.theme_type_variation = entry_theme_type
	row.add_child(label)
	return row


func _display_name(entry: Dictionary) -> String:
	var configured := String(entry.get("display_name", ""))
	if not configured.is_empty():
		return configured
	# Fall back to the last path segment of the namespaced identifier.
	var action: StringName = entry["action"]
	return String(action).get_file().capitalize()


func _restyle() -> void:
	for entry in _entries:
		if not is_instance_valid(entry):
			continue
		for child in entry.get_children():
			var label := child as Label
			if label != null:
				label.theme_type_variation = entry_theme_type
