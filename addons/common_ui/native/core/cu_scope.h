#ifndef COMMON_UI_CORE_SCOPE_H
#define COMMON_UI_CORE_SCOPE_H

#include "core/cu_types.h"

#include <unordered_map>
#include <vector>

namespace cu {

// Ordering of the currently active contexts and layers of one scope. Rebuilt
// from ScopeState whenever routing needs it; never cached across a mutation.
struct ScopeRanks {
	// context id -> position, lowest first. Absent means the context is not
	// active.
	std::unordered_map<Id, int> context_rank;
	// context id -> true when the id exists but every entry is suspended.
	std::unordered_map<Id, bool> context_suspended;
	int context_count = 0;

	// layer id -> position, lowest first. Absent means the layer is inactive or
	// unknown.
	std::unordered_map<Id, int> layer_rank;
	int layer_count = 0;
};

// All mutable routing state belonging to one (UI user, Viewport) pair.
//
// ScopeState performs no deferral of its own. Callers must not mutate it while
// a dispatch is reading it; Core enforces that with its deferred queue.
class ScopeState {
public:
	ScopeKey key;

	// -- Registrations ------------------------------------------------------

	void add_registration(const ActionRegistration &p_registration);
	bool release_registration(HandleId p_handle);
	const ActionRegistration *find_registration(HandleId p_handle) const;
	const std::vector<ActionRegistration> &all_registrations() const { return registrations; }

	// Drops registrations whose owner is gone. Returns their handles so Core can
	// remove every matching entry from its handle index as one transaction.
	template <typename IsValid>
	std::vector<HandleId> prune_dead_owners(IsValid p_is_valid) {
		std::vector<HandleId> removed;
		for (std::size_t i = registrations.size(); i > 0; --i) {
			const std::size_t at = i - 1;
			if (!p_is_valid(registrations[at].owner)) {
				removed.push_back(registrations[at].handle);
				registrations.erase(registrations.begin() + static_cast<std::ptrdiff_t>(at));
			}
		}
		if (!removed.empty()) {
			reindex();
		}
		return removed;
	}

	// -- Contexts -----------------------------------------------------------

	void push_context(const ContextEntry &p_entry);
	bool remove_context(HandleId p_handle);
	bool set_context_suspended(HandleId p_handle, bool p_suspended);
	const ContextEntry *find_context(HandleId p_handle) const;
	const std::vector<ContextEntry> &all_contexts() const { return contexts; }

	// -- Layers -------------------------------------------------------------

	void configure_layer(Id p_layer, int p_priority, bool p_active, std::uint64_t p_sequence);
	bool set_layer_active(Id p_layer, bool p_active);
	bool push_screen(Id p_layer, OwnerId p_screen);
	// Removes p_screen from its layer stack wherever it sits, not only the top.
	bool remove_screen(Id p_layer, OwnerId p_screen);
	OwnerId top_screen(Id p_layer) const;
	const LayerEntry *find_layer(Id p_layer) const;
	const std::vector<LayerEntry> &all_layers() const { return layers; }

	// Returns the layer whose stack contains p_screen, or INVALID_ID.
	Id layer_of_screen(OwnerId p_screen) const;

	// -- Derived ------------------------------------------------------------

	ScopeRanks build_ranks() const;

	bool is_empty() const {
		return registrations.empty() && contexts.empty() && layers.empty();
	}

private:
	void reindex();

	std::vector<ActionRegistration> registrations;
	std::unordered_map<HandleId, std::size_t> registration_index;
	std::vector<ContextEntry> contexts;
	std::vector<LayerEntry> layers;
};

} // namespace cu

#endif // COMMON_UI_CORE_SCOPE_H
