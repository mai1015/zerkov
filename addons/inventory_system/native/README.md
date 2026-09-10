# Native boundaries

- `core/` uses C++17 standard-library value types only.
- `protocol/` may depend on `core/` and remains engine independent.
- `godot/` may adapt core/protocol values through godot-cpp.
- `resources/` contains Godot authoring inputs and copies them into native
  definitions before catalog sealing.
- `tests/` builds as an ordinary executable without Godot headers or runtime.

Core and protocol may not include Godot or sibling-addon internals. The
standalone boundary check enforces this rule.
