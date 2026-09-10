# Presentation: Model, Controls, and the Optional Adapters

The GDScript presentation layer (tasks.md §8) built on top of the native
façade: the snapshot-driven presentation model, the renderer registry and
container controls, the interaction controller, the shared primitives, the
full state matrix, and how the two optional adapters (CommonUI,
Gameplay Abilities) plug into it. `docs/inventory/DESIGN.md` is the required
visual-direction/design-token gate this whole layer was built against — read
it first for tokens, density modes, typography, materials, icon rules,
spacing, motion, and the state catalog referenced throughout this document.

**Everything below is presentation, not authority**: this layer holds
selection, hover, pending intent, drag ghosts, rejection feedback, and view
state (`runtime/inventory_presentation_model.gd`), and turns intent into
authority commands (`runtime/inventory_interaction_controller.gd`) — it never
mutates canonical inventory state directly. Only `InventoryAuthority`
(`api.md`) ever changes canonical state; this layer only ever *reacts* to
`apply_snapshot()`/`apply_result()`.

## `InventoryPresentationModel` (`runtime/inventory_presentation_model.gd`)

Fed snapshots and command results by a host (a game's own authority-to-model
bridge — this class does not fetch or refresh its own canonical layer):

- `apply_snapshot(snapshot: InventorySnapshotResource)` — replaces this
  model's canonical view of one inventory; emits `model_changed`.
- `begin_intent(kind, args) -> pending_id` / `cancel_intent(pending_id)` —
  the pending-intent layer a drag/action shows before a command round-trips.
- `apply_result(result: Dictionary)` — the same result Dictionary shape
  `InventoryAuthority`'s command methods return (`api.md`); resolves the
  matching pending intent to accepted (`STATE_ACCEPTED`, an `accepted-flash`)
  or rejected (`STATE_REJECTED`, feeding `rejection_feedback`), or corrects a
  stale local guess (`STATE_STALE_CORRECTED`) if the model had assumed a
  location the accepted result contradicts.
- Selection/hover/focus-memory/open-container path:
  `select()`/`clear_selection()`/`get_selection()`, `set_hover()`/
  `clear_hover()`, `remember_focus()`/`recall_focus()` (per-container, for
  keyboard/gamepad focus restoration — task 8.6), `open_container()`/
  `close_container()`/`get_open_container_path()`/`current_container()` (the
  nested-container navigation stack).
- Per-container/per-item visibility and access flags:
  `set_container_read_only()`, `set_item_read_only()`,
  `set_container_inaccessible()`, `set_container_overweight()`,
  `set_disconnected()`, `set_resynchronizing()` — each backs one of the
  states below.
- `item_state(inventory_id, item_id)` / `container_state(inventory_id,
  container_id)` — the single source of truth a control reads to pick its
  StyleBox/glyph; computes the full precedence staircase (redacted >
  disconnected > resynchronizing > read-only > inaccessible > overweight >
  rejected > stale-corrected > accepted > pending > dragging > selected >
  hover > normal) so no control re-implements state precedence itself.
- `tick(ticks)` — advances the model's own internal timers (e.g. the
  accepted-flash duration) without a `_process()` dependency, so headless
  tests can drive time deterministically.
- Signals: `model_changed`, `pending_changed`, `rejection_feedback(info)`.

### The full state catalog

Every state a primitive or container can report, `InventoryPresentationModel`
constants `STATE_*`:
`normal, hover, focus, selected, pressed, dragging, drop-valid, drop-invalid,
drop-occupied, drop-filtered, drop-overweight, drop-inaccessible, pending,
accepted-flash, rejected, stale-corrected, redacted, read-only, disabled,
empty, loading, disconnected, overflow, resynchronizing` — 24 states total
(task 8.7), exhaustively covered non-color-only (glyph or shape, never color
alone — DESIGN.md §11.2) by `controls/inventory_state_glyphs.gd`
(`InventoryStateGlyphs`) and exercised across all 10 primitives'
documented-applicable subset by
`tests/inventory_system/harness/inv_harness_main.gd` (5180 checks: the full
primitive×state matrix plus a resolution×UI-scale×density geometry/
hit-target/overflow matrix).

## `InventoryInteractionController` (`runtime/inventory_interaction_controller.gd`)

Turns pointer/keyboard/gamepad/touch intent into exactly the expected
authority command (task 8.5), against a `p_command_sink` object (duck-typed —
any object exposing the matching `InventoryAuthority`-shaped methods, real or
a test recording sink):

