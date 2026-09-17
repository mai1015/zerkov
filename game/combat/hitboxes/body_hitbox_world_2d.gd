class_name BodyHitboxWorld2D
extends RefCounted
## Bounded deterministic owner for authoritative 2D body-hit geometry.
##
## A movement/world owner publishes one complete integer snapshot per raid
## tick. Firearm/melee adapters may ask this boundary for spatial facts, but
## neither Weapon System nor Gameplay Abilities participates in hit selection.

enum Lifecycle {
	UNBOUND,
	BOUND,
	RELEASED,
}

class BindingCapability:
	extends RefCounted

	# The lease material exists only in the object returned by bind. The world
	# retains a one-way commitment, never this byte sequence or this object.
	var _lease_secret: PackedByteArray = PackedByteArray()


	func _init(secret: PackedByteArray = PackedByteArray()) -> void:
		_lease_secret = secret.duplicate()


	func _revoke() -> void:
		# Best-effort local erasure complements synchronous world-side revocation.
		for index in _lease_secret.size():
			_lease_secret[index] = 0
		_lease_secret = PackedByteArray()


const BINDING_SCHEMA: String = "zerkov.combat.body_hitbox_binding.v2"
const SNAPSHOT_SCHEMA: String = "zerkov.combat.body_hitbox_snapshot.v2"
const RAY_QUERY_SCHEMA: String = "zerkov.combat.body_hitbox_ray_query.v2"
const BINDING_COMMITMENT_SCHEMA: String = \
	"zerkov.combat.body_hitbox_binding_commitment.v1"
const BINDING_LEASE_BYTES: int = 32

# Cross products in exact ray-fraction comparison remain below int64 max:
# (2 * 1_500_000_000)^2 = 9_000_000_000_000_000_000.
const MAX_COORDINATE_RAW: int = 1_500_000_000
const MAX_COLLISION_MASK: int = 0x7fff_ffff
const MAX_BODIES: int = 64
const MAX_OBSTRUCTIONS: int = 256
const MAX_BODY_HISTORY: int = 256
const MAX_OBSTRUCTION_HISTORY: int = 1024
const MAX_EXCLUDED_ENTITIES: int = 16
const MAX_QUERY_RESULTS: int = 4096
const MAX_PHASE_CONSUMERS: int = 16
const MAX_BINDING_TOKEN: int = 2_147_483_647

const BODY_RECORD_KEYS: PackedStringArray = [
	"entity_id",
	"actor_source",
	"profile_id",
	"body_revision",
	"origin_raw",
	"facing_quarter_turns",
	"collision_layer",
	"targetable",
]
const OBSTRUCTION_RECORD_KEYS: PackedStringArray = [
	"obstruction_id",
	"geometry_revision",
	"min_raw",
	"max_raw",
	"collision_layer",
	"enabled",
]
const RAY_QUERY_KEYS: PackedStringArray = [
	"request_id",
	"raid_id",
	"session_id",
	"authority_epoch",
	"authority_generation",
	"binding_token",
	"owner_actor_id",
	"owner_actor_source",
	"query_actor_id",
	"query_actor_source",
	"tick",
	"world_revision",
	"origin_raw",
	"target_raw",
	"body_mask",
	"obstruction_mask",
	"excluded_entity_ids",
]

var lifecycle: Lifecycle = Lifecycle.UNBOUND
var last_error: StringName = &""
var last_publication_duplicate: bool = false
var last_query_duplicate: bool = false

var _authority: RaidAuthority
var _authority_instance_id: int = 0
var _authority_generation: int = 0
var _raid_id: ZRaidId
var _session_id: ZSessionId
var _authority_epoch: int = 0
var _owner_actor_id: ZEntityId
var _owner_actor_source: ZRaidIntent.Source = ZRaidIntent.Source.PLAYER
var _binding_counter: int = 0
var _active_binding_token: int = 0
# This digest is not a bearer: it is a one-way verifier over a random lease,
# the candidate object's runtime identity and the exact binding context. It is
# intentionally absent from every published/canonical/replay record.
var _active_binding_commitment: PackedByteArray = PackedByteArray()
var _binding_provenance: Dictionary = {}
var _delegated_only: bool = false

var _snapshot_tick: int = -1
var _snapshot_revision: int = 0
var _snapshot_digest: String = ""
var _bodies_by_id: Dictionary = {}
var _obstructions_by_id: Dictionary = {}
var _body_history: Dictionary = {}
var _obstruction_history: Dictionary = {}
var _query_ledger: Dictionary = {}
var _phase_consumers: Dictionary = {}


## Binding is allowed only while RaidAuthority is preparing. Numeric tokens
## remain useful deterministic provenance, but authorization is carried by a
## fresh exact-object capability. A capability from another or prior world can
## never authenticate even when all public IDs and counters collide.
func bind_raid_authority(
	authority: RaidAuthority,
	owner_actor_value: Variant,
	owner_source_value: Variant,
	expected_generation: int
) -> BindingCapability:
	last_error = &""
	if lifecycle == Lifecycle.BOUND:
		return _reject_capability(&"hitbox_world_already_bound")
	if authority == null or not is_instance_valid(authority):
		return _reject_capability(&"raid_authority_invalid")
	if expected_generation <= 0 or authority.generation() != expected_generation:
		return _reject_capability(&"authority_generation_mismatch")
	if authority.lifecycle != RaidAuthority.Lifecycle.PREPARING:
		return _reject_capability(&"authority_binding_closed")
	var raid := authority.raid_id()
	var admission := authority.admission()
	if raid == null or not raid.is_initialized() or admission == null \
			or not admission.is_usable() or not admission.raid_id.is_equal(raid):
		return _reject_capability(&"authority_identity_invalid")
	var profile_report := ZerkovBodyHitboxProfile.validate()
	if not bool(profile_report.get("ok", false)):
		return _reject_capability(&"body_hitbox_profile_invalid")
	var owner := _validated_actor_source(
		owner_actor_value, owner_source_value, &"binding_owner")
	if owner.is_empty():
		return null
	var owner_actor := owner["actor_id"] as ZEntityId
	var owner_source: ZRaidIntent.Source = int(owner["actor_source"])
	if not authority.has_authorized_actor_source(
		owner_actor, owner_source, expected_generation):
		return _reject_capability(&"binding_owner_not_authorized")
	if not authority.require_named_phase_handlers(expected_generation):
		last_error = authority.last_error
		return null
	if _binding_counter >= MAX_BINDING_TOKEN:
		return _reject_capability(&"binding_token_exhausted")
	var next_token := _binding_counter + 1
	var lease_secret := Crypto.new().generate_random_bytes(BINDING_LEASE_BYTES)
	if not _binding_lease_secret_is_valid(lease_secret):
		return _reject_capability(&"binding_capability_generation_failed")
	var capability := BindingCapability.new(lease_secret)
	var commitment := _binding_capability_commitment(
		capability, lease_secret, authority.get_instance_id(),
		expected_generation, next_token)
	# The local copy is no longer needed after capability construction. Clearing
	# it before canonical mutation prevents a partial bind from retaining raw
	# lease material in the world stack/state on a failed hash operation.
	for index in lease_secret.size():
		lease_secret[index] = 0
	lease_secret = PackedByteArray()
	if commitment.size() != BINDING_LEASE_BYTES:
		capability._revoke()
		return _reject_capability(&"binding_capability_generation_failed")

	_clear_snapshot_state()
	_binding_counter = next_token
	_active_binding_token = _binding_counter
	_authority = authority
	_authority_instance_id = authority.get_instance_id()
	_authority_generation = expected_generation
	_raid_id = ZRaidId.parse(raid.canonical_key())
	_session_id = ZSessionId.parse(admission.session_id.canonical_key())
	_authority_epoch = admission.authority_epoch
	_owner_actor_id = ZEntityId.parse(owner_actor.canonical_key())
	_owner_actor_source = owner_source
	_active_binding_commitment = commitment.duplicate()
	_binding_provenance = {
		"schema": BINDING_SCHEMA,
		"raid_id": _raid_id.canonical_key(),
		"session_id": _session_id.canonical_key(),
		"authority_epoch": _authority_epoch,
		"authority_generation": _authority_generation,
		"binding_token": _active_binding_token,
		"owner_actor_id": _owner_actor_id.canonical_key(),
		"owner_actor_source": int(_owner_actor_source),
		"world_instance_id": get_instance_id(),
		"authority_instance_id": _authority_instance_id,
	}
	_make_deep_read_only(_binding_provenance)
	lifecycle = Lifecycle.BOUND
	return capability


