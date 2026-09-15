class_name RaidAIWorldPort
extends RefCounted
## The only task-3/task-5 integration surface. Owned by raid composition, never
## passed to a brain. Override with real movement/navigation/combat adapters.
## An unbound base port fails startup, rather than creating a second simulation.

func is_ready(_generation: int) -> bool:
	return false


## Exactly {actors: Array, geometry_revision: int, segments: Array}; actor and
## segment schemas are checked by RaidVisionActorRegistry. Called after movement.
func capture_vision_frame(_generation: int, _tick: int) -> Dictionary:
	return {}


## Only this actor's canonical facts, using ZAIAgent.SELF_KEYS.
func self_state(_generation: int, _tick: int, _actor_id: String) -> Dictionary:
	return {}


func patrol_points(_actor_id: String) -> Array:
	return []


func cover_points(_actor_id: String) -> Array:
	return []


## Must invoke task 3.9's bounded navigation seam; no direct transform mutation.
func submit_path_request(_request: Dictionary) -> bool:
	return false


## Full request correlation + points. Empty means still pending, not failure.
func poll_path_result(_generation: int, _tick: int, _actor_id: String) -> Dictionary:
	return {}


## Translate direction_milli and action requests through the SAME player
## movement/combat intent encoder, then RaidAuthority.enqueue_intent(Source.AI).
## Return admission truth only. Do not invoke movement/weapon/health mutation.
func submit_action_request(_request: Dictionary) -> Dictionary:
	return {"admitted": false, "reason": &"ai_game_intent_bridge_unbound"}


## Actual committed/rejected action receipts, not enqueue acknowledgements.
func take_action_results(_generation: int, _tick: int, _actor_id: String) -> Array:
	return []


## Each event: {event_id, source_id, tick, position_raw, category, intensity_milli}.
## Supply committed action/consequence IDs and poses, never an AudioStream signal.
func take_committed_noise(_generation: int, _tick: int) -> Array:
	return []
