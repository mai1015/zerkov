#ifndef GAMEPLAY_ABILITIES_GODOT_ABILITY_COMPONENT_H
#define GAMEPLAY_ABILITIES_GODOT_ABILITY_COMPONENT_H

#include "core/ga_abilities.h"
#include "core/ga_ability_component.h"
#include "core/ga_attributes.h"
#include "core/ga_effects.h"
#include "core/ga_ids.h"
#include "core/ga_prediction.h"
#include "core/ga_reconciliation.h"
#include "core/ga_status.h"
#include "core/ga_tag_reactions.h"
#include "core/ga_tags.h"
#include "core/ga_tick.h"

#include "resources/gameplay_ability_definition.h"
#include "resources/gameplay_ability_task_request.h"
#include "resources/gameplay_attribute_definition.h"
#include "resources/gameplay_cue_definition.h"
#include "resources/gameplay_definition_catalog.h"
#include "resources/gameplay_effect_definition.h"
#include "resources/gameplay_tag_definition.h"
#include "resources/gameplay_target_data_schema.h"

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/callable.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/typed_array.hpp>

#include <map>
#include <memory>
#include <string>
#include <utility>
#include <vector>

namespace godot {
// Forward declarations only -- the full script-hook adapter types
// (gameplay_ability_hook_bridge.h) are needed only by the .cpp; keeping them
// out of this header avoids widening every file that already includes this
// one (task 6.10).
class ScriptAuthorityAbilityHook;
class ScriptPredictionSafeAbilityHook;
} //namespace godot

// The engine-side thin adapter around `ga::AbilityComponent` (tasks 7.3, 7.4,
// 7.9; also serves 6.2-6.8's Godot exposure). Every gameplay decision --
// validation, cost/cooldown/tag application, cancellation, snapshotting --
// happens in the core object this class owns; this file only ever converts
// `Variant` <-> core value types at the boundary and translates core change
// records into signals (see GA_CONTRACT.md section 11).
//
// Definitions (tag/attribute/effect/cue Resources, plus ability definitions --
// see `ability_definitions` below) are supplied before `configure()` and
// become immutable for the session once it succeeds, matching design.md's
// "Stable identities and immutable definitions". `ability_definitions`
// accepts EITHER an `Array[Dictionary]` shaped exactly like
// `ga::AbilityDefinitionDesc` (the original seam) OR a
// `TypedArray[GameplayAbilityDefinition]`/plain `Array` of
// `GameplayAbilityDefinition` resources directly (task 12.3's ergonomic
// follow-up) -- `configure()` accepts either element shape per-entry, so a
// caller may even mix the two. `GameplayAbilityDefinitionBridge.to_dictionary_array()`
// (runtime/ga_ability_definition_bridge.gd) therefore becomes an optional
// convenience, not a required conversion step.
namespace godot {

class GameplayAbilityComponent : public Node {
	GDCLASS(GameplayAbilityComponent, Node)

public:
	// Mirrors ga::ComponentRole exactly (see ga_ability_component.h).
	enum Role {
		ROLE_OFFLINE_AUTHORITY = 0,
		ROLE_SERVER_AUTHORITY = 1,
		ROLE_NETWORK_CLIENT = 2,
	};

	// Mirrors ga::ChangeProvenance.
	enum Provenance {
		PROVENANCE_AUTHORITATIVE = 0,
		PROVENANCE_PREDICTED = 1,
	};

	// Mirrors ga::ExecutionPhase.
	enum Phase {
		PHASE_REQUESTED = 0,
		PHASE_VALIDATING = 1,
		PHASE_BEGUN = 2,
		PHASE_COMMITTED = 3,
		PHASE_ACTIVE = 4,
		PHASE_ENDED = 5,
		PHASE_CANCELLED = 6,
	};

	// Mirrors ga::ExecutionEndReason.
	enum EndReason {
		END_REASON_NONE = 0,
		END_REASON_EXPLICIT_SUCCESS = 1,
		END_REASON_EXPLICIT_CANCEL = 2,
		END_REASON_CANCEL_TAG = 3,
		END_REASON_REVOKED = 4,
		END_REASON_OWNER_TEARDOWN = 5,
		END_REASON_AUTHORITY_CORRECTION = 6,
		END_REASON_HOOK_FAILURE = 7,
	};

	// Mirrors ga::AbilityLifecycleKind. Also the value carried by every
	// activation_* signal's event Dictionary under the "kind" key.
	enum LifecycleKind {
		LIFECYCLE_GRANTED = 0,
		LIFECYCLE_REVOKED = 1,
		LIFECYCLE_REQUESTED = 2,
		LIFECYCLE_PHASE_CHANGED = 3,
		LIFECYCLE_COMMITTED = 4,
		LIFECYCLE_ENDED = 5,
		LIFECYCLE_CANCELLED = 6,
		LIFECYCLE_FAILED = 7,
		LIFECYCLE_SNAPSHOT_RESTORED = 8,
	};

	// Mirrors ga::AbilityDiagnosticKind.
	enum DiagnosticEventKind {
		DIAGNOSTIC_EVENT_RECURSION_LIMIT_REACHED = 0,
		DIAGNOSTIC_EVENT_CAPABILITY_VIOLATION_DETECTED = 1,
		DIAGNOSTIC_EVENT_ROLE_VIOLATION_DETECTED = 2,
	};

	// Mirrors ga::EffectLifecycleKind.
	enum EffectLifecycleKind {
		EFFECT_LIFECYCLE_APPLIED = 0,
		EFFECT_LIFECYCLE_STACK_CHANGED = 1,
		EFFECT_LIFECYCLE_PERIODIC_EXECUTED = 2,
		EFFECT_LIFECYCLE_REMOVED = 3,
		EFFECT_LIFECYCLE_EXPIRED = 4,
	};

	// Mirrors ga::EffectRemovalReason.
	enum EffectRemovalReason {
		EFFECT_REMOVAL_NONE = 0,
		EFFECT_REMOVAL_EXPLICIT = 1,
		EFFECT_REMOVAL_EXPIRED = 2,
		EFFECT_REMOVAL_REPLACED_BY_STACK_POLICY = 3,
	};

	// Mirrors ga::CuePhase.
	enum CuePhase {
		CUE_PREDICT = 0,
		CUE_CONFIRM = 1,
		CUE_CORRECT = 2,
		CUE_CANCEL = 3,
		CUE_AUTHORITY_ONLY = 4,
		CUE_SNAPSHOT_RESTORED = 5,
	};

	enum TaskKind {
		TASK_WAIT_TICKS = 0,
		TASK_WAIT_GAMEPLAY_EVENT = 1,
		TASK_WAIT_TAG_QUERY = 2,
		TASK_WAIT_LOGICAL_INPUT = 3,
		TASK_WAIT_AUTHORITY = 4,
		TASK_WAIT_TARGET_DATA = 5,
	};

	enum TaskOutcome {
		TASK_ACTIVE = 0,
		TASK_COMPLETED = 1,
		TASK_FAILED = 2,
		TASK_TIMED_OUT = 3,
		TASK_CANCELLED = 4,
	};

	enum TaskCancelReason {
		TASK_CANCEL_NONE = 0,
		TASK_CANCEL_EXPLICIT = 1,
		TASK_CANCEL_PARENT_ENDED = 2,
		TASK_CANCEL_PARENT_CANCELLED = 3,
		TASK_CANCEL_SPEC_REVOKED = 4,
		TASK_CANCEL_OWNER_TEARDOWN = 5,
		TASK_CANCEL_AUTHORITY_CORRECTION = 6,
		TASK_CANCEL_TARGET_SESSION = 7,
	};

