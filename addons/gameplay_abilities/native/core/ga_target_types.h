#ifndef GAMEPLAY_ABILITIES_CORE_TARGET_TYPES_H
#define GAMEPLAY_ABILITIES_CORE_TARGET_TYPES_H

#include "core/ga_bytes.h"
#include "core/ga_ids.h"
#include "core/ga_limits.h"
#include "core/ga_manifest.h"
#include "core/ga_snapshot.h"
#include "core/ga_status.h"
#include "core/ga_tick.h"

#include <array>
#include <cstdint>
#include <map>
#include <string>
#include <vector>

namespace ga {

// The target value wire union is deliberately closed. Adding a value kind is
// a protocol change, not an editor-only extension.
constexpr std::uint8_t TARGET_VALUE_VERSION = 1;
constexpr std::uint16_t TARGET_SCHEMA_CANONICAL_VERSION = 1;

enum class TargetValueKind : std::uint8_t {
	ENTITY_SET = 0,
	POINT = 1,
	DIRECTION = 2,
	RAY = 3,
	HIT_SET = 4,
};

enum class TargetSpatialDimension : std::uint8_t {
	NONE = 0,
	TWO_D = 2,
	THREE_D = 3,
};

enum class TargetEntityOrder : std::uint8_t {
	CANONICAL_BY_ID = 0,
	PROVIDER_RANKED = 1,
};

enum class TargetDuplicatePolicy : std::uint8_t {
	REJECT = 0,
	STABLE_FIRST_DEDUPLICATE = 1,
};

enum class TargetSessionMode : std::uint8_t {
	INSTANT = 0,
	EXPLICIT_CONFIRM = 1,
	CONFIRM_OR_CANCEL = 2,
};

enum class TargetAcceptancePolicy : std::uint8_t {
	REQUIRE_ALL = 0,
	REQUIRE_ANY = 1,
	ALLOW_EMPTY = 2,
};

enum class TargetResultVisibility : std::uint8_t {
	OWNER_ONLY = 0,
	OBSERVABLE = 1,
	INTERNAL = 2,
};

enum class TargetPredictionPolicy : std::uint8_t {
	AUTHORITY_ONLY = 0,
	PREVIEW_ONLY = 1,
	PREDICTION_SAFE = 2,
};

// Raw spatial integers use the schema's scale. Unused components MUST be zero.
// This representation never contains a float or an engine-owned identity.
struct TargetVector {
	std::array<std::int64_t, 3> raw{ { 0, 0, 0 } };

	bool operator==(const TargetVector &p_other) const { return raw == p_other.raw; }
	bool operator!=(const TargetVector &p_other) const { return !(*this == p_other); }
};

struct TargetRay {
	TargetVector origin;
	TargetVector direction;
	std::int64_t length_raw = 0;

	bool operator==(const TargetRay &p_other) const {
		return origin == p_other.origin && direction == p_other.direction &&
				length_raw == p_other.length_raw;
	}
};

struct TargetHit {
	bool has_entity = false;
	EntityId entity = INVALID_ENTITY_ID;
	TargetVector position;
	TargetVector normal;
	std::int64_t distance_raw = 0;
	bool has_surface_tag = false;
	DefinitionId surface_tag = INVALID_DEFINITION_ID;

	bool operator==(const TargetHit &p_other) const {
		return has_entity == p_other.has_entity && entity == p_other.entity &&
				position == p_other.position && normal == p_other.normal &&
				distance_raw == p_other.distance_raw &&
				has_surface_tag == p_other.has_surface_tag &&
				surface_tag == p_other.surface_tag;
	}
};

// Value-oriented tagged union. Fields not selected by `kind` are ignored on
// input and cleared by normalization, preventing hidden payload channels.
struct TargetValue {
	TargetValueKind kind = TargetValueKind::ENTITY_SET;
	std::vector<EntityId> entities;
	TargetVector point;
	TargetVector direction;
	TargetRay ray;
	std::vector<TargetHit> hits;

