class_name ZSessionRequest
extends RefCounted
## Transport-neutral request presented to a session ingress port.

enum Mode {
	OFFLINE,
	REMOTE,
}

const MAX_CREDENTIAL_BYTES: int = 4096
const MAX_TRANSPORT_PEER_ID: int = 2_147_483_647

var mode: Mode = Mode.OFFLINE
var request_id: ZRequestId
var raid_id: ZRaidId
var profile_key: StringName = &""
var actor_slot: StringName = &""
var requested_authority_epoch: int = 0
var credential: PackedByteArray = PackedByteArray()
var transport_peer_id: int = 0
var client_instance: StringName = &""
var compatibility: ZProductCompatibilityManifest


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


static func create_remote(
	p_request_id: ZRequestId,
	p_raid_id: ZRaidId,
	p_profile_key: StringName,
	p_actor_slot: StringName,
	p_epoch: int,
	p_transport_peer_id: int,
	p_client_instance: StringName,
	p_credential: PackedByteArray,
	p_compatibility: ZProductCompatibilityManifest
) -> ZSessionRequest:
	var result := ZSessionRequest.new()
	result.mode = Mode.REMOTE
	result.request_id = p_request_id
	result.raid_id = p_raid_id
	result.profile_key = p_profile_key
	result.actor_slot = p_actor_slot
	result.requested_authority_epoch = p_epoch
	result.transport_peer_id = p_transport_peer_id
	result.client_instance = p_client_instance
	result.credential = p_credential.duplicate()
	result.compatibility = p_compatibility.snapshot() if p_compatibility != null else null
	return result


func is_well_formed() -> bool:
	return (
		int(mode) >= int(Mode.OFFLINE)
		and int(mode) <= int(Mode.REMOTE)
		and request_id != null
		and request_id.is_initialized()
		and request_id.kind() == ZRequestId.KIND
		and raid_id != null
		and raid_id.is_initialized()
		and raid_id.kind() == ZRaidId.KIND
		and ZIdentityRules.is_valid_part(String(profile_key))
		and ZIdentityRules.is_valid_part(String(actor_slot))
		and requested_authority_epoch > 0
		and credential.size() <= MAX_CREDENTIAL_BYTES
	)


func is_well_formed_remote() -> bool:
	return (
		is_well_formed()
		and mode == Mode.REMOTE
		and transport_peer_id > 1
		and transport_peer_id <= MAX_TRANSPORT_PEER_ID
		and ZIdentityRules.is_valid_part(String(client_instance))
		and not credential.is_empty()
		and compatibility != null
		and compatibility.is_well_formed()
	)


func snapshot() -> ZSessionRequest:
	if not is_well_formed():
		return null
	var request_copy := ZRequestId.parse(request_id.canonical_key())
	var raid_copy := ZRaidId.parse(raid_id.canonical_key())
	if request_copy == null or raid_copy == null:
		return null
	var result := ZSessionRequest.new()
	result.mode = mode
	result.request_id = request_copy
	result.raid_id = raid_copy
	result.profile_key = profile_key
	result.actor_slot = actor_slot
	result.requested_authority_epoch = requested_authority_epoch
	result.credential = credential.duplicate()
	result.transport_peer_id = transport_peer_id
	result.client_instance = client_instance
	result.compatibility = compatibility.snapshot() if compatibility != null else null
	if mode == Mode.REMOTE and not result.is_well_formed_remote():
		return null
	return result
