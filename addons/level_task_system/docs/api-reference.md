# API reference

This reference separates the API Godot actually registers from the native C++
source surface. All names and defaults below describe the current 0.1.0
snapshot.

## Godot API availability

Godot registers `LevelTaskSystemVersion` and the 15 `LevelTask*` Resource
classes listed below. On Resources, only property getters and setters (plus the
`identifier_value` alias on `LevelTaskValue`) are bound.

The following C++ methods are **not** available to GDScript:

- every `to_core_*()` / `to_core_definition()` conversion;
- `validate_core()`;
- `get_core_fingerprint()`;
- catalog/compiler/runtime/migration methods;
- native `Status`, `Diagnostic`, request/trace records; and
- native snapshot encode/restore.

Use ordinary property syntax in GDScript. All Resource setters call
`emit_changed()`, but that signal is not proof that the value is valid.

## `LevelTaskSystemVersion`

`LevelTaskSystemVersion` derives from `RefCounted`; all of its methods are
static.

| Method | Current result |
| --- | --- |
| `get_api_version()` | `"0.1.0"` |
| `get_api_version_major()` | `0` |
| `get_api_version_minor()` | `1` |
| `get_api_version_patch()` | `0` |
| `get_protocol_version()` | `1` |
| `get_level_definition_schema_version()` | `1` |
| `get_task_graph_definition_schema_version()` | `1` |
| `get_conversation_definition_schema_version()` | `1` |
| `get_speaker_definition_schema_version()` | `1` |
| `get_provider_definition_schema_version()` | `1` |
| `get_resource_schema_version()` | `1` |
| `get_snapshot_schema_version()` | `1` |
| `get_canonical_format_version()` | `1` |
| `get_catalog_fingerprint_algorithm()` | `"fnv1a64-canonical-v1"` |
| `get_manifest_algorithm()` | `"fnv1a64-canonical-v1"` |
| `get_supported_features()` | bitmask `63` in this version |
| `has_feature(feature)` | `true` if all requested bits are set |

Feature constants:

| Constant | Value |
| --- | ---: |
| `FEATURE_LEVEL_DEFINITIONS` | 1 |
| `FEATURE_TASK_GRAPHS` | 2 |
| `FEATURE_CONVERSATIONS` | 4 |
| `FEATURE_CATALOG_VALIDATION` | 8 |
| `FEATURE_SNAPSHOTS` | 16 |
| `FEATURE_DETERMINISTIC_RUNTIME` | 32 |

These flags advertise the package/native contract, not GDScript method
availability. Check `ClassDB.class_exists()` and `has_method()` for the exact
surface required by a script.

## Registered Resources

### `LevelTaskValue`

Closed value used by predicates, parameters, events, requests, and responses.
The Inspector shows only the payload for the selected `type`.

| Property | Type | Meaning |
| --- | --- | --- |
| `type` | enum | Selects exactly one payload. |
| `boolean_value` | `bool` | Boolean payload. |
| `integer_value` | `int` | Signed integer payload. |
| `fixed_raw` | `int` | Fixed-point raw units; divide by 1,000,000 for the conceptual value. |
| `string_value` | `String` | UTF-8 string payload, max 256 bytes after native validation. |
| `text_value` | `String` | Global stable ID payload when type is Identifier. |
| `bytes_value` | `PackedByteArray` | Byte payload, max 1,024 bytes after native validation. |

`set_identifier_value()` and `get_identifier_value()` are bound aliases for
`text_value`; `identifier_value` is not a separate Inspector property.

| Enum | Value |
| --- | ---: |
| `VALUE_NONE` | 0 |
| `VALUE_BOOLEAN` | 1 |
| `VALUE_INTEGER` | 2 |
| `VALUE_FIXED` | 3 |
| `VALUE_STRING` | 4 |
| `VALUE_IDENTIFIER` | 5 |
| `VALUE_BYTES` | 6 |

### `LevelTaskFactPredicate`

| Property | Type | Meaning |
| --- | --- | --- |
| `provider_identifier` | `StringName` | Global ID of a Fact provider. |
| `fact_identifier` | `StringName` | Global ID of the fact inside the provider contract. |
| `comparator` | enum | Typed comparison operator. |
| `expected` | `LevelTaskValue` | Required expected value. |

Comparators in order: `COMPARISON_EQUAL` (0), `COMPARISON_NOT_EQUAL` (1),
`COMPARISON_LESS` (2), `COMPARISON_LESS_OR_EQUAL` (3),
`COMPARISON_GREATER` (4), and `COMPARISON_GREATER_OR_EQUAL` (5).

