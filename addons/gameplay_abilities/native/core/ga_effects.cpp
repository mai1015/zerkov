#include "core/ga_effects.h"

#include "core/ga_bytes.h"
#include "core/ga_hash.h"
#include "core/ga_identifier.h"
#include "core/ga_tick.h"

#include <algorithm>
#include <iterator>
#include <set>

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

Status quantize_field(double p_value, Fixed &r_out) {
	return fixed_quantize(p_value, r_out);
}

// Set-by-caller fields are lightweight named parameters (e.g. "heal_amount"),
// not top-level namespaced content identifiers -- they are never registered
// in a shared registry or looked up across effects, only matched against the
// SAME effect's own declaration (see EffectSpec/validate_effect_spec). They
// therefore use the identifier grammar's single-segment charset
// (`[a-z][a-z0-9_]*`) WITHOUT requiring `validate_identifier`'s >= 2 dotted
// segments, which is reserved for tag/attribute/effect/cue identifiers.
bool is_valid_field_name(const std::string &p_name) {
	if (p_name.empty() || p_name.size() > MAX_IDENTIFIER_BYTES) {
		return false;
	}
	if (p_name[0] < 'a' || p_name[0] > 'z') {
		return false;
	}
	for (char c : p_name) {
		const bool ok = (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_';
		if (!ok) {
			return false;
		}
	}
	return true;
}

} // namespace

Status EffectRegistry::register_cue(const std::string &p_identifier) {
	if (is_sealed) {
		return make_status(StatusCode::REGISTRY_SEALED);
	}
	const Status grammar = validate_identifier(p_identifier);
	if (!grammar.ok()) {
		return grammar;
	}
	if (!registered_cues.insert(p_identifier).second) {
		return make_status(StatusCode::DUPLICATE_DEFINITION, DiagnosticId::DEFINITION_DUPLICATE, hash_string(p_identifier));
	}
	return ok_status();
}

