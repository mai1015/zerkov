#ifndef GAMEPLAY_ABILITIES_GODOT_WORLD_COORDINATOR_H
#define GAMEPLAY_ABILITIES_GODOT_WORLD_COORDINATOR_H

#include "godot/gameplay_ability_component.h"
#include "godot/gameplay_target_value.h"

#include "resources/gameplay_definition_catalog.h"
#include "resources/gameplay_target_data_schema.h"

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/core/object_id.hpp>
#include <godot_cpp/variant/callable.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>

#include <map>
#include <memory>
#include <vector>

namespace godot {

class ScriptAuthorityTargetProvider;
class ScriptPreviewTargetProvider;

// Explicit scene/world-owned adapter over ga::GameplayAbilityWorldCoordinator.
// It is never an autoload or singleton: two Nodes create isolated component,
// provider, session, and batch namespaces even when local entity numbers
// overlap.
class GameplayAbilityWorldCoordinator : public Node {
	GDCLASS(GameplayAbilityWorldCoordinator, Node)

public:
	GameplayAbilityWorldCoordinator();
	~GameplayAbilityWorldCoordinator() override;

	void set_target_data_schemas(
			const TypedArray<GameplayTargetDataSchema> &p_schemas);
	TypedArray<GameplayTargetDataSchema> get_target_data_schemas() const {
		return target_data_schemas;
	}
	void set_definition_catalog(
			const Ref<GameplayDefinitionCatalog> &p_catalog);
	Ref<GameplayDefinitionCatalog> get_definition_catalog() const {
		return definition_catalog;
	}

	Array configure();
	bool is_configured() const { return coordinator != nullptr; }
	ga::GameplayAbilityWorldCoordinator *core_coordinator() {
		return coordinator.get();
	}
	const ga::GameplayAbilityWorldCoordinator *core_coordinator() const {
		return coordinator.get();
	}
	const ga::TargetSchemaRegistry &target_schema_registry() const {
		return schemas;
	}

	Dictionary register_component(GameplayAbilityComponent *p_component,
			bool p_authoritative = true);
	Dictionary unregister_component(int64_t p_entity, int64_t p_tick);
	bool has_component(int64_t p_entity) const;

	Dictionary register_authority_provider(
			const StringName &p_identifier, int p_contract_version,
			int p_intent_kind, int p_result_kind,
			bool p_prediction_safe, int p_max_work,
			const Callable &p_resolver);
	Dictionary register_preview_provider(
			const StringName &p_identifier, int p_contract_version,
			int p_intent_kind, int p_result_kind,
			bool p_prediction_safe, int p_max_work,
			const Callable &p_previewer);
	Dictionary validate_provider_contracts() const;
	// Explicit legacy migration seam: normalizes a raw entity id list into a
	// canonical ENTITY_SET under `p_schema` exactly like `ga::
	// adapt_legacy_entity_targets` does at the core layer. Read-only and
	// side-effect-free -- it hands back a typed value for the caller to
	// submit through the normal intent path, it never submits one itself.
	Dictionary adapt_legacy_entity_targets(const StringName &p_schema,
			const PackedInt64Array &p_entities,
			int64_t p_source) const;
	Dictionary preview_target(int64_t p_source,
			const String &p_ability_identifier, int64_t p_execution,
			int64_t p_session, const StringName &p_schema,
			int64_t p_tick);

	Dictionary resolve_direct(int64_t p_source,
			const String &p_ability_identifier,
			const Ref<GameplayTargetValue> &p_intent, int64_t p_tick);
	Dictionary resolve_gameplay_event(int64_t p_source,
			const String &p_ability_identifier,
			const Ref<GameplayTargetValue> &p_intent, int64_t p_tick);
	Dictionary resolve_ai(int64_t p_source,
			const String &p_ability_identifier,
			const Ref<GameplayTargetValue> &p_intent, int64_t p_tick);
	Dictionary resolve_test(int64_t p_source,
			const String &p_ability_identifier,
			const Ref<GameplayTargetValue> &p_intent, int64_t p_tick);

