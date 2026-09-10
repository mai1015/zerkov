#include "core/ga_abilities.h"

#include "core/ga_bytes.h"
#include "core/ga_hash.h"
#include "core/ga_identifier.h"

#include <algorithm>
#include <set>
#include <utility>

namespace ga {

namespace {

Status resolve_operands(const std::vector<TagOperandDesc> &p_descs, const TagRegistry &p_tags,
		std::vector<TagQueryOperand> &r_operands) {
	r_operands.clear();
	r_operands.reserve(p_descs.size());
	for (const TagOperandDesc &desc : p_descs) {
		const DefinitionId id = p_tags.id_of(desc.tag);
		if (id == INVALID_DEFINITION_ID) {
			return make_status(StatusCode::UNKNOWN_TAG, DiagnosticId::DEFINITION_UNKNOWN_REFERENCE, hash_string(desc.tag));
		}
		r_operands.push_back(TagQueryOperand{ id, desc.mode });
	}
	return ok_status();
}

Status build_requirement_query(const TagRequirementDesc &p_desc, const TagRegistry &p_tags, TagQuery &r_query) {
	std::vector<TagQueryOperand> all, any, none;
	Status status = resolve_operands(p_desc.all, p_tags, all);
	if (!status.ok()) {
		return status;
	}
	status = resolve_operands(p_desc.any, p_tags, any);
	if (!status.ok()) {
		return status;
	}
	status = resolve_operands(p_desc.none, p_tags, none);
	if (!status.ok()) {
		return status;
	}
	return TagQuery::build_requirements(all, any, none, r_query);
}

bool is_valid_input_id(const std::string &p_value) {
	if (p_value.empty() || p_value.size() > MAX_STRING_BYTES) {
		return false;
	}
	return true;
}

// Checks the ONE half of "Prediction declaration is unsafe" this file can
// validate against already-sealed content: the effect named by `p_identifier`
// (empty = not declared, trivially fine) must exist, declare itself
// `prediction_safe`, and never carry a periodic outcome. See
// `AbilityRegistry::register_ability`'s doc comment for the full policy.
Status check_effect_prediction_safe(const std::string &p_identifier, const EffectRegistry &p_effects, DefinitionId &r_id) {
	r_id = INVALID_DEFINITION_ID;
	if (p_identifier.empty()) {
		return ok_status();
	}
	const EffectDefinition *definition = p_effects.find(p_identifier);
	if (definition == nullptr) {
		return make_status(StatusCode::UNKNOWN_EFFECT, DiagnosticId::DEFINITION_UNKNOWN_REFERENCE, hash_string(p_identifier));
	}
	r_id = definition->id;
	if (!definition->prediction_safe || definition->has_period) {
		return make_status(StatusCode::PREDICTION_NOT_SAFE, DiagnosticId::HOOK_CAPABILITY_DENIED, hash_string(p_identifier));
	}
	return ok_status();
}

Status resolve_effect_reference(const std::string &p_identifier, const EffectRegistry &p_effects, bool &r_has, DefinitionId &r_id) {
	r_has = false;
	r_id = INVALID_DEFINITION_ID;
	if (p_identifier.empty()) {
		return ok_status();
	}
	const DefinitionId id = p_effects.id_of(p_identifier);
	if (id == INVALID_DEFINITION_ID) {
		return make_status(StatusCode::UNKNOWN_EFFECT, DiagnosticId::DEFINITION_UNKNOWN_REFERENCE, hash_string(p_identifier));
	}
	r_has = true;
	r_id = id;
	return ok_status();
}

} // namespace

Status AbilityRegistry::register_ability(const AbilityDefinitionDesc &p_desc, const TagRegistry &p_tags,
		const EffectRegistry &p_effects, DefinitionId &r_id) {
	r_id = INVALID_DEFINITION_ID;
	if (is_sealed) {
		return make_status(StatusCode::REGISTRY_SEALED);
	}

	const Status grammar = validate_identifier(p_desc.identifier);
	if (!grammar.ok()) {
		return grammar;
	}

	if (p_desc.owned_tags.size() > MAX_GRANTED_TAGS) {
		return make_status(StatusCode::CAPACITY_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, p_desc.owned_tags.size());
	}
	if (p_desc.commit_effects.size() > MAX_ABILITY_COMMIT_EFFECTS) {
		return make_status(StatusCode::CAPACITY_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, p_desc.commit_effects.size());
	}
	if (p_desc.triggers.size() > MAX_ABILITY_TRIGGERS) {
		return make_status(StatusCode::CAPACITY_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, p_desc.triggers.size());
	}

	AbilityDefinition definition;
	definition.identifier = p_desc.identifier;
	definition.activation_policy = p_desc.activation_policy;

	Status status = build_requirement_query(p_desc.required_tags, p_tags, definition.required_tags);
	if (!status.ok()) {
		return status;
	}
	status = build_requirement_query(p_desc.blocked_tags, p_tags, definition.blocked_tags);
	if (!status.ok()) {
		return status;
	}
	status = build_requirement_query(p_desc.cancel_tags, p_tags, definition.cancel_tags);
	if (!status.ok()) {
		return status;
	}

	std::set<DefinitionId> owned_set;
	for (const std::string &tag_identifier : p_desc.owned_tags) {
		const DefinitionId id = p_tags.id_of(tag_identifier);
		if (id == INVALID_DEFINITION_ID) {
			return make_status(StatusCode::UNKNOWN_TAG, DiagnosticId::DEFINITION_UNKNOWN_REFERENCE, hash_string(tag_identifier));
		}
		owned_set.insert(id);
	}
	definition.owned_tags.assign(owned_set.begin(), owned_set.end());

	for (const AbilityTriggerDesc &trigger_desc : p_desc.triggers) {
		AbilityTrigger trigger;
		trigger.kind = trigger_desc.kind;
		switch (trigger_desc.kind) {
			case AbilityTriggerDesc::Kind::INPUT: {
				if (!is_valid_input_id(trigger_desc.input_id)) {
					return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::BYTE_LIMIT_EXCEEDED, hash_string(trigger_desc.input_id));
				}
				trigger.input_id = trigger_desc.input_id;
				break;
			}
			case AbilityTriggerDesc::Kind::GAMEPLAY_EVENT: {
				const DefinitionId id = p_tags.id_of(trigger_desc.gameplay_event_tag);
				if (id == INVALID_DEFINITION_ID) {
					return make_status(StatusCode::UNKNOWN_TAG, DiagnosticId::DEFINITION_UNKNOWN_REFERENCE, hash_string(trigger_desc.gameplay_event_tag));
				}
				trigger.gameplay_event_tag = id;
				break;
			}
		}
		definition.triggers.push_back(trigger);
	}

