# Troubleshooting

## The native classes are missing

Symptoms:

- `ClassDB.class_exists(&"LevelTaskGraphDefinition")` is false;
- the Create Resource dialog does not list Level Task System types;
- Godot reports that it cannot open a dynamic library; or
- enabling the plugin prints a missing-class warning.

Check these in order:

1. The folder is exactly `res://addons/level_task_system/`.
2. `level_task_system.gdextension` is present next to `plugin.gd`.
3. Godot is 4.7 or newer.
4. `bin/` contains the file named by the `.gdextension` entry for the current
   platform, architecture, and editor build mode.
5. The library was built against a compatible Godot/godot-cpp configuration.
6. Restart Godot after replacing the library; the extension declares
   `reloadable = false`.

This package physically includes only an unpromoted macOS universal debug
library. The release manifest marks every target `planned`, with null checksum
and no verification evidence. A macOS release export, Windows, Linux, Android,
iOS, or Web project needs the corresponding artifact before it can load.

The plugin checkbox does not load missing native code. The `.gdextension` file
controls native loading; `plugin.gd` only warns when four expected classes are
absent.

## Enabling the plugin appears to do nothing

That is the current behavior. The plugin adds no dock, main screen, custom
Inspector, menu, autoload, runtime node, catalog, or simulator. It only checks
for `LevelTaskSystemVersion`, `LevelTaskLevelDefinition`,
`LevelTaskGraphDefinition`, and `LevelTaskConversationDefinition` and calls
`push_warning()` when one is missing.

Use Godot's standard Resource Inspector for authoring. The scripts and showcase
below `editor/` are unmounted component/document-model fixtures, not a shipped
authoring workspace.

## A Resource saves even though its data is invalid

This is expected in the current Godot layer. Setters assign values and emit
`Resource.changed`; they do not run complete native validation. Godot's
`ResourceSaver` checks serialization, not Level Task System semantics.

A C++ integration must:

1. convert every Resource to an engine-independent definition;
2. add all definitions to an `lts::LevelTaskCatalog`;
3. inspect `validate(CatalogValidationReport&)` findings;
4. seal the catalog; and
5. compile task graphs before constructing instances.

If your project has no C++ bridge yet, GDScript lint can catch obvious missing
fields, but it cannot certify the canonical native contract.

## `validate_core()` or `get_core_fingerprint()` does not exist in GDScript

Those methods are declared for C++ callers but are not bound with
`ClassDB::bind_method()`. The same applies to `to_core_*()` methods and all
catalog, compiler, runtime, migration, diagnostic, request, trace, and snapshot
types.

Use `has_method()` when probing dynamically:

```gdscript
var graph := LevelTaskGraphDefinition.new()
assert(not graph.has_method(&"validate_core")) # Expected in 0.1.0.
```

Do not use `LevelTaskSystemVersion.has_feature()` as proof that a GDScript class
or method exists. Its feature mask describes native contract metadata.

## A field disappeared from the Inspector

`LevelTaskValue`, `LevelTaskNodeDefinition`, and
`LevelTaskConversationStepDefinition` filter properties by their selected
kind. Select the intended `type`/`kind` first, then edit the fields that appear.

Values from the previous kind may still be stored. Native conversion can ignore
or reject conflicting data, so clear obsolete fields from script if a Resource
is repurposed.

Current external-action edge case: a conversation external-action step requires
`provider_identifier` and can carry `parameters`, but the filtered Inspector may
hide those properties. Set them from GDScript or serialized data, then validate
through the native catalog.

## An identifier is rejected

Global IDs require at least two lowercase dot-separated segments:

```text
game.task.harbor_intro       valid global
task                         invalid global (not namespaced)
Game.task                    invalid (uppercase)
game-task.intro              invalid (hyphen)
game..task                   invalid (empty segment)
```

Local IDs may have one segment, such as `entry` or `success`. A segment must
start with `a`–`z` and continue with lowercase letters, digits, or underscores.
Limits are 128 bytes total, eight segments, and 32 bytes per segment.

The core never trims or lowercases an ID. Treat identity changes as migrations.

## A graph fails on a missing or invalid port

Check all four edge fields and explicitly author the canonical node ports. The
usual control-flow names are:

- Entry output: `entry` (`next` is a compiler alias).
- Standard input: `input` (`in` is a compiler alias).
- Objective success: `success`.
- Condition: `true`, `false`.
- All/Any gate: `all`, `any` (`success` is a compiler alias).
- Action/Reward: `accepted`, `rejected`, `success`, `failure`, `timeout`,
  `cancelled`.
- Conversation: one output for each `accepted_outcomes` value.

The compiler can insert its static built-in ports and canonicalize aliases, but
catalog cross-reference validation looks up an edge's ports in the authored
node. Explicit canonical ports avoid a definition that compiles alone but fails
the complete catalog.

Also verify direction and value type match, required ports are connected, a
normal input has no more than one incoming edge, and no node exceeds 16 ports.

## A graph is rejected although every edge points to an existing node

