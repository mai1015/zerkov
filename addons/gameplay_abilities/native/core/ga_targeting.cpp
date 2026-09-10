#include "core/ga_targeting.h"

#include "core/ga_hash.h"
#include "core/ga_identifier.h"

#include <algorithm>
#include <set>

namespace ga {

namespace {

constexpr std::size_t MAX_TARGET_SESSION_TOMBSTONES =
		MAX_ACTIVE_TARGET_SESSIONS * 4;

bool authority_role(ComponentRole p_role) {
	return p_role == ComponentRole::OFFLINE_AUTHORITY ||
			p_role == ComponentRole::SERVER_AUTHORITY;
}

bool visible_to(TargetResultVisibility p_visibility,
		TargetResultVisibility p_audience) {
	switch (p_audience) {
		case TargetResultVisibility::OWNER_ONLY:
			return p_visibility == TargetResultVisibility::OWNER_ONLY ||
					p_visibility == TargetResultVisibility::OBSERVABLE;
		case TargetResultVisibility::OBSERVABLE:
			return p_visibility == TargetResultVisibility::OBSERVABLE;
		case TargetResultVisibility::INTERNAL:
			return true;
	}
	return false;
}

int command_priority(TargetSessionCommandKind p_kind) {
	switch (p_kind) {
		case TargetSessionCommandKind::CANCEL:
			return 0;
		case TargetSessionCommandKind::SUBMIT:
			return 1;
		case TargetSessionCommandKind::CONFIRM:
			return 2;
	}
	return 3;
}

Status provider_rejection(Status p_status) {
	return p_status.ok() ?
			make_status(StatusCode::TARGET_PROVIDER_REJECTED,
					DiagnosticId::TARGET_RULE_REJECTED) :
			p_status;
}

TargetEffectContext make_task_target_context(
		const TargetSchema &p_schema,
		const ActiveTargetSession &p_session, Tick p_tick,
		Status p_status, const ValidatedTargetData *p_validated) {
	TargetEffectContext context;
	context.present = true;
	context.schema = p_schema.id;
	context.schema_version = p_schema.desc.schema_version;
	context.source = p_session.owner;
	context.ability = p_session.ability;
	context.execution = p_session.execution;
	context.session = p_session.id;
	context.authority_tick = p_tick;
	context.accepted = p_status.ok();
	context.target_status = p_status;
	context.visibility = p_schema.desc.visibility;
	context.canonical_intent = p_session.latest_intent.value;
	if (p_validated != nullptr && p_validated->valid()) {
		context.validated_result = p_validated->result();
	}
	return context;
}

} // namespace

GameplayAbilityWorldCoordinator::GameplayAbilityWorldCoordinator(
		const TargetSchemaRegistry &p_schemas) :
		schemas(&p_schemas) {
	// Runtime-only capability seal. It is never serialized and is checked
	// together with this coordinator's address.
	authority_seal = hash_string("gameplay.target.authority") ^
			reinterpret_cast<std::uintptr_t>(this);
	if (authority_seal == 0) {
		authority_seal = 1;
	}
}

Status GameplayAbilityWorldCoordinator::register_component(
		AbilityComponent &p_component, bool p_authoritative) {
	if (authority_provider_running) {
		return make_status(StatusCode::CAPABILITY_VIOLATION,
				DiagnosticId::HOOK_CAPABILITY_DENIED);
	}
	if (!p_component.entity()) {
		return make_status(StatusCode::INVALID_ARGUMENT,
				DiagnosticId::TARGET_NOT_RELEVANT);
	}
	if (components.size() >= MAX_COLLECTION_COUNT) {
		return make_status(StatusCode::CAPACITY_EXCEEDED,
				DiagnosticId::COUNT_LIMIT_EXCEEDED, components.size());
	}
	if (p_authoritative && !authority_role(p_component.role())) {
		return make_status(StatusCode::ROLE_VIOLATION,
				DiagnosticId::INVALID_TARGET_PROVENANCE,
				static_cast<std::uint64_t>(p_component.role()));
	}
	if (!p_authoritative &&
			p_component.role() != ComponentRole::NETWORK_CLIENT) {
		return make_status(StatusCode::ROLE_VIOLATION,
				DiagnosticId::INVALID_TARGET_PROVENANCE,
				static_cast<std::uint64_t>(p_component.role()));
	}
	if (components.find(p_component.entity()) != components.end()) {
		return make_status(StatusCode::ALREADY_EXISTS,
				DiagnosticId::DEFINITION_DUPLICATE,
				p_component.entity().value);
	}
	components.emplace(p_component.entity(),
			ComponentRegistration{ &p_component, p_authoritative });
	return ok_status();
}

Status GameplayAbilityWorldCoordinator::unregister_component(
		EntityId p_entity, Tick p_tick, bool p_component_destroyed) {
	if (authority_provider_running) {
		return make_status(StatusCode::CAPABILITY_VIOLATION,
				DiagnosticId::HOOK_CAPABILITY_DENIED,
				p_entity.value);
	}
	auto found = components.find(p_entity);
	if (found == components.end()) {
		return make_status(StatusCode::NOT_FOUND,
				DiagnosticId::TARGET_NOT_RELEVANT, p_entity.value);
	}
	// Remove the identity first so session listeners cannot re-enter and
	// resolve new work for a component whose teardown has begun. Retain the
	// non-owning component pointer long enough to cancel this owner's attached
	// WAIT_TARGET_DATA tasks; find_component() can no longer find it after the
	// erase. When `p_component_destroyed` is true the pointer is retained ONLY
	// for identity comparison below -- it is never dereferenced, because the
	// object it names has already been freed (see this method's own doc
	// comment in ga_targeting.h).
	AbilityComponent *removed_component = found->second.component;
	components.erase(found);
	std::vector<TargetSessionId> stale;
	for (const auto &entry : sessions) {
		bool references_entity =
				entry.second.owner == p_entity;
		if (!references_entity && entry.second.has_intent) {
			const std::vector<EntityId> intent_entities =
					entities_from_result(
							entry.second.latest_intent.value);
			references_entity =
					std::find(intent_entities.begin(),
							intent_entities.end(),
							p_entity) !=
					intent_entities.end();
		}
		if (references_entity) {
			stale.push_back(entry.first);
		}
	}
	for (TargetSessionId id : stale) {
		auto it = sessions.find(id);
		if (it == sessions.end()) {
			continue;
		}
		TargetSessionEvent event;
		event.kind = TargetSessionLifecycleKind::CANCELLED;
		event.session = id;
		event.owner = it->second.owner;
		event.execution = it->second.execution;
		event.task = it->second.task;
		event.schema = it->second.schema;
		event.tick = p_tick;
		event.status = make_status(StatusCode::ABILITY_TASK_CANCELLED,
				DiagnosticId::OWNER_FREED, p_entity.value);
		// A session owned by `p_entity` can only be cancelled through
		// `removed_component`, and only when that component is still a live
		// object -- if it has already been destroyed (`p_component_destroyed`)
		// its task runtime was destroyed with it, so there is nothing to
		// cancel and dereferencing the pointer would be a use-after-free. A
		// session owned by a DIFFERENT entity that merely references
		// `p_entity` is always cancelled through ITS OWN owner's live
		// component via `find_component`, unaffected by this flag.
		AbilityComponent *owner_component =
				it->second.owner == p_entity ?
				(p_component_destroyed ? nullptr : removed_component) :
				find_component(it->second.owner);
		if (owner_component != nullptr) {
			owner_component->cancel_ability_task(it->second.task,
					p_tick,
					it->second.owner == p_entity ?
							AbilityTaskCancelReason::
									OWNER_TEARDOWN :
							AbilityTaskCancelReason::
									TARGET_SESSION_CANCELLED);
		}
		terminalize_session(id, event,
				it->second.last_command_sequence);
		emit_session_event(event);
	}
	return ok_status();
}

bool GameplayAbilityWorldCoordinator::has_component(EntityId p_entity) const {
	return components.find(p_entity) != components.end();
}

AbilityComponent *GameplayAbilityWorldCoordinator::find_component(
		EntityId p_entity) const {
	auto it = components.find(p_entity);
	return it == components.end() ? nullptr : it->second.component;
}

Status GameplayAbilityWorldCoordinator::validate_contract(
		const TargetProviderContract &p_contract) const {
	Status status = validate_identifier(p_contract.identifier);
	if (!status.ok()) {
		return status;
	}
	if (p_contract.version == 0 ||
			static_cast<std::uint8_t>(p_contract.intent_kind) >
					static_cast<std::uint8_t>(TargetValueKind::HIT_SET) ||
			static_cast<std::uint8_t>(p_contract.result_kind) >
					static_cast<std::uint8_t>(TargetValueKind::HIT_SET) ||
			p_contract.max_work == 0 ||
			p_contract.max_work > MAX_TARGET_PROVIDER_WORK) {
		return make_status(StatusCode::INVALID_ARGUMENT,
				DiagnosticId::TARGET_PROVIDER_MISMATCH);
	}
	return ok_status();
}

Status GameplayAbilityWorldCoordinator::register_authority_provider(
		const AuthorityTargetProvider &p_provider) {
	if (authority_provider_running) {
		return make_status(StatusCode::CAPABILITY_VIOLATION,
				DiagnosticId::HOOK_CAPABILITY_DENIED);
	}
	const TargetProviderContract contract = p_provider.contract();
	Status status = validate_contract(contract);
	if (!status.ok()) {
		return status;
	}
	if (authority_providers.find(contract.identifier) !=
			authority_providers.end()) {
		return make_status(StatusCode::ALREADY_EXISTS,
				DiagnosticId::DEFINITION_DUPLICATE,
				hash_string(contract.identifier));
	}
	authority_providers.emplace(contract.identifier,
			ProviderRegistration{ &p_provider, contract });
	return ok_status();
}

Status GameplayAbilityWorldCoordinator::register_preview_provider(
		const LocalPreviewTargetProvider &p_provider) {
	if (authority_provider_running) {
		return make_status(StatusCode::CAPABILITY_VIOLATION,
				DiagnosticId::HOOK_CAPABILITY_DENIED);
	}
	const TargetProviderContract contract = p_provider.contract();
	Status status = validate_contract(contract);
	if (!status.ok()) {
		return status;
	}
	if (preview_providers.find(contract.identifier) !=
			preview_providers.end()) {
		return make_status(StatusCode::ALREADY_EXISTS,
				DiagnosticId::DEFINITION_DUPLICATE,
				hash_string(contract.identifier));
	}
	preview_providers.emplace(contract.identifier,
			PreviewRegistration{ &p_provider, contract });
	return ok_status();
}

Status GameplayAbilityWorldCoordinator::validate_provider_for_schema(
		const TargetSchema &p_schema) const {
	auto found = authority_providers.find(
			p_schema.desc.authority_provider);
	if (found == authority_providers.end() ||
			found->second.provider == nullptr) {
		return make_status(StatusCode::INVALID_REFERENCE,
				DiagnosticId::TARGET_PROVIDER_MISMATCH,
				hash_string(p_schema.desc.authority_provider));
	}
	const TargetProviderContract &contract = found->second.contract;
	if (contract.version !=
					p_schema.desc.provider_contract_version ||
			contract.intent_kind != p_schema.desc.intent_kind ||
			contract.result_kind != p_schema.desc.result_kind ||
			contract.max_work < p_schema.desc.max_provider_work ||
			(p_schema.desc.prediction_policy ==
							TargetPredictionPolicy::PREDICTION_SAFE &&
					!contract.prediction_safe)) {
		return make_status(StatusCode::INVALID_REFERENCE,
				DiagnosticId::TARGET_PROVIDER_MISMATCH,
				hash_string(contract.identifier));
	}
	return ok_status();
}

Status GameplayAbilityWorldCoordinator::validate_provider_contracts() const {
	if (schemas == nullptr || !schemas->sealed()) {
		return make_status(StatusCode::INVALID_ARGUMENT,
				DiagnosticId::INVALID_TARGET_SCHEMA);
	}
	for (DefinitionId id : schemas->canonical_order()) {
		const TargetSchema *schema = schemas->find(id);
		if (schema == nullptr) {
			continue;
		}
		Status status = validate_provider_for_schema(*schema);
		if (!status.ok()) {
			return status;
		}
	}
	return ok_status();
}

Status GameplayAbilityWorldCoordinator::normalize_intent(
		const TargetIntent &p_intent,
		CanonicalTargetIntent &r_intent) const {
	if (schemas == nullptr || !schemas->sealed()) {
		return make_status(StatusCode::INVALID_ARGUMENT,
				DiagnosticId::INVALID_TARGET_SCHEMA);
	}
	const TargetSchema *schema = schemas->find(p_intent.schema);
	if (schema == nullptr) {
		return make_status(StatusCode::UNKNOWN_TARGET_SCHEMA,
				DiagnosticId::DEFINITION_UNKNOWN_REFERENCE,
				p_intent.schema);
	}
	if (p_intent.schema_version != schema->desc.schema_version ||
			!p_intent.source ||
			static_cast<std::uint8_t>(p_intent.origin) >
					static_cast<std::uint8_t>(
							TargetIntentOrigin::REMOTE_OWNER)) {
		return make_status(StatusCode::INVALID_TARGET_DATA,
				DiagnosticId::INVALID_TARGET_SCHEMA,
				p_intent.schema_version);
	}
	TargetValue canonical;
	Status status = normalize_target_value(p_intent.value, *schema, true,
			p_intent.source, canonical);
	if (!status.ok()) {
		return status;
	}
	std::uint64_t hash = 0;
	status = hash_target_value(canonical, *schema, true, hash);
	if (!status.ok()) {
		return status;
	}
	r_intent.origin = p_intent.origin;
	r_intent.source = p_intent.source;
	r_intent.ability = p_intent.ability;
	r_intent.execution = p_intent.execution;
	r_intent.session = p_intent.session;
	r_intent.schema = p_intent.schema;
	r_intent.schema_version = p_intent.schema_version;
	r_intent.submitted_tick = p_intent.submitted_tick;
	r_intent.value = std::move(canonical);
	r_intent.canonical_hash = hash;
	return ok_status();
}

std::uint64_t GameplayAbilityWorldCoordinator::state_fingerprint(
		const AbilityComponent &p_component) const {
	SnapshotWriter writer;
	if (!p_component.write_snapshot(writer).ok()) {
		return 0;
	}
	return writer.digest();
}

Status GameplayAbilityWorldCoordinator::invoke_provider(
		const CanonicalTargetIntent &p_intent, Tick p_tick,
		ValidatedTargetData &r_data) {
	r_data = ValidatedTargetData{};
	if (authority_provider_running) {
		return make_status(StatusCode::CAPABILITY_VIOLATION,
				DiagnosticId::HOOK_CAPABILITY_DENIED,
				p_intent.source.value);
	}
	const TargetSchema *schema = schemas->find(p_intent.schema);
	if (schema == nullptr) {
		return make_status(StatusCode::UNKNOWN_TARGET_SCHEMA,
				DiagnosticId::DEFINITION_UNKNOWN_REFERENCE,
				p_intent.schema);
	}
	Status status = validate_provider_for_schema(*schema);
	if (!status.ok()) {
		return status;
	}
	auto provider_it = authority_providers.find(
			schema->desc.authority_provider);
	const AuthorityTargetProvider *provider =
			provider_it->second.provider;

	struct ProviderGuardCapture {
		EntityId entity = INVALID_ENTITY_ID;
		AbilityComponent *component = nullptr;
		AbilityComponentBatchCapture state;
		std::uint64_t fingerprint = 0;
	};
	std::vector<ProviderGuardCapture> before;
	before.reserve(components.size());
	for (const auto &entry : components) {
		if (entry.second.authoritative &&
				entry.second.component != nullptr) {
			ProviderGuardCapture capture;
			capture.entity = entry.first;
			capture.component = entry.second.component;
			Status capture_status =
					capture.component->capture_target_batch_state(
							capture.state);
			if (!capture_status.ok()) {
				for (ProviderGuardCapture &started : before) {
					started.component->
							rollback_target_batch_publication();
				}
				return capture_status;
			}
			capture.fingerprint =
					state_fingerprint(*capture.component);
			capture_status =
					capture.component->
							begin_target_batch_publication();
			if (!capture_status.ok()) {
				for (ProviderGuardCapture &started : before) {
					started.component->
							rollback_target_batch_publication();
				}
				return capture_status;
			}
			before.push_back(std::move(capture));
		}
	}

	TargetProviderContext context;
	context.source = p_intent.source;
	context.ability = p_intent.ability;
	context.execution = p_intent.execution;
	context.session = p_intent.session;
	context.authority_tick = p_tick;
	context.schema = schema;
	context.entity_exists = [this](EntityId p_entity) {
		auto it = components.find(p_entity);
		return it != components.end() &&
				it->second.authoritative &&
				it->second.component != nullptr;
	};
	const std::size_t registered_component_count = components.size();
	TargetProviderOutput output;
	authority_provider_running = true;
	status = provider->resolve(context, p_intent, output);
	authority_provider_running = false;

	EntityId mutated = INVALID_ENTITY_ID;
	if (components.size() != registered_component_count) {
		mutated = p_intent.source;
	}
	for (const ProviderGuardCapture &entry : before) {
		if (find_component(entry.entity) != entry.component ||
				entry.component->
						target_batch_publication_hold_changed() ||
				state_fingerprint(*entry.component) !=
						entry.fingerprint) {
			mutated = entry.entity;
			break;
		}
	}
	if (mutated) {
		bool restored = true;
		// Drop every notification/request the provider attempted before
		// restoring value state, so observers cannot see the forbidden
		// intermediate mutation.
		for (ProviderGuardCapture &entry : before) {
			restored =
					entry.component->
							rollback_target_batch_publication()
									.ok() &&
					restored;
		}
		for (ProviderGuardCapture &entry : before) {
			restored =
					entry.component->
							restore_target_batch_state(entry.state)
									.ok() &&
					restored;
		}
		return make_status(
				restored ? StatusCode::CAPABILITY_VIOLATION :
						   StatusCode::INTERNAL_ERROR,
				restored ? DiagnosticId::HOOK_CAPABILITY_DENIED :
						   DiagnosticId::TARGET_BATCH_ROLLED_BACK,
				mutated.value);
	}
	for (ProviderGuardCapture &entry : before) {
		Status release_status =
				entry.component->
						release_target_batch_publication_hold();
		if (!release_status.ok()) {
			return release_status;
		}
	}
	if (!status.ok()) {
		return provider_rejection(status);
	}
	if (!output.status.ok()) {
		return provider_rejection(output.status);
	}
	if (output.work_units > schema->desc.max_provider_work ||
			output.work_units > provider_it->second.contract.max_work ||
			output.outcomes.size() > MAX_TARGETS_PER_COMMAND) {
		return make_status(StatusCode::CAPACITY_EXCEEDED,
				DiagnosticId::COUNT_LIMIT_EXCEEDED,
				output.work_units);
	}
	TargetValue canonical_result;
	status = normalize_target_value(output.result, *schema, false,
			p_intent.source, canonical_result);
	if (!status.ok()) {
		return make_status(StatusCode::TARGET_PROVIDER_REJECTED,
				status.diagnostic, status.detail);
	}
	std::set<EntityId> outcome_entities;
	std::set<std::uint16_t> outcome_ranks;
	const std::vector<EntityId> result_entities =
			entities_from_result(canonical_result);
	std::map<EntityId, std::uint16_t> result_ranks;
	for (std::size_t i = 0; i < result_entities.size(); ++i) {
		result_ranks.emplace(result_entities[i],
				static_cast<std::uint16_t>(i));
	}
	for (const TargetEntityOutcome &outcome : output.outcomes) {
		const auto result_rank = result_ranks.find(outcome.entity);
		if (!outcome.entity ||
				!outcome_entities.insert(outcome.entity).second ||
				!outcome_ranks.insert(outcome.rank).second ||
				outcome.rank >= MAX_TARGETS_PER_COMMAND ||
				(outcome.kind !=
								TargetEntityOutcomeKind::ACCEPTED &&
						outcome.kind !=
								TargetEntityOutcomeKind::PROVIDER_REJECTED) ||
				(outcome.kind ==
								TargetEntityOutcomeKind::ACCEPTED &&
						(result_rank == result_ranks.end() ||
								result_rank->second !=
										outcome.rank ||
								!outcome.status.ok())) ||
				(outcome.kind ==
								TargetEntityOutcomeKind::PROVIDER_REJECTED &&
						outcome.status.ok())) {
			return make_status(StatusCode::TARGET_PROVIDER_REJECTED,
					DiagnosticId::TARGET_RULE_REJECTED,
					outcome.entity.value);
		}
	}
	r_data = ValidatedTargetData{};
	r_data.authority_owner = this;
	r_data.authority_seal = authority_seal;
	r_data.intent = p_intent;
	r_data.resolved_result = std::move(canonical_result);
	r_data.outcomes = std::move(output.outcomes);
	r_data.source_entity = p_intent.source;
	r_data.ability_definition = p_intent.ability;
	r_data.execution_id = p_intent.execution;
	r_data.session_id = p_intent.session;
	r_data.schema_id = p_intent.schema;
	r_data.version = p_intent.schema_version;
	r_data.validated_tick = p_tick;
	r_data.result_visibility = schema->desc.visibility;
	return ok_status();
}

Status GameplayAbilityWorldCoordinator::resolve_intent(
		const TargetIntent &p_intent, Tick p_tick,
		ValidatedTargetData &r_data) {
	auto component_it = components.find(p_intent.source);
	if (component_it == components.end() ||
			!component_it->second.authoritative ||
			component_it->second.component == nullptr) {
		return make_status(StatusCode::NOT_AUTHORITY,
				DiagnosticId::INVALID_TARGET_PROVENANCE,
				p_intent.source.value);
	}
	CanonicalTargetIntent canonical;
	Status status = normalize_intent(p_intent, canonical);
	if (!status.ok()) {
		return status;
	}
	return invoke_provider(canonical, p_tick, r_data);
}

Status GameplayAbilityWorldCoordinator::resolve_direct(
		const TargetIntent &p_intent, Tick p_tick,
		ValidatedTargetData &r_data) {
	TargetIntent direct = p_intent;
	direct.origin = TargetIntentOrigin::DIRECT_ACTIVATION;
	return resolve_intent(direct, p_tick, r_data);
}

Status GameplayAbilityWorldCoordinator::resolve_gameplay_event(
		const TargetIntent &p_intent, Tick p_tick,
		ValidatedTargetData &r_data) {
	TargetIntent event = p_intent;
	event.origin = TargetIntentOrigin::GAMEPLAY_EVENT;
	return resolve_intent(event, p_tick, r_data);
}

Status GameplayAbilityWorldCoordinator::resolve_ai(
		const TargetIntent &p_intent, Tick p_tick,
		ValidatedTargetData &r_data) {
	TargetIntent ai = p_intent;
	ai.origin = TargetIntentOrigin::AI;
	return resolve_intent(ai, p_tick, r_data);
}

Status GameplayAbilityWorldCoordinator::resolve_test(
		const TargetIntent &p_intent, Tick p_tick,
		ValidatedTargetData &r_data) {
	TargetIntent test = p_intent;
	test.origin = TargetIntentOrigin::TEST;
	return resolve_intent(test, p_tick, r_data);
}

Status GameplayAbilityWorldCoordinator::preview_target(
		EntityId p_source, DefinitionId p_ability,
		ExecutionId p_execution, TargetSessionId p_session,
		DefinitionId p_schema, Tick p_tick,
		LocalTargetPreview &r_preview) {
	r_preview = LocalTargetPreview{};
	if (authority_provider_running) {
		return make_status(StatusCode::CAPABILITY_VIOLATION,
				DiagnosticId::HOOK_CAPABILITY_DENIED,
				p_source.value);
	}
	const TargetSchema *schema = schemas->find(p_schema);
	if (schema == nullptr) {
		return make_status(StatusCode::UNKNOWN_TARGET_SCHEMA,
				DiagnosticId::DEFINITION_UNKNOWN_REFERENCE,
				p_schema);
	}
	if (!schema->desc.preview_allowed) {
		return make_status(StatusCode::NOT_SUPPORTED,
				DiagnosticId::TARGET_PROVIDER_MISMATCH,
				p_schema);
	}
	auto found = preview_providers.find(
			schema->desc.authority_provider);
	if (found == preview_providers.end() ||
			found->second.provider == nullptr) {
		return make_status(StatusCode::INVALID_REFERENCE,
				DiagnosticId::TARGET_PROVIDER_MISMATCH,
				hash_string(schema->desc.authority_provider));
	}
	const TargetProviderContract &contract = found->second.contract;
	if (contract.version !=
					schema->desc.provider_contract_version ||
			contract.intent_kind != schema->desc.intent_kind ||
			contract.result_kind != schema->desc.result_kind) {
		return make_status(StatusCode::INVALID_REFERENCE,
				DiagnosticId::TARGET_PROVIDER_MISMATCH,
				hash_string(contract.identifier));
	}
	TargetProviderContext context;
	context.source = p_source;
	context.ability = p_ability;
	context.execution = p_execution;
	context.session = p_session;
	context.authority_tick = p_tick;
	context.schema = schema;
	context.entity_exists = [this](EntityId p_entity) {
		return has_component(p_entity);
	};
	LocalTargetPreview output;
	authority_provider_running = true;
	Status status = found->second.provider->preview(context, output);
	authority_provider_running = false;
	if (!status.ok()) {
		return status;
	}
	if (!output.status.ok()) {
		return output.status;
	}

	TargetValue presentation;
	status = normalize_target_value(output.presentation_value, *schema,
			false, p_source, presentation);
	if (!status.ok()) {
		return status;
	}
	TargetIntent intent = output.intent;
	intent.source = p_source;
	intent.ability = p_ability;
	intent.execution = p_execution;
	intent.session = p_session;
	intent.schema = p_schema;
	intent.schema_version = schema->desc.schema_version;
	intent.submitted_tick = p_tick;
	CanonicalTargetIntent canonical;
	status = normalize_intent(intent, canonical);
	if (!status.ok()) {
		return status;
	}
	output.presentation_value = std::move(presentation);
	output.intent.origin = canonical.origin;
	output.intent.source = canonical.source;
	output.intent.ability = canonical.ability;
	output.intent.execution = canonical.execution;
	output.intent.session = canonical.session;
	output.intent.schema = canonical.schema;
	output.intent.schema_version = canonical.schema_version;
	output.intent.submitted_tick = canonical.submitted_tick;
	output.intent.value = canonical.value;
	r_preview = std::move(output);
	return ok_status();
}

TargetSessionStartResult
GameplayAbilityWorldCoordinator::begin_wait_target_data(
		EntityId p_owner, ExecutionId p_execution,
		DefinitionId p_schema, Tick p_tick,
		const TargetValue *p_initial_intent) {
	TargetSessionStartResult result;
	if (authority_provider_running) {
		result.status = make_status(StatusCode::CAPABILITY_VIOLATION,
				DiagnosticId::HOOK_CAPABILITY_DENIED,
				p_owner.value);
		return result;
	}
	AbilityComponent *component = find_component(p_owner);
	const TargetSchema *schema = schemas->find(p_schema);
	if (component == nullptr || schema == nullptr) {
		result.status = make_status(StatusCode::UNKNOWN_TARGET_SCHEMA,
				DiagnosticId::DEFINITION_UNKNOWN_REFERENCE, p_schema);
		return result;
	}
	AbilityTaskRequest request;
	request.kind = AbilityTaskKind::WAIT_TARGET_DATA;
	request.target_schema = p_schema;
	request.visibility =
			schema->desc.visibility == TargetResultVisibility::OWNER_ONLY ?
			AbilityTaskVisibility::OWNER_ONLY :
			(schema->desc.visibility ==
							TargetResultVisibility::OBSERVABLE ?
					AbilityTaskVisibility::OBSERVABLE :
					AbilityTaskVisibility::INTERNAL);
	request.prediction_policy =
			schema->desc.prediction_policy ==
							TargetPredictionPolicy::PREDICTION_SAFE ?
			AbilityTaskPredictionPolicy::PREDICTION_SAFE :
			AbilityTaskPredictionPolicy::AUTHORITY_ONLY;
	if (schema->desc.deadline_ticks > 0) {
		request.has_deadline = true;
		Status tick_status = tick_advance(p_tick,
				schema->desc.deadline_ticks,
				request.deadline_tick);
		if (!tick_status.ok()) {
			result.status = tick_status;
			return result;
		}
	}
	AbilityTaskStartResult task =
			component->start_ability_task(p_execution, request, p_tick);
	result.status = task.status;
	result.task = task.task;
	if (!task.status.ok() || task.terminal) {
		result.terminal = task.terminal;
		return result;
	}
	result = attach_wait_target_data(p_owner, p_execution, task.task,
			p_tick, p_initial_intent);
	if (!result.status.ok()) {
		component->cancel_ability_task(task.task, p_tick,
				AbilityTaskCancelReason::EXPLICIT);
	}
	return result;
}

TargetSessionStartResult
GameplayAbilityWorldCoordinator::attach_wait_target_data(
		EntityId p_owner, ExecutionId p_execution,
		AbilityTaskHandle p_task, Tick p_tick,
		const TargetValue *p_initial_intent) {
	TargetSessionStartResult result;
	result.task = p_task;
	if (authority_provider_running) {
		result.status = make_status(StatusCode::CAPABILITY_VIOLATION,
				DiagnosticId::HOOK_CAPABILITY_DENIED,
				p_owner.value);
		return result;
	}
	AbilityComponent *component = find_component(p_owner);
	if (component == nullptr || !authority_role(component->role())) {
		result.status = make_status(StatusCode::NOT_AUTHORITY,
				DiagnosticId::INVALID_TARGET_PROVENANCE,
				p_owner.value);
		return result;
	}
	const ActiveExecution *execution =
			component->find_execution(p_execution);
	const ActiveAbilityTask *task =
			component->ability_tasks().find(p_task);
	if (execution == nullptr || task == nullptr ||
			task->execution != p_execution ||
			task->request.kind != AbilityTaskKind::WAIT_TARGET_DATA) {
		result.status = make_status(StatusCode::INVALID_ABILITY_TASK,
				DiagnosticId::TASK_PARENT_MISSING,
				p_task.value);
		return result;
	}
	const TargetSchema *schema =
			schemas->find(task->request.target_schema);
	if (schema == nullptr) {
		result.status = make_status(StatusCode::UNKNOWN_TARGET_SCHEMA,
				DiagnosticId::DEFINITION_UNKNOWN_REFERENCE,
				task->request.target_schema);
		return result;
	}
	Status status = validate_provider_for_schema(*schema);
	if (!status.ok()) {
		result.status = status;
		return result;
	}
	if (sessions.size() >= MAX_ACTIVE_TARGET_SESSIONS) {
		result.status = make_status(StatusCode::CAPACITY_EXCEEDED,
				DiagnosticId::COUNT_LIMIT_EXCEEDED,
				sessions.size());
		return result;
	}
	std::size_t execution_sessions = 0;
	for (const auto &entry : sessions) {
		if (entry.second.owner == p_owner &&
				entry.second.execution == p_execution) {
			++execution_sessions;
		}
	}
	if (execution_sessions >= MAX_TARGET_SESSIONS_PER_EXECUTION) {
		result.status = make_status(StatusCode::CAPACITY_EXCEEDED,
				DiagnosticId::COUNT_LIMIT_EXCEEDED,
				execution_sessions);
		return result;
	}

	ActiveTargetSession session;
	session.id = session_allocator.allocate();
	session.owner = p_owner;
	session.ability = execution->ability;
	session.execution = p_execution;
	session.task = p_task;
	session.schema = schema->id;
	session.start_tick = p_tick;
	session.provenance = task->provenance;
	session.prediction_key = task->prediction_key;
	if (task->request.has_deadline) {
		session.has_deadline = true;
		session.deadline_tick = task->request.deadline_tick;
	} else if (schema->desc.deadline_ticks > 0) {
		session.has_deadline = true;
		status = tick_advance(p_tick, schema->desc.deadline_ticks,
				session.deadline_tick);
		if (!status.ok()) {
			result.status = status;
			return result;
		}
	}
	sessions.emplace(session.id, session);
	result.session = session.id;

	TargetSessionEvent requested;
	requested.kind = TargetSessionLifecycleKind::REQUESTED;
	requested.session = session.id;
	requested.owner = session.owner;
	requested.execution = session.execution;
	requested.task = session.task;
	requested.schema = session.schema;
	requested.tick = p_tick;
	emit_session_event(requested);

	if (p_initial_intent != nullptr) {
		TargetSessionCommand command;
		command.kind =
				schema->desc.session_mode == TargetSessionMode::INSTANT ?
				TargetSessionCommandKind::CONFIRM :
				TargetSessionCommandKind::SUBMIT;
		command.owner = p_owner;
		command.execution = p_execution;
		command.task = p_task;
		command.session = session.id;
		command.schema = schema->id;
		command.schema_version = schema->desc.schema_version;
		command.sequence = CommandSeq{ 1 };
		command.tick = p_tick;
		command.has_intent = true;
		command.intent = *p_initial_intent;
		TargetSessionCommandResult command_result =
				submit_session_command(command);
		result.status = command_result.status;
		result.terminal = command_result.terminal;
		result.has_validated_data =
				command_result.has_validated_data;
		result.validated_data =
				command_result.validated_data;
		return result;
	}
	result.status = ok_status();
	return result;
}

void GameplayAbilityWorldCoordinator::emit_session_event(
		const TargetSessionEvent &p_event) {
	for (const auto &listener : session_listeners) {
		listener(p_event);
	}

	// Task 1.4 (add-granular-delta-replication-2026-07-27): cover retained
	// target-session state with the SAME per-audience change tracking as
	// every other section, resolving PUBLIC visibility from the session's
	// OWN schema-declared visibility (`TargetSchemaDesc::visibility`, via
	// `visible_to` above) -- exactly how `AbilityComponent`'s own change
	// tracking resolves ABILITY_TASK visibility from
	// `AbilityTaskRequest::visibility` via `task_visible_to`. This
	// coordinator has no `Transaction`/rollback participation of its own
	// (see file comment), so every event reaching this point already is the
	// durable outcome -- there is nothing to defer or undo, matching
	// `ChangeTracker`'s own "why this class never touches Transaction"
	// reasoning (ga_change_tracking.h). RESTORED replays prior state (see
	// `notify_restored_sessions`), not a new change -- excluded, mirroring
	// this addon's other restore exclusions (`AbilityLifecycleKind::
	// SNAPSHOT_RESTORED`, a restored `AbilityTaskEvent`).
	if (p_event.kind == TargetSessionLifecycleKind::RESTORED) {
		return;
	}
	AbilityComponent *owner_component = find_component(p_event.owner);
	if (owner_component == nullptr) {
		return;
	}
	const TargetSchema *schema = schemas->find(p_event.schema);
	const bool public_visible = schema != nullptr &&
			visible_to(schema->desc.visibility, TargetResultVisibility::OBSERVABLE);
	owner_component->record_target_session_change(p_event.session, public_visible);
}

void GameplayAbilityWorldCoordinator::terminalize_session(
		TargetSessionId p_session, const TargetSessionEvent &p_event,
		CommandSeq p_last_sequence) {
	sessions.erase(p_session);
	terminal_sessions[p_session] =
			TerminalSession{ p_event, p_last_sequence };
	while (terminal_sessions.size() >
			MAX_TARGET_SESSION_TOMBSTONES) {
		terminal_sessions.erase(terminal_sessions.begin());
	}
}

TargetSessionCommandResult
GameplayAbilityWorldCoordinator::resolve_session(
		ActiveTargetSession &p_session,
		const TargetSessionCommand &p_command) {
	TargetSessionCommandResult result;
	const TargetSchema *schema = schemas->find(p_session.schema);

	ValidatedTargetData validated;
	Status status = invoke_provider(p_session.latest_intent,
			p_command.tick, validated);
	TargetSessionEvent event;
	event.session = p_session.id;
	event.owner = p_session.owner;
	event.execution = p_session.execution;
	event.task = p_session.task;
	event.schema = p_session.schema;
	event.tick = p_command.tick;
	event.command_sequence = p_command.sequence;
	event.has_intent = true;
	event.canonical_intent_hash =
			p_session.latest_intent.canonical_hash;
	if (!status.ok()) {
		event.kind = TargetSessionLifecycleKind::REJECTED;
		event.status = status;
		AbilityComponent *component =
				find_component(p_session.owner);
		if (component != nullptr) {
			const TargetEffectContext task_context =
					make_task_target_context(*schema, p_session,
							p_command.tick, status, nullptr);
			component->complete_target_task(p_session.task,
					p_session.id, p_command.tick, status,
					&task_context);
		}
		terminalize_session(p_session.id, event,
				p_command.sequence);
		emit_session_event(event);
		result.status = status;
		result.transitioned = true;
		result.terminal = true;
		result.event = event;
		return result;
	}

	event.kind = TargetSessionLifecycleKind::COMPLETED;
	event.status = ok_status();
	AbilityComponent *component = find_component(p_session.owner);
	if (component == nullptr) {
		status = make_status(StatusCode::UNKNOWN_NETWORK_IDENTITY,
				DiagnosticId::TARGET_NOT_RELEVANT,
				p_session.owner.value);
	} else {
		const TargetEffectContext task_context =
				make_task_target_context(*schema, p_session,
						p_command.tick, ok_status(), &validated);
		const AbilityTaskTransitionResult task_result =
				component->complete_target_task(p_session.task,
						p_session.id, p_command.tick,
						ok_status(), &task_context);
		status = task_result.status;
	}
	if (!status.ok()) {
		event.kind = TargetSessionLifecycleKind::REJECTED;
		event.status = status;
	}
	terminalize_session(p_session.id, event,
			p_command.sequence);
	emit_session_event(event);
	result.status = status;
	result.transitioned = true;
	result.terminal = true;
	result.event = event;
	if (status.ok()) {
		result.has_validated_data = true;
		result.validated_data = validated;
	}
	return result;
}

TargetSessionCommandResult
GameplayAbilityWorldCoordinator::submit_session_command(
		const TargetSessionCommand &p_command) {
	TargetSessionCommandResult result;
	if (authority_provider_running) {
		result.status = make_status(StatusCode::CAPABILITY_VIOLATION,
				DiagnosticId::HOOK_CAPABILITY_DENIED,
				p_command.session.value);
		return result;
	}
	auto terminal = terminal_sessions.find(p_command.session);
	if (terminal != terminal_sessions.end()) {
		result.status = make_status(
				StatusCode::TARGET_SESSION_ALREADY_TERMINAL,
				DiagnosticId::TARGET_SESSION_STALE,
				p_command.session.value);
		result.terminal = true;
		result.duplicate_terminal = true;
		result.event = terminal->second.event;
		return result;
	}
	auto found = sessions.find(p_command.session);
	if (found == sessions.end()) {
		result.status = make_status(StatusCode::UNKNOWN_TARGET_SESSION,
				DiagnosticId::TARGET_SESSION_STALE,
				p_command.session.value);
		return result;
	}
	ActiveTargetSession &session = found->second;
	const TargetSchema *schema = schemas->find(session.schema);
	if (schema == nullptr || p_command.owner != session.owner ||
			p_command.execution != session.execution ||
			p_command.task != session.task ||
			p_command.schema != session.schema ||
			p_command.schema_version != schema->desc.schema_version) {
		result.status = make_status(StatusCode::PERMISSION_DENIED,
				DiagnosticId::TARGET_SESSION_STALE,
				p_command.session.value);
		return result;
	}
	if (!p_command.sequence ||
			p_command.sequence.value <=
					session.last_command_sequence.value) {
		result.status = make_status(StatusCode::DUPLICATE_COMMAND,
				DiagnosticId::SEQUENCE_OUT_OF_ORDER,
				p_command.sequence.value);
		return result;
	}
	if (p_command.sequence.value !=
			session.last_command_sequence.value + 1) {
		result.status = make_status(StatusCode::SEQUENCE_GAP,
				DiagnosticId::SEQUENCE_OUT_OF_ORDER,
				p_command.sequence.value);
		return result;
	}
	if (session.has_deadline &&
			p_command.tick >= session.deadline_tick) {
		advance_to(p_command.tick);
		result.status = make_status(StatusCode::UNKNOWN_TARGET_SESSION,
				DiagnosticId::TARGET_SESSION_STALE,
				p_command.session.value);
		result.terminal = true;
		return result;
	}
	// Spec "Submission rate is exhausted" bounds excessive non-terminal
	// SUBMIT/preview traffic. CONFIRM and CANCEL always resolve the session
	// to a terminal outcome below (see "Owner confirms latest intent" /
	// "Owner cancels selection") -- rejecting the one command that already
	// ends the session for having exceeded a budget meant to bound spam
	// would instead leave it stuck forever whenever `deadline_ticks == 0`
	// (a session's only other exits are its deadline and parent cleanup).
	// Only SUBMIT, which never terminalizes by itself outside INSTANT mode,
	// counts against the budget.
	if (p_command.kind == TargetSessionCommandKind::SUBMIT) {
		if (session.submission_count >= schema->desc.max_submissions) {
			result.status = make_status(StatusCode::RATE_LIMITED,
					DiagnosticId::COUNT_LIMIT_EXCEEDED,
					session.submission_count);
			return result;
		}
		++session.submission_count;
	}
	session.last_command_sequence = p_command.sequence;

	if (p_command.kind == TargetSessionCommandKind::CANCEL) {
		if (schema->desc.session_mode !=
				TargetSessionMode::CONFIRM_OR_CANCEL) {
			result.status = make_status(StatusCode::NOT_SUPPORTED,
					DiagnosticId::INVALID_TARGET_SCHEMA);
			return result;
		}
		TargetSessionEvent event;
		event.kind = TargetSessionLifecycleKind::CANCELLED;
		event.session = session.id;
		event.owner = session.owner;
		event.execution = session.execution;
		event.task = session.task;
		event.schema = session.schema;
		event.tick = p_command.tick;
		event.command_sequence = p_command.sequence;
		event.status = make_status(StatusCode::ABILITY_TASK_CANCELLED);
		AbilityComponent *component = find_component(session.owner);
		if (component != nullptr) {
			component->cancel_ability_task(session.task,
					p_command.tick,
					AbilityTaskCancelReason::
							TARGET_SESSION_CANCELLED);
		}
		terminalize_session(session.id, event,
				p_command.sequence);
		emit_session_event(event);
		result.status = ok_status();
		result.transitioned = true;
		result.terminal = true;
		result.event = event;
		return result;
	}

	if (p_command.has_intent) {
		TargetIntent intent;
		intent.origin = TargetIntentOrigin::ABILITY_TASK;
		intent.source = session.owner;
		intent.ability = session.ability;
		intent.execution = session.execution;
		intent.session = session.id;
		intent.schema = session.schema;
		intent.schema_version = schema->desc.schema_version;
		intent.submitted_tick = p_command.tick;
		intent.value = p_command.intent;
		CanonicalTargetIntent canonical;
		Status status = normalize_intent(intent, canonical);
		if (!status.ok()) {
			result.status = status;
			return result;
		}
		session.latest_intent = std::move(canonical);
		session.has_intent = true;
		TargetSessionEvent submitted;
		submitted.kind =
				TargetSessionLifecycleKind::INTENT_SUBMITTED;
		submitted.session = session.id;
		submitted.owner = session.owner;
		submitted.execution = session.execution;
		submitted.task = session.task;
		submitted.schema = session.schema;
		submitted.tick = p_command.tick;
		submitted.command_sequence = p_command.sequence;
		submitted.has_intent = true;
		submitted.canonical_intent_hash =
				session.latest_intent.canonical_hash;
		emit_session_event(submitted);
		result.transitioned = true;
		result.event = submitted;
	}

	const bool resolve_now =
			schema->desc.session_mode == TargetSessionMode::INSTANT ||
			p_command.kind == TargetSessionCommandKind::CONFIRM;
	if (!resolve_now) {
		result.status = ok_status();
		return result;
	}
	if (!session.has_intent) {
		result.status = make_status(StatusCode::INVALID_TARGET_DATA,
				DiagnosticId::TARGET_SESSION_STALE);
		return result;
	}
	return resolve_session(session, p_command);
}

std::vector<TargetSessionCommandResult>
GameplayAbilityWorldCoordinator::submit_session_commands(
		std::vector<TargetSessionCommand> p_commands) {
	std::stable_sort(p_commands.begin(), p_commands.end(),
			[](const TargetSessionCommand &p_a,
					const TargetSessionCommand &p_b) {
				if (p_a.tick != p_b.tick) {
					return p_a.tick < p_b.tick;
				}
				if (p_a.session != p_b.session) {
					return p_a.session < p_b.session;
				}
				const int a_priority =
						command_priority(p_a.kind);
				const int b_priority =
						command_priority(p_b.kind);
				if (a_priority != b_priority) {
					return a_priority < b_priority;
				}
				return p_a.sequence < p_b.sequence;
			});
	std::vector<TargetSessionCommandResult> results;
	results.reserve(p_commands.size());
	for (const TargetSessionCommand &command : p_commands) {
		results.push_back(submit_session_command(command));
	}
	return results;
}

void GameplayAbilityWorldCoordinator::prune_stale_sessions(Tick p_tick) {
	std::vector<TargetSessionId> stale;
	for (const auto &entry : sessions) {
		AbilityComponent *component =
				find_component(entry.second.owner);
		if (component == nullptr ||
				component->find_execution(entry.second.execution) ==
						nullptr ||
				component->ability_tasks().find(entry.second.task) ==
						nullptr) {
			stale.push_back(entry.first);
		}
	}
	for (TargetSessionId id : stale) {
		auto it = sessions.find(id);
		if (it == sessions.end()) {
			continue;
		}
		TargetSessionEvent event;
		event.kind =
				it->second.has_deadline &&
						p_tick >= it->second.deadline_tick ?
				TargetSessionLifecycleKind::TIMED_OUT :
				TargetSessionLifecycleKind::CANCELLED;
		event.session = id;
		event.owner = it->second.owner;
		event.execution = it->second.execution;
		event.task = it->second.task;
		event.schema = it->second.schema;
		event.tick = p_tick;
		event.status =
				event.kind == TargetSessionLifecycleKind::TIMED_OUT ?
				make_status(StatusCode::ABILITY_TASK_TIMED_OUT,
						DiagnosticId::TASK_DEADLINE_INVALID) :
				make_status(StatusCode::ABILITY_TASK_CANCELLED,
						DiagnosticId::TASK_PARENT_MISSING);
		terminalize_session(id, event,
				it->second.last_command_sequence);
		emit_session_event(event);
	}
}

Status GameplayAbilityWorldCoordinator::advance_to(Tick p_tick) {
	if (authority_provider_running) {
		return make_status(StatusCode::CAPABILITY_VIOLATION,
				DiagnosticId::HOOK_CAPABILITY_DENIED);
	}
	std::set<EntityId> due_owners;
	for (const auto &entry : sessions) {
		if (entry.second.has_deadline &&
				entry.second.deadline_tick <= p_tick) {
			due_owners.insert(entry.second.owner);
		}
	}
	for (EntityId owner : due_owners) {
		AbilityComponent *component = find_component(owner);
		if (component != nullptr) {
			Status status = component->advance_to(p_tick);
			if (!status.ok()) {
				return status;
			}
		}
	}
	prune_stale_sessions(p_tick);
	return ok_status();
}

const ActiveTargetSession *
GameplayAbilityWorldCoordinator::find_session(
		TargetSessionId p_session) const {
	auto it = sessions.find(p_session);
	return it == sessions.end() ? nullptr : &it->second;
}

std::vector<TargetSessionId>
GameplayAbilityWorldCoordinator::active_sessions() const {
	std::vector<TargetSessionId> result;
	result.reserve(sessions.size());
	for (const auto &entry : sessions) {
		result.push_back(entry.first);
	}
	return result;
}

void GameplayAbilityWorldCoordinator::add_session_listener(
		std::function<void(const TargetSessionEvent &)> p_listener) {
	session_listeners.push_back(std::move(p_listener));
}

void GameplayAbilityWorldCoordinator::notify_restored_sessions(
		Tick p_tick, EntityId p_owner_filter) {
	for (const auto &entry : sessions) {
		const ActiveTargetSession &session = entry.second;
		if (p_owner_filter &&
				session.owner != p_owner_filter) {
			continue;
		}
		TargetSessionEvent event;
		event.kind = TargetSessionLifecycleKind::RESTORED;
		event.session = session.id;
		event.owner = session.owner;
		event.execution = session.execution;
		event.task = session.task;
		event.schema = session.schema;
		event.tick = p_tick;
		event.has_intent = session.has_intent;
		event.canonical_intent_hash =
				session.has_intent ?
				session.latest_intent.canonical_hash : 0;
		emit_session_event(event);
	}
}

Status GameplayAbilityWorldCoordinator::write_snapshot(
		SnapshotWriter &p_writer,
		TargetResultVisibility p_audience,
		EntityId p_owner_filter) const {
	if (!p_writer.begin_section(
				GA_SNAPSHOT_KIND_TARGET_COORDINATOR)) {
		return p_writer.status();
	}
	p_writer.write_u8(TARGET_SESSION_SNAPSHOT_VERSION);
	p_writer.write_u64(session_allocator.next_raw());
	std::vector<const ActiveTargetSession *> visible;
	for (const auto &entry : sessions) {
		const TargetSchema *schema =
				schemas->find(entry.second.schema);
		if (schema != nullptr &&
				(!p_owner_filter ||
						entry.second.owner == p_owner_filter) &&
				visible_to(schema->desc.visibility, p_audience)) {
			visible.push_back(&entry.second);
		}
	}
	p_writer.write_count(visible.size(),
			MAX_ACTIVE_TARGET_SESSIONS);
	for (const ActiveTargetSession *session : visible) {
		const TargetSchema *schema =
				schemas->find(session->schema);
		if (!p_writer.begin_section(
					GA_SNAPSHOT_KIND_TARGET_SESSION)) {
			return p_writer.status();
		}
		p_writer.write_u64(session->id.value);
		p_writer.write_u64(session->owner.value);
		p_writer.write_u32(session->ability);
		p_writer.write_u64(session->execution.value);
		p_writer.write_u64(session->task.value);
		p_writer.write_u32(session->schema);
		p_writer.write_u64(session->start_tick);
		p_writer.write_bool(session->has_deadline);
		p_writer.write_u64(session->deadline_tick);
		p_writer.write_u64(
				session->last_command_sequence.value);
		p_writer.write_u16(session->submission_count);
		p_writer.write_bool(session->has_intent);
		if (session->has_intent) {
			std::vector<std::uint8_t> bytes;
			Status status = encode_target_value(
					session->latest_intent.value,
					*schema, true, bytes);
			if (!status.ok()) {
				return status;
			}
			p_writer.write_count(bytes.size(),
					schema->desc.max_payload_bytes);
			for (std::uint8_t byte : bytes) {
				p_writer.write_u8(byte);
			}
			p_writer.write_u64(
					session->latest_intent.submitted_tick);
			p_writer.write_u64(
					session->latest_intent.canonical_hash);
		}
		p_writer.write_u8(static_cast<std::uint8_t>(
				session->provenance));
		p_writer.write_u64(session->prediction_key.value);
		if (!p_writer.end_section()) {
			return p_writer.status();
		}
	}
	if (!p_writer.end_section()) {
		return p_writer.status();
	}
	return p_writer.ok() ? ok_status() : p_writer.status();
}

Status GameplayAbilityWorldCoordinator::restore_snapshot(
		SnapshotReader &p_reader) {
	if (authority_provider_running) {
		return make_status(StatusCode::CAPABILITY_VIOLATION,
				DiagnosticId::HOOK_CAPABILITY_DENIED);
	}
	if (!p_reader.begin_section(
				GA_SNAPSHOT_KIND_TARGET_COORDINATOR)) {
		return p_reader.status();
	}
	std::uint8_t version = 0;
	std::uint64_t allocator_raw = 0;
	std::size_t count = 0;
	if (!p_reader.read_u8(version) ||
			version != TARGET_SESSION_SNAPSHOT_VERSION ||
			!p_reader.read_u64(allocator_raw) ||
			!p_reader.read_count(count,
					MAX_ACTIVE_TARGET_SESSIONS)) {
		return p_reader.status().ok() ?
				make_status(StatusCode::DECODE_FAILED,
						DiagnosticId::PROTOCOL_VERSION_DIFFERS,
						version) :
				p_reader.status();
	}
	std::map<TargetSessionId, ActiveTargetSession> restored;
	std::uint64_t max_session = 0;
	for (std::size_t i = 0; i < count; ++i) {
		if (!p_reader.begin_section(
					GA_SNAPSHOT_KIND_TARGET_SESSION)) {
			return p_reader.status();
		}
		ActiveTargetSession session;
		std::uint64_t session_raw = 0;
		std::uint64_t owner_raw = 0;
		std::uint32_t ability_raw = 0;
		std::uint64_t execution_raw = 0;
		std::uint64_t task_raw = 0;
		std::uint32_t schema_raw = 0;
		std::uint64_t sequence_raw = 0;
		std::uint8_t provenance_raw = 0;
		std::uint64_t prediction_raw = 0;
		if (!p_reader.read_u64(session_raw) ||
				!p_reader.read_u64(owner_raw) ||
				!p_reader.read_u32(ability_raw) ||
				!p_reader.read_u64(execution_raw) ||
				!p_reader.read_u64(task_raw) ||
				!p_reader.read_u32(schema_raw) ||
				!p_reader.read_u64(session.start_tick) ||
				!p_reader.read_bool(session.has_deadline) ||
				!p_reader.read_u64(session.deadline_tick) ||
				!p_reader.read_u64(sequence_raw) ||
				!p_reader.read_u16(session.submission_count) ||
				!p_reader.read_bool(session.has_intent)) {
			return p_reader.status();
		}
		session.id = TargetSessionId{ session_raw };
		session.owner = EntityId{ owner_raw };
		session.ability = ability_raw;
		session.execution = ExecutionId{ execution_raw };
		session.task = AbilityTaskHandle{ task_raw };
		session.schema = schema_raw;
		session.last_command_sequence =
				CommandSeq{ sequence_raw };
		const TargetSchema *schema = schemas->find(session.schema);
		AbilityComponent *component =
				find_component(session.owner);
		const ActiveAbilityTask *task =
				component == nullptr ? nullptr :
				component->ability_tasks().find(session.task);
		if (!session.id || schema == nullptr ||
				component == nullptr ||
				component->find_execution(session.execution) ==
						nullptr ||
				task == nullptr ||
				task->request.kind !=
						AbilityTaskKind::WAIT_TARGET_DATA ||
				task->request.target_schema != session.schema ||
				session.submission_count >
						schema->desc.max_submissions) {
			return make_status(StatusCode::DECODE_FAILED,
					DiagnosticId::TARGET_SESSION_STALE,
					session_raw);
		}
		if (session.has_intent) {
			std::size_t byte_count = 0;
			if (!p_reader.read_count(byte_count,
						schema->desc.max_payload_bytes)) {
				return p_reader.status();
			}
			std::vector<std::uint8_t> bytes;
			bytes.reserve(byte_count);
			for (std::size_t b = 0; b < byte_count; ++b) {
				std::uint8_t byte = 0;
				if (!p_reader.read_u8(byte)) {
					return p_reader.status();
				}
				bytes.push_back(byte);
			}
			TargetValue value;
			Status status = decode_target_value(bytes, *schema,
					true, value);
			if (!status.ok()) {
				return status;
			}
			session.latest_intent.origin =
					TargetIntentOrigin::ABILITY_TASK;
			session.latest_intent.source = session.owner;
			session.latest_intent.ability = session.ability;
			session.latest_intent.execution =
					session.execution;
			session.latest_intent.session = session.id;
			session.latest_intent.schema = session.schema;
			session.latest_intent.schema_version =
					schema->desc.schema_version;
			session.latest_intent.value = std::move(value);
			if (!p_reader.read_u64(
						session.latest_intent.submitted_tick) ||
					!p_reader.read_u64(
							session.latest_intent.canonical_hash)) {
				return p_reader.status();
			}
			std::uint64_t expected_hash = 0;
			status = hash_target_value(
					session.latest_intent.value, *schema,
					true, expected_hash);
			if (!status.ok() ||
					expected_hash !=
							session.latest_intent.canonical_hash) {
				return make_status(StatusCode::DECODE_FAILED,
						DiagnosticId::INVALID_TARGET_PROVENANCE,
						session_raw);
			}
		}
		if (!p_reader.read_u8(provenance_raw) ||
				!p_reader.read_u64(prediction_raw) ||
				!p_reader.end_section()) {
			return p_reader.status();
		}
		if (provenance_raw >
				static_cast<std::uint8_t>(
						ChangeProvenance::PREDICTED)) {
			return make_status(StatusCode::DECODE_FAILED,
					DiagnosticId::INVALID_ENUM,
					provenance_raw);
		}
		session.provenance =
				static_cast<ChangeProvenance>(provenance_raw);
		session.prediction_key =
				PredictionKey{ prediction_raw };
		if (restored.find(session.id) != restored.end()) {
			return make_status(StatusCode::DECODE_FAILED,
					DiagnosticId::DEFINITION_DUPLICATE,
					session.id.value);
		}
		restored.emplace(session.id, std::move(session));
		max_session = std::max(max_session, session_raw);
	}
	if (!p_reader.end_section()) {
		return p_reader.status();
	}
	if (allocator_raw < max_session) {
		return make_status(StatusCode::DECODE_FAILED,
				DiagnosticId::SEQUENCE_OUT_OF_ORDER,
				allocator_raw);
	}
	sessions = std::move(restored);
	terminal_sessions.clear();
	session_allocator.restore_exact(allocator_raw);
	return ok_status();
}

Status GameplayAbilityWorldCoordinator::restore_owner_snapshot(
		SnapshotReader &p_reader, EntityId p_owner) {
	if (!p_owner) {
		return make_status(StatusCode::INVALID_ARGUMENT,
				DiagnosticId::TARGET_NOT_RELEVANT);
	}
	const auto original_sessions = sessions;
	const auto original_terminal = terminal_sessions;
	const std::uint64_t original_allocator =
			session_allocator.next_raw();
	Status status = restore_snapshot(p_reader);
	if (!status.ok()) {
		return status;
	}
	for (const auto &entry : sessions) {
		if (entry.second.owner != p_owner) {
			sessions = original_sessions;
			terminal_sessions = original_terminal;
			session_allocator.restore_exact(original_allocator);
			return make_status(StatusCode::DECODE_FAILED,
					DiagnosticId::INVALID_TARGET_PROVENANCE,
					entry.second.owner.value);
		}
	}
	std::map<TargetSessionId, ActiveTargetSession> merged;
	for (const auto &entry : original_sessions) {
		if (entry.second.owner != p_owner) {
			merged.emplace(entry);
		}
	}
	for (const auto &entry : sessions) {
		if (!merged.emplace(entry).second) {
			sessions = original_sessions;
			terminal_sessions = original_terminal;
			session_allocator.restore_exact(original_allocator);
			return make_status(StatusCode::DECODE_FAILED,
					DiagnosticId::DEFINITION_DUPLICATE,
					entry.first.value);
		}
	}
	std::map<TargetSessionId, TerminalSession> retained_terminal;
	for (const auto &entry : original_terminal) {
		if (entry.second.event.owner != p_owner) {
			retained_terminal.emplace(entry);
		}
	}
	sessions = std::move(merged);
	terminal_sessions = std::move(retained_terminal);
	session_allocator.restore_exact(std::max(original_allocator,
			session_allocator.next_raw()));
	return ok_status();
}

bool GameplayAbilityWorldCoordinator::validated_by_this(
		const ValidatedTargetData &p_data) const {
	return p_data.authority_owner == this &&
			p_data.authority_seal == authority_seal &&
			p_data.valid();
}

std::vector<EntityId>
GameplayAbilityWorldCoordinator::entities_from_result(
		const TargetValue &p_value) const {
	std::vector<EntityId> entities;
	if (p_value.kind == TargetValueKind::ENTITY_SET) {
		entities = p_value.entities;
	} else if (p_value.kind == TargetValueKind::HIT_SET) {
		std::set<EntityId> seen;
		for (const TargetHit &hit : p_value.hits) {
			if (hit.has_entity && seen.insert(hit.entity).second) {
				entities.push_back(hit.entity);
			}
		}
	}
	return entities;
}

Status GameplayAbilityWorldCoordinator::prepare_batch(
		const TargetBatchRequest &p_request,
		PreparedTargetBatch &r_batch) {
	r_batch = PreparedTargetBatch{};
	if (authority_provider_running) {
		r_batch.preparation_status =
				make_status(StatusCode::CAPABILITY_VIOLATION,
						DiagnosticId::HOOK_CAPABILITY_DENIED);
		return r_batch.preparation_status;
	}
	if (in_flight_batch != INVALID_TARGET_BATCH_ID) {
		r_batch.preparation_status =
				make_status(StatusCode::CAPABILITY_VIOLATION,
						DiagnosticId::TARGET_BATCH_IN_FLIGHT,
						in_flight_batch.value);
		return r_batch.preparation_status;
	}
	if (!validated_by_this(p_request.validated_data)) {
		r_batch.preparation_status =
				make_status(StatusCode::PERMISSION_DENIED,
						DiagnosticId::INVALID_TARGET_PROVENANCE);
		return r_batch.preparation_status;
	}
	const TargetSchema *schema =
			schemas->find(p_request.validated_data.schema());
	if (schema == nullptr ||
			schema->desc.schema_version !=
					p_request.validated_data.schema_version()) {
		r_batch.preparation_status =
				make_status(StatusCode::UNKNOWN_TARGET_SCHEMA,
						DiagnosticId::INVALID_TARGET_SCHEMA);
		return r_batch.preparation_status;
	}
	AbilityComponent *source =
			find_component(p_request.validated_data.source());
	if (source == nullptr || !authority_role(source->role()) ||
			(p_request.validated_data.execution() &&
					source->find_execution(
							p_request.validated_data.execution()) ==
							nullptr)) {
		r_batch.preparation_status =
				make_status(StatusCode::NOT_AUTHORITY,
						DiagnosticId::INVALID_TARGET_PROVENANCE);
		return r_batch.preparation_status;
	}
	if (p_request.source_effects.size() +
					p_request.target_effects.size() >
			MAX_EFFECT_MODIFIERS) {
		r_batch.preparation_status =
				make_status(StatusCode::CAPACITY_EXCEEDED,
						DiagnosticId::COUNT_LIMIT_EXCEEDED);
		return r_batch.preparation_status;
	}

	r_batch.owner = this;
	r_batch.seal = authority_seal;
	r_batch.batch_id = batch_allocator.allocate();
	r_batch.source = p_request.validated_data.source();
	r_batch.schema = schema->id;
	r_batch.tick = p_request.tick;
	r_batch.target_outcomes =
			p_request.validated_data.provider_outcomes();
	auto make_context = [&p_request, schema](EntityId p_target,
			std::uint16_t p_rank, Status p_status) {
		TargetEffectContext context;
		context.present = true;
		context.schema = schema->id;
		context.schema_version = schema->desc.schema_version;
		context.source = p_request.validated_data.source();
		context.target = p_target;
		context.ability = p_request.validated_data.ability();
		context.execution =
				p_request.validated_data.execution();
		context.session = p_request.validated_data.session();
		context.authority_tick =
				p_request.validated_data.authority_tick();
		context.target_rank = p_rank;
		context.accepted = p_status.ok();
		context.target_status = p_status;
		context.visibility = schema->desc.visibility;
		context.canonical_intent =
				p_request.validated_data.canonical_intent().value;
		context.validated_result =
				p_request.validated_data.result();
		return context;
	};

	std::map<EntityId, std::size_t> provider_outcome_indexes;
	for (std::size_t i = 0; i < r_batch.target_outcomes.size();
			++i) {
		provider_outcome_indexes.emplace(
				r_batch.target_outcomes[i].entity, i);
	}

	const std::vector<EntityId> candidates =
			entities_from_result(
					p_request.validated_data.result());
	std::vector<EntityId> accepted;
	std::size_t ordinal = 0;
	for (std::size_t rank = 0; rank < candidates.size(); ++rank) {
		const EntityId entity = candidates[rank];
		auto provider_outcome =
				provider_outcome_indexes.find(entity);
		if (provider_outcome != provider_outcome_indexes.end() &&
				r_batch.target_outcomes[provider_outcome->second].kind !=
						TargetEntityOutcomeKind::ACCEPTED) {
			continue;
		}
		TargetEntityOutcome outcome;
		outcome.entity = entity;
		outcome.rank = static_cast<std::uint16_t>(rank);
		std::vector<PendingRemoteEffectCommand> commands;
		std::vector<PreparedEffectApplication> prepared_effects;
		AbilityComponent *target = find_component(entity);
		if (target == nullptr || !authority_role(target->role())) {
			outcome.kind =
					TargetEntityOutcomeKind::COMPONENT_MISSING;
			outcome.status =
					make_status(StatusCode::UNKNOWN_NETWORK_IDENTITY,
							DiagnosticId::TARGET_NOT_RELEVANT,
							entity.value);
		} else {
			outcome.kind = TargetEntityOutcomeKind::ACCEPTED;
			for (const TargetEffectApplication &application :
					p_request.target_effects) {
				PendingRemoteEffectCommand command;
				command.source = r_batch.source;
				command.target = entity;
				command.effect_definition =
						application.effect_definition;
				command.level = application.level;
				command.set_by_caller =
						application.set_by_caller;
				command.originating_execution =
						p_request.validated_data.execution();
				command.tick = p_request.tick;
				command.target_context = make_context(entity,
						static_cast<std::uint16_t>(rank),
						ok_status());
				PreparedEffectApplication prepared;
				Status status = target->prepare_remote_effect(
						command, p_request.tick,
						&source->attributes(), &source->tags(),
						prepared);
				if (!status.ok()) {
					outcome.kind =
							TargetEntityOutcomeKind::EFFECT_REJECTED;
					outcome.status = status;
					break;
				}
				commands.push_back(std::move(command));
				prepared_effects.push_back(std::move(prepared));
			}
		}
		if (provider_outcome != provider_outcome_indexes.end()) {
			r_batch.target_outcomes[provider_outcome->second] =
					outcome;
		} else {
			provider_outcome_indexes.emplace(entity,
					r_batch.target_outcomes.size());
			r_batch.target_outcomes.push_back(outcome);
		}
		if (outcome.kind == TargetEntityOutcomeKind::ACCEPTED) {
			accepted.push_back(entity);
			for (std::size_t i = 0; i < commands.size(); ++i) {
				PreparedTargetBatch::Operation operation;
				operation.command = std::move(commands[i]);
				operation.prepared =
						std::move(prepared_effects[i]);
				operation.ordinal = ordinal++;
				r_batch.operations.push_back(
						std::move(operation));
			}
		}
	}

	bool rejected = false;
	for (const TargetEntityOutcome &outcome :
			r_batch.target_outcomes) {
		rejected = rejected ||
				outcome.kind != TargetEntityOutcomeKind::ACCEPTED;
	}
	if ((schema->desc.acceptance_policy ==
						TargetAcceptancePolicy::REQUIRE_ALL &&
				rejected) ||
			(schema->desc.acceptance_policy ==
							TargetAcceptancePolicy::REQUIRE_ANY &&
					accepted.empty())) {
		r_batch.operations.clear();
		r_batch.preparation_status =
				make_status(StatusCode::TARGET_BATCH_REJECTED,
						DiagnosticId::TARGET_RULE_REJECTED);
		return r_batch.preparation_status;
	}
	if (accepted.empty() &&
			schema->desc.acceptance_policy !=
					TargetAcceptancePolicy::ALLOW_EMPTY &&
			!p_request.target_effects.empty()) {
		r_batch.operations.clear();
		r_batch.preparation_status =
				make_status(StatusCode::TARGET_BATCH_REJECTED,
						DiagnosticId::TARGET_RULE_REJECTED);
		return r_batch.preparation_status;
	}

	for (const TargetEffectApplication &application :
			p_request.source_effects) {
		PendingRemoteEffectCommand command;
		command.source = r_batch.source;
		command.target = r_batch.source;
		command.effect_definition = application.effect_definition;
		command.level = application.level;
		command.set_by_caller = application.set_by_caller;
		command.originating_execution =
				p_request.validated_data.execution();
		command.tick = p_request.tick;
		command.target_context = make_context(r_batch.source, 0,
				ok_status());
		PreparedEffectApplication prepared;
		Status status = source->prepare_remote_effect(command,
				p_request.tick, &source->attributes(),
				&source->tags(), prepared);
		if (!status.ok()) {
			r_batch.operations.clear();
			r_batch.preparation_status =
					make_status(StatusCode::TARGET_BATCH_REJECTED,
							status.diagnostic, status.detail);
			return r_batch.preparation_status;
		}
		PreparedTargetBatch::Operation operation;
		operation.command = std::move(command);
		operation.prepared = std::move(prepared);
		operation.ordinal = ordinal++;
		r_batch.operations.push_back(std::move(operation));
	}

	std::stable_sort(r_batch.operations.begin(),
			r_batch.operations.end(),
			[](const PreparedTargetBatch::Operation &p_a,
					const PreparedTargetBatch::Operation &p_b) {
				if (p_a.command.target != p_b.command.target) {
					return p_a.command.target <
							p_b.command.target;
				}
				return p_a.ordinal < p_b.ordinal;
			});
	std::set<EntityId> participants;
	participants.insert(r_batch.source);
	for (const auto &operation : r_batch.operations) {
		participants.insert(operation.command.target);
	}
	if (participants.size() >
			MAX_TARGET_BATCH_PARTICIPANTS) {
		r_batch.operations.clear();
		r_batch.preparation_status =
				make_status(StatusCode::CAPACITY_EXCEEDED,
						DiagnosticId::COUNT_LIMIT_EXCEEDED,
						participants.size());
		return r_batch.preparation_status;
	}
	r_batch.participant_entities.assign(participants.begin(),
			participants.end());
	r_batch.preparation_status = ok_status();
	// Only a batch that actually reaches this success path occupies the
	// single in-flight slot -- every earlier `return` above left it
	// untouched, since a rejected preparation never becomes a live prepared
	// batch a caller could commit. `commit_batch`/`discard_batch` clear it.
	in_flight_batch = r_batch.batch_id;
	return ok_status();
}

TargetBatchCommitResult
GameplayAbilityWorldCoordinator::commit_batch(
		PreparedTargetBatch &p_batch) {
	TargetBatchCommitResult result;
	result.batch = p_batch.batch_id;
	result.outcomes = p_batch.target_outcomes;
	if (authority_provider_running) {
		result.status = make_status(StatusCode::CAPABILITY_VIOLATION,
				DiagnosticId::HOOK_CAPABILITY_DENIED,
				p_batch.batch_id.value);
		return result;
	}
	if (p_batch.owner != this ||
			p_batch.seal != authority_seal ||
			!p_batch.preparation_status.ok() ||
			p_batch.committed ||
			p_batch.discarded ||
			p_batch.batch_id != in_flight_batch) {
		result.status = make_status(StatusCode::TARGET_BATCH_REJECTED,
				DiagnosticId::INVALID_TARGET_PROVENANCE,
				p_batch.batch_id.value);
		return result;
	}
	// `p_batch` is confirmed to be the one coordinator-tracked in-flight
	// batch: release the slot now, before any further work, so every path
	// below (success or an internal rollback) leaves the coordinator free to
	// prepare the next batch rather than wedging it on a mid-commit failure.
	in_flight_batch = INVALID_TARGET_BATCH_ID;
	AbilityComponent *source = find_component(p_batch.source);
	if (source == nullptr) {
		result.status = make_status(StatusCode::UNKNOWN_NETWORK_IDENTITY,
				DiagnosticId::TARGET_NOT_RELEVANT,
				p_batch.source.value);
		return result;
	}

	struct Participant {
		EntityId entity;
		AbilityComponent *component = nullptr;
		AbilityComponentBatchCapture capture;
		bool captured = false;
		PreparedAbilityComponentMutation mutation;
	};
	std::vector<Participant> participants;
	participants.reserve(p_batch.participant_entities.size());
	for (EntityId entity : p_batch.participant_entities) {
		AbilityComponent *component = find_component(entity);
		if (component == nullptr) {
			result.status = make_status(
					StatusCode::UNKNOWN_NETWORK_IDENTITY,
					DiagnosticId::TARGET_NOT_RELEVANT,
					entity.value);
			return result;
		}
		participants.push_back(
				Participant{ entity, component, {}, false, {} });
	}

	auto rollback_all = [&participants, &result]() {
		bool restored = true;
		for (auto it = participants.rbegin();
				it != participants.rend(); ++it) {
			if (it->mutation.transaction != nullptr &&
					!it->mutation.committed) {
				restored = it->component
						->rollback_prepared_effect_mutation(
								it->mutation)
								   .ok() &&
						restored;
			} else if (it->mutation.transaction != nullptr) {
				restored = it->component
								   ->rollback_target_batch_publication()
								   .ok() &&
						restored;
			}
		}
		// A transaction normally rolls itself back. The full captures are
		// the invariant-recovery layer: they also restore participants whose
		// transaction had already committed and discarded its undo list.
		for (auto it = participants.rbegin();
				it != participants.rend(); ++it) {
			if (it->captured) {
				restored =
						it->component
								->restore_target_batch_state(
										it->capture)
								.ok() &&
						restored;
			}
		}
		result.applied_effects.clear();
		result.rolled_back = true;
		if (!restored) {
			result.status = make_status(StatusCode::INTERNAL_ERROR,
					DiagnosticId::TARGET_BATCH_ROLLED_BACK);
		}
	};

	for (Participant &participant : participants) {
		Status status =
				participant.component->capture_target_batch_state(
						participant.capture);
		if (!status.ok()) {
			result.status = status;
			rollback_all();
			return result;
		}
		participant.captured = true;
		status =
				participant.component
						->begin_prepared_effect_mutation(
								p_batch.tick,
								participant.mutation);
		if (!status.ok()) {
			result.status = status;
			rollback_all();
			return result;
		}
	}

	for (const auto &operation : p_batch.operations) {
		auto participant = std::lower_bound(participants.begin(),
				participants.end(), operation.command.target,
				[](const Participant &p_participant,
						EntityId p_entity) {
					return p_participant.entity < p_entity;
				});
		if (participant == participants.end() ||
				participant->entity != operation.command.target) {
			result.status = make_status(StatusCode::INTERNAL_ERROR,
					DiagnosticId::TARGET_BATCH_ROLLED_BACK);
			rollback_all();
			return result;
		}
		EffectHandle handle;
		Status status =
				participant->component->apply_prepared_effect(
						operation.prepared, p_batch.tick,
						&source->attributes(), &source->tags(),
						participant->mutation, handle);
		if (!status.ok()) {
			result.status = make_status(
					StatusCode::TARGET_BATCH_REJECTED,
					DiagnosticId::TARGET_BATCH_ROLLED_BACK,
					status.detail);
			rollback_all();
			return result;
		}
		result.applied_effects.push_back(AppliedTargetEffect{
				operation.command.target,
				operation.command.effect_definition, handle });
	}
	for (const Participant &participant : participants) {
		if (!participant.component
						->can_commit_prepared_effect_mutation(
								participant.mutation)) {
			result.status = make_status(StatusCode::CAPACITY_EXCEEDED,
					DiagnosticId::TARGET_BATCH_ROLLED_BACK);
			rollback_all();
			return result;
		}
	}
	for (Participant &participant : participants) {
		Status status =
				participant.component
						->commit_prepared_effect_mutation(
								participant.mutation);
		if (!status.ok()) {
			// All queue capacities were checked above. Reaching this path is
			// an invariant failure; held publication is still discarded.
			result.status = make_status(StatusCode::INTERNAL_ERROR,
					DiagnosticId::TARGET_BATCH_ROLLED_BACK,
					status.detail);
			rollback_all();
			return result;
		}
	}
	for (Participant &participant : participants) {
		Status status =
				participant.component
						->commit_target_batch_publication(
								p_batch.tick);
		if (!status.ok()) {
			result.status = status;
			return result;
		}
	}
	p_batch.committed = true;
	result.status = ok_status();
	result.committed = true;
	return result;
}

Status GameplayAbilityWorldCoordinator::discard_batch(
		PreparedTargetBatch &p_batch) {
	if (authority_provider_running) {
		return make_status(StatusCode::CAPABILITY_VIOLATION,
				DiagnosticId::HOOK_CAPABILITY_DENIED,
				p_batch.batch_id.value);
	}
	if (p_batch.owner != this ||
			p_batch.seal != authority_seal ||
			!p_batch.preparation_status.ok() ||
			p_batch.committed ||
			p_batch.discarded ||
			p_batch.batch_id != in_flight_batch) {
		return make_status(StatusCode::TARGET_BATCH_REJECTED,
				DiagnosticId::INVALID_TARGET_PROVENANCE,
				p_batch.batch_id.value);
	}
	// Preparation only ever preflights a plan against captured/simulated
	// state -- it never publishes a mutation (see design.md's "Cross-
	// component application uses a prepared batch") -- so there is nothing
	// to roll back here; releasing the slot is the entire operation.
	in_flight_batch = INVALID_TARGET_BATCH_ID;
	p_batch.discarded = true;
	return ok_status();
}

} // namespace ga
