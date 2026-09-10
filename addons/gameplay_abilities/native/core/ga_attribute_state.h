#ifndef GAMEPLAY_ABILITIES_CORE_ATTRIBUTE_STATE_H
#define GAMEPLAY_ABILITIES_CORE_ATTRIBUTE_STATE_H

#include "core/ga_attributes.h"
#include "core/ga_fixed.h"
#include "core/ga_ids.h"
#include "core/ga_limits.h"
#include "core/ga_snapshot.h"
#include "core/ga_status.h"
#include "core/ga_transaction.h"

#include <cstdint>
#include <functional>
#include <map>
#include <string>
#include <vector>

// Per-component attribute runtime state: `AttributeValue` (base/current/
// revision) and `AttributeSet`, the container that owns one component's
// initialized attributes and active modifiers.
//
// -----------------------------------------------------------------------
// Aggregation model (read this before calling anything below)
// -----------------------------------------------------------------------
//
// `AttributeSet::recompute_value()` is the ONE place `current` is ever
// derived. It is a pure query -- it reads `base` plus whatever is presently
// in the modifier table and returns a result; it never mutates state. Every
// mutating entry point (`set_base`, `add_modifier`, `remove_modifier`,
// `apply_costs`) calls it, inspects the `Status`, and only THEN commits the
// new `current`/`revision`/change-record. There is no second, incremental
// "apply this one modifier's delta" path -- this is deliberate: the spec
// requires recomputing from "base + the complete active modifier set" on
// every relevant change and forbids ever reversing a modifier by subtracting
// a previously evaluated delta, and the only way to make that structurally
// impossible (not just avoided by convention) is to have exactly one
// function that computes `current`, from scratch, every time.
//
// Phases, in order, exactly as the spec names them:
//   1. ADD       -- running sum via `fixed_add`, starting from `base`.
//   2. MULTIPLY  -- running product via `fixed_mul`, continuing from the ADD
//                   phase's result. `magnitude` is the direct multiplicative
//                   factor (e.g. 0.5 halves, 2.0 doubles) -- not a "percent
//                   bonus added to 1.0" -- so chaining multiple MULTIPLY
//                   modifiers is a straightforward running product.
//   3. OVERRIDE  -- if any OVERRIDE modifier targets this attribute, the one
//                   that sorts first in canonical order (see below) replaces
//                   the running value outright; otherwise this phase is a
//                   no-op and the ADD+MULTIPLY result stands.
//   4. CLAMP     -- if the definition has `has_min`/`has_max`, the phase-3
//                   result is clamped with `fixed_max`/`fixed_min`. This is
//                   the ONLY place clamping happens; nothing upstream of
//                   this line ever clamps. The pre-clamp value is preserved
//                   as `AttributeChangeRecord::requested_current` and the
//                   post-clamp value as `new_current`, so a clamped mutation
//                   always reports both (per the "Bounds and Clamping"
//                   requirement).
//
// Within phases 1-3, modifiers that tie in `op` are ordered by the spec's
// documented tie-breakers, ascending: `priority`, then `source` identity
// (`SourceToken::value`), then `effect` identity (`EffectHandle::value`),
// then `declaration_index`. "Ascending" is this file's one arbitrary choice
// among two symmetric options; the important, spec-mandated property is that
// the order is stable and identical for every peer, which ascending-by-value
// trivially is. For OVERRIDE, "sorts first" is exactly this same order --
// the modifier least in this order wins; removing it promotes whichever
// remaining OVERRIDE modifier now sorts first, or falls back to the
// ADD+MULTIPLY result if none remain.
//
// ADD is applied as a running sum (not "sum then add once") -- and, unlike
// real-number addition, that is NOT a distinction without a difference here:
// `fixed_add` is exact and overflow-checked, so an intermediate partial sum
// can overflow even when the final mathematical total would not. Every peer
// must see the SAME intermediate overflow behavior, which requires a fixed
// canonical application order -- hence the tie-breakers apply to phase 1
// too, not only to OVERRIDE selection. MULTIPLY has the same requirement for
// a second reason: `fixed_mul` rounds (half away from zero), and rounding
// breaks associativity, so a different application order can legitimately
// produce a different final integer even without overflow.
//
// A `ModifierHandle` (this file's own `Handle<Tag>` instantiation, see
// ga_ids.h) is a purely local, insertion-order-dependent identity issued by
// `add_modifier` so a caller (an effect, when section 5 is built) can later
// call `remove_modifier`. It is NOT part of a modifier's canonical identity
// and therefore never appears in a canonical snapshot or participates in any
// ordering: two components that reached equivalent modifier sets through
// different insertion histories would otherwise be assigned different handle
// numbers for "the same" modifier, which would break the byte-identical-
// snapshot requirement. Snapshots instead serialize modifiers sorted by
// `(target_attribute, op, priority, source, effect, declaration_index)` --
// content-derived and therefore history-independent.
namespace ga {

// One attribute's authoritative/evaluated state. `base` and `current` are
// deliberately kept as two separate fields rather than one "value that
// modifiers mutate in place" -- see the aggregation model above.
struct AttributeValue {
	Fixed base = Fixed::zero();
	Fixed current = Fixed::zero();
	// Bumped exactly once per committed change to this attribute (base
	// change, modifier add/remove that changes `current`). Left at 0 by
	// `initialize_attribute` -- initialization establishes state, it does
	// not "change" it.
	RevisionCounter revision;
};

// V1's three modifier operations, evaluated in exactly this phase order
// (see file comment).
enum class ModifierOp : std::uint8_t {
	ADD = 0,
	MULTIPLY = 1,
	OVERRIDE = 2,
};

// A local, session-scoped identity for one active modifier instance, issued
// by `AttributeSet::add_modifier`. See the file comment for why this is
// deliberately excluded from canonical ordering and snapshots.
struct ModifierHandleTag {};
using ModifierHandle = Handle<ModifierHandleTag>;
constexpr ModifierHandle INVALID_MODIFIER_HANDLE{ 0 };

// One active modifier. `source` and `effect` are the stable identities the
// spec names as tie-breakers; `declaration_index` disambiguates multiple
// modifiers declared by the same effect (e.g. its Nth declared modifier).
struct AttributeModifier {
	DefinitionId target_attribute = INVALID_DEFINITION_ID;
	ModifierOp op = ModifierOp::ADD;
	Fixed magnitude = Fixed::zero();
	std::int32_t priority = 0;
	SourceToken source = INVALID_SOURCE_TOKEN;
	EffectHandle effect = INVALID_EFFECT_HANDLE;
	std::uint32_t declaration_index = 0;
};

// Whether a committed change originated from authoritative simulation or
// from a client's local prediction. The prediction/reconciliation layer
// (section 8) reads this to decide whether a record can be trusted as a
// confirmed baseline or must be treated as provisional.
enum class ChangeProvenance : std::uint8_t {
	AUTHORITATIVE = 0,
	PREDICTED = 1,
};

// An immutable record of one committed attribute change. Captured BY VALUE
// into a `Transaction` notification closure (see ga_transaction.h) and
// handed to listeners as `const &`, so a listener structurally cannot alter
// it. `requested_current` is the phase-3 (pre-clamp) result;
// `new_current` is the phase-4 (post-clamp, effective) result -- identical
// when no clamping occurred, which is how a caller distinguishes "clamped"
// from "not clamped" without a separate flag.
struct AttributeChangeRecord {
	DefinitionId attribute = INVALID_DEFINITION_ID;
	Fixed old_base = Fixed::zero();
	Fixed new_base = Fixed::zero();
	Fixed old_current = Fixed::zero();
	Fixed new_current = Fixed::zero();
	Fixed requested_current = Fixed::zero();
	std::uint64_t revision = 0;
	TransactionId transaction;
	ChangeProvenance provenance = ChangeProvenance::AUTHORITATIVE;
};

// One cost line for `AttributeSet::apply_costs`: "subtract `amount` from
// `attribute`'s base, but only if every cost in the batch is affordable."
struct AttributeCost {
	DefinitionId attribute = INVALID_DEFINITION_ID;
	Fixed amount = Fixed::zero();
};

// Snapshot section kinds this file writes/reads. Scoped to this file's own
// nested sections -- a sibling subsystem's snapshot code opens and closes
// its own sections and never needs to agree on these values (see
// ga_snapshot.h: a kind is only ever compared against the `begin_section`
// call that is decoding the exact bytes this file itself wrote).
constexpr std::uint8_t GA_SNAPSHOT_KIND_ATTRIBUTE_SET = 1;
constexpr std::uint8_t GA_SNAPSHOT_KIND_ATTRIBUTE_ENTRY = 2;
constexpr std::uint8_t GA_SNAPSHOT_KIND_MODIFIER_ENTRY = 3;

// Per-component attribute state. Constructed against a sealed
// `AttributeRegistry` (definitions must already have their final
// `DefinitionId`s); the registry outlives the `AttributeSet` and is never
// copied or owned by it.
//
// Every mutating method takes both a `Transaction&` and the
// `NotificationQueue&` that will eventually dispatch it. The queue
// reference is threaded through so the notification closure registered with
// the transaction can pass it to listeners -- exactly how a listener gets
// access to `NotificationQueue::request_mutation()` to defer a reentrant
// mutation instead of applying it inline (see `add_listener`).
class AttributeSet {
public:
	explicit AttributeSet(const AttributeRegistry &p_registry) :
			registry(&p_registry) {}

