extends RefCounted
## Loaded by the multiplayer session CI driver; not a shipped scene entrypoint.

class FakeAuthenticator:
	extends ZSessionAuthenticatorPort

	var expected_credential: PackedByteArray
	var grant: ZSessionAuthGrant

	func _init(
		p_expected_credential: PackedByteArray,
		p_grant: ZSessionAuthGrant
	) -> void:
		expected_credential = p_expected_credential.duplicate()
		grant = p_grant

	func authenticate(request: ZSessionRequest) -> ZSessionAuthGrant:
		if request == null or request.credential != expected_credential:
			return null
		return grant


var checks: int = 0
var failures: int = 0


func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("PRODUCT_SESSION_CONTRACT: " + message)


func run() -> Dictionary:
	var fingerprint := "a".repeat(64)
	var required := ZProductCompatibilityManifest.create(
		1,
		3,
		fingerprint,
		PackedStringArray(["raid_intent_v1", "authoritative_inventory"])
	)
	var offered := ZProductCompatibilityManifest.create(
		1,
		3,
		fingerprint,
		PackedStringArray([
			"cosmetic_prediction",
			"authoritative_inventory",
			"raid_intent_v1",
			"raid_intent_v1",
		])
	)
	check(required != null and offered != null, "valid compatibility manifests construct")
	check(
		offered.features == PackedStringArray([
			"authoritative_inventory",
			"cosmetic_prediction",
			"raid_intent_v1",
		]),
		"features are deduplicated and sorted"
	)
	check(offered.rejection_against(required).is_empty(), "compatible offer is accepted")
	check(not offered.negotiation_digest(required).is_empty(), "negotiation is digest-bound")
	check(
		ZProductCompatibilityManifest.create(1, 3, "A".repeat(64)) == null,
		"uppercase fingerprint is rejected"
	)
	check(
		ZProductCompatibilityManifest.create(
			1,
			3,
			fingerprint,
			PackedStringArray(["bad feature"])
		) == null,
		"invalid feature grammar is rejected"
	)
	var protocol_mismatch := ZProductCompatibilityManifest.create(2, 3, fingerprint)
	check(
		protocol_mismatch.rejection_against(required) == &"protocol_version_mismatch",
		"protocol mismatch has a typed reason"
	)
	var schema_mismatch := ZProductCompatibilityManifest.create(1, 4, fingerprint)
	check(
		schema_mismatch.rejection_against(required) == &"command_schema_version_mismatch",
		"command schema mismatch has a typed reason"
	)
	var content_mismatch := ZProductCompatibilityManifest.create(1, 3, "b".repeat(64))
	check(
		content_mismatch.rejection_against(required) == &"content_fingerprint_mismatch",
		"content mismatch has a typed reason"
	)
	var missing_feature := ZProductCompatibilityManifest.create(
		1,
		3,
		fingerprint,
		PackedStringArray(["authoritative_inventory"])
	)
	check(
		missing_feature.rejection_against(required) == &"missing_required_feature",
		"required feature omission is rejected"
	)

	var raid := ZRaidId.from_parts(PackedStringArray(["multiplayer", "session_contract"]))
	var credential := PackedByteArray([11, 29, 47, 83])
	var grant := ZSessionAuthGrant.create(&"steam_7656119", &"profile_a", &"player")
	var authenticator := FakeAuthenticator.new(credential, grant)
	var ingress := AuthenticatedSessionIngress.new(authenticator, required)
	var coordinator := SessionCoordinator.new(ingress)

	var default_remote := SessionCoordinator.new().open_remote(
		raid,
		&"profile_a",
		&"player",
		31,
		&"client_a",
		credential,
		offered
	)
	check(
		not default_remote.accepted and default_remote.reason == &"offline_ingress_rejects_remote",
		"default coordinator remains offline and cannot authenticate remote callers"
	)

	var local_request := ZSessionRequest.create_offline(
		ZRequestId.from_parts(PackedStringArray(["session", "local_probe", "00000001"])),
		raid,
		&"profile_local",
		&"player",
		1
	)
	var remote_only := ingress.admit(local_request)
	check(
		not remote_only.accepted
			and remote_only.reason == &"authenticated_ingress_rejects_offline",
		"authenticated ingress cannot silently promote an offline request"
	)
	local_request.transport_peer_id = 31
	var confused_local := OfflineSessionIngress.new().admit(local_request)
	check(
		not confused_local.accepted
			and confused_local.reason == &"offline_remote_metadata_forbidden",
		"offline ingress rejects transport metadata"
	)

	var bad_credential := coordinator.open_remote(
		raid,
		&"profile_a",
		&"player",
		31,
		&"client_bad_auth",
		PackedByteArray([1]),
		offered
	)
	check(
		not bad_credential.accepted and bad_credential.reason == &"authentication_rejected",
		"invalid credential fails closed"
	)
	var bad_peer := coordinator.open_remote(
		raid,
		&"profile_a",
		&"player",
		1,
		&"client_bad_peer",
		credential,
		offered
	)
	check(
		not bad_peer.accepted and bad_peer.reason == &"malformed_remote_session_request",
		"server peer identity cannot be presented as a remote client"
	)
	var incompatible := coordinator.open_remote(
		raid,
		&"profile_a",
		&"player",
		31,
		&"client_bad_content",
		credential,
		content_mismatch
	)
	check(
		not incompatible.accepted and incompatible.reason == &"content_fingerprint_mismatch",
		"incompatible content is rejected before admission"
	)

	var first := coordinator.open_remote(
		raid,
		&"profile_a",
		&"player",
		31,
		&"client_a",
		credential,
		offered
	)
	check(first.is_usable(), "authenticated compatible remote session is admitted")
	check(
		first.trust_level == ZSessionAdmission.TrustLevel.REMOTE_AUTHENTICATED,
		"remote trust is explicit"
	)
	check(
		first.session_id.canonical_key()
			== "zerkov.session.remote.steam_7656119.client_a.00000004",
		"remote session identity includes principal, client instance and authority epoch"
	)
	check(
		first.actor_id.canonical_key() == "zerkov.entity.remote.profile_a.player",
		"remote actor identity is stable across session replacement"
	)
	check(
		first.profile_key == &"profile_a"
			and first.actor_slot == &"player"
			and first.principal_key == &"steam_7656119"
			and first.transport_peer_id == 31,
		"authenticated ownership claims are retained without credentials"
	)
	check(
		ZProductCompatibilityManifest.is_sha256(first.compatibility_digest),
		"admission records a valid negotiation digest"
	)

	var direct_request := ZSessionRequest.create_remote(
		ZRequestId.from_parts(PackedStringArray(["session", "snapshot", "00000001"])),
		raid,
		&"profile_a",
		&"player",
		99,
		44,
		&"snapshot_client",
		credential,
		offered
	)
	var direct := ingress.admit(direct_request)
	check(direct.is_usable(), "direct ingress request is admitted")
	var direct_digest := direct.compatibility_digest
	direct_request.profile_key = &"forged_profile"
	direct_request.transport_peer_id = 77
	direct_request.compatibility.content_fingerprint = "c".repeat(64)
	check(
		direct.profile_key == &"profile_a"
			and direct.transport_peer_id == 44
			and direct.compatibility_digest == direct_digest
			and direct.compatibility_digest == offered.negotiation_digest(required),
		"admission snapshots request and compatibility state"
	)

	var direct_snapshot := direct.snapshot()
	direct.principal_key = &"forged"
	check(
		not direct.is_usable()
			and direct_snapshot != null
			and direct_snapshot.principal_key == &"steam_7656119",
		"remote admission identity fields cannot be mutated into a usable forgery"
	)

	var mismatched_grant := ZSessionAuthGrant.create(&"steam_other", &"profile_b", &"player")
	var mismatch_ingress := AuthenticatedSessionIngress.new(
		FakeAuthenticator.new(credential, mismatched_grant),
		required
	)
	var claim_mismatch := SessionCoordinator.new(mismatch_ingress).open_remote(
		raid,
		&"profile_a",
		&"player",
		55,
		&"claim_mismatch",
		credential,
		offered
	)
	check(
		not claim_mismatch.accepted and claim_mismatch.reason == &"session_claim_mismatch",
		"client profile claim must match authenticated grant"
	)

	var malformed_grant := ZSessionAuthGrant.new()
	malformed_grant.principal_key = &"Bad Principal"
	malformed_grant.profile_key = &"profile_a"
	malformed_grant.actor_slot = &"player"
	var malformed_grant_result := SessionCoordinator.new(
		AuthenticatedSessionIngress.new(
			FakeAuthenticator.new(credential, malformed_grant),
			required
		)
	).open_remote(
		raid,
		&"profile_a",
		&"player",
		56,
		&"malformed_grant",
		credential,
		offered
	)
	check(
		not malformed_grant_result.accepted
			and malformed_grant_result.reason == &"malformed_auth_grant",
		"malformed authenticator claims fail closed"
	)

	var other_raid := ZRaidId.from_parts(PackedStringArray(["multiplayer", "other_raid"]))
	var wrong_raid_registry := ZProductSessionRegistry.new(other_raid)
	check(
		not wrong_raid_registry.activate(first)
			and wrong_raid_registry.last_error == &"raid_mismatch",
		"session ownership registry is scoped to one raid"
	)
	var registry := ZProductSessionRegistry.new(raid)
	check(registry.activate(first), "first authenticated session activates")
	check(registry.active_session_count() == 1, "registry tracks one active session")
	check(
		registry.owns_actor(
			first.session_id,
			first.actor_id,
			first.transport_peer_id,
			first.authority_epoch
		),
		"session owns only its authenticated actor binding"
	)
	check(
		registry.next_command_sequence(first.session_id) == 1,
		"first expected command sequence is one"
	)
	check(
		registry.admit_command(
			first.session_id,
			first.actor_id,
			first.transport_peer_id,
			first.authority_epoch,
			1
		),
		"next contiguous command sequence is accepted"
	)
	check(
		not registry.admit_command(
			first.session_id,
			first.actor_id,
			first.transport_peer_id,
			first.authority_epoch,
			1
		) and registry.last_error == &"command_sequence_replayed",
		"duplicate command sequence is rejected"
	)
	check(
		not registry.admit_command(
			first.session_id,
			first.actor_id,
			first.transport_peer_id,
			first.authority_epoch,
			3
		) and registry.last_error == &"command_sequence_gap",
		"future sequence gap is rejected"
	)
	check(
		registry.next_command_sequence(first.session_id) == 2,
		"rejected replay and gap do not consume sequence"
	)
	var forged_actor := ZEntityId.from_parts(PackedStringArray([
		"remote",
		"profile_a",
		"forged",
	]))
	check(
		not registry.admit_command(
			first.session_id,
			forged_actor,
			first.transport_peer_id,
			first.authority_epoch,
			2
		) and registry.last_error == &"actor_not_owned",
		"forged actor cannot consume a command sequence"
	)
	check(
		not registry.admit_command(
			first.session_id,
			first.actor_id,
			99,
			first.authority_epoch,
			2
		) and registry.last_error == &"transport_peer_mismatch",
		"forged transport peer cannot consume a command sequence"
	)
	check(
		not registry.admit_command(
			first.session_id,
			first.actor_id,
			first.transport_peer_id,
			first.authority_epoch + 1,
			2
		) and registry.last_error == &"authority_epoch_mismatch",
		"forged authority epoch cannot consume a command sequence"
	)
	check(
		registry.admit_command(
			first.session_id,
			first.actor_id,
			first.transport_peer_id,
			first.authority_epoch,
			2
		),
		"correct command remains admissible after hostile attempts"
	)

	var second := coordinator.open_remote(
		raid,
		&"profile_a",
		&"player",
		32,
		&"client_b",
		credential,
		offered
	)
	check(second.is_usable() and second.authority_epoch > first.authority_epoch,
		"replacement session has a newer authority epoch")
	check(registry.activate(second), "newer session replaces the same authenticated actor")
	check(registry.active_session_count() == 1, "replacement is fail-atomic and bounded")
	check(
		not registry.admit_command(
			first.session_id,
			first.actor_id,
			first.transport_peer_id,
			first.authority_epoch,
			3
		) and registry.last_error == &"session_not_active",
		"replaced session cannot issue late commands"
	)
	check(
		registry.next_command_sequence(second.session_id) == 1,
		"replacement receives a fresh command sequence namespace"
	)

	check(
		not registry.activate(first)
			and registry.last_error == &"authority_epoch_not_newer",
		"older authority epoch cannot reclaim an active actor"
	)

	var other_principal_grant := ZSessionAuthGrant.create(&"steam_other", &"profile_a", &"player")
	var other_ingress := AuthenticatedSessionIngress.new(
		FakeAuthenticator.new(credential, other_principal_grant),
		required
	)
	var hostile_epoch := second.authority_epoch + 1
	var hostile_request := ZSessionRequest.create_remote(
		ZRequestId.from_parts(PackedStringArray([
			"session",
			"other_owner",
			"%08d" % hostile_epoch,
		])),
		raid,
		&"profile_a",
		&"player",
		hostile_epoch,
		60,
		&"other_owner",
		credential,
		offered
	)
	var hostile_owner := other_ingress.admit(hostile_request)
	check(hostile_owner.is_usable(), "different principal session is independently valid")
	check(
		not registry.activate(hostile_owner)
			and registry.last_error == &"actor_owned_by_another_principal",
		"a different authenticated principal cannot replace an owned actor"
	)
	var retained_owner := registry.admission_for_actor(second.actor_id)
	check(
		retained_owner != null and retained_owner.session_id.is_equal(second.session_id),
		"rejected ownership takeover preserves the current session"
	)

	check(registry.retire(second.session_id, second.authority_epoch), "current session retires")
	check(registry.active_session_count() == 0, "retire removes active bindings")
	check(
		not registry.activate(second) and registry.last_error == &"authority_epoch_retired",
		"retired epoch cannot be reactivated"
	)
	check(
		not registry.activate(hostile_owner)
			and registry.last_error == &"actor_owned_by_another_principal",
		"retired actor ownership remains pinned to its authenticated principal"
	)
	var third := coordinator.open_remote(
		raid,
		&"profile_a",
		&"player",
		33,
		&"client_c",
		credential,
		offered
	)
	check(registry.activate(third), "higher epoch can claim the retired actor")
	check(
		not registry.activate(
			SessionCoordinator.new().open_offline(raid, &"profile_local", &"player")
		) and registry.last_error == &"remote_admission_required",
		"local trust cannot be installed into the remote registry"
	)

	var authority := RaidAuthority.new()
	check(authority.configure(raid, third, 7283), "RaidAuthority accepts remote admission snapshot")
	var configured := authority.admission()
	third.authority_epoch = 999
	third.principal_key = &"forged"
	check(
		configured.authority_epoch != third.authority_epoch
			and configured.principal_key == &"steam_7656119",
		"RaidAuthority snapshots authenticated session metadata"
	)

	return {"checks": checks, "failures": failures}
