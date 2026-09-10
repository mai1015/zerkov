#include "core/wpn_runtime.h"

#include "core/wpn_checked_math.h"
#include "core/wpn_hash.h"
#include "core/wpn_identifier.h"
#include "core/wpn_limits.h"
#include "core/wpn_numerics.h"

#include <algorithm>
#include <cstdlib>
#include <limits>
#include <set>

namespace wpn {

namespace {

std::int64_t scale_value(std::int64_t p_value, std::int64_t p_ppm) {
	return (p_value * p_ppm) / 1000000;
}

std::int64_t clamp_i64(std::int64_t p_value, std::int64_t p_min, std::int64_t p_max) {
	if (p_value < p_min) return p_min;
	if (p_value > p_max) return p_max;
	return p_value;
}

std::uint64_t fire_payload_hash(const FireCommand &p_command) {
	Hasher h;
	h.write_string("fire");
	h.write_string(p_command.command_id);
	h.write_u64(p_command.sequence);
	h.write_string(p_command.instance_id);
	h.write_u64(p_command.expected_revision);
	h.write_u64(p_command.tick);
	h.write_string(p_command.authority_scope);
	h.write_u64(p_command.authority_epoch);
	h.write_i64(p_command.claimed_origin.x);
	h.write_i64(p_command.claimed_origin.y);
	h.write_i64(p_command.claimed_aim.x);
	h.write_i64(p_command.claimed_aim.y);
	h.write_u64(p_command.spread_seed);
	return h.digest();
}

std::uint64_t begin_reload_payload_hash(const BeginReloadCommand &p_command) {
	Hasher h;
	h.write_string("begin_reload");
	h.write_string(p_command.command_id);
	h.write_u64(p_command.sequence);
	h.write_string(p_command.instance_id);
	h.write_u64(p_command.expected_revision);
	h.write_u64(p_command.tick);
	h.write_string(p_command.authority_scope);
	h.write_u64(p_command.authority_epoch);
	h.write_string(p_command.reservation_id);
	h.write_u32(p_command.reserved_rounds);
	h.write_string(p_command.profile.id);
	h.write_u16(p_command.profile.version);
	return h.digest();
}

std::uint64_t cancel_reload_payload_hash(const CancelReloadCommand &p_command) {
	Hasher h;
	h.write_string("cancel_reload");
	h.write_string(p_command.command_id);
	h.write_u64(p_command.sequence);
	h.write_string(p_command.instance_id);
	h.write_u64(p_command.expected_revision);
	h.write_u64(p_command.tick);
	h.write_string(p_command.authority_scope);
	h.write_u64(p_command.authority_epoch);
	return h.digest();
}

std::uint64_t configure_attachments_payload_hash(const ConfigureAttachmentsCommand &p_command) {
	Hasher h;
	h.write_string("configure_attachments");
	h.write_string(p_command.command_id);
	h.write_u64(p_command.sequence);
	h.write_string(p_command.instance_id);
	h.write_u64(p_command.expected_revision);
	h.write_u64(p_command.tick);
	h.write_string(p_command.authority_scope);
	h.write_u64(p_command.authority_epoch);
	h.write_u32(static_cast<std::uint32_t>(p_command.desired_loadout.size()));
	for (const AttachmentLoadoutEntry &entry : p_command.desired_loadout) {
		h.write_string(entry.slot_id);
		h.write_string(entry.attachment_id);
		h.write_u16(entry.attachment_version);
	}
	return h.digest();
}

std::uint64_t teardown_payload_hash(const TeardownCommand &p_command) {
	Hasher h;
	h.write_string("teardown");
	h.write_string(p_command.command_id);
	h.write_u64(p_command.sequence);
	h.write_string(p_command.instance_id);
	h.write_u64(p_command.expected_revision);
	h.write_u64(p_command.tick);
	h.write_string(p_command.authority_scope);
	h.write_u64(p_command.authority_epoch);
	return h.digest();
}

bool valid_modifier(std::int64_t p_value) {
	return p_value >= 0 && p_value <= 4000000;
}

} // namespace

std::uint64_t WeaponSnapshot::fingerprint() const {
	Hasher h;
	h.write_string(instance_id);
	h.write_string(definition_id);
	h.write_u16(definition_version);
	h.write_u64(revision);
	h.write_bool(has_last_command_sequence);
	if (has_last_command_sequence) h.write_u64(last_command_sequence);
	h.write_u32(loaded_rounds);
	h.write_bool(loaded_profile.has_value());
	if (loaded_profile.has_value()) {
		h.write_string(loaded_profile->id);
		h.write_u16(loaded_profile->version);
	}
	h.write_bool(has_last_fire_tick);
	if (has_last_fire_tick) h.write_u64(last_fire_tick);
	h.write_u8(static_cast<std::uint8_t>(phase));
	h.write_bool(reload.has_value());
	if (reload.has_value()) {
		h.write_string(reload->reservation_id);
		h.write_u32(reload->reserved_rounds);
		h.write_u64(reload->start_tick);
		h.write_u64(reload->due_tick);
		h.write_string(reload->reserved_profile.id);
		h.write_u16(reload->reserved_profile.version);
	}
	h.write_string(authority_scope);
	h.write_u64(authority_epoch);
	h.write_u64(authority_tick_floor);
	h.write_u64(admitted_sequence_high_watermark);
	h.write_bool(tick_unhealthy);
	h.write_i64(recoil_vertical_offset_nrad);
	h.write_i64(recoil_horizontal_offset_nrad);
	h.write_u64(recoil_anchor_tick);
	h.write_u32(static_cast<std::uint32_t>(attachment_loadout.size()));
	for (const AttachmentLoadoutEntry &entry : attachment_loadout) {
		h.write_string(entry.slot_id);
		h.write_string(entry.attachment_id);
		h.write_u16(entry.attachment_version);
	}
	return h.digest();
}

std::uint64_t WeaponSnapshot::mechanical_fingerprint() const {
	Hasher h;
	h.write_string(instance_id);
	h.write_string(definition_id);
	h.write_u16(definition_version);
	h.write_u64(revision);
	h.write_bool(has_last_command_sequence);
	if (has_last_command_sequence) h.write_u64(last_command_sequence);
	h.write_u32(loaded_rounds);
	h.write_bool(loaded_profile.has_value());
	if (loaded_profile.has_value()) {
		h.write_string(loaded_profile->id);
		h.write_u16(loaded_profile->version);
	}
	h.write_bool(has_last_fire_tick);
	if (has_last_fire_tick) h.write_u64(last_fire_tick);
	h.write_u8(static_cast<std::uint8_t>(phase));
	h.write_bool(reload.has_value());
	if (reload.has_value()) {
		h.write_string(reload->reservation_id);
		h.write_u32(reload->reserved_rounds);
		h.write_u64(reload->start_tick);
		h.write_u64(reload->due_tick);
		h.write_string(reload->reserved_profile.id);
		h.write_u16(reload->reserved_profile.version);
	}
	h.write_i64(recoil_vertical_offset_nrad);
	h.write_i64(recoil_horizontal_offset_nrad);
	h.write_u64(recoil_anchor_tick);
	h.write_u32(static_cast<std::uint32_t>(attachment_loadout.size()));
	for (const AttachmentLoadoutEntry &entry : attachment_loadout) {
		h.write_string(entry.slot_id);
		h.write_string(entry.attachment_id);
		h.write_u16(entry.attachment_version);
	}
	return h.digest();
}

bool WeaponSnapshot::operator==(const WeaponSnapshot &p_other) const {
	return instance_id == p_other.instance_id &&
			definition_id == p_other.definition_id &&
			definition_version == p_other.definition_version &&
			revision == p_other.revision &&
			has_last_command_sequence == p_other.has_last_command_sequence &&
			(!has_last_command_sequence || last_command_sequence == p_other.last_command_sequence) &&
			loaded_rounds == p_other.loaded_rounds &&
			loaded_profile == p_other.loaded_profile &&
			has_last_fire_tick == p_other.has_last_fire_tick &&
			(!has_last_fire_tick || last_fire_tick == p_other.last_fire_tick) &&
			phase == p_other.phase &&
			reload == p_other.reload &&
			authority_scope == p_other.authority_scope &&
			authority_epoch == p_other.authority_epoch &&
			authority_tick_floor == p_other.authority_tick_floor &&
			admitted_sequence_high_watermark == p_other.admitted_sequence_high_watermark &&
			tick_unhealthy == p_other.tick_unhealthy &&
			recoil_vertical_offset_nrad == p_other.recoil_vertical_offset_nrad &&
			recoil_horizontal_offset_nrad == p_other.recoil_horizontal_offset_nrad &&
			recoil_anchor_tick == p_other.recoil_anchor_tick &&
			attachment_loadout == p_other.attachment_loadout;
}

std::uint64_t ConsequenceIdentity::compact_hash() const {
	Hasher h;
	h.write_u16(version);
	h.write_u32(domain);
	h.write_string(authority_scope);
	h.write_u64(authority_epoch);
	h.write_string(instance_id);
	h.write_u64(successor_revision);
	h.write_string(command_id);
	return h.digest();
}

bool CommandOutcome::operator==(const CommandOutcome &p_other) const {
	return accepted == p_other.accepted && rejection == p_other.rejection &&
			status == p_other.status && revision == p_other.revision &&
			loaded_rounds == p_other.loaded_rounds &&
			shot.has_value() == p_other.shot.has_value() &&
			reservation_to_release == p_other.reservation_to_release;
}

Status WeaponRuntime::create_instance(
		const std::string &p_instance_id,
		const std::string &p_definition_id,
		std::uint16_t p_definition_version,
		std::uint32_t p_loaded_rounds,
		const std::optional<BallisticProfileIdentity> &p_profile,
		const std::string &p_authority_scope,
		std::uint64_t p_authority_epoch) {
	if (!catalog.sealed()) return make_status(StatusCode::CATALOG_NOT_SEALED, DiagnosticId::CATALOG_REQUIRES_SEAL);
	Status status = validate_identifier(p_instance_id);
	if (!status.ok()) return status;
	if (instances.size() >= MAX_WEAPON_INSTANCES) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, instances.size() + 1);
	}
	const WeaponDefinition *definition = catalog.find_weapon(p_definition_id, p_definition_version);
	if (definition == nullptr) return make_status(StatusCode::UNKNOWN_DEFINITION, DiagnosticId::DEFINITION_UNKNOWN_REFERENCE);
	if (p_loaded_rounds > definition->capacity) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_OUT_OF_RANGE, p_loaded_rounds);
	}
	// Ballistic-profile identity invariant (weapon-runtime spec,
	// "Deterministic Weapon Instance State"): present exactly when loaded
	// rounds are positive.
	if (p_loaded_rounds > 0) {
		if (!p_profile.has_value()) {
			return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::PROFILE_REQUIRED);
		}
		status = validate_identifier(p_profile->id);
		if (!status.ok()) return status;
		if (p_profile->version == 0) return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_OUT_OF_RANGE);
		const AmmunitionBallisticProfile *profile_def = catalog.find_ammo_profile(p_profile->id, p_profile->version);
		if (profile_def == nullptr) return make_status(StatusCode::UNKNOWN_DEFINITION, DiagnosticId::PROFILE_UNKNOWN_REFERENCE);
		if (profile_def->ammunition_trait != definition->ammunition_trait) {
			return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::PROFILE_TRAIT_MISMATCH);
		}
	} else if (p_profile.has_value()) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::PROFILE_MUST_BE_ABSENT);
	}
	WeaponSnapshot state;
	state.instance_id = p_instance_id;
	state.definition_id = p_definition_id;
	state.definition_version = p_definition_version;
	state.loaded_rounds = p_loaded_rounds;
	state.loaded_profile = p_loaded_rounds > 0 ? p_profile : std::nullopt;
	state.authority_scope = p_authority_scope;
	state.authority_epoch = p_authority_epoch;
	if (!instances.emplace(p_instance_id, state).second) {
		return make_status(StatusCode::ALREADY_EXISTS, DiagnosticId::INSTANCE_DUPLICATE);
	}
	return ok_status();
}