	// ---------------------------------------------------------------
	// Initialization
	// ---------------------------------------------------------------

	// Initializes attribute `p_id` on this component. `base` becomes the
	// definition's default, or `p_override_base` if `p_has_override` is
	// true (the "validated initialization override" the spec names --
	// validation is simply that `p_id` names a registered definition and
	// has not already been initialized here; the override is already a
	// `Fixed`, so no further quantization applies). `current` becomes the
	// fully evaluated and clamped result against zero active modifiers.
	//
	// Fails with:
	//   - `StatusCode::UNKNOWN_ATTRIBUTE` if `p_id` is not in `registry`.
	//   - `StatusCode::ALREADY_EXISTS` if already initialized here.
	//   - `StatusCode::CAPACITY_EXCEEDED` past `MAX_ATTRIBUTES`.
	Status initialize_attribute(DefinitionId p_id, bool p_has_override, Fixed p_override_base,
			Transaction &p_txn, NotificationQueue &p_queue,
			ChangeProvenance p_provenance = ChangeProvenance::AUTHORITATIVE);

	// ---------------------------------------------------------------
	// Reads -- never create state implicitly.
	// ---------------------------------------------------------------

	bool has_attribute(DefinitionId p_id) const;
	Status get_base(DefinitionId p_id, Fixed &r_value) const;
	Status get_current(DefinitionId p_id, Fixed &r_value) const;
	Status get_value(DefinitionId p_id, AttributeValue &r_value) const;

