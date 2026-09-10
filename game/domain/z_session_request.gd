class_name ZSessionRequest
extends RefCounted
## Transport-neutral request presented to a session ingress port.

enum Mode {
	OFFLINE,
	REMOTE,
}

var mode: Mode = Mode.OFFLINE
var request_id: ZRequestId
var raid_id: ZRaidId
var profile_key: StringName = &""
var actor_slot: StringName = &""
var requested_authority_epoch: int = 0
var credential: PackedByteArray = PackedByteArray()


static func create_offline(
	p_request_id: ZRequestId,
	p_raid_id: ZRaidId,
	p_profile_key: StringName,
	p_actor_slot: StringName,
	p_epoch: int
) -> ZSessionRequest:
	var result := ZSessionRequest.new()
	result.mode = Mode.OFFLINE
	result.request_id = p_request_id
	result.raid_id = p_raid_id
	result.profile_key = p_profile_key
	result.actor_slot = p_actor_slot
	result.requested_authority_epoch = p_epoch
	return result


func is_well_formed() -> bool:
	return (
		request_id != null
		and request_id.is_initialized()
		and request_id.kind() == ZRequestId.KIND
		and raid_id != null
		and raid_id.is_initialized()
		and raid_id.kind() == ZRaidId.KIND
		and ZIdentityRules.is_valid_part(String(profile_key))
		and ZIdentityRules.is_valid_part(String(actor_slot))
		and requested_authority_epoch > 0
		and credential.size() <= 4096
	)
