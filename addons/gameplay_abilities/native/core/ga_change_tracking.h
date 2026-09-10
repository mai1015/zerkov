#ifndef GAMEPLAY_ABILITIES_CORE_CHANGE_TRACKING_H
#define GAMEPLAY_ABILITIES_CORE_CHANGE_TRACKING_H

#include "core/ga_ids.h"
#include "core/ga_limits.h"

#include <cstdint>
#include <deque>
#include <set>
#include <vector>

// Per-audience change tracking (add-granular-delta-replication-2026-07-27,
// tasks 1.1-1.4, "Per-Audience Change Tracking"). This file owns exactly
// three things that a later wave's delta codec and bridge push logic (tasks
// 2.x/3.x) will read to decide WHAT changed and WHETHER a given peer already
// has it:
//   - which audiences exist (`ChangeAudience`) and which canonical snapshot
//     sections this ledger distinguishes (`ChangeSection`);
//   - the bounded per-component ring of per-revision dirty summaries
//     (`ChangeTracker`) that records stable record identities, never their
//     content;
//   - the engine-free seam (`AudienceVisibilityConfig`) a caller (a Godot
//     bridge in a later wave, or a test today) uses to say which identities
//     are PUBLIC-visible, so this file never has to know what a "hidden
//     attribute identifier" or a Godot `PackedStringArray` is.
//
// What this file deliberately does NOT do: encode bytes, decide payload
// shape, or reach into `AbilityComponent`/`GameplayAbilityWorldCoordinator`
// state itself. Callers (see `AbilityComponent`'s constructor-installed
// listeners, and `GameplayAbilityWorldCoordinator::emit_session_event`) hand
// this class already-resolved facts; this class only bookkeeps them.
namespace ga {

// Replication audiences a change can be relevant to (spec "Per-Audience
// Change Tracking"). OWNER_FACING is this component's own owning peer
// (everything not INTERNAL-only); PUBLIC is every other synced observer,
// already filtered by visibility.
enum class ChangeAudience : std::uint8_t {
	OWNER_FACING = 0,
	PUBLIC = 1,
};
constexpr std::size_t CHANGE_AUDIENCE_COUNT = 2;

// Canonical snapshot sections this ledger distinguishes. Mirrors the section
// list design.md's "Dirty tracking is transaction-driven" decision names,
// with one deliberate omission: COOLDOWN is not its own section. Cooldown
// state lives entirely on records ABILITY_GRANT and ACTIVE_EFFECT already
// cover (a grant's `cooldown_handle` and that handle's own active-effect
// timing -- see "Ability Costs and Cooldowns as Effects"), so a cooldown
// change is never a fact this ledger could miss by not having a section of
// its own for it.
enum class ChangeSection : std::uint8_t {
	ATTRIBUTE = 0,
	TAG_SOURCE = 1,
	ABILITY_GRANT = 2,
	ACTIVE_EXECUTION = 3,
	ACTIVE_EFFECT = 4,
	ABILITY_TASK = 5,
	TARGET_SESSION = 6,
};
constexpr std::size_t CHANGE_SECTION_COUNT = 7;

// One touched record's stable identity within its section: the
// `Handle<Tag>::value` (or `DefinitionId`) of whichever protocol identity
// `section` names -- attribute id, tag source token, ability spec id,
// execution id, effect handle, task handle, or target-session id (see the
// spec's "bounded ring of per-revision dirty summaries" wording). Never the
// record's CONTENT: a later wave's delta codec re-reads live state for that;
// this ledger only ever answers "did section S's record I know as identity V
// change since revision R", not "to what".
struct DirtyRecord {
	ChangeSection section = ChangeSection::ATTRIBUTE;
	std::uint64_t identity = 0;

