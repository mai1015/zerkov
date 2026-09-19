class_name OfflineSessionIngress
extends ZSessionIngressPort
## Trusted local adapter; it still uses the transport-neutral admission port.


func admit(request: ZSessionRequest) -> ZSessionAdmission:
	if request == null or not request.is_well_formed():
		return ZSessionAdmission.reject(
			request.request_id if request != null else null,
			&"malformed_session_request"
		)
	if request.mode != ZSessionRequest.Mode.OFFLINE:
		return ZSessionAdmission.reject(request.request_id, &"offline_ingress_rejects_remote")
	if not request.credential.is_empty():
		return ZSessionAdmission.reject(request.request_id, &"offline_credential_forbidden")
	if (
		request.transport_peer_id != 0
		or not request.client_instance.is_empty()
		or request.compatibility != null
	):
		return ZSessionAdmission.reject(request.request_id, &"offline_remote_metadata_forbidden")

	var epoch := "%08d" % request.requested_authority_epoch
	var profile := String(request.profile_key)
	var slot := String(request.actor_slot)
	var session_id := ZSessionId.from_parts(PackedStringArray(["offline", profile, epoch]))
	var actor_id := ZEntityId.from_parts(PackedStringArray(["offline", profile, slot, epoch]))
	if session_id == null or actor_id == null:
		return ZSessionAdmission.reject(request.request_id, &"derived_identity_invalid")
	return ZSessionAdmission.accept_local(request, session_id, actor_id)