func binding_provenance(capability: Variant) -> Dictionary:
	last_error = &""
	if not _guard_binding_capability(capability) or not _binding_identity_is_current():
		if last_error.is_empty():
			last_error = &"binding_generation_invalidated"
		return _read_only_dictionary({})
	return _read_only_dictionary(_binding_provenance)


## Finalizes composition after all narrow phase grants are installed. The raw
## Task 5.3 bearer is synchronously revoked and can never authorize again,
## including when recovered from a closure or Dictionary key.
func seal_phase_grants(capability: Variant) -> bool:
	last_error = &""
	if not _guard_binding_capability(capability) or not _binding_identity_is_current():
		return false
	var has_raycast_consumer := false
	for grant_value in _phase_consumers.values():
		var grant := grant_value as Dictionary
		if StringName(grant.get("permission", &"")) == &"raycast":
			has_raycast_consumer = true
			break
	if not has_raycast_consumer:
		return _reject_bool(&"phase_raycast_consumer_missing")
	_active_binding_commitment = PackedByteArray()
	(capability as BindingCapability)._revoke()
	_delegated_only = true
	return true


func release_delegated_binding(
	reason: StringName = &"body_hitbox_world_delegated_released"
) -> bool:
	last_error = &""
	if lifecycle != Lifecycle.BOUND or not _delegated_only:
		return _reject_bool(&"delegated_binding_not_active")
	if reason.is_empty() or not ZIdentityRules.is_valid_part(String(reason)):
		return _reject_bool(&"release_reason_invalid")
	if _authority != null and is_instance_valid(_authority) \
			and _authority.lifecycle not in [
				RaidAuthority.Lifecycle.COMPLETED,
				RaidAuthority.Lifecycle.FAILED,
				RaidAuthority.Lifecycle.TORN_DOWN,
			]:
		return _reject_bool(&"delegated_binding_authority_active")
	_clear_snapshot_state()
	_authority = null
	_authority_instance_id = 0
	_authority_generation = 0
	_raid_id = null
	_session_id = null
	_authority_epoch = 0
	_owner_actor_id = null
	_owner_actor_source = ZRaidIntent.Source.PLAYER
	_active_binding_token = 0
	_binding_provenance = {}
	_delegated_only = false
	lifecycle = Lifecycle.RELEASED
	return true


## Release remains available after the captured authority terminalizes. It
## requires the exact binding capability, invalidates it synchronously before
## clearing geometry/replay state, and permits a safe replacement bind.
func release_binding(
	capability: Variant,
	reason: StringName = &"body_hitbox_world_released"
) -> bool:
	last_error = &""
	if lifecycle != Lifecycle.BOUND:
		return _reject_bool(&"hitbox_world_not_bound")
	if not _guard_binding_capability(capability):
		return false
	if reason.is_empty() or not ZIdentityRules.is_valid_part(String(reason)):
		return _reject_bool(&"release_reason_invalid")
	# Revoke authorization before any other lifecycle state changes. No retained
	# world reference can recover the capability object or reuse this digest.
	_active_binding_commitment = PackedByteArray()
	(capability as BindingCapability)._revoke()
	_clear_snapshot_state()
	_authority = null
	_authority_instance_id = 0
	_authority_generation = 0
	_raid_id = null
	_session_id = null
	_authority_epoch = 0
	_owner_actor_id = null
	_owner_actor_source = ZRaidIntent.Source.PLAYER
	_active_binding_token = 0
	_binding_provenance = {}
	_delegated_only = false
	lifecycle = Lifecycle.RELEASED
	return true


func teardown(capability: Variant) -> bool:
	return release_binding(capability, &"body_hitbox_world_torn_down")


## Geometry-free metadata is safe to expose to audit/replay code. Actor poses
## and obstruction coordinates remain inside this owned query boundary.
func snapshot_metadata(capability: Variant) -> Dictionary:
	last_error = &""
	if not _guard_binding_capability(capability) or not _binding_identity_is_current():
		if last_error.is_empty():
			last_error = &"binding_generation_invalidated"
		return _read_only_dictionary({})
	return _snapshot_metadata_record()


## Converts a raw binding capability into a narrow phase-registration grant.
## The raw bearer is authenticated here and never retained. The resulting
## grant can only inspect metadata in phase 5 and raycast in the exact phase-6
## dispatch registered with RaidAuthority.
func authorize_phase_consumer(
	capability: Variant,
	handler_id: StringName,
	registration_id: String,
	callback: Callable
) -> bool:
	last_error = &""
	if not _guard_binding_capability(capability) or not _binding_identity_is_current():
		return false
	if _authority.lifecycle != RaidAuthority.Lifecycle.PREPARING \
			or not ZIdentityRules.is_valid_part(String(handler_id)) \
			or registration_id.is_empty() or not callback.is_valid():
		return _reject_bool(&"phase_consumer_invalid")
	if not _authority.has_exact_phase_handler(
		handler_id, registration_id, callback,
		RaidAuthority.TickPhase.WORLD_CONSEQUENCES, _authority_generation):
		return _reject_bool(&"phase_consumer_registration_invalid")
	if _phase_consumers.has(registration_id):
		var prior := _phase_consumers[registration_id] as Dictionary
		return StringName(prior.get("handler_id", &"")) == handler_id
	for grant_value in _phase_consumers.values():
		var grant := grant_value as Dictionary
		if StringName(grant.get("permission", &"")) == &"raycast":
			return _reject_bool(&"phase_raycast_consumer_already_authorized")
	if _phase_consumers.size() >= MAX_PHASE_CONSUMERS:
		return _reject_bool(&"phase_consumer_capacity_exceeded")
	_phase_consumers[registration_id] = {
		"handler_id": handler_id,
		"binding_token": _active_binding_token,
		"phase": int(RaidAuthority.TickPhase.WORLD_CONSEQUENCES),
		"permission": &"raycast",
	}
	return true


## A distinct narrow grant for the game's melee executor. It cannot claim the
## firearm slot or use raycast APIs. Install before seal_phase_grants().
func authorize_melee_consumer(capability: Variant, handler_id: StringName,
	registration_id: String, callback: Callable) -> bool:
	if not _guard_binding_capability(capability) or not _binding_identity_is_current():
		return false
	var owner: Object = callback.get_object()
	if _authority.lifecycle != RaidAuthority.Lifecycle.PREPARING \
		or owner == null or owner.get_script() != load("res://game/combat/execution/raid_combat_execution.gd") \
		or handler_id != &"combat_melee_contacts" or callback.get_method() != &"_contacts" \
		or callback.get_bound_arguments_count() != 0 \
		or not _authority.has_exact_phase_handler(handler_id, registration_id, callback,
			RaidAuthority.TickPhase.WORLD_CONSEQUENCES, _authority_generation):
		return _reject_bool(&"melee_consumer_invalid")
	for entry: Dictionary in _phase_consumers.values():
		if entry.permission == &"melee":
			return _reject_bool(&"melee_consumer_already_authorized")
	if _phase_consumers.size() >= MAX_PHASE_CONSUMERS or _phase_consumers.has(registration_id):
		return _reject_bool(&"phase_consumer_capacity_exceeded")
	_phase_consumers[registration_id] = {"handler_id": handler_id,
		"binding_token": _active_binding_token,
		"phase": int(RaidAuthority.TickPhase.WORLD_CONSEQUENCES), "permission": &"melee"}
	return true

func melee_snapshot_metadata(handler_id: StringName, registration_id: String,
	callback: Callable, tick: int) -> Dictionary:
	if not _guard_exact_phase_grant(handler_id, registration_id, callback, tick,
		RaidAuthority.TickPhase.WORLD_CONSEQUENCES, &"melee"):
		return _read_only_dictionary({})
	return _read_only_dictionary(_snapshot_metadata_record())

## Sweep an axis-aligned square along the centerline, not a circular capsule.
## Both bodies AND walls are expanded. Exact rational earliest-contact ordering
## and obstruction-before-body ties are shared with firearm queries.
func phase_melee_sweep(query: Dictionary, radius_raw: int, handler_id: StringName,
	registration_id: String, callback: Callable) -> Dictionary:
	if not _guard_exact_phase_grant(handler_id, registration_id, callback,
		int(query.get("tick", -1)), RaidAuthority.TickPhase.WORLD_CONSEQUENCES, &"melee"):
		return _rejection(last_error)
	if radius_raw < 1 or radius_raw > 1_000_000:
		return _rejection(&"melee_radius_invalid")
	return _raycast_after_binding(query, null, radius_raw)


