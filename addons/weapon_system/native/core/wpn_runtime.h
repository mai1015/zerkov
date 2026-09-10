#ifndef WEAPON_SYSTEM_CORE_RUNTIME_H
#define WEAPON_SYSTEM_CORE_RUNTIME_H

#include "core/wpn_catalog.h"
#include "core/wpn_status.h"

#include <cstdint>
#include <deque>
#include <map>
#include <optional>
#include <string>
#include <vector>

namespace wpn {

struct FixedVec2 {
	std::int64_t x = 0;
	std::int64_t y = 0;

	bool operator==(const FixedVec2 &p_other) const { return x == p_other.x && y == p_other.y; }
};

enum class WeaponPhase : std::uint8_t {
	READY = 0,
	RELOADING = 1,
};

// Exact ammunition-ballistic-profile identity carried by loaded rounds,
// reservations, and committed shots (tasks.md 4.12; weapon-runtime spec,
// "Deterministic Weapon Instance State": "optional exact ballistic-profile
// identity"). Deliberately just an id/version pair -- the profile's own
// sealed content (trait, and any game-owned penetration data) lives in
// catalog::AmmunitionBallisticProfile, never duplicated here.
struct BallisticProfileIdentity {
	std::string id;
	std::uint16_t version = 1;

	bool operator==(const BallisticProfileIdentity &p_other) const {
		return id == p_other.id && version == p_other.version;
	}
	bool operator!=(const BallisticProfileIdentity &p_other) const { return !(*this == p_other); }
};

// One accepted slot->attachment binding in a weapon instance's canonical flat
// loadout (tasks.md 4.11; weapon-runtime spec, "Atomic Flat Attachment
// Loadout"). `attachment_version` names the exact sealed AttachmentDefinition
// version accepted into this slot.
struct AttachmentLoadoutEntry {
	std::string slot_id;
	std::string attachment_id;
	std::uint16_t attachment_version = 1;

	bool operator==(const AttachmentLoadoutEntry &p_other) const {
		return slot_id == p_other.slot_id && attachment_id == p_other.attachment_id &&
				attachment_version == p_other.attachment_version;
	}
};

struct ReloadState {
	std::string reservation_id;
	std::uint32_t reserved_rounds = 0;
	std::uint64_t start_tick = 0;
	std::uint64_t due_tick = 0;
	// Exact ballistic-profile identity this reservation carries (tasks.md
	// 4.12; weapon-runtime spec, "Simple Tick-Based Reload": "Beginning a
	// reload MUST identify ... exact ballistic-profile identity whose sealed
	// trait matches the weapon"). Always populated for an accepted reload --
	// unlike WeaponSnapshot::loaded_profile, a reload always names exactly
	// one profile, so this is not optional.
	BallisticProfileIdentity reserved_profile;

	bool operator==(const ReloadState &p_other) const {
		return reservation_id == p_other.reservation_id &&
				reserved_rounds == p_other.reserved_rounds &&
				start_tick == p_other.start_tick &&
				due_tick == p_other.due_tick &&
				reserved_profile == p_other.reserved_profile;
	}
};

struct WeaponSnapshot {
	std::string instance_id;
	std::string definition_id;
	std::uint16_t definition_version = 1;
	std::uint64_t revision = 0;
	bool has_last_command_sequence = false;
	std::uint64_t last_command_sequence = 0;
	std::uint32_t loaded_rounds = 0;
	// Present exactly when loaded_rounds > 0 (weapon-runtime spec,
	// "Deterministic Weapon Instance State"). Fire copies this onto the
	// committed shot before clearing it on the last round (tasks.md 4.12).
	std::optional<BallisticProfileIdentity> loaded_profile;
	bool has_last_fire_tick = false;
	std::uint64_t last_fire_tick = 0;
	WeaponPhase phase = WeaponPhase::READY;
	std::optional<ReloadState> reload;

