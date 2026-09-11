class_name WeaponCombatAdapter
extends Node
## Game-owned committed-shot -> authoritative hit/miss adapter.
##
## Weapon System owns the mechanical commit, BodyHitboxWorld2D owns spatial
## facts, and this adapter owns the one stable consequence joining them.  It
## deliberately does not apply damage, injury, death, noise, or presentation.

signal consequence_committed(consequence: Dictionary)
signal binding_invalidated(reason: StringName)

enum Lifecycle {
	UNBOUND,
	BOUND,
	INVALIDATED,
	RELEASED,
}

const PHASE_HANDLER_ID: StringName = &"weapon_combat_adapter"
const PHASE_HANDLER_PRIORITY: int = 100
const CONSEQUENCE_SCHEMA: String = "zerkov.combat.weapon_consequence.v1"
const MAX_PENDING_SHOTS: int = 64
const MAX_RESOLVED_SHOTS: int = 4096
const MAX_IDENTIFIER_BYTES: int = 128
const MAX_DAMAGE_MILLIUNITS: int = 1_000_000_000
const MAX_RANGE_MILLIUNITS: int = 1_000_000_000
const MAX_NOISE_MILLIUNITS: int = 1_000_000_000

const OUTCOME_KEYS: PackedStringArray = [
	"accepted", "replayed", "rejection", "status", "revision",
	"loaded_rounds", "reservation_to_release", "shot",
]
const SHOT_KEYS: PackedStringArray = [
	"consequence_id", "instance_id", "weapon_id", "weapon_version", "tick",
	"origin", "direction", "damage_milliunits", "range_milliunits",
	"noise_radius_milliunits", "consumed_profile",
]
const VECTOR_KEYS: PackedStringArray = ["x", "y"]
const PROFILE_KEYS: PackedStringArray = ["has_profile", "id", "version"]

var lifecycle: Lifecycle = Lifecycle.UNBOUND
var last_error: StringName = &""

var _authority: RaidAuthority
var _authority_instance_id: int = 0
var _raid_generation: int = 0
var _admission: ZSessionAdmission
var _weapon_authority: WeaponAuthority
var _weapon_authority_instance_id: int = 0
var _weapon_context: WeaponInstanceContextAdapter
var _weapon_context_instance_id: int = 0
var _weapon_context_binding_generation: int = 0
var _hitbox_world: BodyHitboxWorld2D
var _hitbox_world_instance_id: int = 0
var _hitbox_capability: Variant
var _hitbox_binding_token: int = 0
var _body_mask: int = 0
var _obstruction_mask: int = 0

var _generation_counter: int = 0
var _binding_generation: int = 0
var _phase_registered: bool = false
var _shot_callback: Callable
var _context_invalidated_callback: Callable
var _pending_order: Array[String] = []
var _pending_by_identity: Dictionary = {}
var _resolved_by_identity: Dictionary = {}
var _reserved_event_ids: Dictionary = {}
var _reserved_request_ids: Dictionary = {}
var _last_result: Dictionary = {}
var _fatal_error: StringName = &""
var _public_signal_active: bool = false