	enum LogicalInputPhase {
		LOGICAL_INPUT_PRESS = 0,
		LOGICAL_INPUT_RELEASE = 1,
		LOGICAL_INPUT_CONFIRM = 2,
		LOGICAL_INPUT_CANCEL = 3,
	};

	// Mirrors ga::StatusCode. Every Dictionary "status" field below carries
	// {code:int, diagnostic:int, detail:int} using these numeric values --
	// stable and additive per the shared contract (GA_CONTRACT.md section 8).
	enum StatusCode {
		STATUS_OK = 0,
		STATUS_INVALID_ARGUMENT = 1,
		STATUS_NOT_FOUND = 2,
		STATUS_ALREADY_EXISTS = 3,
		STATUS_OUT_OF_BOUNDS = 4,
		STATUS_ARITHMETIC_ERROR = 5,
		STATUS_CAPACITY_EXCEEDED = 6,
		STATUS_NOT_SUPPORTED = 7,
		STATUS_INTERNAL_ERROR = 8,
		STATUS_INVALID_IDENTIFIER = 20,
		STATUS_DUPLICATE_DEFINITION = 21,
		STATUS_UNKNOWN_DEFINITION = 22,
		STATUS_INVALID_REFERENCE = 23,
		STATUS_REGISTRY_SEALED = 24,
		STATUS_MANIFEST_MISMATCH = 25,
		STATUS_UNKNOWN_TAG = 40,
		STATUS_UNKNOWN_TAG_SOURCE = 41,
		STATUS_TAG_COUNT_UNDERFLOW = 42,
		STATUS_INVALID_QUERY = 43,
		STATUS_UNKNOWN_ATTRIBUTE = 60,
		STATUS_INVALID_BOUNDS = 61,
		STATUS_INSUFFICIENT_ATTRIBUTE = 62,
		STATUS_UNKNOWN_MODIFIER = 63,
		STATUS_UNKNOWN_EFFECT = 80,
		STATUS_INVALID_EFFECT_SPEC = 81,
		STATUS_EFFECT_REQUIREMENTS_FAILED = 82,
		STATUS_EFFECT_IMMUNE = 83,
		STATUS_EFFECT_STACK_REJECTED = 84,
		STATUS_UNKNOWN_EFFECT_HANDLE = 85,
		STATUS_MISSING_SET_BY_CALLER = 86,
		STATUS_UNDECLARED_SET_BY_CALLER = 87,
		STATUS_HOOK_FAILED = 88,
		STATUS_UNKNOWN_ABILITY = 100,
		STATUS_ABILITY_NOT_GRANTED = 101,
		STATUS_ABILITY_ALREADY_GRANTED = 102,
		STATUS_ABILITY_ALREADY_ACTIVE = 103,
		STATUS_ABILITY_MISSING_TAG = 104,
		STATUS_ABILITY_BLOCKED_TAG = 105,
		STATUS_ABILITY_ON_COOLDOWN = 106,
		STATUS_ABILITY_COST_UNAFFORDABLE = 107,
		STATUS_ABILITY_INVALID_TARGET = 108,
		STATUS_ABILITY_ALREADY_ENDED = 109,
		STATUS_ABILITY_REVOKED = 110,
		STATUS_ABILITY_POLICY_VIOLATION = 111,
		STATUS_RECURSION_LIMIT = 112,
		STATUS_CAPABILITY_VIOLATION = 113,
		STATUS_ROLE_VIOLATION = 140,
		STATUS_NOT_AUTHORITY = 141,
		STATUS_NOT_OWNER = 142,
		STATUS_PERMISSION_DENIED = 143,
		STATUS_NETWORK_UNAVAILABLE = 144,
		STATUS_PROTOCOL_MISMATCH = 145,
		STATUS_SESSION_MISMATCH = 146,
		STATUS_STALE_COMMAND = 147,
		STATUS_DUPLICATE_COMMAND = 148,
		STATUS_RATE_LIMITED = 149,
		STATUS_SEQUENCE_GAP = 150,
		STATUS_DECODE_FAILED = 151,
		STATUS_PAYLOAD_TOO_LARGE = 152,
		STATUS_SNAPSHOT_REQUIRED = 153,
		STATUS_UNKNOWN_NETWORK_IDENTITY = 154,
		STATUS_PREDICTION_UNAVAILABLE = 180,
		STATUS_PREDICTION_NOT_SAFE = 181,
		STATUS_PREDICTION_REJECTED = 182,
		STATUS_PREDICTION_JOURNAL_FULL = 183,
		STATUS_PREDICTION_BASELINE_LOST = 184,
		STATUS_PREDICTION_UNKNOWN_KEY = 185,
		STATUS_UNKNOWN_ABILITY_TASK = 200,
		STATUS_ABILITY_TASK_ALREADY_TERMINAL = 201,
		STATUS_INVALID_ABILITY_TASK = 202,
		STATUS_ABILITY_TASK_TIMED_OUT = 203,
		STATUS_ABILITY_TASK_CANCELLED = 204,
		STATUS_ABILITY_TASK_INPUT_REJECTED = 205,
		STATUS_UNKNOWN_TARGET_SCHEMA = 220,
		STATUS_INVALID_TARGET_DATA = 221,
		STATUS_UNKNOWN_TARGET_SESSION = 222,
		STATUS_TARGET_SESSION_ALREADY_TERMINAL = 223,
		STATUS_TARGET_PROVIDER_REJECTED = 224,
		STATUS_TARGET_BATCH_REJECTED = 225,
	};

	GameplayAbilityComponent();
	~GameplayAbilityComponent() override;

	// -- Pre-configuration properties (immutable once configure() succeeds) --

	void set_role(Role p_role);
	Role get_role() const { return role; }

	void set_entity_id(int64_t p_id);
	int64_t get_entity_id() const;

	// Task 7.19: the ticks/second this component's session runs at. This is
	// the AUTHORITATIVE home for tick rate (see ga_manifest.h's
	// `ManifestBuilder` constructor and `configure()`'s manifest-building
	// step below) -- not `GameplayAbilityNetworkBridge`, even though a bridge
	// also exposes a `tick_rate` property of its own for its pre-wiring
	// protocol-layer bookkeeping. The reasoning: this component is what
	// builds and permanently caches the content-manifest fingerprint
	// (`get_content_manifest_fingerprint()`), and `configure()` -- like
	// every other pre-configuration property above -- can be, and in every
	// existing test/example IS, called completely independently of any
	// bridge (a bridge may not even exist yet, or may wire to this component
	// long after `configure()` already ran). A value that lives only on the
	// bridge can therefore never reliably reach the manifest at the moment
	// it is built; putting it here instead removes that ordering hazard
	// entirely. `GameplayAbilityNetworkBridge::effective_tick_rate()` reads
	// THIS value once it resolves a configured served component, so there is
	// exactly one tick rate in force for a wired session, never two that can
	// silently disagree. Same "immutable once configured" rule as `role`/
	// `entity_id` above; degenerate (<= 0) input clamps to
	// `ga::DEFAULT_TICK_RATE`, matching the bridge's own existing
	// convention.
	void set_tick_rate(int p_tick_rate);
	int get_tick_rate() const { return tick_rate; }

	void set_tag_definitions(const TypedArray<GameplayTagDefinition> &p_tags);
	TypedArray<GameplayTagDefinition> get_tag_definitions() const { return tag_definitions; }