	// --- Authority scope/epoch/tick command envelope (tasks.md 4.13;
	// weapon-runtime spec, "Canonical Revision and Authority-Tick
	// Semantics") ---
	// Stable authority scope this instance is bound to. Set once at
	// create_instance()/replace_from_snapshots() time; a command whose
	// claimed scope does not match is rejected as a foreign-scope command
	// before it can even be admitted (never merely "unknown instance").
	std::string authority_scope;
	// Current trusted authority epoch. Only a trusted replacement snapshot
	// (replace_from_snapshots()) may change this -- never a regular command.
	std::uint64_t authority_epoch = 0;
	// Non-regressing floor: the highest authority tick any command has been
	// validated against so far. A later command whose trusted tick is below
	// this floor is rejected as authority_tick_regression before sequence
	// admission.
	std::uint64_t authority_tick_floor = 0;
	// Per (authority scope, instance, authority epoch) monotonic admitted-
	// sequence high-watermark, independent from the bounded outcome cache in
	// WeaponRuntime::command_history. Advances for both accepted transitions
	// and deterministic gameplay rejections; a malformed envelope rejected
	// before admission never advances it.
	std::uint64_t admitted_sequence_high_watermark = 0;
	// Latched true by a checked tick-arithmetic fault (e.g. an overflowing
	// reload due-tick calculation). While true every command against this
	// instance is rejected until a trusted replacement snapshot starts a new
	// epoch (which implies constructing the incoming snapshot with this
	// false again).
	bool tick_unhealthy = false;

	// --- Deterministic recoil kick/recovery (tasks.md 4.10) ---
	// Vertical/horizontal recoil offsets stored at `recoil_anchor_tick`,
	// in integer nanoradians. Effective recoil at any later authority tick
	// is a pure derivation (wpn_numerics.h's compute_effective_recoil_offset_nrad),
	// never a stored per-tick value.
	std::int64_t recoil_vertical_offset_nrad = 0;
	std::int64_t recoil_horizontal_offset_nrad = 0;
	std::uint64_t recoil_anchor_tick = 0;

	// --- Flat attachment loadout (tasks.md 4.11) ---
	// Canonical accepted slot->attachment projection, kept sorted by slot_id.
	// Bounded by MAX_ATTACHMENT_SLOTS_PER_WEAPON.
	std::vector<AttachmentLoadoutEntry> attachment_loadout;

	// Full-fidelity fingerprint, including authority scope/epoch/tick-floor
	// and the admitted-sequence high-watermark. Used for snapshot/restore
	// equality (weapon-runtime spec, "Snapshot is restored").
	std::uint64_t fingerprint() const;
	// Fingerprint over gameplay-relevant mechanical state ONLY -- everything
	// EXCEPT the admission-bookkeeping fields (authority_tick_floor,
	// admitted_sequence_high_watermark, tick_unhealthy) that the Shared
	// Authoritative Command Gate (tasks.md 4.13) deliberately advances even
	// for a deterministic gameplay rejection. Use this (not fingerprint())
	// to assert "a rejected command mutated nothing mechanically" -- the
	// weapon-runtime spec's "Expected revision is stale" scenario names
	// exactly this narrower set explicitly: "loaded rounds, cadence, phase,
	// and revision remain unchanged" while "the admitted sequence records
	// that rejection for duplicate safety" (a bookkeeping-only change).
	std::uint64_t mechanical_fingerprint() const;
	bool operator==(const WeaponSnapshot &p_other) const;
};

// One revisioned tombstone left behind by an accepted teardown (tasks.md
// 4.13; weapon-runtime spec's revision matrix: "teardown/tombstone"),
// retained within WeaponRuntime's bounded history (MAX_TOMBSTONES) after the
// live instance itself is removed.
struct WeaponTombstone {
	std::string instance_id;
	std::string authority_scope;
	std::uint64_t authority_epoch = 0;
	std::uint64_t revision = 0;
};

// Versioned canonical consequence identity (tasks.md 4.13; weapon-runtime
// spec, "Semi-Automatic Fire Transition": "a versioned canonical value
// containing a fixed domain identifier, authority scope/epoch, weapon
// instance, accepted successor revision, and command identity"). Full-value
// equality (operator==) is the ONLY canonical comparison; compact_hash() may
// index this value (e.g. as a map key) but MUST NOT replace operator== for
// identity decisions.
constexpr std::uint16_t CONSEQUENCE_IDENTITY_VERSION = 1;
// Sealed fixed domain identifier distinguishing a weapon-system committed-
// shot consequence from any other future consequence-identity domain.
constexpr std::uint32_t CONSEQUENCE_DOMAIN_WEAPON_SHOT = 1;

struct ConsequenceIdentity {
	std::uint16_t version = CONSEQUENCE_IDENTITY_VERSION;
	std::uint32_t domain = CONSEQUENCE_DOMAIN_WEAPON_SHOT;
	std::string authority_scope;
	std::uint64_t authority_epoch = 0;
	std::string instance_id;
	std::uint64_t successor_revision = 0;
	std::string command_id;

