#include "core/ga_attributes.h"

#include "core/ga_bytes.h"
#include "core/ga_hash.h"
#include "core/ga_identifier.h"
#include "core/ga_limits.h"

namespace ga {

Status AttributeRegistry::register_attribute(const std::string &p_identifier,
		double p_default_base,
		bool p_has_min, double p_min_value,
		bool p_has_max, double p_max_value,
		const std::string &p_display_name,
		DefinitionId &r_id) {
	r_id = INVALID_DEFINITION_ID;

	if (is_sealed) {
		return make_status(StatusCode::REGISTRY_SEALED);
	}

	if (pending.size() >= MAX_ATTRIBUTES) {
		return make_status(StatusCode::CAPACITY_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, MAX_ATTRIBUTES);
	}

	const Status identifier_status = validate_identifier(p_identifier);
	if (!identifier_status.ok()) {
		return identifier_status;
	}

	if (p_display_name.size() > MAX_STRING_BYTES) {
		return make_status(StatusCode::OUT_OF_BOUNDS, DiagnosticId::BYTE_LIMIT_EXCEEDED, p_display_name.size());
	}

	const std::uint64_t identifier_hash = hash_string(p_identifier);

	Fixed default_base;
	if (!fixed_quantize(p_default_base, default_base).ok()) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_NOT_REPRESENTABLE, identifier_hash);
	}

	Fixed min_value = Fixed::zero();
	if (p_has_min && !fixed_quantize(p_min_value, min_value).ok()) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_NOT_REPRESENTABLE, identifier_hash);
	}

	Fixed max_value = Fixed::zero();
	if (p_has_max && !fixed_quantize(p_max_value, max_value).ok()) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_NOT_REPRESENTABLE, identifier_hash);
	}

	if (p_has_min && p_has_max && min_value > max_value) {
		return make_status(StatusCode::INVALID_BOUNDS, DiagnosticId::BOUNDS_INVERTED, identifier_hash);
	}

	DefinitionId placeholder = INVALID_DEFINITION_ID;
	const Status intern_status = id_table.intern(p_identifier, placeholder);
	if (!intern_status.ok()) {
		return intern_status;
	}

	AttributeDefinition definition;
	definition.identifier = p_identifier;
	definition.default_base = default_base;
	definition.has_min = p_has_min;
	definition.min_value = min_value;
	definition.has_max = p_has_max;
	definition.max_value = max_value;
	definition.display_name = p_display_name;

	pending.emplace(p_identifier, definition);
	r_id = INVALID_DEFINITION_ID;
	return ok_status();
}

Status AttributeRegistry::seal() {
	if (is_sealed) {
		return make_status(StatusCode::REGISTRY_SEALED);
	}

	const Status seal_status = id_table.seal();
	if (!seal_status.ok()) {
		return seal_status;
	}

	const std::vector<DefinitionId> order = id_table.canonical_order();
	sealed_definitions.assign(order.size() + 1, AttributeDefinition{}); // index 0 unused

	for (DefinitionId id : order) {
		const std::string *name = id_table.name_of(id);
		if (name == nullptr) {
			continue; // unreachable: every id from canonical_order() has a name.
		}
		auto it = pending.find(*name);
		if (it == pending.end()) {
			continue; // unreachable: every interned identifier was registered with a pending entry.
		}
		AttributeDefinition definition = it->second;
		definition.id = id;
		sealed_definitions[id] = definition;
	}

	is_sealed = true;
	return ok_status();
}

const AttributeDefinition *AttributeRegistry::find(DefinitionId p_id) const {
	if (!is_sealed || p_id == INVALID_DEFINITION_ID || p_id >= sealed_definitions.size()) {
		return nullptr;
	}
	return &sealed_definitions[p_id];
}

const AttributeDefinition *AttributeRegistry::find(const std::string &p_identifier) const {
	return find(id_of(p_identifier));
}

DefinitionId AttributeRegistry::id_of(const std::string &p_identifier) const {
	return id_table.lookup(p_identifier);
}

std::vector<DefinitionId> AttributeRegistry::canonical_order() const {
	return id_table.canonical_order();
}

std::size_t AttributeRegistry::size() const {
	return is_sealed ? (sealed_definitions.empty() ? 0 : sealed_definitions.size() - 1) : pending.size();
}

Status AttributeRegistry::contribute_manifest(ManifestBuilder &p_builder) const {
	if (!is_sealed) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::NONE);
	}

	for (DefinitionId id : id_table.canonical_order()) {
		const AttributeDefinition *definition = find(id);
		if (definition == nullptr) {
			continue; // unreachable
		}

		ByteWriter writer(MAX_SNAPSHOT_BYTES);
		writer.write_i64(definition->default_base.raw);
		writer.write_bool(definition->has_min);
		writer.write_i64(definition->min_value.raw);
		writer.write_bool(definition->has_max);
		writer.write_i64(definition->max_value.raw);
		if (!writer.ok()) {
			return writer.status();
		}

		const Status add_status = p_builder.add(ManifestEntryKind::ATTRIBUTE, definition->identifier, writer.bytes());
		if (!add_status.ok()) {
			return add_status;
		}
	}

	return ok_status();
}

} // namespace ga
