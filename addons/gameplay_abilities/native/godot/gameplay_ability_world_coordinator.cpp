#include "godot/gameplay_ability_world_coordinator.h"

#include "godot/gameplay_ability_godot_util.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/object.hpp>
#include <godot_cpp/variant/array.hpp>

#include <algorithm>
#include <utility>

namespace godot {

namespace {

Dictionary status_dictionary(const ga::Status &p_status) {
	Dictionary result;
	result["ok"] = p_status.ok();
	result["code"] = static_cast<int>(p_status.code);
	result["diagnostic"] = static_cast<int>(p_status.diagnostic);
	result["detail"] = static_cast<int64_t>(p_status.detail);
	return result;
}

Dictionary status_result(const ga::Status &p_status) {
	Dictionary result;
	result["status"] = status_dictionary(p_status);
	return result;
}

ga::Status parse_status(const Variant &p_value) {
	if (p_value.get_type() != Variant::DICTIONARY) {
		return ga::make_status(ga::StatusCode::INVALID_ARGUMENT,
				ga::DiagnosticId::INVALID_TARGET_PROVENANCE);
	}
	const Dictionary value = p_value;
	const int64_t code_raw = value.get("code", 0);
	const int64_t diagnostic_raw = value.get("diagnostic", 0);
	const int64_t detail_raw = value.get("detail", 0);
	if (code_raw < 0 || code_raw > 65535 ||
			diagnostic_raw < 0 || diagnostic_raw > 65535 ||
			detail_raw < 0 ||
			!ga::is_known_status_code(
					static_cast<std::uint16_t>(code_raw)) ||
			!ga::is_known_diagnostic_id(
					static_cast<std::uint16_t>(diagnostic_raw))) {
		return ga::make_status(ga::StatusCode::INVALID_ARGUMENT,
				ga::DiagnosticId::INVALID_ENUM);
	}
	return ga::make_status(
			static_cast<ga::StatusCode>(code_raw),
			static_cast<ga::DiagnosticId>(diagnostic_raw),
			static_cast<std::uint64_t>(detail_raw));
}

Dictionary finding(const String &p_field, const String &p_code,
		const String &p_message) {
	Dictionary result;
	result["severity"] = "error";
	result["resource_path"] = String();
	result["field"] = p_field;
	result["code"] = p_code;
	result["message"] = p_message;
	return result;
}

ga::EntityId entity_id(int64_t p_value) {
	return p_value > 0 ?
			ga::EntityId{ static_cast<std::uint64_t>(p_value) } :
			ga::INVALID_ENTITY_ID;
}

ga::ExecutionId execution_id(int64_t p_value) {
	return p_value > 0 ?
			ga::ExecutionId{ static_cast<std::uint64_t>(p_value) } :
			ga::INVALID_EXECUTION_ID;
}

ga::TargetSessionId target_session_id(int64_t p_value) {
	return p_value > 0 ?
			ga::TargetSessionId{
					static_cast<std::uint64_t>(p_value) } :
			ga::INVALID_TARGET_SESSION_ID;
}

ga::CommandSeq command_sequence(int64_t p_value) {
	return p_value > 0 ?
			ga::CommandSeq{ static_cast<std::uint64_t>(p_value) } :
			ga::INVALID_COMMAND_SEQ;
}

ga::PredictionKey prediction_key(int64_t p_value) {
	return p_value > 0 ?
			ga::PredictionKey{ static_cast<std::uint64_t>(p_value) } :
			ga::INVALID_PREDICTION_KEY;
}

} // namespace

class ScriptAuthorityTargetProvider final :
		public ga::AuthorityTargetProvider {
public:
	ScriptAuthorityTargetProvider(ga::TargetProviderContract p_contract,
			Callable p_resolver) :
			provider_contract(std::move(p_contract)),
			resolver(std::move(p_resolver)) {}

	ga::TargetProviderContract contract() const override {
		return provider_contract;
	}

	ga::Status resolve(const ga::TargetProviderContext &p_context,
			const ga::CanonicalTargetIntent &p_intent,
			ga::TargetProviderOutput &r_output) const override {
		if (!resolver.is_valid() || p_context.schema == nullptr) {
			return ga::make_status(
					ga::StatusCode::TARGET_PROVIDER_REJECTED,
					ga::DiagnosticId::TARGET_PROVIDER_MISMATCH);
		}
		Dictionary context;
		context["source"] =
				static_cast<int64_t>(p_context.source.value);
		context["ability"] =
				static_cast<int64_t>(p_context.ability);
		context["execution"] =
				static_cast<int64_t>(p_context.execution.value);
		context["session"] =
				static_cast<int64_t>(p_context.session.value);
		context["authority_tick"] =
				static_cast<int64_t>(p_context.authority_tick);
		context["schema_id"] =
				static_cast<int64_t>(p_context.schema->id);
		context["schema_identifier"] =
				String(p_context.schema->desc.identifier.c_str());
		context["schema_version"] =
				static_cast<int>(
						p_context.schema->desc.schema_version);
		context["canonical_hash"] =
				static_cast<int64_t>(p_intent.canonical_hash);
		const Ref<GameplayTargetValue> intent =
				GameplayTargetValue::from_core(p_intent.value,
						p_context.schema->desc.coordinate_scale,
						static_cast<int>(
								p_context.schema->desc.dimension));
		const Variant returned = resolver.call(context, intent);
		if (returned.get_type() != Variant::DICTIONARY) {
			return ga::make_status(
					ga::StatusCode::TARGET_PROVIDER_REJECTED,
					ga::DiagnosticId::INVALID_TARGET_PROVENANCE);
		}
		const Dictionary value = returned;
		r_output = ga::TargetProviderOutput{};
		if (value.has("status")) {
			r_output.status = parse_status(value["status"]);
			if (!r_output.status.ok()) {
				return ga::ok_status();
			}
		} else {
			r_output.status = ga::ok_status();
		}
		r_output.work_units = static_cast<std::uint16_t>(
				std::clamp<int64_t>(
						value.get("work_units", 0), 0, 65535));

		const Variant result_variant = value.get("result", Variant());
		if (result_variant.get_type() != Variant::OBJECT) {
			return ga::make_status(
					ga::StatusCode::TARGET_PROVIDER_REJECTED,
					ga::DiagnosticId::INVALID_TARGET_KIND);
		}
		const Ref<GameplayTargetValue> result = result_variant;
		if (result.is_null()) {
			return ga::make_status(
					ga::StatusCode::TARGET_PROVIDER_REJECTED,
					ga::DiagnosticId::INVALID_TARGET_KIND);
		}
		ga::Status status = result->to_core(*p_context.schema, false,
				p_context.source, r_output.result);
		if (!status.ok()) {
			return status;
		}

		const Array outcomes = value.get("outcomes", Array());
		if (outcomes.size() > int(ga::MAX_TARGETS_PER_COMMAND)) {
			return ga::make_status(ga::StatusCode::CAPACITY_EXCEEDED,
					ga::DiagnosticId::COUNT_LIMIT_EXCEEDED,
					outcomes.size());
		}
		for (int i = 0; i < outcomes.size(); ++i) {
			if (outcomes[i].get_type() != Variant::DICTIONARY) {
				return ga::make_status(
						ga::StatusCode::TARGET_PROVIDER_REJECTED,
						ga::DiagnosticId::
								INVALID_TARGET_PROVENANCE);
			}
			const Dictionary authored = outcomes[i];
			const int64_t outcome_entity =
					authored.get("entity", 0);
			const int64_t rank = authored.get("rank", i);
			const int64_t kind = authored.get("kind", 0);
			if (outcome_entity <= 0 || rank < 0 || rank > 65535 ||
					kind < 0 ||
					kind > static_cast<int64_t>(
							ga::TargetEntityOutcomeKind::
									EFFECT_REJECTED)) {
				return ga::make_status(
						ga::StatusCode::TARGET_PROVIDER_REJECTED,
						ga::DiagnosticId::INVALID_ENUM);
			}
			ga::TargetEntityOutcome outcome;
			outcome.entity = entity_id(outcome_entity);
			outcome.rank = static_cast<std::uint16_t>(rank);
			outcome.kind =
					static_cast<ga::TargetEntityOutcomeKind>(kind);
			outcome.status = authored.has("status") ?
					parse_status(authored["status"]) :
					ga::ok_status();
			r_output.outcomes.push_back(outcome);
		}
		return ga::ok_status();
	}

private:
	ga::TargetProviderContract provider_contract;
	Callable resolver;
};

class ScriptPreviewTargetProvider final :
		public ga::LocalPreviewTargetProvider {
public:
	ScriptPreviewTargetProvider(ga::TargetProviderContract p_contract,
			Callable p_previewer) :
			provider_contract(std::move(p_contract)),
			previewer(std::move(p_previewer)) {}

	ga::TargetProviderContract contract() const override {
		return provider_contract;
	}

	ga::Status preview(const ga::TargetProviderContext &p_context,
			ga::LocalTargetPreview &r_preview) const override {
		if (!previewer.is_valid() || p_context.schema == nullptr) {
			return ga::make_status(ga::StatusCode::INVALID_REFERENCE,
					ga::DiagnosticId::TARGET_PROVIDER_MISMATCH);
		}
		Dictionary context;
		context["source"] =
				static_cast<int64_t>(p_context.source.value);
		context["ability"] =
				static_cast<int64_t>(p_context.ability);
		context["execution"] =
				static_cast<int64_t>(p_context.execution.value);
		context["session"] =
				static_cast<int64_t>(p_context.session.value);
		context["tick"] =
				static_cast<int64_t>(p_context.authority_tick);
		context["schema_id"] =
				static_cast<int64_t>(p_context.schema->id);
		context["schema_identifier"] =
				String(p_context.schema->desc.identifier.c_str());
		context["schema_version"] =
				static_cast<int>(
						p_context.schema->desc.schema_version);
		const Variant returned = previewer.call(context);
		if (returned.get_type() != Variant::DICTIONARY) {
			return ga::make_status(ga::StatusCode::INVALID_TARGET_DATA,
					ga::DiagnosticId::INVALID_TARGET_PROVENANCE);
		}
		const Dictionary value = returned;
		r_preview = ga::LocalTargetPreview{};
		r_preview.status = value.has("status") ?
				parse_status(value["status"]) :
				ga::ok_status();
		if (!r_preview.status.ok()) {
			return ga::ok_status();
		}
		const Ref<GameplayTargetValue> presentation =
				value.get("presentation_value", Variant());
		const Ref<GameplayTargetValue> intent =
				value.get("intent", Variant());
		if (presentation.is_null() || intent.is_null()) {
			return ga::make_status(
					ga::StatusCode::INVALID_TARGET_DATA,
					ga::DiagnosticId::INVALID_TARGET_KIND);
		}
		ga::Status status = presentation->to_core(*p_context.schema,
				false, p_context.source,
				r_preview.presentation_value);
		if (!status.ok()) {
			return status;
		}
		status = intent->to_core(*p_context.schema, true,
				p_context.source, r_preview.intent.value);
		return status;
	}

private:
	ga::TargetProviderContract provider_contract;
	Callable previewer;
};

GameplayAbilityWorldCoordinator::GameplayAbilityWorldCoordinator() = default;
GameplayAbilityWorldCoordinator::~GameplayAbilityWorldCoordinator() = default;

void GameplayAbilityWorldCoordinator::set_target_data_schemas(
		const TypedArray<GameplayTargetDataSchema> &p_schemas) {
	if (is_configured()) {
		return;
	}
	target_data_schemas = p_schemas;
}

void GameplayAbilityWorldCoordinator::set_definition_catalog(
		const Ref<GameplayDefinitionCatalog> &p_catalog) {
	if (is_configured()) {
		return;
	}
	definition_catalog = p_catalog;
}

Array GameplayAbilityWorldCoordinator::configure() {
	Array findings;
	if (is_configured()) {
		findings.append(finding("", "already_configured",
				"configure() was already called."));
		return findings;
	}
	if (definition_catalog.is_valid() &&
			!target_data_schemas.is_empty()) {
		findings.append(finding("target_data_schemas",
				"catalog_legacy_conflict",
				"A coordinator cannot mix a definition catalog with "
				"direct target schema resources."));
		return findings;
	}
	const TypedArray<GameplayTargetDataSchema> source =
			definition_catalog.is_valid() ?
			definition_catalog->get_target_data_schemas() :
			target_data_schemas;
	ga::TargetSchemaRegistry candidate;
	for (int i = 0; i < source.size(); ++i) {
		const Ref<GameplayTargetDataSchema> schema = source[i];
		if (schema.is_null()) {
			findings.append(finding(
					vformat("target_data_schemas[%d]", i),
					"null_resource", "Target schema slot is empty."));
			continue;
		}
		ga::DefinitionId unused = ga::INVALID_DEFINITION_ID;
		const ga::Status status = candidate.register_schema(
				schema->to_core_desc(), unused);
		if (!status.ok()) {
			findings.append(finding(
					vformat("target_data_schemas[%d]", i),
					"target_schema_registration_failed",
					vformat("Schema '%s' failed validation (code %d, "
									"diagnostic %d).",
							String(schema->get_identifier()),
							int(status.code), int(status.diagnostic))));
		}
	}
	if (!findings.is_empty()) {
		return findings;
	}
	const ga::Status seal_status = candidate.seal();
	if (!seal_status.ok()) {
		findings.append(finding("target_data_schemas", "seal_failed",
				"Failed to seal the target schema registry."));
		return findings;
	}
	schemas = std::move(candidate);
	coordinator =
			std::make_unique<ga::GameplayAbilityWorldCoordinator>(
					schemas);
	coordinator->add_session_listener(
			[this](const ga::TargetSessionEvent &p_event) {
				emit_signal("target_session_changed",
						session_event_dictionary(p_event));
			});
	set_process(true);
	return findings;
}

bool GameplayAbilityWorldCoordinator::registries_match(
		const ga::TargetSchemaRegistry &p_other) const {
	if (!schemas.sealed() || !p_other.sealed() ||
			schemas.size() != p_other.size()) {
		return false;
	}
	ga::ManifestBuilder own_builder(ga::DEFAULT_TICK_RATE);
	ga::ManifestBuilder other_builder(ga::DEFAULT_TICK_RATE);
	if (!schemas.contribute_manifest(own_builder).ok() ||
			!p_other.contribute_manifest(other_builder).ok()) {
		return false;
	}
	ga::ContentManifest own;
	ga::ContentManifest other;
	return own_builder.build(own).ok() &&
			other_builder.build(other).ok() &&
			own.fingerprint == other.fingerprint;
}

Dictionary GameplayAbilityWorldCoordinator::register_component(
		GameplayAbilityComponent *p_component, bool p_authoritative) {
	if (!is_configured() || p_component == nullptr ||
			!p_component->is_configured() ||
			p_component->core_component() == nullptr) {
		return status_result(ga::make_status(
				ga::StatusCode::INVALID_ARGUMENT,
				ga::DiagnosticId::TARGET_NOT_RELEVANT));
	}
	// A freed-but-not-yet-pruned registration for the SAME entity id must not
	// spuriously block a genuinely new registration with an ALREADY_EXISTS
	// (spec "Entity registration is duplicated" is about a second LIVE
	// registration, not a stale one).
	prune_freed_components(last_tick);
	if (!registries_match(p_component->target_schema_registry())) {
		return status_result(ga::make_status(
				ga::StatusCode::MANIFEST_MISMATCH,
				ga::DiagnosticId::MANIFEST_FINGERPRINT_DIFFERS));
	}
	const ga::Status status = coordinator->register_component(
			*p_component->core_component(), p_authoritative);
	if (status.ok()) {
		const ga::EntityId id =
				p_component->core_component()->entity();
		components[id] = ComponentAdapterRegistration{
			p_component, ObjectID(p_component->get_instance_id())
		};
	}
	return status_result(status);
}

Dictionary GameplayAbilityWorldCoordinator::unregister_component(
		int64_t p_entity, int64_t p_tick) {
	if (!is_configured()) {
		return status_result(ga::make_status(
				ga::StatusCode::INVALID_ARGUMENT));
	}
	last_tick = std::max(last_tick, p_tick);
	const ga::EntityId id = entity_id(p_entity);
	// A caller may legitimately hold this entity id after the node itself
	// was already freed (e.g. a script reacting to `component_pruned`, or a
	// racing teardown path) -- checking `ObjectDB` here, exactly like
	// `prune_freed_components` does, avoids handing the core a live-
	// component call against a registration whose object no longer exists.
	auto registration = components.find(id);
	const bool component_destroyed = registration != components.end() &&
			ObjectDB::get_instance(registration->second.object_id) ==
					nullptr;
	const ga::Status status = coordinator->unregister_component(id,
			static_cast<ga::Tick>(std::max<int64_t>(0, p_tick)),
			component_destroyed);
	if (status.ok()) {
		components.erase(id);
	}
	return status_result(status);
}

bool GameplayAbilityWorldCoordinator::has_component(
		int64_t p_entity) const {
	return is_configured() &&
			coordinator->has_component(entity_id(p_entity));
}

Dictionary GameplayAbilityWorldCoordinator::register_authority_provider(
		const StringName &p_identifier, int p_contract_version,
		int p_intent_kind, int p_result_kind,
		bool p_prediction_safe, int p_max_work,
		const Callable &p_resolver) {
	if (!is_configured() || !p_resolver.is_valid() ||
			p_contract_version < 1 || p_contract_version > 65535 ||
			p_intent_kind < 0 ||
			p_intent_kind > int(ga::TargetValueKind::HIT_SET) ||
			p_result_kind < 0 ||
			p_result_kind > int(ga::TargetValueKind::HIT_SET) ||
			p_max_work < 1 || p_max_work > 65535) {
		return status_result(ga::make_status(
				ga::StatusCode::INVALID_ARGUMENT,
				ga::DiagnosticId::TARGET_PROVIDER_MISMATCH));
	}
	ga::TargetProviderContract contract;
	contract.identifier = to_std(String(p_identifier));
	contract.version =
			static_cast<std::uint16_t>(p_contract_version);
	contract.intent_kind =
			static_cast<ga::TargetValueKind>(p_intent_kind);
	contract.result_kind =
			static_cast<ga::TargetValueKind>(p_result_kind);
	contract.prediction_safe = p_prediction_safe;
	contract.max_work = static_cast<std::uint16_t>(p_max_work);
	auto provider = std::make_unique<ScriptAuthorityTargetProvider>(
			contract, p_resolver);
	const ga::Status status =
			coordinator->register_authority_provider(*provider);
	if (status.ok()) {
		authority_providers.push_back(std::move(provider));
	}
	return status_result(status);
}

Dictionary GameplayAbilityWorldCoordinator::register_preview_provider(
		const StringName &p_identifier, int p_contract_version,
		int p_intent_kind, int p_result_kind,
		bool p_prediction_safe, int p_max_work,
		const Callable &p_previewer) {
	if (!is_configured() || !p_previewer.is_valid() ||
			p_contract_version < 1 || p_contract_version > 65535 ||
			p_intent_kind < 0 ||
			p_intent_kind > int(ga::TargetValueKind::HIT_SET) ||
			p_result_kind < 0 ||
			p_result_kind > int(ga::TargetValueKind::HIT_SET) ||
			p_max_work < 1 || p_max_work > 65535) {
		return status_result(ga::make_status(
				ga::StatusCode::INVALID_ARGUMENT,
				ga::DiagnosticId::TARGET_PROVIDER_MISMATCH));
	}
	ga::TargetProviderContract contract;
	contract.identifier = to_std(String(p_identifier));
	contract.version =
			static_cast<std::uint16_t>(p_contract_version);
	contract.intent_kind =
			static_cast<ga::TargetValueKind>(p_intent_kind);
	contract.result_kind =
			static_cast<ga::TargetValueKind>(p_result_kind);
	contract.prediction_safe = p_prediction_safe;
	contract.max_work = static_cast<std::uint16_t>(p_max_work);
	auto provider = std::make_unique<ScriptPreviewTargetProvider>(
			contract, p_previewer);
	const ga::Status status =
			coordinator->register_preview_provider(*provider);
	if (status.ok()) {
		preview_providers.push_back(std::move(provider));
	}
	return status_result(status);
}

Dictionary GameplayAbilityWorldCoordinator::validate_provider_contracts()
		const {
	return status_result(is_configured() ?
			coordinator->validate_provider_contracts() :
			ga::make_status(ga::StatusCode::INVALID_ARGUMENT,
					ga::DiagnosticId::INVALID_TARGET_SCHEMA));
}

Dictionary GameplayAbilityWorldCoordinator::adapt_legacy_entity_targets(
		const StringName &p_schema, const PackedInt64Array &p_entities,
		int64_t p_source) const {
	if (!is_configured()) {
		return status_result(ga::make_status(
				ga::StatusCode::INVALID_ARGUMENT,
				ga::DiagnosticId::INVALID_TARGET_SCHEMA));
	}
	// Unlike `preview_target`/`begin_targeting`/etc. below, this method never
	// resolves `p_source` through `components` -- it only reads the sealed
	// schema registry and normalizes a value, so a freed-but-not-yet-pruned
	// registration can't make it dereference anything stale. Pruning is
	// therefore skipped here, exactly like the schema-only
	// `validate_provider_contracts()` above.
	const ga::TargetSchema *schema =
			schemas.find(to_std(String(p_schema)));
	if (schema == nullptr) {
		return status_result(ga::make_status(
				ga::StatusCode::UNKNOWN_TARGET_SCHEMA,
				ga::DiagnosticId::DEFINITION_UNKNOWN_REFERENCE));
	}
	std::vector<ga::EntityId> entities;
	entities.reserve(p_entities.size());
	for (int64_t i = 0; i < p_entities.size(); ++i) {
		entities.push_back(entity_id(p_entities[i]));
	}
	ga::TargetValue canonical;
	const ga::Status status = ga::adapt_legacy_entity_targets(entities,
			*schema, entity_id(p_source), canonical);
	Dictionary result = status_result(status);
	if (status.ok()) {
		result["value"] = GameplayTargetValue::from_core(canonical,
				schema->desc.coordinate_scale,
				static_cast<int>(schema->desc.dimension));
	}
	return result;
}

Dictionary GameplayAbilityWorldCoordinator::preview_target(
		int64_t p_source, const String &p_ability_identifier,
		int64_t p_execution, int64_t p_session,
		const StringName &p_schema, int64_t p_tick) {
	if (!is_configured()) {
		return status_result(ga::make_status(
				ga::StatusCode::INVALID_ARGUMENT,
				ga::DiagnosticId::INVALID_TARGET_SCHEMA));
	}
	prune_freed_components(p_tick);
	const ga::EntityId source_id = entity_id(p_source);
	auto registration = components.find(source_id);
	const ga::TargetSchema *schema =
			schemas.find(to_std(String(p_schema)));
	if (registration == components.end() ||
			registration->second.component == nullptr ||
			schema == nullptr) {
		return status_result(ga::make_status(
				schema == nullptr ?
						ga::StatusCode::UNKNOWN_TARGET_SCHEMA :
						ga::StatusCode::UNKNOWN_NETWORK_IDENTITY,
				ga::DiagnosticId::TARGET_NOT_RELEVANT));
	}
	GameplayAbilityComponent *source =
			registration->second.component;
	ga::LocalTargetPreview preview;
	const ga::Status status = coordinator->preview_target(source_id,
			static_cast<ga::DefinitionId>(
					source->ability_id_of(p_ability_identifier)),
			execution_id(p_execution), target_session_id(p_session),
			schema->id,
			static_cast<ga::Tick>(
					std::max<int64_t>(0, p_tick)),
			preview);
	Dictionary result = status_result(status);
	if (status.ok()) {
		result["presentation_value"] =
				GameplayTargetValue::from_core(
						preview.presentation_value,
						schema->desc.coordinate_scale,
						static_cast<int>(schema->desc.dimension));
		result["intent"] = GameplayTargetValue::from_core(
				preview.intent.value, schema->desc.coordinate_scale,
				static_cast<int>(schema->desc.dimension));
	}
	last_tick = std::max(last_tick, p_tick);
	return result;
}

Dictionary GameplayAbilityWorldCoordinator::resolve_with_origin(
		ga::TargetIntentOrigin p_origin, int64_t p_source,
		const String &p_ability_identifier,
		const Ref<GameplayTargetValue> &p_intent, int64_t p_tick) {
	if (!is_configured() || p_intent.is_null()) {
		return status_result(ga::make_status(
				ga::StatusCode::INVALID_ARGUMENT,
				ga::DiagnosticId::INVALID_TARGET_KIND));
	}
	prune_freed_components(p_tick);
	const ga::EntityId source_id = entity_id(p_source);
	auto registration = components.find(source_id);
	if (registration == components.end() ||
			registration->second.component == nullptr) {
		return status_result(ga::make_status(
				ga::StatusCode::UNKNOWN_NETWORK_IDENTITY,
				ga::DiagnosticId::TARGET_NOT_RELEVANT,
				source_id.value));
	}
	GameplayAbilityComponent *source =
			registration->second.component;
	const Dictionary schema_info =
			source->get_target_data_schema_for_ability(
					p_ability_identifier);
	const std::string schema_identifier =
			to_std(String(schema_info.get("schema", String())));
	const ga::TargetSchema *schema =
			schemas.find(schema_identifier);
	if (schema == nullptr) {
		return status_result(ga::make_status(
				ga::StatusCode::UNKNOWN_TARGET_SCHEMA,
				ga::DiagnosticId::DEFINITION_UNKNOWN_REFERENCE));
	}
	ga::TargetValue value;
	ga::Status status = p_intent->to_core(*schema, true, source_id,
			value);
	if (!status.ok()) {
		return status_result(status);
	}
	ga::TargetIntent intent;
	intent.origin = p_origin;
	intent.source = source_id;
	intent.ability = static_cast<ga::DefinitionId>(
			source->ability_id_of(p_ability_identifier));
	intent.schema = schema->id;
	intent.schema_version = schema->desc.schema_version;
	intent.submitted_tick =
			static_cast<ga::Tick>(std::max<int64_t>(0, p_tick));
	intent.value = std::move(value);
	ga::ValidatedTargetData validated;
	switch (p_origin) {
		case ga::TargetIntentOrigin::DIRECT_ACTIVATION:
			status = coordinator->resolve_direct(intent,
					intent.submitted_tick, validated);
			break;
		case ga::TargetIntentOrigin::GAMEPLAY_EVENT:
			status = coordinator->resolve_gameplay_event(intent,
					intent.submitted_tick, validated);
			break;
		case ga::TargetIntentOrigin::AI:
			status = coordinator->resolve_ai(intent,
					intent.submitted_tick, validated);
			break;
		case ga::TargetIntentOrigin::TEST:
			status = coordinator->resolve_test(intent,
					intent.submitted_tick, validated);
			break;
		default:
			status = ga::make_status(ga::StatusCode::INVALID_ARGUMENT,
					ga::DiagnosticId::INVALID_ENUM);
			break;
	}
	Dictionary result;
	result["status"] = status_dictionary(status);
	if (status.ok()) {
		result["validated_data"] = wrap_validated(validated);
	}
	last_tick = std::max(last_tick, p_tick);
	return result;
}

Dictionary GameplayAbilityWorldCoordinator::resolve_direct(
		int64_t p_source, const String &p_ability_identifier,
		const Ref<GameplayTargetValue> &p_intent, int64_t p_tick) {
	return resolve_with_origin(
			ga::TargetIntentOrigin::DIRECT_ACTIVATION, p_source,
			p_ability_identifier, p_intent, p_tick);
}

Dictionary GameplayAbilityWorldCoordinator::resolve_gameplay_event(
		int64_t p_source, const String &p_ability_identifier,
		const Ref<GameplayTargetValue> &p_intent, int64_t p_tick) {
	return resolve_with_origin(ga::TargetIntentOrigin::GAMEPLAY_EVENT,
			p_source, p_ability_identifier, p_intent, p_tick);
}

Dictionary GameplayAbilityWorldCoordinator::resolve_ai(
		int64_t p_source, const String &p_ability_identifier,
		const Ref<GameplayTargetValue> &p_intent, int64_t p_tick) {
	return resolve_with_origin(ga::TargetIntentOrigin::AI, p_source,
			p_ability_identifier, p_intent, p_tick);
}

Dictionary GameplayAbilityWorldCoordinator::resolve_test(
		int64_t p_source, const String &p_ability_identifier,
		const Ref<GameplayTargetValue> &p_intent, int64_t p_tick) {
	return resolve_with_origin(ga::TargetIntentOrigin::TEST, p_source,
			p_ability_identifier, p_intent, p_tick);
}

Dictionary GameplayAbilityWorldCoordinator::begin_targeting(
		int64_t p_owner, int64_t p_execution,
		const StringName &p_schema, int64_t p_tick,
		const Ref<GameplayTargetValue> &p_initial_intent) {
	if (!is_configured()) {
		return status_result(
				ga::make_status(ga::StatusCode::INVALID_ARGUMENT));
	}
	prune_freed_components(p_tick);
	const ga::EntityId owner = entity_id(p_owner);
	const ga::TargetSchema *schema =
			schemas.find(to_std(String(p_schema)));
	if (schema == nullptr) {
		return status_result(ga::make_status(
				ga::StatusCode::UNKNOWN_TARGET_SCHEMA,
				ga::DiagnosticId::DEFINITION_UNKNOWN_REFERENCE));
	}
	ga::TargetValue initial;
	const ga::TargetValue *initial_ptr = nullptr;
	if (p_initial_intent.is_valid()) {
		const ga::Status status = p_initial_intent->to_core(
				*schema, true, owner, initial);
		if (!status.ok()) {
			return status_result(status);
		}
		initial_ptr = &initial;
	}
	const ga::TargetSessionStartResult result =
			coordinator->begin_wait_target_data(owner,
					execution_id(p_execution), schema->id,
					static_cast<ga::Tick>(
							std::max<int64_t>(0, p_tick)),
					initial_ptr);
	last_tick = std::max(last_tick, p_tick);
	return session_start_result_dictionary(result);
}

Dictionary GameplayAbilityWorldCoordinator::attach_targeting(
		int64_t p_owner, int64_t p_execution, int64_t p_task,
		int64_t p_tick,
		const Ref<GameplayTargetValue> &p_initial_intent) {
	if (!is_configured() || p_task <= 0) {
		return status_result(ga::make_status(
				ga::StatusCode::INVALID_ARGUMENT,
				ga::DiagnosticId::INVALID_TASK_PAYLOAD));
	}
	prune_freed_components(p_tick);
	const ga::EntityId owner = entity_id(p_owner);
	auto registration = components.find(owner);
	if (registration == components.end() ||
			registration->second.component == nullptr ||
			registration->second.component->core_component() == nullptr) {
		return status_result(ga::make_status(
				ga::StatusCode::UNKNOWN_NETWORK_IDENTITY,
				ga::DiagnosticId::TARGET_NOT_RELEVANT,
				owner.value));
	}
	const ga::AbilityTaskHandle task{
		static_cast<std::uint64_t>(p_task)
	};
	const ga::ActiveAbilityTask *active =
			registration->second.component->core_component()
					->ability_tasks()
					.find(task);
	const ga::TargetSchema *schema = active != nullptr ?
			schemas.find(active->request.target_schema) :
			nullptr;
	if (active == nullptr || schema == nullptr) {
		return status_result(ga::make_status(
				ga::StatusCode::INVALID_ABILITY_TASK,
				ga::DiagnosticId::TASK_PARENT_MISSING,
				task.value));
	}
	ga::TargetValue initial;
	const ga::TargetValue *initial_ptr = nullptr;
	if (p_initial_intent.is_valid()) {
		const ga::Status status = p_initial_intent->to_core(
				*schema, true, owner, initial);
		if (!status.ok()) {
			return status_result(status);
		}
		initial_ptr = &initial;
	}
	const ga::TargetSessionStartResult result =
			coordinator->attach_wait_target_data(owner,
					execution_id(p_execution), task,
					static_cast<ga::Tick>(
							std::max<int64_t>(0, p_tick)),
					initial_ptr);
	last_tick = std::max(last_tick, p_tick);
	return session_start_result_dictionary(result);
}

Dictionary GameplayAbilityWorldCoordinator::submit_session_command(
		ga::TargetSessionCommandKind p_kind, int64_t p_session,
		const Ref<GameplayTargetValue> &p_intent,
		int64_t p_sequence, int64_t p_tick,
		int64_t p_prediction_key) {
	if (!is_configured()) {
		return status_result(
				ga::make_status(ga::StatusCode::INVALID_ARGUMENT));
	}
	prune_freed_components(p_tick);
	const ga::TargetSessionId session_id =
			target_session_id(p_session);
	const ga::ActiveTargetSession *session =
			coordinator->find_session(session_id);
	if (session == nullptr) {
		ga::TargetSessionCommand command;
		command.kind = p_kind;
		command.session = session_id;
		command.sequence = command_sequence(p_sequence);
		command.tick = static_cast<ga::Tick>(
				std::max<int64_t>(0, p_tick));
		return session_command_result_dictionary(
				coordinator->submit_session_command(command));
	}
	const ga::TargetSchema *schema = schemas.find(session->schema);
	if (schema == nullptr) {
		return status_result(ga::make_status(
				ga::StatusCode::UNKNOWN_TARGET_SCHEMA,
				ga::DiagnosticId::DEFINITION_UNKNOWN_REFERENCE));
	}
	ga::TargetSessionCommand command;
	command.kind = p_kind;
	command.owner = session->owner;
	command.execution = session->execution;
	command.task = session->task;
	command.session = session->id;
	command.schema = session->schema;
	command.schema_version = schema->desc.schema_version;
	command.sequence = command_sequence(p_sequence);
	command.tick = static_cast<ga::Tick>(
			std::max<int64_t>(0, p_tick));
	command.prediction_key = prediction_key(p_prediction_key);
	if (p_intent.is_valid()) {
		const ga::Status status = p_intent->to_core(*schema, true,
				session->owner, command.intent);
		if (!status.ok()) {
			return status_result(status);
		}
		command.has_intent = true;
	}
	const ga::TargetSessionCommandResult result =
			coordinator->submit_session_command(command);
	last_tick = std::max(last_tick, p_tick);
	return session_command_result_dictionary(result);
}

Dictionary GameplayAbilityWorldCoordinator::submit_target_intent(
		int64_t p_session,
		const Ref<GameplayTargetValue> &p_intent,
		int64_t p_sequence, int64_t p_tick,
		int64_t p_prediction_key) {
	return submit_session_command(
			ga::TargetSessionCommandKind::SUBMIT, p_session, p_intent,
			p_sequence, p_tick, p_prediction_key);
}

Dictionary GameplayAbilityWorldCoordinator::confirm_target(
		int64_t p_session, int64_t p_sequence, int64_t p_tick,
		const Ref<GameplayTargetValue> &p_latest_intent,
		int64_t p_prediction_key) {
	return submit_session_command(
			ga::TargetSessionCommandKind::CONFIRM, p_session,
			p_latest_intent, p_sequence, p_tick, p_prediction_key);
}

Dictionary GameplayAbilityWorldCoordinator::cancel_target(
		int64_t p_session, int64_t p_sequence, int64_t p_tick,
		int64_t p_prediction_key) {
	return submit_session_command(
			ga::TargetSessionCommandKind::CANCEL, p_session,
			Ref<GameplayTargetValue>(), p_sequence, p_tick,
			p_prediction_key);
}

Dictionary GameplayAbilityWorldCoordinator::advance_to(int64_t p_tick) {
	if (!is_configured()) {
		return status_result(
				ga::make_status(ga::StatusCode::INVALID_ARGUMENT));
	}
	prune_freed_components(p_tick);
	const ga::Status status = coordinator->advance_to(
			static_cast<ga::Tick>(std::max<int64_t>(0, p_tick)));
	last_tick = std::max(last_tick, p_tick);
	return status_result(status);
}

Dictionary GameplayAbilityWorldCoordinator::get_target_session(
		int64_t p_session) const {
	Dictionary result;
	if (!is_configured()) {
		return result;
	}
	const ga::ActiveTargetSession *session =
			coordinator->find_session(target_session_id(p_session));
	if (session == nullptr) {
		return result;
	}
	result["session"] = static_cast<int64_t>(session->id.value);
	result["owner"] = static_cast<int64_t>(session->owner.value);
	result["ability"] = static_cast<int64_t>(session->ability);
	result["execution"] =
			static_cast<int64_t>(session->execution.value);
	result["task"] = static_cast<int64_t>(session->task.value);
	result["schema_id"] = static_cast<int64_t>(session->schema);
	result["start_tick"] = static_cast<int64_t>(session->start_tick);
	result["has_deadline"] = session->has_deadline;
	result["deadline_tick"] =
			static_cast<int64_t>(session->deadline_tick);
	result["last_sequence"] =
			static_cast<int64_t>(
					session->last_command_sequence.value);
	result["submission_count"] =
			static_cast<int>(session->submission_count);
	result["has_intent"] = session->has_intent;
	if (session->has_intent) {
		const ga::TargetSchema *schema =
				schemas.find(session->schema);
		result["intent"] = GameplayTargetValue::from_core(
				session->latest_intent.value,
				schema != nullptr ?
						schema->desc.coordinate_scale :
						1000000,
				schema != nullptr ?
						static_cast<int>(schema->desc.dimension) :
						0);
		result["intent_hash"] = static_cast<int64_t>(
				session->latest_intent.canonical_hash);
	}
	return result;
}

PackedInt64Array
GameplayAbilityWorldCoordinator::active_target_sessions() const {
	PackedInt64Array result;
	if (!is_configured()) {
		return result;
	}
	for (ga::TargetSessionId session :
			coordinator->active_sessions()) {
		result.append(static_cast<int64_t>(session.value));
	}
	return result;
}

bool GameplayAbilityWorldCoordinator::parse_effect_applications(
		const Array &p_values, GameplayAbilityComponent &p_source,
		std::vector<ga::TargetEffectApplication> &r_out) const {
	if (p_values.size() > int(ga::MAX_EFFECT_MODIFIERS)) {
		return false;
	}
	std::vector<ga::TargetEffectApplication> parsed;
	parsed.reserve(p_values.size());
	for (int i = 0; i < p_values.size(); ++i) {
		if (p_values[i].get_type() != Variant::DICTIONARY) {
			return false;
		}
		const Dictionary authored = p_values[i];
		const std::string identifier =
				to_std(String(authored.get("effect", String())));
		ga::TargetEffectApplication application;
		application.effect_definition =
				p_source.resolve_effect_definition_id(identifier);
		application.level =
				static_cast<std::int32_t>(
						static_cast<int64_t>(
								authored.get("level", 1)));
		if (application.effect_definition ==
					ga::INVALID_DEFINITION_ID ||
				application.level < 1) {
			return false;
		}
		const Array fields =
				authored.get("set_by_caller", Array());
		if (!GameplayAbilityComponent::parse_set_by_caller_fields(
					fields, application.set_by_caller)) {
			return false;
		}
		parsed.push_back(std::move(application));
	}
	r_out = std::move(parsed);
	return true;
}

Dictionary GameplayAbilityWorldCoordinator::apply_effect_batch(
		const Ref<GameplayValidatedTargetData> &p_validated,
		const Array &p_source_effects, const Array &p_target_effects,
		int64_t p_tick) {
	Dictionary result;
	if (!is_configured() || p_validated.is_null() ||
			!p_validated->is_valid() ||
			p_validated->owner != this) {
		result["status"] = status_dictionary(ga::make_status(
				ga::StatusCode::PERMISSION_DENIED,
				ga::DiagnosticId::INVALID_TARGET_PROVENANCE));
		return result;
	}
	prune_freed_components(p_tick);
	auto source_it = components.find(p_validated->data.source());
	if (source_it == components.end() ||
			source_it->second.component == nullptr) {
		result["status"] = status_dictionary(ga::make_status(
				ga::StatusCode::UNKNOWN_NETWORK_IDENTITY,
				ga::DiagnosticId::TARGET_NOT_RELEVANT));
		return result;
	}
	ga::TargetBatchRequest request;
	request.validated_data = p_validated->data;
	request.tick = static_cast<ga::Tick>(
			std::max<int64_t>(0, p_tick));
	if (!parse_effect_applications(p_source_effects,
				*source_it->second.component,
				request.source_effects) ||
			!parse_effect_applications(p_target_effects,
					*source_it->second.component,
					request.target_effects)) {
		result["status"] = status_dictionary(ga::make_status(
				ga::StatusCode::INVALID_ARGUMENT,
				ga::DiagnosticId::INVALID_TARGET_PROVENANCE));
		return result;
	}
	ga::PreparedTargetBatch prepared;
	ga::Status status = coordinator->prepare_batch(request, prepared);
	if (!status.ok()) {
		result["status"] = status_dictionary(status);
		Array outcomes;
		for (const ga::TargetEntityOutcome &outcome :
				prepared.outcomes()) {
			Dictionary entry;
			entry["entity"] =
					static_cast<int64_t>(outcome.entity.value);
			entry["rank"] = static_cast<int>(outcome.rank);
			entry["kind"] = static_cast<int>(outcome.kind);
			entry["status"] = status_dictionary(outcome.status);
			outcomes.append(entry);
		}
		result["outcomes"] = outcomes;
		return result;
	}
	const ga::TargetBatchCommitResult committed =
			coordinator->commit_batch(prepared);
	result["status"] = status_dictionary(committed.status);
	result["batch"] = static_cast<int64_t>(committed.batch.value);
	result["committed"] = committed.committed;
	result["rolled_back"] = committed.rolled_back;
	Array outcomes;
	for (const ga::TargetEntityOutcome &outcome :
			committed.outcomes) {
		Dictionary entry;
		entry["entity"] =
				static_cast<int64_t>(outcome.entity.value);
		entry["rank"] = static_cast<int>(outcome.rank);
		entry["kind"] = static_cast<int>(outcome.kind);
		entry["status"] = status_dictionary(outcome.status);
		outcomes.append(entry);
	}
	result["outcomes"] = outcomes;
	Array applied;
	for (const ga::AppliedTargetEffect &effect :
			committed.applied_effects) {
		Dictionary entry;
		entry["target"] =
				static_cast<int64_t>(effect.target.value);
		entry["effect_definition"] =
				static_cast<int64_t>(effect.effect_definition);
		entry["handle"] =
				static_cast<int64_t>(effect.handle.value);
		applied.append(entry);
	}
	result["applied_effects"] = applied;
	last_tick = std::max(last_tick, p_tick);
	return result;
}

Dictionary GameplayAbilityWorldCoordinator::session_event_dictionary(
		const ga::TargetSessionEvent &p_event) const {
	Dictionary result;
	result["kind"] = static_cast<int>(p_event.kind);
	result["session"] = static_cast<int64_t>(p_event.session.value);
	result["owner"] = static_cast<int64_t>(p_event.owner.value);
	result["execution"] =
			static_cast<int64_t>(p_event.execution.value);
	result["task"] = static_cast<int64_t>(p_event.task.value);
	result["schema_id"] = static_cast<int64_t>(p_event.schema);
	result["tick"] = static_cast<int64_t>(p_event.tick);
	result["status"] = status_dictionary(p_event.status);
	result["command_sequence"] =
			static_cast<int64_t>(p_event.command_sequence.value);
	result["has_intent"] = p_event.has_intent;
	result["canonical_intent_hash"] =
			static_cast<int64_t>(p_event.canonical_intent_hash);
	return result;
}

Ref<GameplayValidatedTargetData>
GameplayAbilityWorldCoordinator::wrap_validated(
		const ga::ValidatedTargetData &p_data) {
	Ref<GameplayValidatedTargetData> result;
	result.instantiate();
	result->owner = this;
	result->data = p_data;
	return result;
}

Dictionary
GameplayAbilityWorldCoordinator::session_start_result_dictionary(
		const ga::TargetSessionStartResult &p_result) {
	Dictionary result;
	result["status"] = status_dictionary(p_result.status);
	result["session"] =
			static_cast<int64_t>(p_result.session.value);
	result["task"] = static_cast<int64_t>(p_result.task.value);
	result["terminal"] = p_result.terminal;
	if (p_result.has_validated_data) {
		result["validated_data"] =
				wrap_validated(p_result.validated_data);
	}
	return result;
}

Dictionary
GameplayAbilityWorldCoordinator::session_command_result_dictionary(
		const ga::TargetSessionCommandResult &p_result) {
	Dictionary result;
	result["status"] = status_dictionary(p_result.status);
	result["transitioned"] = p_result.transitioned;
	result["terminal"] = p_result.terminal;
	result["duplicate_terminal"] = p_result.duplicate_terminal;
	result["event"] = session_event_dictionary(p_result.event);
	if (p_result.has_validated_data) {
		result["validated_data"] =
				wrap_validated(p_result.validated_data);
	}
	return result;
}

PackedByteArray GameplayAbilityWorldCoordinator::write_snapshot(
		int p_audience) const {
	PackedByteArray result;
	if (!is_configured() || p_audience < 0 || p_audience > 2) {
		return result;
	}
	ga::SnapshotWriter writer;
	const ga::Status status = coordinator->write_snapshot(writer,
			static_cast<ga::TargetResultVisibility>(p_audience));
	if (!status.ok()) {
		return result;
	}
	const std::vector<std::uint8_t> bytes = writer.take();
	result.resize(static_cast<int64_t>(bytes.size()));
	for (std::size_t i = 0; i < bytes.size(); ++i) {
		result.set(static_cast<int64_t>(i), bytes[i]);
	}
	return result;
}

bool GameplayAbilityWorldCoordinator::restore_snapshot(
		const PackedByteArray &p_bytes) {
	if (!is_configured()) {
		return false;
	}
	// The core's own `restore_snapshot` resolves each restored session's
	// owner through `find_component` and dereferences it (parent execution/
	// task lookups) -- prune first so a freed-but-not-yet-pruned entity can
	// never hand it a dangling pointer.
	prune_freed_components(last_tick);
	std::vector<std::uint8_t> bytes;
	bytes.reserve(p_bytes.size());
	for (int64_t i = 0; i < p_bytes.size(); ++i) {
		bytes.push_back(p_bytes[i]);
	}
	ga::SnapshotReader reader(bytes);
	const ga::Status status = coordinator->restore_snapshot(reader);
	return status.ok() && reader.at_end();
}

ga::Status GameplayAbilityWorldCoordinator::restore_owner_snapshot(
		ga::SnapshotReader &p_reader, ga::EntityId p_owner) {
	if (!is_configured()) {
		return ga::make_status(ga::StatusCode::INVALID_ARGUMENT);
	}
	// Same reasoning as `restore_snapshot()` above: the core restore path
	// resolves the owner through `find_component` and dereferences it -- see
	// that method's own comment.
	prune_freed_components(last_tick);
	return coordinator->restore_owner_snapshot(p_reader, p_owner);
}

void GameplayAbilityWorldCoordinator::notify_restored_sessions(
		int64_t p_tick) {
	if (!is_configured()) {
		return;
	}
	coordinator->notify_restored_sessions(
			static_cast<ga::Tick>(std::max<int64_t>(0, p_tick)));
}

void GameplayAbilityWorldCoordinator::prune_freed_components(
		int64_t p_tick) {
	if (!is_configured()) {
		return;
	}
	std::vector<ga::EntityId> stale;
	for (const auto &entry : components) {
		if (ObjectDB::get_instance(entry.second.object_id) == nullptr) {
			stale.push_back(entry.first);
		}
	}
	for (ga::EntityId entity : stale) {
		// `ObjectDB::get_instance` above already returned nullptr for this
		// entity's node, so its `ga::AbilityComponent` (owned by the node's
		// unique_ptr) has already been destroyed -- the destroyed variant
		// ensures the core never dereferences that freed object while
		// terminalizing sessions it owned.
		coordinator->unregister_component(entity,
				static_cast<ga::Tick>(
						std::max<int64_t>(0, p_tick)),
				/*p_component_destroyed=*/true);
		components.erase(entity);
		emit_signal("component_pruned",
				static_cast<int64_t>(entity.value));
	}
}

void GameplayAbilityWorldCoordinator::_notification(int p_what) {
	if (p_what == NOTIFICATION_PROCESS) {
		prune_freed_components(last_tick);
	}
}

void GameplayAbilityWorldCoordinator::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_target_data_schemas", "schemas"),
			&GameplayAbilityWorldCoordinator::set_target_data_schemas);
	ClassDB::bind_method(D_METHOD("get_target_data_schemas"),
			&GameplayAbilityWorldCoordinator::get_target_data_schemas);
	ClassDB::bind_method(D_METHOD("set_definition_catalog", "catalog"),
			&GameplayAbilityWorldCoordinator::set_definition_catalog);
	ClassDB::bind_method(D_METHOD("get_definition_catalog"),
			&GameplayAbilityWorldCoordinator::get_definition_catalog);
	ClassDB::bind_method(D_METHOD("configure"),
			&GameplayAbilityWorldCoordinator::configure);
	ClassDB::bind_method(D_METHOD("is_configured"),
			&GameplayAbilityWorldCoordinator::is_configured);
	ClassDB::bind_method(D_METHOD("register_component", "component",
								 "authoritative"),
			&GameplayAbilityWorldCoordinator::register_component,
			DEFVAL(true));
	ClassDB::bind_method(D_METHOD("unregister_component", "entity", "tick"),
			&GameplayAbilityWorldCoordinator::unregister_component);
	ClassDB::bind_method(D_METHOD("has_component", "entity"),
			&GameplayAbilityWorldCoordinator::has_component);
	ClassDB::bind_method(D_METHOD("register_authority_provider",
								 "identifier", "contract_version",
								 "intent_kind", "result_kind",
								 "prediction_safe", "max_work", "resolver"),
			&GameplayAbilityWorldCoordinator::
					register_authority_provider);
	ClassDB::bind_method(D_METHOD("register_preview_provider",
								 "identifier", "contract_version",
								 "intent_kind", "result_kind",
								 "prediction_safe", "max_work", "previewer"),
			&GameplayAbilityWorldCoordinator::
					register_preview_provider);
	ClassDB::bind_method(D_METHOD("validate_provider_contracts"),
			&GameplayAbilityWorldCoordinator::
					validate_provider_contracts);
	ClassDB::bind_method(D_METHOD("adapt_legacy_entity_targets", "schema",
									 "entities", "source"),
			&GameplayAbilityWorldCoordinator::
					adapt_legacy_entity_targets);
	ClassDB::bind_method(D_METHOD("preview_target", "source",
								 "ability_identifier", "execution",
								 "session", "schema", "tick"),
			&GameplayAbilityWorldCoordinator::preview_target);
	ClassDB::bind_method(D_METHOD("resolve_direct", "source",
								 "ability_identifier", "intent", "tick"),
			&GameplayAbilityWorldCoordinator::resolve_direct);
	ClassDB::bind_method(D_METHOD("resolve_gameplay_event", "source",
								 "ability_identifier", "intent", "tick"),
			&GameplayAbilityWorldCoordinator::
					resolve_gameplay_event);
	ClassDB::bind_method(D_METHOD("resolve_ai", "source",
								 "ability_identifier", "intent", "tick"),
			&GameplayAbilityWorldCoordinator::resolve_ai);
	ClassDB::bind_method(D_METHOD("resolve_test", "source",
								 "ability_identifier", "intent", "tick"),
			&GameplayAbilityWorldCoordinator::resolve_test);
	ClassDB::bind_method(D_METHOD("begin_targeting", "owner", "execution",
								 "schema", "tick", "initial_intent"),
			&GameplayAbilityWorldCoordinator::begin_targeting,
			DEFVAL(Ref<GameplayTargetValue>()));
	ClassDB::bind_method(D_METHOD("attach_targeting", "owner",
								 "execution", "task", "tick",
								 "initial_intent"),
			&GameplayAbilityWorldCoordinator::attach_targeting,
			DEFVAL(Ref<GameplayTargetValue>()));
	ClassDB::bind_method(D_METHOD("submit_target_intent", "session",
								 "intent", "sequence", "tick",
								 "prediction_key"),
			&GameplayAbilityWorldCoordinator::submit_target_intent,
			DEFVAL(0));
	ClassDB::bind_method(D_METHOD("confirm_target", "session",
								 "sequence", "tick", "latest_intent",
								 "prediction_key"),
			&GameplayAbilityWorldCoordinator::confirm_target,
			DEFVAL(Ref<GameplayTargetValue>()), DEFVAL(0));
	ClassDB::bind_method(D_METHOD("cancel_target", "session", "sequence",
								 "tick", "prediction_key"),
			&GameplayAbilityWorldCoordinator::cancel_target,
			DEFVAL(0));
	ClassDB::bind_method(D_METHOD("advance_to", "tick"),
			&GameplayAbilityWorldCoordinator::advance_to);
	ClassDB::bind_method(D_METHOD("get_target_session", "session"),
			&GameplayAbilityWorldCoordinator::get_target_session);
	ClassDB::bind_method(D_METHOD("active_target_sessions"),
			&GameplayAbilityWorldCoordinator::active_target_sessions);
	ClassDB::bind_method(D_METHOD("apply_effect_batch", "validated_data",
								 "source_effects", "target_effects", "tick"),
			&GameplayAbilityWorldCoordinator::apply_effect_batch);
	ClassDB::bind_method(D_METHOD("write_snapshot", "audience"),
			&GameplayAbilityWorldCoordinator::write_snapshot,
			DEFVAL(2));
	ClassDB::bind_method(D_METHOD("restore_snapshot", "bytes"),
			&GameplayAbilityWorldCoordinator::restore_snapshot);
	ClassDB::bind_method(D_METHOD("notify_restored_sessions", "tick"),
			&GameplayAbilityWorldCoordinator::
					notify_restored_sessions);

	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "target_data_schemas",
						 PROPERTY_HINT_ARRAY_TYPE,
						 "GameplayTargetDataSchema"),
			"set_target_data_schemas", "get_target_data_schemas");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "definition_catalog",
						 PROPERTY_HINT_RESOURCE_TYPE,
						 "GameplayDefinitionCatalog"),
			"set_definition_catalog", "get_definition_catalog");

	ADD_SIGNAL(MethodInfo("target_session_changed",
			PropertyInfo(Variant::DICTIONARY, "event")));
	ADD_SIGNAL(MethodInfo("component_pruned",
			PropertyInfo(Variant::INT, "entity")));
}

} // namespace godot