## Binding is mutation-free and permitted only during raid preparation.  All
## owner/session/actor facts are derived from the authority and authenticated
## against both accepted dependency bindings.
func bind_context(
	authority: RaidAuthority,
	weapon_authority: WeaponAuthority,
	weapon_context: WeaponInstanceContextAdapter,
	hitbox_world: BodyHitboxWorld2D,
	hitbox_capability: Variant,
	expected_raid_generation: int,
	expected_weapon_context_binding_generation: int,
	body_mask: int,
	obstruction_mask: int
) -> bool:
	last_error = &""
	if _public_signal_active:
		return _reject(&"reentrant_binding_change")
	if lifecycle == Lifecycle.BOUND or lifecycle == Lifecycle.INVALIDATED:
		return _reject(&"combat_adapter_already_bound")
	if authority == null or not is_instance_valid(authority) \
			or expected_raid_generation <= 0 \
			or authority.generation() != expected_raid_generation \
			or authority.lifecycle != RaidAuthority.Lifecycle.PREPARING:
		return _reject(&"raid_authority_invalid")
	var admission := authority.admission()
	if admission == null or not admission.is_usable() \
			or not authority.has_authorized_actor_source(
				admission.actor_id, ZRaidIntent.Source.PLAYER,
				expected_raid_generation):
		return _reject(&"raid_admission_invalid")
	if weapon_authority == null or not is_instance_valid(weapon_authority) \
			or not weapon_authority.is_ready():
		return _reject(&"weapon_authority_invalid")
	if weapon_context == null or not is_instance_valid(weapon_context) \
			or not weapon_context.authenticates_combat_binding(
				authority, weapon_authority, admission.actor_id,
				ZRaidIntent.Source.PLAYER,
				expected_weapon_context_binding_generation):
		return _reject(&"weapon_context_binding_invalid")
	if hitbox_world == null or not is_instance_valid(hitbox_world):
		return _reject(&"hitbox_world_invalid")
	var provenance := hitbox_world.binding_provenance(hitbox_capability)
	if provenance.is_empty() \
			or String(provenance.get("raid_id", "")) \
				!= admission.raid_id.canonical_key() \
			or String(provenance.get("session_id", "")) \
				!= admission.session_id.canonical_key() \
			or int(provenance.get("authority_epoch", 0)) \
				!= admission.authority_epoch \
			or int(provenance.get("authority_generation", 0)) \
				!= expected_raid_generation \
			or String(provenance.get("owner_actor_id", "")) \
				!= admission.actor_id.canonical_key() \
			or int(provenance.get("owner_actor_source", -1)) \
				!= int(ZRaidIntent.Source.PLAYER) \
			or int(provenance.get("world_instance_id", 0)) \
				!= hitbox_world.get_instance_id() \
			or int(provenance.get("authority_instance_id", 0)) \
				!= authority.get_instance_id() \
			or int(provenance.get("binding_token", 0)) <= 0:
		return _reject(&"hitbox_binding_invalid")
	if body_mask < 0 or body_mask > BodyHitboxWorld2D.MAX_COLLISION_MASK \
			or obstruction_mask < 0 \
			or obstruction_mask > BodyHitboxWorld2D.MAX_COLLISION_MASK \
			or (body_mask == 0 and obstruction_mask == 0):
		return _reject(&"collision_mask_invalid")

	var next_generation := _generation_counter + 1
	_reset_runtime_state()
	_authority = authority
	_authority_instance_id = authority.get_instance_id()
	_raid_generation = expected_raid_generation
	_admission = admission.snapshot()
	_weapon_authority = weapon_authority
	_weapon_authority_instance_id = weapon_authority.get_instance_id()
	_weapon_context = weapon_context
	_weapon_context_instance_id = weapon_context.get_instance_id()
	_weapon_context_binding_generation = expected_weapon_context_binding_generation
	_hitbox_world = hitbox_world
	_hitbox_world_instance_id = hitbox_world.get_instance_id()
	_hitbox_capability = hitbox_capability
	_hitbox_binding_token = int(provenance["binding_token"])
	_body_mask = body_mask
	_obstruction_mask = obstruction_mask
	if not authority.register_phase_handler(
		RaidAuthority.TickPhase.WORLD_CONSEQUENCES,
		PHASE_HANDLER_ID,
		Callable(self, "_on_world_consequence_phase").bind(next_generation),
		expected_raid_generation,
		PHASE_HANDLER_PRIORITY
	):
		var registration_error := authority.last_error
		_reset_runtime_state()
		last_error = registration_error
		return false
	_phase_registered = true
	_generation_counter = next_generation
	_binding_generation = next_generation
	lifecycle = Lifecycle.BOUND
	_shot_callback = Callable(self, "_on_shot_committed").bind(
		_weapon_authority_instance_id, _binding_generation)
	_weapon_authority.shot_committed.connect(_shot_callback)
	_context_invalidated_callback = Callable(self, "_on_weapon_context_invalidated").bind(
		_binding_generation)
	_weapon_context.binding_invalidated.connect(_context_invalidated_callback)
	return true


func is_bound() -> bool:
	return lifecycle == Lifecycle.BOUND and _binding_is_current()


func binding_generation() -> int:
	return _binding_generation


func pending_count() -> int:
	return _pending_order.size()


func ledger_size() -> int:
	return _resolved_by_identity.size()


func last_result() -> Dictionary:
	return _read_only_copy(_last_result)


func resolved_consequence(weapon_consequence_id: String) -> Dictionary:
	var entry := _resolved_by_identity.get(weapon_consequence_id, {}) as Dictionary
	return _read_only_copy(entry.get("result", {}) as Dictionary)


func resolved_consequences() -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	var identities := PackedStringArray(_resolved_by_identity.keys())
	identities.sort()
	for identity in identities:
		var entry := _resolved_by_identity[identity] as Dictionary
		results.append(_read_only_copy(entry["result"] as Dictionary))
	results.make_read_only()
	return results


## A WeaponAuthority replay never performs world work.  The exact original
## immutable result is returned only when its full committed-shot fingerprint
## matches the retained binding-generation ledger.
func replay_committed_shot(outcome_value: Variant) -> Dictionary:
	last_error = &""
	if lifecycle != Lifecycle.BOUND or not _binding_is_current():
		return _rejection(&"combat_binding_stale")
	var normalized := _normalize_outcome(outcome_value)
	if normalized.is_empty():
		return _rejection(last_error)
	if not bool(normalized["replayed"]):
		return _rejection(&"committed_shot_not_replay")
	var identity := String(normalized["shot_identity"])
	var fingerprint := String(normalized["fingerprint"])
	if _resolved_by_identity.has(identity):
		var resolved := _resolved_by_identity[identity] as Dictionary
		if String(resolved.get("fingerprint", "")) != fingerprint:
			return _rejection(&"shot_identity_collision", identity)
		return _read_only_copy(resolved["result"] as Dictionary)
	if _pending_by_identity.has(identity):
		var pending := _pending_by_identity[identity] as Dictionary
		if String(pending.get("fingerprint", "")) != fingerprint:
			return _rejection(&"shot_identity_collision", identity)
		return _read_only_copy(pending["receipt"] as Dictionary)
	return _rejection(&"shot_replay_unknown", identity)