	// Every initialized attribute, in canonical (ascending DefinitionId)
	// order.
	std::vector<DefinitionId> initialized_attributes() const;

	bool has_modifier(ModifierHandle p_handle) const;
	Status get_modifier(ModifierHandle p_handle, AttributeModifier &r_value) const;
	std::size_t modifier_count() const { return modifiers.size(); }

	// Diagnostic-only instrumentation for task 4.7's budget test (see
	// ga_test_budgets.cpp): counts, cumulatively since construction or the
	// last `reset_modifier_scan_visit_count()`, how many (handle, modifier)
	// entries `ordered_modifiers_for` has examined. This is NOT part of the
	// aggregation contract, never influences a `Status`/value result, and no
	// gameplay path reads it -- it exists only so a test can prove, as a hard
	// operation count rather than wall-clock timing, that one recompute's
	// scan cost is bounded by the TARGET attribute's own modifier count, not
	// by how many other modifiers/attributes coexist in the component.
	std::uint64_t modifier_scan_visit_count() const { return modifier_scan_visits; }
	void reset_modifier_scan_visit_count() { modifier_scan_visits = 0; }

	// ---------------------------------------------------------------
	// Mutations
	// ---------------------------------------------------------------

	// Sets `p_id`'s base to `p_new_base` and recomputes `current` from that
	// new base plus the complete active modifier set. Fails with
	// `StatusCode::UNKNOWN_ATTRIBUTE` if uninitialized, or
	// `StatusCode::ARITHMETIC_ERROR` if aggregation overflows -- in which
	// case NOTHING is mutated (see file comment: `recompute_value` is a
	// pure query, called before any state is touched).
	Status set_base(DefinitionId p_id, Fixed p_new_base,
			Transaction &p_txn, NotificationQueue &p_queue,
			ChangeProvenance p_provenance = ChangeProvenance::AUTHORITATIVE);