	void set_attribute_definitions(const TypedArray<GameplayAttributeDefinition> &p_attributes);
	TypedArray<GameplayAttributeDefinition> get_attribute_definitions() const { return attribute_definitions; }

	void set_effect_definitions(const TypedArray<GameplayEffectDefinition> &p_effects);
	TypedArray<GameplayEffectDefinition> get_effect_definitions() const { return effect_definitions; }

	void set_cue_definitions(const TypedArray<GameplayCueDefinition> &p_cues);
	TypedArray<GameplayCueDefinition> get_cue_definitions() const { return cue_definitions; }

	// Array of Dictionary and/or GameplayAbilityDefinition; see class comment
	// for the exact per-entry Dictionary schema (mirrors
	// ga::AbilityDefinitionDesc field-for-field).
	void set_ability_definitions(const Array &p_abilities);
	Array get_ability_definitions() const { return ability_definitions; }

	// Named `GameplayTargetDataSchema` resources an ability's `target_schema`
	// field (GameplayAbilityDefinition, or the Dictionary shape's
	// "target_schema" key) may reference (task 7.16). Resolved by identifier
	// at `configure()` time; see `get_target_data_schema_for_ability`.
	void set_target_data_schemas(const TypedArray<GameplayTargetDataSchema> &p_schemas);
	TypedArray<GameplayTargetDataSchema> get_target_data_schemas() const { return target_data_schemas; }

	// Task 1.2: explicit per-component catalog override (design.md decision
	// 1 "Use a unified project definition catalog"). `configure()`'s
	// resolution order is: this override if set, else the project setting
	// `gameplay_abilities/default_definition_catalog`, else no catalog at
	// all -- the legacy arrays above then apply exactly as before (task
	// 1.4). Immutable once configure() succeeds, same as every other
	// pre-configuration property in this section. Important for tests,
	// editor previews, and independently configured simulation worlds that
	// must not depend on -- or interfere with -- the project's own default
	// catalog (design.md's own reasoning for this property).
	void set_definition_catalog(const Ref<GameplayDefinitionCatalog> &p_catalog);
	Ref<GameplayDefinitionCatalog> get_definition_catalog() const { return definition_catalog; }

	// Builds and seals every registry from the properties above, constructs
	// the owned `ga::AbilityComponent`, and wires every core change-record
	// listener to this node's signals. Idempotent-safe: a second call is
	// rejected (returns a single "already_configured" finding) rather than
	// rebuilding -- definitions are immutable for the session once accepted.
	// Returns a bounded findings Array of Dictionary ({severity,
	// resource_path, field, code, message}), matching
	// GameplayDefinitionValidator's shape; empty means success.
	Array configure();
	// Finding 5 (spec "Restoring a snapshot MUST replace the covered state
	// atomically"): false while `quarantined` too, not just before
	// `configure()` succeeds. Quarantine is this component's fail-closed
	// response to a snapshot restore whose ROLLBACK also failed (see
	// `restore_snapshot()`/`rollback_or_quarantine()`) -- a genuinely
	// unrecoverable component must refuse every mutating entry point (almost
	// all of which already gate on `is_configured()`) rather than keep
	// accepting commands against unknown state. `configure()` clears
	// `quarantined` the moment it builds a brand-new `component` -- the
	// documented recovery path (see `desync_rebuild_required`) -- but its
	// OWN "already_configured" guard is keyed on `component != nullptr`
	// directly, never on this method, so a quarantined-but-still-configured
	// instance cannot be trivially un-quarantined by a no-op `configure()`
	// call that never actually rebuilds anything.
	bool is_configured() const { return component != nullptr && !quarantined; }

	// Content-manifest fingerprint over every sealed registry this component
	// was configured with (ga::ManifestBuilder, see ga_manifest.h), computed
	// once at the end of a successful configure(). This is the value
	// GameplayAbilityNetworkBridge's handshake compares against the remote
	// peer's own fingerprint (task 7.2's "Protocol and Content Compatibility
	// Handshake", already implemented -- see gap_handshake.h). 0 before
	// configure() succeeds.
	int64_t get_content_manifest_fingerprint() const { return manifest_fingerprint; }

	// Initializes one registered attribute on THIS component instance (see
	// ga::AttributeSet::initialize_attribute -- a shared AttributeRegistry
	// only describes content; a component decides which of its attributes
	// it actually carries and their starting value). Must be called once
	// per attribute identifier before any effect/cost/cooldown that
	// references it is applied; calling it twice for the same identifier,
	// or naming an unregistered identifier, fails closed with the
	// underlying core Status (ALREADY_EXISTS / UNKNOWN_ATTRIBUTE) and
	// mutates nothing. `p_has_override` false uses the definition's own
	// `default_base`.
	Dictionary initialize_attribute(const String &p_identifier, bool p_has_override, double p_override_base, int64_t p_tick);

	// -- Grants (task 6.2) ------------------------------------------------
	//
	// Every mutating method below takes an explicit `tick`, matching the
	// core 1:1 (see ga_ability_component.h) -- this adapter holds no
	// implicit "current tick" state machine of its own; `get_current_tick()`
	// is purely the highest tick value observed so far, for diagnostics.

	Dictionary grant_ability(const String &p_identifier, int p_level, const String &p_input_id, int64_t p_tick);
	Dictionary revoke_ability(int64_t p_spec, int64_t p_tick, Provenance p_provenance = PROVENANCE_AUTHORITATIVE);
	bool has_grant(int64_t p_spec) const;
	Dictionary get_grant(int64_t p_spec) const;
	PackedInt64Array granted_specs() const;
	int64_t ability_id_of(const String &p_identifier) const;

	// -- Activation (tasks 6.3-6.5) ----------------------------------------

	Dictionary request_activation(const Dictionary &p_request, int64_t p_tick);
	Array process_activation_batch(const Array &p_requests, int64_t p_tick);
	Dictionary commit_activation(int64_t p_execution, int64_t p_tick);
	Dictionary handle_gameplay_event(const Dictionary &p_event, int64_t p_tick);

	// -- Execution-owned deterministic waits -------------------------------
	Dictionary start_ability_task(int64_t p_execution,
			const Ref<GameplayAbilityTaskRequest> &p_request, int64_t p_tick,
			Provenance p_provenance = PROVENANCE_AUTHORITATIVE);
	Dictionary cancel_ability_task(int64_t p_task, int64_t p_tick,
			TaskCancelReason p_reason = TASK_CANCEL_EXPLICIT,
			Provenance p_provenance = PROVENANCE_AUTHORITATIVE);
	Dictionary submit_logical_input(int64_t p_execution, int64_t p_task,
			const String &p_logical_input, LogicalInputPhase p_phase,
			int64_t p_command_sequence, int64_t p_prediction_key,
			int64_t p_tick,
			Provenance p_provenance = PROVENANCE_AUTHORITATIVE);
	Dictionary acknowledge_task_authority(int64_t p_prediction_key,
			int64_t p_tick);
	bool has_ability_task(int64_t p_task) const;
	Dictionary get_ability_task(int64_t p_task) const;
	PackedInt64Array active_ability_tasks() const;
	PackedInt64Array ability_tasks_for_execution(int64_t p_execution) const;
	void notify_restored_ability_tasks(int64_t p_tick);