func release_binding(reason: StringName = &"weapon_combat_adapter_released") -> bool:
	last_error = &""
	if _public_signal_active:
		return _reject(&"reentrant_binding_change")
	if lifecycle != Lifecycle.BOUND and lifecycle != Lifecycle.INVALIDATED:
		return _reject(&"combat_adapter_not_bound")
	if reason.is_empty() or not ZIdentityRules.is_valid_part(String(reason)):
		return _reject(&"release_reason_invalid")
	if _phase_registered and _authority != null \
			and is_instance_valid(_authority) \
			and _authority.has_phase_handler(PHASE_HANDLER_ID, _raid_generation):
		if not _authority.can_unregister_phase_handler(
			PHASE_HANDLER_ID, _raid_generation):
			last_error = _authority.last_error
			return false
		if not _authority.unregister_phase_handler(
			PHASE_HANDLER_ID, _raid_generation):
			last_error = _authority.last_error
			return false
	_disconnect_dependencies()
	_generation_counter += 1
	_binding_generation = _generation_counter
	_reset_runtime_state()
	lifecycle = Lifecycle.RELEASED
	last_error = reason
	return true


func teardown() -> bool:
	return release_binding(&"teardown")


func _on_shot_committed(
	outcome: Dictionary,
	expected_weapon_authority_instance_id: int,
	expected_binding_generation: int
) -> void:
	if expected_binding_generation != _binding_generation \
			or lifecycle != Lifecycle.BOUND:
		return
	if _public_signal_active:
		var replay_probe := _normalize_outcome(outcome)
		if not replay_probe.is_empty() and bool(replay_probe.get("replayed", false)):
			replay_committed_shot(outcome)
			return
		_latch_fatal(&"reentrant_shot_callback")
		return
	if _weapon_authority == null or not is_instance_valid(_weapon_authority) \
			or _weapon_authority.get_instance_id() \
				!= expected_weapon_authority_instance_id:
		_latch_fatal(&"weapon_authority_replaced")
		return
	var normalized := _normalize_outcome(outcome)
	if normalized.is_empty():
		_latch_fatal(last_error)
		return
	if bool(normalized["replayed"]):
		var replay := replay_committed_shot(outcome)
		if not bool(replay.get("accepted", false)):
			_latch_fatal(StringName(replay.get("reason", &"shot_replay_invalid")))
		return
	_enqueue_committed_shot(normalized)


func _enqueue_committed_shot(normalized: Dictionary) -> Dictionary:
	var identity := String(normalized["shot_identity"])
	var fingerprint := String(normalized["fingerprint"])
	if _resolved_by_identity.has(identity):
		var resolved := _resolved_by_identity[identity] as Dictionary
		if String(resolved.get("fingerprint", "")) != fingerprint:
			return _latch_fatal(&"shot_identity_collision")
		return _read_only_copy(resolved["result"] as Dictionary)
	if _pending_by_identity.has(identity):
		var pending := _pending_by_identity[identity] as Dictionary
		if String(pending.get("fingerprint", "")) != fingerprint:
			return _latch_fatal(&"shot_identity_collision")
		return _read_only_copy(pending["receipt"] as Dictionary)
	if _pending_order.size() >= MAX_PENDING_SHOTS:
		return _latch_fatal(&"pending_shot_capacity_exceeded")
	if _resolved_by_identity.size() + _pending_by_identity.size() \
			>= MAX_RESOLVED_SHOTS:
		return _latch_fatal(&"shot_ledger_capacity_exceeded")
	if not _binding_is_current():
		return _latch_fatal(&"combat_binding_stale")
	var tick := int(normalized["tick"])
	if not _authority.is_processing_tick_phase(
		RaidAuthority.TickPhase.INTERACTIONS_AND_WEAPONS,
		tick, _raid_generation):
		return _latch_fatal(&"committed_shot_phase_invalid")
	var shot := normalized["shot"] as Dictionary
	var record := _current_weapon_record(String(shot["instance_id"]))
	if record.is_empty() or not bool(record.get("equipped", false)) \
			or bool(record.get("parked", true)) \
			or int(record.get("weapon_binding_generation", 0)) <= 0 \
			or ZEntityId.parse(String(record.get("entity_id", ""))) == null:
		return _latch_fatal(&"committed_weapon_binding_invalid")
	var native_snapshot := _weapon_authority.snapshot(String(shot["instance_id"]))
	if native_snapshot.is_empty() \
			or String(native_snapshot.get("instance_id", "")) \
				!= String(shot["instance_id"]) \
			or StringName(native_snapshot.get("definition_id", &"")) \
				!= StringName(shot["weapon_id"]) \
			or int(native_snapshot.get("definition_version", 0)) \
				!= int(shot["weapon_version"]) \
			or int(native_snapshot.get("revision", -1)) \
				!= int(normalized["revision"]) \
			or int(native_snapshot.get("loaded_rounds", -1)) \
				!= int(normalized["loaded_rounds"]):
		return _latch_fatal(&"committed_weapon_snapshot_mismatch")
	var ids := _stable_ids_for_shot(identity)
	if ids.is_empty():
		return _latch_fatal(&"stable_consequence_identity_invalid")
	var collision := _reserve_stable_ids(identity, fingerprint, ids)
	if not collision.is_empty():
		return _latch_fatal(collision)
	var receipt := {
		"accepted": true,
		"queued": true,
		"replayed": false,
		"shot_identity": identity,
		"tick": tick,
		"binding_generation": _binding_generation,
	}
	var entry := normalized.duplicate(true)
	entry["ids"] = ids.duplicate(true)
	entry["weapon_binding_generation"] = int(record["weapon_binding_generation"])
	entry["weapon_entity_id"] = String(record["entity_id"])
	entry["receipt"] = receipt.duplicate(true)
	_pending_by_identity[identity] = entry
	_pending_order.append(identity)
	return _read_only_copy(receipt)


