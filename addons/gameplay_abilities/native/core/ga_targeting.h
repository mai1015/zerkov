#ifndef GAMEPLAY_ABILITIES_CORE_TARGETING_H
#define GAMEPLAY_ABILITIES_CORE_TARGETING_H

#include "core/ga_ability_component.h"
#include "core/ga_target_types.h"

#include <cstdint>
#include <functional>
#include <map>
#include <string>
#include <vector>

namespace ga {

constexpr std::uint8_t GA_SNAPSHOT_KIND_TARGET_COORDINATOR = 40;
constexpr std::uint8_t GA_SNAPSHOT_KIND_TARGET_SESSION = 41;
constexpr std::uint8_t TARGET_SESSION_SNAPSHOT_VERSION = 1;

enum class TargetIntentOrigin : std::uint8_t {
	DIRECT_ACTIVATION = 0,
	GAMEPLAY_EVENT = 1,
	AI = 2,
	ABILITY_TASK = 3,
	TEST = 4,
	REMOTE_OWNER = 5,
};

struct TargetIntent {
	TargetIntentOrigin origin = TargetIntentOrigin::DIRECT_ACTIVATION;
	EntityId source = INVALID_ENTITY_ID;
	DefinitionId ability = INVALID_DEFINITION_ID;
	ExecutionId execution = INVALID_EXECUTION_ID;
	TargetSessionId session = INVALID_TARGET_SESSION_ID;
	DefinitionId schema = INVALID_DEFINITION_ID;
	std::uint16_t schema_version = 0;
	Tick submitted_tick = 0;
	TargetValue value;
};

struct CanonicalTargetIntent {
	TargetIntentOrigin origin = TargetIntentOrigin::DIRECT_ACTIVATION;
	EntityId source = INVALID_ENTITY_ID;
	DefinitionId ability = INVALID_DEFINITION_ID;
	ExecutionId execution = INVALID_EXECUTION_ID;
	TargetSessionId session = INVALID_TARGET_SESSION_ID;
	DefinitionId schema = INVALID_DEFINITION_ID;
	std::uint16_t schema_version = 0;
	Tick submitted_tick = 0;
	TargetValue value;
	std::uint64_t canonical_hash = 0;
};

enum class TargetEntityOutcomeKind : std::uint8_t {
	ACCEPTED = 0,
	PROVIDER_REJECTED = 1,
	COMPONENT_MISSING = 2,
	EFFECT_REJECTED = 3,
};

struct TargetEntityOutcome {
	EntityId entity = INVALID_ENTITY_ID;
	std::uint16_t rank = 0;
	TargetEntityOutcomeKind kind =
			TargetEntityOutcomeKind::ACCEPTED;
	Status status;
};

struct TargetProviderContract {
	std::string identifier;
	std::uint16_t version = 1;
	TargetValueKind intent_kind = TargetValueKind::ENTITY_SET;
	TargetValueKind result_kind = TargetValueKind::ENTITY_SET;
	bool prediction_safe = false;
	std::uint16_t max_work = 1;
};

struct TargetProviderContext {
	EntityId source = INVALID_ENTITY_ID;
	DefinitionId ability = INVALID_DEFINITION_ID;
	ExecutionId execution = INVALID_EXECUTION_ID;
	TargetSessionId session = INVALID_TARGET_SESSION_ID;
	Tick authority_tick = 0;
	const TargetSchema *schema = nullptr;