	// -- Legacy remote-target hook commands (compatibility only) -------------
	//
	// `request_activation`/`process_activation_batch`/`commit_activation`'s
	// result Dictionary carries a "pending_remote_effects" Array (possibly
	// empty): every `APPLY_TARGET_EFFECT` hook command this commit validated
	// and accepted but whose target was not this component's own owner (see
	// `ga::PendingRemoteEffectCommand`'s doc comment for why this component
	// cannot apply it itself). Each entry is a Dictionary shaped
	// {source:int, target:int, effect_definition:int, effect_identifier:String,
	// level:int, set_by_caller:Array[Dictionary{field:String,value:float}],
	// provenance:int, prediction_key:int, originating_spec:int,
	// originating_execution:int, tick:int}.
	//
	// This remains supported for pre-typed integrations, but it is deprecated
	// as the primary cross-component path. New code should resolve typed
	// intent through `GameplayAbilityWorldCoordinator` and call
	// `apply_effect_batch`, which preflights all participants and publishes
	// only after a successful coordinated commit.
	//
	// The compatibility path for applying one: resolve `target` to ITS OWN
	// `GameplayAbilityComponent` (never reach into the originating
	// component's internals) and call THIS method on that instance --
	// `apply_pending_remote_effect` delegates, unchanged, to
	// `ga::AbilityComponent::apply_remote_effect`, so every guarantee that
	// method documents (authority-only regardless of the command's own
	// `provenance` field, target-identity match required, normal validated
	// `EffectRuntime::apply` path, no authority-handle injection possible)
	// holds here too. `p_source`, if non-null, must already be
	// `is_configured()`; its OWN read-only attribute/tag state is exposed to
	// the applied effect's magnitude resolution exactly as
	// `ga::EffectRuntime::apply` already documents for any source entity
	// (pass null if the command's effect needs no source-attribute reads, or
	// `p_source` is unavailable). Returns `{status: Dictionary, handle: int}`
	// (`handle` is 0/INVALID_EFFECT_HANDLE for an INSTANT effect).
	Dictionary apply_pending_remote_effect(const Dictionary &p_command, GameplayAbilityComponent *p_source, int64_t p_tick);

	// Task 6.14: read-only preflight twin of `apply_pending_remote_effect`,
	// for a game that wants to implement a strict "never charge a cost for a
	// cross-entity effect that cannot land" atomicity policy (see
	// `ga::EffectRuntime::preflight_apply`'s own doc comment for the full
	// motivation -- cross-entity attacks are not atomic in this addon: a
	// source's cost/cooldown commits independently of whether the target
	// ever actually applies the effect). Parses `p_command` with the SAME
	// `build_pending_remote_effect_command` `apply_pending_remote_effect`
	// uses (identical Dictionary shape), then delegates to
	// `ga::AbilityComponent::preflight_remote_effect` -- unchanged, so every
	// check that method documents (authority-role/target-identity match,
	// then the full `EffectRuntime::preflight_apply` chain) applies here too.
	// `p_source` is read exactly like `apply_pending_remote_effect`'s own
	// parameter of the same name (its read-only attribute/tag state feeds
	// magnitude resolution; pass null if unavailable/not needed).
	//
	// Const and side-effect-free: never mutates this component's
	// `current_tick`, unlike its mutating twin. Returns `{status: Dictionary}`
	// (no `handle` key -- nothing is ever allocated). Advisory only: see
	// `ga::EffectRuntime::preflight_apply` for exactly what an `ok` status
	// does and does not promise.
	Dictionary preflight_pending_remote_effect(const Dictionary &p_command, GameplayAbilityComponent *p_source, int64_t p_tick) const;

	// -- Ending & cancellation (task 6.7) -----------------------------------

	Dictionary end_execution(int64_t p_execution, int64_t p_tick, Provenance p_provenance = PROVENANCE_AUTHORITATIVE);
	Dictionary cancel_execution(int64_t p_execution, int64_t p_tick, Provenance p_provenance = PROVENANCE_AUTHORITATIVE,
			EndReason p_reason = END_REASON_EXPLICIT_CANCEL);
	bool has_execution(int64_t p_execution) const;
	Dictionary get_execution(int64_t p_execution) const;
	PackedInt64Array active_executions() const;

	// -- Active effects (task 6.12) -------------------------------------------
	//
	// Read-only local accessor: before this existed, the reactive
	// `effect_lifecycle_changed` signal was the ONLY way to learn anything
	// about a component's active effects (a late-attaching observer, a
	// diagnostic overlay, or simple polling code had no way to ask "what is
	// active right now"). Both methods below read ONLY `this` component's
	// OWN `ga::EffectRuntime` -- exactly the same trust boundary
	// `get_execution`/`get_grant` above already use -- so this can never
	// become a way to read another peer's owner-only state: a
	// `ROLE_NETWORK_CLIENT` component only ever holds what it was already
	// granted via snapshot/prediction, and a networked caller still has to
	// go through `GameplayAbilityNetworkBridge`'s own visibility filtering to
	// reach a REMOTE peer's component at all.
	PackedInt64Array active_effect_handles() const;
	Dictionary get_active_effect(int64_t p_handle) const;

	// -- Prediction handle mapping (task 8.11) ---------------------------------
	//
	// Read-only local accessor over `ga::PredictionHandleMap` (owned by this
	// component's own `ga::PredictionReconciler`, task 8.5): once an
	// acknowledgement maps a predicted temporary effect handle to its
	// authority-issued counterpart, this resolves that mapping. Returns 0
	// (INVALID_EFFECT_HANDLE) if `p_temp_handle` has no recorded mapping --
	// not yet confirmed, already pruned once the underlying effect was
	// removed/expired, or this component is not `ROLE_NETWORK_CLIENT` (no
	// `ga::PredictionReconciler` exists at all outside that role). Same
	// component-local trust boundary as `active_effect_handles()` above --
	// this only ever reads THIS component's own bookkeeping.
	int64_t predicted_effect_authority_handle(int64_t p_temp_handle) const;

	// -- Tick driver ---------------------------------------------------------

	Dictionary advance_to(int64_t p_tick);
	int64_t get_current_tick() const { return static_cast<int64_t>(current_tick); }

	// -- Attribute / tag queries ---------------------------------------------

	bool has_attribute(const String &p_identifier) const;
	double get_attribute_base(const String &p_identifier) const;
	double get_attribute_current(const String &p_identifier) const;
	// Every initialized attribute's identifier, ascending DefinitionId order
	// (matches ga::AttributeSet::initialized_attributes' own canonical
	// order). Lets a caller (e.g. GameplayAbilityNetworkBridge's relevance
	// filter) enumerate attributes by name without a separate registry
	// reference of its own.
	PackedStringArray get_initialized_attributes() const;
	bool has_tag_exact(const String &p_identifier) const;
	bool has_tag_parent_aware(const String &p_identifier) const;
	PackedStringArray owned_tags() const;

	// -- Diagnostics ----------------------------------------------------------

	Dictionary get_diagnostics() const;

	// -- Canonical snapshots (task 7.9) --------------------------------------