### `LevelTaskLocalizedParameter`

| Property | Type | Meaning |
| --- | --- | --- |
| `identifier` | `StringName` | Local substitution name. |
| `value` | `LevelTaskValue` | Closed substitution value. |

### `LevelTaskPortDefinition`

| Property | Type | Meaning |
| --- | --- | --- |
| `identifier` | `StringName` | Local port ID. |
| `direction` | enum | `PORT_INPUT` (0) or `PORT_OUTPUT` (1). |
| `value_type` | `LevelTaskValue.ValueType` | Closed payload type; built-in control-flow ports use None. |
| `required` | `bool` | Requires at least one connection when compiled. |

### `LevelTaskNodeDefinition`

| Property | Type | Used by |
| --- | --- | --- |
| `identifier` | `StringName` | All nodes; local ID. |
| `schema_version` | `int` | All nodes; must be 1. |
| `kind` | enum | All nodes. |
| `ports` | `Array[LevelTaskPortDefinition]` | All nodes. |
| `provider_identifier` | `StringName` | Objective, Condition, External Action, Reward Request. |
| `objective_target` | `int` | Objective; 1 through 1,000,000. |
| `filters` | `Array[LevelTaskFactPredicate]` | Objective and Condition. |
| `parameters` | `Array[LevelTaskValue]` | Provider-backed request nodes. |
| `conversation_identifier` | `StringName` | Conversation. |
| `conversation_entry_label` | `StringName` | Conversation. |
| `accepted_outcomes` | `PackedStringArray` | Conversation; also defines dynamic output IDs. |
| `subgraph_identifier` | `StringName` | Subgraph. |
| `outcome_identifier` | `StringName` | Terminal nodes. |

Node enum values and required data:

| Kind | Value | Required kind-specific fields |
| --- | ---: | --- |
| `NODE_ENTRY` | 0 | none |
| `NODE_OBJECTIVE` | 1 | `provider_identifier`, valid `objective_target` |
| `NODE_CONDITION` | 2 | `provider_identifier` |
| `NODE_ALL_GATE` | 3 | none |
| `NODE_ANY_GATE` | 4 | none |
| `NODE_EXTERNAL_ACTION` | 5 | `provider_identifier` |
| `NODE_CONVERSATION` | 6 | conversation ID, entry label, at least one accepted outcome |
| `NODE_SUBGRAPH` | 7 | `subgraph_identifier` |
| `NODE_REWARD_REQUEST` | 8 | `provider_identifier` |
| `NODE_SUCCESS_TERMINAL` | 9 | `outcome_identifier` |
| `NODE_FAILURE_TERMINAL` | 10 | `outcome_identifier` |
| `NODE_CANCELLED_TERMINAL` | 11 | `outcome_identifier` |

The Inspector hides irrelevant properties when `kind` changes.

### `LevelTaskEdgeDefinition`

| Property | Type |
| --- | --- |
| `identifier` | local `StringName` |
| `schema_version` | `int`, must be 1 |
| `from_node_identifier` | local node ID |
| `from_port_identifier` | local output-port ID |
| `to_node_identifier` | local node ID |
| `to_port_identifier` | local input-port ID |

### `LevelTaskGraphDefinition`

| Property | Type | Contract |
| --- | --- | --- |
| `identifier` | `StringName` | Global graph ID. |
| `schema_version` | `int` | Must be 1. |
| `entry_node_identifier` | `StringName` | Local ID of the one entry node. |
| `terminal_outcomes` | `PackedStringArray` | Nonempty, unique local outcome IDs. |
| `nodes` | `Array[LevelTaskNodeDefinition]` | Nonempty; max 256. |
| `edges` | `Array[LevelTaskEdgeDefinition]` | Max 512; authored order is semantic. |
| `max_transitions_per_advance` | `int` | 1 through 1,024; default 1,024. |

### `LevelTaskLevelAnchorDefinition`

| Property | Type | Meaning |
| --- | --- | --- |
| `identifier` | `StringName` | Local anchor ID. |
| `kind` | enum | `ANCHOR_POINT` (0), `ANCHOR_TRANSFORM` (1), or `ANCHOR_AREA` (2). |
| `required` | `bool` | Whether the host must resolve the binding. |
| `binding_label` | `String` | Host-defined scene binding label, max 128 bytes. |

### `LevelTaskLevelExitDefinition`

| Property | Type | Meaning |
| --- | --- | --- |
| `identifier` | `StringName` | Local exit ID. |
| `target_level_identifier` | `StringName` | Global destination level ID. |
| `target_anchor_identifier` | `StringName` | Local anchor ID in the target level. |
| `outcome_identifier` | `StringName` | Local semantic outcome. |

