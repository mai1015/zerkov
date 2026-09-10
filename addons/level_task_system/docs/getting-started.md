# Getting started

This guide gets the currently registered Godot surface working and creates
valid-looking definition Resources. It deliberately stops at the boundary of
the shipped GDScript API: the addon does not yet expose catalog validation,
compilation, execution, or snapshots to scripts.

## 1. Install the complete package

Copy the folder containing this document to:

```text
res://addons/level_task_system/
```

Do not copy only `plugin.gd`. The Resource classes come from
`level_task_system.gdextension`, which in turn loads a platform-specific file
from `bin/`.

Requirements for this snapshot:

- Godot 4.7 or newer; the manifest records validation against 4.7.1-stable.
- A native artifact whose platform, architecture, and debug/release mode match
  the running editor or exported game.
- For the files packaged here, macOS universal debug is the only artifact that
  is physically present. It is still marked `planned`, not supported.

Open the project once so Godot imports the GDExtension. Enabling **Level Task
System** in **Project > Project Settings > Plugins** is optional for class
loading; it activates only a compatibility warning check and installs no UI or
autoload.

## 2. Verify class registration

Attach this temporary script to any node and run the scene:

```gdscript
extends Node


func _ready() -> void:
    var required := [
        &"LevelTaskSystemVersion",
        &"LevelTaskLevelDefinition",
        &"LevelTaskGraphDefinition",
        &"LevelTaskConversationDefinition",
        &"LevelTaskProviderDeclaration",
    ]

    for class_name_to_check in required:
        assert(
            ClassDB.class_exists(class_name_to_check),
            "Missing native class: %s" % class_name_to_check
        )

    print("API: ", LevelTaskSystemVersion.get_api_version())
    print("Resource schema: ", LevelTaskSystemVersion.get_resource_schema_version())
```

