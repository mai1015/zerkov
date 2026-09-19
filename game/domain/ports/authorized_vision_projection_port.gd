class_name ZAuthorizedVisionProjectionPort
extends RefCounted
## Fail-closed value-only source for recipient-authorized Vision projections.
##
## A production adapter may wrap RaidVisionActorRegistry/Common Vision, but it
## must expose neither the native world nor a complete identity map. Hidden and
## remembered target identities are resolved only when a record is currently
## visible to the exact authorized recipient.


func is_authorized_recipient(
	_recipient_actor_id: ZEntityId,
	_generation: int
) -> bool:
	return false


func projection_for(
	_recipient_actor_id: ZEntityId,
	_generation: int
) -> Dictionary:
	return {}


func entity_for_visible_native_id(
	_recipient_actor_id: ZEntityId,
	_native_target_id: int,
	_generation: int
) -> ZEntityId:
	return null