Status WeaponRuntime::remove_instance(const std::string &p_instance_id, std::optional<std::string> &r_reservation_to_release) {
	r_reservation_to_release.reset();
	auto found = instances.find(p_instance_id);
	if (found == instances.end()) return make_status(StatusCode::NOT_FOUND, DiagnosticId::INSTANCE_UNKNOWN);
	if (found->second.reload.has_value()) r_reservation_to_release = found->second.reload->reservation_id;
	instances.erase(found);
	return ok_status();
}

const WeaponSnapshot *WeaponRuntime::find_instance(const std::string &p_instance_id) const {
	auto found = instances.find(p_instance_id);
	return found == instances.end() ? nullptr : &found->second;
}

const WeaponTombstone *WeaponRuntime::find_tombstone(const std::string &p_instance_id) const {
	auto found = tombstones.find(p_instance_id);
	return found == tombstones.end() ? nullptr : &found->second;
}

std::vector<WeaponSnapshot> WeaponRuntime::snapshots() const {
	std::vector<WeaponSnapshot> result;
	result.reserve(instances.size());
	for (const auto &entry : instances) result.push_back(entry.second);
	return result;
}

Status WeaponRuntime::replace_from_snapshots(const std::vector<WeaponSnapshot> &p_snapshots) {
	if (p_snapshots.size() > MAX_WEAPON_INSTANCES) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, p_snapshots.size());
	}
	std::map<std::string, WeaponSnapshot> replacement;
	for (const WeaponSnapshot &state : p_snapshots) {
		Status status = validate_identifier(state.instance_id);
		if (!status.ok()) return status;
		const WeaponDefinition *definition = catalog.find_weapon(state.definition_id, state.definition_version);
		if (definition == nullptr) return make_status(StatusCode::UNKNOWN_DEFINITION, DiagnosticId::DEFINITION_UNKNOWN_REFERENCE);
		if (state.loaded_rounds > definition->capacity ||
				(state.phase == WeaponPhase::RELOADING) != state.reload.has_value()) {
			return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_OUT_OF_RANGE);
		}
		if (state.loaded_rounds > 0 && !state.loaded_profile.has_value()) {
			return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::PROFILE_REQUIRED);
		}
		if (state.loaded_rounds == 0 && state.loaded_profile.has_value()) {
			return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::PROFILE_MUST_BE_ABSENT);
		}
		if (state.attachment_loadout.size() > MAX_ATTACHMENT_SLOTS_PER_WEAPON) {
			return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, state.attachment_loadout.size());
		}
		if (!replacement.emplace(state.instance_id, state).second) {
			return make_status(StatusCode::ALREADY_EXISTS, DiagnosticId::INSTANCE_DUPLICATE);
		}
	}
	instances = std::move(replacement);
	command_history.clear();
	command_order.clear();
	// A trusted replacement snapshot is exactly the recovery/resync point for
	// in-flight reload-completion bookkeeping tied to the old instance set
	// (weapon-runtime spec, "Canonical Revision and Authority-Tick
	// Semantics": tick-arithmetic-fault recovery starts a new epoch via a
	// trusted replacement snapshot).
	reload_participants.clear();
	reload_participant_terminal_order.clear();
	return ok_status();
}

std::optional<CommandOutcome> WeaponRuntime::replay_or_conflict(const std::string &p_command_id, std::uint64_t p_payload_hash) const {
	auto found = command_history.find(p_command_id);
	if (found == command_history.end()) return std::nullopt;
	if (found->second.payload_hash != p_payload_hash) {
		CommandOutcome conflict;
		conflict.rejection = Rejection::DUPLICATE_CONFLICT;
		conflict.status = make_status(StatusCode::DUPLICATE_CONFLICT, DiagnosticId::COMMAND_DUPLICATE_CONFLICT);
		return conflict;
	}
	CommandOutcome replay = found->second.outcome;
	replay.replayed = true;
	return replay;
}

void WeaponRuntime::record_command(const std::string &p_command_id, std::uint64_t p_payload_hash, const CommandOutcome &p_outcome) {
	if (command_history.find(p_command_id) != command_history.end()) return;
	while (command_history.size() >= MAX_IDEMPOTENCY_RECORDS && !command_order.empty()) {
		command_history.erase(command_order.front());
		command_order.pop_front();
	}
	command_order.push_back(p_command_id);
	command_history.emplace(p_command_id, RecordedCommand{ p_payload_hash, p_outcome });
}

CommandOutcome WeaponRuntime::rejected(const WeaponSnapshot *p_state, Rejection p_rejection, DiagnosticId p_diagnostic) const {
	CommandOutcome outcome;
	outcome.rejection = p_rejection;
	outcome.status = make_status(StatusCode::COMMAND_REJECTED, p_diagnostic);
	if (p_state != nullptr) {
		outcome.revision = p_state->revision;
		outcome.loaded_rounds = p_state->loaded_rounds;
	}
	return outcome;
}

const WeaponDefinition *WeaponRuntime::definition_for(const WeaponSnapshot &p_state) const {
	return catalog.find_weapon(p_state.definition_id, p_state.definition_version);
}

bool WeaponRuntime::valid_fixed_vector(const FixedVec2 &p_value, std::int64_t p_limit, bool p_allow_zero) {
	if (p_value.x < -p_limit || p_value.x > p_limit || p_value.y < -p_limit || p_value.y > p_limit) return false;
	return p_allow_zero || p_value.x != 0 || p_value.y != 0;
}

bool WeaponRuntime::origin_compatible(const FixedVec2 &p_claimed, const FixedVec2 &p_authoritative, std::int64_t p_tolerance) {
	const std::int64_t dx = p_claimed.x - p_authoritative.x;
	const std::int64_t dy = p_claimed.y - p_authoritative.y;
	return dx * dx + dy * dy <= p_tolerance * p_tolerance;
}

bool WeaponRuntime::aim_compatible(const FixedVec2 &p_claimed, const FixedVec2 &p_authoritative, std::int64_t p_tolerance_microradians) {
	const std::int64_t dot = p_claimed.x * p_authoritative.x + p_claimed.y * p_authoritative.y;
	if (dot <= 0) return false;
	const std::int64_t cross = p_claimed.x * p_authoritative.y - p_claimed.y * p_authoritative.x;
	const std::uint64_t abs_cross = static_cast<std::uint64_t>(cross < 0 ? -cross : cross);
	const std::uint64_t allowed = (static_cast<std::uint64_t>(p_tolerance_microradians) *
			static_cast<std::uint64_t>(dot)) / 1000000ULL;
	return abs_cross <= allowed;
}

// --- Shared Authoritative Command Gate (tasks.md 4.13) ---------------------