	PackedByteArray write_snapshot() const;
	// Finding 5 (spec "Restoring a snapshot MUST replace the covered state
	// atomically"): core `ga::AbilityComponent::restore_snapshot` restores
	// subsystem-by-subsystem (attributes, tags, effects, then grants/
	// executions) and its OWN doc comment documents that a failure on a
	// LATER section leaves an EARLIER one already replaced -- MIXED state,
	// part new / part old. This wrapper is where the atomicity contract
	// actually gets enforced, via rollback-then-quarantine:
	//   1. Capture the CURRENT (pre-restore) state via this component's own
	//      canonical `write_snapshot()` BEFORE attempting anything -- always
	//      well-formed, since it is read from an already-live, already-valid
	//      component.
	//   2. Attempt the incoming restore directly through the core
	//      `ga::AbilityComponent::restore_snapshot(SnapshotReader&)`. On
	//      success, this component now holds EXACTLY the new snapshot's
	//      state -- atomic from the caller's perspective.
	//   3. On failure, roll back to the captured pre-state (see
	//      `rollback_or_quarantine()`). This is well-defined even though the
	//      incoming restore may have left mixed state: every subsystem's own
	//      `restore_snapshot` builds into local temporaries and only
	//      replaces ITS OWN live state, wholesale, at the very end, after
	//      full success (verified directly against this addon's actual
	//      implementations -- e.g. `AttributeSet::restore_snapshot`,
	//      `TagContainer::restore_snapshot`, `EffectRuntime::
	//      restore_snapshot`, and the grants/executions maps
	//      `AbilityComponent::restore_snapshot` itself only assigns at its
	//      own tail -- every one of them builds a fresh local value and only
	//      commits it to the live member on total success). So rolling back
	//      over mixed state just means "every subsystem gets wholesale
	//      replaced by the pre-state's value again," identical in effect to
	//      a full fresh restore -- there is no partial-subsystem state for
	//      the rollback to trip over.
	//   4. If that rollback ALSO fails (the pre-state THIS component itself
	//      just wrote moments earlier somehow fails to decode back in --
	//      should not happen in practice, but "should not happen" is exactly
	//      what fail-closed defends against), this component is genuinely
	//      unrecoverable and is quarantined (see `rollback_or_quarantine()`).
	// Returns true only on the initial restore's own success (matching the
	// old signature/contract callers already depend on); false covers both
	// "rolled back to pre-state" and "quarantined" -- `is_configured()`
	// distinguishes the two afterward.
	bool restore_snapshot(const PackedByteArray &p_bytes);

	// -- Owner teardown seam --------------------------------------------------

	void queue_teardown(int64_t p_tick);
	bool is_owner_valid() const;
	bool is_torn_down() const;

	// -- Network-bridge seams (called by GameplayAbilityNetworkBridge, or by
	// a future section-8 prediction/reconciliation layer) ---------------------

	// Reports a bounded replication-gap diagnostic (stable code + numeric
	// detail only -- never an untrusted string) and emits
	// `replication_gap_detected`. The bridge calls this when its
	// `ga::proto::ClientEventStream` leaves SYNCED (gap detected, snapshot
	// required, relevance lost); this component has no network state of its
	// own to detect that condition itself.
	void notify_replication_gap(int p_reason_code, int64_t p_detail);

	// Emits `prediction_phase_changed` with a Dictionary shaped
	// {prediction_key:int, phase:int, ability:int, ability_identifier:String,
	// target:int, definition:int, handle:int, occurrence:int, tick:int} --
	// the `definition`/`handle`/`occurrence` triple (with `target`) is
	// `ga::CueDedupId` field-for-field, so `runtime/ga_cue_adapter.gd`'s
	// dedup logic keys on it directly without a separate
	// `prediction_key`-only fallback (task 8.10). Driven internally by this
	// component's own owned `ga::PredictingComponent` (see
	// `predicting_component()`) for a `ROLE_NETWORK_CLIENT` component;
	// exposed publicly too so a caller composing its own prediction layer may
	// still drive it directly, matching the pre-8.10 seam contract.
	void notify_prediction_phase(const Dictionary &p_payload);

	// -- Constrained behavior hooks (tasks 6.6/6.10) --------------------------
	//
	// Registers a Callable-based `ga::AuthorityAbilityHook`/
	// `ga::PredictionSafeAbilityHook` for `p_ability_identifier` (must already
	// be a sealed ability whose `hook_binding` names the matching family --
	// see ga_ability_component.h's `bind_authority_hook`/
	// `bind_prediction_safe_hook`, which this delegates to unchanged, so
	// every existing guarantee -- sticky rejection, structural family
	// separation, atomic command application through the normal
	// EffectRuntime/handle_gameplay_event path -- holds identically for a
	// script-authored hook). Returns `{status: Dictionary}`.
	//
	// The bound Callable is invoked as
	// `callable.call(context: Dictionary, builder: GameplayAbilityCommandBuilder) -> Variant`.
	// `context` is an immutable, read-only snapshot (never a live reference
	// into core state -- see `ability_execution_context_dict`); `builder`
	// wraps the SAME `ga::AbilityCommandBuilder&` the C++ hook interface
	// receives and is invalidated the instant the call returns, so a script
	// cannot retain it and mutate later. The Callable's return value is
	// interpreted narrowly (task 6.10's "a script hook that throws/errors or
	// returns garbage must fail the transaction with a bounded diagnostic"):
	// Nil -> success; `bool` -> that value; anything else (including a call
	// that raised a script error and therefore returned Nil-shaped garbage
	// from a non-void expression) -> `STATUS_HOOK_FAILED`. A rejected command
	// builder submission is still checked UNCONDITIONALLY afterward exactly
	// like the C++ path -- a script cannot swallow its own
	// `STATUS_CAPABILITY_VIOLATION` by ignoring it or returning true anyway.
	Dictionary bind_authority_hook(const String &p_ability_identifier,
			const Callable &p_callable,
			const Callable &p_task_callable = Callable());

	// As above, but for `ga::PredictionSafeAbilityHook`. The four trailing
	// booleans are this hook's OWN honest capability declaration (mirroring
	// `PredictionSafeAbilityHook::depends_on_time`/`depends_on_randomness`/
	// `depends_on_scene_or_physics`/`uses_unrestricted_callback`) -- passing
	// `true` for any of them is validated by the EXISTING
	// `validate_prediction_safe_hook` before binding, exactly like the C++
	// interface, so a script declaring a non-deterministic dependency is
	// rejected with `STATUS_PREDICTION_NOT_SAFE` before it can ever run, not
	// silently accepted as authority-only.
	Dictionary bind_prediction_safe_hook(const String &p_ability_identifier, const Callable &p_callable,
			bool p_depends_on_time = false, bool p_depends_on_randomness = false,
			bool p_depends_on_scene_or_physics = false,
			bool p_uses_unrestricted_callback = false,
			const Callable &p_task_callable = Callable());

	// -- Identifier resolvers (diagnostics ergonomics follow-up) --------------
	//
	// Public `DefinitionId -> identifier` resolvers so a diagnostic overlay
	// (or any other caller) can resolve the raw numeric ids carried by
	// `tag_changed`/`attribute_changed` change records without reimplementing
	// a lookup of its own. Empty string if unresolvable or not yet
	// configured.
	String resolve_tag_identifier(int64_t p_id) const;
	String resolve_attribute_identifier(int64_t p_id) const;
	// Wave 4 (add-granular-delta-replication-2026-07-27, task 4.2): the same
	// resolver shape as the two above, for the one identifier domain they
	// did not yet cover. `GameplayAbilityNetworkBridge`'s observer-side
	// public-delta apply path uses this to resolve a scratch mirror
	// component's raw `DefinitionId`s back to ability identifier strings
	// WITHOUT the mirror itself needing its own registry access -- see
	// `build_scratch_mirror()`'s own doc comment for why the mirror shares
	// THIS component's registries, which is exactly what makes resolving
	// through `this` (rather than the mirror) correct.
	String resolve_ability_identifier(int64_t p_id) const;

