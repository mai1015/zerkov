#include "core/cu_binding.h"

#include <algorithm>

namespace cu {

namespace {

const char *slot_name(BindingSlot p_slot) {
	return p_slot == BindingSlot::PRIMARY ? "primary" : "secondary";
}

} // namespace

void BindingSet::define(const ActionDefinition &p_definition) {
	if (p_definition.action == INVALID_ID) {
		return;
	}
	if (definitions.find(p_definition.action) == definitions.end()) {
		order.push_back(p_definition.action);
	}
	definitions[p_definition.action] = p_definition;
}

void BindingSet::clear_definitions() {
	definitions.clear();
	order.clear();
	override_map.clear();
}

bool BindingSet::has_action(Id p_action) const {
	return definitions.find(p_action) != definitions.end();
}

const ActionDefinition *BindingSet::find_definition(Id p_action) const {
	auto found = definitions.find(p_action);
	return found == definitions.end() ? nullptr : &found->second;
}

BindingRecord BindingSet::effective(Id p_action, BindingSlot p_slot) const {
	const ActionDefinition *definition = find_definition(p_action);
	if (definition == nullptr) {
		return BindingRecord();
	}
	auto found = override_map.find(key_of(p_action, p_slot));
	if (found == override_map.end()) {
		return definition->defaults[static_cast<int>(p_slot)];
	}
	if (found->second.cleared) {
		return BindingRecord();
	}
	BindingRecord record;
	record.signature = found->second.signature;
	record.glyph = found->second.glyph;
	return record;
}

bool BindingSet::has_any_binding(Id p_action) const {
	for (int slot = 0; slot < BINDING_SLOT_COUNT; ++slot) {
		if (effective(p_action, static_cast<BindingSlot>(slot)).is_bound()) {
			return true;
		}
	}
	return false;
}

bool BindingSet::conflicts_in_scope(const ActionDefinition &p_a, const ActionDefinition &p_b) const {
	// A global action shares a binding with nothing; two context-scoped actions
	// only conflict inside the same context.
	if (p_a.context == INVALID_ID || p_b.context == INVALID_ID) {
		return true;
	}
	return p_a.context == p_b.context;
}

int BindingSet::bound_slot_count_after(Id p_action, BindingSlot p_slot, Id p_signature) const {
	int count = 0;
	for (int slot = 0; slot < BINDING_SLOT_COUNT; ++slot) {
		const BindingSlot current = static_cast<BindingSlot>(slot);
		const Id signature = current == p_slot ? p_signature : effective(p_action, current).signature;
		if (signature != INVALID_ID) {
			++count;
		}
	}
	return count;
}

std::vector<Conflict> BindingSet::find_conflicts(Id p_action, BindingSlot p_slot, Id p_signature) const {
	std::vector<Conflict> conflicts;
	if (p_signature == INVALID_ID) {
		return conflicts;
	}
	const ActionDefinition *candidate = find_definition(p_action);
	if (candidate == nullptr) {
		return conflicts;
	}

	for (Id other_action : order) {
		const ActionDefinition *other = find_definition(other_action);
		if (other == nullptr || !conflicts_in_scope(*candidate, *other)) {
			continue;
		}
		for (int slot = 0; slot < BINDING_SLOT_COUNT; ++slot) {
			const BindingSlot other_slot = static_cast<BindingSlot>(slot);
			if (other_action == p_action && other_slot == p_slot) {
				continue;
			}
			if (effective(other_action, other_slot).signature != p_signature) {
				continue;
			}
			Conflict conflict;
			conflict.action = other_action;
			conflict.slot = other_slot;
			conflict.signature = p_signature;
			conflict.is_protected = other->protection != Protection::NONE;
			conflicts.push_back(conflict);
		}
	}
	return conflicts;
}

BindingResult BindingSet::rebind(Id p_action, BindingSlot p_slot, Id p_signature, Id p_glyph,
		ConflictPolicy p_policy, bool p_confirmed) {
	BindingResult result;
	const ActionDefinition *definition = find_definition(p_action);
	if (definition == nullptr) {
		result.error = "Unknown action.";
		return result;
	}
	if (p_signature == INVALID_ID) {
		result.error = "Candidate binding is empty; use clear_binding to unbind a slot.";
		return result;
	}

	if (definition->protection == Protection::CONFIRM && !p_confirmed) {
		result.needs_confirmation = true;
		result.error = "Protected action requires explicit confirmation.";
		return result;
	}

	result.conflicts = find_conflicts(p_action, p_slot, p_signature);
	if (!result.conflicts.empty() && p_policy == ConflictPolicy::REJECT) {
		result.error = "Candidate binding conflicts with another action.";
		return result;
	}

	if (p_policy == ConflictPolicy::REPLACE) {
		for (const Conflict &conflict : result.conflicts) {
			const ActionDefinition *other = find_definition(conflict.action);
			if (other == nullptr) {
				continue;
			}
			// Displacing a protected action's last binding is never implicit.
			if (other->protection != Protection::NONE &&
					bound_slot_count_after(conflict.action, conflict.slot, INVALID_ID) == 0) {
				result.error = "Replacing would leave protected action unbound.";
				return result;
			}
		}
	}

	// Everything validated; from here the mutation cannot fail.
	if (p_policy == ConflictPolicy::REPLACE) {
		for (const Conflict &conflict : result.conflicts) {
			BindingOverride cleared;
			cleared.action = conflict.action;
			cleared.slot = conflict.slot;
			cleared.cleared = true;
			override_map[key_of(conflict.action, conflict.slot)] = cleared;
		}
	}

	BindingOverride applied;
	applied.action = p_action;
	applied.slot = p_slot;
	applied.signature = p_signature;
	applied.glyph = p_glyph;
	applied.cleared = false;
	override_map[key_of(p_action, p_slot)] = applied;

	result.ok = true;
	return result;
}

BindingResult BindingSet::clear_binding(Id p_action, BindingSlot p_slot, bool p_confirmed) {
	BindingResult result;
	const ActionDefinition *definition = find_definition(p_action);
	if (definition == nullptr) {
		result.error = "Unknown action.";
		return result;
	}
	if (definition->protection == Protection::CONFIRM && !p_confirmed) {
		result.needs_confirmation = true;
		result.error = "Protected action requires explicit confirmation.";
		return result;
	}
	if (definition->protection != Protection::NONE &&
			bound_slot_count_after(p_action, p_slot, INVALID_ID) == 0) {
		result.error = std::string("Cannot clear the last ") + slot_name(p_slot) +
				" binding of a required action.";
		return result;
	}

	BindingOverride cleared;
	cleared.action = p_action;
	cleared.slot = p_slot;
	cleared.cleared = true;
	override_map[key_of(p_action, p_slot)] = cleared;
	result.ok = true;
	return result;
}

BindingResult BindingSet::restore_defaults() {
	BindingResult result;
	// Defaults are authored to satisfy protection, but a definition set can
	// still be invalid; validate before discarding the user's overrides.
	for (Id action : order) {
		const ActionDefinition *definition = find_definition(action);
		if (definition == nullptr || definition->protection == Protection::NONE) {
			continue;
		}
		const bool any_default = definition->defaults[0].is_bound() || definition->defaults[1].is_bound();
		if (!any_default) {
			result.error = "Defaults would leave a protected action unbound.";
			return result;
		}
	}
	override_map.clear();
	result.ok = true;
	return result;
}

BindingResult BindingSet::restore_action_defaults(Id p_action) {
	BindingResult result;
	const ActionDefinition *definition = find_definition(p_action);
	if (definition == nullptr) {
		result.error = "Unknown action.";
		return result;
	}
	if (definition->protection != Protection::NONE && !definition->defaults[0].is_bound() &&
			!definition->defaults[1].is_bound()) {
		result.error = "Defaults would leave a protected action unbound.";
		return result;
	}
	for (int slot = 0; slot < BINDING_SLOT_COUNT; ++slot) {
		override_map.erase(key_of(p_action, static_cast<BindingSlot>(slot)));
	}
	result.ok = true;
	return result;
}

std::vector<BindingOverride> BindingSet::overrides() const {
	std::vector<BindingOverride> result;
	for (Id action : order) {
		for (int slot = 0; slot < BINDING_SLOT_COUNT; ++slot) {
			auto found = override_map.find(key_of(action, static_cast<BindingSlot>(slot)));
			if (found != override_map.end()) {
				result.push_back(found->second);
			}
		}
	}
	return result;
}

std::vector<std::string> BindingSet::load_overrides(const std::vector<BindingOverride> &p_overrides) {
	std::vector<std::string> problems;
	const Snapshot before = snapshot();
	override_map.clear();

	for (const BindingOverride &entry : p_overrides) {
		if (!has_action(entry.action)) {
			problems.push_back("Override references an unknown action; skipped.");
			continue;
		}
		override_map[key_of(entry.action, entry.slot)] = entry;
	}

	// A loaded file must never be able to leave a protected action unbound.
	for (Id action : order) {
		const ActionDefinition *definition = find_definition(action);
		if (definition == nullptr || definition->protection == Protection::NONE) {
			continue;
		}
		if (has_any_binding(action)) {
			continue;
		}
		problems.push_back("Overrides left a protected action unbound; its defaults were kept.");
		for (int slot = 0; slot < BINDING_SLOT_COUNT; ++slot) {
			override_map.erase(key_of(action, static_cast<BindingSlot>(slot)));
		}
	}

	if (problems.size() == p_overrides.size() && !p_overrides.empty() && override_map.empty()) {
		// Nothing usable survived; keep whatever was active before.
		restore(before);
	}
	return problems;
}

void BindingSet::clear_overrides() {
	override_map.clear();
}

BindingSet::Snapshot BindingSet::snapshot() const {
	Snapshot snapshot;
	snapshot.definitions = definitions;
	snapshot.order = order;
	snapshot.overrides = override_map;
	return snapshot;
}

void BindingSet::restore(const Snapshot &p_snapshot) {
	definitions = p_snapshot.definitions;
	order = p_snapshot.order;
	override_map = p_snapshot.overrides;
}

} // namespace cu