	// Adds `p_modifier` and recomputes its target attribute. `r_handle`
	// receives the new modifier's local removal identity. Fails with
	// `StatusCode::UNKNOWN_ATTRIBUTE` if the target is uninitialized,
	// `StatusCode::CAPACITY_EXCEEDED` past `MAX_MODIFIERS`, or
	// `StatusCode::ARITHMETIC_ERROR` on overflow (nothing mutated).
	Status add_modifier(const AttributeModifier &p_modifier, ModifierHandle &r_handle,
			Transaction &p_txn, NotificationQueue &p_queue,
			ChangeProvenance p_provenance = ChangeProvenance::AUTHORITATIVE);

	// Removes a previously added modifier and recomputes its target
	// attribute from the remaining set. Fails with
	// `StatusCode::UNKNOWN_MODIFIER` if `p_handle` is not active.
	Status remove_modifier(ModifierHandle p_handle,
			Transaction &p_txn, NotificationQueue &p_queue,
			ChangeProvenance p_provenance = ChangeProvenance::AUTHORITATIVE);

	// Atomic multi-attribute cost application (task 4.5). Multiple entries
	// naming the same attribute are summed (checked) into one total before
	// anything else happens. Preflight then checks EVERY distinct
	// attribute's `current >= total` before mutating anything; the first
	// insufficient attribute fails the whole batch with
	// `StatusCode::INSUFFICIENT_ATTRIBUTE`, `detail == attribute`, and
	// leaves every attribute untouched. Affordable attributes are processed
	// in ascending `DefinitionId` order regardless of `p_costs`' order, so
	// the resulting change-record dispatch order is canonical and
	// reproducible. Each cost reduces the attribute's BASE by its total
	// amount (an instant cost is a base mutation, like any other instant
	// effect) via the same `set_base` path used everywhere else.
	Status apply_costs(const std::vector<AttributeCost> &p_costs,
			Transaction &p_txn, NotificationQueue &p_queue,
			ChangeProvenance p_provenance = ChangeProvenance::AUTHORITATIVE);

	// ---------------------------------------------------------------
	// Change notification
	// ---------------------------------------------------------------

	// Registers a listener invoked once per committed `AttributeChangeRecord`
	// when the owning `NotificationQueue::dispatch()` runs (never
	// synchronously from a mutating call above). The listener receives the
	// same `NotificationQueue` so it can call `request_mutation()` to defer
	// a reentrant mutation instead of ever re-entering this class's mutating
	// API from inside dispatch (see ga_transaction.h).
	void add_listener(std::function<void(const AttributeChangeRecord &, NotificationQueue &)> p_listener);

	// ---------------------------------------------------------------
	// Canonical snapshots
	// ---------------------------------------------------------------

	// Writes every initialized attribute (ascending DefinitionId) and every
	// active modifier (ascending `(target_attribute, op, priority, source,
	// effect, declaration_index)` -- NOT insertion/handle order, see file
	// comment) into one self-contained section. Two `AttributeSet`s with
	// equivalent state reached via different histories produce identical
	// bytes and digest.
	Status write_snapshot(SnapshotWriter &p_writer) const;

	// Replaces this set's entire state from a previously written snapshot.
	// Decodes into local temporaries first and only swaps them into live
	// state once decoding fully succeeds, so a malformed or truncated
	// snapshot never leaves this object in a partially restored state.
	// Restored modifiers are reassigned fresh local handles in the same
	// canonical order the snapshot stored them in, so two peers restoring
	// the same snapshot bytes assign identical handle numbers even though
	// handles themselves are not part of the snapshot's canonical content.
	Status restore_snapshot(SnapshotReader &p_reader);