### `LevelTaskLevelDefinition`

| Property | Type | Contract |
| --- | --- | --- |
| `identifier` | `StringName` | Global level ID. |
| `schema_version` | `int` | Must be 1. |
| `display_name_key` | `StringName` | Required localization key. |
| `description_key` | `StringName` | Optional localization key. |
| `scene_resource` | `String` | Required descriptive path/reference, max 512 bytes; not a `PackedScene`. |
| `availability_rules` | `Array[LevelTaskFactPredicate]` | Max 32. |
| `entry_graph_identifiers` | `PackedStringArray` | 1–32 global graph IDs. |
| `anchors` | `Array[LevelTaskLevelAnchorDefinition]` | Max 128. |
| `exits` | `Array[LevelTaskLevelExitDefinition]` | Max 64. |

### `LevelTaskConversationChoiceDefinition`

| Property | Type | Meaning |
| --- | --- | --- |
| `identifier` | `StringName` | Local choice ID; order among sibling choices is preserved. |
| `label_key` | `StringName` | Localization key. |
| `target_step_identifier` | `StringName` | Local destination step. |
| `conditions` | `Array[LevelTaskFactPredicate]` | All must match for the choice to be visible; max 8. |

### `LevelTaskConversationStepDefinition`

| Property | Type | Used by |
| --- | --- | --- |
| `identifier` | `StringName` | All steps; local ID. |
| `kind` | enum | All steps. |
| `speaker_identifier` | `StringName` | Line; global speaker ID. |
| `line_key` | `StringName` | Line localization key. |
| `parameters` | `Array[LevelTaskLocalizedParameter]` | Line (and native action payload source); max 8. |
| `next_step_identifier` | `StringName` | Line. |
| `provider_identifier` | `StringName` | Condition and External Action; global ID. |
| `conditions` | `Array[LevelTaskFactPredicate]` | Condition; max 8. |
| `true_step_identifier` / `false_step_identifier` | `StringName` | Condition. |
| `success_step_identifier` / `failure_step_identifier` | `StringName` | External Action. |
| `choices` | `Array[LevelTaskConversationChoiceDefinition]` | Choice; 1–16. |
| `target_step_identifier` | `StringName` | Jump. |
| `outcome_identifier` | `StringName` | Outcome. |

Step enum values and required data:

| Kind | Value | Required fields |
| --- | ---: | --- |
| `STEP_LINE` | 0 | speaker, line key, next step |
| `STEP_CHOICE` | 1 | at least one choice |
| `STEP_CONDITION` | 2 | provider, true target, false target |
| `STEP_EXTERNAL_ACTION` | 3 | provider, success target, failure target |
| `STEP_JUMP` | 4 | target step |
| `STEP_OUTCOME` | 5 | outcome ID |

The Inspector hides irrelevant fields. In this snapshot it also hides the
external-action `provider_identifier` and `parameters` even though native
validation requires the provider and the runtime can use the parameters; set
those properties from script or serialized data if necessary.

### `LevelTaskSpeakerDefinition`

| Property | Type | Contract |
| --- | --- | --- |
| `identifier` | `StringName` | Global speaker ID. |
| `schema_version` | `int` | Must be 1. |
| `display_name_key` | `StringName` | Required localization key. |
| `portrait_key` | `StringName` | Optional host key, not a Texture. |

### `LevelTaskConversationDefinition`

| Property | Type | Contract |
| --- | --- | --- |
| `identifier` | `StringName` | Global conversation ID. |
| `schema_version` | `int` | Must be 1. |
| `entry_label` | `StringName` | Local existing step ID. |
| `speaker_identifiers` | `PackedStringArray` | Unique global speaker IDs; max 64. |
| `terminal_outcomes` | `PackedStringArray` | Nonempty unique local outcomes; max 32. |
| `steps` | `Array[LevelTaskConversationStepDefinition]` | Nonempty; max 512. |
| `max_steps_per_advance` | `int` | 1–1,024; default 1,024. |
| `max_jumps_per_advance` | `int` | 1–256; default 256. |

### `LevelTaskProviderDeclaration`

| Property | Type | Contract |
| --- | --- | --- |
| `identifier` | `StringName` | Global provider ID. |
| `schema_version` | `int` | Must be 1. |
| `kind` | enum | Integration family. |
| `request_type` | `LevelTaskValue.ValueType` | Declared request payload type. |
| `response_type` | `LevelTaskValue.ValueType` | Declared response payload type. |
| `max_request_bytes` | `int` | 0–4,096. |
| `max_response_bytes` | `int` | 0–4,096. |
| `deterministic` | `bool` | Adapter-visible declaration; default true. |
| `authority_only` | `bool` | Adapter-visible declaration; default true. |

