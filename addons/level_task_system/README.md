# Level Task System

Level Task System is a pre-release Godot 4.7 addon for describing levels,
directed task graphs, conversations, and the provider contracts that connect
them to a game. Its native core keeps authored data deterministic and bounded;
the host game remains responsible for scenes, UI, localization, rewards,
networking, and authoritative ownership.

> **Current 0.1.0 boundary:** Godot currently exposes the compatibility façade
> and 15 authoring `Resource` classes. You can create, inspect, load, and save
> those Resources from GDScript. Catalog validation, graph compilation,
> migrations, task execution, conversation execution, diagnostics, and
> runtime snapshot methods exist only as engine-independent C++ source APIs; they are not
> registered with `ClassDB`. The editor plugin adds no workspace or autoload.

## What you can use now

| Capability | Godot/GDScript | Native C++ source | Notes |
| --- | --- | --- | --- |
| Author level, graph, conversation, speaker, provider, and nested value Resources | Yes | Yes | Godot setters do not perform whole-resource validation. |
| Query API/schema/fingerprint-algorithm versions | Yes | Yes | Use `LevelTaskSystemVersion`. |
| Validate and seal a cross-resource catalog | No | Yes | `lts::LevelTaskCatalog`; source API, not a stable binary ABI. |
| Validate and compile a task DAG | No | Yes | `lts::TaskGraphCompiler`. |
| Advance and snapshot task instances; service typed external requests | No | Yes | `lts::TaskGraphInstance`; subgraph execution is not supported in this slice. |
| Advance render-neutral conversations and snapshot them | No | Yes | `lts::ConversationInstance`. |
| Preview/apply identifier renames | No | Yes | `lts::LevelTaskMigrationPlanner`; the host still reads/writes save files. |
| Dedicated visual authoring workspace | No | No | Packaged controls/showcase are development fixtures and are not mounted by the plugin. |

The feature flags returned by `LevelTaskSystemVersion` describe the native
package contract. They do **not** mean a corresponding GDScript runtime class
is registered. Test the exact class or method you intend to call.

## Install

1. Copy this entire directory to `res://addons/level_task_system/`. Keep
   `level_task_system.gdextension`, `plugin.gd`, `native/`, and `bin/` together.
2. Confirm that `bin/` contains a library matching the platform and build type
   Godot will run. This snapshot physically includes only the macOS universal
   debug library.
3. Open the project with Godot 4.7 or newer and let it import the extension.
4. Optionally enable **Level Task System** under **Project > Project Settings >
   Plugins**. Enabling it runs a missing-class check only; the GDExtension is
   loaded from its `.gdextension` file independently of that checkbox.
5. Verify the registered surface:

```gdscript
func _ready() -> void:
    assert(ClassDB.class_exists(&"LevelTaskGraphDefinition"))
    assert(ClassDB.class_exists(&"LevelTaskConversationDefinition"))
    print("Level Task System API ", LevelTaskSystemVersion.get_api_version())
```

The package is still marked `pre_release`. Every entry in
[`release_manifest.json`](release_manifest.json) is `planned`, with no checksum
or verification evidence, so the bundled macOS debug file is not a production
support claim. Other platforms and release exports need their matching native
artifacts.

## Five-minute authoring path

The simplest usable authored graph is:

```text
entry --entry--> done
                    └─ success outcome
```

Create a `LevelTaskGraphDefinition`, give it a global identifier such as
`game.task.first`, add an entry node and a success-terminal node, then connect
their explicit `entry` output and `input` input. See
[`docs/getting-started.md`](docs/getting-started.md) for the exact Inspector
workflow and a complete GDScript example.

Stable identifiers are part of saved and networked identity:

- Global identifiers contain at least two lowercase dot-separated segments,
  for example `game.level.harbor` or `game.provider.quest_events`.
- Local identifiers use the same lowercase grammar but may contain one segment,
  for example `entry`, `accepted`, or `spawn`.
- Identifiers are rejected rather than trimmed or lowercased. Plan renames as
  migrations instead of silently changing strings.

## How the pieces fit

```text
Godot Resources (.tres/.res)
          |
          | host adapter copies values (C++ only today)
          v
  validated definitions --> sealed catalog --> catalog fingerprint
                                      |
                                      v
                           compiled canonical task DAG
                                      |
                     +----------------+----------------+
                     v                                 v
             task graph instance             conversation instance
                     |                                 |
            typed host requests               render-neutral frames
                     +----------------+----------------+
                                      v
                     game-owned providers, UI, saves,
                     localization, scenes, and authority
```

After a native adapter converts them, core definitions retain no Godot `Node`,
`Object`, `Callable`, script, arbitrary `Variant` container, or live scene
reference. Runtime-facing values use a closed set: none, boolean, integer,
fixed-point raw integer, string, stable identifier, or bytes. Godot authoring
Resources do, naturally, contain nested Resource objects before conversion.

## Documentation

- [`docs/getting-started.md`](docs/getting-started.md) — installation, Inspector
  workflow, and complete authoring examples.
- [`docs/how-it-works.md`](docs/how-it-works.md) — data flow, validation,
  canonicalization, runtime behavior, persistence, and ownership boundaries.
- [`docs/api-reference.md`](docs/api-reference.md) — registered Godot classes,
  properties, enums, native C++ entry points, built-in ports, and limits.
- [`docs/troubleshooting.md`](docs/troubleshooting.md) — missing classes,
  invalid definitions, export failures, hidden fields, and runtime boundaries.
- [`release_manifest.json`](release_manifest.json) — exact pre-release target
  and artifact claims.
- [`THIRD_PARTY_LICENSES.md`](THIRD_PARTY_LICENSES.md) — dependency notices.

## Ownership at a glance

| Level Task System owns | Your game owns |
| --- | --- |
| Stable identifiers and schemas | Loading/streaming scenes |
| Declarative definitions and canonical fingerprints | Binding anchor labels to scene nodes/transforms/areas |
| Graph topology and deterministic native progression | Producing facts/events and executing providers |
| Render-neutral conversation control flow | Localized text, dialogue UI, portraits, audio, and input |
| Typed external requests and acknowledgements | Rewards, inventory transactions, transport, authentication, and recipients |
| Task/conversation snapshot bytes and rename plans in native C++ | Save envelopes, storage, replication, and migration commits |

There is deliberately no process-global runtime or autoload. A host may create
separate owners for a player, party, local session, or server-authoritative
scope.

## Important limitations

- GDScript can save structurally invalid Resources because validation is not
  ClassDB-bound. A C++ adapter must convert and validate before shipping or
  executing authored content.
- The standard Inspector is the current editor workflow. No graph canvas,
  catalog browser, simulator, or diagnostics panel is installed.
- `LevelDefinition.scene_resource` is descriptive text. The core does not load
  the scene or bind its anchors.
- Providers are declarations, not callbacks. The game executes the requested
  action/reward/conversation/transition and acknowledges it explicitly.
- Task and conversation runtimes have bounded V1 snapshot codecs in native
  C++ source, but neither snapshot API is registered with Godot. Treat the
  pre-release native ABI as revision-specific and run its tests before relying
  on it for persistence.
- Task subgraphs can be validated/compiled, but `TaskGraphInstance` returns
  `NOT_SUPPORTED` when a subgraph node activates.
- No target is supported by the current release manifest.

Start with [Getting started](docs/getting-started.md), then read
[How it works](docs/how-it-works.md) before building a runtime adapter.