	// -- Per-ability target-data schema (task 7.16) ---------------------------
	//
	// `{schema: String, max_targets: int, max_payload_bytes: int}` resolved
	// for `p_ability_identifier` at `configure()` time from
	// `target_data_schemas`, or an empty Dictionary if this ability declared
	// no `target_schema` (only the protocol's global bounds apply then).
	// `GameplayAbilityNetworkBridge`'s authority validation point
	// (`_rpc_activation_command`) is the caller that actually enforces this
	// against a decoded command's cardinality/byte size, before the
	// game-provided target-authorization callback and before any mutation.
	Dictionary get_target_data_schema_for_ability(const String &p_ability_identifier) const;

	void _notification(int p_what);

	// -- C++-only collaborator seams (NOT ClassDB-bound -- Variant cannot
	// marshal these core types; reachable only from other native/godot/ code
	// in the SAME module, exactly like ga_ability_component.h's own
	// "compose, do not edit" seams) -------------------------------------------
	//
	// Owned only for `ROLE_NETWORK_CLIENT` after a successful `configure()`
	// (task 8.10); nullptr otherwise -- see that method's body for why
	// ownership lives here rather than on `GameplayAbilityNetworkBridge`.
	ga::PredictingComponent *predicting_component() { return predicting.get(); }
	const ga::PredictingComponent *predicting_component() const { return predicting.get(); }
	ga::PredictionReconciler *prediction_reconciler() { return reconciler.get(); }
	ga::AbilityComponent *core_component() { return component.get(); }
	const ga::AbilityComponent *core_component() const {
		return component.get();
	}
	const ga::TargetSchemaRegistry &target_schema_registry() const {
		return core_target_schemas;
	}

	// Wave 4 (add-granular-delta-replication-2026-07-27, task 4.2, "Sequenced
	// Observer Delta Streams"): builds a freshly constructed, otherwise
	// untouched `ga::AbilityComponent` sharing THIS component's already-
	// sealed registries (`core_abilities`/`core_effects`/`core_attributes`/
	// `core_tags`) and this component's own entity id/role, with no tag-
	// reaction registry (a passive display mirror never evaluates reactions
	// -- see the core constructor's own `p_reactions` doc comment) and no
	// listeners registered (canonical restore/delta-apply installs state
	// directly via `install_records`, never through
	// `Transaction`/`NotificationQueue`, so there is nothing for a listener
	// to observe here). `GameplayAbilityNetworkBridge`'s observer-side
	// public-delta apply path (`apply_public_delta`) uses this to build (and,
	// on every fresh baseline, REBUILD -- see that method's own doc comment
	// for why a stale mirror must be discarded rather than reused across a
	// resync) the scratch component `ga::proto::decode_and_apply_delta_batch`
	// installs canonical PUBLIC-audience state onto, reusing that SAME
	// validate-then-mutate codec an owner's confirmed baseline already uses
	// rather than a second delta interpreter. Returns nullptr if
	// `!is_configured()` (nothing sealed yet to share).
	std::unique_ptr<ga::AbilityComponent> build_scratch_mirror() const;

	// Finding 2a + Finding 5: the ONE seam `GameplayAbilityNetworkBridge`
	// uses whenever a fresh authoritative payload (a SNAPSHOT, or an
	// EVENT_BATCH -- both carry a full canonical snapshot, see that file's
	// "Deliberate v1 scope reductions") arrives for a `ROLE_NETWORK_CLIENT`
	// component that is CURRENTLY PREDICTING (`predicting_component()->
	// journal().pending_count() > 0`): replays every still-pending journaled
	// command on top of the fresh baseline via `ga::PredictionReconciler::
	// reconcile(p_confirmed_snapshot, p_tick, p_stream, nullptr)` (preserved
	// identity -- see that method's own doc comment), restoring
	// `p_confirmed_snapshot`'s bytes EXACTLY ONCE (reconcile() performs its
	// own restore internally -- never ALSO call `restore_snapshot()` for the
	// SAME payload). WITH the same atomic-replacement guarantee
	// `restore_snapshot()` provides for the plain (non-predicting) path:
	// this component's pre-restore state is captured first via
	// `write_snapshot()`, and rolled back to (or, failing that, quarantined
	// -- see `rollback_or_quarantine()`) if `reconcile()` reports
	// `ga::ReconciliationOutcomeKind::COMPONENT_MUST_BE_REBUILT`. Returns
	// the same `ga::ReconciliationResult` `reconcile()` produced, unchanged
	// either way -- the caller distinguishes success from failure via
	// `result.outcome` exactly as it would calling `reconcile()` directly;
	// this wrapper only adds the atomicity guarantee underneath, never
	// changes reconcile's own contract surface (including its own resend
	// decision: this method never resends anything, matching `reconcile()`
	// itself).
	//
	// `p_apply_events` (add-granular-delta-replication-2026-07-27, task 4.3):
	// forwarded UNCHANGED to `ga::PredictionReconciler::reconcile`'s own
	// `AuthoritativeEventApplier` parameter -- see that method's doc comment
	// for the exact restore-then-apply-then-replay ordering it guarantees.
	// Defaults to `nullptr` (every pre-existing caller: plain restore, no
	// extra events to layer on) so this signature change is purely additive.
	ga::ReconciliationResult reconcile_snapshot(
			const std::vector<std::uint8_t> &p_confirmed_snapshot,
			ga::Tick p_tick,
			const ga::proto::ClientEventStream &p_stream,
			const ga::AuthoritativeEventApplier &p_apply_events = nullptr,
			ga::GameplayAbilityWorldCoordinator *p_target_coordinator =
					nullptr);

	// Builds one `ga::ActivationRequest` from a request Dictionary. Returns
	// false (leaving r_request untouched) on a malformed shape so the caller
	// can fail closed with STATUS_INVALID_ARGUMENT rather than guessing.
	// Public so `GameplayAbilityNetworkBridge` can build the SAME request
	// shape to feed `predicting_component()->request(...)` before encoding
	// the wire command (task 8.10).
	bool build_activation_request(const Dictionary &p_request, ga::ActivationRequest &r_request) const;
	bool build_gameplay_event(const Dictionary &p_event, ga::GameplayEventContext &r_event) const;
	bool build_ability_task_request(
			const Ref<GameplayAbilityTaskRequest> &p_request,
			ga::AbilityTaskRequest &r_request) const;

	// Task 7.16/7.20: the ONE implementation of per-ability target-data
	// schema cardinality/byte-bound enforcement -- both
	// `GameplayAbilityNetworkBridge::validate_target_data_schema` (the
	// networked authority path, `_rpc_activation_command`) and THIS
	// component's own `request_activation`/`process_activation_batch` (the
	// direct/offline path) delegate to this method rather than duplicating
	// its logic, so a per-ability schema can never be enforced on one
	// activation path and silently skipped on the other. Public (like
	// `build_activation_request` above) so the bridge can call it directly;
	// NOT ClassDB-bound (see this section's own header comment) since
	// `std::vector<ga::EntityId>`/`std::vector<ga::SetByCallerMagnitude>` are
	// not Variant-marshalable -- a script exercises the identical check
	// indirectly through `request_activation`/`process_activation_batch`
	// (which now run it) or inspects a schema's raw bounds directly via the
	// already-bound `get_target_data_schema_for_ability`.
	//
	// Resolves `p_ability_identifier`'s bounds directly from
	// `ability_target_schema_bounds` (no per-ability schema declared, or an
	// unrecognized identifier, is `ok_status()` -- only the protocol's global
	// `MAX_TARGETS_PER_COMMAND`/`MAX_SET_BY_CALLER` bounds apply then, exactly
	// like `get_target_data_schema_for_ability`'s own empty-Dictionary case).
	// Otherwise fails, before any mutation, with:
	//   - `StatusCode::ABILITY_INVALID_TARGET` /
	//     `DiagnosticId::COUNT_LIMIT_EXCEEDED` if `p_targets.size()` exceeds
	//     the schema's declared `max_targets`.
	//   - `StatusCode::PAYLOAD_TOO_LARGE` / `DiagnosticId::BYTE_LIMIT_EXCEEDED`
	//     if the SAME encoded shape `encode_activation_command` writes for one
	//     command's target-data portion (entity ids, then set-by-caller
	//     fields -- measured with a `ga::ByteWriter` probe, never an
	//     approximation) exceeds `max_payload_bytes`.
	ga::Status validate_target_data_schema(const String &p_ability_identifier, const std::vector<ga::EntityId> &p_targets,
			const std::vector<ga::SetByCallerMagnitude> &p_set_by_caller) const;