	status = resolve_effect_reference(p_desc.cost_effect, p_effects, definition.has_cost_effect, definition.cost_effect);
	if (!status.ok()) {
		return status;
	}
	status = resolve_effect_reference(p_desc.cooldown_effect, p_effects, definition.has_cooldown_effect, definition.cooldown_effect);
	if (!status.ok()) {
		return status;
	}
	for (const std::string &effect_identifier : p_desc.commit_effects) {
		bool has = false;
		DefinitionId id = INVALID_DEFINITION_ID;
		status = resolve_effect_reference(effect_identifier, p_effects, has, id);
		if (!status.ok()) {
			return status;
		}
		if (has) {
			definition.commit_effects.push_back(id);
		}
	}

	definition.concurrency_policy = p_desc.concurrency_policy;
	definition.duplicate_grant_policy = p_desc.duplicate_grant_policy;
	definition.revoke_policy = p_desc.revoke_policy;
	definition.prediction_policy = p_desc.prediction_policy;
	definition.hook_binding = p_desc.hook_binding;
	definition.auto_commit = p_desc.auto_commit;
	definition.ends_on_commit = p_desc.ends_on_commit;
	definition.prediction_safe_declared = p_desc.prediction_safe_declared;

	// Prediction-safety validation -- see doc comment on this method.
	if (p_desc.prediction_policy == AbilityPredictionPolicy::PREDICTABLE) {
		if (definition.hook_binding == AbilityHookBinding::AUTHORITY_ONLY) {
			return make_status(StatusCode::PREDICTION_NOT_SAFE, DiagnosticId::HOOK_CAPABILITY_DENIED, hash_string(p_desc.identifier));
		}
		DefinitionId unused = INVALID_DEFINITION_ID;
		status = check_effect_prediction_safe(p_desc.cost_effect, p_effects, unused);
		if (!status.ok()) {
			return status;
		}
		status = check_effect_prediction_safe(p_desc.cooldown_effect, p_effects, unused);
		if (!status.ok()) {
			return status;
		}
		for (const std::string &effect_identifier : p_desc.commit_effects) {
			status = check_effect_prediction_safe(effect_identifier, p_effects, unused);
			if (!status.ok()) {
				return status;
			}
		}
	}