Structural validation is stronger than reference existence. A valid compiled
graph must have exactly one entry, be acyclic, keep required connection counts,
make required nodes/terminals reachable, let live paths reach a terminal, and
provide a terminal node for each declared outcome. Subgraph reference cycles
and excessive nesting are rejected too.

Compiler/catalog diagnostics include an authored path. Preserve that path in
logs or CI rather than reporting only `GRAPH_INVALID`.

## A provider reference is rejected

The referenced declaration must exist and have the expected kind:

| Use | Expected provider kind |
| --- | --- |
| Fact predicate | Fact |
| Objective node | Event |
| Condition node/step | Condition |
| External-action node/step | Action |
| Reward-request node | Reward |

A provider declaration does not install a callback or discover a Godot
singleton. The host must map the stable ID to an implementation and explicitly
return a result.

## A fact condition unexpectedly evaluates false

Native runtimes treat a missing `(provider_identifier, fact_identifier)` pair
or an incompatible value type as not matching. Verify:

- both IDs are the exact global IDs used by the predicate;
- the fact snapshot belongs to the same scope;
- the actual and expected closed value types match;
- fixed values are authored in raw millionths; and
- string and identifier values were not confused.

Fact snapshots reject duplicate keys. Task event filters and node filters are
both evaluated when an objective receives an event.

## A task request never advances the node

Emitting a request intentionally changes the node to Pending; it does not imply
success. The host must call the matching native C++ resolution method using the
request ID:

- `acknowledge_request()` routes the supplied/default successful outcome;
- `reject_request()` routes `rejected`; or
- `timeout_request()` routes `timeout`.

For a conversation task node, an acknowledged outcome must be one of the
node's `accepted_outcomes`. If there is exactly one it may be inferred; otherwise
the host must provide it (or an Identifier response).

Resolved request IDs are idempotent. A stale expected revision, decreasing
tick, unknown request, wrong outcome, or malformed response is rejected without
partially mutating the instance.

## A subgraph compiles but fails at runtime

The catalog/compiler can resolve, validate, and compile subgraph definitions,
including depth/cycle checks. The current `lts::TaskGraphInstance` deliberately
returns `NOT_SUPPORTED` when a Subgraph node activates. Flatten the graph or
keep subgraph nodes out of executable paths until runtime support is added.

## Conversation input is rejected as stale

Use the revision from the frame actually presented to the player:

- submit a line frame's revision to `continue_line()`;
- submit a choice frame's revision and an exposed choice ID to
  `select_choice()`; and
- resolve the current action request ID (and revision when using that overload).

Changing the fact snapshot while a choice is visible rebuilds the choices and
increments the frame revision. The old UI response should be rejected. Facts
cannot be changed while waiting for an external action, and a terminal
conversation cannot be advanced.

## A conversation restore fails

Native conversation snapshots are definition-bound. Restore validates the
snapshot envelope, size, schema, configured definition fingerprint, IDs,
pending/resolved request data, and reconstructed current frame before replacing
the instance.

Use the same canonical conversation definition that created the snapshot. The
codec is C++ only and is not a complete game-save system: your game must store
the bytes with version/catalog/player metadata and route future migrations.

Task snapshot methods are unavailable to Godot even though the native C++
`TaskGraphInstance` implements a bounded V1 codec. Native callers must restore
against the same compiled-graph fingerprint and should verify the exact
pre-release source revision they build.

## A rename misses save data

The migration planner never parses your save format. Decode every stable-ID
field into a typed `SavedInstanceReference`, including owner/nested-owner
context for local IDs, before preview. Apply only the reviewed plan against the
same sealed catalog fingerprint and commit catalog/save changes together.

This migration API renames identifiers. It is not a general schema-version
migrator, and it does not rewrite `.tres` files by itself.

## A level scene or anchor does not load/bind

`scene_resource` is String metadata with a file hint, not a `PackedScene`.
Anchors contain semantic IDs and binding labels, not Nodes or transforms. The
native core never calls `load()`, changes the scene tree, or searches for a
binding.

Your scene adapter must load/stream the described resource, resolve required
anchor labels in the loaded scene, and fulfill level-transition requests.

## Export works in the editor but fails in release

Debug and release use different library entries. The included macOS debug file
does not satisfy a release export, and no other platform file is packaged.
Build/package the exact artifact named by `level_task_system.gdextension`, then
validate extension load and export for that tuple.

Do not change `release_manifest.json` to `supported` merely because a file
exists. Its policy requires the exact artifact, checksum, load/export evidence,
and role-applicable conformance.

## What the bundled smoke tests prove

The Godot smoke verifies class/version availability and basic graph property
round-tripping. The component-showcase test verifies development controls can
instantiate. Neither test validates a catalog, runs a task/conversation, proves
export support, or turns the showcase into product UI.

For source checkouts, the helper can be invoked with an explicit Godot binary:

```sh
GODOT_BIN=/path/to/godot tools/godot.sh smoke
```

Native source tests are built/run from the checkout root with:

```sh
scons level_task_system_tests run_level_task_system_tests=yes
```

These commands and the root build files are development conveniences; they are
not included in a project that copies only `addons/level_task_system/`.
