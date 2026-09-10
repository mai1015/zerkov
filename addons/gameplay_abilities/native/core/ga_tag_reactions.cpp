#include "core/ga_tag_reactions.h"

#include "core/ga_bytes.h"
#include "core/ga_hash.h"
#include "core/ga_identifier.h"

#include <functional>
#include <set>

namespace ga {

Status contribute_tag_reaction_manifest(ManifestBuilder &p_builder, const TagReactionCanonicalDesc &p_desc) {
	ByteWriter writer;
	writer.write_string(p_desc.operand_tag);
	writer.write_u8(static_cast<std::uint8_t>(p_desc.match_mode));
	writer.write_u8(static_cast<std::uint8_t>(p_desc.mode));
	writer.write_string(p_desc.effect_identifier);
	if (!writer.ok()) {
		return writer.status();
	}
	return p_builder.add(ManifestEntryKind::REACTION, p_desc.identifier, writer.bytes());
}

// ---------------------------------------------------------------------------
// TagReactionRegistry
// ---------------------------------------------------------------------------

Status TagReactionRegistry::register_reaction(const TagReactionCanonicalDesc &p_desc, const TagRegistry &p_tags,
		const EffectRegistry &p_effects, DefinitionId &r_id) {
	r_id = INVALID_DEFINITION_ID;
	if (is_sealed) {
		return make_status(StatusCode::REGISTRY_SEALED);
	}

	const Status grammar = validate_identifier(p_desc.identifier);
	if (!grammar.ok()) {
		return grammar;
	}

	const DefinitionId operand_tag = p_tags.id_of(p_desc.operand_tag);
	if (operand_tag == INVALID_DEFINITION_ID) {
		return make_status(StatusCode::UNKNOWN_TAG, DiagnosticId::DEFINITION_UNKNOWN_REFERENCE, hash_string(p_desc.operand_tag));
	}

	const EffectDefinition *effect = p_effects.find(p_desc.effect_identifier);
	if (effect == nullptr) {
		return make_status(StatusCode::UNKNOWN_EFFECT, DiagnosticId::DEFINITION_UNKNOWN_REFERENCE, hash_string(p_desc.effect_identifier));
	}

	// WHILE_PRESENT must be guaranteed for the complete predicate interval:
	// only an INFINITE effect can be relied on to still be active (and
	// therefore removable) at the matching true-to-false edge (design.md
	// decision 3; specs/gameplay-effects/spec.md "While-present reaction
	// targets a duration effect"). `has_period` is orthogonal -- a periodic
	// INFINITE effect is accepted (specs/gameplay-effects/spec.md
	// "While-present effect is periodic").
	if (p_desc.mode == TagReactionMode::WHILE_PRESENT && effect->duration_policy != EffectDuration::INFINITE) {
		return make_status(StatusCode::INVALID_EFFECT_SPEC, DiagnosticId::DURATION_INVALID, hash_string(p_desc.identifier));
	}

	// Intern the identifier last, after every other validation step has
	// succeeded, so a failed registration never consumes the name (mirrors
	// EffectRegistry::register_effect).
	DefinitionId unused = INVALID_DEFINITION_ID;
	const Status intern_status = identifiers.intern(p_desc.identifier, unused);
	if (!intern_status.ok()) {
		return intern_status;
	}

	TagReactionDefinition definition;
	definition.identifier = p_desc.identifier;
	definition.operand_tag = operand_tag;
	definition.match_mode = p_desc.match_mode;
	definition.mode = p_desc.mode;
	definition.effect_id = effect->id;
	definition.effect_identifier = p_desc.effect_identifier;
	definition.effect_granted_tags = effect->granted_tags; // already ascending, deduplicated

	pending[p_desc.identifier] = std::move(definition);
	return ok_status();
}

Status TagReactionRegistry::seal(const TagRegistry &p_tags, TagReactionCycleConflict *r_conflict) {
	if (is_sealed) {
		return make_status(StatusCode::REGISTRY_SEALED);
	}

	// `pending` is a std::map sorted by identifier; iterating it in order and
	// assigning dense ids 1..N as we go reproduces the exact same
	// identifier-byte-order seal-time assignment every other registry in
	// this addon uses (see IdentifierTable::seal), without needing a second
	// IdentifierTable instance just to re-derive an order this map already
	// has (mirrors EffectRegistry::seal).
	by_id.clear();
	by_id.emplace_back(); // index 0 unused
	DefinitionId next_id = 1;
	for (auto &entry : pending) {
		TagReactionDefinition definition = entry.second;
		definition.id = next_id;
		by_id.push_back(std::move(definition));
		++next_id;
	}

	tags = &p_tags;

	// Task 3.2: exact/parent-aware operand index, keyed by each reaction's
	// OWN operand tag. Built once here, from the now-dense by_id order, so
	// every per-tag bucket is already ascending by reaction id.
	exact_index.clear();
	parent_aware_index.clear();
	for (std::size_t i = 1; i < by_id.size(); ++i) {
		const TagReactionDefinition &definition = by_id[i];
		if (definition.match_mode == TagReactionMatchMode::EXACT) {
			exact_index[definition.operand_tag].push_back(definition.id);
		} else {
			parent_aware_index[definition.operand_tag].push_back(definition.id);
		}
	}

	// Task 3.4: conservative dependency-graph cycle validation. A directed
	// edge exists from reaction A to reaction B when a tag A's target effect
	// grants satisfies B's operand (match-mode-aware); this is exactly
	// `affected_reactions` applied to A's own `effect_granted_tags`, so the
	// edge set reuses the same bounded index lookups task 3.2 built above
	// instead of a second O(reactions^2) comparison. A depth-first walk in
	// ascending reaction-id order (deterministic, content-derived) with
	// three-color marking finds the first cycle, if any -- a self-loop is
	// simply an edge from a GRAY node back to itself, discovered the moment
	// that node's own neighbor list is scanned.
	const std::size_t reaction_count = by_id.size() - 1;
	std::vector<std::uint8_t> color(by_id.size(), 0); // 0 = white, 1 = gray, 2 = black
	std::vector<DefinitionId> stack;
	bool cycle_found = false;

	std::function<bool(DefinitionId)> visit = [&](DefinitionId p_node) -> bool {
		color[p_node] = 1;
		stack.push_back(p_node);
		for (DefinitionId next : affected_reactions_unsealed(by_id[p_node].effect_granted_tags)) {
			if (color[next] == 1) {
				if (r_conflict != nullptr) {
					build_cycle_conflict(stack, next, *r_conflict);
				}
				return true;
			}
			if (color[next] == 0 && visit(next)) {
				return true;
			}
		}
		color[p_node] = 2;
		stack.pop_back();
		return false;
	};

	for (DefinitionId id = 1; id <= reaction_count && !cycle_found; ++id) {
		if (color[id] == 0) {
			cycle_found = visit(id);
		}
	}

	if (cycle_found) {
		// No partial seal -- mirrors EffectRegistry::seal's unknown-overflow-
		// reference failure: leave nothing usable behind a failed seal.
		by_id.clear();
		exact_index.clear();
		parent_aware_index.clear();
		tags = nullptr;
		return make_status(StatusCode::INVALID_REFERENCE, DiagnosticId::REACTION_CYCLE);
	}

	is_sealed = true;
	return ok_status();
}

const TagReactionDefinition *TagReactionRegistry::find(DefinitionId p_id) const {
	if (!is_sealed || p_id == INVALID_DEFINITION_ID || p_id >= by_id.size()) {
		return nullptr;
	}
	return &by_id[p_id];
}

const TagReactionDefinition *TagReactionRegistry::find(const std::string &p_identifier) const {
	return find(id_of(p_identifier));
}

DefinitionId TagReactionRegistry::id_of(const std::string &p_identifier) const {
	if (!is_sealed) {
		return INVALID_DEFINITION_ID;
	}
	for (std::size_t i = 1; i < by_id.size(); ++i) {
		if (by_id[i].identifier == p_identifier) {
			return by_id[i].id;
		}
	}
	return INVALID_DEFINITION_ID;
}

std::vector<DefinitionId> TagReactionRegistry::canonical_order() const {
	std::vector<DefinitionId> result;
	if (!is_sealed) {
		return result;
	}
	result.reserve(by_id.size() > 0 ? by_id.size() - 1 : 0);
	for (std::size_t i = 1; i < by_id.size(); ++i) {
		result.push_back(by_id[i].id);
	}
	return result;
}

std::vector<DefinitionId> TagReactionRegistry::affected_reactions(const std::vector<DefinitionId> &p_changed_tags) const {
	if (!is_sealed) {
		return {};
	}
	return affected_reactions_unsealed(p_changed_tags);
}

std::vector<DefinitionId> TagReactionRegistry::affected_reactions_unsealed(const std::vector<DefinitionId> &p_changed_tags) const {
	// std::set both deduplicates across multiple changed tags AND keeps the
	// result in ascending DefinitionId order for free -- no separate sort
	// step, matching this addon's "no hash-order dependence" rule.
	std::set<DefinitionId> result;
	for (DefinitionId changed_tag : p_changed_tags) {
		// EXACT: only an identical operand tag is affected.
		const auto exact_it = exact_index.find(changed_tag);
		if (exact_it != exact_index.end()) {
			result.insert(exact_it->second.begin(), exact_it->second.end());
		}

		// PARENT_AWARE: an operand on `changed_tag` itself OR any of its
		// ancestors is affected -- a descendant becoming true/false is
		// exactly what makes a parent-aware operand on an ancestor change
		// truth. Walk the changed tag's OWN (bounded, <= MAX_IDENTIFIER_
		// SEGMENTS) ancestor chain and probe the index at each one, rather
		// than scanning every registered reaction.
		if (tags != nullptr) {
			const auto self_it = parent_aware_index.find(changed_tag);
			if (self_it != parent_aware_index.end()) {
				result.insert(self_it->second.begin(), self_it->second.end());
			}
			for (DefinitionId ancestor : tags->ancestors_of(changed_tag)) {
				const auto ancestor_it = parent_aware_index.find(ancestor);
				if (ancestor_it != parent_aware_index.end()) {
					result.insert(ancestor_it->second.begin(), ancestor_it->second.end());
				}
			}
		}
	}
	return std::vector<DefinitionId>(result.begin(), result.end());
}

void TagReactionRegistry::build_cycle_conflict(const std::vector<DefinitionId> &p_stack, DefinitionId p_closing_node, TagReactionCycleConflict &r_conflict) const {
	r_conflict.reaction_path.clear();
	r_conflict.effect_path.clear();

	std::size_t start = 0;
	for (std::size_t i = 0; i < p_stack.size(); ++i) {
		if (p_stack[i] == p_closing_node) {
			start = i;
			break;
		}
	}
	for (std::size_t i = start; i < p_stack.size(); ++i) {
		const TagReactionDefinition &definition = by_id[p_stack[i]];
		r_conflict.reaction_path.push_back(definition.identifier);
		r_conflict.effect_path.push_back(definition.effect_identifier);
	}
	// Repeat the closing node's identifier so the loop's closure is visible
	// without the caller needing to know this path wraps around; see the
	// struct comment. A length-one self-loop (start == stack.size() - 1)
	// therefore reads as exactly { identifier, identifier }.
	r_conflict.reaction_path.push_back(by_id[p_closing_node].identifier);
}

} // namespace ga