	bool operator==(const ConsequenceIdentity &p_other) const {
		return version == p_other.version && domain == p_other.domain &&
				authority_scope == p_other.authority_scope &&
				authority_epoch == p_other.authority_epoch &&
				instance_id == p_other.instance_id &&
				successor_revision == p_other.successor_revision &&
				command_id == p_other.command_id;
	}
	bool operator!=(const ConsequenceIdentity &p_other) const { return !(*this == p_other); }

	// Compact index-only hash; NEVER a substitute for operator== (weapon-
	// runtime spec: "a compact hash MUST NOT replace full-value equality").
	std::uint64_t compact_hash() const;
};

// One signed parts-per-million modifier contribution, tagged with the
// canonical ordering keys used to fold deltas deterministically
// (weapon-authoring spec, "Canonical Modifier Algebra": "sum deltas in
// canonical source, slot-ID, and definition-ID order"). Declared here
// (rather than in core/wpn_numerics.h, where fold_modifier_deltas_ppm()
// consuming it lives) because wpn_numerics.h already depends on this header
// for FixedVec2; declaring it here instead of there avoids a circular
// include.
struct ModifierDelta {
	std::string source;
	std::string slot_id;
	std::string definition_id;
	std::uint16_t definition_version = 0;
	std::int64_t delta_ppm = 0;
};

struct AuthorityContext {
	bool actor_live = false;
	bool weapon_equipped = false;
	bool weapon_usable = false;
	FixedVec2 authoritative_origin;
	FixedVec2 authoritative_aim;
	std::int64_t spread_modifier_ppm = 1000000;
	std::int64_t damage_modifier_ppm = 1000000;
	std::int64_t range_modifier_ppm = 1000000;
	std::int64_t noise_modifier_ppm = 1000000;
	// Authority-derived recoil-control multiplier (1e6 neutral, like its
	// siblings above). Folded into the same canonical recoil-kick delta
	// algebra as attachment recoil modifiers; affects new kick magnitude
	// only, never the sealed recovery slope (design.md, "Canonical numeric
	// contract").
	std::int64_t recoil_modifier_ppm = 1000000;
};

// Every mutating command below carries the same authority-created envelope
// identity fields (weapon-runtime spec, "Shared Authoritative Command
// Gate"): command_id/sequence/instance_id/expected_revision/tick, plus the
// authority scope/epoch this instance must currently be bound to. Declared
// flat (not a nested sub-struct) on each command so existing field-by-field
// construction keeps working; `tick` remains the trusted authority tick
// supplied by the caller's authority context, never an untrusted command
// payload (see protocol/wpn_protocol_types.h's *Intent DTOs, which
// deliberately omit it).

struct FireCommand {
	std::string command_id;
	std::uint64_t sequence = 0;
	std::string instance_id;
	std::uint64_t expected_revision = 0;
	std::uint64_t tick = 0;
	std::string authority_scope;
	std::uint64_t authority_epoch = 0;
	FixedVec2 claimed_origin;
	FixedVec2 claimed_aim;
	std::uint64_t spread_seed = 0;
};

struct BeginReloadCommand {
	std::string command_id;
	std::uint64_t sequence = 0;
	std::string instance_id;
	std::uint64_t expected_revision = 0;
	std::uint64_t tick = 0;
	std::string authority_scope;
	std::uint64_t authority_epoch = 0;
	std::string reservation_id;
	std::uint32_t reserved_rounds = 0;
	// Exact ballistic-profile identity this reservation carries (tasks.md
	// 4.12). Required: begin_reload rejects when this does not resolve to a
	// sealed catalog profile whose trait matches the weapon.
	BallisticProfileIdentity profile;
};

struct CancelReloadCommand {
	std::string command_id;
	std::uint64_t sequence = 0;
	std::string instance_id;
	std::uint64_t expected_revision = 0;
	std::uint64_t tick = 0;
	std::string authority_scope;
	std::uint64_t authority_epoch = 0;
};

// Complete bounded desired slot->attachment loadout (tasks.md 4.11;
// weapon-runtime spec, "Atomic Flat Attachment Loadout"). Entries not naming
// a declared slot are unknown; a slot the game wants empty is simply absent
// from `desired_loadout` -- this is NOT a delta/patch against the previous
// loadout, it wholesale replaces it.
struct ConfigureAttachmentsCommand {
	std::string command_id;
	std::uint64_t sequence = 0;
	std::string instance_id;
	std::uint64_t expected_revision = 0;
	std::uint64_t tick = 0;
	std::string authority_scope;
	std::uint64_t authority_epoch = 0;
	std::vector<AttachmentLoadoutEntry> desired_loadout;
};

struct TeardownCommand {
	std::string command_id;
	std::uint64_t sequence = 0;
	std::string instance_id;
	std::uint64_t expected_revision = 0;
	std::uint64_t tick = 0;
	std::string authority_scope;
	std::uint64_t authority_epoch = 0;
};

struct CommittedShot {
	// Legacy compact consequence-id string (`command_id + ":shot"`), kept
	// verbatim for source compatibility with native/godot's Dictionary
	// façade and core/wpn_world_ports.h's DamageRequest/NoiseRequest, which
	// are out of this task's scope. `consequence_identity` below is now the
	// CANONICAL versioned value (tasks.md 4.13); this string is a derived,
	// non-canonical convenience projection of it.
	std::string consequence_id;
	// Canonical versioned consequence identity (tasks.md 4.13). Full-value
	// equality (ConsequenceIdentity::operator==) is authoritative.
	ConsequenceIdentity consequence_identity;
	std::string instance_id;
	std::string weapon_id;
	std::uint16_t weapon_version = 1;
	std::string shot_profile_id;
	std::uint16_t shot_profile_version = 1;
	std::uint64_t tick = 0;
	FixedVec2 origin;
	FixedVec2 direction;
	std::int64_t damage_milliunits = 0;
	std::int64_t range_milliunits = 0;
	std::int64_t noise_radius_milliunits = 0;
	// Exact ballistic-profile identity consumed by this shot (tasks.md
	// 4.12), copied from the instance's loaded profile before it is cleared
	// on the last round.
	BallisticProfileIdentity consumed_profile;
};

struct CommandOutcome {
	bool accepted = false;
	bool replayed = false;
	Rejection rejection = Rejection::NONE;
	Status status;
	std::uint64_t revision = 0;
	std::uint32_t loaded_rounds = 0;
	std::optional<CommittedShot> shot;
	std::optional<std::string> reservation_to_release;

