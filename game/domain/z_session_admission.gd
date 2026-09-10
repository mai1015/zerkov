class_name ZSessionAdmission
extends RefCounted
## Immutable-by-convention result produced by every session ingress adapter.

enum TrustLevel {
	NONE,
	LOCAL_TRUSTED,
	REMOTE_AUTHENTICATED,
}

var accepted: bool = false
var reason: StringName = &"rejected"
var request_id: ZRequestId
var raid_id: ZRaidId
var session_id: ZSessionId
var actor_id: ZEntityId
var authority_epoch: int = 0
var generation: int = 0
var trust_level: TrustLevel = TrustLevel.NONE


static func reject(p_request_id: ZRequestId, code: StringName) -> ZSessionAdmission:
	var result := ZSessionAdmission.new()
	result.request_id = p_request_id
	result.reason = code
	return result


static func accept_local(
	request: ZSessionRequest,
	p_session_id: ZSessionId,
	p_actor_id: ZEntityId
) -> ZSessionAdmission:
	var result := ZSessionAdmission.new()
	result.accepted = true
	result.reason = &""
	result.request_id = request.request_id
	result.raid_id = request.raid_id
	result.session_id = p_session_id
	result.actor_id = p_actor_id
	result.authority_epoch = request.requested_authority_epoch
	result.generation = request.requested_authority_epoch
	result.trust_level = TrustLevel.LOCAL_TRUSTED
	return result


func is_usable() -> bool:
	return (
		accepted
		and request_id != null
		and request_id.is_initialized()
		and request_id.kind() == ZRequestId.KIND
		and raid_id != null
		and raid_id.is_initialized()
		and raid_id.kind() == ZRaidId.KIND
		and session_id != null
		and session_id.is_initialized()
		and session_id.kind() == ZSessionId.KIND
		and actor_id != null
		and actor_id.is_initialized()
		and actor_id.kind() == ZEntityId.KIND
		and authority_epoch > 0
		and generation > 0
		and (trust_level == TrustLevel.LOCAL_TRUSTED
			or trust_level == TrustLevel.REMOTE_AUTHENTICATED)
	)


func snapshot() -> ZSessionAdmission:
	if not is_usable():
		return null
	var result := ZSessionAdmission.new()
	result.accepted = accepted
	result.reason = reason
	result.request_id = ZRequestId.parse(request_id.canonical_key())
	result.raid_id = ZRaidId.parse(raid_id.canonical_key())
	result.session_id = ZSessionId.parse(session_id.canonical_key())
	result.actor_id = ZEntityId.parse(actor_id.canonical_key())
	result.authority_epoch = authority_epoch
	result.generation = generation
	result.trust_level = trust_level
	return result if result.is_usable() else null