Status EffectRegistry::register_effect(const EffectDefinitionDesc &p_desc, const TagRegistry &p_tags,
		const AttributeRegistry &p_attributes, DefinitionId &r_id) {
	r_id = INVALID_DEFINITION_ID;
	if (is_sealed) {
		return make_status(StatusCode::REGISTRY_SEALED);
	}

	const Status grammar = validate_identifier(p_desc.identifier);
	if (!grammar.ok()) {
		return grammar;
	}

	// Duration/period consistency.
	switch (p_desc.duration_policy) {
		case EffectDuration::INSTANT: {
			if (p_desc.has_period) {
				return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::PERIOD_INVALID, hash_string(p_desc.identifier));
			}
			break;
		}
		case EffectDuration::DURATION: {
			const Status duration_status = validate_duration_ticks(p_desc.duration_ticks);
			if (!duration_status.ok()) {
				return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::DURATION_INVALID, hash_string(p_desc.identifier));
			}
			break;
		}
		case EffectDuration::INFINITE:
			break;
	}
	if (p_desc.has_period) {
		const Status period_status = validate_period_ticks(p_desc.period_ticks);
		if (!period_status.ok()) {
			return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::PERIOD_INVALID, hash_string(p_desc.identifier));
		}
	}

	if (p_desc.modifiers.size() > MAX_EFFECT_MODIFIERS) {
		return make_status(StatusCode::CAPACITY_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, p_desc.modifiers.size());
	}
	if (p_desc.granted_tags.size() > MAX_GRANTED_TAGS) {
		return make_status(StatusCode::CAPACITY_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, p_desc.granted_tags.size());
	}
	if (p_desc.set_by_caller_fields.size() > MAX_SET_BY_CALLER) {
		return make_status(StatusCode::CAPACITY_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, p_desc.set_by_caller_fields.size());
	}

	// Set-by-caller field declarations: validate grammar, reject duplicates.
	std::set<std::string> declared_fields;
	for (const SetByCallerFieldDesc &field : p_desc.set_by_caller_fields) {
		if (!is_valid_field_name(field.identifier)) {
			return make_status(StatusCode::INVALID_IDENTIFIER, DiagnosticId::IDENTIFIER_BAD_CHARACTER, hash_string(field.identifier));
		}
		if (!declared_fields.insert(field.identifier).second) {
			return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::DEFINITION_DUPLICATE, hash_string(field.identifier));
		}
	}

	// Modifiers.
	std::vector<ModifierDeclaration> modifiers;
	modifiers.reserve(p_desc.modifiers.size());
	for (const ModifierDeclarationDesc &mod_desc : p_desc.modifiers) {
		ModifierDeclaration modifier;
		modifier.target_attribute = p_attributes.id_of(mod_desc.target_attribute);
		if (modifier.target_attribute == INVALID_DEFINITION_ID) {
			return make_status(StatusCode::UNKNOWN_ATTRIBUTE, DiagnosticId::DEFINITION_UNKNOWN_REFERENCE, hash_string(mod_desc.target_attribute));
		}
		modifier.op = mod_desc.op;
		modifier.priority = mod_desc.priority;

		MagnitudeSource magnitude;
		magnitude.kind = mod_desc.magnitude.kind;
		const Status coeff_status = quantize_field(mod_desc.magnitude.coefficient, magnitude.coefficient);
		if (!coeff_status.ok()) {
			return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_NOT_REPRESENTABLE, hash_string(p_desc.identifier));
		}
		switch (mod_desc.magnitude.kind) {
			case MagnitudeSourceKind::CONSTANT:
			case MagnitudeSourceKind::ABILITY_LEVEL:
				break;
			case MagnitudeSourceKind::SOURCE_ATTRIBUTE:
			case MagnitudeSourceKind::TARGET_ATTRIBUTE: {
				magnitude.attribute = p_attributes.id_of(mod_desc.magnitude.attribute);
				if (magnitude.attribute == INVALID_DEFINITION_ID) {
					return make_status(StatusCode::UNKNOWN_ATTRIBUTE, DiagnosticId::DEFINITION_UNKNOWN_REFERENCE, hash_string(mod_desc.magnitude.attribute));
				}
				break;
			}
			case MagnitudeSourceKind::SET_BY_CALLER: {
				if (declared_fields.find(mod_desc.magnitude.set_by_caller_field) == declared_fields.end()) {
					return make_status(StatusCode::UNDECLARED_SET_BY_CALLER, DiagnosticId::NONE, hash_string(mod_desc.magnitude.set_by_caller_field));
				}
				magnitude.set_by_caller_field = mod_desc.magnitude.set_by_caller_field;
				break;
			}
		}
		modifier.magnitude = magnitude;
		modifiers.push_back(modifier);
	}

	// Granted tags: resolve, dedupe, sort ascending (canonical order).
	std::set<DefinitionId> granted_set;
	for (const std::string &tag_identifier : p_desc.granted_tags) {
		const DefinitionId id = p_tags.id_of(tag_identifier);
		if (id == INVALID_DEFINITION_ID) {
			return make_status(StatusCode::UNKNOWN_TAG, DiagnosticId::DEFINITION_UNKNOWN_REFERENCE, hash_string(tag_identifier));
		}
		granted_set.insert(id);
	}

	// Requirement / immunity queries.
	TagQuery source_requirements;
	Status status = build_requirement_query(p_desc.source_requirements, p_tags, source_requirements);
	if (!status.ok()) {
		return status;
	}
	TagQuery target_requirements;
	status = build_requirement_query(p_desc.target_requirements, p_tags, target_requirements);
	if (!status.ok()) {
		return status;
	}
	TagQuery immunity_query;
	status = build_requirement_query(p_desc.immunity, p_tags, immunity_query);
	if (!status.ok()) {
		return status;
	}

	// Cues: must already be registered via `register_cue`.
	for (const std::string &cue : p_desc.cue_identifiers) {
		if (registered_cues.find(cue) == registered_cues.end()) {
			return make_status(StatusCode::UNKNOWN_DEFINITION, DiagnosticId::DEFINITION_UNKNOWN_REFERENCE, hash_string(cue));
		}
	}

	// Stacking policy.
	StackingPolicy stacking;
	stacking.stackable = p_desc.stacking.stackable;
	stacking.source_scope = p_desc.stacking.source_scope;
	stacking.overflow_policy = p_desc.stacking.overflow_policy;
	stacking.refresh_duration_on_add = p_desc.stacking.refresh_duration_on_add;
	stacking.reset_period_on_add = p_desc.stacking.reset_period_on_add;
	stacking.removal_rule = p_desc.stacking.removal_rule;
	std::string overflow_effect_identifier;
	if (stacking.stackable) {
		stacking.max_stacks = p_desc.stacking.max_stacks;
		if (stacking.max_stacks < 1 || stacking.max_stacks > MAX_STACK_COUNT) {
			return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::COUNT_LIMIT_EXCEEDED, hash_string(p_desc.identifier));
		}
		stacking.stack_key = p_desc.stacking.stack_key.empty() ? p_desc.identifier : p_desc.stacking.stack_key;
		const Status key_grammar = validate_identifier(stacking.stack_key);
		if (!key_grammar.ok()) {
			return key_grammar;
		}
		if (stacking.overflow_policy == StackOverflowPolicy::APPLY_OVERFLOW_EFFECT) {
			if (p_desc.stacking.overflow_effect.empty()) {
				return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::NONE, hash_string(p_desc.identifier));
			}
			overflow_effect_identifier = p_desc.stacking.overflow_effect;
		} else if (!p_desc.stacking.overflow_effect.empty()) {
			return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::NONE, hash_string(p_desc.identifier));
		}
	} else {
		stacking.max_stacks = 1;
	}

	// Intern the identifier last, after every other validation step has
	// succeeded, so a failed registration never consumes the name.
	DefinitionId unused = INVALID_DEFINITION_ID;
	status = identifiers.intern(p_desc.identifier, unused);
	if (!status.ok()) {
		return status;
	}

	EffectDefinition definition;
	definition.identifier = p_desc.identifier;
	definition.duration_policy = p_desc.duration_policy;
	definition.duration_ticks = p_desc.duration_ticks;
	definition.has_period = p_desc.has_period;
	definition.period_ticks = p_desc.period_ticks;
	definition.modifiers = std::move(modifiers);
	definition.granted_tags.assign(granted_set.begin(), granted_set.end());
	definition.source_requirements = source_requirements;
	definition.target_requirements = target_requirements;
	definition.immunity_query = immunity_query;
	definition.stacking = stacking;
	definition.set_by_caller_fields = p_desc.set_by_caller_fields;
	definition.cue_identifiers = p_desc.cue_identifiers;
	definition.prediction_safe = p_desc.prediction_safe;
	definition.retain_target_context = p_desc.retain_target_context;

	PendingEffect pending_entry;
	pending_entry.definition = std::move(definition);
	pending_entry.overflow_effect_identifier = overflow_effect_identifier;
	pending[p_desc.identifier] = std::move(pending_entry);

	return ok_status();
}