	status = identifiers.intern(p_desc.identifier, r_id);
	if (!status.ok()) {
		return status;
	}
	pending.emplace(p_desc.identifier, std::move(definition));
	return ok_status();
}

Status AbilityRegistry::seal() {
	if (is_sealed) {
		return make_status(StatusCode::REGISTRY_SEALED);
	}

	// `pending` is a std::map sorted by identifier; iterating it in order and
	// assigning dense ids 1..N as we go reproduces the exact same
	// identifier-byte-order seal-time assignment every other registry in
	// this addon uses (see IdentifierTable::seal / EffectRegistry::seal).
	// `identifiers` itself is used only for intern()'s duplicate/collision
	// detection at registration time, never sealed -- `id_of`/`find` below
	// scan `by_id` directly, matching `EffectRegistry`'s own convention.
	by_id.clear();
	by_id.emplace_back(); // index 0 unused
	DefinitionId next_id = 1;
	for (auto &entry : pending) {
		AbilityDefinition definition = std::move(entry.second);
		definition.id = next_id;
		by_id.push_back(std::move(definition));
		++next_id;
	}

	is_sealed = true;
	return ok_status();
}

const AbilityDefinition *AbilityRegistry::find(DefinitionId p_id) const {
	if (!is_sealed || p_id == INVALID_DEFINITION_ID || p_id >= by_id.size()) {
		return nullptr;
	}
	return &by_id[p_id];
}

const AbilityDefinition *AbilityRegistry::find(const std::string &p_identifier) const {
	return find(id_of(p_identifier));
}

DefinitionId AbilityRegistry::id_of(const std::string &p_identifier) const {
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

std::vector<DefinitionId> AbilityRegistry::canonical_order() const {
	std::vector<DefinitionId> result;
	if (!is_sealed) {
		return result;
	}
	for (std::size_t i = 1; i < by_id.size(); ++i) {
		result.push_back(by_id[i].id);
	}
	return result;
}

Status AbilityRegistry::contribute_manifest(ManifestBuilder &p_builder) const {
	if (!is_sealed) {
		return make_status(StatusCode::INVALID_ARGUMENT);
	}
	for (std::size_t i = 1; i < by_id.size(); ++i) {
		const AbilityDefinition &def = by_id[i];
		ByteWriter writer;
		writer.write_u8(static_cast<std::uint8_t>(def.activation_policy));

		Status encode_status = def.required_tags.encode(writer);
		if (!encode_status.ok()) {
			return encode_status;
		}
		encode_status = def.blocked_tags.encode(writer);
		if (!encode_status.ok()) {
			return encode_status;
		}
		encode_status = def.cancel_tags.encode(writer);
		if (!encode_status.ok()) {
			return encode_status;
		}

		writer.write_u16(static_cast<std::uint16_t>(def.owned_tags.size()));
		for (DefinitionId tag : def.owned_tags) {
			writer.write_u32(tag);
		}

		writer.write_bool(def.has_cost_effect);
		writer.write_u32(def.cost_effect);
		writer.write_bool(def.has_cooldown_effect);
		writer.write_u32(def.cooldown_effect);

		writer.write_u16(static_cast<std::uint16_t>(def.commit_effects.size()));
		for (DefinitionId effect : def.commit_effects) {
			writer.write_u32(effect);
		}

		writer.write_u16(static_cast<std::uint16_t>(def.triggers.size()));
		for (const AbilityTrigger &trigger : def.triggers) {
			writer.write_u8(static_cast<std::uint8_t>(trigger.kind));
			writer.write_string(trigger.input_id);
			writer.write_u32(trigger.gameplay_event_tag);
		}

		writer.write_u8(static_cast<std::uint8_t>(def.concurrency_policy));
		writer.write_u8(static_cast<std::uint8_t>(def.duplicate_grant_policy));
		writer.write_u8(static_cast<std::uint8_t>(def.revoke_policy));
		writer.write_u8(static_cast<std::uint8_t>(def.prediction_policy));
		writer.write_u8(static_cast<std::uint8_t>(def.hook_binding));
		writer.write_bool(def.auto_commit);
		writer.write_bool(def.ends_on_commit);
		writer.write_bool(def.prediction_safe_declared);

		if (!writer.ok()) {
			return writer.status();
		}
		const Status add_status = p_builder.add(ManifestEntryKind::ABILITY, def.identifier, writer.take());
		if (!add_status.ok()) {
			return add_status;
		}
	}
	return ok_status();
}

} // namespace ga