	bool operator==(const DirtyRecord &p_other) const {
		return section == p_other.section && identity == p_other.identity;
	}
	bool operator!=(const DirtyRecord &p_other) const {
		return !(*this == p_other);
	}
};

// One ring slot: every distinct dirty fact marked while producing `revision`.
// `revision` values are always contiguous and strictly ascending within one
// `ChangeTracker` audience's ring -- see `ChangeTracker::commit_change`.
struct ChangeRevisionEntry {
	std::uint64_t revision = 0;
	std::vector<DirtyRecord> records;
};

// Engine-free predicate the bridge populates (a later wave, from its
// `hidden_attributes`/`hidden_tags`/`hidden_abilities` Godot-side
// `PackedStringArray` sets -- see
// `GameplayAbilityNetworkBridge::encode_public_state`, translated to core
// identities at the boundary) and that core tests populate directly. Says
// which identities are visible to the PUBLIC audience, for the three
// sections that have NO visibility marker of their own on the record:
//   - ABILITY_TASK and TARGET_SESSION already carry a per-record visibility
//     marker in core (`AbilityTaskRequest::visibility` /
//     `TargetSchemaDesc::visibility`, decided via
//     `task_visible_to`/`visible_to`); callers resolve PUBLIC-visibility for
//     those two sections from that marker directly and never consult this
//     struct -- consulting a SECOND, independent hidden-set here would let
//     the two disagree.
//   - ACTIVE_EXECUTION and ACTIVE_EFFECT have no public exposure at all
//     today (`GameplayAbilityNetworkBridge::encode_public_state` encodes
//     neither section) -- callers mark them OWNER_FACING only until a later
//     wave defines what "public execution/effect visibility" means.
//
// Default-constructed: every identity is public (empty hidden sets),
// matching `GameplayAbilityNetworkBridge`'s own default (nothing hidden
// until a game explicitly configures it).
struct AudienceVisibilityConfig {
	std::set<DefinitionId> hidden_attributes;
	std::set<DefinitionId> hidden_tags;
	std::set<DefinitionId> hidden_abilities;

	bool attribute_public(DefinitionId p_attribute) const {
		return hidden_attributes.find(p_attribute) == hidden_attributes.end();
	}
	bool tag_public(DefinitionId p_tag) const {
		return hidden_tags.find(p_tag) == hidden_tags.end();
	}
	bool ability_public(DefinitionId p_ability) const {
		return hidden_abilities.find(p_ability) == hidden_abilities.end();
	}
};

// Per-component, per-audience change ledger (spec "Per-Audience Change
// Tracking" / "Delta Bounds and Snapshot Fallback"). Two independent
// audience states (OWNER_FACING, PUBLIC) each own a monotonic revision and a
// bounded ring of `ChangeRevisionEntry` -- see `commit_change`.
//
// -----------------------------------------------------------------------
// Why this class never touches `Transaction`
// -----------------------------------------------------------------------
// Every caller of `commit_change` (see `AbilityComponent`'s constructor-
// installed listeners, and `GameplayAbilityWorldCoordinator::
// emit_session_event`) is ALREADY past the point where the work it is
// reporting could still roll back: `AttributeSet`/`TagContainer`/
// `EffectRuntime`/ability-lifecycle notifications only ever dispatch (see
// `NotificationQueue::dispatch()`) once their owning `Transaction` has
// actually committed -- `Transaction::commit()` calls `rollback()` instead
// of ever enqueuing a notification for a failed transaction (see
// ga_transaction.cpp) -- and `GameplayAbilityWorldCoordinator`'s own session
// mutations are synchronous with no `Transaction` participation at all (see
// ga_targeting.h's file comment). So "a rolled-back transaction marks
// nothing" (spec scenario) and "undo restores prior dirty state" both fall
// out structurally: `commit_change` is simply never called for work that did
// not, or might not yet, durably happen -- there is no speculative ledger
// state to undo in the first place.
//
// This mirrors this addon's own existing precedent for the identical
// problem: `AbilityComponent::flush_tag_reactions` (ga_ability_component.h)
// accumulates `TagChangeRecord`s -- which, by design, carry no transaction
// identity of their own (see that struct's file comment) -- into a pending
// set during dispatch, and only acts on the pending set once dispatch()
// returns, rather than reaching for `Transaction::add_undo`. Change tracking
// follows the same shape: `AbilityComponent` accumulates dirty facts via
// listeners installed on `attributes()`/`tags()`/`effects()`/ability-task and
// -lifecycle notifications, then flushes the accumulated per-audience lists
// into this class exactly once, immediately after each of its own
// commit-and-`queue.dispatch()` call sites.
class ChangeTracker {
public:
	// Advances `p_audience`'s revision by exactly one and appends a new ring
	// entry holding `p_records`, evicting the oldest entry once already at
	// `MAX_CHANGE_REVISION_RING_DEPTH`. Callers are not required to
	// deduplicate `p_records` themselves -- a duplicate identity is harmless,
	// just slightly wasteful. A no-op -- revision unchanged, nothing
	// appended -- if `p_records` is empty: nothing visible to this audience
	// changed, so nothing may advance (spec: "Mutations invisible to an
	// audience MUST NOT advance that audience's revision").
	void commit_change(ChangeAudience p_audience, std::vector<DirtyRecord> p_records);