func _on_world_consequence_phase(
	authority: RaidAuthority,
	phase: RaidAuthority.TickPhase,
	tick: int,
	_intents: Array[ZRaidIntent],
	expected_binding_generation: int
) -> bool:
	if expected_binding_generation != _binding_generation:
		return true
	if authority != _authority \
			or phase != RaidAuthority.TickPhase.WORLD_CONSEQUENCES:
		return _reject(&"combat_phase_context_invalid")
	if lifecycle != Lifecycle.BOUND or not _fatal_error.is_empty():
		return _reject(_fatal_error if not _fatal_error.is_empty() \
			else &"combat_binding_invalidated")
	if not _binding_is_current():
		return _reject(&"combat_binding_stale")
	while not _pending_order.is_empty():
		var identity := _pending_order[0]
		var entry := _pending_by_identity.get(identity, {}) as Dictionary
		if entry.is_empty() or int(entry.get("tick", -1)) != tick:
			return _reject(&"pending_shot_tick_invalid")
		if not _resolve_pending(entry):
			return false
		_pending_by_identity.erase(identity)
		_pending_order.remove_at(0)
		if not _fatal_error.is_empty():
			return _reject(_fatal_error)
	return true


func _resolve_pending(entry: Dictionary) -> bool:
	var identity := String(entry["shot_identity"])
	var fingerprint := String(entry["fingerprint"])
	var shot := entry["shot"] as Dictionary
	var ids := entry["ids"] as Dictionary
	var event_id := ZConsequenceId.parse(String(ids["event_id"]))
	var request_id := ZRequestId.parse(String(ids["request_id"]))
	if event_id == null or request_id == null:
		return _reject(&"stable_consequence_identity_invalid")
	var tick := int(entry["tick"])
	var preflight_payload := {"schema": CONSEQUENCE_SCHEMA, "shot_identity": identity}
	if not _authority.can_record_event(
		ZRaidEvent.EventKind.HIT, event_id, tick, _admission.actor_id,
		preflight_payload, _raid_generation):
		return _reject(_authority.last_error)
	var metadata := _hitbox_world.snapshot_metadata(_hitbox_capability)
	if metadata.is_empty() \
			or int(metadata.get("binding_token", 0)) != _hitbox_binding_token \
			or int(metadata.get("tick", -1)) != tick \
			or int(metadata.get("world_revision", 0)) <= 0:
		return _reject(&"hitbox_snapshot_stale")
	if int(metadata.get("query_result_count", -1)) \
			>= BodyHitboxWorld2D.MAX_QUERY_RESULTS:
		return _reject(&"hitbox_query_capacity_exceeded")
	var geometry := _shot_geometry(shot)
	if geometry.is_empty():
		return false
	var query := {
		"request_id": request_id.canonical_key(),
		"raid_id": _admission.raid_id.canonical_key(),
		"session_id": _admission.session_id.canonical_key(),
		"authority_epoch": _admission.authority_epoch,
		"authority_generation": _raid_generation,
		"binding_token": _hitbox_binding_token,
		"owner_actor_id": _admission.actor_id.canonical_key(),
		"owner_actor_source": int(ZRaidIntent.Source.PLAYER),
		"query_actor_id": _admission.actor_id.canonical_key(),
		"query_actor_source": int(ZRaidIntent.Source.PLAYER),
		"tick": tick,
		"world_revision": int(metadata["world_revision"]),
		"origin_raw": geometry["origin_raw"],
		"target_raw": geometry["target_raw"],
		"body_mask": _body_mask,
		"obstruction_mask": _obstruction_mask,
		"excluded_entity_ids": [_admission.actor_id.canonical_key()],
	}
	var world_result := _hitbox_world.raycast(query, _hitbox_capability)
	if not bool(world_result.get("accepted", false)):
		return _reject(StringName(world_result.get("reason", &"world_query_failed")))
	if bool(world_result.get("duplicate", false)):
		return _reject(&"world_query_identity_collision")
	var consequence := _build_consequence(
		entry, event_id.canonical_key(), world_result)
	if consequence.is_empty():
		return false
	if not _authority.record_event(
		ZRaidEvent.EventKind.HIT, event_id, tick, _admission.actor_id,
		consequence, _raid_generation):
		return _reject(_authority.last_error)
	_resolved_by_identity[identity] = {
		"fingerprint": fingerprint,
		"result": consequence.duplicate(true),
	}
	_last_result = consequence.duplicate(true)
	var publication := _read_only_copy(consequence)
	_public_signal_active = true
	consequence_committed.emit(publication)
	_public_signal_active = false
	return true


