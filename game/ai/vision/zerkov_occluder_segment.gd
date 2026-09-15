class_name ZerkovOccluderSegment
extends RefCounted
## One stable, baked Common Vision occluder line segment.
##
## Produced only by `ZOccluderBake`. Endpoints are already-converted Vision
## raw microunit coordinates (see `ZWorldUnits.godot_to_vision`); nothing
## downstream of the bake infers occluders from physics, TileMaps, or the
## Sawmill scene.

var id: String = ""
var mask: int = 0
var a: Vector2i = Vector2i.ZERO
var b: Vector2i = Vector2i.ZERO
## Sorted, distinct authored `structures` row ids that contributed to this
## segment's boundary. Kept as a plain Array (not PackedStringArray) so the
## record stays compatible with `ZCanonicalValue`.
var source_ids: Array = []


static func create(
	p_id: String,
	p_mask: int,
	p_a: Vector2i,
	p_b: Vector2i,
	p_source_ids: Array
) -> ZerkovOccluderSegment:
	var segment := ZerkovOccluderSegment.new()
	segment.id = p_id
	segment.mask = p_mask
	segment.a = p_a
	segment.b = p_b
	segment.source_ids = p_source_ids.duplicate()
	return segment


func is_degenerate() -> bool:
	return a == b


func canonical_record() -> Dictionary:
	return {
		"a": a,
		"b": b,
		"id": id,
		"mask": mask,
		"source_ids": source_ids.duplicate(),
	}


func digest() -> String:
	return ZCanonicalValue.sha256(canonical_record())
