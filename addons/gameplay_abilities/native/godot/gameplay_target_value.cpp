#include "godot/gameplay_target_value.h"

#include "godot/gameplay_ability_world_coordinator.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/array.hpp>

#include <cmath>
#include <limits>

namespace godot {

namespace {

std::vector<double> components(const Vector2 &p_value) {
	return { p_value.x, p_value.y };
}

std::vector<double> components(const Vector3 &p_value) {
	return { p_value.x, p_value.y, p_value.z };
}

Array raw_vector_array(const ga::TargetVector &p_value) {
	Array result;
	result.append(p_value.raw[0]);
	result.append(p_value.raw[1]);
	result.append(p_value.raw[2]);
	return result;
}

Array double_vector_array(const std::vector<double> &p_value) {
	Array result;
	for (double component : p_value) {
		result.append(component);
	}
	return result;
}

Dictionary status_dictionary(const ga::Status &p_status) {
	Dictionary result;
	result["code"] = static_cast<int>(p_status.code);
	result["diagnostic"] = static_cast<int>(p_status.diagnostic);
	result["detail"] = static_cast<int64_t>(p_status.detail);
	return result;
}

ga::Status quantize_nonnegative_scalar(double p_value,
		const ga::TargetSchema &p_schema, std::int64_t &r_raw) {
	if (!std::isfinite(p_value) || p_value < 0.0) {
		return ga::make_status(ga::StatusCode::INVALID_TARGET_DATA,
				ga::DiagnosticId::INVALID_TARGET_COORDINATE);
	}
	const long double scaled =
			static_cast<long double>(p_value) *
			static_cast<long double>(
					p_schema.desc.coordinate_scale);
	if (scaled >
					static_cast<long double>(
							std::numeric_limits<std::int64_t>::max()) ||
			scaled >
					static_cast<long double>(
							p_schema.desc.max_coordinate_raw)) {
		return ga::make_status(ga::StatusCode::INVALID_TARGET_DATA,
				ga::DiagnosticId::INVALID_TARGET_COORDINATE);
	}
	r_raw = static_cast<std::int64_t>(std::llround(scaled));
	return ga::ok_status();
}

double dequantize(std::int64_t p_raw, std::int64_t p_scale) {
	if (p_scale <= 0) {
		return 0.0;
	}
	return static_cast<double>(p_raw) /
			static_cast<double>(p_scale);
}

Vector2 vector_2d(const ga::TargetVector &p_value,
		std::int64_t p_scale) {
	return Vector2(dequantize(p_value.raw[0], p_scale),
			dequantize(p_value.raw[1], p_scale));
}

Vector3 vector_3d(const ga::TargetVector &p_value,
		std::int64_t p_scale) {
	return Vector3(dequantize(p_value.raw[0], p_scale),
			dequantize(p_value.raw[1], p_scale),
			dequantize(p_value.raw[2], p_scale));
}

} // namespace

Ref<GameplayTargetHit> GameplayTargetHit::hit_2d(
		const Vector2 &p_position, const Vector2 &p_normal,
		double p_distance, int64_t p_entity,
		int64_t p_surface_tag_id) {
	Ref<GameplayTargetHit> result;
	result.instantiate();
	result->dimension = 2;
	result->position = components(p_position);
	result->normal = components(p_normal);
	result->distance = p_distance;
	result->entity = p_entity;
	result->surface_tag_id = p_surface_tag_id;
	return result;
}

Ref<GameplayTargetHit> GameplayTargetHit::hit_3d(
		const Vector3 &p_position, const Vector3 &p_normal,
		double p_distance, int64_t p_entity,
		int64_t p_surface_tag_id) {
	Ref<GameplayTargetHit> result;
	result.instantiate();
	result->dimension = 3;
	result->position = components(p_position);
	result->normal = components(p_normal);
	result->distance = p_distance;
	result->entity = p_entity;
	result->surface_tag_id = p_surface_tag_id;
	return result;
}

Vector2 GameplayTargetHit::get_position_2d() const {
	return position.size() == 2 ?
			Vector2(position[0], position[1]) :
			Vector2();
}

Vector3 GameplayTargetHit::get_position_3d() const {
	return position.size() == 3 ?
			Vector3(position[0], position[1], position[2]) :
			Vector3();
}

Vector2 GameplayTargetHit::get_normal_2d() const {
	return normal.size() == 2 ?
			Vector2(normal[0], normal[1]) :
			Vector2();
}

Vector3 GameplayTargetHit::get_normal_3d() const {
	return normal.size() == 3 ?
			Vector3(normal[0], normal[1], normal[2]) :
			Vector3();
}

Dictionary GameplayTargetHit::to_dictionary() const {
	Dictionary result;
	result["dimension"] = dimension;
	result["entity"] = entity;
	result["position"] = double_vector_array(position);
	result["normal"] = double_vector_array(normal);
	result["distance"] = distance;
	result["surface_tag_id"] = surface_tag_id;
	return result;
}

void GameplayTargetHit::_bind_methods() {
	ClassDB::bind_static_method("GameplayTargetHit",
			D_METHOD("hit_2d", "position", "normal", "distance",
					"entity", "surface_tag_id"),
			&GameplayTargetHit::hit_2d, DEFVAL(0), DEFVAL(0));
	ClassDB::bind_static_method("GameplayTargetHit",
			D_METHOD("hit_3d", "position", "normal", "distance",
					"entity", "surface_tag_id"),
			&GameplayTargetHit::hit_3d, DEFVAL(0), DEFVAL(0));
	ClassDB::bind_method(D_METHOD("get_dimension"),
			&GameplayTargetHit::get_dimension);
	ClassDB::bind_method(D_METHOD("has_entity"),
			&GameplayTargetHit::has_entity);
	ClassDB::bind_method(D_METHOD("get_entity"),
			&GameplayTargetHit::get_entity);
	ClassDB::bind_method(D_METHOD("get_position_2d"),
			&GameplayTargetHit::get_position_2d);
	ClassDB::bind_method(D_METHOD("get_position_3d"),
			&GameplayTargetHit::get_position_3d);
	ClassDB::bind_method(D_METHOD("get_normal_2d"),
			&GameplayTargetHit::get_normal_2d);
	ClassDB::bind_method(D_METHOD("get_normal_3d"),
			&GameplayTargetHit::get_normal_3d);
	ClassDB::bind_method(D_METHOD("get_distance"),
			&GameplayTargetHit::get_distance);
	ClassDB::bind_method(D_METHOD("has_surface_tag"),
			&GameplayTargetHit::has_surface_tag);
	ClassDB::bind_method(D_METHOD("get_surface_tag_id"),
			&GameplayTargetHit::get_surface_tag_id);
	ClassDB::bind_method(D_METHOD("to_dictionary"),
			&GameplayTargetHit::to_dictionary);
}

Ref<GameplayTargetValue> GameplayTargetValue::entity_set(
		const PackedInt64Array &p_entities) {
	Ref<GameplayTargetValue> result;
	result.instantiate();
	result->kind = ga::TargetValueKind::ENTITY_SET;
	result->entities.reserve(p_entities.size());
	for (int64_t entity : p_entities) {
		result->entities.push_back(entity > 0 ?
						ga::EntityId{
							static_cast<std::uint64_t>(entity) } :
						ga::INVALID_ENTITY_ID);
	}
	return result;
}

Ref<GameplayTargetValue> GameplayTargetValue::point_2d(
		const Vector2 &p_point) {
	Ref<GameplayTargetValue> result;
	result.instantiate();
	result->kind = ga::TargetValueKind::POINT;
	result->dimension = 2;
	result->first = components(p_point);
	return result;
}

Ref<GameplayTargetValue> GameplayTargetValue::point_3d(
		const Vector3 &p_point) {
	Ref<GameplayTargetValue> result;
	result.instantiate();
	result->kind = ga::TargetValueKind::POINT;
	result->dimension = 3;
	result->first = components(p_point);
	return result;
}

Ref<GameplayTargetValue> GameplayTargetValue::direction_2d(
		const Vector2 &p_direction) {
	Ref<GameplayTargetValue> result;
	result.instantiate();
	result->kind = ga::TargetValueKind::DIRECTION;
	result->dimension = 2;
	result->first = components(p_direction);
	return result;
}

Ref<GameplayTargetValue> GameplayTargetValue::direction_3d(
		const Vector3 &p_direction) {
	Ref<GameplayTargetValue> result;
	result.instantiate();
	result->kind = ga::TargetValueKind::DIRECTION;
	result->dimension = 3;
	result->first = components(p_direction);
	return result;
}

Ref<GameplayTargetValue> GameplayTargetValue::ray_2d(
		const Vector2 &p_origin, const Vector2 &p_direction,
		double p_length) {
	Ref<GameplayTargetValue> result;
	result.instantiate();
	result->kind = ga::TargetValueKind::RAY;
	result->dimension = 2;
	result->first = components(p_origin);
	result->second = components(p_direction);
	result->scalar = p_length;
	return result;
}

Ref<GameplayTargetValue> GameplayTargetValue::ray_3d(
		const Vector3 &p_origin, const Vector3 &p_direction,
		double p_length) {
	Ref<GameplayTargetValue> result;
	result.instantiate();
	result->kind = ga::TargetValueKind::RAY;
	result->dimension = 3;
	result->first = components(p_origin);
	result->second = components(p_direction);
	result->scalar = p_length;
	return result;
}

Ref<GameplayTargetValue> GameplayTargetValue::hit_set(
		const TypedArray<GameplayTargetHit> &p_hits) {
	Ref<GameplayTargetValue> result;
	result.instantiate();
	result->kind = ga::TargetValueKind::HIT_SET;
	for (int i = 0; i < p_hits.size(); ++i) {
		const Ref<GameplayTargetHit> hit = p_hits[i];
		if (hit.is_null()) {
			result->dimension = -1;
			continue;
		}
		if (result->dimension == 0) {
			result->dimension = hit->dimension;
		} else if (result->dimension != hit->dimension) {
			result->dimension = -1;
		}
		result->hits.push_back(hit);
	}
	return result;
}

PackedInt64Array GameplayTargetValue::get_entities() const {
	PackedInt64Array result;
	const std::vector<ga::EntityId> *source = &entities;
	if (canonical &&
			canonical_value.kind == ga::TargetValueKind::ENTITY_SET) {
		source = &canonical_value.entities;
	}
	for (ga::EntityId entity : *source) {
		result.append(static_cast<int64_t>(entity.value));
	}
	return result;
}

Vector2 GameplayTargetValue::get_point_2d() const {
	if (kind != ga::TargetValueKind::POINT || dimension != 2) {
		return Vector2();
	}
	return canonical ? vector_2d(canonical_value.point, canonical_scale) :
					   Vector2(first[0], first[1]);
}

Vector3 GameplayTargetValue::get_point_3d() const {
	if (kind != ga::TargetValueKind::POINT || dimension != 3) {
		return Vector3();
	}
	return canonical ? vector_3d(canonical_value.point, canonical_scale) :
					   Vector3(first[0], first[1], first[2]);
}

Vector2 GameplayTargetValue::get_direction_2d() const {
	if (kind != ga::TargetValueKind::DIRECTION || dimension != 2) {
		return Vector2();
	}
	return canonical ?
			vector_2d(canonical_value.direction, canonical_scale) :
			Vector2(first[0], first[1]);
}

Vector3 GameplayTargetValue::get_direction_3d() const {
	if (kind != ga::TargetValueKind::DIRECTION || dimension != 3) {
		return Vector3();
	}
	return canonical ?
			vector_3d(canonical_value.direction, canonical_scale) :
			Vector3(first[0], first[1], first[2]);
}

Vector2 GameplayTargetValue::get_ray_origin_2d() const {
	if (kind != ga::TargetValueKind::RAY || dimension != 2) {
		return Vector2();
	}
	return canonical ?
			vector_2d(canonical_value.ray.origin, canonical_scale) :
			Vector2(first[0], first[1]);
}

Vector3 GameplayTargetValue::get_ray_origin_3d() const {
	if (kind != ga::TargetValueKind::RAY || dimension != 3) {
		return Vector3();
	}
	return canonical ?
			vector_3d(canonical_value.ray.origin, canonical_scale) :
			Vector3(first[0], first[1], first[2]);
}

Vector2 GameplayTargetValue::get_ray_direction_2d() const {
	if (kind != ga::TargetValueKind::RAY || dimension != 2) {
		return Vector2();
	}
	return canonical ?
			vector_2d(canonical_value.ray.direction, canonical_scale) :
			Vector2(second[0], second[1]);
}

Vector3 GameplayTargetValue::get_ray_direction_3d() const {
	if (kind != ga::TargetValueKind::RAY || dimension != 3) {
		return Vector3();
	}
	return canonical ?
			vector_3d(canonical_value.ray.direction, canonical_scale) :
			Vector3(second[0], second[1], second[2]);
}

double GameplayTargetValue::get_ray_length() const {
	if (kind != ga::TargetValueKind::RAY) {
		return 0.0;
	}
	return canonical ?
			dequantize(canonical_value.ray.length_raw, canonical_scale) :
			scalar;
}

TypedArray<GameplayTargetHit> GameplayTargetValue::get_hits() const {
	TypedArray<GameplayTargetHit> result;
	if (kind != ga::TargetValueKind::HIT_SET) {
		return result;
	}
	if (!canonical) {
		for (const Ref<GameplayTargetHit> &hit : hits) {
			result.append(hit);
		}
		return result;
	}
	for (const ga::TargetHit &hit : canonical_value.hits) {
		const int64_t entity = hit.has_entity ?
				static_cast<int64_t>(hit.entity.value) :
				0;
		const int64_t surface = hit.has_surface_tag ?
				static_cast<int64_t>(hit.surface_tag) :
				0;
		if (dimension == 2) {
			result.append(GameplayTargetHit::hit_2d(
					vector_2d(hit.position, canonical_scale),
					vector_2d(hit.normal, canonical_scale),
					dequantize(hit.distance_raw, canonical_scale),
					entity, surface));
		} else if (dimension == 3) {
			result.append(GameplayTargetHit::hit_3d(
					vector_3d(hit.position, canonical_scale),
					vector_3d(hit.normal, canonical_scale),
					dequantize(hit.distance_raw, canonical_scale),
					entity, surface));
		}
	}
	return result;
}

Dictionary GameplayTargetValue::to_dictionary() const {
	Dictionary result;
	result["kind"] = static_cast<int>(kind);
	result["dimension"] = dimension;
	result["canonical"] = canonical;
	if (!canonical) {
		if (kind == ga::TargetValueKind::ENTITY_SET) {
			result["entities"] = get_entities();
		} else {
			result["first"] = double_vector_array(first);
			result["second"] = double_vector_array(second);
			result["scalar"] = scalar;
			Array hit_values;
			for (const Ref<GameplayTargetHit> &hit : hits) {
				hit_values.append(hit.is_valid() ?
								hit->to_dictionary() :
								Dictionary());
			}
			result["hits"] = hit_values;
		}
		return result;
	}

	switch (canonical_value.kind) {
		case ga::TargetValueKind::ENTITY_SET:
			result["entities"] = get_entities();
			break;
		case ga::TargetValueKind::POINT:
			result["point_raw"] =
					raw_vector_array(canonical_value.point);
			break;
		case ga::TargetValueKind::DIRECTION:
			result["direction_raw"] =
					raw_vector_array(canonical_value.direction);
			break;
		case ga::TargetValueKind::RAY:
			result["origin_raw"] =
					raw_vector_array(canonical_value.ray.origin);
			result["direction_raw"] =
					raw_vector_array(canonical_value.ray.direction);
			result["length_raw"] =
					canonical_value.ray.length_raw;
			break;
		case ga::TargetValueKind::HIT_SET: {
			Array hit_values;
			for (const ga::TargetHit &hit : canonical_value.hits) {
				Dictionary entry;
				entry["entity"] = hit.has_entity ?
						static_cast<int64_t>(hit.entity.value) : 0;
				entry["position_raw"] =
						raw_vector_array(hit.position);
				entry["normal_raw"] =
						raw_vector_array(hit.normal);
				entry["distance_raw"] = hit.distance_raw;
				entry["surface_tag_id"] = hit.has_surface_tag ?
						static_cast<int64_t>(hit.surface_tag) : 0;
				hit_values.append(entry);
			}
			result["hits"] = hit_values;
			break;
		}
	}
	return result;
}

ga::Status GameplayTargetValue::to_core(
		const ga::TargetSchema &p_schema, bool p_for_intent,
		ga::EntityId p_source, ga::TargetValue &r_value) const {
	if (canonical) {
		return ga::normalize_target_value(canonical_value, p_schema,
				p_for_intent, p_source, r_value);
	}
	const ga::TargetValueKind expected = p_for_intent ?
			p_schema.desc.intent_kind : p_schema.desc.result_kind;
	if (kind != expected) {
		return ga::make_status(ga::StatusCode::INVALID_TARGET_DATA,
				ga::DiagnosticId::INVALID_TARGET_KIND,
				static_cast<std::uint64_t>(kind));
	}
	const int expected_dimension =
			static_cast<int>(p_schema.desc.dimension);
	if (kind != ga::TargetValueKind::ENTITY_SET &&
			dimension != 0 && dimension != expected_dimension) {
		return ga::make_status(ga::StatusCode::INVALID_TARGET_DATA,
				ga::DiagnosticId::INVALID_TARGET_COORDINATE,
				dimension);
	}

	ga::TargetValue local;
	local.kind = kind;
	ga::Status status = ga::ok_status();
	switch (kind) {
		case ga::TargetValueKind::ENTITY_SET:
			local.entities = entities;
			break;
		case ga::TargetValueKind::POINT:
			status = ga::quantize_target_vector(first, p_schema, false,
					local.point);
			break;
		case ga::TargetValueKind::DIRECTION:
			status = ga::quantize_target_vector(first, p_schema, true,
					local.direction);
			break;
		case ga::TargetValueKind::RAY:
			status = ga::quantize_target_vector(first, p_schema, false,
					local.ray.origin);
			if (status.ok()) {
				status = ga::quantize_target_vector(second, p_schema,
						true, local.ray.direction);
			}
			if (status.ok()) {
				status = quantize_nonnegative_scalar(scalar, p_schema,
						local.ray.length_raw);
			}
			break;
		case ga::TargetValueKind::HIT_SET:
			if (hits.size() > ga::MAX_TARGET_HITS) {
				status = ga::make_status(
						ga::StatusCode::CAPACITY_EXCEEDED,
						ga::DiagnosticId::COUNT_LIMIT_EXCEEDED,
						hits.size());
				break;
			}
			for (const Ref<GameplayTargetHit> &input : hits) {
				if (input.is_null() ||
						input->dimension != expected_dimension) {
					status = ga::make_status(
							ga::StatusCode::INVALID_TARGET_DATA,
							ga::DiagnosticId::
									INVALID_TARGET_COORDINATE);
					break;
				}
				ga::TargetHit hit;
				hit.has_entity = input->entity > 0;
				hit.entity = hit.has_entity ?
						ga::EntityId{ static_cast<std::uint64_t>(
								input->entity) } :
						ga::INVALID_ENTITY_ID;
				hit.has_surface_tag = input->surface_tag_id > 0;
				if (hit.has_surface_tag &&
						static_cast<std::uint64_t>(
								input->surface_tag_id) >
								std::numeric_limits<
										ga::DefinitionId>::max()) {
					status = ga::make_status(
							ga::StatusCode::INVALID_TARGET_DATA,
							ga::DiagnosticId::
									DEFINITION_UNKNOWN_REFERENCE);
					break;
				}
				hit.surface_tag = hit.has_surface_tag ?
						static_cast<ga::DefinitionId>(
								input->surface_tag_id) :
						ga::INVALID_DEFINITION_ID;
				status = ga::quantize_target_vector(input->position,
						p_schema, false, hit.position);
				if (status.ok()) {
					status = ga::quantize_target_vector(input->normal,
							p_schema, true, hit.normal);
				}
				if (status.ok()) {
					status = quantize_nonnegative_scalar(
							input->distance, p_schema,
							hit.distance_raw);
				}
				if (!status.ok()) {
					break;
				}
				local.hits.push_back(hit);
			}
			break;
	}
	if (!status.ok()) {
		return status;
	}
	return ga::normalize_target_value(local, p_schema, p_for_intent,
			p_source, r_value);
}

Ref<GameplayTargetValue> GameplayTargetValue::from_core(
		const ga::TargetValue &p_value, int64_t p_coordinate_scale,
		int p_dimension) {
	Ref<GameplayTargetValue> result;
	result.instantiate();
	result->kind = p_value.kind;
	result->dimension = p_dimension;
	result->canonical = true;
	result->canonical_scale =
			std::max<int64_t>(1, p_coordinate_scale);
	result->canonical_value = p_value;
	return result;
}

void GameplayTargetValue::_bind_methods() {
	ClassDB::bind_static_method("GameplayTargetValue",
			D_METHOD("entity_set", "entities"),
			&GameplayTargetValue::entity_set);
	ClassDB::bind_static_method("GameplayTargetValue",
			D_METHOD("point_2d", "point"),
			&GameplayTargetValue::point_2d);
	ClassDB::bind_static_method("GameplayTargetValue",
			D_METHOD("point_3d", "point"),
			&GameplayTargetValue::point_3d);
	ClassDB::bind_static_method("GameplayTargetValue",
			D_METHOD("direction_2d", "direction"),
			&GameplayTargetValue::direction_2d);
	ClassDB::bind_static_method("GameplayTargetValue",
			D_METHOD("direction_3d", "direction"),
			&GameplayTargetValue::direction_3d);
	ClassDB::bind_static_method("GameplayTargetValue",
			D_METHOD("ray_2d", "origin", "direction", "length"),
			&GameplayTargetValue::ray_2d);
	ClassDB::bind_static_method("GameplayTargetValue",
			D_METHOD("ray_3d", "origin", "direction", "length"),
			&GameplayTargetValue::ray_3d);
	ClassDB::bind_static_method("GameplayTargetValue",
			D_METHOD("hit_set", "hits"),
			&GameplayTargetValue::hit_set);
	ClassDB::bind_method(D_METHOD("get_kind"),
			&GameplayTargetValue::get_kind);
	ClassDB::bind_method(D_METHOD("get_dimension"),
			&GameplayTargetValue::get_dimension);
	ClassDB::bind_method(D_METHOD("is_canonical"),
			&GameplayTargetValue::is_canonical);
	ClassDB::bind_method(D_METHOD("get_entities"),
			&GameplayTargetValue::get_entities);
	ClassDB::bind_method(D_METHOD("get_point_2d"),
			&GameplayTargetValue::get_point_2d);
	ClassDB::bind_method(D_METHOD("get_point_3d"),
			&GameplayTargetValue::get_point_3d);
	ClassDB::bind_method(D_METHOD("get_direction_2d"),
			&GameplayTargetValue::get_direction_2d);
	ClassDB::bind_method(D_METHOD("get_direction_3d"),
			&GameplayTargetValue::get_direction_3d);
	ClassDB::bind_method(D_METHOD("get_ray_origin_2d"),
			&GameplayTargetValue::get_ray_origin_2d);
	ClassDB::bind_method(D_METHOD("get_ray_origin_3d"),
			&GameplayTargetValue::get_ray_origin_3d);
	ClassDB::bind_method(D_METHOD("get_ray_direction_2d"),
			&GameplayTargetValue::get_ray_direction_2d);
	ClassDB::bind_method(D_METHOD("get_ray_direction_3d"),
			&GameplayTargetValue::get_ray_direction_3d);
	ClassDB::bind_method(D_METHOD("get_ray_length"),
			&GameplayTargetValue::get_ray_length);
	ClassDB::bind_method(D_METHOD("get_hits"),
			&GameplayTargetValue::get_hits);
	ClassDB::bind_method(D_METHOD("to_dictionary"),
			&GameplayTargetValue::to_dictionary);
}

Ref<GameplayTargetValue>
GameplayValidatedTargetData::get_canonical_intent() const {
	const ga::TargetSchema *schema = owner != nullptr ?
			owner->target_schema_registry().find(data.schema()) :
			nullptr;
	return GameplayTargetValue::from_core(
			data.canonical_intent().value,
			schema != nullptr ? schema->desc.coordinate_scale : 1000000,
			schema != nullptr ?
					static_cast<int>(schema->desc.dimension) :
					0);
}

Ref<GameplayTargetValue> GameplayValidatedTargetData::get_result() const {
	const ga::TargetSchema *schema = owner != nullptr ?
			owner->target_schema_registry().find(data.schema()) :
			nullptr;
	return GameplayTargetValue::from_core(data.result(),
			schema != nullptr ? schema->desc.coordinate_scale : 1000000,
			schema != nullptr ?
					static_cast<int>(schema->desc.dimension) :
					0);
}

Array GameplayValidatedTargetData::get_provider_outcomes() const {
	Array result;
	for (const ga::TargetEntityOutcome &outcome :
			data.provider_outcomes()) {
		Dictionary entry;
		entry["entity"] = static_cast<int64_t>(outcome.entity.value);
		entry["rank"] = static_cast<int>(outcome.rank);
		entry["kind"] = static_cast<int>(outcome.kind);
		entry["status"] = status_dictionary(outcome.status);
		result.append(entry);
	}
	return result;
}

void GameplayValidatedTargetData::_bind_methods() {
	ClassDB::bind_method(D_METHOD("is_valid"),
			&GameplayValidatedTargetData::is_valid);
	ClassDB::bind_method(D_METHOD("get_source"),
			&GameplayValidatedTargetData::get_source);
	ClassDB::bind_method(D_METHOD("get_execution"),
			&GameplayValidatedTargetData::get_execution);
	ClassDB::bind_method(D_METHOD("get_session"),
			&GameplayValidatedTargetData::get_session);
	ClassDB::bind_method(D_METHOD("get_schema_id"),
			&GameplayValidatedTargetData::get_schema_id);
	ClassDB::bind_method(D_METHOD("get_schema_version"),
			&GameplayValidatedTargetData::get_schema_version);
	ClassDB::bind_method(D_METHOD("get_authority_tick"),
			&GameplayValidatedTargetData::get_authority_tick);
	ClassDB::bind_method(D_METHOD("get_canonical_intent"),
			&GameplayValidatedTargetData::get_canonical_intent);
	ClassDB::bind_method(D_METHOD("get_result"),
			&GameplayValidatedTargetData::get_result);
	ClassDB::bind_method(D_METHOD("get_provider_outcomes"),
			&GameplayValidatedTargetData::get_provider_outcomes);
}

} // namespace godot