func _build_consequence(
	entry: Dictionary,
	event_id: String,
	world_result: Dictionary
) -> Dictionary:
	var shot := entry["shot"] as Dictionary
	var is_hit := bool(world_result.get("hit", false))
	var is_blocked := bool(world_result.get("blocked", false))
	var result := {
		"schema": CONSEQUENCE_SCHEMA,
		"accepted": true,
		"consequence_id": event_id,
		"weapon_consequence_id": String(entry["shot_identity"]),
		"raid_id": _admission.raid_id.canonical_key(),
		"session_id": _admission.session_id.canonical_key(),
		"authority_epoch": _admission.authority_epoch,
		"authority_generation": _raid_generation,
		"binding_generation": _binding_generation,
		"weapon_context_binding_generation": _weapon_context_binding_generation,
		"actor_id": _admission.actor_id.canonical_key(),
		"actor_source": int(ZRaidIntent.Source.PLAYER),
		"weapon_instance_id": String(shot["instance_id"]),
		"weapon_entity_id": String(entry["weapon_entity_id"]),
		"weapon_binding_generation": int(entry["weapon_binding_generation"]),
		"weapon_id": String(shot["weapon_id"]),
		"weapon_version": int(shot["weapon_version"]),
		"weapon_revision": int(entry["revision"]),
		"loaded_rounds_after_commit": int(entry["loaded_rounds"]),
		"tick": int(shot["tick"]),
		"damage_milliunits": int(shot["damage_milliunits"]),
		"consumed_profile": (shot["consumed_profile"] as Dictionary).duplicate(true),
		"outcome": &"hit" if is_hit else &"miss",
		"miss_reason": &"" if is_hit else (&"occluded" if is_blocked else &"clear"),
		"hit": is_hit,
		"blocked": is_blocked,
		"entity_id": String(world_result.get("entity_id", "")),
		"body_revision": int(world_result.get("body_revision", 0)),
		"profile_id": String(world_result.get("profile_id", "")),
		"hitbox_id": String(world_result.get("hitbox_id", "")),
		"body_zone": StringName(world_result.get("body_zone", &"")),
		"anatomy_group": StringName(world_result.get("anatomy_group", &"")),
		"obstruction_id": String(world_result.get("obstruction_id", "")),
		"hit_point_raw": world_result.get("hit_point_raw", Vector2i.ZERO),
		"ray_fraction_numerator": int(world_result.get("ray_fraction_numerator", -1)),
		"ray_fraction_denominator": int(world_result.get("ray_fraction_denominator", 1)),
		"world_revision": int(world_result.get("world_revision", 0)),
		"world_snapshot_digest": String(world_result.get("snapshot_digest", "")),
		"world_resolution_digest": String(world_result.get("resolution_digest", "")),
	}
	var digest := ZCanonicalValue.sha256(result)
	if digest.is_empty() or not ZCanonicalValue.is_bounded(result):
		last_error = &"consequence_result_invalid"
		return {}
	result["resolution_digest"] = digest
	_make_deep_read_only(result)
	return result