	// Same section shape `write_snapshot` writes (identical
	// `GA_SNAPSHOT_KIND_ATTRIBUTE_SET`/`_ATTRIBUTE_ENTRY`/`_MODIFIER_ENTRY`
	// framing and canonical ordering, decodable by the SAME
	// `restore_snapshot`), restricted to attributes for which `p_is_public`
	// returns true and modifiers whose `target_attribute` passes it too.
	// Used by the delta codec's (add-granular-delta-replication-2026-07-27,
	// task 2.1) PUBLIC-audience `DeltaSectionMode::FULL_REENCODE` fallback --
	// `write_snapshot()` itself stays the OWNER-audience fallback, unfiltered,
	// so that one keeps matching "the corresponding snapshot section" byte
	// for byte.
	Status write_snapshot_filtered(SnapshotWriter &p_writer, const std::function<bool(DefinitionId)> &p_is_public) const;

	// Task 2.1's per-record delta body for the ATTRIBUTE section: writes the
	// SAME fields `write_snapshot`'s own per-attribute entry writes (id,
	// base, current, revision) followed by every currently active modifier
	// targeting `p_id`, in the SAME canonical (priority, source, effect,
	// declaration_index) order `write_snapshot`'s own (separate, section-
	// level) modifier list uses. Bundling a touched attribute's modifiers
	// into its OWN delta record -- rather than leaving them in a sibling
	// list the way the full snapshot section does -- is what makes one
	// attribute's delta record self-sufficient: a RECORD_OPS section delta
	// never re-encodes attributes it did not touch, so any modifier list
	// kept separate from its target attribute could not be reconstructed
	// without the OTHER attribute's own (possibly absent) record. Fails,
	// without writing anything, if `p_id` is not currently initialized here
	// (every caller of this codec only ever calls this for a live identity
	// it already confirmed with `has_attribute`).
	Status write_attribute_delta_record(SnapshotWriter &p_writer, DefinitionId p_id) const;

	// Decodes one record `write_attribute_delta_record` wrote, WITHOUT
	// touching this set's live state (task 2.3/2.4: validate the whole
	// batch before any mutation) -- fails closed on an unregistered
	// attribute or modifier target, an out-of-range `ModifierOp`, or a
	// modifier count past `MAX_MODIFIERS`, exactly like `restore_snapshot`'s
	// own per-entry validation. `r_id` is the record's OWN embedded
	// identity (its first field, per `write_attribute_delta_record`'s own
	// layout) -- a caller cross-checks it against the delta op header's
	// identity (spec "Malformed delta batch is rejected... an invalid
	// record identity"), since this method has no independent way to know
	// what identity the caller expected. `r_id`/`r_value`/`r_modifiers` are
	// populated only on success.
	Status decode_attribute_delta_record(SnapshotReader &p_reader, DefinitionId &r_id, AttributeValue &r_value, std::vector<AttributeModifier> &r_modifiers) const;

	// The pure-decode half of `restore_snapshot`: reads and validates a
	// COMPLETE `GA_SNAPSHOT_KIND_ATTRIBUTE_SET` section (as `write_snapshot`
	// writes it) into `r_attributes`/`r_modifiers` WITHOUT installing
	// anything -- `restore_snapshot` itself is just this call followed by
	// `install_records`. The delta codec's `DeltaSectionMode::FULL_REENCODE`
	// apply path (`AbilityComponent::apply_delta_batch`, ga_ability_component.cpp)
	// calls this DIRECTLY instead of `restore_snapshot` so a full-reencode
	// section decodes into a local temporary just like a RECORD_OPS section
	// does, keeping the whole batch's validate-before-mutate contract intact
	// even when one of its sections chose the full-reencode fallback.
	Status decode_snapshot_section(SnapshotReader &p_reader, std::map<DefinitionId, AttributeValue> &r_attributes, std::vector<AttributeModifier> &r_modifiers) const;

	// Replaces this set's ENTIRE state from already-validated, already-
	// decoded content: the shared install tail `restore_snapshot` and the
	// delta codec's `AbilityComponent::apply_delta_batch`
	// (ga_ability_component.cpp) both converge on, so there is exactly one
	// place that reassigns modifier handles fresh, in canonical order, and
	// rebuilds the per-attribute index (see `restore_snapshot`'s own doc
	// comment on why modifier handles are reassigned rather than trusted
	// from input). Trusts `p_attributes`/`p_modifiers` completely -- every
	// caller has already validated them (registry membership, bounds); this
	// method itself performs no validation and must never be called
	// directly on untrusted input.
	void install_records(std::map<DefinitionId, AttributeValue> p_attributes, std::vector<AttributeModifier> p_modifiers);

