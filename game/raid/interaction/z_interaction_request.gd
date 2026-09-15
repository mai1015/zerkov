class_name ZInteractionRequest
extends RefCounted
## Task 3.8 -- one bounded "may actor A interact with target T now" request.
##
## Presentation/input only ever names `target_id` and `requested_kind` (the
## verb affordance it displayed); it never resolves the target, its range,
## its eligibility, or the acting actor's authoritative position. Those come
## from authoritative state (`ZMovementWorld2D`, the injected target index)
## before `ZInteractionPolicy.evaluate` runs.

var actor_id: ZEntityId = null
var actor_position_px: Vector2 = Vector2.ZERO
var target_id: StringName = &""
var requested_kind: StringName = &""


static func create(
	p_actor_id: ZEntityId,
	p_actor_position_px: Vector2,
	p_target_id: StringName,
	p_requested_kind: StringName
) -> ZInteractionRequest:
	var request := ZInteractionRequest.new()
	request.actor_id = p_actor_id
	request.actor_position_px = p_actor_position_px
	request.target_id = p_target_id
	request.requested_kind = p_requested_kind
	return request