	// Out-of-band, non-transactional resync: advances EVERY audience's
	// revision by one and clears its ring, without recording any dirty
	// record (there is no specific record to name -- see below). Call this
	// whenever something that is not itself a gameplay transaction changes
	// what an audience can see. The one documented case today: a bridge
	// reconfiguring `AudienceVisibilityConfig` (a previously-hidden
	// attribute/tag/ability becoming visible, or vice versa -- see that
	// struct's own comment) changes PUBLIC-visible state without any
	// transaction ever running, so there is nothing a normal `commit_change`
	// call could mark.
	//
	// Advancing BOTH audiences -- not only PUBLIC, the one a visibility
	// reconfiguration actually touches -- is a deliberate simplification: it
	// is always safe (a resync a peer did not strictly need only costs one
	// wasted snapshot, never incorrect state), and it keeps this entry
	// point's contract a single unconditional statement ("every peer of
	// every audience must treat this component as fully stale") instead of
	// two audience-scoped ones a caller could apply inconsistently. The ring
	// is CLEARED, not merely appended to, because entries recorded under the
	// OLD visibility configuration could otherwise be replayed as a delta
	// under the NEW one and silently mis-encode which peer should have seen
	// what.
	void force_full_resync();

	std::uint64_t revision(ChangeAudience p_audience) const;

	// True if `p_cursor` (a peer's last-confirmed revision for `p_audience`)
	// can no longer be bridged to the current head using only ring-held
	// entries -- some intervening revision's summary already fell off the
	// ring (spec "Delta Bounds and Snapshot Fallback": "its change cursor
	// exceeds the documented per-component change-history bound"). A cursor
	// at or ahead of the current revision is never overflowed (there is
	// nothing to deliver).
	bool cursor_overflowed(ChangeAudience p_audience, std::uint64_t p_cursor) const;

	// Every ring-held entry for `p_audience`, oldest first. Empty either
	// because nothing has ever been marked for this audience (`revision() ==
	// 0`) or because every entry has since been evicted -- compare against
	// `revision()` to tell the two apart (or just call `cursor_overflowed`).
	const std::deque<ChangeRevisionEntry> &ring(ChangeAudience p_audience) const;

	// Every `DirtyRecord` marked for `p_audience` in ring entries strictly
	// newer than `p_cursor` (revision > p_cursor), oldest-entry-first,
	// unsorted and not deduplicated within that order (a duplicate identity
	// across two entries is harmless -- see `commit_change`'s own comment;
	// callers that want a canonical per-section identity set reduce this
	// themselves, exactly like `ga_delta.cpp`'s batch builder does). This is
	// the read side of task 2.1's "dirty snapshot sections" input: a delta
	// batch encoder calls this once per audience to learn what changed since
	// a peer's last-confirmed revision, rather than re-deriving it from the
	// ring by hand.
	//
	// The caller MUST check `cursor_overflowed(p_audience, p_cursor)` first
	// -- this method does not itself detect that condition. A cursor already
	// off the ring silently returns only what the ring still holds (a
	// STRICT SUBSET of everything that actually changed), which is exactly
	// the wrong input for a correct delta: the missing revisions must fall
	// back to a full snapshot instead (spec "Delta Bounds and Snapshot
	// Fallback"), not be silently under-reported as a smaller delta.
	std::vector<DirtyRecord> dirty_since(ChangeAudience p_audience, std::uint64_t p_cursor) const;

private:
	struct AudienceState {
		std::uint64_t revision_value = 0;
		std::deque<ChangeRevisionEntry> ring_entries;
	};

	AudienceState &state_for(ChangeAudience p_audience);
	const AudienceState &state_for(ChangeAudience p_audience) const;

	AudienceState states[CHANGE_AUDIENCE_COUNT];
};

} // namespace ga

#endif // GAMEPLAY_ABILITIES_CORE_CHANGE_TRACKING_H
