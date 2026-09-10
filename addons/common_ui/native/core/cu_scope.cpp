#include "core/cu_scope.h"

#include <algorithm>

namespace cu {

// ---------------------------------------------------------------------------
// Registrations
// ---------------------------------------------------------------------------

void ScopeState::add_registration(const ActionRegistration &p_registration) {
	registration_index[p_registration.handle] = registrations.size();
	registrations.push_back(p_registration);
}

bool ScopeState::release_registration(HandleId p_handle) {
	auto found = registration_index.find(p_handle);
	if (found == registration_index.end()) {
		return false;
	}
	registrations.erase(registrations.begin() + static_cast<std::ptrdiff_t>(found->second));
	reindex();
	return true;
}

const ActionRegistration *ScopeState::find_registration(HandleId p_handle) const {
	auto found = registration_index.find(p_handle);
	if (found == registration_index.end()) {
		return nullptr;
	}
	return &registrations[found->second];
}

void ScopeState::reindex() {
	registration_index.clear();
	registration_index.reserve(registrations.size());
	for (std::size_t i = 0; i < registrations.size(); ++i) {
		registration_index[registrations[i].handle] = i;
	}
}

// ---------------------------------------------------------------------------
// Contexts
// ---------------------------------------------------------------------------

void ScopeState::push_context(const ContextEntry &p_entry) {
	contexts.push_back(p_entry);
}

bool ScopeState::remove_context(HandleId p_handle) {
	for (std::size_t i = 0; i < contexts.size(); ++i) {
		if (contexts[i].handle == p_handle) {
			// Erasing preserves the relative order of the remaining entries, so
			// removing a non-top context leaves the rest of the stack intact.
			contexts.erase(contexts.begin() + static_cast<std::ptrdiff_t>(i));
			return true;
		}
	}
	return false;
}

bool ScopeState::set_context_suspended(HandleId p_handle, bool p_suspended) {
	for (ContextEntry &entry : contexts) {
		if (entry.handle == p_handle) {
			if (entry.suspended == p_suspended) {
				return false;
			}
			// The stack position is stored in `sequence` and is untouched here,
			// so resuming restores the original ordering.
			entry.suspended = p_suspended;
			return true;
		}
	}
	return false;
}

const ContextEntry *ScopeState::find_context(HandleId p_handle) const {
	for (const ContextEntry &entry : contexts) {
		if (entry.handle == p_handle) {
			return &entry;
		}
	}
	return nullptr;
}

// ---------------------------------------------------------------------------
// Layers
// ---------------------------------------------------------------------------

void ScopeState::configure_layer(Id p_layer, int p_priority, bool p_active, std::uint64_t p_sequence) {
	for (LayerEntry &entry : layers) {
		if (entry.layer == p_layer) {
			entry.priority = p_priority;
			entry.active = p_active;
			return;
		}
	}
	LayerEntry entry;
	entry.layer = p_layer;
	entry.priority = p_priority;
	entry.active = p_active;
	entry.sequence = p_sequence;
	layers.push_back(entry);
}

bool ScopeState::set_layer_active(Id p_layer, bool p_active) {
	for (LayerEntry &entry : layers) {
		if (entry.layer == p_layer) {
			if (entry.active == p_active) {
				return false;
			}
			entry.active = p_active;
			return true;
		}
	}
	return false;
}

bool ScopeState::push_screen(Id p_layer, OwnerId p_screen) {
	if (p_screen == INVALID_OWNER) {
		return false;
	}
	for (LayerEntry &entry : layers) {
		if (entry.layer != p_layer) {
			continue;
		}
		// A screen may only occupy one position in its stack.
		auto existing = std::find(entry.stack.begin(), entry.stack.end(), p_screen);
		if (existing != entry.stack.end()) {
			entry.stack.erase(existing);
		}
		entry.stack.push_back(p_screen);
		return true;
	}
	return false;
}

bool ScopeState::remove_screen(Id p_layer, OwnerId p_screen) {
	for (LayerEntry &entry : layers) {
		if (entry.layer != p_layer) {
			continue;
		}
		auto existing = std::find(entry.stack.begin(), entry.stack.end(), p_screen);
		if (existing == entry.stack.end()) {
			return false;
		}
		entry.stack.erase(existing);
		return true;
	}
	return false;
}

OwnerId ScopeState::top_screen(Id p_layer) const {
	const LayerEntry *entry = find_layer(p_layer);
	if (entry == nullptr || entry->stack.empty()) {
		return INVALID_OWNER;
	}
	return entry->stack.back();
}

const LayerEntry *ScopeState::find_layer(Id p_layer) const {
	for (const LayerEntry &entry : layers) {
		if (entry.layer == p_layer) {
			return &entry;
		}
	}
	return nullptr;
}

Id ScopeState::layer_of_screen(OwnerId p_screen) const {
	if (p_screen == INVALID_OWNER) {
		return INVALID_ID;
	}
	for (const LayerEntry &entry : layers) {
		if (std::find(entry.stack.begin(), entry.stack.end(), p_screen) != entry.stack.end()) {
			return entry.layer;
		}
	}
	return INVALID_ID;
}

// ---------------------------------------------------------------------------
// Derived ordering
// ---------------------------------------------------------------------------

ScopeRanks ScopeState::build_ranks() const {
	ScopeRanks ranks;

	// Contexts: highest priority first, most recently pushed entry breaking
	// ties. Suspended entries keep their stack position but earn no rank.
	std::vector<const ContextEntry *> ordered_contexts;
	ordered_contexts.reserve(contexts.size());
	for (const ContextEntry &entry : contexts) {
		ordered_contexts.push_back(&entry);
	}
	std::sort(ordered_contexts.begin(), ordered_contexts.end(),
			[](const ContextEntry *a, const ContextEntry *b) {
				if (a->priority != b->priority) {
					return a->priority > b->priority;
				}
				return a->sequence > b->sequence;
			});

	for (const ContextEntry *entry : ordered_contexts) {
		if (entry->suspended) {
			// Only record suspension if no active entry already claimed the id.
			if (ranks.context_rank.find(entry->context) == ranks.context_rank.end()) {
				ranks.context_suspended.emplace(entry->context, true);
			}
			continue;
		}
		if (ranks.context_rank.find(entry->context) != ranks.context_rank.end()) {
			continue;
		}
		ranks.context_suspended.erase(entry->context);
		ranks.context_rank.emplace(entry->context, ranks.context_count++);
	}

	// Layers: highest priority first, earliest configured breaking ties so that
	// a stable project layer configuration produces a stable order.
	std::vector<const LayerEntry *> ordered_layers;
	ordered_layers.reserve(layers.size());
	for (const LayerEntry &entry : layers) {
		if (entry.active) {
			ordered_layers.push_back(&entry);
		}
	}
	std::sort(ordered_layers.begin(), ordered_layers.end(),
			[](const LayerEntry *a, const LayerEntry *b) {
				if (a->priority != b->priority) {
					return a->priority > b->priority;
				}
				return a->sequence < b->sequence;
			});

	for (const LayerEntry *entry : ordered_layers) {
		ranks.layer_rank.emplace(entry->layer, ranks.layer_count++);
	}

	return ranks;
}

} // namespace cu