	Dictionary begin_targeting(int64_t p_owner, int64_t p_execution,
			const StringName &p_schema, int64_t p_tick,
			const Ref<GameplayTargetValue> &p_initial_intent =
					Ref<GameplayTargetValue>());
	Dictionary attach_targeting(int64_t p_owner, int64_t p_execution,
			int64_t p_task, int64_t p_tick,
			const Ref<GameplayTargetValue> &p_initial_intent =
					Ref<GameplayTargetValue>());
	Dictionary submit_target_intent(int64_t p_session,
			const Ref<GameplayTargetValue> &p_intent,
			int64_t p_sequence, int64_t p_tick,
			int64_t p_prediction_key = 0);
	Dictionary confirm_target(int64_t p_session, int64_t p_sequence,
			int64_t p_tick,
			const Ref<GameplayTargetValue> &p_latest_intent =
					Ref<GameplayTargetValue>(),
			int64_t p_prediction_key = 0);
	Dictionary cancel_target(int64_t p_session, int64_t p_sequence,
			int64_t p_tick, int64_t p_prediction_key = 0);
	Dictionary advance_to(int64_t p_tick);
	Dictionary get_target_session(int64_t p_session) const;
	PackedInt64Array active_target_sessions() const;

	Dictionary apply_effect_batch(
			const Ref<GameplayValidatedTargetData> &p_validated,
			const Array &p_source_effects, const Array &p_target_effects,
			int64_t p_tick);

	PackedByteArray write_snapshot(int p_audience = 2) const;
	bool restore_snapshot(const PackedByteArray &p_bytes);
	void notify_restored_sessions(int64_t p_tick);

	// Native-only wrapper (never bound to GDScript -- the network bridge is
	// the only caller, exactly like `core_coordinator()` below) around
	// `ga::GameplayAbilityWorldCoordinator::restore_owner_snapshot`. That
	// core call resolves `p_owner` through `find_component` and dereferences
	// it directly (same as the core `restore_snapshot` this class's own
	// `restore_snapshot()` above already prunes for -- see that method's own
	// comment), so a node freed since the last process frame could otherwise
	// be dereferenced. Pruning HERE, in the one wrapper entry point every
	// caller goes through, covers every call site instead of requiring each
	// one to remember it individually.
	ga::Status restore_owner_snapshot(ga::SnapshotReader &p_reader,
			ga::EntityId p_owner);

protected:
	static void _bind_methods();
	void _notification(int p_what);

private:
	struct ComponentAdapterRegistration {
		GameplayAbilityComponent *component = nullptr;
		ObjectID object_id;
	};

	void prune_freed_components(int64_t p_tick);
	Dictionary resolve_with_origin(ga::TargetIntentOrigin p_origin,
			int64_t p_source, const String &p_ability_identifier,
			const Ref<GameplayTargetValue> &p_intent, int64_t p_tick);
	Dictionary submit_session_command(
			ga::TargetSessionCommandKind p_kind, int64_t p_session,
			const Ref<GameplayTargetValue> &p_intent,
			int64_t p_sequence, int64_t p_tick,
			int64_t p_prediction_key);
	Dictionary session_start_result_dictionary(
			const ga::TargetSessionStartResult &p_result);
	Dictionary session_command_result_dictionary(
			const ga::TargetSessionCommandResult &p_result);
	Dictionary session_event_dictionary(
			const ga::TargetSessionEvent &p_event) const;
	Ref<GameplayValidatedTargetData> wrap_validated(
			const ga::ValidatedTargetData &p_data);
	bool parse_effect_applications(const Array &p_values,
			GameplayAbilityComponent &p_source,
			std::vector<ga::TargetEffectApplication> &r_out) const;
	bool registries_match(
			const ga::TargetSchemaRegistry &p_other) const;

	TypedArray<GameplayTargetDataSchema> target_data_schemas;
	Ref<GameplayDefinitionCatalog> definition_catalog;
	ga::TargetSchemaRegistry schemas;
	std::unique_ptr<ga::GameplayAbilityWorldCoordinator> coordinator;
	std::map<ga::EntityId, ComponentAdapterRegistration> components;
	std::vector<std::unique_ptr<ScriptAuthorityTargetProvider>>
			authority_providers;
	std::vector<std::unique_ptr<ScriptPreviewTargetProvider>>
			preview_providers;
	int64_t last_tick = 0;
};

} // namespace godot

#endif // GAMEPLAY_ABILITIES_GODOT_WORLD_COORDINATOR_H