	bool operator==(const CommandOutcome &p_other) const;
};

struct ReloadCompletion {
	std::string instance_id;
	std::string reservation_id;
	std::uint32_t added_rounds = 0;
	std::uint64_t revision = 0;
	std::uint32_t loaded_rounds = 0;
	// The instance's resulting loaded-profile identity after this
	// completion (tasks.md 4.12); always present since added_rounds > 0
	// implies loaded_rounds > 0 for an accepted completion.
	std::optional<BallisticProfileIdentity> profile;
};

// Outcome of one prepared reload-completion participant call (tasks.md 4.14;
// weapon-runtime spec, "Prepared Reload Completion Participant"). Mirrors
// the sibling inventory addon's QuantityReservationResult shape
// (addons/inventory_system/native/core/inv_quantity_reservations.h).
struct ReloadParticipantOutcome {
	bool accepted = false;
	bool replayed = false;
	Status status;
	std::string reservation_id;
	std::string instance_id;
	std::uint64_t predecessor_revision = 0;
	std::uint64_t successor_revision = 0;
	std::uint32_t added_rounds = 0;
	std::uint32_t loaded_rounds = 0;
	std::optional<BallisticProfileIdentity> profile;
};

class WeaponRuntime {
public:
	explicit WeaponRuntime(const WeaponCatalog &p_catalog) :
			catalog(p_catalog) {}

	Status create_instance(
			const std::string &p_instance_id,
			const std::string &p_definition_id,
			std::uint16_t p_definition_version,
			std::uint32_t p_loaded_rounds,
			const std::optional<BallisticProfileIdentity> &p_profile = std::nullopt,
			const std::string &p_authority_scope = std::string(),
			std::uint64_t p_authority_epoch = 0);
	Status remove_instance(const std::string &p_instance_id, std::optional<std::string> &r_reservation_to_release);
	const WeaponSnapshot *find_instance(const std::string &p_instance_id) const;
	const WeaponTombstone *find_tombstone(const std::string &p_instance_id) const;
	std::vector<WeaponSnapshot> snapshots() const;
	// Trusted replacement of the entire instance set. This is the one and
	// only way an instance's authority_epoch/tick_unhealthy fields may
	// change outside admitted mutation: a trusted caller supplying a
	// snapshot with a new epoch value and tick_unhealthy=false is exactly
	// "a trusted replacement snapshot starts a new epoch" (weapon-runtime
	// spec, "Canonical Revision and Authority-Tick Semantics").
	Status replace_from_snapshots(const std::vector<WeaponSnapshot> &p_snapshots);