bool WeaponRuntime::admit(
		const std::string &p_command_id,
		std::uint64_t p_sequence,
		const std::string &p_instance_id,
		std::uint64_t p_authority_tick,
		const std::string &p_authority_scope,
		std::uint64_t p_authority_epoch,
		std::uint64_t p_payload_hash,
		bool p_structurally_valid,
		WeaponSnapshot *&r_state,
		CommandOutcome &r_outcome) {
	r_state = nullptr;

	// Idempotency lookup by command identity, independent of instance/scope.
	if (auto replay = replay_or_conflict(p_command_id, p_payload_hash)) {
		r_outcome = *replay;
		return false;
	}

	auto found = instances.find(p_instance_id);
	if (found == instances.end()) {
		const bool tombstoned = tombstones.find(p_instance_id) != tombstones.end();
		r_outcome = rejected(nullptr, Rejection::UNKNOWN_INSTANCE,
				tombstoned ? DiagnosticId::TOMBSTONED_INSTANCE : DiagnosticId::INSTANCE_UNKNOWN);
		record_command(p_command_id, p_payload_hash, r_outcome);
		return false;
	}
	WeaponSnapshot &state = found->second;

	if (state.authority_scope != p_authority_scope) {
		r_outcome = rejected(&state, Rejection::AUTHORITY_SCOPE_MISMATCH, DiagnosticId::AUTHORITY_SCOPE_MISMATCH);
		record_command(p_command_id, p_payload_hash, r_outcome);
		return false;
	}
	if (!p_structurally_valid) {
		r_outcome = rejected(&state, Rejection::MALFORMED_COMMAND, DiagnosticId::VALUE_OUT_OF_RANGE);
		record_command(p_command_id, p_payload_hash, r_outcome);
		return false;
	}
	if (state.authority_epoch != p_authority_epoch) {
		r_outcome = rejected(&state, Rejection::AUTHORITY_EPOCH_MISMATCH, DiagnosticId::AUTHORITY_EPOCH_MISMATCH);
		record_command(p_command_id, p_payload_hash, r_outcome);
		return false;
	}
	if (state.tick_unhealthy) {
		r_outcome = rejected(&state, Rejection::RUNTIME_UNHEALTHY, DiagnosticId::RUNTIME_UNHEALTHY);
		r_outcome.status = make_status(StatusCode::UNHEALTHY, DiagnosticId::RUNTIME_UNHEALTHY);
		record_command(p_command_id, p_payload_hash, r_outcome);
		return false;
	}
	// Authority-tick regression: rejected BEFORE sequence admission, and --
	// per weapon-runtime spec's "Authority tick regresses" scenario -- with
	// NO mechanical, sequence, or history-cache mutation whatsoever.
	if (p_authority_tick < state.authority_tick_floor) {
		r_outcome = rejected(&state, Rejection::AUTHORITY_TICK_REGRESSION, DiagnosticId::AUTHORITY_TICK_REGRESSION);
		r_outcome.status = make_status(StatusCode::COMMAND_REJECTED, DiagnosticId::AUTHORITY_TICK_REGRESSION, state.authority_tick_floor);
		return false;
	}
	// Sequence admission against the epoch high-watermark, independent from
	// the bounded outcome cache above: a sequence at or below the watermark
	// whose command identity was not found in that cache (evicted, or never
	// truly submitted before) can never execute.
	if (p_sequence <= state.admitted_sequence_high_watermark) {
		r_outcome = rejected(&state, Rejection::DUPLICATE_OUTCOME_EVICTED, DiagnosticId::DUPLICATE_OUTCOME_EVICTED);
		record_command(p_command_id, p_payload_hash, r_outcome);
		return false;
	}
	// Freshly admitted sequence: advance the watermark and tick floor now,
	// BEFORE any gameplay-specific legality check, so a subsequent
	// deterministic gameplay rejection still counts as admission.
	state.admitted_sequence_high_watermark = p_sequence;
	state.authority_tick_floor = std::max(state.authority_tick_floor, p_authority_tick);
	r_state = &state;
	return true;
}

void WeaponRuntime::collect_attachment_modifier_deltas(const WeaponSnapshot &p_state, AttachmentModifierDeltas &r_deltas) const {
	r_deltas = AttachmentModifierDeltas{};
	for (const AttachmentLoadoutEntry &entry : p_state.attachment_loadout) {
		const AttachmentDefinition *definition = catalog.find_attachment(entry.attachment_id, entry.attachment_version);
		if (definition == nullptr) continue; // Defensive: unreachable for an accepted loadout.
		r_deltas.accuracy.push_back(ModifierDelta{ "attachment", entry.slot_id, entry.attachment_id, entry.attachment_version, definition->accuracy_modifier_ppm });
		r_deltas.recoil.push_back(ModifierDelta{ "attachment", entry.slot_id, entry.attachment_id, entry.attachment_version, definition->recoil_modifier_ppm });
		r_deltas.noise.push_back(ModifierDelta{ "attachment", entry.slot_id, entry.attachment_id, entry.attachment_version, definition->noise_modifier_ppm });
		r_deltas.reload_duration.push_back(ModifierDelta{ "attachment", entry.slot_id, entry.attachment_id, entry.attachment_version, definition->reload_duration_modifier_ppm });
		r_deltas.cadence.push_back(ModifierDelta{ "attachment", entry.slot_id, entry.attachment_id, entry.attachment_version, definition->cadence_modifier_ppm });
	}
}

void WeaponRuntime::insert_tombstone(const std::string &p_instance_id, const std::string &p_scope, std::uint64_t p_epoch, std::uint64_t p_revision) {
	while (tombstones.size() >= MAX_TOMBSTONES && !tombstone_order.empty()) {
		tombstones.erase(tombstone_order.front());
		tombstone_order.pop_front();
	}
	tombstones[p_instance_id] = WeaponTombstone{ p_instance_id, p_scope, p_epoch, p_revision };
	tombstone_order.push_back(p_instance_id);
}

// --- Semi-Automatic Fire Transition (tasks.md 4.9-4.13) --------------------