Status EffectRegistry::seal() {
	if (is_sealed) {
		return make_status(StatusCode::REGISTRY_SEALED);
	}

	// `pending` is a std::map sorted by identifier; iterating it in order and
	// assigning dense ids 1..N as we go reproduces the exact same
	// identifier-byte-order seal-time assignment every other registry in
	// this addon uses (see IdentifierTable::seal), without needing a second
	// IdentifierTable instance just to re-derive an order this map already
	// has.
	by_id.clear();
	by_id.emplace_back(); // index 0 unused
	DefinitionId next_id = 1;
	for (auto &entry : pending) {
		EffectDefinition definition = entry.second.definition;
		definition.id = next_id;
		by_id.push_back(std::move(definition));
		++next_id;
	}

	// Resolve deferred overflow-effect references now that every identifier
	// has a final id.
	std::size_t idx = 1;
	for (auto &entry : pending) {
		const std::string &overflow_identifier = entry.second.overflow_effect_identifier;
		if (!overflow_identifier.empty()) {
			const auto found = pending.find(overflow_identifier);
			if (found == pending.end()) {
				by_id.clear();
				return make_status(StatusCode::UNKNOWN_DEFINITION, DiagnosticId::DEFINITION_UNKNOWN_REFERENCE, hash_string(overflow_identifier));
			}
			const DefinitionId resolved = DefinitionId(std::distance(pending.begin(), found) + 1);
			by_id[idx].stacking.has_overflow_effect = true;
			by_id[idx].stacking.overflow_effect = resolved;
		}
		++idx;
	}

	is_sealed = true;
	return ok_status();
}