	// Read-only entity membership query. It exposes no component pointer,
	// mutation API, Node, RID, or transport capability.
	std::function<bool(EntityId)> entity_exists;
};

struct TargetProviderOutput {
	Status status;
	TargetValue result;
	std::vector<TargetEntityOutcome> outcomes;
	std::uint16_t work_units = 0;
};

class AuthorityTargetProvider {
public:
	virtual ~AuthorityTargetProvider() = default;
	virtual TargetProviderContract contract() const = 0;
	virtual Status resolve(const TargetProviderContext &p_context,
			const CanonicalTargetIntent &p_intent,
			TargetProviderOutput &r_output) const = 0;
};

struct LocalTargetPreview {
	Status status;
	TargetValue presentation_value;
	TargetIntent intent;
};

class LocalPreviewTargetProvider {
public:
	virtual ~LocalPreviewTargetProvider() = default;
	virtual TargetProviderContract contract() const = 0;
	virtual Status preview(const TargetProviderContext &p_context,
			LocalTargetPreview &r_preview) const = 0;
};

class GameplayAbilityWorldCoordinator;

// The default value is intentionally unvalidated. Only a coordinator can
// fill the private authority owner/seal, so callers cannot manufacture
// validated provenance with a serialized flag or public constructor.
class ValidatedTargetData {
public:
	bool valid() const {
		return authority_owner != nullptr && authority_seal != 0;
	}
	const CanonicalTargetIntent &canonical_intent() const {
		return intent;
	}
	const TargetValue &result() const { return resolved_result; }
	const std::vector<TargetEntityOutcome> &provider_outcomes() const {
		return outcomes;
	}
	EntityId source() const { return source_entity; }
	DefinitionId ability() const { return ability_definition; }
	ExecutionId execution() const { return execution_id; }
	TargetSessionId session() const { return session_id; }
	DefinitionId schema() const { return schema_id; }
	std::uint16_t schema_version() const { return version; }
	Tick authority_tick() const { return validated_tick; }
	TargetResultVisibility visibility() const { return result_visibility; }

private:
	friend class GameplayAbilityWorldCoordinator;

