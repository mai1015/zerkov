#ifndef GAMEPLAY_ABILITIES_RESOURCES_TARGET_DATA_SCHEMA_H
#define GAMEPLAY_ABILITIES_RESOURCES_TARGET_DATA_SCHEMA_H

#include "core/ga_target_types.h"

#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/core/property_info.hpp>
#include <godot_cpp/variant/string_name.hpp>

namespace godot {

// Catalog-owned authoring form of ga::TargetSchemaDesc. Every field that can
// change targeting behavior has an editor property and is converted through
// to_core_desc(), so validation, runtime registration, manifest hashing, and
// multiplayer compatibility all consume one canonical contract.
class GameplayTargetDataSchema : public Resource {
	GDCLASS(GameplayTargetDataSchema, Resource)

public:
	enum ValueKind {
		VALUE_ENTITY_SET = 0,
		VALUE_POINT = 1,
		VALUE_DIRECTION = 2,
		VALUE_RAY = 3,
		VALUE_HIT_SET = 4,
	};
	enum SpatialDimension {
		DIMENSION_NONE = 0,
		DIMENSION_2D = 2,
		DIMENSION_3D = 3,
	};
	enum EntityOrder {
		ORDER_CANONICAL_BY_ID = 0,
		ORDER_PROVIDER_RANKED = 1,
	};
	enum DuplicatePolicy {
		DUPLICATES_REJECT = 0,
		DUPLICATES_STABLE_FIRST = 1,
	};
	enum SessionMode {
		SESSION_INSTANT = 0,
		SESSION_EXPLICIT_CONFIRM = 1,
		SESSION_CONFIRM_OR_CANCEL = 2,
	};
	enum AcceptancePolicy {
		ACCEPT_REQUIRE_ALL = 0,
		ACCEPT_REQUIRE_ANY = 1,
		ACCEPT_ALLOW_EMPTY = 2,
	};
	enum ResultVisibility {
		VISIBILITY_OWNER_ONLY = 0,
		VISIBILITY_OBSERVABLE = 1,
		VISIBILITY_INTERNAL = 2,
	};
	enum PredictionPolicy {
		PREDICTION_AUTHORITY_ONLY = 0,
		PREDICTION_PREVIEW_ONLY = 1,
		PREDICTION_SAFE = 2,
	};

	void set_identifier(const StringName &p_identifier);
	StringName get_identifier() const { return identifier; }
	void set_schema_version(int p_version);
	int get_schema_version() const { return schema_version; }

	void set_intent_kind(ValueKind p_kind);
	ValueKind get_intent_kind() const { return intent_kind; }
	void set_result_kind(ValueKind p_kind);
	ValueKind get_result_kind() const { return result_kind; }
	void set_spatial_dimension(SpatialDimension p_dimension);
	SpatialDimension get_spatial_dimension() const {
		return spatial_dimension;
	}
	void set_coordinate_space(const StringName &p_space);
	StringName get_coordinate_space() const { return coordinate_space; }
	void set_coordinate_scale(int64_t p_scale);
	int64_t get_coordinate_scale() const { return coordinate_scale; }
	void set_precision_raw(int64_t p_precision);
	int64_t get_precision_raw() const { return precision_raw; }
	void set_max_coordinate_raw(int64_t p_max);
	int64_t get_max_coordinate_raw() const {
		return max_coordinate_raw;
	}

	void set_min_entities(int p_count);
	int get_min_entities() const { return min_entities; }
	void set_max_entities(int p_count);
	int get_max_entities() const { return max_entities; }
	// Backward-compatible alias for the pre-typed resource field. New
	// authoring should use max_entities.
	void set_max_targets(int p_count) { set_max_entities(p_count); }
	int get_max_targets() const { return get_max_entities(); }
	void set_min_hits(int p_count);
	int get_min_hits() const { return min_hits; }
	void set_max_hits(int p_count);
	int get_max_hits() const { return max_hits; }
	void set_max_payload_bytes(int p_max_bytes);
	int get_max_payload_bytes() const { return max_payload_bytes; }
	void set_entity_order(EntityOrder p_order);
	EntityOrder get_entity_order() const { return entity_order; }
	void set_duplicate_policy(DuplicatePolicy p_policy);
	DuplicatePolicy get_duplicate_policy() const {
		return duplicate_policy;
	}
	void set_allow_self(bool p_allow);
	bool get_allow_self() const { return allow_self; }
	void set_allow_empty(bool p_allow);
	bool get_allow_empty() const { return allow_empty; }

