# Level Task System documentation

These guides are packaged with the addon and describe the implementation in
this 0.1.0 snapshot.

Start here:

1. [Getting started](getting-started.md) — install, verify the extension, use
   the standard Inspector, and create graph/conversation Resources.
2. [How it works](how-it-works.md) — understand definitions, validation,
   canonicalization, runtimes, persistence, and host ownership.
3. [API reference](api-reference.md) — look up registered Godot properties,
   native C++ entry points, ports, enums, and hard limits.
4. [Troubleshooting](troubleshooting.md) — diagnose missing classes, invalid
   content, unavailable methods, and export artifacts.

The package-level [README](../README.md) gives the shortest adoption overview.

## Current boundary in one sentence

Godot exposes a version façade plus 15 mutable authoring Resource classes;
validation, cataloging, compilation, diagnostics, migrations, task/conversation
execution, and conversation snapshots are C++ source-only, while the plugin
itself installs no editor workspace or autoload.

No short C++ alias names such as `TaskGraphDefinition` are registered as Godot
classes; use the full `LevelTask*` names in GDScript.
