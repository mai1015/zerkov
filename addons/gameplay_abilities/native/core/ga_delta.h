#ifndef GAMEPLAY_ABILITIES_CORE_DELTA_H
#define GAMEPLAY_ABILITIES_CORE_DELTA_H

#include "core/ga_change_tracking.h"
#include "core/ga_limits.h"

#include <cstddef>
#include <cstdint>
#include <map>
#include <set>
#include <vector>

// Canonical section-delta and record-operation primitives (add-granular-
// delta-replication-2026-07-27, task 2.1-2.2, "Granular Owner Delta
// Batches" / "Delta Protocol Compatibility" / "Deterministic Delta
// Convergence"). This file owns the SHARED vocabulary every section's own
// delta codec (`AttributeSet`, `TagContainer`, `EffectRuntime`,
// `AbilityTaskRuntime`, `AbilityComponent`'s own grant/execution sections --
// each alongside that class's existing `write_snapshot`/`restore_snapshot`,
// matching this addon's core/protocol split) builds on: the op/mode enums a
// decoder must validate as untrusted input, the deterministic ops-vs-
// re-encode rule (task 2.2), and the identity-existence ledger
// (`DeltaBaseline`) a delta encoder needs to label a touched record ADD vs.
// UPDATE. It does not itself encode or decode a single byte -- see
// `ga_ability_component.h`'s `write_delta_batch`/`apply_delta_batch` for the
// actual per-section codec, and `protocol/gap_delta_messages.h` for the
// byte-vector wire entry points built on top of it.
//
// -----------------------------------------------------------------------
// Why an explicit `DeltaBaseline` instead of re-deriving ADD vs. UPDATE
// -----------------------------------------------------------------------
// The server never keeps a full historical copy of a peer's last-confirmed
// section content -- only the peer's last-confirmed REVISION (a cursor) and
// `ChangeTracker`'s bounded ring of identities touched since then (see
// ga_change_tracking.h). A touched identity's CURRENT existence (live now)
// is cheap to query, but "did this identity exist BEFORE these touches" is
// not recoverable from the ring alone (a ring entry never records prior
// content, only "this identity changed"). `DeltaBaseline` makes that fact an
// explicit INPUT instead of an implicit assumption: the caller (a future
// wave's per-peer bookkeeping, or a test) supplies the identity set it
// already knows a peer has confirmed, and the encoder labels each touched,
// still-live identity ADD (absent from the baseline) or UPDATE (present in
// it) purely from that set membership -- never by guessing. A caller with no
// such bookkeeping yet (this wave) may pass an empty `DeltaBaseline`, which
// labels every still-live touched identity ADD; this is always a SAFE
// over-approximation (an apply treats ADD and UPDATE identically -- see
// `DeltaOpKind`'s own comment -- so mislabeling one as the other never
// produces incorrect resulting state, only a less informative op tag).
namespace ga {

// Wire "kind" bytes for this codec's own `SnapshotWriter`/`SnapshotReader`
// section framing (`AbilityComponent::write_delta_batch`/`apply_delta_batch`,
// ga_ability_component.cpp). Scoped to this codec's own nested sections, like
// every sibling subsystem's `GA_SNAPSHOT_KIND_*` (see ga_snapshot.h: a kind
// is only ever compared against the exact `begin_section` call decoding the
// bytes this codec itself wrote) -- chosen past every currently-assigned
// range (1-11 attributes/abilities, 30-31 tasks, 40-41 targeting) so this
// file can never collide with an existing subsystem's own section kind.
constexpr std::uint8_t GA_SNAPSHOT_KIND_DELTA_BATCH = 60;
constexpr std::uint8_t GA_SNAPSHOT_KIND_DELTA_SECTION = 61;
constexpr std::uint8_t GA_SNAPSHOT_KIND_DELTA_RECORD_OP = 62;

// Body-format version for the delta batch envelope itself (distinct from
// `GA_PROTOCOL_VERSION`, which this wave deliberately does not touch -- see
// this change's task list, "NO wire activation"). Mirrors
// `gap_task_messages.h`'s `TASK_MESSAGE_VERSION` precedent: an additive body
// version lets a stored/replayed delta-batch fixture reject an incompatible
// shape independently of the outer message envelope.
constexpr std::uint16_t DELTA_BATCH_VERSION = 1;

// One operation within a `DeltaSectionMode::RECORD_OPS` section delta (spec
// "Granular Owner Delta Batches": "record-level add, update, and remove
// operations"). ADD and UPDATE carry an IDENTICAL record body -- the
// record's current full content, written by the exact same per-record
// writer the corresponding snapshot section's own entries use (task 2.1:
// "reusing the existing snapshot record codecs") -- because applying either
// is the identical action: upsert this identity's content. The two values
// stay distinct on the wire (rather than collapsing to one "upsert" op)
// purely so a decoded batch can report how much of a section is newly
// appearing vs. merely changing (diagnostics, budget measurement) without a
// second pass over live state; `apply_delta_batch` itself never branches on
// which of the two a given op is (see that method's own doc comment).
enum class DeltaOpKind : std::uint8_t {
	ADD = 0,
	UPDATE = 1,
	REMOVE = 2,
};

inline bool is_valid_delta_op_kind(std::uint8_t p_raw) {
	return p_raw <= static_cast<std::uint8_t>(DeltaOpKind::REMOVE);
}

// How one section delta is encoded (design.md: "Delta payload = ordered
// dirty-section records with record-level ops; whole-section re-encode as
// the in-band fallback"). `FULL_REENCODE`'s body is ALWAYS exactly that
// section's own existing snapshot-section bytes (`AttributeSet::
// write_snapshot`/`write_snapshot_filtered`, `TagContainer::write_snapshot`/
// `write_snapshot_filtered`, `EffectRuntime::write_snapshot`,
// `AbilityTaskRuntime::write_snapshot`, or the grant/execution section
// bodies `AbilityComponent::write_snapshot` itself writes) -- literally the
// same writer call, so byte-identity to "the corresponding snapshot section"
// (spec "Granular Owner Delta Batches") is structural, not a separately
// maintained promise.
enum class DeltaSectionMode : std::uint8_t {
	RECORD_OPS = 0,
	FULL_REENCODE = 1,
};

inline bool is_valid_delta_section_mode(std::uint8_t p_raw) {
	return p_raw <= static_cast<std::uint8_t>(DeltaSectionMode::FULL_REENCODE);
}

inline bool is_valid_change_section(std::uint8_t p_raw) {
	return p_raw <= static_cast<std::uint8_t>(ChangeSection::TARGET_SESSION);
}

// Task 2.2's documented, deterministic ops-vs-re-encode rule: a pure
// function of two counts, so the SAME inputs choose the SAME mode on every
// run and every platform (spec "Deterministic Delta Convergence" / "Same
// inputs -> same choice -> same bytes"). Two triggers, checked in order:
//
//   1. `p_dirty_count` exceeds `MAX_DELTA_RECORD_OPS_PER_SECTION` -- a
//      RECORD_OPS section delta could never legally declare this many ops
//      (the SAME bound decode enforces, ga_limits.h), so re-encoding is the
//      only representable choice, not merely the cheaper one.
//   2. Churn: `p_dirty_count` reaches `DELTA_SECTION_REENCODE_CHURN_PERCENT`
//      of `p_live_count` (this section's CURRENT live record count -- what a
//      full re-encode would write). See `DELTA_SECTION_REENCODE_CHURN_PERCENT`'s
//      own doc comment (ga_limits.h) for why this approximates "ops would be
//      larger" without paying to build and compare both encodings.
//
// `p_live_count == 0` with `p_dirty_count > 0` (every touched record is now
// gone) always re-encodes: re-encoding an empty section costs a handful of
// framing bytes, cheaper than even a single REMOVE op.
inline DeltaSectionMode choose_delta_section_mode(std::size_t p_dirty_count, std::size_t p_live_count) {
	if (p_dirty_count > MAX_DELTA_RECORD_OPS_PER_SECTION) {
		return DeltaSectionMode::FULL_REENCODE;
	}
	if (p_live_count == 0) {
		return p_dirty_count > 0 ? DeltaSectionMode::FULL_REENCODE : DeltaSectionMode::RECORD_OPS;
	}
	const std::uint64_t churn_permille_numerator = static_cast<std::uint64_t>(p_dirty_count) * 100ULL;
	const std::uint64_t churn_threshold = static_cast<std::uint64_t>(p_live_count) * static_cast<std::uint64_t>(DELTA_SECTION_REENCODE_CHURN_PERCENT);
	if (churn_permille_numerator >= churn_threshold) {
		return DeltaSectionMode::FULL_REENCODE;
	}
	return DeltaSectionMode::RECORD_OPS;
}

// Per-audience, per-section record identities a delta ENCODER already knows
// a peer has confirmed -- see this file's own comment on why this is an
// explicit input rather than something re-derived from the dirty ring. Empty
// (default) is always safe: every touched, still-live identity then encodes
// as `DeltaOpKind::ADD` (see that enum's own comment on why mislabeling ADD
// vs. UPDATE never affects applied state, only the op tag's diagnostic
// value).
struct DeltaBaseline {
	std::map<ChangeSection, std::set<std::uint64_t>> known_identities;

	bool knows(ChangeSection p_section, std::uint64_t p_identity) const {
		const auto it = known_identities.find(p_section);
		return it != known_identities.end() && it->second.find(p_identity) != it->second.end();
	}
};

// Reduces `p_dirty` (as returned by `ChangeTracker::dirty_since`, oldest-
// entry-first and not deduplicated -- see that method's own doc comment) to
// the distinct identities touched for exactly `p_section`, in ascending
// order: the canonical per-section dirty-identity list every section's own
// delta encoder consumes (task 2.1's "canonically ordered ... record
// bodies").
inline std::vector<std::uint64_t> dirty_identities_for_section(const std::vector<DirtyRecord> &p_dirty, ChangeSection p_section) {
	std::set<std::uint64_t> unique;
	for (const DirtyRecord &record : p_dirty) {
		if (record.section == p_section) {
			unique.insert(record.identity);
		}
	}
	return std::vector<std::uint64_t>(unique.begin(), unique.end());
}

} // namespace ga

#endif // GAMEPLAY_ABILITIES_CORE_DELTA_H