CommandOutcome WeaponRuntime::fire(const FireCommand &p_command, const AuthorityContext &p_authority) {
	const std::uint64_t payload_hash = fire_payload_hash(p_command);
	const bool structurally_valid =
			valid_fixed_vector(p_command.claimed_origin, MAX_WORLD_MILLIUNITS, true) &&
			valid_fixed_vector(p_command.claimed_aim, MAX_DIRECTION_COMPONENT, false) &&
			valid_fixed_vector(p_authority.authoritative_origin, MAX_WORLD_MILLIUNITS, true) &&
			valid_fixed_vector(p_authority.authoritative_aim, MAX_DIRECTION_COMPONENT, false) &&
			valid_modifier(p_authority.spread_modifier_ppm) &&
			valid_modifier(p_authority.damage_modifier_ppm) &&
			valid_modifier(p_authority.range_modifier_ppm) &&
			valid_modifier(p_authority.noise_modifier_ppm) &&
			valid_modifier(p_authority.recoil_modifier_ppm);

	WeaponSnapshot *state_ptr = nullptr;
	CommandOutcome admission_outcome;
	if (!admit(p_command.command_id, p_command.sequence, p_command.instance_id, p_command.tick,
				p_command.authority_scope, p_command.authority_epoch, payload_hash, structurally_valid,
				state_ptr, admission_outcome)) {
		return admission_outcome;
	}
	WeaponSnapshot &state = *state_ptr;

	auto finish_rejection = [&](Rejection p_rejection, DiagnosticId p_diagnostic) {
		CommandOutcome rejection_outcome = rejected(&state, p_rejection, p_diagnostic);
		record_command(p_command.command_id, payload_hash, rejection_outcome);
		return rejection_outcome;
	};

	const WeaponDefinition *definition = definition_for(state);
	const HitscanShotProfile *shot_profile = definition == nullptr ? nullptr :
			catalog.find_shot_profile(definition->shot_profile_id, definition->shot_profile_version);
	const RecoilProfile *recoil_profile = definition == nullptr ? nullptr :
			catalog.find_recoil_profile(definition->recoil_profile_id, definition->recoil_profile_version);
	if (definition == nullptr || shot_profile == nullptr || recoil_profile == nullptr) {
		return finish_rejection(Rejection::MALFORMED_COMMAND, DiagnosticId::DEFINITION_UNKNOWN_REFERENCE);
	}
	if (state.revision != p_command.expected_revision) return finish_rejection(Rejection::REVISION_MISMATCH, DiagnosticId::REVISION_STALE);
	if (!p_authority.actor_live) return finish_rejection(Rejection::ACTOR_NOT_LIVE, DiagnosticId::ACTOR_NOT_LIVE);
	if (!p_authority.weapon_equipped) return finish_rejection(Rejection::WEAPON_NOT_EQUIPPED, DiagnosticId::WEAPON_NOT_EQUIPPED);
	if (!p_authority.weapon_usable) return finish_rejection(Rejection::WEAPON_NOT_USABLE, DiagnosticId::WEAPON_NOT_USABLE);
	if (state.phase == WeaponPhase::RELOADING) return finish_rejection(Rejection::WEAPON_RELOADING, DiagnosticId::WEAPON_RELOADING);
	if (!origin_compatible(p_command.claimed_origin, p_authority.authoritative_origin, shot_profile->origin_tolerance_milliunits)) {
		return finish_rejection(Rejection::ORIGIN_MISMATCH, DiagnosticId::ORIGIN_MISMATCH);
	}
	if (!aim_compatible(p_command.claimed_aim, p_authority.authoritative_aim, shot_profile->aim_tolerance_microradians)) {
		return finish_rejection(Rejection::AIM_MISMATCH, DiagnosticId::AIM_MISMATCH);
	}

	AttachmentModifierDeltas attachment_deltas;
	collect_attachment_modifier_deltas(state, attachment_deltas);

	// Cadence, folded once with the attachment cadence modifier.
	std::int64_t cadence_aggregate_ppm = 0;
	Status mod_status = fold_modifier_deltas_ppm(attachment_deltas.cadence, cadence_aggregate_ppm);
	std::int64_t effective_cadence_i64 = 0;
	if (mod_status.ok()) {
		mod_status = apply_modifier_multiplier(static_cast<std::int64_t>(definition->cadence_ticks), cadence_aggregate_ppm,
				1, static_cast<std::int64_t>(MAX_TICK_DURATION), effective_cadence_i64);
	}
	if (!mod_status.ok()) {
		return finish_rejection(Rejection::MALFORMED_COMMAND, DiagnosticId::VALUE_OUT_OF_RANGE);
	}
	const std::uint64_t effective_cadence_ticks = static_cast<std::uint64_t>(effective_cadence_i64);
	if (state.has_last_fire_tick) {
		if (p_command.tick < state.last_fire_tick || p_command.tick - state.last_fire_tick < effective_cadence_ticks) {
			return finish_rejection(Rejection::CADENCE_NOT_ELAPSED, DiagnosticId::CADENCE_NOT_ELAPSED);
		}
	}
	if (state.loaded_rounds == 0) return finish_rejection(Rejection::OUT_OF_AMMO, DiagnosticId::OUT_OF_AMMO);
	if (!state.loaded_profile.has_value()) {
		// Defensive: the create_instance()/begin_reload() invariant already
		// guarantees loaded_rounds > 0 implies a loaded profile.
		return finish_rejection(Rejection::PROFILE_INVALID, DiagnosticId::PROFILE_REQUIRED);
	}
	const AmmunitionBallisticProfile *loaded_profile_def =
			catalog.find_ammo_profile(state.loaded_profile->id, state.loaded_profile->version);
	if (loaded_profile_def == nullptr || loaded_profile_def->ammunition_trait != definition->ammunition_trait) {
		return finish_rejection(Rejection::PROFILE_INVALID, DiagnosticId::PROFILE_TRAIT_MISMATCH);
	}

	// Sealed shot-direction derivation (weapon-runtime: "Deterministic Shot
	// Direction"): accuracy is folded once from the authority-supplied
	// checked spread modifier plus every accepted attachment's accuracy
	// modifier, then converted to a nanoradian angular radius and sampled
	// from the versioned DISPERSION seed channel.
	std::vector<ModifierDelta> accuracy_deltas = attachment_deltas.accuracy;
	accuracy_deltas.push_back(ModifierDelta{ "authority", "", "", 0, p_authority.spread_modifier_ppm - MODIFIER_NEUTRAL_PPM });
	std::int64_t accuracy_aggregate_ppm = 0;
	Status numeric_status = fold_modifier_deltas_ppm(accuracy_deltas, accuracy_aggregate_ppm);
	std::int64_t angular_radius_nrad = 0;
	if (numeric_status.ok()) {
		numeric_status = convert_accuracy_moa_milli_to_angular_radius_nrad(definition->accuracy_moa_milli, angular_radius_nrad);
	}
	std::int64_t effective_radius_nrad = 0;
	if (numeric_status.ok()) {
		numeric_status = apply_modifier_multiplier(angular_radius_nrad, accuracy_aggregate_ppm, 0, MAX_ANGLE_NANORADIANS, effective_radius_nrad);
	}
	std::int64_t dispersion_offset_nrad = 0;
	const std::uint64_t dispersion_seed = p_command.spread_seed ^ p_command.sequence ^ hash_string(state.instance_id);
	if (numeric_status.ok()) {
		numeric_status = sample_uniform_signed_offset_nrad(dispersion_seed, SeedChannel::DISPERSION, effective_radius_nrad, dispersion_offset_nrad);
	}
	if (!numeric_status.ok()) {
		// Unreachable given catalog-sealed/authority-checked bounds, but the
		// numeric contract is checked end-to-end: any defensive failure
		// rejects before mutation rather than risking overflow UB.
		return finish_rejection(Rejection::MALFORMED_COMMAND, DiagnosticId::VALUE_OUT_OF_RANGE);
	}

	// Deterministic recoil (weapon-runtime: "Deterministic Recoil Kick and
	// Recovery"): evaluate residual at the command tick BEFORE this shot's
	// kick is applied; the residual affects THIS shot's direction.
	std::int64_t residual_vertical_nrad = 0;
	std::int64_t residual_horizontal_nrad = 0;
	Status recoil_status = compute_effective_recoil_offset_nrad(
			state.recoil_vertical_offset_nrad, state.recoil_anchor_tick, recoil_profile->recovery_per_tick_nrad,
			p_command.tick, residual_vertical_nrad);
	if (recoil_status.ok()) {
		recoil_status = compute_effective_recoil_offset_nrad(
				state.recoil_horizontal_offset_nrad, state.recoil_anchor_tick, recoil_profile->recovery_per_tick_nrad,
				p_command.tick, residual_horizontal_nrad);
	}
	if (!recoil_status.ok()) {
		return finish_rejection(Rejection::MALFORMED_COMMAND, DiagnosticId::VALUE_OUT_OF_RANGE);
	}

	std::int64_t total_offset_nrad = 0;
	Status combine_status = checked_add_i64(dispersion_offset_nrad, residual_vertical_nrad, total_offset_nrad);
	if (combine_status.ok()) combine_status = checked_add_i64(total_offset_nrad, residual_horizontal_nrad, total_offset_nrad);
	if (!combine_status.ok()) {
		return finish_rejection(Rejection::MALFORMED_COMMAND, DiagnosticId::VALUE_OUT_OF_RANGE);
	}

	// New kick for subsequent shots: fixed non-negative vertical kick, plus a
	// deterministic signed horizontal kick drawn from the HORIZONTAL_RECOIL
	// seed channel, both scaled once by the folded recoil-modifier aggregate.
	std::int64_t recoil_aggregate_ppm = 0;
	attachment_deltas.recoil.push_back(ModifierDelta{ "authority", "", "", 0, p_authority.recoil_modifier_ppm - MODIFIER_NEUTRAL_PPM });
	Status kick_status = fold_modifier_deltas_ppm(attachment_deltas.recoil, recoil_aggregate_ppm);
	std::int64_t effective_vertical_kick = 0;
	if (kick_status.ok()) {
		kick_status = apply_modifier_multiplier(recoil_profile->vertical_kick_nrad, recoil_aggregate_ppm, 0, MAX_RECOIL_KICK_NRAD, effective_vertical_kick);
	}
	std::int64_t effective_horizontal_min = 0;
	std::int64_t effective_horizontal_max = 0;
	if (kick_status.ok()) {
		kick_status = apply_modifier_multiplier(recoil_profile->horizontal_kick_min_nrad, recoil_aggregate_ppm,
				-MAX_RECOIL_KICK_NRAD, MAX_RECOIL_KICK_NRAD, effective_horizontal_min);
	}
	if (kick_status.ok()) {
		kick_status = apply_modifier_multiplier(recoil_profile->horizontal_kick_max_nrad, recoil_aggregate_ppm,
				-MAX_RECOIL_KICK_NRAD, MAX_RECOIL_KICK_NRAD, effective_horizontal_max);
	}
	if (kick_status.ok() && effective_horizontal_min > effective_horizontal_max) {
		effective_horizontal_max = effective_horizontal_min; // Defensive; see apply_modifier_multiplier's monotonicity note.
	}
	std::int64_t horizontal_kick_nrad = 0;
	const std::uint64_t recoil_seed = p_command.spread_seed ^ p_command.sequence ^ hash_string(state.instance_id);
	if (kick_status.ok()) {
		kick_status = sample_uniform_signed_range_nrad(recoil_seed, SeedChannel::HORIZONTAL_RECOIL,
				effective_horizontal_min, effective_horizontal_max, horizontal_kick_nrad);
	}
	if (!kick_status.ok()) {
		return finish_rejection(Rejection::MALFORMED_COMMAND, DiagnosticId::VALUE_OUT_OF_RANGE);
	}

	std::int64_t new_vertical_nrad = 0;
	std::int64_t new_horizontal_nrad = 0;
	Status accumulate_status = checked_add_i64(residual_vertical_nrad, effective_vertical_kick, new_vertical_nrad);
	if (accumulate_status.ok()) accumulate_status = checked_add_i64(residual_horizontal_nrad, horizontal_kick_nrad, new_horizontal_nrad);
	if (!accumulate_status.ok()) {
		return finish_rejection(Rejection::MALFORMED_COMMAND, DiagnosticId::VALUE_OUT_OF_RANGE);
	}
	new_vertical_nrad = clamp_i64(new_vertical_nrad, 0, recoil_profile->max_vertical_offset_nrad);
	new_horizontal_nrad = clamp_i64(new_horizontal_nrad, -recoil_profile->max_horizontal_offset_nrad, recoil_profile->max_horizontal_offset_nrad);

	// Noise, folded once with the attachment noise modifier.
	std::vector<ModifierDelta> noise_deltas = attachment_deltas.noise;
	noise_deltas.push_back(ModifierDelta{ "authority", "", "", 0, p_authority.noise_modifier_ppm - MODIFIER_NEUTRAL_PPM });
	std::int64_t noise_aggregate_ppm = 0;
	Status noise_status = fold_modifier_deltas_ppm(noise_deltas, noise_aggregate_ppm);
	std::int64_t effective_noise = 0;
	if (noise_status.ok()) {
		noise_status = apply_modifier_multiplier(definition->noise_radius_milliunits, noise_aggregate_ppm, 0, MAX_NOISE_MILLIUNITS, effective_noise);
	}
	if (!noise_status.ok()) {
		return finish_rejection(Rejection::MALFORMED_COMMAND, DiagnosticId::VALUE_OUT_OF_RANGE);
	}

	const BallisticProfileIdentity consumed_profile = *state.loaded_profile;
	const std::uint64_t successor_revision = state.revision + 1;

	CommittedShot shot;
	shot.consequence_id = p_command.command_id + ":shot";
	shot.consequence_identity = ConsequenceIdentity{
		CONSEQUENCE_IDENTITY_VERSION, CONSEQUENCE_DOMAIN_WEAPON_SHOT,
		p_command.authority_scope, p_command.authority_epoch,
		state.instance_id, successor_revision, p_command.command_id
	};
	shot.instance_id = state.instance_id;
	shot.weapon_id = definition->id;
	shot.weapon_version = definition->version;
	shot.shot_profile_id = shot_profile->id;
	shot.shot_profile_version = shot_profile->version;
	shot.tick = p_command.tick;
	shot.origin = p_authority.authoritative_origin;
	shot.direction = rotate_unit_vector_by_angle_nrad(p_authority.authoritative_aim, total_offset_nrad);
	shot.damage_milliunits = scale_value(shot_profile->damage_milliunits, p_authority.damage_modifier_ppm);
	shot.range_milliunits = scale_value(shot_profile->range_milliunits, p_authority.range_modifier_ppm);
	shot.noise_radius_milliunits = effective_noise;
	shot.consumed_profile = consumed_profile;

	--state.loaded_rounds;
	if (state.loaded_rounds == 0) {
		state.loaded_profile.reset();
	}
	state.has_last_command_sequence = true;
	state.last_command_sequence = p_command.sequence;
	state.has_last_fire_tick = true;
	state.last_fire_tick = p_command.tick;
	state.recoil_vertical_offset_nrad = new_vertical_nrad;
	state.recoil_horizontal_offset_nrad = new_horizontal_nrad;
	state.recoil_anchor_tick = p_command.tick;
	++state.revision;
	current_tick = std::max(current_tick, p_command.tick);

	CommandOutcome outcome;
	outcome.accepted = true;
	outcome.status = ok_status();
	outcome.revision = state.revision;
	outcome.loaded_rounds = state.loaded_rounds;
	outcome.shot = shot;
	record_command(p_command.command_id, payload_hash, outcome);
	return outcome;
}

