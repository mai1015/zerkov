class_name ZInteractionTargetState
extends RefCounted
## Task 3.8 -- one authoritative interaction target snapshot.
##
## Plain injected data, never a live scene reference: `ZInteractionPolicy`
## reads it, never mutates it, and never resolves it from a Node. Doors,
## crates, corpses and heal targets are point anchors (`position_px`);
## extraction zones are area anchors (`zone_cells`) per the documented
## containment-vs-radius split in `ZInteractionPolicy`.
##
## `eligibility_context` carries the current-state flags `ZInteractionPolicy`
## consults for this target's kind (for example `{"locked": true}` for a
## door). Owning systems for most of these flags do not exist yet in the
## first playable; see `ZInteractionPolicy` for each kind's documented
## default when a flag is absent.

var target_id: StringName = &""
var kind: StringName = &""
var position_px: Vector2 = Vector2.ZERO
var zone_cells: Rect2i = Rect2i()
var eligibility_context: Dictionary = {}


static func create_point(
	p_target_id: StringName,
	p_kind: StringName,
	p_position_px: Vector2,
	p_eligibility_context: Dictionary = {}
) -> ZInteractionTargetState:
	var state := ZInteractionTargetState.new()
	state.target_id = p_target_id
	state.kind = p_kind
	state.position_px = p_position_px
	state.eligibility_context = p_eligibility_context.duplicate(true)
	return state


## Extraction is always `ZInteractionKind.EXTRACTION_ZONE`; `position_px` is
## kept only as an informational anchor (for example presentation labels),
## never consulted by the range/eligibility decision for this kind.
static func create_zone(
	p_target_id: StringName,
	p_position_px: Vector2,
	p_zone_cells: Rect2i,
	p_eligibility_context: Dictionary = {}
) -> ZInteractionTargetState:
	var state := ZInteractionTargetState.new()
	state.target_id = p_target_id
	state.kind = ZInteractionKind.EXTRACTION_ZONE
	state.position_px = p_position_px
	state.zone_cells = p_zone_cells
	state.eligibility_context = p_eligibility_context.duplicate(true)
	return state


## Bounded authoring problems for this snapshot, in deterministic order.
## `ZInteractionPolicyOwner.upsert_target` rejects any state whose list is
## non-empty; the pure policy itself only ever reads validated state.
func validate() -> Array[String]:
	var problems: Array[String] = []
	if String(target_id).is_empty():
		problems.append("target_id is empty")
	if not ZInteractionKind.is_valid(kind):
		problems.append("kind is not an interaction kind: %s" % String(kind))
	var anchor_tile := ZWorldUnits.godot_to_tile(position_px)
	if not anchor_tile.ok:
		problems.append(
			"position_px is not a convertible Godot position: %s" % str(position_px)
		)
	if kind == ZInteractionKind.EXTRACTION_ZONE:
		if zone_cells.size.x <= 0 or zone_cells.size.y <= 0:
			problems.append(
				"zone_cells has non-positive dimensions: %s" % str(zone_cells)
			)
		elif anchor_tile.ok and not zone_cells.has_point(anchor_tile.vector2i_value):
			problems.append(
				"zone_cells %s does not contain the anchor cell" % str(zone_cells)
			)
	return problems


## Canonical fixed-point record: the authored px position is converted to
## microunits through `ZWorldUnits` only, and the tile rect is stored as plain
## ints (`ZCanonicalValue` has no Rect2i vocabulary).
func canonical_record() -> Dictionary:
	var position_micro := ZWorldUnits.godot_to_canonical(position_px)
	return {
		"eligibility": eligibility_context.duplicate(true),
		"kind": String(kind),
		"position_micro": position_micro.vector2i_value
			if position_micro.ok else Vector2i.ZERO,
		"target_id": String(target_id),
		"zone_cells": [
			zone_cells.position.x, zone_cells.position.y,
			zone_cells.size.x, zone_cells.size.y,
		],
	}


func digest() -> String:
	return ZCanonicalValue.sha256(canonical_record())