	// Finding 6d: the ONE shared `set_by_caller` Array-of-Dictionaries ->
	// `std::vector<ga::SetByCallerMagnitude>` converter, replacing what used
	// to be three independently hand-copied (and disagreeing) inline
	// conversions -- here (via `build_activation_request`),
	// `build_pending_remote_effect_command` below, and
	// `GameplayAbilityCommandBuilder::submit` (gameplay_ability_command_builder.cpp,
	// a different native/godot/ file, hence this being public and static
	// rather than a private free function). Every prior copy silently
	// truncated at `ga::MAX_SET_BY_CALLER` and substituted a zero magnitude
	// for a value that failed fixed-point quantization; this one instead
	// fails closed -- returns false and leaves `r_out` untouched -- if
	// `p_fields.size()` exceeds the limit OR any entry's value cannot be
	// exactly quantized, matching `build_activation_request`'s own
	// pre-existing (and correct) fail-closed convention. A caller that gets
	// `false` back must reject the whole command, never proceed with a
	// partial/corrupted result.
	static bool parse_set_by_caller_fields(const Array &p_fields, std::vector<ga::SetByCallerMagnitude> &r_out);

	// Resolves an effect identifier to its sealed `DefinitionId` (0/
	// INVALID_DEFINITION_ID if unregistered or not yet configured). Used by
	// `GameplayAbilityCommandBuilder::submit` (gameplay_ability_hook_bridge.*)
	// to turn a script-submitted command's string identifier into the id
	// `ga::AbilityCommandBuilder::submit` expects, without exposing the
	// private `core_effects` registry itself.
	ga::DefinitionId resolve_effect_definition_id(const std::string &p_identifier) const;

	// Same shape as `resolve_effect_definition_id` immediately above, for the
	// three sections `ga::AudienceVisibilityConfig` (core/ga_change_tracking.h)
	// hides by `DefinitionId` set membership (add-granular-delta-replication-
	// 2026-07-27, task 3.x "Wire the visibility seam"). Used by
	// `GameplayAbilityNetworkBridge::set_hidden_attribute_identifiers`/
	// `set_hidden_tag_identifiers`/`set_hidden_ability_identifiers` to
	// translate their script-facing `PackedStringArray` identifiers into the
	// core identities `AudienceVisibilityConfig` actually stores, without
	// exposing the private `core_attributes`/`core_tags`/`core_abilities`
	// registries themselves. 0 (`INVALID_DEFINITION_ID`) if unregistered or
	// not yet configured -- a caller filters those out before inserting into
	// a hidden set (an invalid identity can never legitimately match a real
	// attribute/tag/ability, so a naive insert would be harmless, but a
	// caller counting "did this set actually change" needs the clean
	// signal).
	ga::DefinitionId resolve_attribute_definition_id(const std::string &p_identifier) const;
	ga::DefinitionId resolve_tag_definition_id(const std::string &p_identifier) const;
	ga::DefinitionId resolve_ability_definition_id(const std::string &p_identifier) const;

	// Immutable, read-only Dictionary snapshot of a `ga::AbilityExecutionContext`
	// -- the value a script-authored hook actually receives (task 6.10). Every
	// attribute/tag id is already resolved to its identifier string here so a
	// hook never has to cross-reference a registry itself.
	Dictionary ability_execution_context_dict(const ga::AbilityExecutionContext &p_context) const;
	Dictionary ability_task_event_dict(const ga::AbilityTaskEvent &p_event) const;

protected:
	static void _bind_methods();

private:
	// Finding 5: shared rollback-then-quarantine leg BOTH `restore_snapshot()`
	// (plain path) and `reconcile_snapshot()` (reconcile-driven path) call on
	// a restore failure, so there is exactly one rollback/quarantine
	// implementation, not two duplicated ones. `p_pre_state`: this
	// component's own canonical snapshot bytes, captured via
	// `write_snapshot()` BEFORE the failed attempt. Restored directly
	// through the CORE `ga::AbilityComponent::restore_snapshot(SnapshotReader&)`
	// -- NEVER recursively through this wrapper's OWN `restore_snapshot()`,
	// which would re-capture "pre-state" from whatever the failed attempt
	// left behind instead of the known-good bytes the caller already
	// captured, and would pointlessly re-enter this same rollback path.
	// `p_original_failure`: the Status the failed restore/reconcile attempt
	// produced, carried into `desync_rebuild_required` if this component
	// ends up quarantined, so the game can see WHY.
	//
	// On success, this component is back to the known-good pre-state (still
	// `is_configured()`). On failure -- the captured pre-state could not be
	// restored back either, which should not happen in practice given it
	// was written from a live component moments earlier, but "should not
	// happen" is exactly what fail-closed defends against -- this component
	// is genuinely unrecoverable: `quarantined` is set (so `is_configured()`
	// now reports false and every mutating entry point fails closed) and
	// `desync_rebuild_required` is emitted so the game knows to discard this
	// instance and rebuild via a fresh `configure()`.
	void rollback_or_quarantine(const PackedByteArray &p_pre_state, const ga::Status &p_original_failure);
	// Non-static (unlike most of this file's other record converters) only
	// because it now also resolves `pending_remote_effects` entries' effect
	// identifiers (task 6.13), which needs this instance's own `core_effects`
	// registry -- see `effect_identifier_of`.
	Dictionary activation_result_dict(const ga::ActivationResult &p_result) const;
	// Task 7.20: shared by `request_activation`/`process_activation_batch` --
	// resolves `p_request.spec`'s grant (if any) and, if that ability
	// declares a target-data schema, enforces it via
	// `validate_target_data_schema` BEFORE the request ever reaches the core
	// (see that method's own header doc comment for why direct/offline
	// activation must enforce the exact same schema the networked
	// `GameplayAbilityNetworkBridge` path already does). No grant at all is
	// deliberately NOT a failure here: the core's own
	// `request_activation`/`process_activation_batch` already reject an
	// unrecognized spec with its normal `UNKNOWN_ABILITY` status, so this
	// never invents an earlier failure path for that case.
	ga::Status validate_activation_request_schema(const ga::ActivationRequest &p_request) const;
	static Dictionary cancellation_result_dict(const ga::CancellationResult &p_result);
	Dictionary grant_dict(const ga::AbilityGrant &p_grant) const;
	Dictionary execution_dict(const ga::ActiveExecution &p_execution) const;
	Dictionary active_effect_dict(const ga::ActiveEffect &p_effect) const;
	Dictionary lifecycle_event_dict(const ga::AbilityLifecycleEvent &p_event) const;
	static Dictionary diagnostic_event_dict(const ga::AbilityDiagnosticEvent &p_event);
	static Dictionary attribute_change_dict(const ga::AttributeChangeRecord &p_record);
	static Dictionary tag_change_dict(const ga::TagChangeRecord &p_record);
	Dictionary effect_lifecycle_dict(const ga::EffectLifecycleEvent &p_event) const;
	Dictionary effect_cue_dict(const ga::EffectCueEvent &p_event) const;
	Dictionary target_effect_context_dict(
			const ga::TargetEffectContext &p_context) const;