func authorize_phase_publisher(
	capability: Variant,
	handler_id: StringName,
	registration_id: String,
	callback: Callable
) -> bool:
	last_error = &""
	if not _guard_binding_capability(capability) or not _binding_identity_is_current():
		return false
	if _authority.lifecycle != RaidAuthority.Lifecycle.PREPARING \
			or not ZIdentityRules.is_valid_part(String(handler_id)) \
			or registration_id.is_empty() or not callback.is_valid():
		return _reject_bool(&"phase_publisher_invalid")
	if not _authority.has_exact_phase_handler(
		handler_id, registration_id, callback,
		RaidAuthority.TickPhase.MOVEMENT, _authority_generation):
		return _reject_bool(&"phase_publisher_registration_invalid")
	if _phase_consumers.has(registration_id):
		return _reject_bool(&"phase_consumer_registration_duplicate")
	if _phase_consumers.size() >= MAX_PHASE_CONSUMERS:
		return _reject_bool(&"phase_consumer_capacity_exceeded")
	_phase_consumers[registration_id] = {
		"handler_id": handler_id,
		"binding_token": _active_binding_token,
		"phase": int(RaidAuthority.TickPhase.MOVEMENT),
		"permission": &"publish",
	}
	return true


func revoke_phase_consumer(
	handler_id: StringName,
	registration_id: String
) -> bool:
	last_error = &""
	var consumer := _phase_consumers.get(registration_id, {}) as Dictionary
	if consumer.is_empty():
		return true
	if StringName(consumer.get("handler_id", &"")) != handler_id:
		return _reject_bool(&"phase_consumer_invalid")
	# A live exact registration cannot be stripped out from underneath a bound
	# adapter. Composition unregisters it first; hostile removal only fails shut.
	if _authority != null and is_instance_valid(_authority) \
			and _authority.phase_handler_registration_id(
				handler_id, _authority_generation) == registration_id:
		return _reject_bool(&"phase_consumer_registration_active")
	_phase_consumers.erase(registration_id)
	return true


func phase_consumer_snapshot_metadata(
	handler_id: StringName,
	registration_id: String,
	callback: Callable,
	tick: int
) -> Dictionary:
	last_error = &""
	if not _guard_phase_consumer(
		handler_id, registration_id, callback, tick, false):
		return _read_only_dictionary({})
	return _snapshot_metadata_record()


func phase_consumer_can_admit_request(
	request_id: String,
	handler_id: StringName,
	registration_id: String,
	callback: Callable,
	tick: int
) -> bool:
	last_error = &""
	if not _guard_phase_consumer(
		handler_id, registration_id, callback, tick, false):
		return false
	if ZRequestId.parse(request_id) == null:
		return _reject_bool(&"request_id_invalid")
	if _query_ledger.has(request_id):
		return _reject_bool(&"request_id_already_resolved")
	if _query_ledger.size() >= MAX_QUERY_RESULTS:
		return _reject_bool(&"query_result_capacity_exceeded")
	if _snapshot_tick != tick or _snapshot_revision <= 0 \
			or _snapshot_digest.is_empty():
		return _reject_bool(&"world_snapshot_missing_or_stale")
	return true


func _snapshot_metadata_record() -> Dictionary:
	return _read_only_dictionary({
		"schema": SNAPSHOT_SCHEMA,
		"raid_id": _raid_id.canonical_key() if _raid_id != null else "",
		"session_id": _session_id.canonical_key() if _session_id != null else "",
		"authority_epoch": _authority_epoch,
		"authority_generation": _authority_generation,
		"binding_token": _active_binding_token,
		"owner_actor_id": _owner_actor_id.canonical_key()
			if _owner_actor_id != null else "",
		"owner_actor_source": int(_owner_actor_source),
		"binding_provenance": _binding_provenance,
		"tick": _snapshot_tick,
		"world_revision": _snapshot_revision,
		"snapshot_digest": _snapshot_digest,
		"profile_digest": ZerkovBodyHitboxProfile.declaration_digest(),
		"body_count": _bodies_by_id.size(),
		"obstruction_count": _obstructions_by_id.size(),
		"query_result_count": _query_ledger.size(),
	})


func phase_consumer_raycast(
	query_value: Variant,
	handler_id: StringName,
	registration_id: String,
	callback: Callable
) -> Dictionary:
	last_error = &""
	last_query_duplicate = false
	var tick := int((query_value as Dictionary).get("tick", -1)) \
		if typeof(query_value) == TYPE_DICTIONARY else -1
	if not _guard_phase_consumer(
		handler_id, registration_id, callback, tick, true):
		return _rejection(last_error)
	return _raycast_after_binding(query_value)


## Replaces the entire spatial snapshot fail-atomically. Input order does not
## affect storage, digest, or query order. Repeating the identical tick/revision
## is an idempotent no-op; an equal-revision divergence fails closed.
func publish_snapshot(
	tick: int,
	world_revision: int,
	bodies_value: Variant,
	obstructions_value: Variant,
	expected_authority_generation: int,
	expected_binding_token: int,
	publisher_actor_value: Variant,
	publisher_source_value: Variant,
	capability: Variant
) -> bool:
	last_error = &""
	last_publication_duplicate = false
	if not _guard_binding(
		capability, expected_authority_generation, expected_binding_token):
		return false
	return _publish_snapshot_after_binding(
		tick, world_revision, bodies_value, obstructions_value,
		publisher_actor_value, publisher_source_value)


func phase_publisher_publish_snapshot(
	tick: int,
	world_revision: int,
	bodies_value: Variant,
	obstructions_value: Variant,
	publisher_actor_value: Variant,
	publisher_source_value: Variant,
	handler_id: StringName,
	registration_id: String,
	callback: Callable
) -> bool:
	last_error = &""
	last_publication_duplicate = false
	if not _guard_exact_phase_grant(
		handler_id, registration_id, callback, tick,
		RaidAuthority.TickPhase.MOVEMENT, &"publish"):
		return false
	return _publish_snapshot_after_binding(
		tick, world_revision, bodies_value, obstructions_value,
		publisher_actor_value, publisher_source_value)


## Advances only the authoritative tick envelope when the exact production
## publisher proves that no body or obstruction record changed. Geometry,
## revision history and the canonical snapshot digest remain immutable; phase
## consumers still require the refreshed current tick before querying.
func phase_publisher_refresh_snapshot(
	tick: int,
	world_revision: int,
	publisher_actor_value: Variant,
	publisher_source_value: Variant,
	handler_id: StringName,
	registration_id: String,
	callback: Callable
) -> bool:
	last_error = &""
	last_publication_duplicate = false
	if not _guard_exact_phase_grant(
		handler_id, registration_id, callback, tick,
		RaidAuthority.TickPhase.MOVEMENT, &"publish"):
		return false
	if not _guard_publisher(publisher_actor_value, publisher_source_value):
		return false
	if not _authority_allows_publication():
		return _reject_bool(&"authority_not_accepting_world_snapshot")
	if tick < 0 or tick != _authority.clock.current_tick:
		return _reject_bool(&"snapshot_tick_not_current")
	if _snapshot_revision <= 0 or _snapshot_digest.is_empty() \
			or _bodies_by_id.is_empty():
		return _reject_bool(&"world_snapshot_missing")
	if world_revision != _snapshot_revision:
		return _reject_bool(&"world_revision_mismatch")
	if tick == _snapshot_tick:
		last_publication_duplicate = true
		return true
	if tick != _snapshot_tick + 1:
		return _reject_bool(&"snapshot_tick_regressed_or_skipped")
	_snapshot_tick = tick
	last_publication_duplicate = true
	return true


