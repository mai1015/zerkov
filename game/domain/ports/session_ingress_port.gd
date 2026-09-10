class_name ZSessionIngressPort
extends RefCounted
## Replaceable admission seam used by both offline and future network sessions.


func admit(request: ZSessionRequest) -> ZSessionAdmission:
	return ZSessionAdmission.reject(
		request.request_id if request != null else null,
		&"session_ingress_not_implemented"
	)
