class_name AuthenticatedSessionIngress
extends ZSessionIngressPort
## Product-layer remote admission. Transport callbacks may call this adapter,
## but accepted peers still receive no gameplay mutation authority.

var _authenticator: ZSessionAuthenticatorPort
var _required_compatibility: ZProductCompatibilityManifest


func _init(
	authenticator: ZSessionAuthenticatorPort,
	required_compatibility: ZProductCompatibilityManifest
) -> void:
	_authenticator = authenticator
	_required_compatibility = (
		required_compatibility.snapshot()
		if required_compatibility != null
		else null
	)


func admit(request: ZSessionRequest) -> ZSessionAdmission:
	if request == null or not request.is_well_formed():
		return ZSessionAdmission.reject(
			request.request_id if request != null else null,
			&"malformed_session_request"
		)
	if request.mode != ZSessionRequest.Mode.REMOTE:
		return ZSessionAdmission.reject(request.request_id, &"authenticated_ingress_rejects_offline")
	if not request.is_well_formed_remote():
		return ZSessionAdmission.reject(request.request_id, &"malformed_remote_session_request")
	if _required_compatibility == null or not _required_compatibility.is_well_formed():
		return ZSessionAdmission.reject(request.request_id, &"server_compatibility_invalid")
	if _authenticator == null:
		return ZSessionAdmission.reject(request.request_id, &"session_authenticator_unavailable")

	var frozen_request := request.snapshot()
	if frozen_request == null or frozen_request.compatibility == null:
		return ZSessionAdmission.reject(request.request_id, &"session_request_snapshot_invalid")
	var compatibility_reason := frozen_request.compatibility.rejection_against(
		_required_compatibility
	)
	if not compatibility_reason.is_empty():
		frozen_request.credential = PackedByteArray()
		return ZSessionAdmission.reject(request.request_id, compatibility_reason)

	var authentication_request := frozen_request.snapshot()
	if authentication_request == null:
		frozen_request.credential = PackedByteArray()
		return ZSessionAdmission.reject(request.request_id, &"session_request_snapshot_invalid")
	var grant := _authenticator.authenticate(authentication_request)
	# Credentials never enter an admission, registry, replay record or profile.
	authentication_request.credential = PackedByteArray()
	frozen_request.credential = PackedByteArray()
	if grant == null:
		return ZSessionAdmission.reject(request.request_id, &"authentication_rejected")
	var frozen_grant := grant.snapshot()
	if frozen_grant == null:
		return ZSessionAdmission.reject(request.request_id, &"malformed_auth_grant")
	if (
		frozen_grant.profile_key != frozen_request.profile_key
		or frozen_grant.actor_slot != frozen_request.actor_slot
	):
		return ZSessionAdmission.reject(request.request_id, &"session_claim_mismatch")

	var epoch := "%08d" % frozen_request.requested_authority_epoch
	var session_id := ZSessionId.from_parts(PackedStringArray([
		"remote",
		String(frozen_grant.principal_key),
		String(frozen_request.client_instance),
		epoch,
	]))
	# Remote actors are stable across session replacement. The authority epoch
	# fences old sessions; it is not embedded into the actor identity.
	var actor_id := ZEntityId.from_parts(PackedStringArray([
		"remote",
		String(frozen_grant.profile_key),
		String(frozen_grant.actor_slot),
	]))
	var negotiation_digest := frozen_request.compatibility.negotiation_digest(
		_required_compatibility
	)
	if session_id == null or actor_id == null or negotiation_digest.is_empty():
		return ZSessionAdmission.reject(request.request_id, &"derived_identity_invalid")
	return ZSessionAdmission.accept_remote(
		frozen_request,
		session_id,
		actor_id,
		frozen_grant,
		negotiation_digest
	)