- Drag/drop: `begin_drag()`, `update_drag_target()`, `end_drag()`,
  `cancel_drag()`, plus a dedicated split-via-drag path
  (`begin_split_drag()`, `confirm_split()`/`cancel_split()`) and rotate while
  dragging (`_rotate_drag()`, wired to an input action). Hosts pair
  `set_footprint_lookup()` with `set_rotation_lookup()` so the local ghost
  only turns for item definitions authority permits to rotate; missing
  rotation entries remain optimistic for backward compatibility. Alt/Option
  held when the primary press is armed uses `begin_half_split_drag()`:
  `floor(quantity / 2)` is fixed at press time, shown on the ghost, validated
  as the staged quantity, and submitted directly to an empty destination
  without opening the arbitrary-quantity dialog.
- Direct actions on the current selection: `rotate_selected()`,
  `quick_transfer_selected()`, `auto_place_selected()`, `inspect_selected()`,
  `perform_action(action_id)` + `available_actions(inventory_id, item_id)`
  (context-menu contents). Inspect emits the resolved snapshot item/state;
  `InventoryTwoPaneView` presents that data by default in a focus-trapped
  `InventoryModal` hosting `InventoryItemDetails` (display name, description,
  quantity, mass, oriented footprint, location, state, and definition id).
  A discrete rotate first probes the flipped
  placement through the command sink's side-effect-free `fits()` query; if
  it cannot fit, the action is a silent no-op rather than an authoritative
  rejection/feedback animation. `Split…` retains arbitrary quantity;
  `Merge…` enters an explicit compatible-target mode with deterministic
  traversal/highlighting; `Drop` appears only when the host installed a
  game-owned resolver capable of approving a nonzero external-owner id.
- Exact context targeting: every item card/list row emits inventory id, item
  id, and pointer anchor on secondary click. The controller replaces stale
  selection with that exact target while idle. Active drag, armed drag,
  move mode, merge mode, split modal, or Drop-policy wait consumes the
  request as Cancel instead. Keyboard/gamepad `inventory_context_menu` and
  touch hold use the same ordered action model and item-anchor fallback.
- Container-providing cards: an occupied target whose item owns materialized
  containers is previewed with
  `preview_transfer_item_to_provider()` before ordinary merge/swap logic.
  Valid release submits `transfer_item_to_provider()`; a full, filtered,
  overweight, inaccessible, cyclic, stale, or otherwise rejected insertion
  never falls back to swapping the container item. Dropping on an already
  rendered subcontainer continues to use the explicit-location path.
- Move mode (keyboard/gamepad equivalent of drag): `activate()`,
  `move_focus(direction)`, `move_focus_next_container()`/
  `move_focus_previous_container()`, `cancel()` — deterministic neighbor
  traversal within a container and a documented cross-container jump rule
  when the edge is reached (task 8.6).
- Touch-hold (touch-safe long-press instead of drag-start):
  `begin_touch_hold()`, `trigger_touch_hold()`, `cancel_touch_hold()`.
- Signals: `drag_started`/`drag_target_updated`/`drag_ended`,
  `move_mode_started`/`move_mode_updated`/`move_mode_ended`,
  `merge_mode_started`/`merge_mode_updated`/`merge_mode_ended`,
  `split_quantity_requested`, `command_submitted(kind, args, result)`,
  `context_actions_requested`, `drop_policy_requested`/
  `drop_policy_closed`, `inspect_requested`.

Every mutating path is proven to submit *exactly* the expected authority
command with the expected arguments by
`tests/inventory_system/presentation/inv_interaction_main.gd` (1601 checks) —
including the cancel path for each (drag/move-mode/split/touch-hold) never
submitting a command at all.

## Renderer registry and container controls (`controls/`)

- `InventoryRendererRegistry` (`controls/inventory_renderer_registry.gd`) —
  maps a container's `layout_kind_token` (`LAYOUT_SPATIAL_GRID`,
  `LAYOUT_NAMED_SLOTS`, `LAYOUT_ORDERED_LIST`) to the control that renders
  it; `register_builtin_defaults()` wires the three built-ins below.
