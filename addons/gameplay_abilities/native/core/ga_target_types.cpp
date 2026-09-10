#include "core/ga_target_types.h"

#include "core/ga_hash.h"
#include "core/ga_identifier.h"

#include <algorithm>
#include <cmath>
#include <limits>
#include <set>

namespace ga {

namespace {

bool valid_kind(TargetValueKind p_kind) {
	return static_cast<std::uint8_t>(p_kind) <=
			static_cast<std::uint8_t>(TargetValueKind::HIT_SET);
}

bool valid_dimension(TargetSpatialDimension p_dimension) {
	return p_dimension == TargetSpatialDimension::NONE ||
			p_dimension == TargetSpatialDimension::TWO_D ||
			p_dimension == TargetSpatialDimension::THREE_D;
}

bool spatial_kind(TargetValueKind p_kind) {
	return p_kind == TargetValueKind::POINT ||
			p_kind == TargetValueKind::DIRECTION ||
			p_kind == TargetValueKind::RAY ||
			p_kind == TargetValueKind::HIT_SET;
}

std::size_t component_count(TargetSpatialDimension p_dimension) {
	return p_dimension == TargetSpatialDimension::TWO_D ? 2 :
			(p_dimension == TargetSpatialDimension::THREE_D ? 3 : 0);
}

bool valid_enum_values(const TargetSchemaDesc &p_desc) {
	return valid_kind(p_desc.intent_kind) && valid_kind(p_desc.result_kind) &&
			valid_dimension(p_desc.dimension) &&
			static_cast<std::uint8_t>(p_desc.entity_order) <=
					static_cast<std::uint8_t>(TargetEntityOrder::PROVIDER_RANKED) &&
			static_cast<std::uint8_t>(p_desc.duplicate_policy) <=
					static_cast<std::uint8_t>(
							TargetDuplicatePolicy::STABLE_FIRST_DEDUPLICATE) &&
			static_cast<std::uint8_t>(p_desc.session_mode) <=
					static_cast<std::uint8_t>(TargetSessionMode::CONFIRM_OR_CANCEL) &&
			static_cast<std::uint8_t>(p_desc.acceptance_policy) <=
					static_cast<std::uint8_t>(TargetAcceptancePolicy::ALLOW_EMPTY) &&
			static_cast<std::uint8_t>(p_desc.visibility) <=
					static_cast<std::uint8_t>(TargetResultVisibility::INTERNAL) &&
			static_cast<std::uint8_t>(p_desc.prediction_policy) <=
					static_cast<std::uint8_t>(TargetPredictionPolicy::PREDICTION_SAFE);
}

std::int64_t abs_raw(std::int64_t p_value) {
	if (p_value == std::numeric_limits<std::int64_t>::min()) {
		return std::numeric_limits<std::int64_t>::max();
	}
	return p_value < 0 ? -p_value : p_value;
}

bool round_to_step(std::int64_t p_value, std::int64_t p_step,
		std::int64_t &r_value) {
	if (p_step <= 0) {
		return false;
	}
	const std::int64_t quotient = p_value / p_step;
	const std::int64_t remainder = p_value % p_step;
	std::int64_t rounded = quotient;
	if (abs_raw(remainder) >= (p_step + 1) / 2) {
		if (p_value > 0) {
			if (rounded == std::numeric_limits<std::int64_t>::max()) {
				return false;
			}
			++rounded;
		} else if (p_value < 0) {
			if (rounded == std::numeric_limits<std::int64_t>::min()) {
				return false;
			}
			--rounded;
		}
	}
	const __int128 product = static_cast<__int128>(rounded) * p_step;
	if (product < std::numeric_limits<std::int64_t>::min() ||
			product > std::numeric_limits<std::int64_t>::max()) {
		return false;
	}
	r_value = static_cast<std::int64_t>(product);
	return true;
}

unsigned __int128 integer_sqrt(unsigned __int128 p_value) {
	if (p_value == 0) {
		return 0;
	}
	unsigned __int128 result = 0;
	unsigned __int128 bit = static_cast<unsigned __int128>(1) << 126;
	while (bit > p_value) {
		bit >>= 2;
	}
	while (bit != 0) {
		if (p_value >= result + bit) {
			p_value -= result + bit;
			result = (result >> 1) + bit;
		} else {
			result >>= 1;
		}
		bit >>= 2;
	}
	return result;
}

bool divide_round(__int128 p_numerator, unsigned __int128 p_denominator,
		std::int64_t &r_value) {
	if (p_denominator == 0) {
		return false;
	}
	const bool negative = p_numerator < 0;
	unsigned __int128 magnitude = negative ?
			static_cast<unsigned __int128>(-p_numerator) :
			static_cast<unsigned __int128>(p_numerator);
	unsigned __int128 quotient = magnitude / p_denominator;
	const unsigned __int128 remainder = magnitude % p_denominator;
	if (remainder * 2 >= p_denominator) {
		++quotient;
	}
	const unsigned __int128 max_positive =
			static_cast<unsigned __int128>(
					std::numeric_limits<std::int64_t>::max());
	if (quotient > max_positive + (negative ? 1 : 0)) {
		return false;
	}
	if (negative && quotient == max_positive + 1) {
		r_value = std::numeric_limits<std::int64_t>::min();
	} else {
		r_value = negative ? -static_cast<std::int64_t>(quotient) :
				static_cast<std::int64_t>(quotient);
	}
	return true;
}

Status canonicalize_vector(const TargetVector &p_input,
		const TargetSchemaDesc &p_schema, bool p_normalize,
		TargetVector &r_output) {
	const std::size_t dimensions = component_count(p_schema.dimension);
	if (dimensions == 0) {
		return make_status(StatusCode::INVALID_TARGET_DATA,
				DiagnosticId::INVALID_TARGET_COORDINATE);
	}
	r_output = TargetVector{};
	for (std::size_t i = 0; i < dimensions; ++i) {
		if (abs_raw(p_input.raw[i]) > p_schema.max_coordinate_raw ||
				!round_to_step(p_input.raw[i], p_schema.precision_raw,
						r_output.raw[i])) {
			return make_status(StatusCode::INVALID_TARGET_DATA,
					DiagnosticId::INVALID_TARGET_COORDINATE, i);
		}
	}
	for (std::size_t i = dimensions; i < 3; ++i) {
		if (p_input.raw[i] != 0) {
			return make_status(StatusCode::INVALID_TARGET_DATA,
					DiagnosticId::INVALID_TARGET_COORDINATE, i);
		}
	}
	if (!p_normalize) {
		return ok_status();
	}

	unsigned __int128 squared = 0;
	for (std::size_t i = 0; i < dimensions; ++i) {
		const __int128 component = r_output.raw[i];
		squared += static_cast<unsigned __int128>(component * component);
	}
	const unsigned __int128 magnitude = integer_sqrt(squared);
	if (magnitude == 0) {
		return make_status(StatusCode::INVALID_TARGET_DATA,
				DiagnosticId::INVALID_TARGET_COORDINATE);
	}
	TargetVector normalized;
	for (std::size_t i = 0; i < dimensions; ++i) {
		std::int64_t raw = 0;
		if (!divide_round(static_cast<__int128>(r_output.raw[i]) *
						p_schema.coordinate_scale,
					magnitude, raw) ||
				!round_to_step(raw, p_schema.precision_raw,
						normalized.raw[i])) {
			return make_status(StatusCode::INVALID_TARGET_DATA,
					DiagnosticId::INVALID_TARGET_COORDINATE, i);
		}
	}
	r_output = normalized;
	return ok_status();
}

Status canonicalize_entities(const std::vector<EntityId> &p_input,
		const TargetSchemaDesc &p_schema, EntityId p_source,
		std::vector<EntityId> &r_output) {
	if (p_input.size() > p_schema.max_entities ||
			p_input.size() > MAX_TARGETS_PER_COMMAND) {
		return make_status(StatusCode::CAPACITY_EXCEEDED,
				DiagnosticId::COUNT_LIMIT_EXCEEDED, p_input.size());
	}
	r_output.clear();
	r_output.reserve(p_input.size());
	std::set<EntityId> seen;
	for (EntityId entity : p_input) {
		if (!entity) {
			return make_status(StatusCode::INVALID_TARGET_DATA,
					DiagnosticId::TARGET_NOT_RELEVANT);
		}
		if (!p_schema.allow_self && p_source && entity == p_source) {
			return make_status(StatusCode::INVALID_TARGET_DATA,
					DiagnosticId::TARGET_RULE_REJECTED, entity.value);
		}
		const bool inserted = seen.insert(entity).second;
		if (!inserted) {
			if (p_schema.duplicate_policy == TargetDuplicatePolicy::REJECT) {
				return make_status(StatusCode::INVALID_TARGET_DATA,
						DiagnosticId::TARGET_RULE_REJECTED, entity.value);
			}
			continue;
		}
		r_output.push_back(entity);
	}
	if (p_schema.entity_order == TargetEntityOrder::CANONICAL_BY_ID) {
		std::sort(r_output.begin(), r_output.end());
	}
	// `allow_empty` is an explicit zero-result alternative to the normal
	// minimum cardinality (for example "zero or at least two targets").
	// Without this branch an ALLOW_EMPTY schema whose ordinary
	// `min_entities` remained non-zero could never fulfill its contract.
	if ((r_output.empty() && !p_schema.allow_empty) ||
			(!r_output.empty() &&
					r_output.size() < p_schema.min_entities)) {
		return make_status(StatusCode::INVALID_TARGET_DATA,
				DiagnosticId::COUNT_LIMIT_EXCEEDED, r_output.size());
	}
	return ok_status();
}

Status canonicalize_hit(const TargetHit &p_input,
		const TargetSchemaDesc &p_schema, EntityId p_source,
		TargetHit &r_output) {
	if (p_input.has_entity && !p_input.entity) {
		return make_status(StatusCode::INVALID_TARGET_DATA,
				DiagnosticId::TARGET_NOT_RELEVANT);
	}
	if (p_input.has_entity && !p_schema.allow_self && p_source &&
			p_input.entity == p_source) {
		return make_status(StatusCode::INVALID_TARGET_DATA,
				DiagnosticId::TARGET_RULE_REJECTED,
				p_input.entity.value);
	}
	r_output = p_input;
	if (!p_input.has_entity) {
		r_output.entity = INVALID_ENTITY_ID;
	}
	if (!p_input.has_surface_tag) {
		r_output.surface_tag = INVALID_DEFINITION_ID;
	} else if (p_input.surface_tag == INVALID_DEFINITION_ID) {
		return make_status(StatusCode::INVALID_TARGET_DATA,
				DiagnosticId::DEFINITION_UNKNOWN_REFERENCE);
	}
	Status status = canonicalize_vector(p_input.position, p_schema, false,
			r_output.position);
	if (!status.ok()) {
		return status;
	}
	status = canonicalize_vector(p_input.normal, p_schema, true,
			r_output.normal);
	if (!status.ok()) {
		return status;
	}
	if (p_input.distance_raw < 0 ||
			p_input.distance_raw > p_schema.max_coordinate_raw ||
			!round_to_step(p_input.distance_raw, p_schema.precision_raw,
					r_output.distance_raw)) {
		return make_status(StatusCode::INVALID_TARGET_DATA,
				DiagnosticId::INVALID_TARGET_COORDINATE);
	}
	return ok_status();
}

void write_vector(ByteWriter &p_writer, const TargetVector &p_vector,
		std::size_t p_dimensions) {
	for (std::size_t i = 0; i < p_dimensions; ++i) {
		p_writer.write_i64(p_vector.raw[i]);
	}
}

bool read_vector(ByteReader &p_reader, TargetVector &r_vector,
		std::size_t p_dimensions) {
	r_vector = TargetVector{};
	for (std::size_t i = 0; i < p_dimensions; ++i) {
		if (!p_reader.read_i64(r_vector.raw[i])) {
			return false;
		}
	}
	return true;
}

void write_schema_fields(ByteWriter &p_writer,
		const TargetSchemaDesc &p_desc) {
	p_writer.write_u16(TARGET_SCHEMA_CANONICAL_VERSION);
	p_writer.write_u16(p_desc.schema_version);
	p_writer.write_u8(static_cast<std::uint8_t>(p_desc.intent_kind));
	p_writer.write_u8(static_cast<std::uint8_t>(p_desc.result_kind));
	p_writer.write_u8(static_cast<std::uint8_t>(p_desc.dimension));
	p_writer.write_string(p_desc.coordinate_space);
	p_writer.write_i64(p_desc.coordinate_scale);
	p_writer.write_i64(p_desc.precision_raw);
	p_writer.write_i64(p_desc.max_coordinate_raw);
	p_writer.write_u16(p_desc.min_entities);
	p_writer.write_u16(p_desc.max_entities);
	p_writer.write_u16(p_desc.min_hits);
	p_writer.write_u16(p_desc.max_hits);
	p_writer.write_u16(p_desc.max_payload_bytes);
	p_writer.write_u8(static_cast<std::uint8_t>(p_desc.entity_order));
	p_writer.write_u8(static_cast<std::uint8_t>(p_desc.duplicate_policy));
	p_writer.write_bool(p_desc.allow_self);
	p_writer.write_bool(p_desc.allow_empty);
	p_writer.write_u8(static_cast<std::uint8_t>(p_desc.session_mode));
	p_writer.write_u8(static_cast<std::uint8_t>(p_desc.acceptance_policy));
	p_writer.write_string(p_desc.authority_provider);
	p_writer.write_u16(p_desc.provider_contract_version);
	p_writer.write_u8(static_cast<std::uint8_t>(p_desc.visibility));
	p_writer.write_u64(p_desc.deadline_ticks);
	p_writer.write_u16(p_desc.max_submissions);
	p_writer.write_u16(p_desc.max_provider_work);
	p_writer.write_bool(p_desc.preview_allowed);
	p_writer.write_u8(static_cast<std::uint8_t>(p_desc.prediction_policy));
}

void write_value_unchecked(ByteWriter &p_writer,
		const TargetValue &p_value, const TargetSchema &p_schema) {
	const std::size_t dimensions = component_count(p_schema.desc.dimension);
	p_writer.write_u8(TARGET_VALUE_VERSION);
	p_writer.write_u8(static_cast<std::uint8_t>(p_value.kind));
	switch (p_value.kind) {
		case TargetValueKind::ENTITY_SET:
			p_writer.write_count(p_value.entities.size(),
					p_schema.desc.max_entities);
			for (EntityId entity : p_value.entities) {
				p_writer.write_u64(entity.value);
			}
			break;
		case TargetValueKind::POINT:
			write_vector(p_writer, p_value.point, dimensions);
			break;
		case TargetValueKind::DIRECTION:
			write_vector(p_writer, p_value.direction, dimensions);
			break;
		case TargetValueKind::RAY:
			write_vector(p_writer, p_value.ray.origin, dimensions);
			write_vector(p_writer, p_value.ray.direction, dimensions);
			p_writer.write_i64(p_value.ray.length_raw);
			break;
		case TargetValueKind::HIT_SET:
			p_writer.write_count(p_value.hits.size(),
					p_schema.desc.max_hits);
			for (const TargetHit &hit : p_value.hits) {
				p_writer.write_bool(hit.has_entity);
				if (hit.has_entity) {
					p_writer.write_u64(hit.entity.value);
				}
				write_vector(p_writer, hit.position, dimensions);
				write_vector(p_writer, hit.normal, dimensions);
				p_writer.write_i64(hit.distance_raw);
				p_writer.write_bool(hit.has_surface_tag);
				if (hit.has_surface_tag) {
					p_writer.write_u32(hit.surface_tag);
				}
			}
			break;
	}
}

} // namespace

Status validate_target_schema(const TargetSchemaDesc &p_desc) {
	Status status = validate_identifier(p_desc.identifier);
	if (!status.ok()) {
		return status;
	}
	if (!valid_enum_values(p_desc)) {
		return make_status(StatusCode::INVALID_ARGUMENT,
				DiagnosticId::INVALID_TARGET_SCHEMA);
	}
	if (p_desc.schema_version == 0 ||
			p_desc.provider_contract_version == 0) {
		return make_status(StatusCode::INVALID_ARGUMENT,
				DiagnosticId::INVALID_TARGET_SCHEMA);
	}
	if (!validate_identifier(p_desc.authority_provider).ok() ||
			!validate_identifier(p_desc.coordinate_space).ok()) {
		return make_status(StatusCode::INVALID_ARGUMENT,
				DiagnosticId::INVALID_TARGET_SCHEMA);
	}
	const bool needs_spatial = spatial_kind(p_desc.intent_kind) ||
			spatial_kind(p_desc.result_kind);
	if (needs_spatial && p_desc.dimension == TargetSpatialDimension::NONE) {
		return make_status(StatusCode::INVALID_ARGUMENT,
				DiagnosticId::INVALID_TARGET_SCHEMA);
	}
	if (!needs_spatial && p_desc.dimension != TargetSpatialDimension::NONE) {
		return make_status(StatusCode::INVALID_ARGUMENT,
				DiagnosticId::INVALID_TARGET_SCHEMA);
	}
	if (p_desc.coordinate_scale <= 0 ||
			p_desc.precision_raw <= 0 ||
			p_desc.precision_raw > p_desc.coordinate_scale ||
			p_desc.coordinate_scale % p_desc.precision_raw != 0 ||
			p_desc.max_coordinate_raw <= 0 ||
			p_desc.max_coordinate_raw > MAX_TARGET_COORDINATE_RAW ||
			p_desc.max_coordinate_raw % p_desc.precision_raw != 0) {
		return make_status(StatusCode::INVALID_ARGUMENT,
				DiagnosticId::INVALID_TARGET_COORDINATE);
	}
	if (p_desc.min_entities > p_desc.max_entities ||
			p_desc.max_entities > MAX_TARGETS_PER_COMMAND ||
			p_desc.min_hits > p_desc.max_hits ||
			p_desc.max_hits > MAX_TARGET_HITS ||
			p_desc.max_payload_bytes == 0 ||
			p_desc.max_payload_bytes > MAX_TARGET_VALUE_BYTES ||
			p_desc.max_submissions == 0 ||
			p_desc.max_submissions > MAX_TARGET_SUBMISSIONS_PER_SESSION ||
			p_desc.max_provider_work == 0 ||
			p_desc.max_provider_work > MAX_TARGET_PROVIDER_WORK ||
			p_desc.deadline_ticks > MAX_TASK_DEADLINE_HORIZON_TICKS) {
		return make_status(StatusCode::CAPACITY_EXCEEDED,
				DiagnosticId::COUNT_LIMIT_EXCEEDED);
	}
	if (!p_desc.allow_empty &&
			p_desc.acceptance_policy == TargetAcceptancePolicy::ALLOW_EMPTY) {
		return make_status(StatusCode::INVALID_ARGUMENT,
				DiagnosticId::INVALID_TARGET_SCHEMA);
	}
	if (p_desc.description.size() > MAX_STRING_BYTES) {
		return make_status(StatusCode::OUT_OF_BOUNDS,
				DiagnosticId::BYTE_LIMIT_EXCEEDED,
				p_desc.description.size());
	}
	return ok_status();
}

Status TargetSchemaRegistry::register_schema(const TargetSchemaDesc &p_desc,
		DefinitionId &r_id) {
	r_id = INVALID_DEFINITION_ID;
	if (is_sealed) {
		return make_status(StatusCode::REGISTRY_SEALED);
	}
	if (pending.size() >= MAX_TARGET_SCHEMAS) {
		return make_status(StatusCode::CAPACITY_EXCEEDED,
				DiagnosticId::COUNT_LIMIT_EXCEEDED, pending.size());
	}
	Status status = validate_target_schema(p_desc);
	if (!status.ok()) {
		return status;
	}
	DefinitionId placeholder = INVALID_DEFINITION_ID;
	status = id_table.intern(p_desc.identifier, placeholder);
	if (!status.ok()) {
		return status;
	}
	TargetSchema schema;
	schema.desc = p_desc;
	pending.emplace(p_desc.identifier, std::move(schema));
	return ok_status();
}

Status TargetSchemaRegistry::seal() {
	if (is_sealed) {
		return make_status(StatusCode::REGISTRY_SEALED);
	}
	Status status = id_table.seal();
	if (!status.ok()) {
		return status;
	}
	const std::vector<DefinitionId> order = id_table.canonical_order();
	sealed_schemas.assign(order.size() + 1, TargetSchema{});
	for (DefinitionId id : order) {
		const std::string *identifier = id_table.name_of(id);
		if (identifier == nullptr) {
			continue;
		}
		auto it = pending.find(*identifier);
		if (it == pending.end()) {
			continue;
		}
		TargetSchema schema = it->second;
		schema.id = id;
		sealed_schemas[id] = std::move(schema);
	}
	is_sealed = true;
	return ok_status();
}

const TargetSchema *TargetSchemaRegistry::find(DefinitionId p_id) const {
	if (!is_sealed || p_id == INVALID_DEFINITION_ID ||
			p_id >= sealed_schemas.size()) {
		return nullptr;
	}
	return &sealed_schemas[p_id];
}

const TargetSchema *TargetSchemaRegistry::find(
		const std::string &p_identifier) const {
	return find(id_of(p_identifier));
}

DefinitionId TargetSchemaRegistry::id_of(
		const std::string &p_identifier) const {
	return id_table.lookup(p_identifier);
}

std::vector<DefinitionId> TargetSchemaRegistry::canonical_order() const {
	return id_table.canonical_order();
}

std::size_t TargetSchemaRegistry::size() const {
	return is_sealed ?
			(sealed_schemas.empty() ? 0 : sealed_schemas.size() - 1) :
			pending.size();
}

Status TargetSchemaRegistry::contribute_manifest(
		ManifestBuilder &p_builder) const {
	if (!is_sealed) {
		return make_status(StatusCode::INVALID_ARGUMENT);
	}
	for (DefinitionId id : canonical_order()) {
		const TargetSchema *schema = find(id);
		if (schema == nullptr) {
			continue;
		}
		ByteWriter writer(MAX_TARGET_VALUE_BYTES);
		write_schema_fields(writer, schema->desc);
		if (!writer.ok()) {
			return writer.status();
		}
		Status status = p_builder.add(ManifestEntryKind::TARGET_SCHEMA,
				schema->desc.identifier, writer.bytes());
		if (!status.ok()) {
			return status;
		}
	}
	return ok_status();
}

Status normalize_target_value(const TargetValue &p_value,
		const TargetSchema &p_schema, bool p_for_intent,
		EntityId p_source, TargetValue &r_canonical) {
	const TargetValueKind expected = p_for_intent ?
			p_schema.desc.intent_kind : p_schema.desc.result_kind;
	if (!valid_kind(p_value.kind) || p_value.kind != expected) {
		return make_status(StatusCode::INVALID_TARGET_DATA,
				DiagnosticId::INVALID_TARGET_KIND,
				static_cast<std::uint64_t>(p_value.kind));
	}
	r_canonical = TargetValue{};
	r_canonical.kind = expected;
	Status status;
	switch (expected) {
		case TargetValueKind::ENTITY_SET:
			status = canonicalize_entities(p_value.entities, p_schema.desc,
					p_source, r_canonical.entities);
			break;
		case TargetValueKind::POINT:
			status = canonicalize_vector(p_value.point, p_schema.desc, false,
					r_canonical.point);
			break;
		case TargetValueKind::DIRECTION:
			status = canonicalize_vector(p_value.direction, p_schema.desc, true,
					r_canonical.direction);
			break;
		case TargetValueKind::RAY:
			status = canonicalize_vector(p_value.ray.origin, p_schema.desc,
					false, r_canonical.ray.origin);
			if (status.ok()) {
				status = canonicalize_vector(p_value.ray.direction,
						p_schema.desc, true,
						r_canonical.ray.direction);
			}
			if (status.ok()) {
				if (p_value.ray.length_raw < 0 ||
						p_value.ray.length_raw >
								p_schema.desc.max_coordinate_raw ||
						!round_to_step(p_value.ray.length_raw,
								p_schema.desc.precision_raw,
								r_canonical.ray.length_raw)) {
					status = make_status(StatusCode::INVALID_TARGET_DATA,
							DiagnosticId::INVALID_TARGET_COORDINATE);
				}
			}
			break;
		case TargetValueKind::HIT_SET: {
			if (p_value.hits.size() > p_schema.desc.max_hits ||
					p_value.hits.size() > MAX_TARGET_HITS) {
				return make_status(StatusCode::CAPACITY_EXCEEDED,
						DiagnosticId::COUNT_LIMIT_EXCEEDED,
						p_value.hits.size());
			}
			r_canonical.hits.reserve(p_value.hits.size());
			std::set<EntityId> seen_entities;
			for (const TargetHit &hit : p_value.hits) {
				TargetHit canonical;
				status = canonicalize_hit(hit, p_schema.desc, p_source,
						canonical);
				if (!status.ok()) {
					return status;
				}
				if (canonical.has_entity) {
					const bool inserted =
							seen_entities.insert(canonical.entity).second;
					if (!inserted) {
						if (p_schema.desc.duplicate_policy ==
								TargetDuplicatePolicy::REJECT) {
							return make_status(
									StatusCode::INVALID_TARGET_DATA,
									DiagnosticId::TARGET_RULE_REJECTED,
									canonical.entity.value);
						}
						continue;
					}
				}
				r_canonical.hits.push_back(canonical);
			}
			if (p_schema.desc.entity_order ==
					TargetEntityOrder::CANONICAL_BY_ID) {
				std::stable_sort(r_canonical.hits.begin(),
						r_canonical.hits.end(),
						[](const TargetHit &p_a, const TargetHit &p_b) {
							if (p_a.has_entity != p_b.has_entity) {
								return p_a.has_entity;
							}
							if (p_a.entity != p_b.entity) {
								return p_a.entity < p_b.entity;
							}
							return p_a.distance_raw < p_b.distance_raw;
						});
			}
			if ((r_canonical.hits.empty() &&
						!p_schema.desc.allow_empty) ||
					(!r_canonical.hits.empty() &&
							r_canonical.hits.size() <
									p_schema.desc.min_hits)) {
				return make_status(StatusCode::INVALID_TARGET_DATA,
						DiagnosticId::COUNT_LIMIT_EXCEEDED,
						r_canonical.hits.size());
			}
			status = ok_status();
			break;
		}
	}
	if (!status.ok()) {
		return status;
	}
	ByteWriter size_writer(MAX_TARGET_VALUE_BYTES);
	write_value_unchecked(size_writer, r_canonical, p_schema);
	if (!size_writer.ok()) {
		return size_writer.status();
	}
	if (size_writer.size() > p_schema.desc.max_payload_bytes) {
		return make_status(StatusCode::PAYLOAD_TOO_LARGE,
				DiagnosticId::BYTE_LIMIT_EXCEEDED, size_writer.size());
	}
	return ok_status();
}

Status validate_canonical_target_value(const TargetValue &p_value,
		const TargetSchema &p_schema, bool p_for_intent,
		EntityId p_source) {
	TargetValue canonical;
	Status status = normalize_target_value(p_value, p_schema, p_for_intent,
			p_source, canonical);
	if (!status.ok()) {
		return status;
	}
	if (canonical != p_value) {
		return make_status(StatusCode::INVALID_TARGET_DATA,
				DiagnosticId::INVALID_TARGET_COORDINATE);
	}
	return ok_status();
}

Status quantize_target_vector(const std::vector<double> &p_components,
		const TargetSchema &p_schema, bool p_normalize,
		TargetVector &r_vector) {
	const std::size_t dimensions = component_count(p_schema.desc.dimension);
	if (p_components.size() != dimensions) {
		return make_status(StatusCode::INVALID_TARGET_DATA,
				DiagnosticId::INVALID_TARGET_COORDINATE,
				p_components.size());
	}
	TargetVector raw;
	for (std::size_t i = 0; i < dimensions; ++i) {
		const double component = p_components[i];
		if (!std::isfinite(component)) {
			return make_status(StatusCode::INVALID_TARGET_DATA,
					DiagnosticId::VALUE_NOT_REPRESENTABLE, i);
		}
		// Deliberately `double`, not `long double`: `long double` is 80-bit
		// x87 extended precision on some x86 toolchains but nothing more than
		// a plain 64-bit IEEE-754 double on ARM64 and MSVC, so the exact same
		// client-supplied `component` could scale-and-round to different raw
		// integers depending on the build platform -- a determinism break at
		// the Godot adapter boundary even though authority re-normalizes and
		// never trusts this value directly. `double`'s mantissa is exact for
		// every integer up to 2^53 (~9.007e15), comfortably past the schema's
		// largest legal magnitude (`MAX_TARGET_COORDINATE_RAW` == 1e12, see
		// ga_limits.h), so `component * coordinate_scale` and the following
		// round-to-nearest-integer are both exact, bit-identical IEEE-754
		// double operations on every platform this addon targets -- no
		// precision is lost relative to the old long-double path for any
		// value this function ultimately accepts.
		const double scaled = component *
				static_cast<double>(p_schema.desc.coordinate_scale);
		if (scaled < -static_cast<double>(
								p_schema.desc.max_coordinate_raw) ||
				scaled > static_cast<double>(
								p_schema.desc.max_coordinate_raw)) {
			return make_status(StatusCode::INVALID_TARGET_DATA,
					DiagnosticId::VALUE_NOT_REPRESENTABLE, i);
		}
		raw.raw[i] = static_cast<std::int64_t>(std::llround(scaled));
	}
	return canonicalize_vector(raw, p_schema.desc, p_normalize, r_vector);
}

Status write_target_value(ByteWriter &p_writer, const TargetValue &p_value,
		const TargetSchema &p_schema, bool p_for_intent) {
	Status status = validate_canonical_target_value(p_value, p_schema,
			p_for_intent);
	if (!status.ok()) {
		return status;
	}
	write_value_unchecked(p_writer, p_value, p_schema);
	return p_writer.ok() ? ok_status() : p_writer.status();
}

Status read_target_value(ByteReader &p_reader, const TargetSchema &p_schema,
		bool p_for_intent, TargetValue &r_value) {
	std::uint8_t version = 0;
	std::uint8_t raw_kind = 0;
	if (!p_reader.read_u8(version) || version != TARGET_VALUE_VERSION ||
			!p_reader.read_u8(raw_kind) ||
			raw_kind > static_cast<std::uint8_t>(TargetValueKind::HIT_SET)) {
		return make_status(StatusCode::DECODE_FAILED,
				DiagnosticId::INVALID_TARGET_KIND, raw_kind);
	}
	TargetValue decoded;
	decoded.kind = static_cast<TargetValueKind>(raw_kind);
	const TargetValueKind expected = p_for_intent ?
			p_schema.desc.intent_kind : p_schema.desc.result_kind;
	if (decoded.kind != expected) {
		return make_status(StatusCode::INVALID_TARGET_DATA,
				DiagnosticId::INVALID_TARGET_KIND, raw_kind);
	}
	const std::size_t dimensions = component_count(p_schema.desc.dimension);
	switch (decoded.kind) {
		case TargetValueKind::ENTITY_SET: {
			std::size_t count = 0;
			if (!p_reader.read_count(count, p_schema.desc.max_entities, 8)) {
				return p_reader.status();
			}
			decoded.entities.reserve(count);
			for (std::size_t i = 0; i < count; ++i) {
				std::uint64_t entity = 0;
				if (!p_reader.read_u64(entity)) {
					return p_reader.status();
				}
				decoded.entities.push_back(EntityId{ entity });
			}
			break;
		}
		case TargetValueKind::POINT:
			if (!read_vector(p_reader, decoded.point, dimensions)) {
				return p_reader.status();
			}
			break;
		case TargetValueKind::DIRECTION:
			if (!read_vector(p_reader, decoded.direction, dimensions)) {
				return p_reader.status();
			}
			break;
		case TargetValueKind::RAY:
			if (!read_vector(p_reader, decoded.ray.origin, dimensions) ||
					!read_vector(p_reader, decoded.ray.direction,
							dimensions) ||
					!p_reader.read_i64(decoded.ray.length_raw)) {
				return p_reader.status();
			}
			break;
		case TargetValueKind::HIT_SET: {
			std::size_t count = 0;
			if (!p_reader.read_count(count, p_schema.desc.max_hits,
						2 + dimensions * 16 + 8)) {
				return p_reader.status();
			}
			decoded.hits.reserve(count);
			for (std::size_t i = 0; i < count; ++i) {
				TargetHit hit;
				std::uint64_t entity = 0;
				std::uint32_t surface = 0;
				if (!p_reader.read_bool(hit.has_entity) ||
						(hit.has_entity && !p_reader.read_u64(entity)) ||
						!read_vector(p_reader, hit.position, dimensions) ||
						!read_vector(p_reader, hit.normal, dimensions) ||
						!p_reader.read_i64(hit.distance_raw) ||
						!p_reader.read_bool(hit.has_surface_tag) ||
						(hit.has_surface_tag &&
								!p_reader.read_u32(surface))) {
					return p_reader.status();
				}
				hit.entity = EntityId{ entity };
				hit.surface_tag = surface;
				decoded.hits.push_back(hit);
			}
			break;
		}
	}
	Status status = validate_canonical_target_value(decoded, p_schema,
			p_for_intent);
	if (!status.ok()) {
		return status;
	}
	r_value = std::move(decoded);
	return ok_status();
}

Status encode_target_value(const TargetValue &p_value,
		const TargetSchema &p_schema, bool p_for_intent,
		std::vector<std::uint8_t> &r_bytes) {
	ByteWriter writer(std::min<std::size_t>(
			p_schema.desc.max_payload_bytes, MAX_TARGET_VALUE_BYTES));
	Status status = write_target_value(writer, p_value, p_schema,
			p_for_intent);
	if (!status.ok()) {
		return status;
	}
	r_bytes = writer.take();
	return ok_status();
}

Status decode_target_value(const std::vector<std::uint8_t> &p_bytes,
		const TargetSchema &p_schema, bool p_for_intent,
		TargetValue &r_value) {
	if (p_bytes.size() > p_schema.desc.max_payload_bytes ||
			p_bytes.size() > MAX_TARGET_VALUE_BYTES) {
		return make_status(StatusCode::PAYLOAD_TOO_LARGE,
				DiagnosticId::BYTE_LIMIT_EXCEEDED, p_bytes.size());
	}
	ByteReader reader(p_bytes);
	Status status = read_target_value(reader, p_schema, p_for_intent,
			r_value);
	if (!status.ok()) {
		return status;
	}
	if (!reader.at_end()) {
		return make_status(StatusCode::DECODE_FAILED,
				DiagnosticId::INVALID_TARGET_PROVENANCE,
				reader.remaining());
	}
	return ok_status();
}

Status hash_target_value(const TargetValue &p_value,
		const TargetSchema &p_schema, bool p_for_intent,
		std::uint64_t &r_hash) {
	std::vector<std::uint8_t> bytes;
	Status status = encode_target_value(p_value, p_schema, p_for_intent,
			bytes);
	if (!status.ok()) {
		return status;
	}
	r_hash = hash_bytes(bytes);
	return ok_status();
}

Status adapt_legacy_entity_targets(
		const std::vector<EntityId> &p_entities,
		const TargetSchema &p_schema, EntityId p_source,
		TargetValue &r_canonical) {
	if (p_schema.desc.intent_kind != TargetValueKind::ENTITY_SET ||
			p_schema.desc.result_kind != TargetValueKind::ENTITY_SET) {
		return make_status(StatusCode::INVALID_TARGET_DATA,
				DiagnosticId::INVALID_TARGET_SCHEMA,
				p_schema.id);
	}
	TargetValue legacy;
	legacy.kind = TargetValueKind::ENTITY_SET;
	legacy.entities = p_entities;
	return normalize_target_value(legacy, p_schema, true, p_source,
			r_canonical);
}

Status write_target_state_value(SnapshotWriter &p_writer,
		const TargetValue &p_value) {
	if (!valid_kind(p_value.kind)) {
		return make_status(StatusCode::INVALID_TARGET_DATA,
				DiagnosticId::INVALID_TARGET_KIND);
	}
	p_writer.write_u8(TARGET_VALUE_VERSION);
	p_writer.write_u8(static_cast<std::uint8_t>(p_value.kind));
	auto write_all = [&p_writer](const TargetVector &p_vector) {
		for (std::int64_t component : p_vector.raw) {
			p_writer.write_i64(component);
		}
	};
	switch (p_value.kind) {
		case TargetValueKind::ENTITY_SET:
			p_writer.write_count(p_value.entities.size(),
					MAX_TARGETS_PER_COMMAND);
			for (EntityId entity : p_value.entities) {
				if (!entity) {
					return make_status(StatusCode::INVALID_TARGET_DATA,
							DiagnosticId::TARGET_NOT_RELEVANT);
				}
				p_writer.write_u64(entity.value);
			}
			break;
		case TargetValueKind::POINT:
			write_all(p_value.point);
			break;
		case TargetValueKind::DIRECTION:
			write_all(p_value.direction);
			break;
		case TargetValueKind::RAY:
			write_all(p_value.ray.origin);
			write_all(p_value.ray.direction);
			p_writer.write_i64(p_value.ray.length_raw);
			break;
		case TargetValueKind::HIT_SET:
			p_writer.write_count(p_value.hits.size(), MAX_TARGET_HITS);
			for (const TargetHit &hit : p_value.hits) {
				p_writer.write_bool(hit.has_entity);
				if (hit.has_entity) {
					if (!hit.entity) {
						return make_status(
								StatusCode::INVALID_TARGET_DATA,
								DiagnosticId::TARGET_NOT_RELEVANT);
					}
					p_writer.write_u64(hit.entity.value);
				}
				write_all(hit.position);
				write_all(hit.normal);
				p_writer.write_i64(hit.distance_raw);
				p_writer.write_bool(hit.has_surface_tag);
				if (hit.has_surface_tag) {
					p_writer.write_u32(hit.surface_tag);
				}
			}
			break;
	}
	return p_writer.ok() ? ok_status() : p_writer.status();
}

Status read_target_state_value(SnapshotReader &p_reader,
		TargetValue &r_value) {
	std::uint8_t version = 0;
	std::uint8_t kind_raw = 0;
	if (!p_reader.read_u8(version) ||
			version != TARGET_VALUE_VERSION ||
			!p_reader.read_u8(kind_raw) ||
			kind_raw >
					static_cast<std::uint8_t>(
							TargetValueKind::HIT_SET)) {
		return make_status(StatusCode::DECODE_FAILED,
				DiagnosticId::INVALID_TARGET_KIND, kind_raw);
	}
	TargetValue value;
	value.kind = static_cast<TargetValueKind>(kind_raw);
	auto read_all = [&p_reader](TargetVector &r_vector) {
		for (std::int64_t &component : r_vector.raw) {
			if (!p_reader.read_i64(component)) {
				return false;
			}
			if (abs_raw(component) > MAX_TARGET_COORDINATE_RAW) {
				return false;
			}
		}
		return true;
	};
	switch (value.kind) {
		case TargetValueKind::ENTITY_SET: {
			std::size_t count = 0;
			if (!p_reader.read_count(count, MAX_TARGETS_PER_COMMAND)) {
				return p_reader.status();
			}
			value.entities.reserve(count);
			for (std::size_t i = 0; i < count; ++i) {
				std::uint64_t entity = 0;
				if (!p_reader.read_u64(entity) || entity == 0) {
					return make_status(StatusCode::DECODE_FAILED,
							DiagnosticId::TARGET_NOT_RELEVANT);
				}
				value.entities.push_back(EntityId{ entity });
			}
			break;
		}
		case TargetValueKind::POINT:
			if (!read_all(value.point)) {
				return make_status(StatusCode::DECODE_FAILED,
						DiagnosticId::INVALID_TARGET_COORDINATE);
			}
			break;
		case TargetValueKind::DIRECTION:
			if (!read_all(value.direction)) {
				return make_status(StatusCode::DECODE_FAILED,
						DiagnosticId::INVALID_TARGET_COORDINATE);
			}
			break;
		case TargetValueKind::RAY:
			if (!read_all(value.ray.origin) ||
					!read_all(value.ray.direction) ||
					!p_reader.read_i64(value.ray.length_raw) ||
					value.ray.length_raw < 0 ||
					value.ray.length_raw >
							MAX_TARGET_COORDINATE_RAW) {
				return make_status(StatusCode::DECODE_FAILED,
						DiagnosticId::INVALID_TARGET_COORDINATE);
			}
			break;
		case TargetValueKind::HIT_SET: {
			std::size_t count = 0;
			if (!p_reader.read_count(count, MAX_TARGET_HITS)) {
				return p_reader.status();
			}
			value.hits.reserve(count);
			for (std::size_t i = 0; i < count; ++i) {
				TargetHit hit;
				std::uint64_t entity = 0;
				std::uint32_t surface = 0;
				if (!p_reader.read_bool(hit.has_entity) ||
						(hit.has_entity &&
								(!p_reader.read_u64(entity) ||
										entity == 0)) ||
						!read_all(hit.position) ||
						!read_all(hit.normal) ||
						!p_reader.read_i64(hit.distance_raw) ||
						hit.distance_raw < 0 ||
						hit.distance_raw >
								MAX_TARGET_COORDINATE_RAW ||
						!p_reader.read_bool(hit.has_surface_tag) ||
						(hit.has_surface_tag &&
								(!p_reader.read_u32(surface) ||
										surface == 0))) {
					return make_status(StatusCode::DECODE_FAILED,
							DiagnosticId::INVALID_TARGET_COORDINATE);
				}
				hit.entity = EntityId{ entity };
				hit.surface_tag = surface;
				value.hits.push_back(hit);
			}
			break;
		}
	}
	r_value = std::move(value);
	return ok_status();
}

Status validate_target_effect_context(
		const TargetEffectContext &p_context) {
	if (!p_context.present) {
		return ok_status();
	}
	if (p_context.schema == INVALID_DEFINITION_ID ||
			p_context.schema_version == 0 || !p_context.source ||
			!p_context.target ||
			static_cast<std::uint8_t>(p_context.visibility) >
					static_cast<std::uint8_t>(
							TargetResultVisibility::INTERNAL)) {
		return make_status(StatusCode::INVALID_TARGET_DATA,
				DiagnosticId::INVALID_TARGET_PROVENANCE);
	}
	SnapshotWriter writer(MAX_TARGET_VALUE_BYTES * 2 + 256);
	Status status = write_target_state_value(writer,
			p_context.canonical_intent);
	if (!status.ok()) {
		return status;
	}
	status = write_target_state_value(writer,
			p_context.validated_result);
	if (!status.ok()) {
		return status;
	}
	return writer.size() <= MAX_TARGET_VALUE_BYTES * 2 + 256 ?
			ok_status() :
			make_status(StatusCode::PAYLOAD_TOO_LARGE,
					DiagnosticId::BYTE_LIMIT_EXCEEDED,
					writer.size());
}

Status write_target_effect_context(SnapshotWriter &p_writer,
		const TargetEffectContext &p_context) {
	Status status = validate_target_effect_context(p_context);
	if (!status.ok()) {
		return status;
	}
	p_writer.write_bool(p_context.present);
	if (!p_context.present) {
		return p_writer.ok() ? ok_status() : p_writer.status();
	}
	p_writer.write_u32(p_context.schema);
	p_writer.write_u16(p_context.schema_version);
	p_writer.write_u64(p_context.source.value);
	p_writer.write_u64(p_context.target.value);
	p_writer.write_u32(p_context.ability);
	p_writer.write_u64(p_context.execution.value);
	p_writer.write_u64(p_context.session.value);
	p_writer.write_u64(p_context.authority_tick);
	p_writer.write_u16(p_context.target_rank);
	p_writer.write_bool(p_context.accepted);
	p_writer.write_u16(
			static_cast<std::uint16_t>(p_context.target_status.code));
	p_writer.write_u16(static_cast<std::uint16_t>(
			p_context.target_status.diagnostic));
	p_writer.write_u64(p_context.target_status.detail);
	p_writer.write_u8(
			static_cast<std::uint8_t>(p_context.visibility));
	status = write_target_state_value(p_writer,
			p_context.canonical_intent);
	if (!status.ok()) {
		return status;
	}
	return write_target_state_value(p_writer,
			p_context.validated_result);
}

Status measure_target_effect_context_bytes(
		const TargetEffectContext &p_context, std::size_t &r_bytes) {
	r_bytes = 0;
	// A generous, non-truncating limit: the largest a valid context can
	// legally encode is bounded by `validate_target_effect_context`'s own
	// combined-size check (`MAX_TARGET_VALUE_BYTES * 2 + 256`), plus a small
	// fixed header -- this stays comfortably above that so measurement
	// itself never fails closed for a reason unrelated to `p_context`'s own
	// validity.
	SnapshotWriter probe(MAX_TARGET_VALUE_BYTES * 4);
	const Status status = write_target_effect_context(probe, p_context);
	if (!status.ok()) {
		return status;
	}
	r_bytes = probe.size();
	return ok_status();
}

Status read_target_effect_context(SnapshotReader &p_reader,
		TargetEffectContext &r_context) {
	bool present = false;
	if (!p_reader.read_bool(present)) {
		return p_reader.status();
	}
	TargetEffectContext context;
	context.present = present;
	if (!present) {
		r_context = context;
		return ok_status();
	}
	std::uint32_t schema = 0;
	std::uint64_t source = 0;
	std::uint64_t target = 0;
	std::uint32_t ability = 0;
	std::uint64_t execution = 0;
	std::uint64_t session = 0;
	std::uint16_t status_code = 0;
	std::uint16_t diagnostic = 0;
	std::uint8_t visibility = 0;
	if (!p_reader.read_u32(schema) ||
			!p_reader.read_u16(context.schema_version) ||
			!p_reader.read_u64(source) ||
			!p_reader.read_u64(target) ||
			!p_reader.read_u32(ability) ||
			!p_reader.read_u64(execution) ||
			!p_reader.read_u64(session) ||
			!p_reader.read_u64(context.authority_tick) ||
			!p_reader.read_u16(context.target_rank) ||
			!p_reader.read_bool(context.accepted) ||
			!p_reader.read_u16(status_code) ||
			!p_reader.read_u16(diagnostic) ||
			!p_reader.read_u64(context.target_status.detail) ||
			!p_reader.read_u8(visibility) ||
			!is_known_status_code(status_code) ||
			!is_known_diagnostic_id(diagnostic) ||
			visibility >
					static_cast<std::uint8_t>(
							TargetResultVisibility::INTERNAL)) {
		return make_status(StatusCode::DECODE_FAILED,
				DiagnosticId::INVALID_TARGET_PROVENANCE);
	}
	context.schema = schema;
	context.source = EntityId{ source };
	context.target = EntityId{ target };
	context.ability = ability;
	context.execution = ExecutionId{ execution };
	context.session = TargetSessionId{ session };
	context.target_status.code =
			static_cast<StatusCode>(status_code);
	context.target_status.diagnostic =
			static_cast<DiagnosticId>(diagnostic);
	context.visibility =
			static_cast<TargetResultVisibility>(visibility);
	Status status = read_target_state_value(p_reader,
			context.canonical_intent);
	if (!status.ok()) {
		return status;
	}
	status = read_target_state_value(p_reader,
			context.validated_result);
	if (!status.ok()) {
		return status;
	}
	status = validate_target_effect_context(context);
	if (!status.ok()) {
		return status;
	}
	r_context = std::move(context);
	return ok_status();
}

TargetEffectContext sanitize_target_effect_context(
		const TargetEffectContext &p_context,
		TargetResultVisibility p_audience) {
	if (!p_context.present) {
		return p_context;
	}
	const bool visible =
			p_audience == TargetResultVisibility::INTERNAL ||
			(p_audience == TargetResultVisibility::OWNER_ONLY &&
					p_context.visibility !=
							TargetResultVisibility::INTERNAL) ||
			(p_audience == TargetResultVisibility::OBSERVABLE &&
					p_context.visibility ==
							TargetResultVisibility::OBSERVABLE);
	if (visible) {
		return p_context;
	}
	TargetEffectContext sanitized;
	sanitized.present = true;
	sanitized.schema = p_context.schema;
	sanitized.schema_version = p_context.schema_version;
	sanitized.source = p_context.source;
	sanitized.target = p_context.target;
	sanitized.ability = p_context.ability;
	sanitized.execution = p_context.execution;
	sanitized.session = p_context.session;
	sanitized.authority_tick = p_context.authority_tick;
	sanitized.target_rank = p_context.target_rank;
	sanitized.accepted = p_context.accepted;
	sanitized.target_status = p_context.target_status;
	sanitized.visibility = p_context.visibility;
	// Intentionally empty values: no hidden positions, candidate entities,
	// surface tags, or rejected identities cross the audience boundary.
	sanitized.canonical_intent.kind =
			p_context.canonical_intent.kind;
	sanitized.validated_result.kind =
			p_context.validated_result.kind;
	return sanitized;
}

} // namespace ga