	// Task 6.13: converts one/every `ga::PendingRemoteEffectCommand` to the
	// Dictionary shape `apply_pending_remote_effect` below parses back.
	Dictionary pending_remote_effect_dict(const ga::PendingRemoteEffectCommand &p_command) const;
	Array pending_remote_effects_array(const std::vector<ga::PendingRemoteEffectCommand> &p_commands) const;
	// Inverse of the above. Returns false (leaving r_command untouched) on a
	// malformed shape or an unresolvable effect identifier, matching
	// `build_activation_request`'s own fail-closed convention.
	bool build_pending_remote_effect_command(const Dictionary &p_command, ga::PendingRemoteEffectCommand &r_command) const;

	String ability_identifier_of(ga::DefinitionId p_id) const;
	String effect_identifier_of(ga::DefinitionId p_id) const;
	String tag_identifier_of(ga::DefinitionId p_id) const;
	String attribute_identifier_of(ga::DefinitionId p_id) const;

	// Dictionary shape `notify_prediction_phase` expects for one
	// `ga::PredictionPresentationEvent` -- see that method's doc comment.
	Dictionary prediction_presentation_dict(const ga::PredictionPresentationEvent &p_event) const;
	Dictionary ability_task_request_dict(
			const ga::AbilityTaskRequest &p_request) const;
	Dictionary active_ability_task_dict(
			const ga::ActiveAbilityTask &p_task) const;

	void register_core_listeners();
	void emit_configure_finding(Array &r_findings, const String &p_severity, const String &p_field,
			const String &p_code, const String &p_message) const;

	Role role = ROLE_OFFLINE_AUTHORITY;
	int64_t entity_id_value = 0;
	// Task 7.19: see set_tick_rate()'s doc comment for why this component,
	// not the bridge, is tick rate's authoritative home.
	int tick_rate = int(ga::DEFAULT_TICK_RATE);

	TypedArray<GameplayTagDefinition> tag_definitions;
	TypedArray<GameplayAttributeDefinition> attribute_definitions;
	TypedArray<GameplayEffectDefinition> effect_definitions;
	TypedArray<GameplayCueDefinition> cue_definitions;
	Array ability_definitions;
	TypedArray<GameplayTargetDataSchema> target_data_schemas;
	Ref<GameplayDefinitionCatalog> definition_catalog;

	// Declaration order matters: these must outlive, and be destroyed after,
	// `component` (see ga_ability_component.h: AttributeSet/TagContainer/
	// EffectRuntime/AbilitySpec all hold non-owning pointers back into
	// these). `component` is declared last so its destructor -- which tears
	// down every runtime record referencing these registries -- runs FIRST.
	ga::TagRegistry core_tags;
	ga::AttributeRegistry core_attributes;
	ga::EffectRegistry core_effects;
	ga::AbilityRegistry core_abilities;
	ga::TargetSchemaRegistry core_target_schemas;
	// Task 5.1: only registered and sealed when a catalog resolves (see
	// configure()'s own comment) -- stays default-constructed and unsealed,
	// UNUSED, for a legacy (no catalog) component, matching every other
	// registry's "component-local, never shared" contract above.
	ga::TagReactionRegistry core_reactions;

	std::unique_ptr<ga::AbilityComponent> component;

	// Task 8.10: owned only for ROLE_NETWORK_CLIENT, constructed once at the
	// end of a successful configure(). `reconciler` composes over
	// `predicting` (ga_reconciliation.h's own constructor requirement) so it
	// is declared after it and therefore destroyed first.
	std::unique_ptr<ga::PredictingComponent> predicting;
	std::unique_ptr<ga::PredictionReconciler> reconciler;

	// Task 6.10: script-authored hook adapters this component owns for the
	// lifetime of the session (the core only ever stores a non-owning
	// pointer -- see ga_ability_component.h's bind_authority_hook/
	// bind_prediction_safe_hook doc comments -- so SOMETHING has to keep the
	// adapter alive; this component is that something, exactly like it
	// already owns `component` itself).
	std::vector<std::unique_ptr<ScriptAuthorityAbilityHook>> script_authority_hooks;
	std::vector<std::unique_ptr<ScriptPredictionSafeAbilityHook>> script_prediction_hooks;

	// Task 7.16: ability DefinitionId -> its resolved target-data schema
	// bounds, built once at the end of a successful configure() from
	// `target_data_schemas` and each ability's own `target_schema`
	// reference. Absent entry means "no per-ability schema declared."
	struct TargetSchemaBounds {
		String identifier;
		int64_t max_targets = 0;
		int64_t max_payload_bytes = 0;
	};
	std::map<ga::DefinitionId, TargetSchemaBounds> ability_target_schema_bounds;

	// Dedicated allocator for the manual Transactions initialize_attribute()
	// builds (ga::AbilityComponent has no wrapper for this core call, and
	// its own internal transaction allocator is private -- see that
	// method's doc comment). A separate id space from the component's own
	// internal transaction ids is harmless: TransactionId is only ever used
	// for diagnostics/ordering within one change-record stream, never
	// cross-referenced against another allocator's values.
	ga::HandleAllocator<ga::TransactionId> attribute_init_transaction_allocator;

	ga::Tick current_tick = 0;
	bool teardown_requested = false;
	int64_t manifest_fingerprint = 0;

	// Finding 5: set only when a snapshot restore's own ROLLBACK also fails
	// (see `rollback_or_quarantine()`) -- this component is then genuinely
	// unrecoverable. Folded into `is_configured()` (see that method's own
	// doc comment) so every mutating entry point, almost all of which
	// already gate on it, fails closed automatically; cleared only by
	// `configure()` successfully building a brand-new `component`.
	bool quarantined = false;
};

} // namespace godot

VARIANT_ENUM_CAST(GameplayAbilityComponent::Role);
VARIANT_ENUM_CAST(GameplayAbilityComponent::Provenance);
VARIANT_ENUM_CAST(GameplayAbilityComponent::Phase);
VARIANT_ENUM_CAST(GameplayAbilityComponent::EndReason);
VARIANT_ENUM_CAST(GameplayAbilityComponent::LifecycleKind);
VARIANT_ENUM_CAST(GameplayAbilityComponent::DiagnosticEventKind);
VARIANT_ENUM_CAST(GameplayAbilityComponent::EffectLifecycleKind);
VARIANT_ENUM_CAST(GameplayAbilityComponent::EffectRemovalReason);
VARIANT_ENUM_CAST(GameplayAbilityComponent::CuePhase);
VARIANT_ENUM_CAST(GameplayAbilityComponent::TaskKind);
VARIANT_ENUM_CAST(GameplayAbilityComponent::TaskOutcome);
VARIANT_ENUM_CAST(GameplayAbilityComponent::TaskCancelReason);
VARIANT_ENUM_CAST(GameplayAbilityComponent::LogicalInputPhase);
VARIANT_ENUM_CAST(GameplayAbilityComponent::StatusCode);

#endif // GAMEPLAY_ABILITIES_GODOT_ABILITY_COMPONENT_H