func _publish_snapshot_after_binding(
	tick: int,
	world_revision: int,
	bodies_value: Variant,
	obstructions_value: Variant,
	publisher_actor_value: Variant,
	publisher_source_value: Variant
) -> bool:
	if not _guard_publisher(publisher_actor_value, publisher_source_value):
		return false
	if not _authority_allows_publication():
		return _reject_bool(&"authority_not_accepting_world_snapshot")
	if tick < 0 or tick != _authority.clock.current_tick:
		return _reject_bool(&"snapshot_tick_not_current")
	if typeof(bodies_value) != TYPE_ARRAY or typeof(obstructions_value) != TYPE_ARRAY:
		return _reject_bool(&"snapshot_collection_type_invalid")
	if world_revision <= 0:
		return _reject_bool(&"snapshot_revision_invalid")
	if _snapshot_revision == 0:
		if world_revision != 1:
			return _reject_bool(&"snapshot_revision_skipped")
	elif world_revision != _snapshot_revision \
			and world_revision != _snapshot_revision + 1:
		return _reject_bool(&"snapshot_revision_regressed_or_skipped")
	if _snapshot_revision > 0 and world_revision == _snapshot_revision \
			and tick != _snapshot_tick:
		return _reject_bool(&"snapshot_revision_tick_mismatch")
	if _snapshot_revision > 0 and world_revision == _snapshot_revision + 1 \
			and tick != _snapshot_tick + 1:
		return _reject_bool(&"snapshot_tick_regressed_or_skipped")

	var build := _build_snapshot(bodies_value as Array, obstructions_value as Array)
	if not bool(build.get("ok", false)):
		return false
	var next_digest := String(build.get("digest", ""))
	if next_digest.is_empty():
		return _reject_bool(&"snapshot_digest_invalid")
	if world_revision == _snapshot_revision:
		if next_digest != _snapshot_digest:
			return _reject_bool(&"equal_snapshot_revision_divergence")
		last_publication_duplicate = true
		return true

	_bodies_by_id = build["bodies"] as Dictionary
	_obstructions_by_id = build["obstructions"] as Dictionary
	_body_history = build["body_history"] as Dictionary
	_obstruction_history = build["obstruction_history"] as Dictionary
	_snapshot_tick = tick
	_snapshot_revision = world_revision
	_snapshot_digest = next_digest
	return true


## Returns one authoritative body hit, one blocking obstruction, or a miss.
## Entry distances are exact rational ray fractions; floats and physics-engine
## enumeration order are never used to choose the winner.
func raycast(query_value: Variant, capability: Variant) -> Dictionary:
	last_error = &""
	last_query_duplicate = false
	if not _guard_binding_capability(capability):
		return _rejection(last_error)
	if not _binding_identity_is_current():
		return _rejection(&"binding_generation_invalidated")
	return _raycast_after_binding(query_value, capability)


func _raycast_after_binding(
	query_value: Variant,
	capability: Variant = null,
	sweep_radius_raw: int = 0
) -> Dictionary:
	var normalized := _normalize_ray_query(query_value)
	if not bool(normalized.get("ok", false)):
		return _rejection(last_error)
	var query := normalized["record"] as Dictionary
	var request_key := String(query["request_id"])
	if capability != null:
		if not _guard_binding(
			capability, int(query["authority_generation"]), int(query["binding_token"])):
			return _rejection(last_error, request_key)
	elif int(query["authority_generation"]) != _authority_generation \
			or int(query["binding_token"]) != _active_binding_token:
		return _rejection(&"binding_context_mismatch", request_key)
	if not _authority_allows_query():
		return _rejection(&"authority_not_accepting_world_query", request_key)

	var fingerprint := String(normalized["fingerprint"])
	if sweep_radius_raw > 0:
		fingerprint = (fingerprint + ":swept_aabb_v1:" + str(sweep_radius_raw)).sha256_text()
	if _query_ledger.has(request_key):
		var previous := _query_ledger[request_key] as Dictionary
		if String(previous.get("fingerprint", "")) != fingerprint:
			return _rejection(&"request_id_reused_with_different_query", request_key)
		last_query_duplicate = true
		var replay := (previous["result"] as Dictionary).duplicate(true)
		replay["duplicate"] = true
		return _read_only_dictionary(replay)
	if int(query["world_revision"]) != _snapshot_revision:
		return _rejection(&"world_revision_mismatch", request_key)
	if int(query["tick"]) != _snapshot_tick \
			or int(query["tick"]) != _authority.clock.current_tick:
		return _rejection(&"query_tick_mismatch", request_key)
	if _snapshot_revision <= 0 or _snapshot_digest.is_empty():
		return _rejection(&"world_snapshot_missing", request_key)
	if _query_ledger.size() >= MAX_QUERY_RESULTS:
		return _rejection(&"query_result_capacity_exceeded", request_key)

	var selected: Dictionary = {}
	var candidate_count := 0
	var origin := query["origin_raw"] as Vector2i
	var target := query["target_raw"] as Vector2i
	var obstruction_mask := int(query["obstruction_mask"])
	if obstruction_mask != 0:
		var obstruction_ids := PackedStringArray(_obstructions_by_id.keys())
		obstruction_ids.sort()
		for obstruction_id in obstruction_ids:
			var obstruction := _obstructions_by_id[obstruction_id] as Dictionary
			if not bool(obstruction["enabled"]) \
					or (int(obstruction["collision_layer"]) & obstruction_mask) == 0:
				continue
			var fraction := _ray_aabb_fraction(
				origin, target,
				_sweep_bound(obstruction["min_raw"], -sweep_radius_raw),
				_sweep_bound(obstruction["max_raw"], sweep_radius_raw))
			if fraction.is_empty():
				continue
			candidate_count += 1
			var candidate := {
				"candidate_kind": 0,
				"obstruction_id": String(obstruction_id),
				"fraction_numerator": int(fraction["numerator"]),
				"fraction_denominator": int(fraction["denominator"]),
			}
			if selected.is_empty() or _candidate_precedes(candidate, selected):
				selected = candidate

	var excluded: Dictionary = normalized["excluded"] as Dictionary
	var body_mask := int(query["body_mask"])
	if body_mask != 0:
		var entity_ids := PackedStringArray(_bodies_by_id.keys())
		entity_ids.sort()
		for entity_id in entity_ids:
			if excluded.has(entity_id):
				continue
			var body := _bodies_by_id[entity_id] as Dictionary
			if not bool(body["targetable"]) \
					or (int(body["collision_layer"]) & body_mask) == 0:
				continue
			for hitbox_value in body["hitboxes"] as Array:
				var hitbox := hitbox_value as Dictionary
				var fraction := _ray_aabb_fraction(
					origin, target,
					_sweep_bound(hitbox["min_raw"], -sweep_radius_raw),
					_sweep_bound(hitbox["max_raw"], sweep_radius_raw))
				if fraction.is_empty():
					continue
				candidate_count += 1
				var candidate := {
					"candidate_kind": 1,
					"entity_id": String(entity_id),
					"body_revision": int(body["body_revision"]),
					"profile_id": String(body["profile_id"]),
					"hitbox_id": String(hitbox["hitbox_id"]),
					"body_zone": String(hitbox["body_zone"]),
					"anatomy_group": String(hitbox["anatomy_group"]),
					"zone_priority": int(hitbox["priority"]),
					"fraction_numerator": int(fraction["numerator"]),
					"fraction_denominator": int(fraction["denominator"]),
				}
				if selected.is_empty() or _candidate_precedes(candidate, selected):
					selected = candidate

	var result := _build_query_result(query, selected, candidate_count)
	if sweep_radius_raw > 0:
		result["query_shape"] = &"swept_aabb_v1"
		result["radius_raw"] = sweep_radius_raw
		var digest_source := result.duplicate(true)
		digest_source.erase("duplicate")
		digest_source.erase("resolution_digest")
		result["resolution_digest"] = ZCanonicalValue.sha256(digest_source)
	_query_ledger[request_key] = {
		"fingerprint": fingerprint,
		"result": result.duplicate(true),
	}
	return _read_only_dictionary(result)


static func _sweep_bound(point: Vector2i, offset: int) -> Vector2i:
	# Clipping only outside the legal world domain cannot remove an in-domain
	# intersection. Scalar arithmetic avoids Vector2i overflow at the boundary.
	return Vector2i(clampi(int(point.x) + offset, -MAX_COORDINATE_RAW, MAX_COORDINATE_RAW),
		clampi(int(point.y) + offset, -MAX_COORDINATE_RAW, MAX_COORDINATE_RAW))