	bool operator==(const TargetValue &p_other) const {
		return kind == p_other.kind && entities == p_other.entities &&
				point == p_other.point && direction == p_other.direction &&
				ray == p_other.ray && hits == p_other.hits;
	}
	bool operator!=(const TargetValue &p_other) const { return !(*this == p_other); }
};

// Immutable context copied into an effect application. The authority-only
// provenance gate lives on `ValidatedTargetData`; this value is the bounded,
// serialization-safe projection calculations, active effects, cues, and
// diagnostics may inspect after the coordinator has admitted the batch.
struct TargetEffectContext {
	bool present = false;
	DefinitionId schema = INVALID_DEFINITION_ID;
	std::uint16_t schema_version = 0;
	EntityId source = INVALID_ENTITY_ID;
	EntityId target = INVALID_ENTITY_ID;
	DefinitionId ability = INVALID_DEFINITION_ID;
	ExecutionId execution = INVALID_EXECUTION_ID;
	TargetSessionId session = INVALID_TARGET_SESSION_ID;
	Tick authority_tick = 0;
	std::uint16_t target_rank = 0;
	bool accepted = false;
	Status target_status;
	TargetResultVisibility visibility =
			TargetResultVisibility::OWNER_ONLY;
	TargetValue canonical_intent;
	TargetValue validated_result;

	bool operator==(const TargetEffectContext &p_other) const {
		return present == p_other.present &&
				schema == p_other.schema &&
				schema_version == p_other.schema_version &&
				source == p_other.source && target == p_other.target &&
				ability == p_other.ability &&
				execution == p_other.execution &&
				session == p_other.session &&
				authority_tick == p_other.authority_tick &&
				target_rank == p_other.target_rank &&
				accepted == p_other.accepted &&
				target_status == p_other.target_status &&
				visibility == p_other.visibility &&
				canonical_intent == p_other.canonical_intent &&
				validated_result == p_other.validated_result;
	}
	bool operator!=(const TargetEffectContext &p_other) const {
		return !(*this == p_other);
	}
};

struct TargetSchemaDesc {
	std::string identifier;
	std::uint16_t schema_version = 1;
	TargetValueKind intent_kind = TargetValueKind::ENTITY_SET;
	TargetValueKind result_kind = TargetValueKind::ENTITY_SET;
	TargetSpatialDimension dimension = TargetSpatialDimension::NONE;
	std::string coordinate_space = "space.world";

	// One whole spatial unit is `coordinate_scale` raw units. Every canonical
	// component is a multiple of `precision_raw` and has absolute magnitude
	// no greater than `max_coordinate_raw`.
	std::int64_t coordinate_scale = 1000000;
	std::int64_t precision_raw = 1000;
	std::int64_t max_coordinate_raw = 1000000000;

	std::uint16_t min_entities = 1;
	std::uint16_t max_entities = 1;
	std::uint16_t min_hits = 0;
	std::uint16_t max_hits = 1;
	std::uint16_t max_payload_bytes = 256;
	TargetEntityOrder entity_order = TargetEntityOrder::CANONICAL_BY_ID;
	TargetDuplicatePolicy duplicate_policy = TargetDuplicatePolicy::REJECT;
	bool allow_self = false;
	bool allow_empty = false;
	TargetSessionMode session_mode = TargetSessionMode::INSTANT;
	TargetAcceptancePolicy acceptance_policy = TargetAcceptancePolicy::REQUIRE_ALL;
	std::string authority_provider;
	std::uint16_t provider_contract_version = 1;
	TargetResultVisibility visibility = TargetResultVisibility::OWNER_ONLY;
	std::uint64_t deadline_ticks = 0;
	std::uint16_t max_submissions = 8;
	std::uint16_t max_provider_work = 64;
	bool preview_allowed = true;
	TargetPredictionPolicy prediction_policy = TargetPredictionPolicy::AUTHORITY_ONLY;
	std::string description;
};

struct TargetSchema {
	DefinitionId id = INVALID_DEFINITION_ID;
	TargetSchemaDesc desc;
};

class TargetSchemaRegistry {
public:
	Status register_schema(const TargetSchemaDesc &p_desc,
			DefinitionId &r_id);
	Status seal();
	bool sealed() const { return is_sealed; }

	const TargetSchema *find(DefinitionId p_id) const;
	const TargetSchema *find(const std::string &p_identifier) const;
	DefinitionId id_of(const std::string &p_identifier) const;
	std::vector<DefinitionId> canonical_order() const;
	std::size_t size() const;