func _normalize_outcome(value: Variant) -> Dictionary:
	last_error = &""
	if typeof(value) != TYPE_DICTIONARY:
		last_error = &"committed_outcome_type_invalid"
		return {}
	var outcome := value as Dictionary
	if not _has_exact_keys(outcome, OUTCOME_KEYS) \
			or typeof(outcome["accepted"]) != TYPE_BOOL \
			or typeof(outcome["replayed"]) != TYPE_BOOL \
			or typeof(outcome["rejection"]) != TYPE_INT \
			or typeof(outcome["status"]) != TYPE_DICTIONARY \
			or typeof(outcome["revision"]) != TYPE_INT \
			or typeof(outcome["loaded_rounds"]) != TYPE_INT \
			or not _is_text(outcome["reservation_to_release"]) \
			or typeof(outcome["shot"]) != TYPE_DICTIONARY:
		last_error = &"committed_outcome_schema_invalid"
		return {}
	if not bool(outcome["accepted"]) or int(outcome["rejection"]) != 0 \
			or int(outcome["revision"]) <= 0 \
			or int(outcome["loaded_rounds"]) < 0 \
			or not String(outcome["reservation_to_release"]).is_empty():
		last_error = &"committed_outcome_not_accepted_fire"
		return {}
	var shot_source := outcome["shot"] as Dictionary
	if not _has_exact_keys(shot_source, SHOT_KEYS):
		last_error = &"committed_shot_schema_invalid"
		return {}
	for key in ["consequence_id", "instance_id", "weapon_id"]:
		if not _is_text(shot_source[key]):
			last_error = &"committed_shot_field_type_invalid"
			return {}
	if typeof(shot_source["weapon_version"]) != TYPE_INT \
			or typeof(shot_source["tick"]) != TYPE_INT \
			or typeof(shot_source["origin"]) != TYPE_DICTIONARY \
			or typeof(shot_source["direction"]) != TYPE_DICTIONARY \
			or typeof(shot_source["damage_milliunits"]) != TYPE_INT \
			or typeof(shot_source["range_milliunits"]) != TYPE_INT \
			or typeof(shot_source["noise_radius_milliunits"]) != TYPE_INT \
			or typeof(shot_source["consumed_profile"]) != TYPE_DICTIONARY:
		last_error = &"committed_shot_field_type_invalid"
		return {}
	var identity := String(shot_source["consequence_id"])
	if identity.is_empty() or identity.to_utf8_buffer().size() > MAX_IDENTIFIER_BYTES \
			or String(shot_source["instance_id"]).is_empty() \
			or String(shot_source["instance_id"]).to_utf8_buffer().size() \
				> MAX_IDENTIFIER_BYTES \
			or StringName(shot_source["weapon_id"]) != ZerkovCombatContent.WEAPON_AKM \
			or int(shot_source["weapon_version"]) != ZerkovCombatContent.CONTENT_VERSION \
			or int(shot_source["tick"]) <= 0 \
			or int(shot_source["damage_milliunits"]) < 0 \
			or int(shot_source["damage_milliunits"]) > MAX_DAMAGE_MILLIUNITS \
			or int(shot_source["range_milliunits"]) <= 0 \
			or int(shot_source["range_milliunits"]) > MAX_RANGE_MILLIUNITS \
			or int(shot_source["noise_radius_milliunits"]) < 0 \
			or int(shot_source["noise_radius_milliunits"]) > MAX_NOISE_MILLIUNITS:
		last_error = &"committed_shot_value_invalid"
		return {}
	var origin := _normalize_vector(shot_source["origin"] as Dictionary)
	var direction := _normalize_vector(shot_source["direction"] as Dictionary)
	if origin.is_empty() or direction.is_empty() \
			or direction == {"x": 0, "y": 0} \
			or absi(int(direction["x"])) > ZWorldUnits.WEAPON_DIRECTION_SCALE \
			or absi(int(direction["y"])) > ZWorldUnits.WEAPON_DIRECTION_SCALE:
		last_error = &"committed_shot_vector_invalid"
		return {}
	var profile_source := shot_source["consumed_profile"] as Dictionary
	if not _has_exact_keys(profile_source, PROFILE_KEYS) \
			or typeof(profile_source["has_profile"]) != TYPE_BOOL \
			or not _is_text(profile_source["id"]) \
			or typeof(profile_source["version"]) != TYPE_INT \
			or not bool(profile_source["has_profile"]) \
			or StringName(profile_source["id"]) \
				!= ZerkovCombatContent.AMMO_PROFILE_762X39_STANDARD \
			or int(profile_source["version"]) != ZerkovCombatContent.CONTENT_VERSION:
		last_error = &"committed_shot_profile_invalid"
		return {}
	var shot := shot_source.duplicate(true)
	shot["origin"] = origin
	shot["direction"] = direction
	shot["consumed_profile"] = profile_source.duplicate(true)
	var fingerprint := ZCanonicalValue.sha256({
		"revision": int(outcome["revision"]),
		"loaded_rounds": int(outcome["loaded_rounds"]),
		"shot": shot,
	})
	if fingerprint.is_empty():
		last_error = &"committed_shot_fingerprint_invalid"
		return {}
	return {
		"accepted": true,
		"replayed": bool(outcome["replayed"]),
		"revision": int(outcome["revision"]),
		"loaded_rounds": int(outcome["loaded_rounds"]),
		"tick": int(shot["tick"]),
		"shot_identity": identity,
		"fingerprint": fingerprint,
		"shot": shot,
	}


