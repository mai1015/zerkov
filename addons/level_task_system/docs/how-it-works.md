# How Level Task System works

Level Task System separates immutable authored definitions from mutable,
per-scope runtime state. The definition format is available to Godot as native
`Resource` classes. The catalog, compiler, runtimes, migration planner, and
diagnostic records are currently engine-independent C++ APIs only.

This distinction is the most important thing to understand when adopting the
0.1.0 package: installing the addon gives GDScript a safe authoring data model,
but it does not yet give GDScript a gameplay manager.

## Capability boundary

```text
REGISTERED WITH GODOT                     C++ SOURCE API ONLY

LevelTaskSystemVersion                    lts::LevelTaskCatalog
15 LevelTask* Resource classes    ---->   lts::TaskGraphCompiler
property getters/setters                  lts::TaskGraphInstance
Godot Resource load/save                  lts::ConversationInstance
                                          lts::LevelTaskMigrationPlanner
                                          Status/Diagnostic/snapshot records
```

No catalog, compiler, runtime, protocol object, diagnostic report, or snapshot
method is registered with `ClassDB`. The C++ conversion methods declared on the
Resource classes (`to_core_*`, `validate_core`, and
`get_core_fingerprint`) are also not bound. A GDScript call such as
`graph.validate_core()` therefore fails even though that method exists in the
C++ header.

The addon plugin itself performs one job: on `_enter_tree()` it checks four
required class names and emits a warning when the GDExtension failed to load.
It adds no dock, main screen, inspector plugin, importer, singleton, or runtime
owner. Files below `editor/components/` and the component showcase are
development fixtures, not a mounted product editor.

## The mental model

Think of the addon as five layers:

1. **Authoring Resources** hold editable data in `.tres`/`.res` files.
2. **Core definitions** are engine-independent, closed C++ values copied from
   those Resources by an adapter.
3. **Catalog and compiler** reject invalid references/topology, canonicalize
   content, and produce immutable identity.
4. **Per-scope runtimes** consume explicit facts/events or host responses and
   produce deterministic records, frames, and requests.
5. **Host adapters** own every side effect: localization, presentation, scene
   loading, rewards, network policy, save storage, and provider execution.

```text
       AUTHORS                         HOST STARTUP

   .tres Resources  --copy values-->  core definitions
                                            |
                                    validate each value
                                            |
                                    add to one catalog
                                            |
                                  cross-reference validation
                                            |
                                       seal + hash
                                            |
                             compile task graphs into DAGs
                                            |
       GAME LOOP                            v

 facts + ordered events ----------> per-scope task instance
                                            |
                                            +--> state/transition/trace records
                                            +--> action/reward/conversation requests
                                                         |
                                                         v
                                              game-owned provider adapter
                                                         |
                                               acknowledge/reject/timeout

 facts + player input -----------> per-scope conversation instance
                                            |
                                            +--> line/choice/action/outcome frame
                                                         |
                                                         v
                                              game-owned localized renderer
```

Definitions never become mutable authority state. A runtime instance owns a
canonical copy (or compiled form) plus its own progress, revision, facts, and
pending requests. Create separate instances for separate players, parties,
sessions, or server scopes.

## Authoring data model

### Closed values and predicates

`LevelTaskValue` intentionally does not wrap a general Godot `Variant`. It
stores exactly one of:

| Type | Authored field | Contract |
| --- | --- | --- |
| None | none | No payload. |
| Boolean | `boolean_value` | `true` or `false`. |
| Integer | `integer_value` | Signed 64-bit integer. |
| Fixed | `fixed_raw` | Signed raw units with scale 1,000,000. Raw `1500000` represents 1.5. |
| String | `string_value` | UTF-8 text, at most 256 bytes. |
| Identifier | `text_value` | A valid global stable identifier. |
| Bytes | `bytes_value` | At most 1,024 bytes. |

This prevents a script, `Object`, `Node`, `Callable`, RID, dictionary, or
floating-point platform difference from entering canonical data.

A `LevelTaskFactPredicate` names a fact by global provider ID plus global fact
ID, chooses a comparison operator, and supplies a typed expected value. Native
runtimes treat a missing fact or incompatible value type as not matching. The
host supplies facts; definitions never contain a live fact store.

### Providers

`LevelTaskProviderDeclaration` describes an integration seam, not executable
code. Its kind says how the reference may be used:

| Provider kind | Referenced by |
| --- | --- |
| Fact | fact predicates |
| Event | objective nodes |
| Condition | condition nodes and conversation condition steps |
| Action | external-action nodes and conversation action steps |
| Reward | reward-request nodes |
| Level Transition | host level-transition integration |
| Conversation | host conversation integration |

