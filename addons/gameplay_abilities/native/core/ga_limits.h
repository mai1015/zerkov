#ifndef GAMEPLAY_ABILITIES_CORE_LIMITS_H
#define GAMEPLAY_ABILITIES_CORE_LIMITS_H

#include <cstddef>
#include <cstdint>

// Every bound the gameplay ability runtime enforces lives here so that the
// normative numbers are reviewable in one place and so decoding untrusted
// payloads can never allocate against an unvalidated count.
//
// These values are part of the wire contract: changing one changes the
// protocol version.
namespace ga {

// ---------------------------------------------------------------------------
// Versioning
// ---------------------------------------------------------------------------

// Public addon API version. Pre-1.0 while the reference vertical slice and a
// second representative game validate the contracts.
constexpr int GA_API_VERSION_MAJOR = 0;
constexpr int GA_API_VERSION_MINOR = 2;
constexpr int GA_API_VERSION_PATCH = 0;

// Wire protocol version. Incremented whenever a required packet meaning or the
// canonical encoding changes; mixed versions fail the handshake. Protocol 3
// adds the additive observable-task section to the public observer payload
// (`GameplayAbilityNetworkBridge::encode_public_state`/`decode_public_state`),
// gated by the required `FeatureSet::OBSERVER_TASK_STATE` bit -- see
// ga_version.h and docs/protocol.md's "Task state visibility" section.
// Protocol 4 (add-granular-delta-replication-2026-07-27, task 5.1) changes the
// MEANING of an owner `EVENT_BATCH` payload: it now carries a canonical
// granular delta (`ga::proto::encode_delta_batch`/`gap_delta_messages.h`)
// instead of a full component snapshot -- a wire-breaking change exactly like
// protocol 3's own additive section, gated the SAME way by a required
// `FeatureSet::DELTA_REPLICATION` bit (ga_version.h) so a peer that cannot
// decode deltas fails the handshake closed rather than misinterpreting a
// delta payload as a full snapshot.
constexpr std::uint16_t GA_PROTOCOL_VERSION = 4;

// Identifier of the content-manifest fingerprint algorithm, exchanged during
// the handshake so peers never compare fingerprints computed differently.
constexpr const char *GA_MANIFEST_ALGORITHM = "fnv1a64-canonical-v1";

// ---------------------------------------------------------------------------
// Deterministic numeric and timing representation
// ---------------------------------------------------------------------------

// Subunits per whole unit in the canonical signed 64-bit fixed-point format.
constexpr std::int64_t FIXED_SCALE = 1000000;

// Gameplay ticks per second. The rate is immutable for a session and is part of
// the handshake.
constexpr std::uint32_t DEFAULT_TICK_RATE = 60;
constexpr std::uint32_t MIN_TICK_RATE = 10;
constexpr std::uint32_t MAX_TICK_RATE = 240;

// ---------------------------------------------------------------------------
// Identifiers
// ---------------------------------------------------------------------------

constexpr std::size_t MAX_IDENTIFIER_BYTES = 128;
constexpr std::size_t MAX_IDENTIFIER_SEGMENTS = 8;

// ---------------------------------------------------------------------------
// Authoring and runtime state bounds
// ---------------------------------------------------------------------------

constexpr std::size_t MAX_QUERY_DEPTH = 4;
constexpr std::size_t MAX_QUERY_OPERANDS = 32;
constexpr std::size_t MAX_TAG_SOURCES = 512;
constexpr std::size_t MAX_ATTRIBUTES = 128;
constexpr std::size_t MAX_MODIFIERS = 256;
constexpr std::size_t MAX_ACTIVE_EFFECTS = 128;
// Task 5.3 (add-global-tag-catalog-and-reactions-2026-07-25): bound on the
// number of active `WHILE_PRESENT` reaction bindings a canonical component
// snapshot's own dedicated section (see ga_ability_component.h's
// `GA_SNAPSHOT_KIND_ABILITY_REACTION_BINDINGS`) may encode. Deliberately
// reuses `MAX_ACTIVE_EFFECTS`'s own value rather than introducing an
// independent number: every active binding is, by construction (task 4.4),
// bound to exactly one currently active effect handle, so the count of
// bindings can never exceed the count of active effects on the SAME
// component -- `MAX_ACTIVE_EFFECTS` is already a strict upper bound.
constexpr std::size_t MAX_ACTIVE_REACTION_BINDINGS = MAX_ACTIVE_EFFECTS;
constexpr std::size_t MAX_ABILITY_GRANTS = 64;
constexpr std::size_t MAX_ACTIVE_EXECUTIONS = 32;
constexpr std::size_t MAX_ACTIVE_ABILITY_TASKS = 32;
constexpr std::size_t MAX_ABILITY_TASKS_PER_EXECUTION = 8;
constexpr std::size_t MAX_TASK_TERMINAL_EVENTS_PER_TICK = 128;
// Bounds how many tasks may share one event/tag/input waiter index bucket
// (AbilityTaskRuntime::start, ga_ability_tasks.cpp). Deliberately equal to
// MAX_ACTIVE_ABILITY_TASKS rather than an independent number: no single
// bucket can ever hold more waiting tasks than the component has active
// tasks in total, so that check already makes this one unreachable today --
// enforced anyway (same reasoning as MAX_ACTIVE_REACTION_BINDINGS above) so
// the constant stays an honest, independently-checked contract.
constexpr std::size_t MAX_TASK_WAITS_PER_INDEX = MAX_ACTIVE_ABILITY_TASKS;
constexpr std::size_t MAX_TASK_PAYLOAD_BYTES = 256;
constexpr std::uint64_t MAX_TASK_DEADLINE_HORIZON_TICKS = 864000;
constexpr std::size_t MAX_TASK_INPUTS_PER_TICK = 128;
constexpr std::size_t MAX_EFFECT_MODIFIERS = 32;
constexpr std::size_t MAX_GRANTED_TAGS = 32;
constexpr std::size_t MAX_TARGETS_PER_COMMAND = 32;
constexpr std::size_t MAX_SET_BY_CALLER = 16;
constexpr std::size_t MAX_EVENT_RECURSION = 8;
constexpr std::size_t MAX_PERIODIC_CATCHUP = 64;
constexpr std::size_t MAX_STACK_COUNT = 999;

// ---------------------------------------------------------------------------
// Typed targeting bounds
// ---------------------------------------------------------------------------

constexpr std::size_t MAX_TARGET_SCHEMAS = 128;
constexpr std::size_t MAX_TARGET_HITS = 32;
constexpr std::size_t MAX_ACTIVE_TARGET_SESSIONS = 16;
constexpr std::size_t MAX_TARGET_SESSIONS_PER_EXECUTION = 4;
constexpr std::size_t MAX_TARGET_SUBMISSIONS_PER_SESSION = 128;
constexpr std::size_t MAX_TARGET_PROVIDER_WORK = 256;
constexpr std::size_t MAX_TARGET_BATCH_PARTICIPANTS = 32;
constexpr std::size_t MAX_TARGET_VALUE_BYTES = 2048;
constexpr std::int64_t MAX_TARGET_COORDINATE_RAW = INT64_C(1000000000000);
// Bound on the SUM of encoded bytes every currently-retained
// `TargetEffectContext` on one component may occupy at once (see
// `EffectRuntime`'s running counter, ga_effect_runtime.h/.cpp) -- independent
// of `MAX_ACTIVE_EFFECTS`, which bounds effect COUNT, not the bytes any one
// retained context may carry. Enforced at effect-application preflight
// (`StatusCode::CAPACITY_EXCEEDED` / `DiagnosticId::BYTE_LIMIT_EXCEEDED`),
// not at snapshot-encode time -- see budgets.md Finding 5.
//
// Derivation: a full canonical component snapshot with every OTHER section
// (tags at MAX_TAG_SOURCES, attributes at MAX_ATTRIBUTES/MAX_MODIFIERS,
// effects at MAX_ACTIVE_EFFECTS, ability grants/executions at
// MAX_ABILITY_GRANTS/MAX_ACTIVE_EXECUTIONS, MAX_ACTIVE_ABILITY_TASKS
// WAIT_TAG_QUERY tasks) at its own declared maximum, and NO retained target
// contexts at all (every active effect's own `target_context` absent, 1 byte
// each), measures exactly 48,497 bytes (see
// `budget_snapshot_full_component_with_tasks_and_retained_target_contexts_within_byte_budget`,
// ga_test_budgets.cpp, which derives this non-context baseline exactly --
// not estimated -- from the same fixture's own linear per-context cost).
// This file's own >= 50% headroom convention (see `MAX_SNAPSHOT_BYTES`'s own
// comment below) requires that combined worst case to stay at or under
// `MAX_SNAPSHOT_BYTES / 2` = 65,536 bytes, leaving at most 65,536 - 48,497 =
// 17,039 bytes available for retained-context growth before that headroom
// is exhausted. 12,288 stays comfortably under that ceiling -- a real
// margin, not the largest number that still barely fits. At the largest
// single retained shape (a HIT_SET `validated_result` at MAX_TARGET_HITS,
// independently measured at 2,315 bytes), this admits 5 such contexts on
// one component -- or many more of a smaller, more typical shape. Content-authoring
// guidance: `retain_target_context` is for SPARSE, deliberate use (a
// handful of effects whose originating aim/hit data genuinely needs to
// survive a resync), not for every concurrent effect on a component -- see
// docs/targeting.md.
constexpr std::size_t MAX_RETAINED_TARGET_CONTEXT_BYTES = 12288;

// ---------------------------------------------------------------------------
// Prediction bounds
// ---------------------------------------------------------------------------

constexpr std::size_t MAX_PENDING_PREDICTIONS = 16;
constexpr std::size_t MAX_PREDICTION_JOURNAL_OPS = 256;
// A predicted command older than this many ticks without acknowledgement is
// abandoned and the component falls back to server-confirmed behavior.
constexpr std::uint64_t MAX_PREDICTION_AGE_TICKS = 300;

// ---------------------------------------------------------------------------
// Change tracking (add-granular-delta-replication-2026-07-27, task 1.2)
// ---------------------------------------------------------------------------

// Depth of the bounded per-component, per-audience ring of dirty-revision
// summaries `ga::ChangeTracker` (ga_change_tracking.h) keeps. Unlike most of
// this file's bounds, this one is addon-internal server bookkeeping, not a
// wire quantity -- it never appears in an encoded payload and changing it
// does not change `GA_PROTOCOL_VERSION` -- so it is closer in spirit to
// `MAX_TRANSACTION_UNDO_OPS` (ga_transaction.h) than to `MAX_SNAPSHOT_BYTES`
// above; it lives here anyway (rather than beside the ring's own class)
// because it is exactly the kind of reviewable-in-one-place bound this file
// exists for, and because a later wave's per-peer cursor bookkeeping
// (design.md: "per-peer cursors and the dirty ring add server memory; both
// are limits-governed and overflow degrades to a snapshot") needs it
// documented alongside every other capacity number.
//
// A ring entry is appended once per committed transaction that advances an
// audience's revision (never once per mutation within it -- see
// `ChangeTracker::commit_change`), so depth bounds "how many CONSECUTIVE
// revision-advancing commits a peer may miss before its cursor falls off the
// ring and the server must fall back to a full snapshot"
// (`ChangeTracker::cursor_overflowed`), not how much gameplay state changed.
// 64 is a documented default, not a measured worst case (Wave 2/3 own the
// send cadence this trades off against -- see design.md's "Open Questions",
// "Heartbeat cadence default"): deep enough that a peer briefly starved of
// updates (a hitch, a burst of unrelated higher-priority traffic) still
// converges through deltas instead of paying for a resync, shallow enough
// that per-component memory never grows with session length regardless of
// how long a peer stays perfectly in sync (a synced peer's cursor tracks the
// head, so its own ring usage never grows past this constant either way).
constexpr std::size_t MAX_CHANGE_REVISION_RING_DEPTH = 64;

// ---------------------------------------------------------------------------
// Canonical delta codec (add-granular-delta-replication-2026-07-27, task 2.x)
// ---------------------------------------------------------------------------

// Upper bound on how many section deltas a single canonical delta batch may
// declare (`gap_delta_messages`/`ga_delta.h`). Mirrors `ga::CHANGE_SECTION_COUNT`
// (ga_change_tracking.h) exactly -- one section slot per `ChangeSection`
// enumerator, never more -- but is declared as its own literal here rather
// than referencing that enum, because `ga_limits.h` sits below
// `ga_change_tracking.h` in the include graph (every subsystem this file's
// OTHER bounds serve already treats `ga_limits.h` as foundational) and must
// never depend upward on it.
constexpr std::size_t MAX_DELTA_SECTIONS_PER_BATCH = 7;

// Upper bound on the record-operation count a single RECORD_OPS-mode section
// delta may declare, enforced identically on the encode side (never emit
// more) and the decode side (task 2.3: "operation counts... fail closed").
// Set to `MAX_TAG_SOURCES` (512), the largest of the per-section record caps
// this codec's six `AbilityComponent`-owned sections already observe
// (`MAX_TAG_SOURCES` 512 > `MAX_ATTRIBUTES`/`MAX_ACTIVE_EFFECTS` 128 >
// `MAX_ABILITY_GRANTS` 64 > `MAX_ACTIVE_EXECUTIONS`/`MAX_ACTIVE_ABILITY_TASKS`
// 32) -- one shared ceiling keeps the decode-side check uniform across every
// section kind rather than needing a per-kind table, while still never
// admitting more ops than the section's own snapshot codec could ever
// legally produce.
constexpr std::size_t MAX_DELTA_RECORD_OPS_PER_SECTION = MAX_TAG_SOURCES;

// Task 2.2's documented ops-vs-re-encode threshold: once a section delta's
// dirty-record count reaches this percentage of that section's current live
// record count, `ga::choose_delta_section_mode` (ga_delta.h/.cpp) chooses
// `DeltaSectionMode::FULL_REENCODE` over `RECORD_OPS`. A record op always
// carries strictly more per-entry overhead than that same record's row in
// the section's own compact snapshot layout (an 8-byte identity plus a
// 1-byte op tag, on top of an identical record body) -- so once ops would
// touch this large a fraction of the section, re-encoding the whole section
// in its native layout is never larger and is usually smaller. 60 is
// deliberately past the midpoint (a bare majority of touched records is not
// enough to flip the choice) so a session's ordinary bursty-but-partial
// churn stays on the cheaper, more diagnostic RECORD_OPS path.
constexpr std::uint8_t DELTA_SECTION_REENCODE_CHURN_PERCENT = 60;

// ---------------------------------------------------------------------------
// Heartbeat cadence (add-granular-delta-replication-2026-07-27, task 3.4/4.4)
// ---------------------------------------------------------------------------

// How many consecutive suppressed authoritative ticks elapse between
// heartbeats (`ga::proto::HeartbeatPayload`, protocol/gap_heartbeat.h) sent
// to a synced peer whose audience revision is unchanged -- design.md's
// "Heartbeat cadence default" open question, resolved here. Governs the
// SEND side only: this file's own heartbeat codec is send-cadence-agnostic
// (see gap_heartbeat.h), and the change-gating logic that schedules sends
// against this cadence is a later wave's concern -- this constant is named
// so that logic can consume it directly without inventing its own literal.
//
// Derived from `ga::ServerTickEstimator`'s own documented correction rule
// (`TICK_ESTIMATOR_SNAP_THRESHOLD_TICKS` / `TICK_ESTIMATOR_SMOOTH_DENOMINATOR`,
// ga_reconciliation.h -- this file cannot name those constants directly
// without an include cycle, since ga_reconciliation.h already includes this
// file, so the two are kept in sync by cross-reference comment, not by
// shared expression), not picked independently. A single `observe()` sample
// whose drift from the current estimate is <= the snap threshold (30 ticks)
// smooths by 1/4 of that drift; a larger single-sample drift snaps
// immediately to the newly observed offset. Setting cadence EQUAL to the
// snap threshold means the estimator is resampled at least once per tick
// window the size of its own "still smoothable, don't snap" boundary: no
// idle stretch, however long sends stay suppressed, ever leaves the
// estimate unrefreshed for longer than exactly one such window (spec
// "Tick estimation survives suppression" -- "continues to correct within
// documented smoothing bounds"). A shorter cadence would only trade more
// heartbeat bytes for a bound already dominated by RTT/jitter, not
// tick-estimator need; a longer cadence would let ordinary (non-snap-worthy)
// drift sit unrefreshed for stretches wider than the estimator's own
// smoothing granularity. Expressed in raw ticks (not wall time), like every
// other tick-scoped bound in this file (`MAX_PREDICTION_AGE_TICKS`,
// `MAX_TASK_DEADLINE_HORIZON_TICKS`), so it scales automatically with a
// session's own tick rate: at `MIN_TICK_RATE` (10) this is 3 seconds between
// heartbeats, at `MAX_TICK_RATE` (240) it is 125 milliseconds -- the
// "how many ticks can the estimate go stale" invariant stays constant
// regardless of how fast the session ticks.
constexpr std::uint64_t HEARTBEAT_SUPPRESSED_CADENCE_TICKS = 30;

// ---------------------------------------------------------------------------
// Packet bounds
// ---------------------------------------------------------------------------

constexpr std::size_t MAX_COMMAND_PACKET_BYTES = 1024;
constexpr std::size_t MAX_EVENT_BATCH_BYTES = 4096;
// Task 11.9: a canonical "Canonical Full Component Snapshot" (tags at
// MAX_TAG_SOURCES, attributes at MAX_ATTRIBUTES/MAX_MODIFIERS, effects at
// MAX_ACTIVE_EFFECTS, PLUS ability grants at MAX_ABILITY_GRANTS and active
// executions at MAX_ACTIVE_EXECUTIONS, all in ONE component) measures
// 39,281 bytes via `AbilityComponent::write_snapshot`
// (`budget_snapshot_full_component_with_abilities_at_declared_maximums`,
// native/tests/ga_test_budgets.cpp). The previous limit (32,768) could not
// hold even the tags+attributes+effects subset alone (34,079 bytes,
// -1,311 bytes / over by 4.0%) -- the spec requires generation to fail
// rather than truncate (see "Canonical Full Component Snapshots" / "Snapshot
// is too large", gameplay-ability-networking/spec.md), so a legal,
// documented-maximum component could never be replicated at all. 131,072
// leaves substantial headroom for task and targeting snapshot sections.
// Protocol 2 includes this bound together with Ability Tasks and Typed
// Targeting; peers presenting protocol 1 fail the handshake rather than
// relying on the earlier limit.
//
// That "substantial headroom" claim was asserted, not measured, until
// `budget_snapshot_full_component_with_tasks_and_retained_target_contexts_within_byte_budget`
// (native/tests/ga_test_budgets.cpp) measured it directly. Folding
// MAX_ACTIVE_ABILITY_TASKS (32) WAIT_TAG_QUERY tasks -- the largest-encoding
// task kind -- into the same 39,281-byte world costs only ~9,200 more bytes
// (~48,500 bytes total, comfortable headroom): tasks alone were never the
// risk. Retaining a worst-case `TargetEffectContext` (a HIT_SET
// `validated_result` at MAX_TARGET_HITS, independently measured at 2,315
// bytes) on EVERY ONE of that same world's MAX_ACTIVE_EFFECTS=128 active
// effects drove the TRUE size to 344,689 bytes -- 163.0% OVER
// MAX_SNAPSHOT_BYTES, not under it (the mechanism still failed closed
// correctly: a real, default-limited `SnapshotWriter` returned
// PAYLOAD_TOO_LARGE rather than truncating, so no peer could ever have
// received a corrupt snapshot from this combination -- but a legal component
// that turned `retain_target_context` on for most/all of its concurrent
// active effects at the largest schema shape could not be snapshotted at
// all).
//
// RESOLVED: `MAX_RETAINED_TARGET_CONTEXT_BYTES` (above) bounds the sum of
// every retained context's encoded bytes on one component, enforced at
// effect-application preflight rather than at snapshot-encode time, so a
// component can no longer accumulate more retained-context bytes than a
// canonical snapshot can carry. The achievable worst case -- the same
// tags+attributes+effects+abilities+tasks world, with as many active
// effects as fit inside `MAX_RETAINED_TARGET_CONTEXT_BYTES` retaining the
// same worst-case context (the rest not retaining one) -- now measures
// comfortably inside `MAX_SNAPSHOT_BYTES` with the required >= 50% headroom
// (see the SAME test above and budgets.md Finding 5, now marked RESOLVED,
// for the exact measured number).
// See protocol.md and budgets.md.
constexpr std::size_t MAX_SNAPSHOT_BYTES = 131072;
constexpr std::size_t MAX_HANDSHAKE_BYTES = 8192;
constexpr std::size_t MAX_STRING_BYTES = 128;
constexpr std::size_t MAX_DIAGNOSTIC_BYTES = 256;
constexpr std::size_t MAX_EVENTS_PER_BATCH = 128;
constexpr std::size_t MAX_COLLECTION_COUNT = 4096;

// ---------------------------------------------------------------------------
// Rate limits
// ---------------------------------------------------------------------------

constexpr std::uint32_t MAX_COMMANDS_PER_SECOND = 30;
constexpr std::uint32_t MAX_RESYNCS_PER_MINUTE = 6;

} // namespace ga

#endif // GAMEPLAY_ABILITIES_CORE_LIMITS_H
