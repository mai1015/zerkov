#ifndef GAMEPLAY_ABILITIES_GODOT_TARGET_VALUE_H
#define GAMEPLAY_ABILITIES_GODOT_TARGET_VALUE_H

#include "core/ga_targeting.h"

#include <godot_cpp/classes/ref.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/typed_array.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <vector>

namespace godot {

class GameplayAbilityWorldCoordinator;

// Immutable local hit input. Construction happens through the typed factory
// methods; no mutating property is exposed after creation.
class GameplayTargetHit : public RefCounted {
	GDCLASS(GameplayTargetHit, RefCounted)

public:
	static Ref<GameplayTargetHit> hit_2d(const Vector2 &p_position,
			const Vector2 &p_normal, double p_distance,
			int64_t p_entity = 0, int64_t p_surface_tag_id = 0);
	static Ref<GameplayTargetHit> hit_3d(const Vector3 &p_position,
			const Vector3 &p_normal, double p_distance,
			int64_t p_entity = 0, int64_t p_surface_tag_id = 0);

	int get_dimension() const { return dimension; }
	bool has_entity() const { return entity > 0; }
	int64_t get_entity() const { return entity; }
	Vector2 get_position_2d() const;
	Vector3 get_position_3d() const;
	Vector2 get_normal_2d() const;
	Vector3 get_normal_3d() const;
	double get_distance() const { return distance; }
	bool has_surface_tag() const { return surface_tag_id > 0; }
	int64_t get_surface_tag_id() const { return surface_tag_id; }
	Dictionary to_dictionary() const;

protected:
	static void _bind_methods();

private:
	friend class GameplayTargetValue;
	int dimension = 0;
	std::vector<double> position;
	std::vector<double> normal;
	double distance = 0.0;
	int64_t entity = 0;
	int64_t surface_tag_id = 0;
};

// Immutable typed target input/result wrapper. Local factories retain engine
// vectors only until a coordinator quantizes them against a registered
// schema. Canonical values created by the coordinator retain the integer-only
// core value. Read-only typed accessors dequantize with the same schema scale;
// to_dictionary() additionally exposes the canonical raw integers for tooling
// and deterministic diagnostics.
class GameplayTargetValue : public RefCounted {
	GDCLASS(GameplayTargetValue, RefCounted)

public:
	static Ref<GameplayTargetValue> entity_set(
			const PackedInt64Array &p_entities);
	static Ref<GameplayTargetValue> point_2d(const Vector2 &p_point);
	static Ref<GameplayTargetValue> point_3d(const Vector3 &p_point);
	static Ref<GameplayTargetValue> direction_2d(
			const Vector2 &p_direction);
	static Ref<GameplayTargetValue> direction_3d(
			const Vector3 &p_direction);
	static Ref<GameplayTargetValue> ray_2d(const Vector2 &p_origin,
			const Vector2 &p_direction, double p_length);
	static Ref<GameplayTargetValue> ray_3d(const Vector3 &p_origin,
			const Vector3 &p_direction, double p_length);
	static Ref<GameplayTargetValue> hit_set(
			const TypedArray<GameplayTargetHit> &p_hits);

	int get_kind() const { return static_cast<int>(kind); }
	int get_dimension() const { return dimension; }
	bool is_canonical() const { return canonical; }
	PackedInt64Array get_entities() const;
	Vector2 get_point_2d() const;
	Vector3 get_point_3d() const;
	Vector2 get_direction_2d() const;
	Vector3 get_direction_3d() const;
	Vector2 get_ray_origin_2d() const;
	Vector3 get_ray_origin_3d() const;
	Vector2 get_ray_direction_2d() const;
	Vector3 get_ray_direction_3d() const;
	double get_ray_length() const;
	TypedArray<GameplayTargetHit> get_hits() const;
	Dictionary to_dictionary() const;

	ga::Status to_core(const ga::TargetSchema &p_schema,
			bool p_for_intent, ga::EntityId p_source,
			ga::TargetValue &r_value) const;
	static Ref<GameplayTargetValue> from_core(
			const ga::TargetValue &p_value,
			int64_t p_coordinate_scale = 1000000,
			int p_dimension = 0);

protected:
	static void _bind_methods();

private:
	ga::TargetValueKind kind = ga::TargetValueKind::ENTITY_SET;
	int dimension = 0;
	bool canonical = false;
	int64_t canonical_scale = 1000000;
	ga::TargetValue canonical_value;
	std::vector<ga::EntityId> entities;
	std::vector<double> first;
	std::vector<double> second;
	double scalar = 0.0;
	std::vector<Ref<GameplayTargetHit>> hits;
};

// Script-visible, read-only carrier for the core's unforgeable validated
// provenance. Constructing this class directly yields an invalid value; only
// GameplayAbilityWorldCoordinator can populate the private payload.
class GameplayValidatedTargetData : public RefCounted {
	GDCLASS(GameplayValidatedTargetData, RefCounted)

public:
	bool is_valid() const { return data.valid() && owner != nullptr; }
	int64_t get_source() const {
		return static_cast<int64_t>(data.source().value);
	}
	int64_t get_execution() const {
		return static_cast<int64_t>(data.execution().value);
	}
	int64_t get_session() const {
		return static_cast<int64_t>(data.session().value);
	}
	int64_t get_schema_id() const {
		return static_cast<int64_t>(data.schema());
	}
	int get_schema_version() const {
		return static_cast<int>(data.schema_version());
	}
	int64_t get_authority_tick() const {
		return static_cast<int64_t>(data.authority_tick());
	}
	Ref<GameplayTargetValue> get_canonical_intent() const;
	Ref<GameplayTargetValue> get_result() const;
	Array get_provider_outcomes() const;

protected:
	static void _bind_methods();

private:
	friend class GameplayAbilityWorldCoordinator;
	const GameplayAbilityWorldCoordinator *owner = nullptr;
	ga::ValidatedTargetData data;
};

} // namespace godot

#endif // GAMEPLAY_ABILITIES_GODOT_TARGET_VALUE_H
