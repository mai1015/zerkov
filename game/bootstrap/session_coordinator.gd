class_name SessionCoordinator
extends RefCounted
## Owns monotonic authority epochs and delegates all admission to one port.

var _ingress: ZSessionIngressPort
var _next_authority_epoch: int = 1


func _init(ingress: ZSessionIngressPort = null) -> void:
	_ingress = ingress if ingress != null else OfflineSessionIngress.new()


func open_offline(
	raid_id: ZRaidId,
	profile_key: StringName,
	actor_slot: StringName = &"player"
) -> ZSessionAdmission:
	var epoch := _next_authority_epoch
	_next_authority_epoch += 1
	var request_id := ZRequestId.from_parts(PackedStringArray([
		"session",
		String(profile_key) if not profile_key.is_empty() else "invalid",
		"%08d" % epoch,
	]))
	var request := ZSessionRequest.create_offline(
		request_id,
		raid_id,
		profile_key,
		actor_slot,
		epoch
	)
	return _ingress.admit(request)


func next_authority_epoch() -> int:
	return _next_authority_epoch