const EffectDefinition *EffectRegistry::find(DefinitionId p_id) const {
	if (!is_sealed || p_id == INVALID_DEFINITION_ID || p_id >= by_id.size()) {
		return nullptr;
	}
	return &by_id[p_id];
}

const EffectDefinition *EffectRegistry::find(const std::string &p_identifier) const {
	return find(id_of(p_identifier));
}

DefinitionId EffectRegistry::id_of(const std::string &p_identifier) const {
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

std::vector<DefinitionId> EffectRegistry::canonical_order() const {
	std::vector<DefinitionId> result;
	if (!is_sealed) {
		return result;
	}
	for (std::size_t i = 1; i < by_id.size(); ++i) {
		result.push_back(by_id[i].id);
	}
	return result;
}

Status EffectRegistry::contribute_manifest(ManifestBuilder &p_builder) const {
	if (!is_sealed) {
		return make_status(StatusCode::INVALID_ARGUMENT);
	}
	for (std::size_t i = 1; i < by_id.size(); ++i) {
		const EffectDefinition &def = by_id[i];
		ByteWriter writer;
		writer.write_u8(static_cast<std::uint8_t>(def.duration_policy));
		writer.write_u64(def.duration_ticks);
		writer.write_bool(def.has_period);
		writer.write_u64(def.period_ticks);
		writer.write_u16(static_cast<std::uint16_t>(def.modifiers.size()));
		for (const ModifierDeclaration &mod : def.modifiers) {
			writer.write_u32(mod.target_attribute);
			writer.write_u8(static_cast<std::uint8_t>(mod.op));
			writer.write_i32(mod.priority);
			writer.write_u8(static_cast<std::uint8_t>(mod.magnitude.kind));
			fixed_write(writer, mod.magnitude.coefficient);
			writer.write_u32(mod.magnitude.attribute);
			writer.write_string(mod.magnitude.set_by_caller_field);
		}
		writer.write_u16(static_cast<std::uint16_t>(def.granted_tags.size()));
		for (DefinitionId tag : def.granted_tags) {
			writer.write_u32(tag);
		}
		Status encode_status = def.source_requirements.encode(writer);
		if (!encode_status.ok()) {
			return encode_status;
		}
		encode_status = def.target_requirements.encode(writer);
		if (!encode_status.ok()) {
			return encode_status;
		}
		encode_status = def.immunity_query.encode(writer);
		if (!encode_status.ok()) {
			return encode_status;
		}
		writer.write_bool(def.stacking.stackable);
		writer.write_string(def.stacking.stack_key);
		writer.write_u8(static_cast<std::uint8_t>(def.stacking.source_scope));
		writer.write_u32(def.stacking.max_stacks);
		writer.write_u8(static_cast<std::uint8_t>(def.stacking.overflow_policy));
		writer.write_bool(def.stacking.refresh_duration_on_add);
		writer.write_bool(def.stacking.reset_period_on_add);
		writer.write_u8(static_cast<std::uint8_t>(def.stacking.removal_rule));
		writer.write_bool(def.stacking.has_overflow_effect);
		writer.write_u32(def.stacking.overflow_effect);
		writer.write_u16(static_cast<std::uint16_t>(def.set_by_caller_fields.size()));
		for (const SetByCallerFieldDesc &field : def.set_by_caller_fields) {
			writer.write_string(field.identifier);
			writer.write_bool(field.required);
		}
		writer.write_u16(static_cast<std::uint16_t>(def.cue_identifiers.size()));
		for (const std::string &cue : def.cue_identifiers) {
			writer.write_string(cue);
		}
		writer.write_bool(def.prediction_safe);
		writer.write_bool(def.retain_target_context);

		if (!writer.ok()) {
			return writer.status();
		}
		const Status add_status = p_builder.add(ManifestEntryKind::EFFECT, def.identifier, writer.take());
		if (!add_status.ok()) {
			return add_status;
		}
	}
	return ok_status();
}

} // namespace ga
