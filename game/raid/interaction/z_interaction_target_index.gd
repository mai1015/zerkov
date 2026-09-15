class_name ZInteractionTargetIndex
extends RefCounted
## Task 3.8 -- builds a static `ZInteractionTargetState` index from authored
## Sawmill layout data: task 3.11 typed markers plus Obstacles-layer `role ==
## "gate"` structures for doors (there is no dedicated door marker resource
## yet, and this task does not invent one).
##
## Duck-typed against the layout resource shape, the same way
## `ZMovementWorldBuilder` stays decoupled from a hard `ZSawmillYardLayout`
## dependency. This builder only reads authored data -- it never mutates the
## layout and never loads a scene. Any marker or gate whose cell/rect fails a
## `ZWorldUnits` conversion is skipped rather than silently indexed at an
## invented position. It cannot resolve `heal_target` entries (those name a
## live actor, not static layout data); callers add those to the index
## directly via `ZInteractionPolicyOwner.upsert_target`.
##
## Returns `{"ok": bool, "targets": Dictionary}` where `targets` maps the
## String target id to its `ZInteractionTargetState`; `last_error` names the
## fail-closed reason when `ok` is false.

const GATE_ROLE: String = "gate"
const OBSTACLE_LAYER: String = "Obstacles"

static var last_error: StringName = &""


static func build_from_sawmill_layout(layout: Resource) -> Dictionary:
	last_error = &""
	var targets: Dictionary = {}
	if layout == null:
		last_error = &"layout_missing"
		return {"ok": false, "targets": {}}
	if not layout.has_method("all_markers"):
		last_error = &"layout_api_invalid"
		return {"ok": false, "targets": {}}

	for marker_value in (layout.all_markers() as Array):
		var marker := marker_value as ZWorldMarker
		var target := _target_from_marker(marker)
		if target != null:
			targets[String(target.target_id)] = target

	var structures_value: Variant = layout.get("structures")
	if typeof(structures_value) == TYPE_ARRAY:
		for row_value in (structures_value as Array):
			if typeof(row_value) != TYPE_DICTIONARY:
				continue
			var row: Dictionary = row_value
			if String(row.get("layer", "")) != OBSTACLE_LAYER:
				continue
			if String(row.get("role", "")) != GATE_ROLE:
				continue
			var door_target := _target_from_gate_row(row)
			if door_target != null:
				targets[String(door_target.target_id)] = door_target

	return {"ok": true, "targets": targets}


static func _target_from_marker(marker: ZWorldMarker) -> ZInteractionTargetState:
	if marker == null:
		return null
	var position := ZWorldUnits.tile_center_to_godot(marker.cell)
	if not position.ok:
		return null
	if marker is ZLootMarker:
		var loot := marker as ZLootMarker
		var kind := ZInteractionKind.CORPSE if loot.is_corpse else ZInteractionKind.CRATE
		return ZInteractionTargetState.create_point(
			loot.marker_id, kind, position.vector2_value
		)
	if marker is ZObjectiveMarker:
		return ZInteractionTargetState.create_point(
			marker.marker_id, ZInteractionKind.CRATE, position.vector2_value
		)
	if marker is ZExtractionMarker:
		var extraction := marker as ZExtractionMarker
		return ZInteractionTargetState.create_zone(
			extraction.marker_id, position.vector2_value, extraction.zone_cells
		)
	return null


static func _target_from_gate_row(row: Dictionary) -> ZInteractionTargetState:
	var id_text := String(row.get("id", ""))
	if id_text.is_empty():
		return null
	var rect_value: Variant = row.get("rect")
	if typeof(rect_value) != TYPE_RECT2I:
		return null
	var rect: Rect2i = rect_value
	var top_left := ZWorldUnits.tile_origin_to_godot(rect.position)
	var bottom_right := ZWorldUnits.tile_origin_to_godot(rect.position + rect.size)
	if not top_left.ok or not bottom_right.ok:
		return null
	var center := (top_left.vector2_value + bottom_right.vector2_value) / 2.0
	return ZInteractionTargetState.create_point(
		StringName(id_text), ZInteractionKind.DOOR, center
	)