- `InventorySpatialGridControl`, `InventoryNamedSlotsControl`,
  `InventoryOrderedListControl` — one per ownership layout
  (`api.md`/`authoring.md`'s three layout kinds), each `configure(model,
  inventory_id, container_id, ..., tokens)`-driven from the presentation
  model above, never from a raw snapshot directly.
- `InventoryTwoPaneView` (`controls/inventory_two_pane_view.gd`) — the
  player/world or player/stash two-pane composition (task 8.4), built purely
  from the renderer registry and a resolver callback — no hard-coded profile
  names, container counts, equipment slots, dimensions, or pixel geometry.
  Its optional `context_actions_presenter` lets a host replace the built-in
  anchored popup without changing exact-target/controller semantics;
  `inspect_presenter` provides the equivalent seam for the persistent item
  details modal.
- `InventoryDesignTokens` / `InventoryThemeFactory`
  (`controls/inventory_design_tokens.gd`, `controls/inventory_theme_factory.gd`)
  — the DESIGN.md token scale (unit, density, UI-scale) and the Theme this
  whole layer's StyleBoxes are built from.
- `InventoryStateGlyphs` — the non-color-only state indicator lookup (see
  above).

## Shared primitives (`controls/primitives/`)

`InventoryItemCard`, `InventoryGridCell` (a themed `Panel` type variation,
not a dedicated script), `InventorySlot` (likewise), `InventoryListRow`
(likewise), `InventoryContainerPanel` (likewise), `InventoryTooltip`,
`InventoryContextMenu` (a themed `PopupMenu`), `InventoryActionBarEntry` (a
themed `Button`), `InventoryDragGhost`, `InventoryModal` (a themed
`PopupPanel`) — the 10 primitives DESIGN.md §12.1–§12.10 each define a
per-state applicability table for, and
`tests/inventory_system/harness/inv_harness_main.gd` exhaustively checks
against (143 applicable + 97 documented "n/a" cells across all 10 × 24
states).

`InventoryItemDetails` is the reusable read-only content hosted by
`InventoryModal` (and by the optional CommonUI inspect dialog); it is not an
additional §12 state-matrix surface of its own.

## Optional CommonUI adapter (`addons/inventory_common_ui/`)

A separately enableable addon depending only on this addon's and CommonUI's
own public façades (never the reverse). Adds an activatable inventory screen,
rotate/split/quick-transfer/inspect/context-menu/accept/cancel/navigation
actions scoped to eligible screens/modals, split-quantity and context-action
dialogs plus a persistent item-details dialog as serialized CommonUI modal
transactions, explicit Merge target mode, and a game-owned Drop-policy wait.
Exact pointer context requests are
routed through `InventoryTwoPaneView.context_actions_presenter`, so they use
the same serialized dialog as keyboard/gamepad context action rather than
opening a second unmanaged popup. `set_drop_policy_resolver()` installs the
optional game seam; screen teardown cancels transient merge/drop state.
The action bar remains driven from current selection + allowed-command
metadata. When the separately distributed adapter is installed, see its
package README for the API and `tests/inventory_common_ui/inv_cui_main.gd`
(261 checks)
for its 469-check coverage, including the adapter-absence isolation proof (task
9.6: enabling, disabling, or omitting this adapter changes nothing about this
addon's or CommonUI's own behavior).

## Optional Gameplay Abilities adapter (`addons/inventory_gameplay_abilities/`)

A separately enableable addon depending only on this addon's and Gameplay
Abilities' own public façades. Maps equipped-item traits to ability
grants/effects/gameplay tags, derives stable adapter-owned GAS source tokens,
applies/revokes them only around accepted inventory revisions, and
reconciles idempotently from a full snapshot. When the separately distributed
adapter is installed, see its package README and
`tests/inventory_gameplay_abilities/inv_gas_main.gd` (103 checks),
including the adapter-absence isolation proof (task 10.8).

Both adapters are exercised together against the SAME reference extraction
flow (equip/loot/split/drop) by
`tests/inventory_system/vertical/inv_vertical_main.gd`'s `_test_11_6_adapter_matrix`
(CommonUI, enabled vs. absent) and `_test_11_7_gas_matrix` (Gameplay
Abilities, enabled vs. absent) sections.

## Staged discovery presentation

Discovery projections and revisions live beside, not inside, ordinary
network-loading state. `InventoryPresentationModel` installs full views or
exact-predecessor replacement deltas, captures pending Search/Scan/Cancel
tuples, marks stale tokens as resynchronizing, and restores focus only to a
recipient-visible target. `InventoryDiscoveryContainerControl` renders
unsearched/searching/indexed/scanning states; opaque entries expose no
ordinary item signals, while revealed items use `InventoryItemCard`.
`InventoryTwoPaneView` composes staged and instant-open containers in the
same pane. Input, reduced-motion, translation, touch-size, and CommonUI modal
rules are detailed in [`discovery.md`](discovery.md) and
[`docs/inventory/DESIGN.md`](../../../docs/inventory/DESIGN.md) §12.11.