If a class is missing, go to [Troubleshooting](troubleshooting.md#the-native-classes-are-missing).

## 3. Know the identifier rules

Every durable definition has a stable identifier. The core accepts ASCII
lowercase letters, digits after the first character, underscores, and dots
between segments.

| Kind | Valid | Invalid |
| --- | --- | --- |
| Global definition/provider/fact ID | `game.task.first`, `game.provider.events` | `first`, `Game.Task`, `game-task` |
| Local node/step/port/outcome/anchor ID | `entry`, `reward_2`, `branch.left` | `Entry`, `_start`, `branch-left` |

A global ID needs at least two segments. A local ID may have one. Both are
limited to 128 UTF-8 bytes, eight segments, and 32 bytes per segment. Setters
do not normalize input: whitespace and uppercase text remain invalid.

Localization keys (`display_name_key`, `line_key`, choice `label_key`) use the
local-identifier grammar, so a namespaced key such as
`game.dialogue.welcome.line_1` is valid.

## 4. Author with the standard Inspector

There is no custom Level Task System editor screen in this snapshot. Use
Godot's Resource creation dialog and Inspector:

1. In the FileSystem dock, choose **New Resource**.
2. Search for a top-level type such as `LevelTaskGraphDefinition`,
   `LevelTaskConversationDefinition`, `LevelTaskSpeakerDefinition`,
   `LevelTaskProviderDeclaration`, or `LevelTaskLevelDefinition`.
3. Save each reusable top-level definition as its own `.tres` or `.res` file.
4. Expand typed arrays and create their nested Resource type in place. For
   example, a graph's `nodes` array contains `LevelTaskNodeDefinition`; each
   node's `ports` array contains `LevelTaskPortDefinition`.
5. Set `schema_version` to `1` (the default) and leave it unchanged unless a
   future package version documents a migration.

The Inspector hides fields that do not apply to the selected value, node, or
conversation-step kind. Hidden does not mean deleted: changing a kind may
leave old values serialized, but core conversion ignores or rejects fields
that conflict with the new kind.

### Recommended authoring order

Definitions refer to one another by ID, not by Resource object:

1. Create provider declarations for facts, events, conditions, actions, and
   rewards supplied by the game.
2. Create speakers and conversations.
3. Create task graphs that reference those provider/conversation IDs.
4. Create levels that reference entry graph IDs and describe scene anchors and
   exits.
5. Have a native adapter add all definitions to one catalog, validate it, and
   seal it before play or export.

The last step cannot currently be performed from GDScript alone.

## 5. Create a minimal task graph in GDScript

This example constructs and saves the smallest useful graph. Explicit ports
are included so the same definition satisfies both catalog cross-reference
checks and compiler port resolution.

```gdscript
extends Node


func make_port(
    id: StringName,
    direction: LevelTaskPortDefinition.PortDirection,
    required: bool = true
) -> LevelTaskPortDefinition:
    var port := LevelTaskPortDefinition.new()
    port.identifier = id
    port.direction = direction
    port.value_type = LevelTaskValue.VALUE_NONE
    port.required = required
    return port


func build_first_graph() -> LevelTaskGraphDefinition:
    var entry := LevelTaskNodeDefinition.new()
    entry.identifier = &"entry"
    entry.kind = LevelTaskNodeDefinition.NODE_ENTRY
    var entry_ports: Array[LevelTaskPortDefinition] = [
        make_port(&"entry", LevelTaskPortDefinition.PORT_OUTPUT)
    ]
    entry.ports = entry_ports

    var done := LevelTaskNodeDefinition.new()
    done.identifier = &"done"
    done.kind = LevelTaskNodeDefinition.NODE_SUCCESS_TERMINAL
    done.outcome_identifier = &"success"
    var done_ports: Array[LevelTaskPortDefinition] = [
        make_port(&"input", LevelTaskPortDefinition.PORT_INPUT)
    ]
    done.ports = done_ports

    var edge := LevelTaskEdgeDefinition.new()
    edge.identifier = &"entry_to_done"
    edge.from_node_identifier = &"entry"
    edge.from_port_identifier = &"entry"
    edge.to_node_identifier = &"done"
    edge.to_port_identifier = &"input"

    var graph := LevelTaskGraphDefinition.new()
    graph.identifier = &"game.task.first"
    graph.entry_node_identifier = &"entry"
    graph.terminal_outcomes = PackedStringArray(["success"])
    var nodes: Array[LevelTaskNodeDefinition] = [entry, done]
    var edges: Array[LevelTaskEdgeDefinition] = [edge]
    graph.nodes = nodes
    graph.edges = edges
    return graph


func _ready() -> void:
    var graph := build_first_graph()
    DirAccess.make_dir_recursive_absolute("res://data/tasks")
    var error := ResourceSaver.save(graph, "res://data/tasks/first.tres")
    assert(error == OK)
```

Saving proves only that Godot can serialize the Resource. It does not prove the
graph is semantically valid, because `validate_core()` and the compiler are not
bound to GDScript.

### Add an objective

An objective is activated by an incoming edge and counts matching host events
until `objective_target` is reached. In native runtime it routes `success` when
the counter reaches the target.

Author these fields:

| Field | Example |
| --- | --- |
| `identifier` | `defeat_guards` |
| `kind` | `NODE_OBJECTIVE` |
| `provider_identifier` | `game.event.enemy_defeated` |
| `objective_target` | `3` |
| input port | `input`, Input, required |
| output port | `success`, Output |

The provider ID must name a catalog entry whose kind is `PROVIDER_EVENT`.
Optional node `filters` are fact predicates evaluated against the fact snapshot
supplied with the event.

## 6. Create a minimal conversation in GDScript

A conversation definition contains render-neutral localization keys and
control-flow targets. It does not contain dialogue UI, translated strings,
audio, portraits, or callbacks.

```gdscript
func build_welcome_conversation() -> LevelTaskConversationDefinition:
    var line := LevelTaskConversationStepDefinition.new()
    line.identifier = &"intro"
    line.kind = LevelTaskConversationStepDefinition.STEP_LINE
    line.speaker_identifier = &"game.speaker.guide"
    line.line_key = &"game.dialogue.welcome.intro"
    line.next_step_identifier = &"done"

    var outcome := LevelTaskConversationStepDefinition.new()
    outcome.identifier = &"done"
    outcome.kind = LevelTaskConversationStepDefinition.STEP_OUTCOME
    outcome.outcome_identifier = &"done"

    var conversation := LevelTaskConversationDefinition.new()
    conversation.identifier = &"game.conversation.welcome"
    conversation.entry_label = &"intro"
    conversation.speaker_identifiers = PackedStringArray([
        "game.speaker.guide"
    ])
    conversation.terminal_outcomes = PackedStringArray(["done"])
    var steps: Array[LevelTaskConversationStepDefinition] = [line, outcome]
    conversation.steps = steps
    return conversation


func save_welcome_conversation() -> void:
    var conversation := build_welcome_conversation()
    DirAccess.make_dir_recursive_absolute("res://data/conversations")
    var error := ResourceSaver.save(
        conversation,
        "res://data/conversations/welcome.tres"
    )
    assert(error == OK)
```

Also create a `LevelTaskSpeakerDefinition` with identifier
`game.speaker.guide` and a valid `display_name_key`. Catalog sealing checks that
the referenced speaker is declared and exists.

The native conversation runtime processes condition and jump steps immediately
until it reaches a yielded frame:

- line — your UI resolves `line_key`, renders it, then calls `continue_line()`;
- choice — your UI renders only currently eligible choices, then calls
  `select_choice()` with the frame revision;
- external action — the host executes the provider request and acknowledges,
  rejects, or times it out;
- outcome — the conversation is terminal and exposes its local outcome ID.

Those calls are C++ only in this snapshot.

## 7. Describe a level

A `LevelTaskLevelDefinition` ties authored systems together without loading
anything itself:

| Property | Meaning |
| --- | --- |
| `identifier` | Global durable level ID, such as `game.level.harbor`. |
| `display_name_key` / `description_key` | Localization keys; description is optional. |
| `scene_resource` | Descriptive file string such as `res://levels/harbor.tscn`. |
| `availability_rules` | Fact predicates checked by a host/native integration. |
| `entry_graph_identifiers` | One or more global task graph IDs started for this level. |
| `anchors` | Local IDs and binding labels the loaded scene must resolve. |
| `exits` | Local exit ID, target level ID, target anchor ID, and outcome. |

The core never calls `load()`, changes scene trees, or searches for nodes. A
scene adapter must map each `binding_label` to a point, transform, or area and
must fulfill level-transition requests.

## 8. Before you rely on authored content

For a native integration, use this readiness sequence:

1. Convert every Godot Resource to its engine-independent value.
2. Add providers, speakers, conversations, graphs, and levels to one
   `lts::LevelTaskCatalog`.
3. Call `validate(report)` to display deterministic paths to authors.
4. Call `seal()` and record `fingerprint()` with saves/replay/network metadata.
5. Compile each task graph to `lts::CanonicalTaskGraph`.
6. Create runtime instances per authority scope; never use a process-global
   singleton as mutable authority.
7. Persist conversation snapshots and any game-owned task state envelope using
   the exact schema/fingerprint identity expected by your adapter.

See [How it works](how-it-works.md) for the full data flow and
[API reference](api-reference.md) for the actual registered/native surfaces.