// --- Simple Tick-Based Reload (tasks.md 4.12-4.13) --------------------------

CommandOutcome WeaponRuntime::begin_reload(const BeginReloadCommand &p_command) {
	const std::uint64_t payload_hash = begin_reload_payload_hash(p_command);
	const bool structurally_valid =
			validate_identifier(p_command.reservation_id).ok() &&
			validate_identifier(p_command.profile.id).ok() &&
			p_command.profile.version != 0;

	WeaponSnapshot *state_ptr = nullptr;
	CommandOutcome admission_outcome;
	if (!admit(p_command.command_id, p_command.sequence, p_command.instance_id, p_command.tick,
				p_command.authority_scope, p_command.authority_epoch, payload_hash, structurally_valid,
				state_ptr, admission_outcome)) {
		return admission_outcome;
	}
	WeaponSnapshot &state = *state_ptr;
	auto finish_rejection = [&](Rejection p_rejection, DiagnosticId p_diagnostic) {
		CommandOutcome rejection_outcome = rejected(&state, p_rejection, p_diagnostic);
		record_command(p_command.command_id, payload_hash, rejection_outcome);
		return rejection_outcome;
	};

	const WeaponDefinition *definition = definition_for(state);
	if (definition == nullptr) return finish_rejection(Rejection::RESERVATION_REQUIRED, DiagnosticId::DEFINITION_UNKNOWN_REFERENCE);
	if (state.revision != p_command.expected_revision) return finish_rejection(Rejection::REVISION_MISMATCH, DiagnosticId::REVISION_STALE);
	if (state.phase == WeaponPhase::RELOADING) return finish_rejection(Rejection::WEAPON_RELOADING, DiagnosticId::WEAPON_RELOADING);
	if (state.loaded_rounds >= definition->capacity) return finish_rejection(Rejection::RELOAD_NOT_NEEDED, DiagnosticId::RELOAD_NOT_NEEDED);

	const AmmunitionBallisticProfile *profile_def = catalog.find_ammo_profile(p_command.profile.id, p_command.profile.version);
	if (profile_def == nullptr) return finish_rejection(Rejection::PROFILE_INVALID, DiagnosticId::PROFILE_UNKNOWN_REFERENCE);
	if (profile_def->ammunition_trait != definition->ammunition_trait) {
		return finish_rejection(Rejection::PROFILE_INVALID, DiagnosticId::PROFILE_TRAIT_MISMATCH);
	}
	// Homogeneous internal magazine (weapon-runtime spec, "Simple Tick-Based
	// Reload": "Different profile tops up a non-empty weapon" is rejected).
	if (state.loaded_profile.has_value() && *state.loaded_profile != p_command.profile) {
		return finish_rejection(Rejection::PROFILE_INVALID, DiagnosticId::PROFILE_TOPUP_MISMATCH);
	}

	const std::uint32_t missing = definition->capacity - state.loaded_rounds;
	if (p_command.reserved_rounds == 0 || p_command.reserved_rounds > missing) {
		return finish_rejection(Rejection::RELOAD_QUANTITY_INVALID, DiagnosticId::RELOAD_QUANTITY_INVALID);
	}

	AttachmentModifierDeltas attachment_deltas;
	collect_attachment_modifier_deltas(state, attachment_deltas);
	std::int64_t reload_duration_aggregate_ppm = 0;
	Status mod_status = fold_modifier_deltas_ppm(attachment_deltas.reload_duration, reload_duration_aggregate_ppm);
	std::int64_t effective_reload_ticks_i64 = 0;
	if (mod_status.ok()) {
		mod_status = apply_modifier_multiplier(static_cast<std::int64_t>(definition->reload_ticks), reload_duration_aggregate_ppm,
				1, static_cast<std::int64_t>(MAX_TICK_DURATION), effective_reload_ticks_i64);
	}
	if (!mod_status.ok()) return finish_rejection(Rejection::RELOAD_QUANTITY_INVALID, DiagnosticId::VALUE_OUT_OF_RANGE);

	std::uint64_t due_tick = 0;
	Status tick_status = checked_add_u64(p_command.tick, static_cast<std::uint64_t>(effective_reload_ticks_i64), due_tick);
	if (!tick_status.ok()) {
		// Checked tick-arithmetic failure (weapon-runtime spec, "Canonical
		// Revision and Authority-Tick Semantics"): latches unhealthy without
		// any mechanical mutation; recovery requires a trusted replacement
		// snapshot starting a new epoch.
		state.tick_unhealthy = true;
		CommandOutcome fault_outcome = rejected(&state, Rejection::TICK_ARITHMETIC_FAULT, DiagnosticId::TICK_ARITHMETIC_OVERFLOW);
		fault_outcome.status = make_status(StatusCode::ARITHMETIC_ERROR, DiagnosticId::TICK_ARITHMETIC_OVERFLOW);
		record_command(p_command.command_id, payload_hash, fault_outcome);
		return fault_outcome;
	}

	state.phase = WeaponPhase::RELOADING;
	state.has_last_command_sequence = true;
	state.last_command_sequence = p_command.sequence;
	state.reload = ReloadState{ p_command.reservation_id, p_command.reserved_rounds, p_command.tick, due_tick, p_command.profile };
	++state.revision;
	current_tick = std::max(current_tick, p_command.tick);
	CommandOutcome outcome;
	outcome.accepted = true;
	outcome.status = ok_status();
	outcome.revision = state.revision;
	outcome.loaded_rounds = state.loaded_rounds;
	record_command(p_command.command_id, payload_hash, outcome);
	return outcome;
}