Provider kinds: `PROVIDER_FACT` (0), `PROVIDER_EVENT` (1),
`PROVIDER_CONDITION` (2), `PROVIDER_ACTION` (3), `PROVIDER_REWARD` (4),
`PROVIDER_LEVEL_TRANSITION` (5), and `PROVIDER_CONVERSATION` (6).

## Identifier grammar

```text
segment  := [a-z][a-z0-9_]*
local    := segment ("." segment)*
global   := segment "." segment ("." segment)*
```

Limits: 128 total UTF-8 bytes, at most eight segments, at most 32 bytes per
segment. Input is not trimmed, lowercased, Unicode-normalized, or otherwise
rewritten. Empty segments, uppercase characters, hyphens, spaces, and a
single-segment global ID are invalid.

## Built-in task ports

The compiler's default node registry resolves these ports. `input` has alias
`in`; Entry `entry` has alias `next`; All/Any outputs have alias `success`.
Aliases are converted to their canonical names in the compiled graph.

| Node kind | Inputs | Outputs |
| --- | --- | --- |
| Entry | — | `entry` (required, fan-out) |
| Objective | `input` (required) | `success`, `next`, `failure`, `timeout`, `cancelled` |
| Condition | `input` (required) | `true`, `false` |
| All Gate | dynamic inputs | `all` |
| Any Gate | dynamic inputs | `any` |
| External Action | `input` (required) | `accepted`, `rejected`, `success`, `failure`, `timeout`, `cancelled` |
| Conversation | `input` (required) | one dynamic output per accepted outcome |
| Subgraph | `input` (required) | dynamic outputs from authored edges |
| Reward Request | `input` (required) | `accepted`, `rejected`, `success`, `failure`, `timeout`, `cancelled` |
| Success/Failure/Cancelled Terminal | `input` (required) | — |

All built-in control-flow ports use value type None. A normal input accepts one
edge. Dynamic gate inputs and outputs that fan out remain bounded by the
16-port ceiling.

## Native C++ source API

These headers are packaged for source integration, but their types are not
ClassDB-bound and the 0.x package does not promise a stable binary ABI.

| Header | Main public types/operations |
| --- | --- |
| `native/core/lts_identifier.h` | global/local validation and stable identifiers |
| `native/core/lts_values.h` | closed `Value`, fixed point, predicates, comparisons |
| `native/core/lts_definitions.h` | all engine-independent definitions and fingerprints |
| `native/core/lts_catalog.h` | add/validate/seal/resolve/canonical-encode catalog |
| `native/core/lts_graph_compiler.h` | node registry, hooks, diagnostics, immutable compiled DAG |
| `native/core/lts_task_runtime.h` | facts/events, per-scope task instance, requests/results/records, snapshot codec |
| `native/core/lts_conversation_runtime.h` | render-neutral frames, choices/actions, snapshot codec |
| `native/core/lts_migration.h` | typed global/local rename preview and fail-atomic apply |
| `native/core/lts_status.h` | exception-free status and diagnostic values |

### Catalog lifecycle

```cpp
#include "core/lts_catalog.h"

lts::LevelTaskCatalog catalog;
lts::Status status = catalog.add_provider(provider, "providers/events.tres");
if (status.ok()) status = catalog.add_task_graph(graph, "tasks/first.tres");

lts::CatalogValidationReport report;
if (status.ok()) status = catalog.validate(report);
if (status.ok()) status = catalog.seal();

if (status.ok()) {
    const std::uint64_t identity = catalog.fingerprint();
    const lts::TaskGraphDefinition *stored =
        catalog.find_task_graph("game.task.first");
}
```

`add_*()` copies data. `find_*()` and `resolve_*()` fail closed until sealing.
`validate(report)` retains at most 64 findings and exposes the total/truncated
state. `encode_canonical()` returns the exact bytes hashed by `fingerprint()`.

### Compile and start a task

```cpp
#include "core/lts_graph_compiler.h"
#include "core/lts_task_runtime.h"

lts::TaskGraphCompiler compiler;
lts::CanonicalTaskGraph compiled;
std::vector<lts::Diagnostic> diagnostics;
lts::Status status = compiler.compile(graph, compiled, &diagnostics);

lts::TaskGraphInstance instance;
lts::TaskAdvanceResult started;
if (status.ok()) {
    status = lts::TaskGraphInstance::create(
        compiled,
        "game.instance.first",
        "game.scope.player_one",
        instance,
        lts::TaskRuntimeLimits{},
        &started
    );
}
```