func _build_snapshot(bodies: Array, obstructions: Array) -> Dictionary:
	if bodies.size() > MAX_BODIES:
		last_error = &"body_capacity_exceeded"
		return {}
	if obstructions.size() > MAX_OBSTRUCTIONS:
		last_error = &"obstruction_capacity_exceeded"
		return {}
	var next_bodies: Dictionary = {}
	for value in bodies:
		var normalized := _normalize_body(value)
		if normalized.is_empty():
			return {}
		var entity_id := String(normalized["entity_id"])
		if next_bodies.has(entity_id):
			last_error = &"body_entity_duplicate"
			return {}
		next_bodies[entity_id] = normalized
	var next_obstructions: Dictionary = {}
	for value in obstructions:
		var normalized := _normalize_obstruction(value)
		if normalized.is_empty():
			return {}
		var obstruction_id := String(normalized["obstruction_id"])
		if next_obstructions.has(obstruction_id):
			last_error = &"obstruction_id_duplicate"
			return {}
		next_obstructions[obstruction_id] = normalized

	var body_history_result := _next_revision_history(
		_body_history, next_bodies, "entity_id", "body_revision",
		MAX_BODY_HISTORY, &"body")
	if not bool(body_history_result.get("ok", false)):
		return {}
	var obstruction_history_result := _next_revision_history(
		_obstruction_history, next_obstructions, "obstruction_id",
		"geometry_revision", MAX_OBSTRUCTION_HISTORY, &"obstruction")
	if not bool(obstruction_history_result.get("ok", false)):
		return {}
	var digest := _digest_snapshot(next_bodies, next_obstructions)
	if digest.is_empty():
		last_error = &"snapshot_digest_invalid"
		return {}
	return {
		"ok": true,
		"bodies": next_bodies,
		"obstructions": next_obstructions,
		"body_history": body_history_result["history"],
		"obstruction_history": obstruction_history_result["history"],
		"digest": digest,
	}


func _normalize_body(value: Variant) -> Dictionary:
	if typeof(value) != TYPE_DICTIONARY:
		last_error = &"body_record_type_invalid"
		return {}
	var source := value as Dictionary
	if not _has_exact_keys(source, BODY_RECORD_KEYS):
		last_error = &"body_record_schema_invalid"
		return {}
	if not _is_text(source["entity_id"]) \
			or typeof(source["actor_source"]) != TYPE_INT \
			or not _is_text(source["profile_id"]) \
			or typeof(source["body_revision"]) != TYPE_INT \
			or typeof(source["origin_raw"]) != TYPE_VECTOR2I \
			or typeof(source["facing_quarter_turns"]) != TYPE_INT \
			or typeof(source["collision_layer"]) != TYPE_INT \
			or typeof(source["targetable"]) != TYPE_BOOL:
		last_error = &"body_record_field_type_invalid"
		return {}
	var entity := ZEntityId.parse(String(source["entity_id"]))
	if entity == null:
		last_error = &"body_entity_id_invalid"
		return {}
	var actor_source_value := int(source["actor_source"])
	if not _actor_source_is_valid(actor_source_value):
		last_error = &"body_actor_source_invalid"
		return {}
	var actor_source: ZRaidIntent.Source = actor_source_value
	if _authority == null or not _authority.has_authorized_actor_source(
		entity, actor_source, _authority_generation):
		last_error = &"body_actor_not_authorized"
		return {}
	if StringName(source["profile_id"]) != ZerkovBodyHitboxProfile.PROFILE_HUMANOID_V1:
		last_error = &"body_profile_unsupported"
		return {}
	var body_revision := int(source["body_revision"])
	var facing := int(source["facing_quarter_turns"])
	var layer := int(source["collision_layer"])
	var origin := source["origin_raw"] as Vector2i
	if body_revision <= 0:
		last_error = &"body_revision_invalid"
		return {}
	if facing < 0 or facing > 3:
		last_error = &"body_facing_invalid"
		return {}
	if layer <= 0 or layer > MAX_COLLISION_MASK:
		last_error = &"body_collision_layer_invalid"
		return {}
	if not _point_is_bounded(origin):
		last_error = &"body_origin_out_of_bounds"
		return {}
	var hitboxes := ZerkovBodyHitboxProfile.build_world_hitboxes(origin, facing)
	if hitboxes.size() != 7:
		last_error = &"body_hitbox_generation_failed"
		return {}
	for hitbox_value in hitboxes:
		var hitbox := hitbox_value as Dictionary
		if not _aabb_is_bounded(
			hitbox["min_raw"] as Vector2i, hitbox["max_raw"] as Vector2i):
			last_error = &"body_hitbox_out_of_bounds"
			return {}
	return {
		"entity_id": entity.canonical_key(),
		"actor_source": int(actor_source),
		"profile_id": String(ZerkovBodyHitboxProfile.PROFILE_HUMANOID_V1),
		"body_revision": body_revision,
		"origin_raw": origin,
		"facing_quarter_turns": facing,
		"collision_layer": layer,
		"targetable": bool(source["targetable"]),
		"hitboxes": hitboxes,
	}


func _normalize_obstruction(value: Variant) -> Dictionary:
	if typeof(value) != TYPE_DICTIONARY:
		last_error = &"obstruction_record_type_invalid"
		return {}
	var source := value as Dictionary
	if not _has_exact_keys(source, OBSTRUCTION_RECORD_KEYS):
		last_error = &"obstruction_record_schema_invalid"
		return {}
	if not _is_text(source["obstruction_id"]) \
			or typeof(source["geometry_revision"]) != TYPE_INT \
			or typeof(source["min_raw"]) != TYPE_VECTOR2I \
			or typeof(source["max_raw"]) != TYPE_VECTOR2I \
			or typeof(source["collision_layer"]) != TYPE_INT \
			or typeof(source["enabled"]) != TYPE_BOOL:
		last_error = &"obstruction_record_field_type_invalid"
		return {}
	var obstruction := ZObstructionId.parse(String(source["obstruction_id"]))
	if obstruction == null:
		last_error = &"obstruction_id_invalid"
		return {}
	var revision := int(source["geometry_revision"])
	var layer := int(source["collision_layer"])
	var minimum := source["min_raw"] as Vector2i
	var maximum := source["max_raw"] as Vector2i
	if revision <= 0:
		last_error = &"obstruction_revision_invalid"
		return {}
	if layer <= 0 or layer > MAX_COLLISION_MASK:
		last_error = &"obstruction_collision_layer_invalid"
		return {}
	if not _aabb_is_bounded(minimum, maximum):
		last_error = &"obstruction_geometry_invalid"
		return {}
	return {
		"obstruction_id": obstruction.canonical_key(),
		"geometry_revision": revision,
		"min_raw": minimum,
		"max_raw": maximum,
		"collision_layer": layer,
		"enabled": bool(source["enabled"]),
	}


func _next_revision_history(
	previous_history: Dictionary,
	current_records: Dictionary,
	id_field: String,
	revision_field: String,
	capacity: int,
	error_prefix: StringName
) -> Dictionary:
	var next_history: Dictionary = {}
	for key in previous_history:
		var prior := (previous_history[key] as Dictionary).duplicate(true)
		prior["present"] = false
		next_history[key] = prior
	var keys := PackedStringArray(current_records.keys())
	keys.sort()
	for key in keys:
		var record := current_records[key] as Dictionary
		var digest_record := record.duplicate(true)
		digest_record.erase("hitboxes")
		var digest := ZCanonicalValue.sha256(digest_record)
		if digest.is_empty():
			last_error = StringName("%s_record_digest_invalid" % String(error_prefix))
			return {}
		var revision := int(record[revision_field])
		if next_history.has(key):
			var prior := next_history[key] as Dictionary
			var floor_revision := int(prior["revision"])
			if revision < floor_revision:
				last_error = StringName("%s_revision_regressed" % String(error_prefix))
				return {}
			if revision == floor_revision:
				if not bool(previous_history[key].get("present", false)):
					last_error = StringName("%s_stale_resurrection" % String(error_prefix))
					return {}
				if String(prior["digest"]) != digest:
					last_error = StringName("%s_equal_revision_divergence" % String(error_prefix))
					return {}
		elif next_history.size() >= capacity:
			last_error = StringName("%s_history_capacity_exceeded" % String(error_prefix))
			return {}
		next_history[key] = {
			"id": String(record[id_field]),
			"revision": revision,
			"digest": digest,
			"present": true,
		}
	return {"ok": true, "history": next_history}


func _digest_snapshot(bodies: Dictionary, obstructions: Dictionary) -> String:
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK:
		return ""
	var header := ZCanonicalValue.encode({
		"schema": SNAPSHOT_SCHEMA,
		"profile_digest": ZerkovBodyHitboxProfile.declaration_digest(),
		"body_count": bodies.size(),
		"obstruction_count": obstructions.size(),
	})
	if header.is_empty() or context.update(header.to_utf8_buffer()) != OK:
		return ""
	var body_ids := PackedStringArray(bodies.keys())
	body_ids.sort()
	for entity_id in body_ids:
		var record := (bodies[entity_id] as Dictionary).duplicate(true)
		record.erase("hitboxes")
		var encoded := ZCanonicalValue.encode(record)
		if encoded.is_empty() \
				or context.update(("body:" + encoded).to_utf8_buffer()) != OK:
			return ""
	var obstruction_ids := PackedStringArray(obstructions.keys())
	obstruction_ids.sort()
	for obstruction_id in obstruction_ids:
		var encoded := ZCanonicalValue.encode(obstructions[obstruction_id])
		if encoded.is_empty() \
				or context.update(("obstruction:" + encoded).to_utf8_buffer()) != OK:
			return ""
	return context.finish().hex_encode()