Request/response value types and byte ceilings describe the payload contract.
`deterministic` and `authority_only` are declarations for an adapter to enforce;
the core does not discover or call a Godot service by ID.

### Task graphs

A task graph is a directed acyclic graph (DAG) with:

- one global graph identifier;
- one local entry node identifier;
- one or more declared local terminal outcomes;
- nodes with local IDs and typed named ports;
- ordered edges connecting output ports to input ports; and
- a bounded transition budget per advance.

Node families:

| Node kind | Native behavior |
| --- | --- |
| Entry | Activates at instance creation and routes its `entry` output. |
| Objective | Waits for matching ordered host events and counts toward `objective_target`. |
| Condition | Evaluates all fact predicates and routes `true` or `false`. |
| All Gate | Routes `all` when every incoming edge has arrived. |
| Any Gate | Routes `any` after an incoming edge arrives. |
| External Action | Emits a typed request and waits for host resolution. |
| Conversation | Emits a conversation request and waits for an accepted outcome. |
| Subgraph | Validated and compiled recursively; runtime activation is `NOT_SUPPORTED` in this slice. |
| Reward Request | Emits a typed reward request and waits for host resolution. |
| Success/Failure/Cancelled Terminal | Completes the instance with the authored outcome. |

The compiler has a closed built-in port vocabulary and can insert static ports
that were omitted. The catalog's cross-reference pass, however, resolves edge
ports against the authored node data. Author canonical ports explicitly when
building Resources so both paths agree. The full port table is in
[API reference](api-reference.md#built-in-task-ports).

Graph edge order is semantic: it determines deterministic fan-out order.
Changing edge order can change the graph fingerprint even if the same nodes are
connected.

### Conversations

A conversation has a global ID, local entry label, declared speaker IDs,
declared terminal outcomes, and a bounded set of local steps.

| Step kind | What native runtime does |
| --- | --- |
| Line | Yields speaker ID, localization key, and substitution parameters. |
| Choice | Filters choices using facts, preserves authored order, then yields visible IDs/label keys. |
| Condition | Evaluates predicates and immediately follows the true/false target. |
| External Action | Yields a stable provider request and waits for acknowledgement, rejection, or timeout. |
| Jump | Immediately follows its target, subject to the jump budget. |
| Outcome | Yields a terminal frame with a local outcome ID. |

The core is render-neutral. It does not resolve localization keys, render a
balloon, select fonts, load portraits, play audio, or route player input.
`portrait_key` and line/choice keys are identifiers the host interprets.

### Levels, anchors, and exits

A level definition collects localized metadata, a descriptive scene-resource
string, availability predicates, entry task graph IDs, anchors, and exits.

An anchor is a local semantic ID with a kind (`Point`, `Transform`, or `Area`),
a required flag, and a plain binding label. It never retains a scene node.
An exit points to a global target-level ID, local target-anchor ID, and local
outcome. The host validates actual scene bindings, loads/streams the target,
and moves the actor after it accepts a level-transition request.

## Validation is staged

The same file can pass one stage and fail a later one. Do not treat Godot
serialization as validation.

### 1. Resource setters

Setters store the value and emit `Resource.changed`. They generally do not
enforce identifier grammar, required references, uniqueness, topology, or
cross-resource compatibility. This is why an invalid `.tres` can save.

### 2. Core definition conversion

A C++ adapter calls the appropriate `to_core_*()` method. Conversion builds a
temporary engine-independent value, validates it, and commits it to the output
only on success. This is fail-atomic: a bad nested Resource does not leave a
partially updated destination.

Definition validation checks schema version, identifier/text grammar, required
kind-specific fields, duplicate local IDs, and hard collection/payload limits.

### 3. Catalog validation and sealing

`lts::LevelTaskCatalog::add_*()` copies and locally canonicalizes each
definition. `validate(report)` then checks project-wide relationships, including:

- duplicate global IDs within each definition family;
- provider references and their expected kinds;
- graph node/edge/port references, entry uniqueness, reachability, terminal
  outcomes, dead ends, and cycles;
- referenced conversations, entry labels, accepted outcomes, and subgraphs;
- conversation steps, choices, speakers, providers, targets, and outcomes;
- level entry graphs, target levels, and target anchors; and
- cycles across subgraph references.

Reports retain at most 64 path-addressable findings but include the total count
and a `truncated` flag. Optional source paths passed to `add_*()` improve error
location but do not affect canonical bytes.

`seal()` repeats validation/canonicalization on a private candidate. On success
the catalog becomes immutable, lookups become available, and its nonzero
fingerprint is fixed. On failure the original catalog remains unsealed and is
not partially rewritten. Registration after sealing fails closed.

### 4. Graph compilation

`lts::TaskGraphCompiler` resolves built-in and dynamic ports, canonicalizes
aliases, enforces connection counts and value types, validates the complete DAG
and optional subgraphs, and publishes an immutable `lts::CanonicalTaskGraph`
only after every pass succeeds. It records canonical node/edge indices,
topological order, terminal indices, a fingerprint, and bounded work units.

The default compiler hooks allow unresolved catalog references so one graph can
be edited in isolation. An integration that needs strict provider,
conversation, or subgraph resolution must supply hooks or validate through a
complete catalog first.

### 5. Runtime input validation

Runtimes validate facts, events, scope IDs, monotonic ticks/sequences, request
IDs, expected revisions, and bounded work before publishing a mutation. Most
mutations use a candidate copy, so rejected input leaves the live instance
unchanged.

## Canonicalization and fingerprints

Canonicalization creates stable bytes for semantically equivalent authoring
data:

- identifier-indexed collections such as catalog definitions, graph nodes,
  conversation steps, speakers, outcomes, and many nested declarations are
  sorted by stable ID;
- graph edges retain authored order because fan-out order affects execution;
- conversation choices retain authored order because presentation order is
  visible to players; and
- source file paths and editor layout are excluded.

Fingerprints use `fnv1a64-canonical-v1`. Zero is the invalid/unavailable
fingerprint. A sealed catalog envelope includes schema/protocol/canonical
versions, API version, fixed-point scale, hard limits, provider declarations,
and the fingerprints of every definition.

Use the catalog fingerprint to detect mismatched content in saves, replays, or
network handshakes. It is an identity/checking mechanism, not a cryptographic
signature or security boundary.

## Task runtime data flow (native C++)

`lts::TaskGraphInstance` starts from a compiled graph plus global instance ID
and scope ID. Creation activates the entry path. Each `advance()` receives:

- a bounded ordered vector of `TaskEvent` values;
- a copied `TaskFactSnapshot`; and
- optionally, a monotonic host tick.

An event sequence of zero is assigned the next deterministic sequence. Explicit
nonzero sequences must strictly increase. A fact snapshot is sorted by
provider/fact key; duplicate keys and a mismatched nonempty scope are rejected.

One successful mutation may produce:

- state-change records for node state/counter changes;
- edge-transition records;
- trace records;
- typed external requests; and
- a new graph status/revision.

Action, reward, and conversation nodes move to `PENDING`; emitting a request is
not completion. The host executes the integration and calls
`acknowledge_request`, `reject_request`, or `timeout_request`. Resolved request
IDs are remembered, so repeating the same resolution is reported as idempotent
without advancing the revision. Optional expected revisions reject stale
owners. Optional timeout ticks expire pending requests deterministically.

Request and result records contain closed values and stable IDs only. They do
not hold provider objects or callbacks. A separate method emits level-transition
requests, because exits belong to level definitions rather than task nodes.

The native task runtime can encode a bounded, little-endian V1 snapshot. The
envelope includes compatibility and compiled-graph identity, runtime limits,
revision and tick/event cursors, node/edge progress, facts, pending and resolved
requests, and retained records. Restore checks the graph fingerprint and
validates a complete temporary instance before replacing live state, preserving
request/event idempotency across a valid restore.

Current task-runtime caveats:

- activation of a subgraph node returns `NOT_SUPPORTED`;
- task instances expose a bounded V1 snapshot codec in native C++ source, but
  it is not registered with Godot and the pre-release native ABI must be
  verified against the exact source revision you build; and
- none of this surface is callable from GDScript without a custom bridge.

## Conversation runtime data flow (native C++)

`lts::ConversationInstance` owns a canonical conversation copy and mutable
progress. `start()` requires global instance and scope IDs, an optional entry
label, an optional opaque task-integration handle, and a copied fact snapshot.
It immediately evaluates condition/jump steps until it reaches a yielded frame.

Every frame carries a revision:

- line continuation must submit the current line revision;
- choice selection must name a choice exposed on the current revision;
- updating facts rebuilds a choice frame and changes its revision, invalidating
  a previously rendered choice; and
- action resolution matches the stable request (and optionally its revision).

This prevents delayed UI/network input from choosing against stale state.
External action resolutions are idempotent by request ID. Rejection and timeout
follow the authored failure target in V1.

The runtime can encode a bounded, little-endian V1 snapshot and restore it
fail-atomically. Restore checks the configured definition fingerprint and
reconstructs/validates the current frame before replacing the destination
instance. The host still owns the save envelope, storage, encryption,
compression, version routing, and association with a player/session.

## Persistence and migration

There are three different persistence concepts:

| Data | Owner | Current mechanism |
| --- | --- | --- |
| Authored definitions | Godot/project | `.tres` or `.res` Resources; GDScript can load/save. |
| Canonical content identity | Native core | Definition/catalog canonical bytes and fingerprints. |
| Mutable play state | Host plus native runtime | Task and conversation snapshot bytes exist in native C++; neither codec is available to GDScript. |

Do not confuse `schema_version` migration with identifier rename migration. V1
accepts exactly schema version 1; it has no automatic schema-upgrade table.

`lts::LevelTaskMigrationPlanner` handles stable-identifier renames in C++:

1. Start with a sealed source catalog.
2. Describe typed global or owner-scoped local rename mappings.
3. Provide decoded stable-ID fields from game saves as
   `SavedInstanceReference` records if saves are affected.
4. Call `preview()` to obtain deterministic affected catalog paths and save
   entries. The planner builds and seals a candidate while previewing.
5. Review the plan, then call `apply()` against the same catalog fingerprint.
6. Persist the returned fresh sealed catalog and rewritten save references in a
   host-owned transaction.

The source catalog is never mutated. The planner does not parse `.tres` files or
a game's save format and does not write files. Mapping/source/affected entries
are bounded.

## Editor workflow and internal document code

For adopters, the current editor workflow is Godot's built-in Resource
Inspector. Kind-aware Resource classes hide irrelevant payload fields, which
makes nested data less noisy.

The package also contains editor component scripts, a showcase scene, and an
internal document model. They demonstrate normalized document state,
projections, commands, inverse commands, selection/layout separation, and a
degraded read-only state. The plugin does not instantiate them, and there is no
`EditorUndoRedoManager` or resource-saving adapter wired into a product editor.
Treat those files as implementation scaffolding rather than public workflow.

One current Inspector edge case: the external-action conversation step requires
`provider_identifier` and may use `parameters`, but the kind-aware property
filter hides both fields for that kind. They can still be set from GDScript or
serialized data. Always run native catalog validation before accepting authored
output.

## Diagnostics

Native operations return a small `lts::Status` with a status code, diagnostic
ID, and integer detail. Compiler diagnostics add an authored path. Catalog
reports add `path` and optional `related_path`, sort findings deterministically,
and report truncation.

A host should present all three parts instead of only converting success to a
boolean. Useful failure categories include malformed identifiers, wrong schema,
duplicate definitions, unknown references, provider-kind mismatch, invalid
ports/topology, cycles/unreachable nodes, exceeded work/payload bounds, stale
revision, and unsupported runtime behavior.

GDScript does not currently receive these diagnostics. If your project authors
content without a C++ bridge, add its own preflight checks and treat them as
helpful lint only—not a replacement for native catalog/compiler validation.

## Integration responsibilities

### Host game

- discover/load definition Resources and bridge them to core values;
- construct and seal catalogs;
- construct one runtime instance per authority scope;
- supply fact snapshots and ordered events;
- resolve provider IDs and enforce kind, payload, determinism, and authority
  declarations;
- render localized conversation frames and submit revisioned input;
- execute rewards/actions/conversations/level transitions and return explicit
  outcomes;
- load scenes and bind anchor labels;
- store/replicate state and enforce authentication/relevance; and
- compare schema/protocol/catalog identity before restore or replication.

### Level Task System

- validate the closed declarative model and hard limits;
- canonicalize and fingerprint content;
- validate/compile deterministic graph topology;
- advance native task/conversation state within bounded work;
- emit typed, side-effect-free requests and records;
- reject stale/invalid inputs fail-atomically; and
- produce native conversation snapshots and identifier-rename plans.

### Explicitly not performed

The addon does not load levels, grant items, invoke abilities, translate text,
render UI, play audio, choose a network recipient, authenticate a client,
discover arbitrary services, or run authored scripts/expressions.

## Practical adoption checklist

- Confirm the matching native artifact loads on every development/export
  target; the current manifest supports none.
- Keep all global and local IDs stable and version-controlled.
- Author explicit canonical task ports.
- Store localization keys, never display text, in definitions.
- Declare every provider and make provider lookup fail closed.
- Validate a complete catalog and compile every graph in CI.
- Record API/schema/protocol/canonical versions plus catalog fingerprint with
  persistent or replicated state.
- Treat frame/request revisions as mandatory at asynchronous boundaries.
- Keep runtime instances scoped; do not add a global mutable autoload.
- Exercise bounds, request retries, timeouts, stale input, and missing facts in
  integration tests.
- Read [Troubleshooting](troubleshooting.md) before diagnosing the plugin as a
  runtime or editor workspace—it is neither in this snapshot.