	// Internal prepared-batch recovery metadata. Handles are local identities
	// and intentionally absent from canonical snapshot content, so a rollback
	// additionally restores the allocator cursor exactly.
	std::uint64_t allocator_next_raw() const {
		return handle_allocator.next_raw();
	}
	void restore_allocator_exact(std::uint64_t p_raw) {
		handle_allocator.restore_exact(p_raw);
	}

private:
	// The one and only place `current` is derived: `p_base` plus every
	// modifier presently in `modifiers` targeting `p_id`, in the phase order
	// and tie-break order documented in the file comment. Pure query -- does
	// not read or write `attributes[p_id]`, so it is equally usable to
	// preview a hypothetical new base (`set_base`) or the effect of a
	// modifier already provisionally inserted/removed from `modifiers`
	// (`add_modifier`/`remove_modifier`). `r_requested` is the phase-3
	// (pre-clamp) result, `r_effective` is phase-4 (post-clamp).
	Status recompute_value(DefinitionId p_id, Fixed p_base, Fixed &r_requested, Fixed &r_effective) const;

	void dispatch(const AttributeChangeRecord &p_record, NotificationQueue &p_queue) const;

	// Modifiers targeting `p_id`, sorted by the phase's tie-breakers
	// (ascending priority, source, effect, declaration index).
	std::vector<const AttributeModifier *> ordered_modifiers_for(DefinitionId p_id, ModifierOp p_op) const;

	// Every active modifier's handle, sorted by the snapshot's canonical
	// content key (target_attribute, op, priority, source, effect,
	// declaration_index; ModifierHandle only as a last-resort total-order
	// guard when all six are equal).
	std::vector<ModifierHandle> canonical_modifier_order() const;

	// --- Task 4.7: per-attribute modifier index -----------------------
	//
	// `modifiers_by_attribute[target]` holds exactly the handles of
	// modifiers targeting `target`, kept sorted in ascending `ModifierHandle`
	// order -- i.e. exactly the subsequence `modifiers` (a
	// `std::map<ModifierHandle, AttributeModifier>`, so ascending-handle by
	// construction) would yield if filtered down to `target` by hand. This
	// index exists ONLY so `ordered_modifiers_for` can visit "modifiers on
	// this attribute" (bounded, typically tiny) instead of "every modifier on
	// every attribute in the component" (bounded by MAX_MODIFIERS, up to 256)
	// -- see the file comment's aggregation model, which this index does not
	// change in any observable way: it accelerates lookup, it does not alter
	// aggregation order, phase logic, or tie-breaking.
	//
	// Preserving the exact ascending-handle pre-sort order matters even
	// though `ordered_modifiers_for`'s own stable_sort re-sorts by
	// (priority, source, effect, declaration_index): a stable sort only
	// preserves *relative* input order among elements that tie on every sort
	// key, and the file comment already documents that such a tie is only
	// possible for content that failed to disambiguate itself. Keeping this
	// index in the identical order the old whole-map scan would have
	// produced means that edge case's (already documented as arbitrary but
	// deterministic) behavior is untouched too -- not just the common case.
	void index_insert(DefinitionId p_target, ModifierHandle p_handle);
	void index_erase(DefinitionId p_target, ModifierHandle p_handle);
	void rebuild_modifier_index();

	const AttributeRegistry *registry = nullptr;
	std::map<DefinitionId, AttributeValue> attributes;
	std::map<ModifierHandle, AttributeModifier> modifiers;
	std::map<DefinitionId, std::vector<ModifierHandle>> modifiers_by_attribute;
	HandleAllocator<ModifierHandle> handle_allocator;
	// See `modifier_scan_visit_count()` above -- diagnostic-only, mutable
	// because it is updated from the otherwise-const `ordered_modifiers_for`.
	mutable std::uint64_t modifier_scan_visits = 0;
	std::vector<std::function<void(const AttributeChangeRecord &, NotificationQueue &)>> listeners;
};

} // namespace ga

#endif // GAMEPLAY_ABILITIES_CORE_ATTRIBUTE_STATE_H
