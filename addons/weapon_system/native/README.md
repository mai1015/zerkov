# Native boundaries

- `core/`: deterministic values, definitions, catalogs, instances,
  transitions, fixed-point spread, snapshots, and pure 2D hitscan math.
- `protocol/`: canonical transport-neutral DTO codecs and admission values.
- `godot/`: ClassDB façades, runtime/coordinator Nodes, ports, and signals.
- `resources/`: Godot authoring Resources copied into sealed core values.
- `tests/`: engine-free native tests and include-boundary checks.

`core/` and `protocol/` must not include Godot or sibling-addon headers.