Key task methods:

- `advance(events, facts, tick, result)` / `tick(tick, facts, result)`;
- `acknowledge_request(id, outcome, response, tick, expected_revision, result)`;
- `reject_request(...)` and `timeout_request(...)`;
- `emit_level_transition_request(...)`;
- accessors for status, revision, terminal outcome, node states, pending/resolved
  requests, and bounded transition/state/trace history; and
- `clear_records()` to discard retained observability records; and
- `encode_snapshot(bytes)` / `restore_snapshot(bytes)`, plus static
  `restore_snapshot(graph, bytes, instance, limits)` / `from_snapshot(...)`.

The bounded V1 task codec stores the graph identity, runtime limits, revisions,
tick/event cursors, node and edge state, facts, pending/resolved requests, and
retained records. Restore checks the compiled graph fingerprint and validates a
complete candidate before publishing it. These methods are native C++
source-only and are not registered with Godot; treat the pre-release native ABI
as revision-specific.

### Start a conversation

```cpp
#include "core/lts_conversation_runtime.h"

lts::ConversationInstance instance;
lts::Status status = instance.start(
    conversation,
    "game.conversation_instance.welcome_1",
    "game.scope.player_one"
);

if (status.ok() && instance.frame().is_line()) {
    const lts::ConversationFrame frame = instance.frame();
    // Host resolves frame.line_key and frame.parameters, renders them,
    // then submits the revision it actually displayed.
    status = instance.continue_line(frame.revision);
}
```

Key conversation methods:

- `configure(definition)` and `start(...)`;
- `frame()`, `available_choices()`, status/revision/identity accessors;
- `set_facts(snapshot)`;
- `continue_line(revision)` and `select_choice(id, revision)`;
- `acknowledge_action`, `reject_action`, and `timeout_action`;
- `encode_snapshot(bytes)` / `restore_snapshot(bytes)`; and
- static fail-atomic restore into a fresh instance with an expected definition.

### Rename migration

`LevelTaskMigrationPlanner::preview()` requires a sealed catalog. A
`RenameMapping` is typed as global or local; local mappings specify their owner
definition and, for nested namespaces such as ports/choices/parameters, may
specify a nested owner. Preview returns catalog paths and decoded save-field
entries. Apply verifies the source fingerprint and produces a fresh sealed
catalog; it never edits files or parses a game save.

## Hard limits

| Area | Limit |
| --- | ---: |
| Global definitions | 1,024 levels; 2,048 graphs; 2,048 conversations; 512 speakers; 512 providers |
| Graph | 256 nodes; 512 edges; 16 ports/node; 32 terminal outcomes |
| Node | 16 parameters; 16 filters; objective target 1,000,000 |
| Level | 32 entry graphs; 32 availability rules; 128 anchors; 64 exits |
| Conversation | 512 steps; 64 speakers; 16 choices/step; 8 choice conditions; 8 line parameters |
| Per advance | 1,024 task transitions; 1,024 conversation steps; 256 jumps; 128 events |
| Runtime | 64 pending task requests; 256 task facts/snapshot; 1,024 trace records; 512 state-change records |
| Payload | 1,024 bytes/value bytes; 4,096 provider/request parameter bytes; 1 MiB snapshot |
| Text | 256-byte string; 128-byte localization key; 512-byte scene reference; 256-byte diagnostic path |
| Subgraphs | maximum depth 16; task runtime execution currently unsupported |

Limits are part of canonical catalog identity. Reducing adapter limits is
allowed; raising them past package hard caps is rejected.

## Native statuses and diagnostics

Native public boundaries return `lts::Status` instead of throwing. Inspect:

- `code` — broad category such as `INVALID_IDENTIFIER`, `INVALID_REFERENCE`,
  `SCHEMA_MISMATCH`, `CATALOG_NOT_SEALED`, `GRAPH_INVALID`,
  `CONVERSATION_INVALID`, `CAPACITY_EXCEEDED`, or `NOT_SUPPORTED`;
- `diagnostic` — stable presentation-neutral reason; and
- `detail` — bounded numeric context whose interpretation depends on the
  diagnostic.

Compiler `Diagnostic` adds a bounded path. Catalog `CatalogDiagnostic` adds
`path` plus optional `related_path`. Do not expose only `status.ok()` in editor
or CI tooling; preserve the diagnostic identity and path so authors can fix the
right Resource field.
