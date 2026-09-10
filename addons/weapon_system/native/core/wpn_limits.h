#ifndef WEAPON_SYSTEM_CORE_LIMITS_H
#define WEAPON_SYSTEM_CORE_LIMITS_H

#include <cstddef>
#include <cstdint>

namespace wpn {

constexpr int API_VERSION_MAJOR = 0;
constexpr int API_VERSION_MINOR = 1;
constexpr int API_VERSION_PATCH = 0;
// Bumped 1 -> 2 for tasks.md 7.8/7.9 (weapon-protocol spec, "Versioned
// Canonical Weapon Protocol" / weapon-platform-support spec, "Pre-1.0
// Evolution"): a breaking wire change that extends CompatibilityHandshake
// (world-geometry versions), WeaponSnapshot/WeaponSnapshotEnvelope/Batch
// (authority epoch/tick-floor/sequence baseline/tick-health, recoil anchor
// state, flat attachment loadout, optional loaded ballistic-profile
// identity, tombstones), ReloadState (reserved ballistic-profile identity),
// CommittedShot (canonical consequence identity, consumed ballistic-profile
// identity), WeaponDelta (lifecycle/tombstone), WeaponTransitionEvent
// (CONFIGURE_ATTACHMENTS kind, tombstone), and adds ConfigureAttachmentsIntent.
// A peer still declaring protocol_version 1 MUST fail compatibility
// explicitly (see check_handshake_compatibility()) rather than silently
// misinterpreting the new wire shape -- see
// wpn_test_protocol_codec.cpp's protocol_version_bump_rejects_the_superseded_v1_required_version.
constexpr std::uint16_t PROTOCOL_VERSION = 2;
constexpr std::uint16_t RESOURCE_SCHEMA_VERSION = 1;
constexpr const char *MANIFEST_ALGORITHM = "fnv1a64-canonical-v1";

constexpr std::size_t MAX_IDENTIFIER_BYTES = 128;
constexpr std::size_t MAX_SOURCE_LABEL_BYTES = 256;
constexpr std::size_t MAX_STRING_BYTES = 256;
constexpr std::size_t MAX_CATALOG_DEFINITIONS = 4096;
constexpr std::size_t MAX_MANIFEST_ENTRIES = 8192;
constexpr std::size_t MAX_MANIFEST_ENTRY_BYTES = 65536;
constexpr std::size_t MAX_MANIFEST_BYTES = 1048576;

constexpr std::size_t MAX_WEAPON_INSTANCES = 4096;
constexpr std::size_t MAX_ACTIVE_RELOADS = 1024;
constexpr std::size_t MAX_IDEMPOTENCY_RECORDS = 4096;
constexpr std::size_t MAX_MODIFIERS_PER_COMMAND = 16;
constexpr std::size_t MAX_TARGET_CANDIDATES = 512;
constexpr std::size_t MAX_EVENTS_PER_TICK = 8192;

constexpr std::size_t MAX_COMMAND_BYTES = 4096;
constexpr std::size_t MAX_SNAPSHOT_BYTES = 1048576;
constexpr std::size_t MAX_DELTA_BYTES = 262144;
constexpr std::size_t MAX_PACKET_BYTES = 262144;

constexpr std::int64_t DIRECTION_SCALE = 1000000;
constexpr std::int64_t MAX_DIRECTION_COMPONENT = DIRECTION_SCALE;
constexpr std::int64_t MAX_WORLD_MILLIUNITS = 1000000000;
constexpr std::int64_t MAX_ANGLE_MICRORADIANS = 3141593;
constexpr std::int64_t MAX_DAMAGE_MILLIUNITS = 1000000000;
constexpr std::uint32_t MAX_CAPACITY = 1000000;
constexpr std::uint32_t MAX_TICK_DURATION = 3600000;
constexpr std::int64_t MAX_NOISE_MILLIUNITS = 1000000000;

// --- Sealed numeric contract (weapon-authoring: Unambiguous Integer MOA
// Authoring; weapon-runtime: Deterministic Shot Direction) ---
// `NANORADIANS_PER_RADIAN` is the fixed-point scale (1 radian == 1e9
// nanoradians). `PI_NANORADIANS` is the sealed V1 integer representation of
// pi in that same scale, used by the milli-MOA -> nanoradian formula
// `round_half_up(accuracy_moa_milli * PI_NANORADIANS / MOA_MILLI_TO_NANORADIAN_DENOMINATOR)`.
constexpr std::int64_t NANORADIANS_PER_RADIAN = 1000000000;
constexpr std::int64_t PI_NANORADIANS = 3141592654;
constexpr std::int64_t MOA_MILLI_TO_NANORADIAN_DENOMINATOR = 21600000;
constexpr std::int64_t MAX_ACCURACY_MOA_MILLI = 60000; // sealed V1 limit: 60 MOA full-group diameter
constexpr std::int64_t MAX_ANGLE_NANORADIANS = PI_NANORADIANS; // half-turn bound for nanoradian angle fields

// --- Recoil profile bounds (weapon-authoring: Versioned Recoil and Flat
// Attachment Definitions) ---
constexpr std::int64_t MAX_RECOIL_KICK_NRAD = 50000000; // per-shot kick bound (~2.9 degrees)
constexpr std::int64_t MAX_RECOIL_OFFSET_NRAD = 200000000; // accumulated-offset bound (~11.5 degrees)
constexpr std::int64_t MAX_RECOVERY_PER_TICK_NRAD = MAX_RECOIL_OFFSET_NRAD;

// --- Flat attachment loadout bounds ---
constexpr std::size_t MAX_ATTACHMENT_SLOTS_PER_WEAPON = 8;
constexpr std::size_t MAX_ATTACHMENT_COMPATIBLE_TAGS = 8;

// --- Canonical modifier algebra bounds (weapon-authoring: Canonical Modifier
// Algebra) ---
constexpr std::int64_t MODIFIER_NEUTRAL_PPM = 1000000; // 100%, zero delta
constexpr std::int64_t MAX_MODIFIER_DELTA_PPM = 500000; // +/-50% per single signed delta
constexpr std::int64_t MIN_MODIFIER_MULTIPLIER_PPM = 0;
constexpr std::int64_t MAX_MODIFIER_MULTIPLIER_PPM = 4000000; // 0%..400% aggregate multiplier
constexpr std::size_t MAX_MODIFIER_FOLD_DELTAS = 64;

// --- Versioned deterministic seed sampling (weapon-runtime: Deterministic
// Shot Direction / Deterministic Recoil Kick and Recovery) ---
constexpr std::size_t MAX_REJECTION_SAMPLING_ATTEMPTS = 64;

// --- Bounded catalog diagnostics (weapon-authoring: Bounded Catalog
// Diagnostics) ---
constexpr std::size_t MAX_DIAGNOSTIC_FINDINGS = 32;

// Sealed V1 world-geometry contract (task 6.8 / weapon-world-integration
// spec, "Canonical World Geometry Values"). All authoritative world ports
// exchange coordinates, radii, and ray distances under this one integer
// milliunit scale. Both versions below are sealed inputs to the
// compatibility fingerprint (see CompatibilityManifest) so a mismatched
// quantization algorithm or tie-break rule fails compatibility instead of
// silently diverging between two authorities.
//
// WORLD_QUANTIZATION_VERSION covers: checked-integer ray-circle entry
// distance, the deterministic bit-by-bit integer square root, round-half-
// away-from-zero unit-direction/impact-point scaling, and the sealed
// per-axis coordinate bound (MAX_WORLD_MILLIUNITS) that a computed
// intersection/impact point must not exceed.
constexpr std::uint16_t WORLD_QUANTIZATION_VERSION = 1;
// WORLD_TIE_RULE_VERSION covers: obstruction wins an equal target-entry/
// obstruction distance tie; the lower stable target ID wins an equal
// target-entry-distance tie; nothing in range misses at the canonical
// range-limit point.
constexpr std::uint16_t WORLD_TIE_RULE_VERSION = 1;

// --- Protocol layer bounds (tasks.md 7.1-7.4: canonical DTOs, codecs,
// admission gates, and snapshot/delta convergence). Additive to the sealed
// V1 wire contract; every one of these participates in the same
// "bounded before allocation or iteration" discipline the MAX_* constants
// above already establish for the core boundary. Command/session-scoped
// identifier strings (command id, reservation id, instance id, definition
// id) all reuse MAX_IDENTIFIER_BYTES rather than declaring parallel
// independent caps -- one identifier grammar/limit pair, per
// wpn_identifier.h's validate_identifier().

// Bounded per-message collection counts for protocol DTOs that batch several
// per-instance records (protocol/wpn_protocol_types.h's WeaponDeltaBatch,
// AcknowledgementBatch, and replica-side full-resync snapshot batches).
constexpr std::size_t MAX_DELTAS_PER_BATCH = 512;
constexpr std::size_t MAX_ACKNOWLEDGEMENTS_PER_BATCH = 512;
constexpr std::size_t MAX_SNAPSHOTS_PER_BATCH = MAX_WEAPON_INSTANCES;

// Admission-gate (protocol/wpn_command_gate.h) tick-based rate limiting:
// per-peer weapon-command and resync-request token buckets, mirroring the
// sibling gameplay_abilities addon's gap_command_gate.h RateLimiter.
constexpr std::uint32_t DEFAULT_TICK_RATE = 60;
constexpr std::uint32_t MAX_COMMANDS_PER_SECOND = 30;
constexpr std::uint32_t MAX_RESYNCS_PER_MINUTE = 6;

// Admission-gate untrusted-input bookkeeping caps: a hostile peer flooding
// distinct sessions/instances/peers must never grow gate memory without
// bound. Exceeding a cap evicts the least-recently-touched entry.
constexpr std::size_t MAX_TRACKED_PEERS = 1024;
constexpr std::size_t MAX_BOUND_INSTANCES_PER_PEER = 256;
constexpr std::size_t MAX_TRACKED_COMMAND_STATES = 2048;
constexpr std::size_t MAX_DUPLICATE_RESULT_CACHE = 32;
constexpr std::size_t MAX_RATE_LIMIT_BUCKETS = 2048;

// --- Authority scope/epoch/tick command envelope, recoil, flat attachment
// loadout, ballistic-profile identity, and prepared reload-completion
// participant (tasks.md 4.10-4.14). Additive to the sealed V1 core
// contract. ---

// Bounded retention of revisioned teardown tombstones (design.md, "Revision,
// tick, and idempotency model": "Item destruction ... creates one revisioned
// tombstone ... after bounded replication/idempotency retention").
constexpr std::size_t MAX_TOMBSTONES = 4096;

// Bounded records for the prepared reload-completion participant
// (weapon-runtime spec, "Prepared Reload Completion Participant"), keyed by
// reservation id, independent from `instances`/`command_history` above.
constexpr std::size_t MAX_RELOAD_PARTICIPANT_RECORDS = 2048;

// A weapon instance's complete accepted attachment loadout is bounded by
// MAX_ATTACHMENT_SLOTS_PER_WEAPON above (one entry per declared slot at
// most); no separate constant is needed for the runtime-side loadout.

// --- World coordinator unresolved-consequence retention (task 6.8
// remainder / weapon-world-integration spec, "Explicit World Adapter
// Failure": "Committed shot is restored before consequence completion").
// Additive. Bounds how many committed shots whose consequence could not be
// confirmed (a world-query/quantization fault, or a HIT whose damage-sink
// response came back AMBIGUOUS) WorldCoordinator retains at once, keyed by
// their own versioned ConsequenceIdentity; the oldest entry is evicted
// first when full, mirroring MAX_IDEMPOTENCY_RECORDS' bounded-FIFO shape.
constexpr std::size_t MAX_UNRESOLVED_CONSEQUENCES = 1024;

// --- Presentation-only client prediction (tasks.md 7.6; weapon-protocol
// spec, "Presentation-Only Client Prediction"). Additive. Bounds
// protocol/wpn_prediction.h's PresentationPredictionTracker -- an owning
// network client bridge's own bookkeeping of in-flight, presentation-only
// predicted commands (muzzle/animation/audio/crosshair/reload-bar cues),
// never canonical ammo/reload/hit/damage state. Exceeding
// MAX_PENDING_PRESENTATION_INTENTS evicts the oldest still-pending intent
// (reported EXPIRED) rather than growing without bound;
// MAX_PRESENTATION_INTENT_AGE_TICKS additionally bounds how long an intent
// may remain unresolved before a periodic sweep expires it even under the
// capacity, so a lost acknowledgement/rejection can never strand a
// presentation cue forever.
constexpr std::size_t MAX_PENDING_PRESENTATION_INTENTS = 64;
constexpr std::uint64_t MAX_PRESENTATION_INTENT_AGE_TICKS = 300; // 5s at the default 60 tick/s rate.

} // namespace wpn

#endif // WEAPON_SYSTEM_CORE_LIMITS_H
