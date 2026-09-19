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
	var epoch := _claim_authority_epoch()
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


func open_remote(
	raid_id: ZRaidId,
	profile_key: StringName,
	actor_slot: StringName,
	transport_peer_id: int,
	client_instance: StringName,
	credential: PackedByteArray,
	compatibility: ZProductCompatibilityManifest
) -> ZSessionAdmission:
	var epoch := _claim_authority_epoch()
	var profile_part := (
		String(profile_key)
		if ZIdentityRules.is_valid_part(String(profile_key))
		else "invalid"
	)
	var instance_part := (
		String(client_instance)
		if ZIdentityRules.is_valid_part(String(client_instance))
		else "invalid"
	)
	var request_id := ZRequestId.from_parts(PackedStringArray([
		"session",
		"remote",
		profile_part,
		instance_part,
		"%08d" % epoch,
	]))
	var request := ZSessionRequest.create_remote(
		request_id,
		raid_id,
		profile_key,
		actor_slot,
		epoch,
		transport_peer_id,
		client_instance,
		credential,
		compatibility
	)
	return _ingress.admit(request)


func next_authority_epoch() -> int:
	return _next_authority_epoch


func _claim_authority_epoch() -> int:
	var epoch := _next_authority_epoch
	_next_authority_epoch += 1
	return epoch