	const GameplayAbilityWorldCoordinator *authority_owner = nullptr;
	std::uint64_t authority_seal = 0;
	CanonicalTargetIntent intent;
	TargetValue resolved_result;
	std::vector<TargetEntityOutcome> outcomes;
	EntityId source_entity = INVALID_ENTITY_ID;
	DefinitionId ability_definition = INVALID_DEFINITION_ID;
	ExecutionId execution_id = INVALID_EXECUTION_ID;
	TargetSessionId session_id = INVALID_TARGET_SESSION_ID;
	DefinitionId schema_id = INVALID_DEFINITION_ID;
	std::uint16_t version = 0;
	Tick validated_tick = 0;
	TargetResultVisibility result_visibility =
			TargetResultVisibility::OWNER_ONLY;
};

enum class TargetSessionLifecycleKind : std::uint8_t {
	REQUESTED = 0,
	INTENT_SUBMITTED = 1,
	CONFIRMED = 2,
	COMPLETED = 3,
	REJECTED = 4,
	CANCELLED = 5,
	TIMED_OUT = 6,
	RESTORED = 7,
	CORRECTED = 8,
};

struct TargetSessionEvent {
	TargetSessionLifecycleKind kind =
			TargetSessionLifecycleKind::REQUESTED;
	TargetSessionId session = INVALID_TARGET_SESSION_ID;
	EntityId owner = INVALID_ENTITY_ID;
	ExecutionId execution = INVALID_EXECUTION_ID;
	AbilityTaskHandle task = INVALID_ABILITY_TASK_HANDLE;
	DefinitionId schema = INVALID_DEFINITION_ID;
	Tick tick = 0;
	Status status;
	CommandSeq command_sequence = INVALID_COMMAND_SEQ;
	bool has_intent = false;
	std::uint64_t canonical_intent_hash = 0;
};

struct ActiveTargetSession {
	TargetSessionId id = INVALID_TARGET_SESSION_ID;
	EntityId owner = INVALID_ENTITY_ID;
	DefinitionId ability = INVALID_DEFINITION_ID;
	ExecutionId execution = INVALID_EXECUTION_ID;
	AbilityTaskHandle task = INVALID_ABILITY_TASK_HANDLE;
	DefinitionId schema = INVALID_DEFINITION_ID;
	Tick start_tick = 0;
	bool has_deadline = false;
	Tick deadline_tick = INVALID_TICK;
	CommandSeq last_command_sequence = INVALID_COMMAND_SEQ;
	std::uint16_t submission_count = 0;
	bool has_intent = false;
	CanonicalTargetIntent latest_intent;
	ChangeProvenance provenance = ChangeProvenance::AUTHORITATIVE;
	PredictionKey prediction_key = INVALID_PREDICTION_KEY;
};

enum class TargetSessionCommandKind : std::uint8_t {
	SUBMIT = 0,
	CONFIRM = 1,
	CANCEL = 2,
};

struct TargetSessionCommand {
	TargetSessionCommandKind kind =
			TargetSessionCommandKind::SUBMIT;
	EntityId owner = INVALID_ENTITY_ID;
	ExecutionId execution = INVALID_EXECUTION_ID;
	AbilityTaskHandle task = INVALID_ABILITY_TASK_HANDLE;
	TargetSessionId session = INVALID_TARGET_SESSION_ID;
	DefinitionId schema = INVALID_DEFINITION_ID;
	std::uint16_t schema_version = 0;
	CommandSeq sequence = INVALID_COMMAND_SEQ;
	Tick tick = 0;
	bool has_intent = false;
	TargetValue intent;
	PredictionKey prediction_key = INVALID_PREDICTION_KEY;
};

struct TargetSessionStartResult {
	Status status;
	TargetSessionId session = INVALID_TARGET_SESSION_ID;
	AbilityTaskHandle task = INVALID_ABILITY_TASK_HANDLE;
	bool terminal = false;
	bool has_validated_data = false;
	ValidatedTargetData validated_data;
};

struct TargetSessionCommandResult {
	Status status;
	bool transitioned = false;
	bool terminal = false;
	bool duplicate_terminal = false;
	TargetSessionEvent event;
	bool has_validated_data = false;
	ValidatedTargetData validated_data;
};

struct TargetEffectApplication {
	DefinitionId effect_definition = INVALID_DEFINITION_ID;
	std::int32_t level = 1;
	std::vector<SetByCallerMagnitude> set_by_caller;
};

struct TargetBatchRequest {
	ValidatedTargetData validated_data;
	std::vector<TargetEffectApplication> source_effects;
	std::vector<TargetEffectApplication> target_effects;
	Tick tick = 0;
};

struct AppliedTargetEffect {
	EntityId target = INVALID_ENTITY_ID;
	DefinitionId effect_definition = INVALID_DEFINITION_ID;
	EffectHandle handle = INVALID_EFFECT_HANDLE;
};

class PreparedTargetBatch {
public:
	TargetBatchId id() const { return batch_id; }
	Status status() const { return preparation_status; }
	const std::vector<TargetEntityOutcome> &outcomes() const {
		return target_outcomes;
	}
	const std::vector<EntityId> &participants() const {
		return participant_entities;
	}

private:
	friend class GameplayAbilityWorldCoordinator;
	struct Operation {
		PendingRemoteEffectCommand command;
		PreparedEffectApplication prepared;
		std::size_t ordinal = 0;
	};

	const GameplayAbilityWorldCoordinator *owner = nullptr;
	std::uint64_t seal = 0;
	TargetBatchId batch_id = INVALID_TARGET_BATCH_ID;
	EntityId source = INVALID_ENTITY_ID;
	DefinitionId schema = INVALID_DEFINITION_ID;
	Tick tick = 0;
	Status preparation_status;
	std::vector<TargetEntityOutcome> target_outcomes;
	std::vector<EntityId> participant_entities;
	std::vector<Operation> operations;
	bool committed = false;
	// Set by `discard_batch`. Distinct from `committed` so a batch can never
	// be committed after being discarded (or discarded after being
	// committed) -- see `GameplayAbilityWorldCoordinator::in_flight_batch`.
	bool discarded = false;
};

struct TargetBatchCommitResult {
	Status status;
	TargetBatchId batch = INVALID_TARGET_BATCH_ID;
	bool committed = false;
	bool rolled_back = false;
	std::vector<TargetEntityOutcome> outcomes;
	std::vector<AppliedTargetEffect> applied_effects;
};

class GameplayAbilityWorldCoordinator {
public:
	explicit GameplayAbilityWorldCoordinator(
			const TargetSchemaRegistry &p_schemas);