	void set_session_mode(SessionMode p_mode);
	SessionMode get_session_mode() const { return session_mode; }
	void set_acceptance_policy(AcceptancePolicy p_policy);
	AcceptancePolicy get_acceptance_policy() const {
		return acceptance_policy;
	}
	void set_authority_provider(const StringName &p_provider);
	StringName get_authority_provider() const {
		return authority_provider;
	}
	void set_provider_contract_version(int p_version);
	int get_provider_contract_version() const {
		return provider_contract_version;
	}
	void set_result_visibility(ResultVisibility p_visibility);
	ResultVisibility get_result_visibility() const {
		return result_visibility;
	}
	void set_deadline_ticks(int64_t p_ticks);
	int64_t get_deadline_ticks() const { return deadline_ticks; }
	void set_max_submissions(int p_count);
	int get_max_submissions() const { return max_submissions; }
	void set_max_provider_work(int p_work);
	int get_max_provider_work() const { return max_provider_work; }
	void set_preview_allowed(bool p_allowed);
	bool get_preview_allowed() const { return preview_allowed; }
	void set_prediction_policy(PredictionPolicy p_policy);
	PredictionPolicy get_prediction_policy() const {
		return prediction_policy;
	}

	void set_description(const String &p_description);
	String get_description() const { return description; }

	ga::TargetSchemaDesc to_core_desc() const;

protected:
	static void _bind_methods();
	void _validate_property(PropertyInfo &p_property) const;

private:
	StringName identifier;
	int schema_version = 1;
	ValueKind intent_kind = VALUE_ENTITY_SET;
	ValueKind result_kind = VALUE_ENTITY_SET;
	SpatialDimension spatial_dimension = DIMENSION_NONE;
	StringName coordinate_space = StringName("space.world");
	int64_t coordinate_scale = 1000000;
	int64_t precision_raw = 1000;
	int64_t max_coordinate_raw = 1000000000;
	int min_entities = 1;
	int max_entities = 1;
	int min_hits = 0;
	int max_hits = 1;
	int max_payload_bytes = 256;
	EntityOrder entity_order = ORDER_CANONICAL_BY_ID;
	DuplicatePolicy duplicate_policy = DUPLICATES_REJECT;
	bool allow_self = false;
	bool allow_empty = false;
	SessionMode session_mode = SESSION_INSTANT;
	AcceptancePolicy acceptance_policy = ACCEPT_REQUIRE_ALL;
	StringName authority_provider =
			StringName("target_provider.direct_entity");
	int provider_contract_version = 1;
	ResultVisibility result_visibility = VISIBILITY_OWNER_ONLY;
	int64_t deadline_ticks = 0;
	int max_submissions = 8;
	int max_provider_work = 64;
	bool preview_allowed = true;
	PredictionPolicy prediction_policy = PREDICTION_AUTHORITY_ONLY;
	String description;
};

} // namespace godot

VARIANT_ENUM_CAST(GameplayTargetDataSchema::ValueKind);
VARIANT_ENUM_CAST(GameplayTargetDataSchema::SpatialDimension);
VARIANT_ENUM_CAST(GameplayTargetDataSchema::EntityOrder);
VARIANT_ENUM_CAST(GameplayTargetDataSchema::DuplicatePolicy);
VARIANT_ENUM_CAST(GameplayTargetDataSchema::SessionMode);
VARIANT_ENUM_CAST(GameplayTargetDataSchema::AcceptancePolicy);
VARIANT_ENUM_CAST(GameplayTargetDataSchema::ResultVisibility);
VARIANT_ENUM_CAST(GameplayTargetDataSchema::PredictionPolicy);

#endif // GAMEPLAY_ABILITIES_RESOURCES_TARGET_DATA_SCHEMA_H
