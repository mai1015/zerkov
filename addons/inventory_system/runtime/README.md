# Runtime presentation

Typed-GDScript presentation model (`inventory_presentation_model.gd` —
`InventoryPresentationModel`) and generic interaction controller
(`inventory_interaction_controller.gd` — `InventoryInteractionController`).
Presentation consumes immutable snapshots and command results fed by a host,
holds selection/hover/focus-memory/pending-intent/drag state separately from
canonical state, and never mutates canonical inventory state directly —
every mutating interaction goes through an `InventoryAuthority`-shaped
command sink instead.

See [`../docs/presentation.md`](../docs/presentation.md) for the full public
surface (every method, signal, and the 24-state catalog) and
`tests/inventory_system/presentation/inv_presentation_main.gd` /
`tests/inventory_system/presentation/inv_interaction_main.gd` for their test
coverage.
