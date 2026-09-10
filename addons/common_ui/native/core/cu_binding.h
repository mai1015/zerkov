#ifndef COMMON_UI_CORE_BINDING_H
#define COMMON_UI_CORE_BINDING_H

#include "core/cu_ids.h"

#include <string>
#include <unordered_map>
#include <vector>

namespace cu {

enum class BindingSlot : std::uint8_t {
	PRIMARY = 0,
	SECONDARY = 1,
};

constexpr int BINDING_SLOT_COUNT = 2;

enum class Protection : std::uint8_t {
	// Freely rebindable, may be left unbound.
	NONE = 0,
	// Must retain at least one eligible binding.
	REQUIRED = 1,
	// Must retain a binding and needs explicit confirmation to change.
	CONFIRM = 2,
};

enum class ConflictPolicy : std::uint8_t {
	// Change nothing and report every blocking action.
	REJECT = 0,
	// Clear the conflicting bindings, subject to protection rules.
	REPLACE = 1,
	// Let the same physical binding drive more than one action.
	ALLOW_DUPLICATE = 2,
};

// One resolved binding. `signature` is an opaque identity for the physical
// input produced by the engine layer (device kind, code, modifiers, axis
// direction), so the core can compare bindings without knowing about
// InputEvent.
struct BindingRecord {
	Id signature = INVALID_ID;
	Id glyph = INVALID_ID;

	bool is_bound() const { return signature != INVALID_ID; }
	bool operator==(const BindingRecord &p_other) const {
		return signature == p_other.signature && glyph == p_other.glyph;
	}
};

struct ActionDefinition {
	Id action = INVALID_ID;
	// Conflict group. Two actions can share a binding when their contexts
	// differ and neither is global.
	Id context = INVALID_ID;
	Protection protection = Protection::NONE;
	BindingRecord defaults[BINDING_SLOT_COUNT];
};

struct Conflict {
	Id action = INVALID_ID;
	BindingSlot slot = BindingSlot::PRIMARY;
	Id signature = INVALID_ID;
	bool is_protected = false;
};

struct BindingResult {
	bool ok = false;
	// Empty when ok. Never a partial application.
	std::string error;
	std::vector<Conflict> conflicts;
	// True when policy allows the change but the caller must confirm first.
	bool needs_confirmation = false;
};

// One difference from the defaults. Only these are persisted.
struct BindingOverride {
	Id action = INVALID_ID;
	BindingSlot slot = BindingSlot::PRIMARY;
	Id signature = INVALID_ID;
	Id glyph = INVALID_ID;
	// True when the user deliberately cleared a slot that has a default.
	bool cleared = false;
};

// Merges framework defaults with user overrides into one authoritative
// effective binding set, and applies changes transactionally.
//
// The set owns no engine state. The engine layer snapshots it, applies a
// change, persists, and projects into InputMap; if any of those steps fails it
// restores the snapshot, so a failure can never leave a partial binding.
class BindingSet {
public:
	// Complete, restorable state of the set.
	struct Snapshot {
		std::unordered_map<Id, ActionDefinition> definitions;
		std::vector<Id> order;
		std::unordered_map<std::uint64_t, BindingOverride> overrides;
	};

	void define(const ActionDefinition &p_definition);
	void clear_definitions();
	bool has_action(Id p_action) const;
	const ActionDefinition *find_definition(Id p_action) const;
	// Definitions in declaration order, so projection and reporting are stable.
	const std::vector<Id> &action_order() const { return order; }

	// Defaults merged with overrides.
	BindingRecord effective(Id p_action, BindingSlot p_slot) const;
	// True when the action has at least one bound slot.
	bool has_any_binding(Id p_action) const;

	// Conflicts a candidate would cause, without changing anything.
	std::vector<Conflict> find_conflicts(Id p_action, BindingSlot p_slot, Id p_signature) const;

	// Validates, resolves conflicts under p_policy, and applies. On failure
	// nothing is changed.
	BindingResult rebind(Id p_action, BindingSlot p_slot, Id p_signature, Id p_glyph,
			ConflictPolicy p_policy, bool p_confirmed);

	BindingResult clear_binding(Id p_action, BindingSlot p_slot, bool p_confirmed);
	BindingResult restore_defaults();
	BindingResult restore_action_defaults(Id p_action);

	// Only the differences from defaults, in stable order, for persistence.
	std::vector<BindingOverride> overrides() const;
	// Applies persisted overrides. Entries for unknown actions or that would
	// leave a protected action unbound are skipped and described in the result;
	// the remaining valid entries still apply.
	std::vector<std::string> load_overrides(const std::vector<BindingOverride> &p_overrides);
	void clear_overrides();

	Snapshot snapshot() const;
	void restore(const Snapshot &p_snapshot);

private:
	static std::uint64_t key_of(Id p_action, BindingSlot p_slot) {
		return (static_cast<std::uint64_t>(p_action) << 8) | static_cast<std::uint64_t>(p_slot);
	}

	// Whether the two actions share a conflict group.
	bool conflicts_in_scope(const ActionDefinition &p_a, const ActionDefinition &p_b) const;
	// Slots that would remain bound if p_slot were set to p_signature.
	int bound_slot_count_after(Id p_action, BindingSlot p_slot, Id p_signature) const;

	std::unordered_map<Id, ActionDefinition> definitions;
	std::vector<Id> order;
	std::unordered_map<std::uint64_t, BindingOverride> override_map;
};

} // namespace cu

#endif // COMMON_UI_CORE_BINDING_H
