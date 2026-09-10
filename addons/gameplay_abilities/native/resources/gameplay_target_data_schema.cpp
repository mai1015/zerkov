#include "resources/gameplay_target_data_schema.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/char_string.hpp>

#include <string>

namespace godot {

namespace {

std::string to_std(const String &p_value) {
	const CharString bytes = p_value.utf8();
	return std::string(bytes.get_data());
}

bool spatial_kind(GameplayTargetDataSchema::ValueKind p_kind) {
	return p_kind == GameplayTargetDataSchema::VALUE_POINT ||
			p_kind == GameplayTargetDataSchema::VALUE_DIRECTION ||
			p_kind == GameplayTargetDataSchema::VALUE_RAY ||
			p_kind == GameplayTargetDataSchema::VALUE_HIT_SET;
}

std::uint16_t to_u16_saturated(int p_value) {
	if (p_value <= 0) {
		return 0;
	}
	if (p_value >= 65535) {
		return 65535;
	}
	return static_cast<std::uint16_t>(p_value);
}

} // namespace

#define GA_SCHEMA_SETTER(m_name, m_type, m_field) \
	void GameplayTargetDataSchema::m_name(m_type p_value) { \
		m_field = p_value; \
		emit_changed(); \
		notify_property_list_changed(); \
	}

GA_SCHEMA_SETTER(set_intent_kind, ValueKind, intent_kind)
GA_SCHEMA_SETTER(set_result_kind, ValueKind, result_kind)
GA_SCHEMA_SETTER(set_spatial_dimension, SpatialDimension,
		spatial_dimension)
GA_SCHEMA_SETTER(set_entity_order, EntityOrder, entity_order)
GA_SCHEMA_SETTER(set_duplicate_policy, DuplicatePolicy,
		duplicate_policy)
GA_SCHEMA_SETTER(set_allow_self, bool, allow_self)
GA_SCHEMA_SETTER(set_allow_empty, bool, allow_empty)
GA_SCHEMA_SETTER(set_session_mode, SessionMode, session_mode)
GA_SCHEMA_SETTER(set_acceptance_policy, AcceptancePolicy,
		acceptance_policy)
GA_SCHEMA_SETTER(set_result_visibility, ResultVisibility,
		result_visibility)
GA_SCHEMA_SETTER(set_preview_allowed, bool, preview_allowed)
GA_SCHEMA_SETTER(set_prediction_policy, PredictionPolicy,
		prediction_policy)

#undef GA_SCHEMA_SETTER

void GameplayTargetDataSchema::set_identifier(
		const StringName &p_identifier) {
	identifier = p_identifier;
	emit_changed();
}

void GameplayTargetDataSchema::set_schema_version(int p_version) {
	schema_version = p_version < 1 ? 1 : p_version;
	emit_changed();
}

void GameplayTargetDataSchema::set_coordinate_space(
		const StringName &p_space) {
	coordinate_space = p_space;
	emit_changed();
}

void GameplayTargetDataSchema::set_coordinate_scale(int64_t p_scale) {
	coordinate_scale = p_scale < 1 ? 1 : p_scale;
	emit_changed();
}

void GameplayTargetDataSchema::set_precision_raw(int64_t p_precision) {
	precision_raw = p_precision < 1 ? 1 : p_precision;
	emit_changed();
}

void GameplayTargetDataSchema::set_max_coordinate_raw(int64_t p_max) {
	max_coordinate_raw = p_max < 1 ? 1 : p_max;
	emit_changed();
}

void GameplayTargetDataSchema::set_min_entities(int p_count) {
	min_entities = p_count < 0 ? 0 : p_count;
	emit_changed();
}

void GameplayTargetDataSchema::set_max_entities(int p_count) {
	max_entities = p_count < 0 ? 0 : p_count;
	emit_changed();
}

void GameplayTargetDataSchema::set_min_hits(int p_count) {
	min_hits = p_count < 0 ? 0 : p_count;
	emit_changed();
}

void GameplayTargetDataSchema::set_max_hits(int p_count) {
	max_hits = p_count < 0 ? 0 : p_count;
	emit_changed();
}

void GameplayTargetDataSchema::set_max_payload_bytes(int p_max_bytes) {
	max_payload_bytes = p_max_bytes < 1 ? 1 : p_max_bytes;
	emit_changed();
}

void GameplayTargetDataSchema::set_authority_provider(
		const StringName &p_provider) {
	authority_provider = p_provider;
	emit_changed();
}

void GameplayTargetDataSchema::set_provider_contract_version(int p_version) {
	provider_contract_version = p_version < 1 ? 1 : p_version;
	emit_changed();
}

void GameplayTargetDataSchema::set_deadline_ticks(int64_t p_ticks) {
	deadline_ticks = p_ticks < 0 ? 0 : p_ticks;
	emit_changed();
}

void GameplayTargetDataSchema::set_max_submissions(int p_count) {
	max_submissions = p_count < 1 ? 1 : p_count;
	emit_changed();
}

void GameplayTargetDataSchema::set_max_provider_work(int p_work) {
	max_provider_work = p_work < 1 ? 1 : p_work;
	emit_changed();
}

void GameplayTargetDataSchema::set_description(
		const String &p_description) {
	description = p_description;
	emit_changed();
}

ga::TargetSchemaDesc GameplayTargetDataSchema::to_core_desc() const {
	ga::TargetSchemaDesc desc;
	desc.identifier = to_std(String(identifier));
	desc.schema_version = to_u16_saturated(schema_version);
	desc.intent_kind =
			static_cast<ga::TargetValueKind>(intent_kind);
	desc.result_kind =
			static_cast<ga::TargetValueKind>(result_kind);
	desc.dimension =
			static_cast<ga::TargetSpatialDimension>(
					spatial_dimension);
	desc.coordinate_space = to_std(String(coordinate_space));
	desc.coordinate_scale = coordinate_scale;
	desc.precision_raw = precision_raw;
	desc.max_coordinate_raw = max_coordinate_raw;
	desc.min_entities = to_u16_saturated(min_entities);
	desc.max_entities = to_u16_saturated(max_entities);
	desc.min_hits = to_u16_saturated(min_hits);
	desc.max_hits = to_u16_saturated(max_hits);
	desc.max_payload_bytes = to_u16_saturated(max_payload_bytes);
	desc.entity_order =
			static_cast<ga::TargetEntityOrder>(entity_order);
	desc.duplicate_policy =
			static_cast<ga::TargetDuplicatePolicy>(
					duplicate_policy);
	desc.allow_self = allow_self;
	desc.allow_empty = allow_empty;
	desc.session_mode =
			static_cast<ga::TargetSessionMode>(session_mode);
	desc.acceptance_policy =
			static_cast<ga::TargetAcceptancePolicy>(
					acceptance_policy);
	desc.authority_provider =
			to_std(String(authority_provider));
	desc.provider_contract_version =
			to_u16_saturated(provider_contract_version);
	desc.visibility =
			static_cast<ga::TargetResultVisibility>(
					result_visibility);
	desc.deadline_ticks =
			static_cast<std::uint64_t>(deadline_ticks);
	desc.max_submissions = to_u16_saturated(max_submissions);
	desc.max_provider_work = to_u16_saturated(max_provider_work);
	desc.preview_allowed = preview_allowed;
	desc.prediction_policy =
			static_cast<ga::TargetPredictionPolicy>(
					prediction_policy);
	desc.description = to_std(description);
	return desc;
}

void GameplayTargetDataSchema::_validate_property(
		PropertyInfo &p_property) const {
	const StringName name = p_property.name;
	auto is = [&name](const char *p_name) {
		return name == StringName(p_name);
	};
	const bool has_spatial = spatial_kind(intent_kind) ||
			spatial_kind(result_kind);
	const bool has_entities =
			intent_kind == VALUE_ENTITY_SET ||
			result_kind == VALUE_ENTITY_SET;
	const bool has_hits = intent_kind == VALUE_HIT_SET ||
			result_kind == VALUE_HIT_SET;

	if ((is("spatial_dimension") || is("coordinate_space") ||
				is("coordinate_scale") || is("precision_raw") ||
				is("max_coordinate_raw")) &&
			!has_spatial) {
		p_property.usage &= ~PROPERTY_USAGE_EDITOR;
	}
	if ((is("min_entities") || is("max_entities")) &&
			!has_entities) {
		p_property.usage &= ~PROPERTY_USAGE_EDITOR;
	}
	if ((is("min_hits") || is("max_hits")) && !has_hits) {
		p_property.usage &= ~PROPERTY_USAGE_EDITOR;
	}
	if (is("allow_self") && !has_entities && !has_hits) {
		p_property.usage &= ~PROPERTY_USAGE_EDITOR;
	}
	// Legacy storage alias only; avoid showing two controls for one field.
	if (is("max_targets")) {
		p_property.usage &= ~PROPERTY_USAGE_EDITOR;
	}
}

void GameplayTargetDataSchema::_bind_methods() {
#define GA_BIND_SCHEMA_PROPERTY(m_name, m_setter, m_getter) \
	ClassDB::bind_method(D_METHOD(#m_setter, #m_name), \
			&GameplayTargetDataSchema::m_setter); \
	ClassDB::bind_method(D_METHOD(#m_getter), \
			&GameplayTargetDataSchema::m_getter)

	GA_BIND_SCHEMA_PROPERTY(identifier, set_identifier, get_identifier);
	GA_BIND_SCHEMA_PROPERTY(schema_version, set_schema_version,
			get_schema_version);
	GA_BIND_SCHEMA_PROPERTY(intent_kind, set_intent_kind, get_intent_kind);
	GA_BIND_SCHEMA_PROPERTY(result_kind, set_result_kind, get_result_kind);
	GA_BIND_SCHEMA_PROPERTY(spatial_dimension, set_spatial_dimension,
			get_spatial_dimension);
	GA_BIND_SCHEMA_PROPERTY(coordinate_space, set_coordinate_space,
			get_coordinate_space);
	GA_BIND_SCHEMA_PROPERTY(coordinate_scale, set_coordinate_scale,
			get_coordinate_scale);
	GA_BIND_SCHEMA_PROPERTY(precision_raw, set_precision_raw,
			get_precision_raw);
	GA_BIND_SCHEMA_PROPERTY(max_coordinate_raw, set_max_coordinate_raw,
			get_max_coordinate_raw);
	GA_BIND_SCHEMA_PROPERTY(min_entities, set_min_entities,
			get_min_entities);
	GA_BIND_SCHEMA_PROPERTY(max_entities, set_max_entities,
			get_max_entities);
	GA_BIND_SCHEMA_PROPERTY(max_targets, set_max_targets,
			get_max_targets);
	GA_BIND_SCHEMA_PROPERTY(min_hits, set_min_hits, get_min_hits);
	GA_BIND_SCHEMA_PROPERTY(max_hits, set_max_hits, get_max_hits);
	GA_BIND_SCHEMA_PROPERTY(max_payload_bytes, set_max_payload_bytes,
			get_max_payload_bytes);
	GA_BIND_SCHEMA_PROPERTY(entity_order, set_entity_order,
			get_entity_order);
	GA_BIND_SCHEMA_PROPERTY(duplicate_policy, set_duplicate_policy,
			get_duplicate_policy);
	GA_BIND_SCHEMA_PROPERTY(allow_self, set_allow_self, get_allow_self);
	GA_BIND_SCHEMA_PROPERTY(allow_empty, set_allow_empty, get_allow_empty);
	GA_BIND_SCHEMA_PROPERTY(session_mode, set_session_mode,
			get_session_mode);
	GA_BIND_SCHEMA_PROPERTY(acceptance_policy, set_acceptance_policy,
			get_acceptance_policy);
	GA_BIND_SCHEMA_PROPERTY(authority_provider, set_authority_provider,
			get_authority_provider);
	GA_BIND_SCHEMA_PROPERTY(provider_contract_version,
			set_provider_contract_version,
			get_provider_contract_version);
	GA_BIND_SCHEMA_PROPERTY(result_visibility, set_result_visibility,
			get_result_visibility);
	GA_BIND_SCHEMA_PROPERTY(deadline_ticks, set_deadline_ticks,
			get_deadline_ticks);
	GA_BIND_SCHEMA_PROPERTY(max_submissions, set_max_submissions,
			get_max_submissions);
	GA_BIND_SCHEMA_PROPERTY(max_provider_work, set_max_provider_work,
			get_max_provider_work);
	GA_BIND_SCHEMA_PROPERTY(preview_allowed, set_preview_allowed,
			get_preview_allowed);
	GA_BIND_SCHEMA_PROPERTY(prediction_policy, set_prediction_policy,
			get_prediction_policy);
	GA_BIND_SCHEMA_PROPERTY(description, set_description, get_description);

#undef GA_BIND_SCHEMA_PROPERTY

	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "identifier",
						 PROPERTY_HINT_PLACEHOLDER_TEXT,
						 "target_schema.combat.ray_hit"),
			"set_identifier", "get_identifier");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "schema_version",
						 PROPERTY_HINT_RANGE, "1,65535,1"),
			"set_schema_version", "get_schema_version");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "intent_kind",
						 PROPERTY_HINT_ENUM,
						 "EntitySet,Point,Direction,Ray,HitSet"),
			"set_intent_kind", "get_intent_kind");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "result_kind",
						 PROPERTY_HINT_ENUM,
						 "EntitySet,Point,Direction,Ray,HitSet"),
			"set_result_kind", "get_result_kind");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "spatial_dimension",
						 PROPERTY_HINT_ENUM,
						 "None:0,2D:2,3D:3"),
			"set_spatial_dimension", "get_spatial_dimension");
	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "coordinate_space",
						 PROPERTY_HINT_PLACEHOLDER_TEXT, "space.world"),
			"set_coordinate_space", "get_coordinate_space");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "coordinate_scale",
						 PROPERTY_HINT_RANGE,
						 "1,1000000000,1,or_greater"),
			"set_coordinate_scale", "get_coordinate_scale");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "precision_raw",
						 PROPERTY_HINT_RANGE,
						 "1,1000000000,1,or_greater"),
			"set_precision_raw", "get_precision_raw");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "max_coordinate_raw",
						 PROPERTY_HINT_RANGE,
						 "1,1000000000000,1,or_greater"),
			"set_max_coordinate_raw", "get_max_coordinate_raw");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "min_entities",
						 PROPERTY_HINT_RANGE, "0,32,1"),
			"set_min_entities", "get_min_entities");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "max_entities",
						 PROPERTY_HINT_RANGE, "0,32,1"),
			"set_max_entities", "get_max_entities");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "max_targets",
						 PROPERTY_HINT_RANGE, "0,32,1"),
			"set_max_targets", "get_max_targets");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "min_hits",
						 PROPERTY_HINT_RANGE, "0,32,1"),
			"set_min_hits", "get_min_hits");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "max_hits",
						 PROPERTY_HINT_RANGE, "0,32,1"),
			"set_max_hits", "get_max_hits");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "max_payload_bytes",
						 PROPERTY_HINT_RANGE, "1,2048,1"),
			"set_max_payload_bytes", "get_max_payload_bytes");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "entity_order",
						 PROPERTY_HINT_ENUM,
						 "CanonicalById,ProviderRanked"),
			"set_entity_order", "get_entity_order");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "duplicate_policy",
						 PROPERTY_HINT_ENUM,
						 "Reject,StableFirstDeduplicate"),
			"set_duplicate_policy", "get_duplicate_policy");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "allow_self"),
			"set_allow_self", "get_allow_self");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "allow_empty"),
			"set_allow_empty", "get_allow_empty");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "session_mode",
						 PROPERTY_HINT_ENUM,
						 "Instant,ExplicitConfirm,ConfirmOrCancel"),
			"set_session_mode", "get_session_mode");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "acceptance_policy",
						 PROPERTY_HINT_ENUM,
						 "RequireAll,RequireAny,AllowEmpty"),
			"set_acceptance_policy", "get_acceptance_policy");
	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "authority_provider",
						 PROPERTY_HINT_PLACEHOLDER_TEXT,
						 "target_provider.direct_entity"),
			"set_authority_provider", "get_authority_provider");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "provider_contract_version",
						 PROPERTY_HINT_RANGE, "1,65535,1"),
			"set_provider_contract_version",
			"get_provider_contract_version");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "result_visibility",
						 PROPERTY_HINT_ENUM,
						 "OwnerOnly,Observable,Internal"),
			"set_result_visibility", "get_result_visibility");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "deadline_ticks",
						 PROPERTY_HINT_RANGE, "0,864000,1"),
			"set_deadline_ticks", "get_deadline_ticks");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "max_submissions",
						 PROPERTY_HINT_RANGE, "1,128,1"),
			"set_max_submissions", "get_max_submissions");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "max_provider_work",
						 PROPERTY_HINT_RANGE, "1,256,1"),
			"set_max_provider_work", "get_max_provider_work");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "preview_allowed"),
			"set_preview_allowed", "get_preview_allowed");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "prediction_policy",
						 PROPERTY_HINT_ENUM,
						 "AuthorityOnly,PreviewOnly,PredictionSafe"),
			"set_prediction_policy", "get_prediction_policy");
	ADD_PROPERTY(PropertyInfo(Variant::STRING, "description",
						 PROPERTY_HINT_MULTILINE_TEXT),
			"set_description", "get_description");

	BIND_ENUM_CONSTANT(VALUE_ENTITY_SET);
	BIND_ENUM_CONSTANT(VALUE_POINT);
	BIND_ENUM_CONSTANT(VALUE_DIRECTION);
	BIND_ENUM_CONSTANT(VALUE_RAY);
	BIND_ENUM_CONSTANT(VALUE_HIT_SET);
	BIND_ENUM_CONSTANT(DIMENSION_NONE);
	BIND_ENUM_CONSTANT(DIMENSION_2D);
	BIND_ENUM_CONSTANT(DIMENSION_3D);
	BIND_ENUM_CONSTANT(ORDER_CANONICAL_BY_ID);
	BIND_ENUM_CONSTANT(ORDER_PROVIDER_RANKED);
	BIND_ENUM_CONSTANT(DUPLICATES_REJECT);
	BIND_ENUM_CONSTANT(DUPLICATES_STABLE_FIRST);
	BIND_ENUM_CONSTANT(SESSION_INSTANT);
	BIND_ENUM_CONSTANT(SESSION_EXPLICIT_CONFIRM);
	BIND_ENUM_CONSTANT(SESSION_CONFIRM_OR_CANCEL);
	BIND_ENUM_CONSTANT(ACCEPT_REQUIRE_ALL);
	BIND_ENUM_CONSTANT(ACCEPT_REQUIRE_ANY);
	BIND_ENUM_CONSTANT(ACCEPT_ALLOW_EMPTY);
	BIND_ENUM_CONSTANT(VISIBILITY_OWNER_ONLY);
	BIND_ENUM_CONSTANT(VISIBILITY_OBSERVABLE);
	BIND_ENUM_CONSTANT(VISIBILITY_INTERNAL);
	BIND_ENUM_CONSTANT(PREDICTION_AUTHORITY_ONLY);
	BIND_ENUM_CONSTANT(PREDICTION_PREVIEW_ONLY);
	BIND_ENUM_CONSTANT(PREDICTION_SAFE);
}

} // namespace godot