	Status contribute_manifest(ManifestBuilder &p_builder) const;

private:
	std::map<std::string, TargetSchema> pending;
	std::vector<TargetSchema> sealed_schemas;
	IdentifierTable id_table;
	bool is_sealed = false;
};

Status validate_target_schema(const TargetSchemaDesc &p_desc);

// Converts an adapter/provider value into its one canonical representation.
// Direction and normal vectors are integer-normalized to coordinate_scale,
// spatial fields are quantized to precision_raw, and entity order/duplicates
// follow the schema. `p_for_intent` selects the schema's expected kind.
Status normalize_target_value(const TargetValue &p_value,
		const TargetSchema &p_schema, bool p_for_intent,
		EntityId p_source, TargetValue &r_canonical);

// Strict counterpart for decoded canonical values. It rejects rather than
// silently correcting non-canonical wire/snapshot data.
Status validate_canonical_target_value(const TargetValue &p_value,
		const TargetSchema &p_schema, bool p_for_intent,
		EntityId p_source = INVALID_ENTITY_ID);

// Local adapter helper. Quantizes finite floating-point components exactly
// once at the engine boundary; canonical core/wire state remains integer-only.
Status quantize_target_vector(const std::vector<double> &p_components,
		const TargetSchema &p_schema, bool p_normalize,
		TargetVector &r_vector);

Status write_target_value(ByteWriter &p_writer, const TargetValue &p_value,
		const TargetSchema &p_schema, bool p_for_intent);
Status read_target_value(ByteReader &p_reader, const TargetSchema &p_schema,
		bool p_for_intent, TargetValue &r_value);
Status encode_target_value(const TargetValue &p_value,
		const TargetSchema &p_schema, bool p_for_intent,
		std::vector<std::uint8_t> &r_bytes);
Status decode_target_value(const std::vector<std::uint8_t> &p_bytes,
		const TargetSchema &p_schema, bool p_for_intent,
		TargetValue &r_value);
Status hash_target_value(const TargetValue &p_value,
		const TargetSchema &p_schema, bool p_for_intent,
		std::uint64_t &r_hash);

// Schema-independent bounded snapshot form used by retained effect context.
// It always writes three integer components, making dimension unnecessary for
// historical restore while still preserving canonical integer values.
Status write_target_state_value(SnapshotWriter &p_writer,
		const TargetValue &p_value);
Status read_target_state_value(SnapshotReader &p_reader,
		TargetValue &r_value);
Status validate_target_effect_context(
		const TargetEffectContext &p_context);
Status write_target_effect_context(SnapshotWriter &p_writer,
		const TargetEffectContext &p_context);
Status read_target_effect_context(SnapshotReader &p_reader,
		TargetEffectContext &r_context);
// Canonical encoded size of `p_context` in isolation, via the SAME
// `write_target_effect_context` a real snapshot section uses -- never an
// estimate. `EffectRuntime` uses this to enforce
// `MAX_RETAINED_TARGET_CONTEXT_BYTES` (ga_limits.h) at effect-application
// preflight, deterministically and without allocating against untrusted
// input (this just measures a value already held in memory). Fails with
// `validate_target_effect_context`'s own `Status` if `p_context` is not
// itself valid -- callers only ever measure a context that was already
// accepted by that check (a freshly-supplied `EffectSpec::target_context`,
// or one already stored on an `ActiveEffect`), so this should never fail in
// practice.
Status measure_target_effect_context_bytes(
		const TargetEffectContext &p_context, std::size_t &r_bytes);
TargetEffectContext sanitize_target_effect_context(
		const TargetEffectContext &p_context,
		TargetResultVisibility p_audience);

// Explicit pre-typed migration seam. It never guesses a schema and only
// accepts a registered ENTITY_SET -> ENTITY_SET contract.
Status adapt_legacy_entity_targets(const std::vector<EntityId> &p_entities,
		const TargetSchema &p_schema, EntityId p_source,
		TargetValue &r_canonical);

} // namespace ga

#endif // GAMEPLAY_ABILITIES_CORE_TARGET_TYPES_H
