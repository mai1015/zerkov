# Native boundaries

- `core/`: deterministic geometry, identities, worlds, memory, scheduling.
- `protocol/`: bounded canonical snapshots, deltas, and codecs.
- `godot/`: ClassDB facade and checked engine lifetime adapters.
- `resources/`: editor-facing immutable authoring resources.
- `tests/`: engine-free unit and conformance tests.

`core/` and `protocol/` must not include Godot or sibling-addon headers.