func _normalize_vector(value: Dictionary) -> Dictionary:
	if not _has_exact_keys(value, VECTOR_KEYS) \
			or typeof(value["x"]) != TYPE_INT \
			or typeof(value["y"]) != TYPE_INT:
		return {}
	return {"x": int(value["x"]), "y": int(value["y"])}


func _shot_geometry(shot: Dictionary) -> Dictionary:
	var origin := shot["origin"] as Dictionary
	var direction := shot["direction"] as Dictionary
	var range_milliunits := int(shot["range_milliunits"])
	var origin_raw := Vector2i(
		int(origin["x"]) * 1000,
		int(origin["y"]) * 1000)
	var target_raw := Vector2i(
		origin_raw.x + _divide_round_half_away(
			int(direction["x"]) * range_milliunits, 1000),
		origin_raw.y + _divide_round_half_away(
			int(direction["y"]) * range_milliunits, 1000))
	if not _point_is_hitbox_bounded(origin_raw) \
			or not _point_is_hitbox_bounded(target_raw) \
			or origin_raw == target_raw:
		last_error = &"committed_shot_geometry_out_of_range"
		return {}
	return {"origin_raw": origin_raw, "target_raw": target_raw}


func _stable_ids_for_shot(shot_identity: String) -> Dictionary:
	var digest := ZCanonicalValue.sha256({
		"domain": "weapon_shot",
		"weapon_consequence_id": shot_identity,
	})
	if digest.length() != 64:
		return {}
	var parts := PackedStringArray([
		"weapon_shot", digest.substr(0, 32), digest.substr(32, 32),
	])
	var event_id := ZConsequenceId.from_parts(parts)
	var request_id := ZRequestId.from_parts(parts)
	if event_id == null or request_id == null:
		return {}
	return {
		"event_id": event_id.canonical_key(),
		"request_id": request_id.canonical_key(),
	}


func _reserve_stable_ids(
	shot_identity: String,
	fingerprint: String,
	ids: Dictionary
) -> StringName:
	var event_id := String(ids.get("event_id", ""))
	var request_id := String(ids.get("request_id", ""))
	for row in [
		[_reserved_event_ids, event_id, &"consequence_id_collision"],
		[_reserved_request_ids, request_id, &"query_id_collision"],
	]:
		var ledger := row[0] as Dictionary
		var key := String(row[1])
		if ledger.has(key):
			var previous := ledger[key] as Dictionary
			if String(previous.get("shot_identity", "")) != shot_identity \
					or String(previous.get("fingerprint", "")) != fingerprint:
				return StringName(row[2])
	_reserved_event_ids[event_id] = {
		"shot_identity": shot_identity, "fingerprint": fingerprint}
	_reserved_request_ids[request_id] = {
		"shot_identity": shot_identity, "fingerprint": fingerprint}
	return &""


func _current_weapon_record(weapon_id: String) -> Dictionary:
	for record_value in _weapon_context.instance_records():
		var record := record_value as Dictionary
		if String(record.get("weapon_id", "")) == weapon_id:
			return record.duplicate(true)
	return {}


func _binding_is_current() -> bool:
	if _authority == null or not is_instance_valid(_authority) \
			or _authority.get_instance_id() != _authority_instance_id \
			or _authority.generation() != _raid_generation \
			or _authority.lifecycle == RaidAuthority.Lifecycle.TORN_DOWN \
			or _admission == null or not _admission.is_usable() \
			or _weapon_authority == null or not is_instance_valid(_weapon_authority) \
			or _weapon_authority.get_instance_id() != _weapon_authority_instance_id \
			or _weapon_context == null or not is_instance_valid(_weapon_context) \
			or _weapon_context.get_instance_id() != _weapon_context_instance_id \
			or _hitbox_world == null or not is_instance_valid(_hitbox_world) \
			or _hitbox_world.get_instance_id() != _hitbox_world_instance_id:
		return false
	if not _weapon_context.authenticates_combat_binding(
		_authority, _weapon_authority, _admission.actor_id,
		ZRaidIntent.Source.PLAYER, _weapon_context_binding_generation):
		return false
	var current_admission := _authority.admission()
	if current_admission == null \
			or not current_admission.raid_id.is_equal(_admission.raid_id) \
			or not current_admission.session_id.is_equal(_admission.session_id) \
			or not current_admission.actor_id.is_equal(_admission.actor_id) \
			or current_admission.authority_epoch != _admission.authority_epoch \
			or current_admission.generation != _admission.generation:
		return false
	var provenance := _hitbox_world.binding_provenance(_hitbox_capability)
	return not provenance.is_empty() \
		and int(provenance.get("binding_token", 0)) == _hitbox_binding_token \
		and int(provenance.get("authority_generation", 0)) == _raid_generation \
		and String(provenance.get("raid_id", "")) == _admission.raid_id.canonical_key() \
		and String(provenance.get("session_id", "")) \
			== _admission.session_id.canonical_key() \
		and String(provenance.get("owner_actor_id", "")) \
			== _admission.actor_id.canonical_key() \
		and int(provenance.get("owner_actor_source", -1)) \
			== int(ZRaidIntent.Source.PLAYER)