CommandOutcome WeaponRuntime::cancel_reload(const CancelReloadCommand &p_command) {
	const std::uint64_t payload_hash = cancel_reload_payload_hash(p_command);
	WeaponSnapshot *state_ptr = nullptr;
	CommandOutcome admission_outcome;
	if (!admit(p_command.command_id, p_command.sequence, p_command.instance_id, p_command.tick,
				p_command.authority_scope, p_command.authority_epoch, payload_hash, /*p_structurally_valid=*/true,
				state_ptr, admission_outcome)) {
		return admission_outcome;
	}
	WeaponSnapshot &state = *state_ptr;
	auto finish_rejection = [&](Rejection p_rejection, DiagnosticId p_diagnostic) {
		CommandOutcome rejection_outcome = rejected(&state, p_rejection, p_diagnostic);
		record_command(p_command.command_id, payload_hash, rejection_outcome);
		return rejection_outcome;
	};
	if (state.revision != p_command.expected_revision) return finish_rejection(Rejection::REVISION_MISMATCH, DiagnosticId::REVISION_STALE);
	if (state.phase != WeaponPhase::RELOADING || !state.reload.has_value()) {
		return finish_rejection(Rejection::WEAPON_NOT_RELOADING, DiagnosticId::WEAPON_NOT_RELOADING);
	}
	const std::string reservation = state.reload->reservation_id;
	state.phase = WeaponPhase::READY;
	state.has_last_command_sequence = true;
	state.last_command_sequence = p_command.sequence;
	state.reload.reset();
	++state.revision;
	current_tick = std::max(current_tick, p_command.tick);
	CommandOutcome outcome;
	outcome.accepted = true;
	outcome.status = ok_status();
	outcome.revision = state.revision;
	outcome.loaded_rounds = state.loaded_rounds;
	outcome.reservation_to_release = reservation;
	record_command(p_command.command_id, payload_hash, outcome);
	return outcome;
}

// --- Atomic Flat Attachment Loadout (tasks.md 4.11) -------------------------

CommandOutcome WeaponRuntime::configure_attachments(const ConfigureAttachmentsCommand &p_command) {
	const std::uint64_t payload_hash = configure_attachments_payload_hash(p_command);
	bool structurally_valid = p_command.desired_loadout.size() <= MAX_ATTACHMENT_SLOTS_PER_WEAPON;
	if (structurally_valid) {
		std::set<std::string> seen_slots;
		for (const AttachmentLoadoutEntry &entry : p_command.desired_loadout) {
			if (!validate_identifier(entry.slot_id).ok() || !validate_identifier(entry.attachment_id).ok() ||
					entry.attachment_version == 0 || !seen_slots.insert(entry.slot_id).second) {
				structurally_valid = false;
				break;
			}
		}
	}

	WeaponSnapshot *state_ptr = nullptr;
	CommandOutcome admission_outcome;
	if (!admit(p_command.command_id, p_command.sequence, p_command.instance_id, p_command.tick,
				p_command.authority_scope, p_command.authority_epoch, payload_hash, structurally_valid,
				state_ptr, admission_outcome)) {
		return admission_outcome;
	}
	WeaponSnapshot &state = *state_ptr;
	auto finish_rejection = [&](Rejection p_rejection, DiagnosticId p_diagnostic) {
		CommandOutcome rejection_outcome = rejected(&state, p_rejection, p_diagnostic);
		record_command(p_command.command_id, payload_hash, rejection_outcome);
		return rejection_outcome;
	};

	const WeaponDefinition *definition = definition_for(state);
	if (definition == nullptr) return finish_rejection(Rejection::ATTACHMENT_INVALID, DiagnosticId::DEFINITION_UNKNOWN_REFERENCE);
	if (state.revision != p_command.expected_revision) return finish_rejection(Rejection::REVISION_MISMATCH, DiagnosticId::REVISION_STALE);
	// Accepted only while ready (weapon-runtime spec, "Atomic Flat Attachment
	// Loadout": "Loadout changes during reload" is rejected without changing
	// reload or attachments).
	if (state.phase == WeaponPhase::RELOADING) {
		return finish_rejection(Rejection::WEAPON_RELOADING, DiagnosticId::ATTACHMENT_CONFIG_DURING_RELOAD);
	}

	std::vector<AttachmentLoadoutEntry> validated_loadout;
	validated_loadout.reserve(p_command.desired_loadout.size());
	for (const AttachmentLoadoutEntry &entry : p_command.desired_loadout) {
		const WeaponAttachmentSlot *declared_slot = nullptr;
		for (const WeaponAttachmentSlot &slot : definition->attachment_slots) {
			if (slot.slot_id == entry.slot_id) {
				declared_slot = &slot;
				break;
			}
		}
		if (declared_slot == nullptr) {
			return finish_rejection(Rejection::ATTACHMENT_INVALID, DiagnosticId::ATTACHMENT_SLOT_UNKNOWN);
		}
		const AttachmentDefinition *attachment_def = catalog.find_attachment(entry.attachment_id, entry.attachment_version);
		if (attachment_def == nullptr) {
			return finish_rejection(Rejection::ATTACHMENT_INVALID, DiagnosticId::ATTACHMENT_UNKNOWN_REFERENCE);
		}
		if ((attachment_def->compatible_slot_kinds_mask & static_cast<std::uint32_t>(declared_slot->slot_kind)) == 0) {
			return finish_rejection(Rejection::ATTACHMENT_INVALID, DiagnosticId::ATTACHMENT_SLOT_INCOMPATIBLE);
		}
		validated_loadout.push_back(entry);
	}
	// Canonical slot-ID order (weapon-runtime spec, "Atomic Flat Attachment
	// Loadout": modifier folding uses "canonical slot-ID then attachment-
	// definition-ID order"); storing the loadout pre-sorted makes every
	// later fold/snapshot/fingerprint order-independent of submission order.
	std::sort(validated_loadout.begin(), validated_loadout.end(),
			[](const AttachmentLoadoutEntry &p_a, const AttachmentLoadoutEntry &p_b) { return p_a.slot_id < p_b.slot_id; });

	state.attachment_loadout = std::move(validated_loadout);
	state.has_last_command_sequence = true;
	state.last_command_sequence = p_command.sequence;
	++state.revision;
	current_tick = std::max(current_tick, p_command.tick);
	CommandOutcome outcome;
	outcome.accepted = true;
	outcome.status = ok_status();
	outcome.revision = state.revision;
	outcome.loaded_rounds = state.loaded_rounds;
	record_command(p_command.command_id, payload_hash, outcome);
	return outcome;
}

// --- Teardown / tombstone (tasks.md 4.13) -----------------------------------

CommandOutcome WeaponRuntime::teardown(const TeardownCommand &p_command) {
	const std::uint64_t payload_hash = teardown_payload_hash(p_command);
	WeaponSnapshot *state_ptr = nullptr;
	CommandOutcome admission_outcome;
	if (!admit(p_command.command_id, p_command.sequence, p_command.instance_id, p_command.tick,
				p_command.authority_scope, p_command.authority_epoch, payload_hash, /*p_structurally_valid=*/true,
				state_ptr, admission_outcome)) {
		return admission_outcome;
	}
	WeaponSnapshot &state = *state_ptr;
	if (state.revision != p_command.expected_revision) {
		CommandOutcome rejection_outcome = rejected(&state, Rejection::REVISION_MISMATCH, DiagnosticId::REVISION_STALE);
		record_command(p_command.command_id, payload_hash, rejection_outcome);
		return rejection_outcome;
	}
	CommandOutcome outcome;
	outcome.accepted = true;
	outcome.status = ok_status();
	outcome.revision = state.revision + 1;
	outcome.loaded_rounds = state.loaded_rounds;
	if (state.reload.has_value()) outcome.reservation_to_release = state.reload->reservation_id;
	insert_tombstone(state.instance_id, state.authority_scope, state.authority_epoch, outcome.revision);
	instances.erase(p_command.instance_id);
	current_tick = std::max(current_tick, p_command.tick);
	record_command(p_command.command_id, payload_hash, outcome);
	return outcome;
}

// --- Authority-driven usability change (tasks.md 4.13) ----------------------

Status WeaponRuntime::notify_usability_change(
		const std::string &p_instance_id,
		const std::string &p_authority_scope,
		std::uint64_t p_authority_epoch,
		std::uint64_t p_authority_tick,
		bool p_usable,
		CommandOutcome &r_outcome) {
	r_outcome = CommandOutcome{};
	auto found = instances.find(p_instance_id);
	if (found == instances.end()) return make_status(StatusCode::NOT_FOUND, DiagnosticId::INSTANCE_UNKNOWN);
	WeaponSnapshot &state = found->second;
	if (state.authority_scope != p_authority_scope) {
		return make_status(StatusCode::COMMAND_REJECTED, DiagnosticId::AUTHORITY_SCOPE_MISMATCH);
	}
	if (state.authority_epoch != p_authority_epoch) {
		return make_status(StatusCode::COMMAND_REJECTED, DiagnosticId::AUTHORITY_EPOCH_MISMATCH);
	}
	if (state.tick_unhealthy) {
		return make_status(StatusCode::UNHEALTHY, DiagnosticId::RUNTIME_UNHEALTHY);
	}
	if (p_authority_tick < state.authority_tick_floor) {
		return make_status(StatusCode::COMMAND_REJECTED, DiagnosticId::AUTHORITY_TICK_REGRESSION, state.authority_tick_floor);
	}
	state.authority_tick_floor = std::max(state.authority_tick_floor, p_authority_tick);
	r_outcome.revision = state.revision;
	r_outcome.loaded_rounds = state.loaded_rounds;
	r_outcome.status = ok_status();
	r_outcome.accepted = true;
	if (p_usable || state.phase != WeaponPhase::RELOADING || !state.reload.has_value()) {
		return ok_status(); // No-op: nothing to cancel.
	}
	const std::string reservation = state.reload->reservation_id;
	state.phase = WeaponPhase::READY;
	state.reload.reset();
	++state.revision;
	current_tick = std::max(current_tick, p_authority_tick);
	r_outcome.revision = state.revision;
	r_outcome.reservation_to_release = reservation;
	return ok_status();
}

// --- Deterministic recoil query (tasks.md 4.10) -----------------------------