	CommandOutcome fire(const FireCommand &p_command, const AuthorityContext &p_authority);
	CommandOutcome begin_reload(const BeginReloadCommand &p_command);
	CommandOutcome cancel_reload(const CancelReloadCommand &p_command);
	CommandOutcome configure_attachments(const ConfigureAttachmentsCommand &p_command);
	CommandOutcome teardown(const TeardownCommand &p_command);

	// Authority-driven usability-change side effect (weapon-runtime spec's
	// revision matrix: "usability change that cancels reload"). Not a client
	// command -- no command_id/sequence/payload-digest admission, mirroring
	// advance_tick()'s authority-owned shape -- but still respects the same
	// scope/epoch/tick-floor discipline. A no-op (weapon not reloading, or
	// becoming usable again) leaves revision unchanged.
	Status notify_usability_change(
			const std::string &p_instance_id,
			const std::string &p_authority_scope,
			std::uint64_t p_authority_epoch,
			std::uint64_t p_authority_tick,
			bool p_usable,
			CommandOutcome &r_outcome);

	// Pure recoil query (tasks.md 4.10): derives each effective recoil axis
	// at `p_authority_tick` without mutating any state. Fails closed
	// (ARITHMETIC_ERROR) if `p_authority_tick` is before the instance's
	// stored recoil anchor.
	Status effective_recoil(
			const std::string &p_instance_id,
			std::uint64_t p_authority_tick,
			std::int64_t &r_vertical_offset_nrad,
			std::int64_t &r_horizontal_offset_nrad) const;

	// Cross-system coordinators first inspect due reloads without mutation,
	// then commit one exact reservation only after their other participant is
	// prepared. `advance_tick()` remains the convenience all-in-one path for
	// games whose ammunition source is not Inventory System. Both are now
	// implemented in terms of the prepared reload-completion participant
	// below (prepare -> commit_silent -> publish), so there is exactly one
	// mutation path.
	Status due_reloads(std::uint64_t p_tick, std::vector<ReloadCompletion> &r_due) const;
	Status commit_due_reload(
			std::uint64_t p_tick,
			const std::string &p_instance_id,
			const std::string &p_reservation_id,
			ReloadCompletion &r_completion);
	Status advance_tick(std::uint64_t p_tick, std::vector<ReloadCompletion> &r_completions);

	// --- Prepared reload-completion participant (tasks.md 4.14) ---
	// Bounded authority-only prepared participant for a due reload: validates
	// the expected weapon revision, phase, due tick, reservation token, exact
	// quantity/profile, capacity, and profile trait before creating an
	// unpublished successor. Supports idempotent commit, rollback to its
	// immediate predecessor before publication, and exactly one accepted
	// publication; retries return the recorded terminal outcome. A direct
	// non-Inventory reload (due_reloads()/commit_due_reload()/advance_tick()
	// above) uses this same contract as a one-participant coordinator.
	ReloadParticipantOutcome prepare_reload_completion(
			const std::string &p_reservation_id,
			const std::string &p_instance_id,
			std::uint64_t p_expected_revision,
			std::uint64_t p_due_tick,
			std::uint32_t p_reserved_rounds,
			const BallisticProfileIdentity &p_profile,
			std::uint64_t p_authority_tick);
	ReloadParticipantOutcome commit_reload_completion_silent(const std::string &p_reservation_id);
	ReloadParticipantOutcome rollback_reload_completion(const std::string &p_reservation_id);
	ReloadParticipantOutcome publish_reload_completion(const std::string &p_reservation_id);

	std::size_t instance_count() const { return instances.size(); }
	std::size_t command_history_count() const { return command_history.size(); }
	std::size_t tombstone_count() const { return tombstones.size(); }
	std::size_t reload_participant_count() const { return reload_participants.size(); }

private:
	struct RecordedCommand {
		std::uint64_t payload_hash = 0;
		CommandOutcome outcome;
	};