func _on_weapon_context_invalidated(
	reason: StringName,
	expected_binding_generation: int
) -> void:
	if lifecycle != Lifecycle.BOUND \
			or expected_binding_generation != _binding_generation:
		return
	_disconnect_shot_signal()
	lifecycle = Lifecycle.INVALIDATED
	_fatal_error = reason if not reason.is_empty() else &"weapon_context_invalidated"
	last_error = _fatal_error
	_public_signal_active = true
	binding_invalidated.emit(_fatal_error)
	_public_signal_active = false


func _latch_fatal(reason: StringName) -> Dictionary:
	var effective := reason if not reason.is_empty() else &"combat_adapter_failure"
	if _fatal_error.is_empty():
		_fatal_error = effective
	last_error = _fatal_error
	return _rejection(_fatal_error)


func _rejection(reason: StringName, shot_identity: String = "") -> Dictionary:
	last_error = reason
	return _read_only_copy({
		"accepted": false,
		"reason": reason,
		"shot_identity": shot_identity,
	})


func _disconnect_dependencies() -> void:
	_disconnect_shot_signal()
	if _weapon_context != null and is_instance_valid(_weapon_context) \
			and _context_invalidated_callback.is_valid() \
			and _weapon_context.binding_invalidated.is_connected(
				_context_invalidated_callback):
		_weapon_context.binding_invalidated.disconnect(_context_invalidated_callback)
	_context_invalidated_callback = Callable()


func _disconnect_shot_signal() -> void:
	if _weapon_authority != null and is_instance_valid(_weapon_authority) \
			and _shot_callback.is_valid() \
			and _weapon_authority.shot_committed.is_connected(_shot_callback):
		_weapon_authority.shot_committed.disconnect(_shot_callback)
	_shot_callback = Callable()


func _reset_runtime_state() -> void:
	_disconnect_dependencies()
	_authority = null
	_authority_instance_id = 0
	_raid_generation = 0
	_admission = null
	_weapon_authority = null
	_weapon_authority_instance_id = 0
	_weapon_context = null
	_weapon_context_instance_id = 0
	_weapon_context_binding_generation = 0
	_hitbox_world = null
	_hitbox_world_instance_id = 0
	_hitbox_capability = null
	_hitbox_binding_token = 0
	_body_mask = 0
	_obstruction_mask = 0
	_phase_registered = false
	_pending_order.clear()
	_pending_by_identity.clear()
	_resolved_by_identity.clear()
	_reserved_event_ids.clear()
	_reserved_request_ids.clear()
	_last_result.clear()
	_fatal_error = &""
	_public_signal_active = false


func _has_exact_keys(value: Dictionary, expected: PackedStringArray) -> bool:
	if value.size() != expected.size():
		return false
	var actual := PackedStringArray()
	for key in value:
		if typeof(key) != TYPE_STRING and typeof(key) != TYPE_STRING_NAME:
			return false
		actual.append(String(key))
	actual.sort()
	var sorted_expected := PackedStringArray(expected)
	sorted_expected.sort()
	return actual == sorted_expected


func _is_text(value: Variant) -> bool:
	return typeof(value) == TYPE_STRING or typeof(value) == TYPE_STRING_NAME


func _point_is_hitbox_bounded(value: Vector2i) -> bool:
	return absi(value.x) <= BodyHitboxWorld2D.MAX_COORDINATE_RAW \
		and absi(value.y) <= BodyHitboxWorld2D.MAX_COORDINATE_RAW


func _divide_round_half_away(numerator: int, denominator: int) -> int:
	var sign_value := -1 if numerator < 0 else 1
	var magnitude := absi(numerator)
	var quotient := magnitude / denominator
	if (magnitude % denominator) * 2 >= denominator:
		quotient += 1
	return quotient * sign_value


func _read_only_copy(value: Dictionary) -> Dictionary:
	var result := value.duplicate(true)
	_make_deep_read_only(result)
	return result


func _make_deep_read_only(value: Variant) -> void:
	if value is Dictionary:
		var dictionary := value as Dictionary
		for child in dictionary.values():
			_make_deep_read_only(child)
		dictionary.make_read_only()
	elif value is Array:
		var array := value as Array
		for child in array:
			_make_deep_read_only(child)
		array.make_read_only()


func _reject(reason: StringName) -> bool:
	last_error = reason
	return false


func _exit_tree() -> void:
	if lifecycle == Lifecycle.BOUND or lifecycle == Lifecycle.INVALIDATED:
		if not _public_signal_active:
			release_binding(&"teardown")
		else:
			_disconnect_dependencies()