	Status register_component(AbilityComponent &p_component,
			bool p_authoritative = true);
	// `p_component_destroyed` MUST be true when `p_component` has already
	// been destroyed (e.g. a freed Godot node discovered via `ObjectDB`) --
	// in that case this never dereferences the removed registration's
	// component pointer, even for sessions this same entity owns: their
	// tasks were destroyed along with the component, so there is nothing
	// left to cancel through it. Those sessions still terminalize with a
	// CANCELLED/`OWNER_FREED` event exactly as the live-component path
	// does. Sessions owned by a DIFFERENT, still-live entity that merely
	// reference `p_entity` (e.g. as a target) are unaffected by this flag --
	// they are always cancelled through their own owner's live component.
	// Default false preserves today's behavior for an explicit caller
	// unregistering a component it knows is still alive.
	Status unregister_component(EntityId p_entity, Tick p_tick,
			bool p_component_destroyed = false);
	bool has_component(EntityId p_entity) const;
	AbilityComponent *find_component(EntityId p_entity) const;
	const TargetSchemaRegistry &schema_registry() const {
		return *schemas;
	}

	Status register_authority_provider(
			const AuthorityTargetProvider &p_provider);
	Status register_preview_provider(
			const LocalPreviewTargetProvider &p_provider);
	Status validate_provider_contracts() const;

	Status normalize_intent(const TargetIntent &p_intent,
			CanonicalTargetIntent &r_intent) const;
	Status resolve_intent(const TargetIntent &p_intent, Tick p_tick,
			ValidatedTargetData &r_data);
	Status resolve_direct(const TargetIntent &p_intent, Tick p_tick,
			ValidatedTargetData &r_data);
	Status resolve_gameplay_event(const TargetIntent &p_intent, Tick p_tick,
			ValidatedTargetData &r_data);
	Status resolve_ai(const TargetIntent &p_intent, Tick p_tick,
			ValidatedTargetData &r_data);
	Status resolve_test(const TargetIntent &p_intent, Tick p_tick,
			ValidatedTargetData &r_data);
	Status preview_target(EntityId p_source, DefinitionId p_ability,
			ExecutionId p_execution, TargetSessionId p_session,
			DefinitionId p_schema, Tick p_tick,
			LocalTargetPreview &r_preview);

	TargetSessionStartResult begin_wait_target_data(
			EntityId p_owner, ExecutionId p_execution,
			DefinitionId p_schema, Tick p_tick,
			const TargetValue *p_initial_intent = nullptr);
	TargetSessionStartResult attach_wait_target_data(
			EntityId p_owner, ExecutionId p_execution,
			AbilityTaskHandle p_task, Tick p_tick,
			const TargetValue *p_initial_intent = nullptr);
	TargetSessionCommandResult submit_session_command(
			const TargetSessionCommand &p_command);
	std::vector<TargetSessionCommandResult> submit_session_commands(
			std::vector<TargetSessionCommand> p_commands);
	Status advance_to(Tick p_tick);
	const ActiveTargetSession *find_session(
			TargetSessionId p_session) const;
	std::vector<TargetSessionId> active_sessions() const;
	void add_session_listener(
			std::function<void(const TargetSessionEvent &)> p_listener);
	void notify_restored_sessions(
			Tick p_tick,
			EntityId p_owner_filter = INVALID_ENTITY_ID);

	Status write_snapshot(SnapshotWriter &p_writer,
			TargetResultVisibility p_audience =
					TargetResultVisibility::INTERNAL,
			EntityId p_owner_filter = INVALID_ENTITY_ID) const;
	Status restore_snapshot(SnapshotReader &p_reader);
	// Replaces only sessions owned by `p_owner`, preserving other entities'
	// sessions in the same explicit world coordinator. Used by one-
	// component-per-bridge owner snapshots.
	Status restore_owner_snapshot(SnapshotReader &p_reader,
			EntityId p_owner);