	enum class ReloadParticipantState : std::uint8_t {
		PREPARED = 0,
		COMMITTED = 1,
		ROLLED_BACK = 2,
		PUBLISHED = 3,
	};

	struct ReloadParticipantRecord {
		std::string instance_id;
		std::uint64_t expected_revision = 0;
		std::uint64_t due_tick = 0;
		std::uint32_t reserved_rounds = 0;
		BallisticProfileIdentity profile;
		ReloadParticipantState state = ReloadParticipantState::PREPARED;
		std::optional<WeaponSnapshot> predecessor;
		ReloadParticipantOutcome terminal_outcome;
	};

	std::optional<CommandOutcome> replay_or_conflict(const std::string &p_command_id, std::uint64_t p_payload_hash) const;
	void record_command(const std::string &p_command_id, std::uint64_t p_payload_hash, const CommandOutcome &p_outcome);
	CommandOutcome rejected(const WeaponSnapshot *p_state, Rejection p_rejection, DiagnosticId p_diagnostic) const;
	const WeaponDefinition *definition_for(const WeaponSnapshot &p_state) const;
	static bool valid_fixed_vector(const FixedVec2 &p_value, std::int64_t p_limit, bool p_allow_zero);
	static bool origin_compatible(const FixedVec2 &p_claimed, const FixedVec2 &p_authoritative, std::int64_t p_tolerance);
	static bool aim_compatible(const FixedVec2 &p_claimed, const FixedVec2 &p_authoritative, std::int64_t p_tolerance_microradians);

	// Shared Authoritative Command Gate (tasks.md 4.13). Runs the identity
	// portion of admission common to every command type: idempotency replay/
	// conflict, instance existence, authority scope match, structural
	// validity (caller-computed), authority epoch match, latched
	// unhealthiness, authority-tick non-regression, and sequence admission
	// against the epoch high-watermark. Returns false with r_outcome already
	// populated (and, for every case except tick regression, already
	// recorded in command_history) when the caller must return immediately.
	// Returns true with r_state pointing at the live instance -- and the
	// sequence watermark plus tick floor already advanced -- when the caller
	// should proceed with its own revision/phase/gameplay-specific checks
	// and is responsible for calling record_command() with its own final
	// outcome.
	bool admit(
			const std::string &p_command_id,
			std::uint64_t p_sequence,
			const std::string &p_instance_id,
			std::uint64_t p_authority_tick,
			const std::string &p_authority_scope,
			std::uint64_t p_authority_epoch,
			std::uint64_t p_payload_hash,
			bool p_structurally_valid,
			WeaponSnapshot *&r_state,
			CommandOutcome &r_outcome);

	// Per-axis RAW (unfolded) modifier deltas contributed by the instance's
	// accepted attachment loadout (tasks.md 4.11), in no particular order --
	// the caller appends its own authority-supplied delta (if any) and folds
	// each axis's complete delta list through wpn_numerics.h's
	// fold_modifier_deltas_ppm() exactly once, so every property is clamped
	// once total rather than once per contributing source (weapon-runtime
	// spec, "Canonical numeric contract": "sums deltas ... clamps the
	// aggregate multiplier once").
	struct AttachmentModifierDeltas {
		std::vector<ModifierDelta> accuracy;
		std::vector<ModifierDelta> recoil;
		std::vector<ModifierDelta> noise;
		std::vector<ModifierDelta> reload_duration;
		std::vector<ModifierDelta> cadence;
	};
	void collect_attachment_modifier_deltas(const WeaponSnapshot &p_state, AttachmentModifierDeltas &r_deltas) const;

	void insert_tombstone(const std::string &p_instance_id, const std::string &p_scope, std::uint64_t p_epoch, std::uint64_t p_revision);
	void trim_reload_participant_records();
	static ReloadParticipantOutcome outcome_for_participant(
			const std::string &p_reservation_id, const ReloadParticipantRecord &p_record, bool p_replayed);

	const WeaponCatalog &catalog;
	std::map<std::string, WeaponSnapshot> instances;
	std::map<std::string, RecordedCommand> command_history;
	std::deque<std::string> command_order;
	std::map<std::string, WeaponTombstone> tombstones;
	std::deque<std::string> tombstone_order;
	std::map<std::string, ReloadParticipantRecord> reload_participants;
	std::deque<std::string> reload_participant_terminal_order;
	std::uint64_t current_tick = 0;
};

} // namespace wpn

#endif // WEAPON_SYSTEM_CORE_RUNTIME_H