Status WeaponRuntime::effective_recoil(
		const std::string &p_instance_id,
		std::uint64_t p_authority_tick,
		std::int64_t &r_vertical_offset_nrad,
		std::int64_t &r_horizontal_offset_nrad) const {
	r_vertical_offset_nrad = 0;
	r_horizontal_offset_nrad = 0;
	auto found = instances.find(p_instance_id);
	if (found == instances.end()) return make_status(StatusCode::NOT_FOUND, DiagnosticId::INSTANCE_UNKNOWN);
	const WeaponSnapshot &state = found->second;
	const WeaponDefinition *definition = definition_for(state);
	const RecoilProfile *recoil_profile = definition == nullptr ? nullptr :
			catalog.find_recoil_profile(definition->recoil_profile_id, definition->recoil_profile_version);
	if (recoil_profile == nullptr) return make_status(StatusCode::INTERNAL_ERROR, DiagnosticId::DEFINITION_UNKNOWN_REFERENCE);
	Status status = compute_effective_recoil_offset_nrad(
			state.recoil_vertical_offset_nrad, state.recoil_anchor_tick, recoil_profile->recovery_per_tick_nrad,
			p_authority_tick, r_vertical_offset_nrad);
	if (!status.ok()) return status;
	return compute_effective_recoil_offset_nrad(
			state.recoil_horizontal_offset_nrad, state.recoil_anchor_tick, recoil_profile->recovery_per_tick_nrad,
			p_authority_tick, r_horizontal_offset_nrad);
}

// --- Prepared Reload Completion Participant (tasks.md 4.14) -----------------

ReloadParticipantOutcome WeaponRuntime::outcome_for_participant(
		const std::string &p_reservation_id, const ReloadParticipantRecord &p_record, bool p_replayed) {
	if (p_record.state == ReloadParticipantState::COMMITTED || p_record.state == ReloadParticipantState::PUBLISHED) {
		ReloadParticipantOutcome outcome = p_record.terminal_outcome;
		outcome.reservation_id = p_reservation_id;
		outcome.instance_id = p_record.instance_id;
		outcome.replayed = p_replayed;
		return outcome;
	}
	ReloadParticipantOutcome outcome;
	outcome.reservation_id = p_reservation_id;
	outcome.instance_id = p_record.instance_id;
	outcome.replayed = p_replayed;
	if (p_record.state == ReloadParticipantState::ROLLED_BACK) {
		outcome.accepted = false;
		outcome.status = make_status(StatusCode::COMMAND_REJECTED, DiagnosticId::RELOAD_PARTICIPANT_STATE_INVALID);
		return outcome;
	}
	// PREPARED: validated and held, but not yet committed/decided.
	outcome.accepted = true;
	outcome.status = ok_status();
	outcome.predecessor_revision = p_record.expected_revision;
	return outcome;
}

void WeaponRuntime::trim_reload_participant_records() {
	while (reload_participants.size() > MAX_RELOAD_PARTICIPANT_RECORDS && !reload_participant_terminal_order.empty()) {
		const std::string oldest = reload_participant_terminal_order.front();
		reload_participant_terminal_order.pop_front();
		auto found = reload_participants.find(oldest);
		if (found != reload_participants.end() &&
				(found->second.state == ReloadParticipantState::ROLLED_BACK ||
						found->second.state == ReloadParticipantState::PUBLISHED)) {
			reload_participants.erase(found);
		}
	}
}

ReloadParticipantOutcome WeaponRuntime::prepare_reload_completion(
		const std::string &p_reservation_id,
		const std::string &p_instance_id,
		std::uint64_t p_expected_revision,
		std::uint64_t p_due_tick,
		std::uint32_t p_reserved_rounds,
		const BallisticProfileIdentity &p_profile,
		std::uint64_t p_authority_tick) {
	ReloadParticipantOutcome rejected_outcome;
	rejected_outcome.reservation_id = p_reservation_id;
	rejected_outcome.instance_id = p_instance_id;

	auto existing = reload_participants.find(p_reservation_id);
	if (existing != reload_participants.end()) {
		const ReloadParticipantRecord &record = existing->second;
		if (record.instance_id == p_instance_id && record.expected_revision == p_expected_revision &&
				record.due_tick == p_due_tick && record.reserved_rounds == p_reserved_rounds &&
				record.profile == p_profile) {
			return outcome_for_participant(p_reservation_id, record, /*p_replayed=*/true);
		}
		rejected_outcome.status = make_status(StatusCode::DUPLICATE_CONFLICT, DiagnosticId::RELOAD_PARTICIPANT_STATE_INVALID);
		return rejected_outcome;
	}

	auto found = instances.find(p_instance_id);
	if (found == instances.end()) {
		rejected_outcome.status = make_status(StatusCode::NOT_FOUND, DiagnosticId::INSTANCE_UNKNOWN);
		return rejected_outcome;
	}
	const WeaponSnapshot &state = found->second;
	if (state.revision != p_expected_revision) {
		rejected_outcome.status = make_status(StatusCode::REVISION_MISMATCH, DiagnosticId::REVISION_STALE, state.revision);
		return rejected_outcome;
	}
	if (state.phase != WeaponPhase::RELOADING || !state.reload.has_value()) {
		rejected_outcome.status = make_status(StatusCode::COMMAND_REJECTED, DiagnosticId::WEAPON_NOT_RELOADING);
		return rejected_outcome;
	}
	const ReloadState &reload = *state.reload;
	if (reload.reservation_id != p_reservation_id || reload.due_tick != p_due_tick ||
			reload.reserved_rounds != p_reserved_rounds || !(reload.reserved_profile == p_profile)) {
		rejected_outcome.status = make_status(StatusCode::COMMAND_REJECTED, DiagnosticId::RESERVATION_REQUIRED);
		return rejected_outcome;
	}
	if (p_authority_tick < reload.due_tick) {
		rejected_outcome.status = make_status(StatusCode::COMMAND_REJECTED, DiagnosticId::TICK_REVERSED, reload.due_tick);
		return rejected_outcome;
	}
	const WeaponDefinition *definition = definition_for(state);
	if (definition == nullptr) {
		rejected_outcome.status = make_status(StatusCode::INTERNAL_ERROR, DiagnosticId::DEFINITION_UNKNOWN_REFERENCE);
		return rejected_outcome;
	}
	const AmmunitionBallisticProfile *profile_def = catalog.find_ammo_profile(p_profile.id, p_profile.version);
	if (profile_def == nullptr || profile_def->ammunition_trait != definition->ammunition_trait) {
		rejected_outcome.status = make_status(StatusCode::COMMAND_REJECTED, DiagnosticId::PROFILE_TRAIT_MISMATCH);
		return rejected_outcome;
	}
	if (state.loaded_profile.has_value() && !(*state.loaded_profile == p_profile)) {
		rejected_outcome.status = make_status(StatusCode::COMMAND_REJECTED, DiagnosticId::PROFILE_TOPUP_MISMATCH);
		return rejected_outcome;
	}
	if (p_reserved_rounds > definition->capacity) {
		rejected_outcome.status = make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_OUT_OF_RANGE, p_reserved_rounds);
		return rejected_outcome;
	}

	if (reload_participants.size() >= MAX_RELOAD_PARTICIPANT_RECORDS) {
		trim_reload_participant_records();
		if (reload_participants.size() >= MAX_RELOAD_PARTICIPANT_RECORDS) {
			rejected_outcome.status = make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, reload_participants.size());
			return rejected_outcome;
		}
	}

	ReloadParticipantRecord record;
	record.instance_id = p_instance_id;
	record.expected_revision = p_expected_revision;
	record.due_tick = p_due_tick;
	record.reserved_rounds = p_reserved_rounds;
	record.profile = p_profile;
	record.state = ReloadParticipantState::PREPARED;
	auto inserted = reload_participants.emplace(p_reservation_id, std::move(record));
	return outcome_for_participant(p_reservation_id, inserted.first->second, /*p_replayed=*/false);
}