	// design.md, "Cross-component application uses a prepared batch": the
	// coordinator serializes one prepared batch at a time per participating
	// authority world. A successful `prepare_batch` occupies that single
	// slot until either `commit_batch` or `discard_batch` is called on the
	// SAME `PreparedTargetBatch`; a `prepare_batch` call while the slot is
	// occupied fails immediately with `StatusCode::CAPABILITY_VIOLATION` /
	// `DiagnosticId::TARGET_BATCH_IN_FLIGHT` and does no other work (same
	// shape as the `authority_provider_running` re-entry guard below). A
	// `PreparedTargetBatch` that is never passed to either call leaves the
	// slot permanently occupied -- this is a native/game-code call-discipline
	// bug, not a state this coordinator can safely repair on its own (the
	// batch's owning coordinator pointer must never be dereferenced once the
	// coordinator itself may have been destroyed).
	Status prepare_batch(const TargetBatchRequest &p_request,
			PreparedTargetBatch &r_batch);
	TargetBatchCommitResult commit_batch(PreparedTargetBatch &p_batch);
	// Releases `p_batch`'s in-flight slot without applying any of its
	// preflighted effect applications. Safe to call at any point after a
	// successful `prepare_batch` and before `commit_batch`: preparation never
	// mutates live component state (it only preflights a plan -- see
	// design.md's "Cross-component application uses a prepared batch"), so
	// there is nothing to roll back. Fails the same way `commit_batch` does
	// (`StatusCode::TARGET_BATCH_REJECTED`) for a batch this coordinator did
	// not prepare, one already committed or discarded, or a preparation that
	// itself failed.
	Status discard_batch(PreparedTargetBatch &p_batch);

private:
	struct ComponentRegistration {
		AbilityComponent *component = nullptr;
		bool authoritative = false;
	};
	struct ProviderRegistration {
		const AuthorityTargetProvider *provider = nullptr;
		TargetProviderContract contract;
	};
	struct PreviewRegistration {
		const LocalPreviewTargetProvider *provider = nullptr;
		TargetProviderContract contract;
	};
	struct TerminalSession {
		TargetSessionEvent event;
		CommandSeq last_sequence = INVALID_COMMAND_SEQ;
	};

	Status validate_contract(const TargetProviderContract &p_contract) const;
	Status validate_provider_for_schema(
			const TargetSchema &p_schema) const;
	Status invoke_provider(const CanonicalTargetIntent &p_intent,
			Tick p_tick, ValidatedTargetData &r_data);
	TargetSessionCommandResult resolve_session(
			ActiveTargetSession &p_session,
			const TargetSessionCommand &p_command);
	void terminalize_session(TargetSessionId p_session,
			const TargetSessionEvent &p_event,
			CommandSeq p_last_sequence);
	void emit_session_event(const TargetSessionEvent &p_event);
	void prune_stale_sessions(Tick p_tick);
	std::vector<EntityId> entities_from_result(
			const TargetValue &p_value) const;
	std::uint64_t state_fingerprint(
			const AbilityComponent &p_component) const;
	bool validated_by_this(const ValidatedTargetData &p_data) const;

	const TargetSchemaRegistry *schemas = nullptr;
	std::map<EntityId, ComponentRegistration> components;
	std::map<std::string, ProviderRegistration> authority_providers;
	std::map<std::string, PreviewRegistration> preview_providers;
	std::map<TargetSessionId, ActiveTargetSession> sessions;
	std::map<TargetSessionId, TerminalSession> terminal_sessions;
	std::vector<std::function<void(const TargetSessionEvent &)>>
			session_listeners;
	HandleAllocator<TargetSessionId> session_allocator;
	HandleAllocator<TargetBatchId> batch_allocator;
	std::uint64_t authority_seal = 0;
	bool authority_provider_running = false;
	// INVALID_TARGET_BATCH_ID when no prepared batch is outstanding; otherwise
	// the id of the one batch `prepare_batch` has prepared but that has not
	// yet reached `commit_batch` or `discard_batch`. See `prepare_batch`'s
	// doc comment above.
	TargetBatchId in_flight_batch = INVALID_TARGET_BATCH_ID;
};

} // namespace ga

#endif // GAMEPLAY_ABILITIES_CORE_TARGETING_H
