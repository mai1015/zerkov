# Inventory controls

Themeable spatial-grid (`inventory_spatial_grid_control.gd`), named-slot
(`inventory_named_slots_control.gd`), and ordered-list
(`inventory_ordered_list_control.gd`) container renderers, the registry that
maps a container's layout kind to its renderer
(`inventory_renderer_registry.gd`), the two-pane player/world composition
(`inventory_two_pane_view.gd`), the design-token scale and theme factory
(`inventory_design_tokens.gd`, `inventory_theme_factory.gd`,
`inventory_state_glyphs.gd`), and the shared item/tooltip/focus/drag/
pending/rejection primitives under `primitives/`.

Built against the required `docs/inventory/DESIGN.md` gate — see
[`../docs/presentation.md`](../docs/presentation.md) for the full reference
(what each class does, its public surface, and the state catalog every
primitive here renders) and
`tests/inventory_system/harness/inv_harness_main.gd`/
`tests/inventory_system/presentation/inv_presentation_main.gd` for their test
coverage.