ReloadParticipantOutcome WeaponRuntime::commit_reload_completion_silent(const std::string &p_reservation_id) {
	ReloadParticipantOutcome rejected_outcome;
	rejected_outcome.reservation_id = p_reservation_id;
	auto found = reload_participants.find(p_reservation_id);
	if (found == reload_participants.end()) {
		rejected_outcome.status = make_status(StatusCode::NOT_FOUND, DiagnosticId::RELOAD_PARTICIPANT_STATE_INVALID);
		return rejected_outcome;
	}
	ReloadParticipantRecord &record = found->second;
	rejected_outcome.instance_id = record.instance_id;
	if (record.state == ReloadParticipantState::COMMITTED || record.state == ReloadParticipantState::PUBLISHED) {
		return outcome_for_participant(p_reservation_id, record, /*p_replayed=*/true);
	}
	if (record.state != ReloadParticipantState::PREPARED) {
		rejected_outcome.status = make_status(StatusCode::COMMAND_REJECTED, DiagnosticId::RELOAD_PARTICIPANT_STATE_INVALID, static_cast<std::uint64_t>(record.state));
		return rejected_outcome;
	}
	auto instance_found = instances.find(record.instance_id);
	if (instance_found == instances.end()) {
		rejected_outcome.status = make_status(StatusCode::NOT_FOUND, DiagnosticId::INSTANCE_UNKNOWN);
		return rejected_outcome;
	}
	WeaponSnapshot &state = instance_found->second;
	// Re-validate the live state still matches what prepare() staged --
	// defense-in-depth against another mutation landing between prepare()
	// and commit_silent() (design.md: "revalidate the reload and held lines
	// against their commit-time state").
	if (state.revision != record.expected_revision || state.phase != WeaponPhase::RELOADING ||
			!state.reload.has_value() || state.reload->reservation_id != p_reservation_id ||
			state.reload->due_tick != record.due_tick || state.reload->reserved_rounds != record.reserved_rounds ||
			!(state.reload->reserved_profile == record.profile)) {
		rejected_outcome.status = make_status(StatusCode::COMMAND_REJECTED, DiagnosticId::RELOAD_PARTICIPANT_STATE_INVALID);
		return rejected_outcome;
	}
	const WeaponDefinition *definition = definition_for(state);
	if (definition == nullptr) {
		rejected_outcome.status = make_status(StatusCode::INTERNAL_ERROR, DiagnosticId::DEFINITION_UNKNOWN_REFERENCE);
		return rejected_outcome;
	}

	record.predecessor = state; // Journal the immediate predecessor for rollback.
	const std::uint32_t missing = definition->capacity - state.loaded_rounds;
	const std::uint32_t added = std::min(missing, record.reserved_rounds);
	state.loaded_rounds += added;
	state.loaded_profile = record.profile;
	state.phase = WeaponPhase::READY;
	state.reload.reset();
	++state.revision;

	ReloadParticipantOutcome outcome;
	outcome.accepted = true;
	outcome.status = ok_status();
	outcome.reservation_id = p_reservation_id;
	outcome.instance_id = record.instance_id;
	outcome.predecessor_revision = record.expected_revision;
	outcome.successor_revision = state.revision;
	outcome.added_rounds = added;
	outcome.loaded_rounds = state.loaded_rounds;
	outcome.profile = state.loaded_profile;
	record.terminal_outcome = outcome;
	record.state = ReloadParticipantState::COMMITTED;
	return outcome;
}

ReloadParticipantOutcome WeaponRuntime::rollback_reload_completion(const std::string &p_reservation_id) {
	ReloadParticipantOutcome rejected_outcome;
	rejected_outcome.reservation_id = p_reservation_id;
	auto found = reload_participants.find(p_reservation_id);
	if (found == reload_participants.end()) {
		rejected_outcome.status = make_status(StatusCode::NOT_FOUND, DiagnosticId::RELOAD_PARTICIPANT_STATE_INVALID);
		return rejected_outcome;
	}
	ReloadParticipantRecord &record = found->second;
	rejected_outcome.instance_id = record.instance_id;
	if (record.state != ReloadParticipantState::COMMITTED || !record.predecessor.has_value()) {
		rejected_outcome.status = make_status(StatusCode::COMMAND_REJECTED, DiagnosticId::RELOAD_PARTICIPANT_STATE_INVALID, static_cast<std::uint64_t>(record.state));
		return rejected_outcome;
	}
	auto instance_found = instances.find(record.instance_id);
	if (instance_found == instances.end() || instance_found->second.revision != record.terminal_outcome.successor_revision) {
		rejected_outcome.status = make_status(StatusCode::COMMAND_REJECTED, DiagnosticId::RELOAD_PARTICIPANT_STATE_INVALID);
		return rejected_outcome;
	}
	instance_found->second = *record.predecessor;
	record.predecessor.reset();
	record.state = ReloadParticipantState::ROLLED_BACK;
	reload_participant_terminal_order.push_back(p_reservation_id);
	trim_reload_participant_records();

	ReloadParticipantOutcome outcome;
	outcome.accepted = true;
	outcome.status = ok_status();
	outcome.reservation_id = p_reservation_id;
	outcome.instance_id = record.instance_id;
	outcome.predecessor_revision = record.expected_revision;
	outcome.successor_revision = instance_found->second.revision;
	outcome.loaded_rounds = instance_found->second.loaded_rounds;
	return outcome;
}

ReloadParticipantOutcome WeaponRuntime::publish_reload_completion(const std::string &p_reservation_id) {
	ReloadParticipantOutcome rejected_outcome;
	rejected_outcome.reservation_id = p_reservation_id;
	auto found = reload_participants.find(p_reservation_id);
	if (found == reload_participants.end()) {
		rejected_outcome.status = make_status(StatusCode::NOT_FOUND, DiagnosticId::RELOAD_PARTICIPANT_STATE_INVALID);
		return rejected_outcome;
	}
	ReloadParticipantRecord &record = found->second;
	rejected_outcome.instance_id = record.instance_id;
	if (record.state == ReloadParticipantState::PUBLISHED) {
		return outcome_for_participant(p_reservation_id, record, /*p_replayed=*/true);
	}
	if (record.state != ReloadParticipantState::COMMITTED) {
		rejected_outcome.status = make_status(StatusCode::COMMAND_REJECTED, DiagnosticId::RELOAD_PARTICIPANT_STATE_INVALID, static_cast<std::uint64_t>(record.state));
		return rejected_outcome;
	}
	record.predecessor.reset();
	record.state = ReloadParticipantState::PUBLISHED;
	reload_participant_terminal_order.push_back(p_reservation_id);
	trim_reload_participant_records();
	ReloadParticipantOutcome outcome = record.terminal_outcome;
	outcome.replayed = false;
	return outcome;
}

// --- due_reloads()/commit_due_reload()/advance_tick(): the direct
// non-Inventory one-participant coordinator path, built on the same
// prepared reload-completion participant contract above -----------------

Status WeaponRuntime::due_reloads(std::uint64_t p_tick, std::vector<ReloadCompletion> &r_due) const {
	r_due.clear();
	if (p_tick < current_tick) return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::TICK_REVERSED, p_tick);
	for (const auto &entry : instances) {
		const WeaponSnapshot &state = entry.second;
		if (state.phase != WeaponPhase::RELOADING || !state.reload.has_value() || state.reload->due_tick > p_tick) continue;
		const WeaponDefinition *definition = definition_for(state);
		if (definition == nullptr) return make_status(StatusCode::INTERNAL_ERROR, DiagnosticId::DEFINITION_UNKNOWN_REFERENCE);
		const std::uint32_t missing = definition->capacity - state.loaded_rounds;
		const std::uint32_t added = std::min(missing, state.reload->reserved_rounds);
		r_due.push_back({
				state.instance_id,
				state.reload->reservation_id,
				added,
				state.revision + 1,
				state.loaded_rounds + added,
				state.reload->reserved_profile });
		if (r_due.size() >= MAX_EVENTS_PER_TICK) break;
	}
	return ok_status();
}

Status WeaponRuntime::commit_due_reload(
		std::uint64_t p_tick,
		const std::string &p_instance_id,
		const std::string &p_reservation_id,
		ReloadCompletion &r_completion) {
	r_completion = ReloadCompletion{};
	if (p_tick < current_tick) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::TICK_REVERSED, p_tick);
	}
	auto found = instances.find(p_instance_id);
	if (found == instances.end()) {
		return make_status(StatusCode::NOT_FOUND, DiagnosticId::INSTANCE_UNKNOWN);
	}
	const WeaponSnapshot &state = found->second;
	if (state.phase != WeaponPhase::RELOADING || !state.reload.has_value() ||
			state.reload->reservation_id != p_reservation_id ||
			state.reload->due_tick > p_tick) {
		return make_status(StatusCode::COMMAND_REJECTED, DiagnosticId::RESERVATION_REQUIRED);
	}
	const std::uint64_t expected_revision = state.revision;
	const std::uint64_t due_tick = state.reload->due_tick;
	const std::uint32_t reserved_rounds = state.reload->reserved_rounds;
	const BallisticProfileIdentity profile = state.reload->reserved_profile;

	// The participant registry is keyed directly by reservation id (design.md,
	// "Reload transaction": reservations are held "under an idempotency key"),
	// matching the sibling Inventory addon's PreparedQuantityReservations.
	ReloadParticipantOutcome prepared = prepare_reload_completion(
			p_reservation_id, p_instance_id, expected_revision, due_tick, reserved_rounds, profile, p_tick);
	if (!prepared.accepted) return prepared.status;
	ReloadParticipantOutcome committed = commit_reload_completion_silent(p_reservation_id);
	if (!committed.accepted) return committed.status;
	ReloadParticipantOutcome published = publish_reload_completion(p_reservation_id);
	if (!published.accepted) return published.status;

	r_completion.instance_id = published.instance_id;
	r_completion.reservation_id = p_reservation_id;
	r_completion.added_rounds = published.added_rounds;
	r_completion.revision = published.successor_revision;
	r_completion.loaded_rounds = published.loaded_rounds;
	r_completion.profile = published.profile;
	current_tick = std::max(current_tick, p_tick);
	return ok_status();
}

Status WeaponRuntime::advance_tick(std::uint64_t p_tick, std::vector<ReloadCompletion> &r_completions) {
	std::vector<ReloadCompletion> due;
	Status status = due_reloads(p_tick, due);
	if (!status.ok()) {
		r_completions.clear();
		return status;
	}
	r_completions.clear();
	for (const ReloadCompletion &candidate : due) {
		ReloadCompletion completion;
		status = commit_due_reload(
				p_tick,
				candidate.instance_id,
				candidate.reservation_id,
				completion);
		if (!status.ok()) {
			return status;
		}
		r_completions.push_back(std::move(completion));
	}
	current_tick = p_tick;
	return ok_status();
}

} // namespace wpn