func _normalize_ray_query(query_value: Variant) -> Dictionary:
	if typeof(query_value) != TYPE_DICTIONARY:
		last_error = &"ray_query_type_invalid"
		return {}
	var source := query_value as Dictionary
	if not _has_exact_keys(source, RAY_QUERY_KEYS):
		last_error = &"ray_query_schema_invalid"
		return {}
	if not _is_text(source["request_id"]) \
			or not _is_text(source["raid_id"]) \
			or not _is_text(source["session_id"]) \
			or typeof(source["authority_epoch"]) != TYPE_INT \
			or typeof(source["authority_generation"]) != TYPE_INT \
			or typeof(source["binding_token"]) != TYPE_INT \
			or not _is_text(source["owner_actor_id"]) \
			or typeof(source["owner_actor_source"]) != TYPE_INT \
			or not _is_text(source["query_actor_id"]) \
			or typeof(source["query_actor_source"]) != TYPE_INT \
			or typeof(source["tick"]) != TYPE_INT \
			or typeof(source["world_revision"]) != TYPE_INT \
			or typeof(source["origin_raw"]) != TYPE_VECTOR2I \
			or typeof(source["target_raw"]) != TYPE_VECTOR2I \
			or typeof(source["body_mask"]) != TYPE_INT \
			or typeof(source["obstruction_mask"]) != TYPE_INT \
			or not [TYPE_ARRAY, TYPE_PACKED_STRING_ARRAY].has(
				typeof(source["excluded_entity_ids"])):
		last_error = &"ray_query_field_type_invalid"
		return {}
	var request := ZRequestId.parse(String(source["request_id"]))
	if request == null:
		last_error = &"ray_query_request_id_invalid"
		return {}
	var raid := ZRaidId.parse(String(source["raid_id"]))
	var session := ZSessionId.parse(String(source["session_id"]))
	var owner_actor := ZEntityId.parse(String(source["owner_actor_id"]))
	var query_actor := ZEntityId.parse(String(source["query_actor_id"]))
	if raid == null or session == null or owner_actor == null or query_actor == null:
		last_error = &"ray_query_provenance_id_invalid"
		return {}
	var authority_epoch := int(source["authority_epoch"])
	var generation := int(source["authority_generation"])
	var token := int(source["binding_token"])
	var owner_source_value := int(source["owner_actor_source"])
	var query_source_value := int(source["query_actor_source"])
	var tick := int(source["tick"])
	var revision := int(source["world_revision"])
	var origin := source["origin_raw"] as Vector2i
	var target := source["target_raw"] as Vector2i
	var body_mask := int(source["body_mask"])
	var obstruction_mask := int(source["obstruction_mask"])
	if authority_epoch <= 0 or generation <= 0 or token <= 0:
		last_error = &"ray_query_binding_invalid"
		return {}
	if not _actor_source_is_valid(owner_source_value) \
			or not _actor_source_is_valid(query_source_value):
		last_error = &"ray_query_actor_source_invalid"
		return {}
	var owner_actor_source: ZRaidIntent.Source = owner_source_value
	var query_actor_source: ZRaidIntent.Source = query_source_value
	if _raid_id == null or not raid.is_equal(_raid_id):
		last_error = &"ray_query_raid_mismatch"
		return {}
	if _session_id == null or not session.is_equal(_session_id):
		last_error = &"ray_query_session_mismatch"
		return {}
	if authority_epoch != _authority_epoch:
		last_error = &"ray_query_authority_epoch_mismatch"
		return {}
	if _owner_actor_id == null or not owner_actor.is_equal(_owner_actor_id) \
			or owner_source_value != int(_owner_actor_source):
		last_error = &"ray_query_owner_mismatch"
		return {}
	if _authority == null or not _authority.has_authorized_actor_source(
		owner_actor, owner_actor_source, _authority_generation):
		last_error = &"ray_query_owner_not_authorized"
		return {}
	if not _authority.has_authorized_actor_source(
		query_actor, query_actor_source, _authority_generation):
		last_error = &"ray_query_actor_not_authorized"
		return {}
	if tick < 0 or revision <= 0:
		last_error = &"ray_query_order_invalid"
		return {}
	if not _point_is_bounded(origin) or not _point_is_bounded(target) \
			or origin == target:
		last_error = &"ray_query_geometry_invalid"
		return {}
	if body_mask < 0 or body_mask > MAX_COLLISION_MASK \
			or obstruction_mask < 0 or obstruction_mask > MAX_COLLISION_MASK \
			or (body_mask == 0 and obstruction_mask == 0):
		last_error = &"ray_query_mask_invalid"
		return {}
	var exclusions_source: Array = []
	if typeof(source["excluded_entity_ids"]) == TYPE_ARRAY:
		exclusions_source = (source["excluded_entity_ids"] as Array).duplicate()
	else:
		for value in source["excluded_entity_ids"] as PackedStringArray:
			exclusions_source.append(value)
	if exclusions_source.size() > MAX_EXCLUDED_ENTITIES:
		last_error = &"ray_query_exclusion_capacity_exceeded"
		return {}
	var excluded: Dictionary = {}
	for value in exclusions_source:
		if not _is_text(value):
			last_error = &"ray_query_exclusion_type_invalid"
			return {}
		var entity := ZEntityId.parse(String(value))
		if entity == null:
			last_error = &"ray_query_exclusion_id_invalid"
			return {}
		var key := entity.canonical_key()
		if excluded.has(key):
			last_error = &"ray_query_exclusion_duplicate"
			return {}
		excluded[key] = true
	var exclusion_ids := PackedStringArray(excluded.keys())
	exclusion_ids.sort()
	var normalized_exclusions: Array[String] = []
	for value in exclusion_ids:
		normalized_exclusions.append(value)
	var record := {
		"schema": RAY_QUERY_SCHEMA,
		"request_id": request.canonical_key(),
		"raid_id": raid.canonical_key(),
		"session_id": session.canonical_key(),
		"authority_epoch": authority_epoch,
		"authority_generation": generation,
		"binding_token": token,
		"owner_actor_id": owner_actor.canonical_key(),
		"owner_actor_source": owner_source_value,
		"query_actor_id": query_actor.canonical_key(),
		"query_actor_source": query_source_value,
		"tick": tick,
		"world_revision": revision,
		"origin_raw": origin,
		"target_raw": target,
		"body_mask": body_mask,
		"obstruction_mask": obstruction_mask,
		"excluded_entity_ids": normalized_exclusions,
	}
	var fingerprint := ZCanonicalValue.sha256(record)
	if fingerprint.is_empty():
		last_error = &"ray_query_fingerprint_invalid"
		return {}
	return {
		"ok": true,
		"record": record,
		"fingerprint": fingerprint,
		"excluded": excluded,
	}


func _ray_aabb_fraction(
	origin: Vector2i,
	target: Vector2i,
	minimum: Vector2i,
	maximum: Vector2i
) -> Dictionary:
	var entry: Array[int] = [0, 1]
	var exit: Array[int] = [1, 1]
	if not _clip_axis(origin.x, target.x - origin.x, minimum.x, maximum.x, entry, exit):
		return {}
	if not _clip_axis(origin.y, target.y - origin.y, minimum.y, maximum.y, entry, exit):
		return {}
	if _compare_fraction(entry[0], entry[1], exit[0], exit[1]) > 0:
		return {}
	return _normalized_fraction(entry[0], entry[1])


func _clip_axis(
	start: int,
	delta: int,
	minimum: int,
	maximum: int,
	entry: Array[int],
	exit: Array[int]
) -> bool:
	if delta == 0:
		return start >= minimum and start <= maximum
	var first_numerator := minimum - start
	var second_numerator := maximum - start
	var denominator := delta
	if denominator < 0:
		first_numerator = -first_numerator
		second_numerator = -second_numerator
		denominator = -denominator
	if _compare_fraction(
		first_numerator, denominator, second_numerator, denominator) > 0:
		var swap := first_numerator
		first_numerator = second_numerator
		second_numerator = swap
	if _compare_fraction(first_numerator, denominator, entry[0], entry[1]) > 0:
		entry[0] = first_numerator
		entry[1] = denominator
	if _compare_fraction(second_numerator, denominator, exit[0], exit[1]) < 0:
		exit[0] = second_numerator
		exit[1] = denominator
	return _compare_fraction(entry[0], entry[1], exit[0], exit[1]) <= 0


func _candidate_precedes(left: Dictionary, right: Dictionary) -> bool:
	var fraction_order := _compare_fraction(
		int(left["fraction_numerator"]), int(left["fraction_denominator"]),
		int(right["fraction_numerator"]), int(right["fraction_denominator"]))
	if fraction_order != 0:
		return fraction_order < 0
	var left_kind := int(left["candidate_kind"])
	var right_kind := int(right["candidate_kind"])
	if left_kind != right_kind:
		# Obstruction (0) wins an exact body/obstruction boundary tie.
		return left_kind < right_kind
	if left_kind == 0:
		return String(left["obstruction_id"]) < String(right["obstruction_id"])
	var left_entity := String(left["entity_id"])
	var right_entity := String(right["entity_id"])
	if left_entity != right_entity:
		return left_entity < right_entity
	var left_priority := int(left["zone_priority"])
	var right_priority := int(right["zone_priority"])
	if left_priority != right_priority:
		return left_priority < right_priority
	return String(left["hitbox_id"]) < String(right["hitbox_id"])


func _build_query_result(
	query: Dictionary,
	selected: Dictionary,
	candidate_count: int
) -> Dictionary:
	var result := {
		"accepted": true,
		"duplicate": false,
		"reason": &"",
		"request_id": String(query["request_id"]),
		"raid_id": _raid_id.canonical_key(),
		"session_id": _session_id.canonical_key(),
		"authority_epoch": _authority_epoch,
		"authority_generation": _authority_generation,
		"binding_token": _active_binding_token,
		"owner_actor_id": _owner_actor_id.canonical_key(),
		"owner_actor_source": int(_owner_actor_source),
		"query_actor_id": String(query["query_actor_id"]),
		"query_actor_source": int(query["query_actor_source"]),
		"tick": _snapshot_tick,
		"world_revision": _snapshot_revision,
		"snapshot_digest": _snapshot_digest,
		"candidate_count": candidate_count,
		"outcome": &"miss",
		"hit": false,
		"blocked": false,
		"entity_id": "",
		"body_revision": 0,
		"profile_id": "",
		"hitbox_id": "",
		"body_zone": &"",
		"anatomy_group": &"",
		"obstruction_id": "",
		"ray_fraction_numerator": -1,
		"ray_fraction_denominator": 1,
		"hit_point_raw": query["target_raw"],
	}
	if not selected.is_empty():
		var numerator := int(selected["fraction_numerator"])
		var denominator := int(selected["fraction_denominator"])
		result["ray_fraction_numerator"] = numerator
		result["ray_fraction_denominator"] = denominator
		result["hit_point_raw"] = _interpolate_point(
			query["origin_raw"] as Vector2i,
			query["target_raw"] as Vector2i,
			numerator, denominator)
		if int(selected["candidate_kind"]) == 0:
			result["outcome"] = &"obstruction"
			result["blocked"] = true
			result["obstruction_id"] = String(selected["obstruction_id"])
		else:
			result["outcome"] = &"body_hit"
			result["hit"] = true
			result["entity_id"] = String(selected["entity_id"])
			result["body_revision"] = int(selected["body_revision"])
			result["profile_id"] = String(selected["profile_id"])
			result["hitbox_id"] = String(selected["hitbox_id"])
			result["body_zone"] = StringName(selected["body_zone"])
			result["anatomy_group"] = StringName(selected["anatomy_group"])
	var digest_record := result.duplicate(true)
	digest_record.erase("duplicate")
	result["resolution_digest"] = ZCanonicalValue.sha256(digest_record)
	return result


func _interpolate_point(
	origin: Vector2i,
	target: Vector2i,
	numerator: int,
	denominator: int
) -> Vector2i:
	# Subtract scalar components rather than Vector2i values: each published
	# coordinate fits int32, while the full endpoint delta may be up to 3e9.
	var delta_x: int = target.x - origin.x
	var delta_y: int = target.y - origin.y
	# The coordinate bound above keeps each product <= 9e18. Round exact
	# rational coordinates half away from zero for a stable integer fact.
	return Vector2i(
		origin.x + _divide_round_half_away(delta_x * numerator, denominator),
		origin.y + _divide_round_half_away(delta_y * numerator, denominator))


func _divide_round_half_away(numerator: int, denominator: int) -> int:
	var sign_value := -1 if numerator < 0 else 1
	var magnitude := absi(numerator)
	var quotient := magnitude / denominator
	var remainder := magnitude % denominator
	if remainder * 2 >= denominator:
		quotient += 1
	return quotient * sign_value


func _normalized_fraction(numerator: int, denominator: int) -> Dictionary:
	if denominator <= 0:
		return {}
	if numerator == 0:
		return {"numerator": 0, "denominator": 1}
	var divisor := _greatest_common_divisor(absi(numerator), denominator)
	return {
		"numerator": numerator / divisor,
		"denominator": denominator / divisor,
	}


func _greatest_common_divisor(left: int, right: int) -> int:
	var a := left
	var b := right
	while b != 0:
		var remainder := a % b
		a = b
		b = remainder
	return maxi(a, 1)


func _compare_fraction(
	left_numerator: int,
	left_denominator: int,
	right_numerator: int,
	right_denominator: int
) -> int:
	# All denominators are positive and the published coordinate bound proves
	# these products cannot overflow signed int64.
	var left_cross := left_numerator * right_denominator
	var right_cross := right_numerator * left_denominator
	if left_cross < right_cross:
		return -1
	if left_cross > right_cross:
		return 1
	return 0


func _guard_binding(
	capability: Variant,
	expected_generation: int,
	expected_token: int
) -> bool:
	if not _guard_binding_capability(capability):
		return false
	if expected_generation <= 0 or expected_generation != _authority_generation:
		return _reject_bool(&"authority_generation_mismatch")
	if expected_token <= 0 or expected_token != _active_binding_token:
		return _reject_bool(&"binding_token_mismatch")
	if not _binding_identity_is_current():
		return _reject_bool(&"binding_generation_invalidated")
	return true


func _guard_binding_capability(capability: Variant) -> bool:
	if lifecycle != Lifecycle.BOUND:
		return _reject_bool(&"hitbox_world_not_bound")
	if _delegated_only:
		return _reject_bool(&"binding_capability_revoked")
	if capability == null or not capability is BindingCapability:
		return _reject_bool(&"binding_capability_mismatch")
	var candidate := capability as BindingCapability
	if not _binding_lease_secret_is_valid(candidate._lease_secret) \
			or _active_binding_commitment.size() != BINDING_LEASE_BYTES:
		return _reject_bool(&"binding_capability_mismatch")
	var candidate_commitment := _binding_capability_commitment(
		candidate, candidate._lease_secret, _authority_instance_id,
		_authority_generation, _active_binding_token)
	if not _constant_time_bytes_equal(
		candidate_commitment, _active_binding_commitment):
		return _reject_bool(&"binding_capability_mismatch")
	return true


func _guard_phase_consumer(
	handler_id: StringName,
	registration_id: String,
	callback: Callable,
	tick: int,
	require_world_dispatch: bool
) -> bool:
	if not _binding_identity_is_current():
		return _reject_bool(&"binding_generation_invalidated")
	var consumer := _phase_consumers.get(registration_id, {}) as Dictionary
	if consumer.is_empty() \
			or StringName(consumer.get("handler_id", &"")) != handler_id \
			or int(consumer.get("binding_token", 0)) != _active_binding_token:
		return _reject_bool(&"phase_consumer_invalid")
	if int(consumer.get("phase", -1)) \
			!= int(RaidAuthority.TickPhase.WORLD_CONSEQUENCES) \
			or StringName(consumer.get("permission", &"")) != &"raycast":
		return _reject_bool(&"phase_consumer_invalid")
	if not _authority.has_exact_phase_handler(
		handler_id, registration_id, callback,
		RaidAuthority.TickPhase.WORLD_CONSEQUENCES, _authority_generation):
		return _reject_bool(&"phase_consumer_registration_invalid")
	if require_world_dispatch:
		if not _authority.is_dispatching_phase_registration(
			handler_id, registration_id, callback,
			RaidAuthority.TickPhase.WORLD_CONSEQUENCES, tick,
			_authority_generation):
			return _reject_bool(&"phase_consumer_dispatch_invalid")
	elif not _authority.is_processing_tick_phase(
		RaidAuthority.TickPhase.INTERACTIONS_AND_WEAPONS,
		tick, _authority_generation) \
			and not _authority.is_dispatching_phase_registration(
				handler_id, registration_id, callback,
				RaidAuthority.TickPhase.WORLD_CONSEQUENCES, tick,
				_authority_generation):
		return _reject_bool(&"phase_consumer_phase_invalid")
	return true


func _guard_exact_phase_grant(
	handler_id: StringName,
	registration_id: String,
	callback: Callable,
	tick: int,
	phase: RaidAuthority.TickPhase,
	permission: StringName
) -> bool:
	if not _binding_identity_is_current():
		return _reject_bool(&"binding_generation_invalidated")
	var consumer := _phase_consumers.get(registration_id, {}) as Dictionary
	if consumer.is_empty() \
			or StringName(consumer.get("handler_id", &"")) != handler_id \
			or int(consumer.get("binding_token", 0)) != _active_binding_token \
			or int(consumer.get("phase", -1)) != int(phase) \
			or StringName(consumer.get("permission", &"")) != permission:
		return _reject_bool(&"phase_consumer_invalid")
	if not _authority.has_exact_phase_handler(
		handler_id, registration_id, callback, phase, _authority_generation):
		return _reject_bool(&"phase_consumer_registration_invalid")
	if not _authority.is_dispatching_phase_registration(
		handler_id, registration_id, callback, phase, tick,
		_authority_generation):
		return _reject_bool(&"phase_consumer_dispatch_invalid")
	return true


func _binding_capability_commitment(
	capability: BindingCapability,
	secret: PackedByteArray,
	authority_instance_id: int,
	authority_generation: int,
	binding_token: int
) -> PackedByteArray:
	if capability == null or not is_instance_valid(capability) \
			or secret.size() != BINDING_LEASE_BYTES \
			or authority_instance_id == 0 or authority_generation <= 0 \
			or binding_token <= 0:
		return PackedByteArray()
	var header := ZCanonicalValue.encode({
		"schema": BINDING_COMMITMENT_SCHEMA,
		"world_instance_id": get_instance_id(),
		"authority_instance_id": authority_instance_id,
		"authority_generation": authority_generation,
		"binding_token": binding_token,
		"capability_instance_id": capability.get_instance_id(),
	})
	if header.is_empty():
		return PackedByteArray()
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK \
			or context.update(header.to_utf8_buffer()) != OK \
			or context.update(secret) != OK:
		return PackedByteArray()
	var digest := context.finish()
	return digest if digest.size() == BINDING_LEASE_BYTES else PackedByteArray()


func _constant_time_bytes_equal(
	left: PackedByteArray,
	right: PackedByteArray
) -> bool:
	if left.size() != right.size() or left.is_empty():
		return false
	var difference := 0
	for index in left.size():
		difference |= int(left[index]) ^ int(right[index])
	return difference == 0


func _binding_lease_secret_is_valid(secret: PackedByteArray) -> bool:
	if secret.size() != BINDING_LEASE_BYTES:
		return false
	var combined := 0
	for value in secret:
		combined |= int(value)
	return combined != 0


func _guard_publisher(actor_value: Variant, source_value: Variant) -> bool:
	var publisher := _validated_actor_source(
		actor_value, source_value, &"snapshot_publisher")
	if publisher.is_empty():
		return false
	var actor := publisher["actor_id"] as ZEntityId
	var source: ZRaidIntent.Source = int(publisher["actor_source"])
	if _owner_actor_id == null or not actor.is_equal(_owner_actor_id) \
			or int(source) != int(_owner_actor_source):
		return _reject_bool(&"snapshot_publisher_mismatch")
	if _authority == null or not _authority.has_authorized_actor_source(
		actor, source, _authority_generation):
		return _reject_bool(&"snapshot_publisher_not_authorized")
	return true


func _validated_actor_source(
	actor_value: Variant,
	source_value: Variant,
	error_prefix: StringName
) -> Dictionary:
	if not actor_value is ZEntityId:
		last_error = StringName("%s_actor_id_invalid" % String(error_prefix))
		return {}
	if typeof(source_value) != TYPE_INT or not _actor_source_is_valid(int(source_value)):
		last_error = StringName("%s_actor_source_invalid" % String(error_prefix))
		return {}
	var actor := actor_value as ZEntityId
	if actor == null or ZEntityId.parse(actor.canonical_key()) == null:
		last_error = StringName("%s_actor_id_invalid" % String(error_prefix))
		return {}
	return {
		"actor_id": ZEntityId.parse(actor.canonical_key()),
		"actor_source": int(source_value),
	}


func _actor_source_is_valid(value: int) -> bool:
	return value >= ZRaidIntent.Source.PLAYER and value <= ZRaidIntent.Source.SYSTEM


func _binding_identity_is_current() -> bool:
	if _authority == null or not is_instance_valid(_authority) \
			or _authority.get_instance_id() != _authority_instance_id \
			or _authority.generation() != _authority_generation \
			or _authority.lifecycle == RaidAuthority.Lifecycle.TORN_DOWN \
			or _raid_id == null or _session_id == null or _owner_actor_id == null:
		return false
	var current_raid := _authority.raid_id()
	var current_admission := _authority.admission()
	return current_raid != null and current_raid.is_equal(_raid_id) \
		and current_admission != null and current_admission.is_usable() \
		and current_admission.raid_id.is_equal(_raid_id) \
		and current_admission.session_id.is_equal(_session_id) \
		and current_admission.authority_epoch == _authority_epoch \
		and current_admission.generation == _authority_generation \
		and _authority.has_authorized_actor_source(
			_owner_actor_id, _owner_actor_source, _authority_generation)


func _authority_allows_publication() -> bool:
	return _authority != null and _authority.clock != null \
		and not _authority.clock.is_sealed() \
		and _authority.lifecycle in [
			RaidAuthority.Lifecycle.PREPARING,
			RaidAuthority.Lifecycle.ACTIVE,
			RaidAuthority.Lifecycle.EXTRACTING,
		]


func _authority_allows_query() -> bool:
	return _authority != null and _authority.clock != null \
		and not _authority.clock.is_sealed() \
		and _authority.lifecycle in [
			RaidAuthority.Lifecycle.ACTIVE,
			RaidAuthority.Lifecycle.EXTRACTING,
		]


func _has_exact_keys(value: Dictionary, expected_keys: PackedStringArray) -> bool:
	if value.size() != expected_keys.size():
		return false
	var actual := PackedStringArray()
	for key in value:
		if typeof(key) != TYPE_STRING and typeof(key) != TYPE_STRING_NAME:
			return false
		actual.append(String(key))
	actual.sort()
	var expected := PackedStringArray(expected_keys)
	expected.sort()
	return actual == expected


func _is_text(value: Variant) -> bool:
	return typeof(value) == TYPE_STRING or typeof(value) == TYPE_STRING_NAME


func _read_only_dictionary(value: Dictionary) -> Dictionary:
	var publication := value.duplicate(true)
	_make_deep_read_only(publication)
	return publication


func _make_deep_read_only(value: Variant) -> void:
	match typeof(value):
		TYPE_DICTIONARY:
			var dictionary := value as Dictionary
			for key in dictionary.keys():
				_make_deep_read_only(dictionary[key])
			dictionary.make_read_only()
		TYPE_ARRAY:
			var array := value as Array
			for entry in array:
				_make_deep_read_only(entry)
			array.make_read_only()


func _point_is_bounded(point: Vector2i) -> bool:
	return absi(point.x) <= MAX_COORDINATE_RAW \
		and absi(point.y) <= MAX_COORDINATE_RAW


func _aabb_is_bounded(minimum: Vector2i, maximum: Vector2i) -> bool:
	return minimum.x < maximum.x and minimum.y < maximum.y \
		and _point_is_bounded(minimum) and _point_is_bounded(maximum)


func _clear_snapshot_state() -> void:
	_snapshot_tick = -1
	_snapshot_revision = 0
	_snapshot_digest = ""
	_bodies_by_id.clear()
	_obstructions_by_id.clear()
	_body_history.clear()
	_obstruction_history.clear()
	_query_ledger.clear()
	_phase_consumers.clear()
	last_publication_duplicate = false
	last_query_duplicate = false


func _rejection(reason: StringName, request_id: String = "") -> Dictionary:
	last_error = reason
	return _read_only_dictionary({
		"accepted": false,
		"duplicate": false,
		"reason": reason,
		"request_id": request_id,
		"hit": false,
		"blocked": false,
	})


func _reject_bool(reason: StringName) -> bool:
	last_error = reason
	return false


func _reject_capability(reason: StringName) -> BindingCapability:
	last_error = reason
	return null
