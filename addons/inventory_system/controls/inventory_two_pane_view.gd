class_name InventoryTwoPaneView
extends Control

const InventoryItemDetailsScript = preload(
		"res://addons/inventory_system/controls/primitives/inventory_item_details.gd")

## Two-pane composition (tasks.md 8.4): a leading ("left") and trailing
## ("right") pane, each hosting a scrollable stack of container renderers
## resolved via [InventoryRendererRegistry] from whatever inventory/containers
## the host assigns through [method set_left]/[method set_right] -- NO
## hard-coded profile name, container count, equipment-slot list, dimension,
## or pixel geometry lives in this script. Any profile (a simple
## ordered-list-only profile, a full extraction-character profile, a world
## crate, ...) renders the same way: every container a snapshot reports as a
## ROOT container (docs/api.md: `provider_item == 0`) gets its own renderer,
## resolved purely from `container_definition_identifier` -> layout/dimension
## metadata the HOST supplies via [member container_info_resolver] --
## catalog-side data this scene-free addon has no other way to reach (the
## same "host supplies catalog data" pattern [InventorySpatialGridControl]
## already established for tasks.md 8.3).
##
## DESIGN.md §8: panes lay out side-by-side (leading/trailing) above
## `stacked_max_width_units`, stacked below it; a `space_2` safe-area margin
## insets the whole composition; each pane's content scrolls internally (a
## [ScrollContainer]) while the two-pane composition itself never scrolls;
## every geometry value here is `tokens.unit(N)`, snapped via [method _snap]
## so a resize never introduces a non-unit pixel remainder.
##
## Nested containers (a visible item's own provided sub-container) render as
## their own FLOATING WINDOW -- a draggable, closable panel layered above
## BOTH panes (never a Godot [Window]/popup: same Control/[CanvasItem]-based
## rationale as [InventoryContextMenu]/[InventoryModal], see those files' own
## header comments) -- for every container currently named in [method
## InventoryPresentationModel.get_open_container_path]; see [member
## _window_root]. This wave supports exactly the containers the open path
## names directly (it does not recursively walk an arbitrarily deep nested
## tree); see [method _render_open_container_windows]'s doc comment. A
## HOSTING layer that presents opened containers itself (e.g. a CommonUI
## adapter's own windowed screens, [InventoryCommonUiContainerWindow]) can
## suppress this view's own window rendering entirely via [member
## render_open_container_windows] -- see that member's doc comment for why
## (avoiding a double presentation of the same container).
##
## DESIGN.md §10.1 ultrawide/wide layout: above [member PANE_MAX_CONTENT_WIDTH_UNITS]
## (derived from §10.2's own baseline reference resolution -- see that
## constant's doc comment), the two panes stop growing and stay adjacent at
## that max width; extra width becomes a CENTERED outer gutter instead of
## pinning the panes to opposite viewport edges (the "dead gulf" docs/
## inventory/visual-qa-2026-07-27.md finding 9 flagged). Once the gutter
## itself exceeds [member _ULTRAWIDE_AUX_MIN_WIDTH_UNITS], a third auxiliary
## column (§10.1's "e.g. persistent action bar") appears at a fixed width
## ([member _ULTRAWIDE_AUX_COLUMN_WIDTH_UNITS], never stretchy) -- [method
## aux_container] is the empty hook a host populates; this addon itself never
## puts anything in it. Both extra breakpoint constants are local to this
## script (expressed as `tokens.unit(N)` like every other geometry value
## here), NOT registered on [InventoryDesignTokens] -- §10.1 only NAMES the
## `ultrawide_aux_min_width_units` token, it does not yet require every
## consumer to share one canonical value, and this wave's brief is scoped to
## NOT touch that resource for this feature.
##
## DESIGN.md §11.3 keyboard/gamepad parity: move-mode's current candidate
## target is fed through the EXACT SAME [method _apply_drop_preview] path a
## pointer drag's per-frame [method _update_drag_visuals] uses -- see [method
## _apply_move_mode_preview] -- so directional navigation shows the identical
## rotation-aware cell-occupancy highlight a pointer drag would.
##
## DESIGN.md §9 "Placement snap": an ACCEPTED drop that settles into a
## [InventorySpatialGridControl] cell tweens the settled card's position from
## the drop-release point (captured here, in the TARGET control's own local
## space, before [method InventoryInteractionController.end_drag] runs -- see
## [method _prepare_placement_animation]) via [method
## InventorySpatialGridControl.animate_placement]. Scoped to pointer drops
## only (the design row's own "drop-release point" wording is inherently
## pointer-shaped); keyboard/gamepad move-mode confirmation does not replay
## this tween.
##
## Optional staged discovery is rendered from the model's separate recipient
## projection, never inferred from missing canonical containers. Hidden
## shells and opaque entries use [InventoryDiscoveryContainerControl];
## indexed/revealed items inside that control still use [InventoryItemCard].
## When no recipient discovery snapshot is installed this path contributes no
## nodes or actions, preserving the base presentation/adapter-absence case.

signal intent_requested(kind: StringName, args: Dictionary)
## Tasks.md 8.5's double-click-to-open affordance, fired AFTER this view has
## already resolved+opened the container and applied its own focus/highlight
## (see [method _on_container_opened]) -- the hook a HOSTING layer (e.g. a
## CommonUI adapter) uses to additionally open ITS OWN windowed view of that
## container, in place of (not alongside) this addon's own floating-window
## rendering (see [member render_open_container_windows], which such a
## layer sets `false` -- typically right where it connects this signal -- so
## the two windowed presentations of the same container never stack).
## [param container_id] is the materialized provided container's real id
## (see [method InventoryInteractionController.resolve_open_container]);
## never fired for the inspect-fallback case (no container actually opened).
signal container_open_requested(inventory_id: int, item_id: int, container_id: int)

const SIDE_LEFT: StringName = &"left"
const SIDE_RIGHT: StringName = &"right"

## DESIGN.md §10.1's "normal max content width" for a SINGLE pane, derived
## from §10.2's own baseline reference resolution (1920x1080 @ ui_scale 1.0,
## "the resolution all §3 pixel values are authored at"): that resolution's
## own usable width after the space_2 safe-area margin (§8), halved for one
## pane, expressed in RAW unit terms so [method InventoryDesignTokens.unit]
## scales it consistently with ui_scale like every other geometry value here.
## 1920px / 8px(base_unit_px) = 240u total; minus two `space_2` (2u) margins =
## 236u usable; halved = 118u. Below/at this baseline (every declared
## resolution up to ~2560x1440, §10.1) the cap has no visible effect --
## `usable.x * 0.5` never exceeds it there -- so ultrawide is the only regime
## this actually changes.
const PANE_MAX_CONTENT_WIDTH_UNITS := 118.0

## Local approximation of DESIGN.md §10.1's NAMED (but not yet registered on
## [InventoryDesignTokens] -- see this file's header comment)
## `ultrawide_aux_min_width_units` breakpoint: the GUTTER width (both panes
## already at their max, §10.1) that must remain before an optional aux
## column is even considered.
const _ULTRAWIDE_AUX_MIN_WIDTH_UNITS := 40.0
## The aux column's own FIXED width once it appears -- never stretches to
## fill whatever gutter happens to be left (that would just re-create the
## "dead gulf" problem one column over); comfortably fits within the min
## width above alongside its own `space_2` gaps on either side.
const _ULTRAWIDE_AUX_COLUMN_WIDTH_UNITS := 32.0

var model: InventoryPresentationModel
var registry: InventoryRendererRegistry
var tokens: InventoryDesignTokens
## `Callable(container_definition_identifier: String) -> Dictionary`,
## returning [code]{layout_kind_token: StringName, grid_width: int,
## grid_height: int, footprint_lookup: Dictionary, slot_defs: Array,
## max_entries: int}[/code] (fields the resolved layout doesn't use are
## simply ignored). This is the ONLY place catalog-side layout/dimension data
## enters this view -- see this file's header comment.
var container_info_resolver: Callable
## Read-only derived queries only (`total_mass`/`container_mass_capacity`/...)
## -- for the pane-header mass/capacity readout. Never called for mutation.
var command_sink: Object
## Wired automatically on assignment: every rendered container control's
## `intent_requested`/`location_hover_entered`/`location_hover_exited`/
## `location_pointer_up` signal is forwarded to this controller, each pane's
## resolved container list is reported via [method InventoryInteractionController.set_containers],
## and this view renders the controller's drag/move-mode/split-quantity/
## inspect/context-menu signals through [member drag_ghost]/[member
## _split_modal] (hosting the reused [member _quantity_spinner])/[member
## _inspect_modal]/[member _context_menu].
var interaction_controller: InventoryInteractionController:
	set(value):
		if interaction_controller != null:
			_disconnect_controller_signals(interaction_controller)
		interaction_controller = value
		if interaction_controller != null:
			interaction_controller.tokens = tokens
			_connect_controller_signals(interaction_controller)

var drag_ghost: InventoryDragGhost

## When [code]true[/code] (the default), this view renders every currently
## OPEN item-provided container (see [method
## InventoryPresentationModel.get_open_container_path]) as its own floating
## window on [member _window_root] -- this addon's own out-of-the-box
## presentation (this file's header comment). A HOSTING layer that presents
## opened containers itself sets this [code]false[/code] -- the concrete
## example is [InventoryCommonUiScreen], which sets it right where it wires
## [signal container_open_requested] to its own [method
## InventoryCommonUiScreen.open_container_window], so a double-click never
## produces TWO presentations of the same container. When [code]false[/code],
## this view renders NOTHING for an open-path container -- no window panel,
## no [member _container_controls]/[member _container_panels] registration,
## and, verified against [InventoryCommonUiContainerWindow.configure], no
## [method _descriptor_entry_for] append either: that class performs its OWN
## [method InventoryInteractionController.set_containers] registration for
## the exact same container id, under its own `container_window_<id>` side
## name, so appending it here too would just have the two calls stomp each
## other's `side` metadata on alternating rebuilds (that lookup is keyed
## purely by container id, not by side -- whichever call runs last for a
## given id wins). It still reports the container's OWN provider item's
## ROOT container normally; only the open sub-container itself is skipped.
var render_open_container_windows := true

## The floating-window layer (this file's header comment; a plain [Control],
## never a Godot [Window]/popup -- same rationale as
## [InventoryContextMenu]/[InventoryModal], see those files' own header
## comments): every currently open item-provided container (see [member
## render_open_container_windows]) renders here as its own draggable,
## closable panel, layered ABOVE both panes' own content but BELOW [member
## drag_ghost] (created right after this one in [method _init], so an active
## item drag's ghost always paints over every open window) and below the
## lazily-created [member _split_modal]/[member _context_menu] (which simply
## land later in this view's own child order the first time either is
## built). MOUSE_FILTER_IGNORE so this layer itself never blocks pane input
## outside an actual window's own rect -- its CHILDREN (each window panel)
## still receive/consume input normally.
var _window_root: Control

## cid -> Vector2, the last position a floating open-container window (see
## [member _window_root]) was placed at (dragged or defaulted), in this
## view's own local space -- restored verbatim (re-clamped to the view's
## CURRENT rect) on every rebuild instead of re-cascading from scratch,
## since [method _rebuild_pane] tears down and rebuilds every panel
## (windowed or not) on EVERY [signal InventoryPresentationModel.model_changed],
## including one triggered by something totally unrelated (a hover, a
## different item's selection, ...). Pruned for any cid no longer named in
## [method InventoryPresentationModel.get_open_container_path] -- see
## [method _prune_stale_window_positions].
var _window_positions: Dictionary = {}

## {} or {"container_id": int, "grab_offset": Vector2} -- an in-progress
## title-bar drag of one open-container window (this file's header comment's
## "Window chrome", [method _add_window_chrome]). Followed by POLLING in
## [method _process], never by the title bar's own [method Control.gui_input]
## motion events -- the SAME lost-mouse-focus reason [constant
## _DRAG_MOVE_THRESHOLD_UNITS]'s doc comment documents for item-card drags
## applies here too: hover changes elsewhere call [method
## InventoryPresentationModel.set_hover] -> [signal
## InventoryPresentationModel.model_changed] -> [method _rebuild_pane], which
## can free this very title-bar Control mid-drag (it is rebuilt from scratch
## every pass, windowed panels included), stranding an event-driven drag
## exactly like a purely event-driven item drag would. A window-drag and an
## item-drag can never both be active -- a title-bar press never calls
## [method InventoryInteractionController.arm_pointer_drag] (see [method
## _on_window_title_bar_gui_input]) -- so [method _process]'s two polling
## branches never have to arbitrate between them.
var _window_drag: Dictionary = {}

## Small per-already-open-window stagger applied to a freshly-opened
## window's own default position (see [method _default_window_position]) so
## opening several containers in the same rebuild pass doesn't stack every
## window exactly on top of the last -- `tokens.unit(N)`, never a bare pixel
## literal (this file's established convention).
const _WINDOW_CASCADE_STEP_UNITS := 2.0
## Wraps the cascade back to the start after this many windows, so a long
## chain of opens doesn't eventually cascade a window off past the view's
## own edge (which [method _clamp_window_position] would then just clamp
## back flush against, defeating the stagger's own purpose).
const _WINDOW_CASCADE_WRAP := 6

## DESIGN.md §10.1's optional ultrawide auxiliary column -- an intentionally
## EMPTY [Control] hook (this addon puts nothing in it itself); a host
## populates it (e.g. a persistent action bar) when it wants to use the
## width [method _update_layout] frees up once the gutter is wide enough (see
## [constant _ULTRAWIDE_AUX_MIN_WIDTH_UNITS]). Hidden (zero-sized) whenever
## that width isn't available -- [method aux_container]/[method aux_rect] are
## the read accessors.
var _aux_root: Control

var _pane_roots: Dictionary = {} # StringName side -> Control
var _pane_headers: Dictionary = {} # StringName side -> Label
var _pane_scrolls: Dictionary = {} # StringName side -> ScrollContainer
var _pane_content: Dictionary = {} # StringName side -> VBoxContainer
var _pane_inventory: Dictionary = {} # StringName side -> int
var _pane_label_override: Dictionary = {} # StringName side -> String
var _container_controls: Dictionary = {} # int container_id -> Control
var _container_layout: Dictionary = {} # int container_id -> StringName
var _container_side: Dictionary = {} # int container_id -> StringName
var _container_panels: Dictionary = {} # int container_id -> Control, the wrapping Panel _build_container_panel() returns (header + rendered control) -- tracked for [method _on_container_opened]'s scroll/focus/highlight.
var _discovery_controls: Dictionary = {} # String stable recipient key -> InventoryDiscoveryContainerControl
var _discovery_side: Dictionary = {} # String stable recipient key -> StringName side
var _quantity_spinner: InventoryQuantitySpinner
## Lazily created on the first [signal InventoryInteractionController.split_quantity_requested]
## -- see [method _on_split_quantity_requested]. Reused across every
## subsequent split (matching [member _quantity_spinner]'s own reuse
## convention); torn down uniformly via [method
## InventoryInteractionController.split_quantity_closed] regardless of which
## path resolved the pending split (docs/inventory/visual-qa-2026-07-27.md
## finding 8's flow-sheet step 7 fix).
var _split_modal: InventoryModal
## Lazily created on the first [signal
## InventoryInteractionController.inspect_requested]. The same persistent,
## focusable [InventoryItemDetails] content is reused for every inspected
## item while [InventoryModal] supplies the scrim/focus trap/Esc behavior
## DESIGN.md §12.6 requires for keyboard/gamepad Inspect.
var _inspect_modal: InventoryModal
var _inspect_details
## Optional host-owned presentation seam for inspected item data. When valid,
## receives `(inventory_id, item_id, item_info)` and replaces this view's
## built-in [InventoryModal]. CommonUI uses it to serialize inspection with
## its own modal layer; plain hosts keep the accessible local modal.
var inspect_presenter: Callable = Callable()
## Optional host-owned presentation seam for exact-item context actions.
## When valid, receives `(inventory_id, item_id, actions, anchor_global_position)`
## and replaces this view's built-in [InventoryContextMenu]. CommonUI uses it
## to push its serialized context dialog while plain hosts keep the local
## anchored popup by leaving it invalid.
var context_actions_presenter: Callable = Callable()
## Lazily created on the first [signal InventoryInteractionController.context_actions_requested].
var _context_menu: InventoryContextMenu
## {} or {inventory_id: int, item_id: int} -- the item [member _context_menu]
## is currently showing actions for, so [method _on_context_menu_action_selected]
## can dispatch against the RIGHT item even if it differs from whatever the
## model's current selection happens to be (e.g. a context menu opened via
## touch-hold on an item that was never separately clicked/selected first).
var _context_menu_target: Dictionary = {}

# =============================================================================
# Pointer press-hold-drag threshold (tasks.md 8.5's press-hold-drag rework):
# a bare press ARMS a potential drag (see [method InventoryInteractionController.arm_pointer_drag]);
# movement past this threshold while held is what actually STARTS the drag --
# a plain press/release with no intervening movement stays a plain click/
# select. Expressed as `tokens.unit(N)` like every other geometry value this
# addon computes (never a bare pixel literal) -- 0.5u is 4px at the base
# unit/scale (`8.0 * 1.0`), matching the "~4px" reference point.
#
# RELEASE is discovered by POLLING, not by trusting the event-driven
# [signal InventoryTwoPaneView.location_pointer_up]/[method
# _on_location_pointer_up] path: every card press ALSO calls
# [method InventoryPresentationModel.select], which unconditionally emits
# [signal InventoryPresentationModel.model_changed] and synchronously rebuilds
# BOTH panes ([method _on_model_changed] -> [method _rebuild_pane]) -- freeing
# the very card the mouse just pressed. When the [Control] holding the
# viewport's gui mouse focus leaves the tree, Godot drops that focus with it,
# and a mouse-button RELEASE event is only ever delivered to whichever
# [Control] currently holds mouse focus -- so with a REAL mouse, the physical
# release lands on NO control at all, and [method
# InventoryInteractionController.release_pointer_arm]/[method
# InventoryInteractionController.end_drag] would never run. [method _process]
# therefore polls [method Input.is_mouse_button_pressed] every frame instead
# of waiting on that event to arrive.
const _DRAG_MOVE_THRESHOLD_UNITS := 0.5

var _preview_container_id: int = 0 # container_id currently carrying an active [method InventorySpatialGridControl.set_drop_preview]-style overlay, or 0.
var _merge_preview_controls: Array[Control] = []


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS
	for side in [SIDE_LEFT, SIDE_RIGHT]:
		_build_pane(side)
	_aux_root = Control.new()
	_aux_root.name = "AuxColumn"
	_aux_root.mouse_filter = Control.MOUSE_FILTER_PASS
	_aux_root.visible = false
	add_child(_aux_root)
	# MUST be added after every pane/[member _aux_root] but before [member
	# drag_ghost] -- see [member _window_root]'s own doc comment for why this
	# exact ordering matters (windows above pane content, below the drag
	# ghost and the lazily-added split modal/context menu).
	_window_root = Control.new()
	_window_root.name = "WindowLayer"
	_window_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_window_root)
	drag_ghost = InventoryDragGhost.new()
	add_child(drag_ghost)
	resized.connect(_update_layout)
	set_process(false)


func configure(p_model: InventoryPresentationModel, p_registry: InventoryRendererRegistry, p_tokens: InventoryDesignTokens,
		p_container_info_resolver: Callable, p_command_sink: Object = null) -> void:
	if model != null and model.model_changed.is_connected(_on_model_changed):
		model.model_changed.disconnect(_on_model_changed)
	model = p_model
	registry = p_registry
	tokens = p_tokens if p_tokens != null else InventoryDesignTokens.new()
	container_info_resolver = p_container_info_resolver
	command_sink = p_command_sink
	if interaction_controller != null:
		interaction_controller.tokens = tokens
	if model != null:
		model.model_changed.connect(_on_model_changed)
	_update_layout()
	_rebuild_pane(SIDE_LEFT)
	_rebuild_pane(SIDE_RIGHT)


## [param label]: empty defaults to the snapshot's own profile identifier (or
## `"inventory <id>"` before a snapshot exists) -- this view invents NO
## profile-specific display name itself; a host names its panes explicitly if
## it wants something friendlier.
func set_left(inventory_id: int, label: String = "") -> void:
	_pane_inventory[SIDE_LEFT] = inventory_id
	_pane_label_override[SIDE_LEFT] = label
	_rebuild_pane(SIDE_LEFT)


func set_right(inventory_id: int, label: String = "") -> void:
	_pane_inventory[SIDE_RIGHT] = inventory_id
	_pane_label_override[SIDE_RIGHT] = label
	_rebuild_pane(SIDE_RIGHT)


func clear_left() -> void:
	set_left(0)


func clear_right() -> void:
	set_right(0)


func pane_inventory_id(side: StringName) -> int:
	return int(_pane_inventory.get(side, 0))


## Canonical (ascending container id) order -- every root container currently
## rendered on [param side], INCLUDING any currently-windowed open container
## (see [member _window_root]; empty for one where [member
## render_open_container_windows] is `false`, since this view then renders
## nothing for it at all -- see that member's own doc comment).
func pane_container_ids(side: StringName) -> Array[int]:
	var ids: Array[int] = []
	for cid in _container_side:
		if _container_side[cid] == side:
			ids.append(cid)
	ids.sort()
	return ids


func container_control(container_id: int) -> Control:
	return _container_controls.get(container_id, null)


func discovery_control_for_token(token: int) -> InventoryDiscoveryContainerControl:
	return _discovery_controls.get("token:%d" % token, null)


func discovery_control_for_container(container_id: int) -> InventoryDiscoveryContainerControl:
	return _discovery_controls.get("container:%d" % container_id, null)


func pane_discovery_keys(side: StringName) -> PackedStringArray:
	var keys := PackedStringArray()
	for key in _discovery_side.keys():
		if _discovery_side[key] == side:
			keys.append(String(key))
	keys.sort()
	return keys


## Test/host inspection accessors for the persistent Inspect surface.
func inspect_modal() -> InventoryModal:
	return _inspect_modal


func inspect_details() -> Control:
	return _inspect_details


## One of `&"spatial"`, `&"named_slots"`, `&"ordered_list"`, or `&""` if
## unresolved/unsupported.
func container_layout(container_id: int) -> StringName:
	return _container_layout.get(container_id, &"")


func pane_header_label(side: StringName) -> String:
	var header: Label = _pane_headers.get(side, null)
	return header.text if header != null else ""


## Test/inspection accessor for the pane header [Label] itself (not just its
## text, [method pane_header_label]) -- proves the §10.3 truncation
## contract's actual Control state (`clip_text`/`text_overrun_behavior`/
## `tooltip_text`), not merely the resolved string.
func pane_header_control(side: StringName) -> Label:
	return _pane_headers.get(side, null)


## Test/inspection accessor for a rendered container panel's own header
## [Label] (the panel's title, [method _build_container_panel]) -- same
## rationale as [method pane_header_control].
func container_header_label(container_id: int) -> Label:
	var panel: Control = _container_panels.get(container_id, null)
	if panel == null:
		return null
	return panel.get_node_or_null("Header") as Label


## `true` when [param container_id]'s own rendered panel is CURRENTLY a
## floating window (parented under [member _window_root], [method
## _spawn_or_update_container_window]) rather than stacked inline into a
## pane's own scroll content (a root container). `false` for an id this view
## isn't rendering at all (including one [member render_open_container_windows]
## `false` deliberately skips -- [method container_control] already returns
## `null` for that case too).
func is_container_windowed(container_id: int) -> bool:
	var panel: Control = _container_panels.get(container_id, null)
	return panel != null and panel.get_parent() == _window_root


## Test/inspection accessor for a windowed container panel's own close
## button (this file's header comment's "Window chrome", [method
## _add_window_chrome]) -- `null` for a root (non-windowed) panel, which has
## no such child. Same rationale as [method container_header_label].
func window_close_button(container_id: int) -> BaseButton:
	var panel: Control = _container_panels.get(container_id, null)
	if panel == null:
		return null
	return panel.get_node_or_null("CloseButton") as BaseButton


## The persisted position [member _window_positions] holds for [param
## container_id] -- [constant Vector2.ZERO] if it isn't (or never was) a
## floating window.
func window_position(container_id: int) -> Vector2:
	return _window_positions.get(container_id, Vector2.ZERO)


## Directly sets [param container_id]'s own floating-window position
## (re-clamped to this view's current rect, exactly like a real drag or
## rebuild-time restore would -- [method _clamp_window_position]) -- a host
## convenience for restoring a previously-saved window layout without
## replaying an actual drag gesture; also the "direct helper" a test can use
## in place of simulating a real title-bar press + [method _process] drag
## (see [method _on_window_title_bar_gui_input]/[method
## _update_window_drag_position] for that path). A no-op if [param
## container_id] isn't currently rendered as a window.
func set_window_position(container_id: int, pos: Vector2) -> void:
	var panel: Control = _container_panels.get(container_id, null)
	if panel == null or panel.get_parent() != _window_root:
		return
	var clamped := _clamp_window_position(pos, panel.size)
	_window_positions[container_id] = clamped
	panel.position = clamped


## Current on-screen rect (position + size) of [param side]'s pane ROOT, in
## this view's own local space -- [method _update_layout]'s only externally
## observable geometry output (DESIGN.md §10.1 layout checks).
func pane_rect(side: StringName) -> Rect2:
	var root: Control = _pane_roots.get(side, null)
	return Rect2(root.position, root.size) if root != null else Rect2()


## Test/inspection accessor for [param side]'s own scroll [code]Content[/code]
## Control's current size ([method _rebuild_pane]'s own `content.size`) --
## the pane's ACTUAL scrollable content extent, distinct from [method
## pane_rect]'s pane-ROOT viewport rect. Windowed open containers ([member
## _window_root]) never contribute to this -- see [method _rebuild_pane]'s
## own doc comment.
func pane_content_size(side: StringName) -> Vector2:
	var content: Control = _pane_content.get(side, null)
	return content.size if content != null else Vector2.ZERO


## The optional ultrawide auxiliary column's hook -- see this file's header
## comment and [member _aux_root]. Always non-null; a host checks [method
## Control.visible]/[method aux_rect] before populating it, since it collapses
## to zero size whenever [method _update_layout] doesn't have the width for it.
func aux_container() -> Control:
	return _aux_root


func aux_rect() -> Rect2:
	return Rect2(_aux_root.position, _aux_root.size)


## Enters/expands [param container_id] (an item-provided sub-container of an
## item currently placed in one of this view's rendered root containers) as
## its own floating window -- see this file's header comment for the
## single-level scope (this wave does not walk deeper than one level under a
## root container) and [member _window_root] for the windowed presentation
## itself. A no-op (still records ancestry) if [param container_id] can't be
## resolved to a currently-visible provider item this rebuild pass; closing
## the INNERMOST open container regardless of which one uses [method
## InventoryPresentationModel.close_container] directly, while closing this
## SPECIFIC window (e.g. its own chrome's close button, [method
## _on_window_close_pressed]) uses [method
## InventoryPresentationModel.close_container_id] instead.
func expand_container(container_id: int) -> void:
	if model == null:
		return
	model.open_container(container_id)


func collapse_container() -> void:
	if model == null:
		return
	model.close_container()


func _on_model_changed() -> void:
	_rebuild_pane(SIDE_LEFT)
	_rebuild_pane(SIDE_RIGHT)
	if interaction_controller != null and interaction_controller.is_merge_mode_active():
		if not interaction_controller.refresh_merge_mode():
			return
		_refresh_merge_previews()


# =============================================================================
# Pane construction
# =============================================================================

func _build_pane(side: StringName) -> void:
	var root := Control.new()
	root.name = "Pane_%s" % side
	root.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(root)
	_pane_roots[side] = root

	var header := Label.new()
	header.name = "Header"
	header.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# MUST be set before any `.size =`/`.text =` assignment (both happen
	# later -- text in [method _update_pane_header], size in [method
	# _update_layout]) -- clip_text off would let the Label's own intrinsic
	# text-minimum-size re-inflate its assigned size back out past the pane
	# edge the moment a long label is set (§10.3's "no translatable text in a
	# fixed-pixel-width container" truncation contract).
	header.clip_text = true
	header.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	root.add_child(header)
	_pane_headers[side] = header

	var scroll := ScrollContainer.new()
	scroll.name = "Scroll"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	root.add_child(scroll)
	_pane_scrolls[side] = scroll

	# A plain Control, NOT a VBoxContainer/PanelContainer: Godot's automatic
	# Container layout nodes add their OWN default separation/content-margin
	# constants (e.g. VBoxContainer's `separation` theme constant), which are
	# fixed engine pixel defaults that do NOT scale with `tokens.ui_scale` and
	# are not `unit * N` values -- exactly the "hard-coded pixel geometry"
	# tasks.md 8.4 forbids. Every child here is stacked at an EXPLICIT
	# `tokens.unit(N)`-derived position instead (see [method _rebuild_pane]),
	# matching this addon's established convention (every container control
	# already positions its own children this same explicit way).
	var content := Control.new()
	content.name = "Content"
	content.mouse_filter = Control.MOUSE_FILTER_PASS
	scroll.add_child(content)
	_pane_content[side] = content

	_pane_inventory[side] = 0
	_pane_label_override[side] = ""


func _rebuild_pane(side: StringName) -> void:
	var content: Control = _pane_content[side]
	for child in content.get_children():
		content.remove_child(child)
		child.queue_free()
	for discovery_key in _discovery_side.keys():
		if _discovery_side[discovery_key] == side:
			_discovery_controls.erase(discovery_key)
			_discovery_side.erase(discovery_key)
	# The model's own open path doesn't change mid-rebuild, so this is
	# idempotent across BOTH sides' own [method _rebuild_pane] calls -- see
	# [method _prune_stale_window_positions]'s own doc comment.
	_prune_stale_window_positions()
	for cid in pane_container_ids(side):
		# A root panel is freed below (it's a child of [param content], which
		# every [method _rebuild_pane] pass tears down unconditionally); a
		# WINDOWED panel lives on [member _window_root] instead, so it needs
		# its own explicit teardown here before this cid's bookkeeping is
		# erased -- it is always rebuilt fresh a few lines down (see [method
		# _spawn_or_update_container_window]), exactly like a root panel
		# always was even before this feature.
		var existing_panel: Control = _container_panels.get(cid, null)
		if existing_panel != null and is_instance_valid(existing_panel) and existing_panel.get_parent() == _window_root:
			_window_root.remove_child(existing_panel)
			existing_panel.queue_free()
		_container_controls.erase(cid)
		_container_layout.erase(cid)
		_container_side.erase(cid)
		_container_panels.erase(cid)
		if _preview_container_id == cid:
			_preview_container_id = 0

	var inventory_id := int(_pane_inventory.get(side, 0))
	_update_pane_header(side, inventory_id)

	if model == null or inventory_id == 0 \
			or (not model.has_snapshot(inventory_id) and not model.has_discovery_snapshot(inventory_id)):
		content.custom_minimum_size = Vector2.ZERO
		if interaction_controller != null:
			interaction_controller.set_containers(side, inventory_id, [])
		return

	var snapshot := model.get_snapshot(inventory_id)
	var root_containers: Array = []
	var discovery_views := model.discovery_containers(inventory_id)
	var staged_container_ids: Dictionary = {}
	for discovery_variant in discovery_views:
		var discovery: InventoryDiscoveryContainerViewResource = discovery_variant
		if discovery.get_container_id() > 0:
			staged_container_ids[discovery.get_container_id()] = true
	if snapshot != null:
		for container_variant in snapshot.get_containers():
			var container: Dictionary = container_variant
			if int(container.get("provider_item", 0)) == 0 \
					and not staged_container_ids.has(int(container.get("id", 0))):
				root_containers.append(container)
	root_containers.sort_custom(func(a, b): return int((a as Dictionary).get("id", 0)) < int((b as Dictionary).get("id", 0)))

	var gap := _snap(tokens.unit(1.0)) if tokens != null else 0.0
	var running_y := 0.0
	var max_width := 0.0
	var descriptor_containers: Array = []
	for container_variant in root_containers:
		var container: Dictionary = container_variant
		var cid := int(container.get("id", 0))
		var definition_identifier := String(container.get("container_definition_identifier", ""))
		var panel := _build_container_panel(cid, definition_identifier, inventory_id, side)
		panel.position.y = running_y
		content.add_child(panel)
		running_y += panel.size.y + gap
		max_width = maxf(max_width, panel.position.x + panel.size.x)
		descriptor_containers.append(_descriptor_entry_for(cid, definition_identifier))
		# Floating windows render on [member _window_root], entirely OUTSIDE
		# [param content] -- unlike the old inline-stacking implementation
		# this replaces, this never threads into `running_y`/`max_width`, so
		# opening a container no longer grows the pane's own scroll content.
		_render_open_container_windows(snapshot, cid, inventory_id, side, descriptor_containers)

	# Recipient discovery shells are a separate projection. Rendering them
	# after ordinary roots avoids inventing a cross-domain ordering key between
	# canonical ids and opaque tokens; each domain is internally canonical.
	for discovery_variant in discovery_views:
		var discovery: InventoryDiscoveryContainerViewResource = discovery_variant
		var discovery_control := _build_discovery_control(discovery, inventory_id, side)
		discovery_control.position.y = running_y
		content.add_child(discovery_control)
		running_y += discovery_control.size.y + gap
		max_width = maxf(max_width, discovery_control.position.x + discovery_control.size.x)
		if discovery.get_container_id() > 0:
			descriptor_containers.append(_descriptor_entry_for_discovery(discovery))

	content.custom_minimum_size = Vector2(max_width, running_y)
	content.size = content.custom_minimum_size

	if interaction_controller != null:
		interaction_controller.set_containers(side, inventory_id, descriptor_containers)


## Drops any [member _window_positions] entry whose container id is no
## longer named in [method InventoryPresentationModel.get_open_container_path]
## -- called once at the top of [method _rebuild_pane]. Safe to call from
## BOTH sides' own rebuild pass in the same [signal
## InventoryPresentationModel.model_changed] cycle: the model's open path is
## shared, global state that does not change mid-rebuild, so a second call
## simply finds nothing left to prune.
func _prune_stale_window_positions() -> void:
	if model == null:
		return
	var open_path := model.get_open_container_path()
	for cid in _window_positions.keys():
		if not (int(cid) in open_path):
			_window_positions.erase(cid)


## Renders [param root_container_id]'s own eligible open item-provided
## sub-containers as floating windows on [member _window_root] -- the SAME
## eligibility rule the old inline-stacking implementation this replaces
## used: the sub-container's own `provider_item` must be an item currently
## placed directly in [param root_container_id], and the sub-container's id
## must be named in [method InventoryPresentationModel.get_open_container_path]
## (regardless of the path's depth/order; this wave does not walk deeper
## than one level under a root container -- a sub-container's OWN nested
## sub-containers are not expanded further even if also named in the path).
## A no-op entirely -- no window, no [method _descriptor_entry_for] append --
## when [member render_open_container_windows] is `false`; see that member's
## own doc comment for why skipping the descriptor append too (not just the
## window) is the correct behavior for a hosting adapter that registers the
## same container itself.
func _render_open_container_windows(snapshot: InventorySnapshotResource, root_container_id: int,
		inventory_id: int, side: StringName, descriptor_containers: Array) -> void:
	if model == null or not render_open_container_windows:
		return
	var open_path := model.get_open_container_path()
	if open_path.is_empty():
		return
	for container_variant in snapshot.get_containers():
		var container: Dictionary = container_variant
		var provider_item_id := int(container.get("provider_item", 0))
		if provider_item_id == 0:
			continue
		var cid := int(container.get("id", 0))
		if not (cid in open_path):
			continue
		# A staged nested container has its own recipient-only control in
		# this pane. Building the canonical placeholder window as well would
		# duplicate it and route around opaque-entry restrictions.
		if model.discovery_container_by_id(inventory_id, cid) != null:
			continue
		var provider_item := _find_item_in_snapshot(snapshot, provider_item_id)
		if provider_item.is_empty():
			continue
		var provider_location: Dictionary = provider_item.get("location", {})
		if int(provider_location.get("container", -1)) != root_container_id:
			continue
		var definition_identifier := String(container.get("container_definition_identifier", ""))
		descriptor_containers.append(_descriptor_entry_for(cid, definition_identifier))
		_spawn_or_update_container_window(cid, definition_identifier, inventory_id, side)


## Builds [param cid]'s own floating window panel fresh (every [method
## _rebuild_pane] pass tears down and rebuilds every panel unconditionally,
## windowed ones included -- see that method's own doc comment) and adds it
## to [member _window_root], restoring its persisted [member
## _window_positions] entry (re-clamped to this view's CURRENT rect, in case
## it resized since the position was last stored) or computing a fresh
## [method _default_window_position] the first time this cid is ever seen
## open.
func _spawn_or_update_container_window(cid: int, definition_identifier: String, inventory_id: int, side: StringName) -> void:
	var panel := _build_container_panel(cid, definition_identifier, inventory_id, side, true)
	_window_root.add_child(panel)
	var pos: Vector2
	if _window_positions.has(cid):
		pos = _clamp_window_position(_window_positions[cid], panel.size)
	else:
		pos = _clamp_window_position(_default_window_position(panel.size), panel.size)
	_window_positions[cid] = pos
	panel.position = pos


## Centered-ish, with a small per-already-open-window cascade (see [constant
## _WINDOW_CASCADE_STEP_UNITS]) -- [member _window_positions]'s own size at
## call time IS the count of currently-open windows already placed earlier
## in this same rebuild pass (stale entries are already pruned by [method
## _prune_stale_window_positions] before any root container's own [method
## _render_open_container_windows] call runs), so each newly-opened window
## in one batch cascades one step further than the last.
func _default_window_position(panel_size: Vector2) -> Vector2:
	var base := (size - panel_size) * 0.5
	if tokens == null:
		return base
	var cascade_index := _window_positions.size() % _WINDOW_CASCADE_WRAP
	var offset := tokens.unit(_WINDOW_CASCADE_STEP_UNITS) * float(cascade_index)
	return base + Vector2(offset, offset)


## Clamps [param pos] so a window panel of [param panel_size] stays fully
## inside this view's own current rect -- shared by [method
## _spawn_or_update_container_window] (rebuild-time restore), [method
## _update_window_drag_position] (live drag), and [method _update_layout]
## (view resize).
func _clamp_window_position(pos: Vector2, panel_size: Vector2) -> Vector2:
	var max_x := maxf(size.x - panel_size.x, 0.0)
	var max_y := maxf(size.y - panel_size.y, 0.0)
	return Vector2(clampf(pos.x, 0.0, max_x), clampf(pos.y, 0.0, max_y))


func _find_item_in_snapshot(snapshot: InventorySnapshotResource, item_id: int) -> Dictionary:
	for item_variant in snapshot.get_items():
		var item: Dictionary = item_variant
		if int(item.get("id", 0)) == item_id:
			return item
	return {}


## A plain [Panel] (NOT [PanelContainer]) with header Label + the rendered
## container control positioned at EXPLICIT `tokens.unit(N)` offsets -- see
## [member _pane_content]'s doc comment for why this view never delegates
## geometry to Godot's automatic Container layout nodes. [param windowed]
## adds this file's header comment's "Window chrome" (a close button + a
## dedicated title-bar drag region, see [method _add_window_chrome]) to the
## header strip; a plain root-container panel ([param windowed] `false`)
## stays exactly as before. Neither case sets this panel's own `.position`
## here -- the caller positions it ([method _rebuild_pane]'s own running-Y
## stack for a root panel, [member _window_positions] via [method
## _spawn_or_update_container_window] for a windowed one).
func _build_container_panel(container_id: int, definition_identifier: String, inventory_id: int, side: StringName, windowed: bool = false) -> Control:
	var control := _instantiate_container(container_id, definition_identifier, inventory_id, side)
	_container_controls[container_id] = control
	_container_layout[container_id] = _layout_token_name(definition_identifier)
	_container_side[container_id] = side

	var header_height := _snap(tokens.unit(2.0))
	var content_size: Vector2 = control.custom_minimum_size
	if content_size.x <= 0.0 or content_size.y <= 0.0:
		content_size = Vector2(maxf(content_size.x, tokens.unit(12.0)), maxf(content_size.y, tokens.unit(3.0)))
	content_size = Vector2(_snap(content_size.x), _snap(content_size.y))

	var panel := Panel.new()
	panel.name = "Container_%d" % container_id
	panel.theme_type_variation = InventoryThemeFactory.TYPE_CONTAINER_PANEL
	panel.size = Vector2(content_size.x, header_height + content_size.y)
	panel.custom_minimum_size = panel.size
	panel.mouse_filter = Control.MOUSE_FILTER_PASS
	# FOCUS_ALL so [method _on_container_opened] (tasks.md 8.5's double-click/
	# context-menu/keyboard "open" affordance) can `grab_focus()` this panel --
	# a plain Panel otherwise defaults to FOCUS_NONE.
	panel.focus_mode = Control.FOCUS_ALL

	var header := Label.new()
	header.name = "Header"
	# MUST precede `.text =`/`.size =` below -- see [method _build_pane]'s
	# identical ordering comment; a container's `definition_identifier` is
	# routinely longer than a narrow container panel's own width.
	header.clip_text = true
	header.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	header.text = definition_identifier
	header.tooltip_text = definition_identifier # §10.3: full string always reachable via tooltip.
	header.position = Vector2.ZERO
	header.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(header)

	if windowed:
		# Sets [param header]'s own `.size` itself (narrower than the panel's
		# full width, leaving room for the close button) -- see that method's
		# own doc comment.
		_add_window_chrome(panel, header, container_id, content_size.x, header_height)
	else:
		header.size = Vector2(content_size.x, header_height)

	control.position = Vector2(0.0, header_height)
	panel.add_child(control)

	_container_panels[container_id] = panel
	return panel


func _build_discovery_control(
		view: InventoryDiscoveryContainerViewResource,
		inventory_id: int,
		side: StringName) -> InventoryDiscoveryContainerControl:
	var control := InventoryDiscoveryContainerControl.new()
	control.name = "Discovery_%s" % (
			"token_%d" % view.get_token()
			if view.get_token() != 0
			else "container_%d" % view.get_container_id())
	control.theme = theme
	control.configure(model, inventory_id, view, tokens)
	_wire_container_signals(control)

	var key := _discovery_key(view)
	_discovery_controls[key] = control
	_discovery_side[key] = side
	if view.get_container_id() > 0:
		var container_id := view.get_container_id()
		_container_controls[container_id] = control
		_container_layout[container_id] = _discovery_layout_token_name(view)
		_container_side[container_id] = side
		_container_panels[container_id] = control
	return control


func _discovery_key(view: InventoryDiscoveryContainerViewResource) -> String:
	return "token:%d" % view.get_token() \
			if view.get_token() != 0 else "container:%d" % view.get_container_id()


func _discovery_layout_token_name(view: InventoryDiscoveryContainerViewResource) -> StringName:
	match view.get_layout_kind():
		InventoryDiscoveryContainerViewResource.LAYOUT_SPATIAL_GRID:
			return &"spatial"
		InventoryDiscoveryContainerViewResource.LAYOUT_NAMED_SLOTS:
			return &"named_slots"
		InventoryDiscoveryContainerViewResource.LAYOUT_ORDERED_LIST:
			return &"ordered_list"
	return &""


func _descriptor_entry_for_discovery(view: InventoryDiscoveryContainerViewResource) -> Dictionary:
	return {
		"container_id": view.get_container_id(),
		"layout": _discovery_layout_token_name(view),
		"grid_width": view.get_width(),
		"grid_height": view.get_height(),
		# Slot identifiers and item footprints are intentionally unavailable in
		# a discovery view; empty means "do not invent", not "no restriction".
		"slot_identifiers": [],
		"max_entries": view.get_capacity(),
	}


## This file's header comment's "Window chrome": a close [TextureButton]
## flush against the header strip's right edge (sized to fit the SAME
## `tokens.unit(2.0)` strip height every header already uses, per this
## file's established `header_height` convention), drawing [constant
## InventoryStateIcons.icon_for]'s `&"invalid_x"` texture (already
## registered, see that class's own header comment) and calling [method
## _on_window_close_pressed] for [param container_id] SPECIFICALLY -- unlike
## [method collapse_container]'s innermost-only pop, this closes exactly the
## window a player dismissed (see [method
## InventoryPresentationModel.close_container_id]). Plus a dedicated
## title-bar drag [Control] (MOUSE_FILTER_STOP) covering the REST of the
## header strip (never the close button's own rect, so a press there is
## never mistaken for a drag-start) whose `gui_input` only ever ARMS [member
## _window_drag] on a left press -- see that member's own doc comment for
## why the actual follow is [method _process] polling, not this Control's
## own motion events.
func _add_window_chrome(panel: Panel, header: Label, container_id: int, content_width: float, header_height: float) -> void:
	var close_size := header_height
	var drag_region_width := maxf(content_width - close_size, 0.0)
	header.size = Vector2(drag_region_width, header_height)

	var drag_region := Control.new()
	drag_region.name = "TitleBarDragRegion"
	drag_region.mouse_filter = Control.MOUSE_FILTER_STOP
	drag_region.position = Vector2.ZERO
	drag_region.size = Vector2(drag_region_width, header_height)
	drag_region.gui_input.connect(_on_window_title_bar_gui_input.bind(container_id))
	panel.add_child(drag_region)

	var close_button := TextureButton.new()
	close_button.name = "CloseButton"
	close_button.texture_normal = InventoryStateIcons.icon_for(&"invalid_x")
	close_button.ignore_texture_size = true
	close_button.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
	close_button.position = Vector2(content_width - close_size, 0.0)
	close_button.size = Vector2(close_size, close_size)
	close_button.tooltip_text = "Close"
	close_button.focus_mode = Control.FOCUS_ALL
	close_button.pressed.connect(_on_window_close_pressed.bind(container_id))
	panel.add_child(close_button)


func _on_window_close_pressed(container_id: int) -> void:
	if model != null:
		model.close_container_id(container_id)


## Only ARMS [member _window_drag] on a left press -- the actual FOLLOW is
## driven entirely by [method _process]'s own polling; see [member
## _window_drag]'s doc comment for why this method never itself repositions
## anything on a motion event.
func _on_window_title_bar_gui_input(event: InputEvent, container_id: int) -> void:
	var mb := event as InputEventMouseButton
	if mb == null or mb.button_index != MOUSE_BUTTON_LEFT or not mb.pressed:
		return
	var panel: Control = _container_panels.get(container_id, null)
	if panel == null:
		return
	_window_drag = {
		"container_id": container_id,
		"grab_offset": get_local_mouse_position() - panel.position,
	}
	set_process(true)


## [method _process]'s own per-frame window-drag follow: re-resolves [param
## container_id]'s panel FRESH every call (never a cached reference) since a
## rebuild triggered by something entirely unrelated (e.g. a different
## item's hover/selection) can replace it mid-drag -- exactly the same
## re-resolution discipline [method _finish_placement_animation]'s own doc
## comment documents for item drags. Silently ends the drag if the panel is
## no longer resolvable at all (e.g. the container closed out from under
## it).
func _update_window_drag_position() -> void:
	var cid := int(_window_drag.get("container_id", 0))
	var panel: Control = _container_panels.get(cid, null)
	if panel == null:
		_window_drag = {}
		return
	var grab_offset: Vector2 = _window_drag.get("grab_offset", Vector2.ZERO)
	var target := _clamp_window_position(get_local_mouse_position() - grab_offset, panel.size)
	panel.position = target
	_window_positions[cid] = target


func _instantiate_container(container_id: int, definition_identifier: String, inventory_id: int, side: StringName) -> Control:
	var info := _resolve_container_info(definition_identifier)
	var layout_token: StringName = info.get("layout_kind_token", InventoryRendererRegistry.LAYOUT_UNKNOWN)
	var control: Control = null
	if registry != null:
		control = registry.instantiate_for({"container_definition_identifier": definition_identifier, "layout_kind_token": layout_token})

	if control == null:
		# "Unknown layout has no renderer" (inventory-presentation spec) -- an
		# explicit unsupported-layout label, never a misleading mutable
		# fallback control.
		var placeholder := Label.new()
		placeholder.name = "UnsupportedLayout_%d" % container_id
		placeholder.text = "unsupported-layout: %s" % definition_identifier
		return placeholder

	if control is InventorySpatialGridControl:
		(control as InventorySpatialGridControl).configure(model, inventory_id, container_id,
				int(info.get("grid_width", 0)), int(info.get("grid_height", 0)), tokens, info.get("footprint_lookup", {}))
	elif control is InventoryNamedSlotsControl:
		(control as InventoryNamedSlotsControl).configure(model, inventory_id, container_id, info.get("slot_defs", []), tokens)
	elif control is InventoryOrderedListControl:
		(control as InventoryOrderedListControl).configure(model, inventory_id, container_id, tokens)
	elif control.has_method(&"configure"):
		# A GAME-REPLACED renderer for an unrecognized layout token (inventory-
		# presentation spec, "Game replaces a renderer"): best-effort minimal
		# `configure(model, inventory_id, container_id, tokens)` call. A richer
		# replacement that needs more (grid dims/slot defs/...) should extend
		# one of the three built-ins above instead, which this method still
		# recognizes via `is` (true for subclasses too).
		control.call(&"configure", model, inventory_id, container_id, tokens)

	if control.theme == null:
		control.theme = theme
	control.mouse_filter = Control.MOUSE_FILTER_PASS
	_wire_container_signals(control)
	return control


func _resolve_container_info(definition_identifier: String) -> Dictionary:
	if not container_info_resolver.is_valid():
		return {}
	var info: Variant = container_info_resolver.call(definition_identifier)
	return info if info is Dictionary else {}


func _layout_token_name(definition_identifier: String) -> StringName:
	var info := _resolve_container_info(definition_identifier)
	var token: StringName = info.get("layout_kind_token", &"")
	match token:
		InventoryRendererRegistry.LAYOUT_SPATIAL_GRID:
			return &"spatial"
		InventoryRendererRegistry.LAYOUT_NAMED_SLOTS:
			return &"named_slots"
		InventoryRendererRegistry.LAYOUT_ORDERED_LIST:
			return &"ordered_list"
		_:
			return &""


func _descriptor_entry_for(container_id: int, definition_identifier: String) -> Dictionary:
	var info := _resolve_container_info(definition_identifier)
	var slot_identifiers: Array = []
	for slot_variant in (info.get("slot_defs", []) as Array):
		slot_identifiers.append(String((slot_variant as Dictionary).get("identifier", "")))
	return {
		"container_id": container_id,
		"layout": _layout_token_name(definition_identifier),
		"grid_width": int(info.get("grid_width", 0)),
		"grid_height": int(info.get("grid_height", 0)),
		"slot_identifiers": slot_identifiers,
		"max_entries": int(info.get("max_entries", 0)),
	}


func _wire_container_signals(control: Control) -> void:
	if control.has_signal(&"intent_requested"):
		control.connect(&"intent_requested", _on_container_intent_requested)
	if control.has_signal(&"location_hover_entered"):
		control.connect(&"location_hover_entered", _on_location_hover_entered)
	if control.has_signal(&"location_hover_exited"):
		control.connect(&"location_hover_exited", _on_location_hover_exited)
	if control.has_signal(&"location_pointer_up"):
		control.connect(&"location_pointer_up", _on_location_pointer_up)


## `select`: a press ARMS a potential drag (tasks.md 8.5's press-hold-drag
## rework) instead of starting one immediately -- [method _process] promotes
## it into a real drag once the pointer moves past the threshold; a press
## released with no such movement stays a plain click/select (see [method
## _on_location_pointer_up]). The split-modifier ([constant
## InventoryInteractionController.ACTION_SPLIT_MODIFIER]) is checked live,
## right here at press time, matching that constant's own documented
## contract ("held ... at drag-press time") -- this is also the fix for
## visual-qa-2026-07-27.md finding 10 (the then-documented modifier split
## was unreachable), which was simply never wired to anything. Alt/Option is
## now the default accelerator.
##
## `open`: tasks.md 8.5's double-click-to-open affordance -- resolves and
## opens the double-clicked item's provided container (or falls back to
## inspect), see [method InventoryInteractionController.open_item]. This
## view's own in-pane focus/scroll/highlight ([method _on_container_opened],
## driven by the controller's [signal InventoryInteractionController.container_opened])
## has ALREADY happened -- synchronously, inside `open_item()` -- by the time
## [signal container_open_requested] fires right below, so a listener never
## races it.
func _on_container_intent_requested(kind: StringName, args: Dictionary) -> void:
	intent_requested.emit(kind, args)
	if interaction_controller == null:
		return
	if kind == &"context":
		interaction_controller.request_context_actions(
				int(args.get("inventory_id", 0)),
				int(args.get("item_id", 0)),
				args.get("anchor_global_position", Vector2.INF))
	elif kind == &"select":
		var inv_id := int(args.get("inventory_id", 0))
		var item_id := int(args.get("item_id", 0))
		if interaction_controller.is_merge_mode_active():
			interaction_controller.choose_merge_target(inv_id, item_id)
			return
		interaction_controller.note_selection(inv_id, item_id)
		var split_held := InputMap.has_action(InventoryInteractionController.ACTION_SPLIT_MODIFIER) \
					and Input.is_action_pressed(InventoryInteractionController.ACTION_SPLIT_MODIFIER)
		if interaction_controller.arm_pointer_drag(inv_id, item_id, get_local_mouse_position(), split_held):
			set_process(true)
	elif kind == &"open":
		var inv_id := int(args.get("inventory_id", 0))
		var item_id := int(args.get("item_id", 0))
		var container_id := interaction_controller.open_item(inv_id, item_id)
		if container_id != 0:
			container_open_requested.emit(inv_id, item_id, container_id)


func _on_location_hover_entered(container_id: int, location: Dictionary) -> void:
	if interaction_controller != null:
		interaction_controller.update_drag_target(container_id, location)


func _on_location_hover_exited(container_id: int, location: Dictionary) -> void:
	if interaction_controller != null:
		interaction_controller.clear_drag_target(container_id, location)


## A CONFIRMED drag resolves the drop as always; an ARMED-but-never-confirmed
## press (no movement past the threshold happened before release) is a plain
## click -- [method InventoryInteractionController.release_pointer_arm]
## clears it without submitting anything (tasks.md 8.5's press-hold-drag
## rework).
func _on_location_pointer_up(container_id: int, location: Dictionary) -> void:
	if interaction_controller == null:
		return
	if interaction_controller.is_dragging():
		var placement := _prepare_placement_animation(container_id, location)
		var result := interaction_controller.end_drag(container_id, location)
		_finish_placement_animation(placement, result)
	else:
		interaction_controller.release_pointer_arm()


## DESIGN.md §9's "Placement snap" -- the drop-release POINT has to be read
## BEFORE [method InventoryInteractionController.end_drag] runs, while the
## drag is still live and this is still the CURRENT rendered control for
## [param container_id]. Only [param container_id] itself (not the control
## reference) is kept for [method _finish_placement_animation] -- an ACCEPTED
## drop's own [signal InventoryPresentationModel.model_changed] (fired from
## inside `end_drag` itself) synchronously rebuilds the destination pane
## ([method _rebuild_pane] instantiates a BRAND NEW container control, it does
## not reuse the old one), so the control this method sees is a NOW-STALE
## instance the view is about to discard -- [method _finish_placement_animation]
## re-resolves [method container_control] fresh, AFTER `end_drag` returns, so
## it operates on whichever control is actually still displayed. Returns `{}`
## when this drop can never qualify (no active drag, a split -- which creates
## a NEW item id at the destination, not "the same card settling" -- the
## target isn't a rendered [InventorySpatialGridControl], or the target
## location isn't spatial); [method _finish_placement_animation] no-ops on an
## empty Dictionary.
func _prepare_placement_animation(container_id: int, location: Dictionary) -> Dictionary:
	if interaction_controller == null or String(location.get("kind", "")) != "spatial":
		return {}
	var target_control := container_control(container_id)
	if not (target_control is InventorySpatialGridControl):
		return {}
	var drag_state := interaction_controller.get_drag_state()
	if drag_state.is_empty() or StringName(drag_state.get("kind", &"move")) == &"split":
		return {}
	return {
		"container_id": container_id,
		"item_id": int(drag_state.get("item_id", 0)),
		"release_position": (target_control as Control).get_local_mouse_position(),
	}


## Only an ACCEPTED command (DESIGN.md §9's "on an ACCEPTED drop") replays the
## tween -- a rejected/awaiting-quantity/no-op result leaves the card exactly
## where [method InventorySpatialGridControl._rebuild] already put it (its
## unchanged current location for a rejection), so this view never needs to
## special-case rejection itself. Re-resolves the container control NOW
## (see [method _prepare_placement_animation]'s doc comment for why this
## can't be the same reference captured before `end_drag` ran).
func _finish_placement_animation(placement: Dictionary, result: Dictionary) -> void:
	if placement.is_empty() or not bool(result.get("accepted", false)):
		return
	var control := container_control(int(placement["container_id"]))
	if not (control is InventorySpatialGridControl):
		return
	(control as InventorySpatialGridControl).animate_placement(int(placement["item_id"]), placement["release_position"] as Vector2)


# =============================================================================
# Pane header: label + derived mass/capacity readout
# =============================================================================

func _update_pane_header(side: StringName, inventory_id: int) -> void:
	var header: Label = _pane_headers.get(side, null)
	if header == null:
		return
	var label_text := String(_pane_label_override.get(side, ""))
	if label_text.is_empty():
		if model != null and model.has_snapshot(inventory_id):
			label_text = model.get_snapshot(inventory_id).get_profile_identifier()
		elif inventory_id != 0:
			label_text = "inventory %d" % inventory_id
		else:
			label_text = "—"

	var readout := _mass_capacity_readout(inventory_id)
	header.text = "%s  %s" % [label_text, readout] if not readout.is_empty() else label_text
	# §10.3: the full, untruncated string stays reachable via the native
	# tooltip even when `clip_text`/`OVERRUN_TRIM_ELLIPSIS` (set once in
	# [method _build_pane]) visually truncates it.
	header.tooltip_text = header.text


## "derived mass/capacity readout via authority queries when available, '—'
## when feature unavailable" (tasks.md 8.4). Mass sums from the single
## whole-inventory `total_mass()` query; capacity has no whole-inventory
## equivalent so it sums every root+nested container's own
## `container_mass_capacity()` that reports `ok: true` (containers without
## the capacity feature simply don't contribute, never inventing a bound).
func _mass_capacity_readout(inventory_id: int) -> String:
	if inventory_id == 0 or command_sink == null:
		return ""
	var mass_text := "—"
	if command_sink.has_method(&"total_mass"):
		var mass_result: Dictionary = command_sink.call(&"total_mass", inventory_id)
		if bool(mass_result.get("ok", false)):
			mass_text = str(int(mass_result.get("mass_mg", 0)))

	var capacity_text := "—"
	if command_sink.has_method(&"container_mass_capacity") and model != null and model.has_snapshot(inventory_id):
		var total_capacity := 0
		var any_capacity := false
		for container_variant in model.get_snapshot(inventory_id).get_containers():
			var container: Dictionary = container_variant
			var capacity_result: Dictionary = command_sink.call(&"container_mass_capacity", inventory_id, int(container.get("id", 0)))
			if bool(capacity_result.get("ok", false)):
				any_capacity = true
				total_capacity += int(capacity_result.get("mass_capacity_mg", 0))
		if any_capacity:
			capacity_text = str(total_capacity)

	if mass_text == "—" and capacity_text == "—":
		return ""
	return "%s / %s mg" % [mass_text, capacity_text]


# =============================================================================
# Layout: side-by-side / stacked reflow (DESIGN.md §8)
# =============================================================================

func _update_layout() -> void:
	if tokens == null:
		return
	var unit := tokens.unit_effective()
	if unit <= 0.0:
		return

	var margin := _snap(tokens.unit(2.0)) # §8 safe-area outer margin, space_2.
	# `size` is the OUTER viewport/window bound this view was given -- an
	# external constraint (a real display resolution), never geometry this
	# addon computes, so it is NOT itself required to be unit-aligned (see
	# the harness's [code]skip_self[/code] parameter for the same rationale).
	# `usable` -- the space this view's OWN layout math actually derives
	# pane geometry from -- IS snapped here so every value derived from it
	# below stays unit-aligned, instead of inheriting the viewport's own
	# unaligned remainder.
	var usable := Vector2(_snap(maxf(size.x - margin * 2.0, 0.0)), _snap(maxf(size.y - margin * 2.0, 0.0)))
	var stacked := size.x < tokens.unit(tokens.stacked_max_width_units)
	var header_height := _snap(tokens.unit(2.0))

	var left_root: Control = _pane_roots[SIDE_LEFT]
	var right_root: Control = _pane_roots[SIDE_RIGHT]
	if stacked:
		_aux_root.visible = false
		_aux_root.size = Vector2.ZERO
		var half_height := _snap(usable.y * 0.5)
		left_root.position = Vector2(margin, margin)
		left_root.size = Vector2(usable.x, half_height)
		right_root.position = Vector2(margin, margin + half_height)
		right_root.size = Vector2(usable.x, usable.y - half_height)
	else:
		# DESIGN.md §10.1: each pane keeps its own normal max content width
		# ([constant PANE_MAX_CONTENT_WIDTH_UNITS]) instead of stretching to
		# fill an arbitrarily wide viewport -- at/below that width (every
		# declared resolution up to ~2560x1440) `pane_width` is simply
		# `natural_half`, byte-for-byte the pre-existing behavior; only once
		# the viewport is wider than that (ultrawide) does the excess get
		# redirected into a centered gutter (plus an optional fixed-width aux
		# column) instead of stretching the panes toward the far edges.
		var pane_max_width := _snap(tokens.unit(PANE_MAX_CONTENT_WIDTH_UNITS))
		var natural_half := usable.x * 0.5
		var pane_width := _snap(minf(natural_half, pane_max_width)) if pane_max_width > 0.0 else _snap(natural_half)
		var content_width := pane_width * 2.0
		var gutter := maxf(usable.x - content_width, 0.0)

		var aux_gap := tokens.unit(2.0)
		var aux_width := 0.0
		if gutter >= tokens.unit(_ULTRAWIDE_AUX_MIN_WIDTH_UNITS):
			aux_width = _snap(tokens.unit(_ULTRAWIDE_AUX_COLUMN_WIDTH_UNITS))

		# Only ONE gap is actually placed (between the right pane and the aux
		# column itself -- the aux column is the block's own trailing edge,
		# nothing sits after it needing a second gap), so the centered block
		# this `side_gutter` derives from must only account for that one gap;
		# double-counting it here would inflate `side_gutter` and leave the
		# TRAILING gutter (measured past the aux column) wider than the
		# leading one by exactly one `aux_gap`.
		var block_extra := (aux_width + aux_gap) if aux_width > 0.0 else 0.0
		var block_width := content_width + block_extra
		var side_gutter := _snap(maxf((usable.x - block_width) * 0.5, 0.0))

		left_root.position = Vector2(margin + side_gutter, margin)
		left_root.size = Vector2(pane_width, usable.y)
		right_root.position = Vector2(margin + side_gutter + pane_width, margin)
		right_root.size = Vector2(pane_width, usable.y)

		_aux_root.visible = aux_width > 0.0
		if aux_width > 0.0:
			_aux_root.position = Vector2(margin + side_gutter + content_width + aux_gap, margin)
			_aux_root.size = Vector2(aux_width, usable.y)
		else:
			_aux_root.size = Vector2.ZERO

	for side in [SIDE_LEFT, SIDE_RIGHT]:
		var root: Control = _pane_roots[side]
		var header: Label = _pane_headers[side]
		header.position = Vector2.ZERO
		header.size = Vector2(root.size.x, header_height)
		var scroll: ScrollContainer = _pane_scrolls[side]
		scroll.position = Vector2(0.0, header_height)
		scroll.size = Vector2(root.size.x, maxf(root.size.y - header_height, 0.0))

	# [member _window_root] is a full-rect overlay above BOTH panes,
	# independent of whichever layout regime (stacked/side-by-side/ultrawide)
	# is active above -- kept in sync with this view's own size on every
	# resize, exactly like the split-quantity modal below. `_snap`ped (unlike
	# `size` itself, which is the view's own OUTER, externally-constrained
	# bound and therefore exempt -- see the harness's own `skip_self`
	# rationale quoted a few lines up): [member _window_root] is an ordinary
	# DESCENDANT control, not this view's own root, so its geometry is held
	# to the same unit-alignment contract as every other child here. Harmless
	# to round down to the nearest unit rather than up -- nothing reads
	# [member _window_root]'s own `.size` for hit-testing or clamping
	# (Godot's [Control] never clips children to its own declared size by
	# default, and [method _clamp_window_position] always measures against
	# this VIEW's own `size` directly, never this layer's). A resize can
	# strand an already-placed window partly or fully outside the view's NEW
	# rect, so every stored [member _window_positions] entry (and its live
	# panel, if one is currently mounted) is re-clamped here too.
	_window_root.position = Vector2.ZERO
	_window_root.size = Vector2(_snap(size.x), _snap(size.y))
	for cid in _window_positions.keys():
		var window_panel: Control = _container_panels.get(cid, null)
		var panel_size: Vector2 = window_panel.size if window_panel != null else Vector2.ZERO
		var clamped := _clamp_window_position(_window_positions[cid], panel_size)
		_window_positions[cid] = clamped
		if window_panel != null:
			window_panel.position = clamped

	# The split-quantity modal is a full-viewport overlay (its scrim must
	# cover the whole view, not just one pane) -- kept in sync with this
	# view's own size whenever it resizes, exactly like every pane root above.
	if _split_modal != null:
		_split_modal.size = size
	if _inspect_modal != null:
		_inspect_modal.size = size


## Rounds [param value] to the nearest whole `unit_effective()` multiple --
## every geometry value this view computes from a fractional viewport split
## goes through this, so a resize never introduces a non-unit pixel
## remainder (tasks.md 8.4's "no hard-coded pixel geometry", extended to
## "no ACCIDENTAL non-unit geometry" for values derived from division).
func _snap(value: float) -> float:
	var unit := tokens.unit_effective() if tokens != null else 1.0
	if unit <= 0.0:
		return value
	return round(value / unit) * unit


# =============================================================================
# Drag ghost / move-mode / split-quantity rendering (driven by the controller)
# =============================================================================

func _connect_controller_signals(controller: InventoryInteractionController) -> void:
	controller.drag_started.connect(_on_drag_started)
	controller.drag_target_updated.connect(_on_drag_target_updated)
	controller.drag_ended.connect(_on_drag_ended)
	controller.move_mode_started.connect(_on_move_mode_started)
	controller.move_mode_updated.connect(_on_move_mode_target_updated)
	controller.move_mode_ended.connect(_on_drag_ended)
	controller.split_quantity_requested.connect(_on_split_quantity_requested)
	controller.split_quantity_closed.connect(_on_split_quantity_closed)
	controller.inspect_requested.connect(_on_inspect_requested)
	controller.container_opened.connect(_on_container_opened)
	controller.context_actions_requested.connect(_on_context_actions_requested)
	controller.merge_mode_started.connect(_on_merge_mode_started)
	controller.merge_mode_updated.connect(_on_merge_mode_updated)
	controller.merge_mode_ended.connect(_on_merge_mode_ended)


func _disconnect_controller_signals(controller: InventoryInteractionController) -> void:
	if controller.drag_started.is_connected(_on_drag_started):
		controller.drag_started.disconnect(_on_drag_started)
	if controller.drag_target_updated.is_connected(_on_drag_target_updated):
		controller.drag_target_updated.disconnect(_on_drag_target_updated)
	if controller.drag_ended.is_connected(_on_drag_ended):
		controller.drag_ended.disconnect(_on_drag_ended)
	if controller.move_mode_started.is_connected(_on_move_mode_started):
		controller.move_mode_started.disconnect(_on_move_mode_started)
	if controller.move_mode_updated.is_connected(_on_move_mode_target_updated):
		controller.move_mode_updated.disconnect(_on_move_mode_target_updated)
	if controller.move_mode_ended.is_connected(_on_drag_ended):
		controller.move_mode_ended.disconnect(_on_drag_ended)
	if controller.split_quantity_requested.is_connected(_on_split_quantity_requested):
		controller.split_quantity_requested.disconnect(_on_split_quantity_requested)
	if controller.split_quantity_closed.is_connected(_on_split_quantity_closed):
		controller.split_quantity_closed.disconnect(_on_split_quantity_closed)
	if controller.inspect_requested.is_connected(_on_inspect_requested):
		controller.inspect_requested.disconnect(_on_inspect_requested)
	if controller.container_opened.is_connected(_on_container_opened):
		controller.container_opened.disconnect(_on_container_opened)
	if controller.context_actions_requested.is_connected(_on_context_actions_requested):
		controller.context_actions_requested.disconnect(_on_context_actions_requested)
	if controller.merge_mode_started.is_connected(_on_merge_mode_started):
		controller.merge_mode_started.disconnect(_on_merge_mode_started)
	if controller.merge_mode_updated.is_connected(_on_merge_mode_updated):
		controller.merge_mode_updated.disconnect(_on_merge_mode_updated)
	if controller.merge_mode_ended.is_connected(_on_merge_mode_ended):
		controller.merge_mode_ended.disconnect(_on_merge_mode_ended)


func _on_drag_started(_inventory_id: int, _item_id: int, footprint: Vector2i, rotated: bool) -> void:
	_dismiss_context_menu()
	var span := Vector2i(footprint.y, footprint.x) if rotated else footprint
	var cell_px := tokens.grid_cell_px() if tokens != null else 1.0
	drag_ghost.begin(Vector2(cell_px * maxi(span.x, 1), cell_px * maxi(span.y, 1)), tokens)
	if interaction_controller != null:
		var drag_state := interaction_controller.get_drag_state()
		if drag_state.get("kind", &"move") == &"split_half":
			drag_ghost.set_staged_quantity(int(drag_state.get("quantity", 0)))
	set_process(true)


## Keyboard/gamepad "move-mode" (tasks.md 8.6): the ghost is parked over the
## SOURCE item's own card as a validity-feedback surface; unlike a pointer
## drag it is not repositioned per navigation step in this wave (the
## LOGICAL candidate location is fully tracked by the controller regardless
## -- see [InventoryInteractionController.get_move_mode_state]).
func _on_move_mode_started(inventory_id: int, item_id: int) -> void:
	_dismiss_context_menu()
	var card := _card_for_item(inventory_id, item_id)
	if card != null:
		drag_ghost.begin(card.size, tokens)
		drag_ghost.position = get_global_transform().affine_inverse() * card.get_global_transform().origin
	else:
		drag_ghost.begin(Vector2(tokens.grid_cell_px(), tokens.grid_cell_px()), tokens)
	set_process(true)


func _on_drag_target_updated(state: StringName, _container_id: int, _location: Dictionary) -> void:
	drag_ghost.set_drop_state(state)


## Keyboard/gamepad parity companion to [method _on_drag_target_updated]
## (DESIGN.md §11.3, this file's header comment): a pointer drag's per-frame
## [method _update_drag_visuals] and move-mode's SIGNAL-driven candidate
## updates are two different call sites feeding the exact same underlying
## preview machinery ([method _update_drag_preview]/[method
## _apply_drop_preview]) -- move-mode has no [method _process] polling of its
## own (there is no continuous "drag" while parked in move-mode), so this is
## the one place its candidate change gets translated into that shared call.
func _on_move_mode_target_updated(state: StringName, container_id: int, location: Dictionary) -> void:
	drag_ghost.set_drop_state(state)
	if interaction_controller == null:
		_clear_active_preview()
		return
	var move_state := interaction_controller.get_move_mode_state()
	if move_state.is_empty():
		_clear_active_preview()
		return
	var inv_id := int(move_state.get("inventory_id", 0))
	var item_id := int(move_state.get("item_id", 0))
	var rotated := bool(move_state.get("rotated", false))
	var span := _resolve_drag_span(inv_id, item_id, rotated)
	# Also keeps the parked ghost's own footprint in sync with the CURRENT
	# (possibly just-rotated) span -- the same thing a pointer drag's
	# per-frame [method _update_drag_visuals] does for its own ghost.
	var cell_px := tokens.grid_cell_px() if tokens != null else 1.0
	drag_ghost.set_footprint_px(Vector2(cell_px * maxi(span.x, 1), cell_px * maxi(span.y, 1)))
	_update_drag_preview({"target_container_id": container_id, "target_location": location, "target_state": state, "inventory_id": inv_id}, span)


func _on_drag_ended() -> void:
	drag_ghost.end()
	_clear_active_preview()
	set_process(false)


## Tasks.md 8.5's double-click/context-menu/keyboard "open" affordance:
## [signal InventoryInteractionController.container_opened] fires AFTER the
## controller has already pushed [param container_id] onto the model's
## open-container ancestry and this view has already rebuilt both panes
## (both happen synchronously inside [method
## InventoryInteractionController.open_item]) -- so the container's own
## rendered section is guaranteed present in [member _container_panels] by
## the time this runs (UNLESS [member render_open_container_windows] is
## `false`, in which case this view never rendered one at all -- see that
## member's doc comment -- and this is a no-op). A WINDOWED panel (parented
## under [member _window_root], the guard this method uses to tell the two
## cases apart) is never inside a [ScrollContainer], so [method
## ScrollContainer.ensure_control_visible] would be meaningless for it --
## instead it is raised to the FRONT of [member _window_root]'s own child
## order (`move_child` to the end), so reopening an already-open window that
## happens to be covered by another one raises it back on top. Either way,
## engine input focus and the transient accent highlight are applied
## identically.
func _on_container_opened(container_id: int) -> void:
	var panel: Control = _container_panels.get(container_id, null)
	if panel == null:
		return
	if panel.get_parent() == _window_root:
		_window_root.move_child(panel, _window_root.get_child_count() - 1)
	else:
		var side: StringName = _container_side.get(container_id, &"")
		var scroll: ScrollContainer = _pane_scrolls.get(side, null)
		if scroll != null:
			scroll.ensure_control_visible(panel)
	panel.grab_focus()
	_highlight_opened_panel(panel)


## `&"opened"` is a plain ad hoc StringName state (like this Theme's own
## `&"stale-corrected"`/`&"hover"`/... entries -- never one of
## [InventoryPresentationModel]'s formal `STATE_*` tokens) registered on
## [constant InventoryThemeFactory.TYPE_CONTAINER_PANEL] purely for this
## transient highlight; a no-op if the active Theme doesn't define it (a
## game's own replacement Theme is never required to).
func _highlight_opened_panel(panel: Control) -> void:
	var stylebox := panel.get_theme_stylebox(InventoryThemeFactory.state_stylebox_name(&"opened"), InventoryThemeFactory.TYPE_CONTAINER_PANEL)
	if stylebox != null:
		panel.add_theme_stylebox_override(&"panel", stylebox)


## DESIGN.md §12.10's real modal host for the split-quantity flow (tasks.md
## 8.3/8.5; docs/inventory/visual-qa-2026-07-27.md finding 8): an
## [InventoryModal] hosting the same [InventoryQuantitySpinner] this view
## always used, now scrimmed/focus-trapped/animated instead of a bare popup.
## Teardown is uniform regardless of which path resolves the pending split
## (spinner's own Confirm/Cancel buttons, the modal's scrim/Esc [signal
## InventoryModal.dismiss_requested], or [method
## InventoryInteractionController.cancel] via some OTHER route entirely, e.g.
## a right-click) -- every one of those paths only ever calls [method
## InventoryInteractionController.confirm_split]/[method
## InventoryInteractionController.cancel_split] on the controller; [method
## _on_split_quantity_closed] (wired to [signal
## InventoryInteractionController.split_quantity_closed], itself fired by
## BOTH of those controller methods) is the SOLE place this modal actually
## closes. This is the fix for the flow-sheet step-7 defect: the OLD bare
## spinner only ever hid itself from its own Cancel button, so an Esc-driven
## cancel (which never touches the spinner directly) left it visibly stuck
## onscreen.
func _on_split_quantity_requested(_inventory_id: int, _item_id: int, min_value: int, max_value: int, default_value: int) -> void:
	if _quantity_spinner == null:
		_quantity_spinner = InventoryQuantitySpinner.new()
		_quantity_spinner.confirmed.connect(func(value: int):
			if interaction_controller != null:
				interaction_controller.confirm_split(value))
		_quantity_spinner.cancelled.connect(func():
			if interaction_controller != null:
				interaction_controller.cancel_split())
	if _split_modal == null:
		_split_modal = InventoryModal.new()
		add_child(_split_modal)
		_split_modal.dismiss_requested.connect(func():
			if interaction_controller != null:
				interaction_controller.cancel_split())
	if _split_modal.theme == null:
		_split_modal.theme = theme
	_split_modal.size = size
	_split_modal.set_title("Split quantity", tokens)
	_quantity_spinner.configure(min_value, max_value, default_value, tokens)
	_split_modal.set_content(_quantity_spinner)
	_split_modal.present()


## The one place [member _split_modal] actually closes -- see [method
## _on_split_quantity_requested]'s doc comment for why every resolution path
## funnels through this single signal instead of each path closing the modal
## itself.
func _on_split_quantity_closed() -> void:
	if _split_modal != null:
		_split_modal.close()


# =============================================================================
# Inspect modal (DESIGN.md §12.6)
# =============================================================================

## The controller owns inspect eligibility/data resolution; this view owns
## the default persistent presentation. A host with a serialized modal stack
## can replace it through [member inspect_presenter] without changing the
## controller action or snapshot payload.
func _on_inspect_requested(inventory_id: int, item_id: int,
		item_info: Dictionary) -> void:
	_dismiss_context_menu()
	if inspect_presenter.is_valid():
		inspect_presenter.call(inventory_id, item_id, item_info.duplicate(true))
		return
	if _inspect_details == null:
		_inspect_details = InventoryItemDetailsScript.new()
		_inspect_details.close_requested.connect(_close_inspect_modal)
	if _inspect_modal == null:
		_inspect_modal = InventoryModal.new()
		add_child(_inspect_modal)
		_inspect_modal.dismiss_requested.connect(_close_inspect_modal)
	if _inspect_modal.theme == null:
		_inspect_modal.theme = theme
	_inspect_modal.size = size
	_inspect_details.populate(model, inventory_id, item_info,
			interaction_controller.footprint_lookup if interaction_controller != null else {},
			interaction_controller.mass_lookup if interaction_controller != null else {},
			tokens)
	_inspect_modal.set_title(_inspect_details.display_name(), tokens)
	_inspect_modal.set_content(_inspect_details)
	_inspect_modal.apply_state(StringName(item_info.get(
			"state", InventoryPresentationModel.STATE_NORMAL)))
	_inspect_modal.present()


func _close_inspect_modal() -> void:
	if _inspect_modal != null:
		_inspect_modal.close()


# =============================================================================
# Context menu (tasks.md 8.3/8.5; docs/inventory/visual-qa-2026-07-27.md
# finding 8): real InventoryContextMenu built/reused from [signal
# InventoryInteractionController.context_actions_requested]'s real
# [method InventoryInteractionController.available_actions] data, anchored at
# the target item's own rendered card.
# =============================================================================

## Real production data ([method InventoryInteractionController.available_actions],
## already resolved by the controller before this fires) -> a real, themed
## [InventoryContextMenu] -- the gap docs/inventory/visual-qa-2026-07-27.md
## finding 8 flagged (previously ONLY the QA driver ever built a PopupMenu
## from this data; no shipped control consumed it at all).
func _on_context_actions_requested(inventory_id: int, item_id: int, actions: Array,
		anchor_global_position: Vector2) -> void:
	if context_actions_presenter.is_valid():
		context_actions_presenter.call(
				inventory_id, item_id, actions.duplicate(true),
				anchor_global_position)
		return
	if _context_menu == null:
		_context_menu = InventoryContextMenu.new()
		add_child(_context_menu)
		_context_menu.action_selected.connect(_on_context_menu_action_selected)
	if _context_menu.theme == null:
		_context_menu.theme = theme
	_context_menu_target = {"inventory_id": inventory_id, "item_id": item_id}
	_context_menu.populate(actions, tokens)
	var anchor := anchor_global_position
	if not anchor.is_finite():
		anchor = _context_menu_anchor_position(inventory_id, item_id)
	_context_menu.present(anchor)


## [InventoryContextMenu] already dismisses itself on action-press/Esc/
## outside-press ([InventoryContextMenu]'s own `_unhandled_input`/entry-press
## wiring) -- this handler only needs to DISPATCH the pressed action, exactly
## like a real click/tap on the target item would.
func _on_context_menu_action_selected(action_id: StringName) -> void:
	if interaction_controller == null or model == null or _context_menu_target.is_empty():
		return
	var inventory_id := int(_context_menu_target.get("inventory_id", 0))
	var item_id := int(_context_menu_target.get("item_id", 0))
	var sel := model.get_selection()
	if int(sel.get("inventory_id", 0)) != inventory_id or int(sel.get("item_id", 0)) != item_id:
		interaction_controller.note_selection(inventory_id, item_id)
		model.select(inventory_id, item_id)
	interaction_controller.perform_action(action_id)


## A drag starting while a context menu happens to be open (e.g. a pointer
## press-drag on a DIFFERENT item, or keyboard/gamepad move-mode) leaves a
## stale menu floating over content that's about to change -- dismiss it
## rather than let it linger. [method InventoryContextMenu.dismiss] is itself
## a no-op when nothing is open, so this is safe to call unconditionally.
func _dismiss_context_menu() -> void:
	if _context_menu != null:
		_context_menu.dismiss()


# =============================================================================
# Explicit Merge… target highlighting
# =============================================================================

func _on_merge_mode_started(_inventory_id: int, _source_item_id: int,
		_candidate_item_ids: Array) -> void:
	_dismiss_context_menu()
	_refresh_merge_previews()


func _on_merge_mode_updated(_inventory_id: int, _source_item_id: int,
		_target_item_id: int, _candidate_item_ids: Array) -> void:
	_refresh_merge_previews()


func _on_merge_mode_ended() -> void:
	_clear_merge_previews()


## All complete-stack-compatible candidates carry the design system's
## drop-occupied warning outline while Merge… target mode is active. The
## currently focused target additionally retains the model's ordinary
## selected/focus treatment, preserving a second non-color cue.
func _refresh_merge_previews() -> void:
	_clear_merge_previews()
	if interaction_controller == null:
		return
	var state := interaction_controller.get_merge_mode_state()
	if state.is_empty():
		return
	var inventory_id := int(state.get("inventory_id", 0))
	for item_id_variant in (state.get("candidate_item_ids", []) as Array):
		var control := _card_for_item(inventory_id, int(item_id_variant))
		if control == null:
			continue
		var stylebox: StyleBox
		if control is InventoryItemCard:
			stylebox = control.get_theme_stylebox(
					InventoryThemeFactory.state_stylebox_name(&"drop-occupied"),
					InventoryThemeFactory.TYPE_ITEM_CARD)
			if stylebox != null:
				(control as InventoryItemCard).set_drop_preview_stylebox(stylebox)
		else:
			stylebox = control.get_theme_stylebox(
					InventoryThemeFactory.state_stylebox_name(&"drop-occupied"),
					InventoryThemeFactory.TYPE_LIST_ROW)
			if stylebox != null:
				control.add_theme_stylebox_override(&"panel", stylebox)
		if stylebox != null:
			_merge_preview_controls.append(control)


func _clear_merge_previews() -> void:
	for control in _merge_preview_controls:
		if control == null or not is_instance_valid(control):
			continue
		if control is InventoryItemCard:
			(control as InventoryItemCard).clear_drop_preview_stylebox()
		else:
			control.remove_theme_stylebox_override(&"panel")
	_merge_preview_controls.clear()


## The target item's own rendered card's top-left corner (global space) when
## one is currently rendered -- matching [method _on_move_mode_started]'s
## identical per-layout card lookup; falls back to the item's own pane's
## center, and finally to the current pointer position, for the
## touch-hold/keyboard-context-menu case where no on-screen card can be
## resolved (e.g. the item scrolled out of its pane's visible region).
func _context_menu_anchor_position(inventory_id: int, item_id: int) -> Vector2:
	var card := _card_for_item(inventory_id, item_id)
	if card != null:
		return card.get_global_rect().position
	for side in _pane_inventory:
		if int(_pane_inventory[side]) == inventory_id:
			var root: Control = _pane_roots.get(side, null)
			if root != null:
				return root.get_global_rect().get_center()
	return get_global_mouse_position()


## Shared by [method _on_move_mode_started] (the keyboard/gamepad move-mode
## ghost anchor) and [method _context_menu_anchor_position] -- the per-layout
## "find this item's own rendered card/row" lookup every container layout
## exposes under a slightly different method name.
func _card_for_item(inventory_id: int, item_id: int) -> Control:
	if interaction_controller == null:
		return null
	var container_id := interaction_controller.container_id_for_item(inventory_id, item_id)
	if container_id == 0:
		return null
	var control := container_control(container_id)
	if control is InventorySpatialGridControl:
		return (control as InventorySpatialGridControl).card_for_item(item_id)
	elif control is InventoryNamedSlotsControl:
		return (control as InventoryNamedSlotsControl).card_for_item(item_id)
	elif control is InventoryOrderedListControl:
		return (control as InventoryOrderedListControl).row_panel_for(item_id)
	elif control is InventoryDiscoveryContainerControl:
		return (control as InventoryDiscoveryContainerControl).card_for_item(item_id)
	return null


## Drives FIVE things every frame while a press is armed, a drag is active,
## or a window-drag is active (tasks.md 8.5's press-hold-drag rework +
## constant snapped cell-occupancy preview + this file's own window-drag
## polling, [member _window_drag]): (0) following an in-progress WINDOW drag
## ([method _update_window_drag_position]) -- checked first and entirely
## independent of [member interaction_controller], since a title-bar press
## never touches that controller at all (see [member _window_drag]'s own doc
## comment for why this is polled here rather than driven by the title bar's
## own `gui_input` motion events, and for why it can never collide with (1)-
## (4) below: a title-bar press never arms an item drag); (1) promoting an
## armed press into a real drag once the pointer moves past the threshold,
## (2) following the pointer + keeping the ghost's footprint correct
## (including a mid-drag rotate), (3) the DESIGN.md §11.2 snapped
## drop-target preview on the actual hovered container control, and (4)
## discovering the PHYSICAL release of the mouse button by POLLING [method
## Input.is_mouse_button_pressed] every frame instead of trusting the
## event-driven [signal location_pointer_up]/[method _on_location_pointer_up]
## path -- see [constant _DRAG_MOVE_THRESHOLD_UNITS]'s doc comment for why a
## real mouse's release event cannot be relied upon here (the select-triggered
## rebuild frees the pressed card, Godot drops the viewport's gui mouse focus
## along with it, and a release event only ever reaches whatever control
## currently holds that focus -- nothing, by then). An armed-but-not-dragging
## press whose button is no longer held is a plain click that already
## resolved at press time -- [method
## InventoryInteractionController.release_pointer_arm] just clears the now-
## stale arm so the next pointer motion can't misread it as a drag. A LIVE
## drag whose button is no longer held resolves the drop immediately, at the
## controller's current hover target (see [method
## _resolve_drag_release_at_current_target]), replaying the exact same accept
## path [method _on_location_pointer_up] uses -- that event-driven path stays
## exactly as-is (direct/test callers still use it, and a lucky cell
## `gui_input` occasionally still catches a release), and both paths guard on
## [method InventoryInteractionController.is_dragging] so double-resolution
## can never happen. Self-disables once nothing (armed press, item drag, OR
## window drag) is still active, exactly like the pre-window-drag version did
## for "not dragging" alone.
func _process(_delta: float) -> void:
	var button_held := Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)

	if not _window_drag.is_empty():
		if button_held:
			_update_window_drag_position()
		else:
			_window_drag = {}

	if interaction_controller == null:
		if _window_drag.is_empty():
			set_process(false)
		return
	if interaction_controller.is_drag_armed() and not interaction_controller.is_dragging():
		if button_held:
			var threshold_px := tokens.unit(_DRAG_MOVE_THRESHOLD_UNITS) if tokens != null else 4.0
			interaction_controller.update_pointer_position(get_local_mouse_position(), threshold_px)
		else:
			interaction_controller.release_pointer_arm()
	if interaction_controller.is_dragging():
		if button_held:
			_update_drag_visuals()
		else:
			_resolve_drag_release_at_current_target()
		return
	if not interaction_controller.is_drag_armed() and _window_drag.is_empty():
		set_process(false)


## Resolves a LIVE drag the instant [method _process] discovers the physical
## mouse button is no longer held (see that method's own doc comment for why
## this can't simply wait for [signal location_pointer_up]) -- reads the
## controller's own CURRENT hover bookkeeping ([method
## InventoryInteractionController.get_drag_state], kept live by [method
## _on_location_hover_entered]/[method _on_location_hover_exited] the whole
## drag) and replays [method _on_location_pointer_up]'s own accept path
## exactly: capture the placement-tween info BEFORE [method
## InventoryInteractionController.end_drag] mutates anything, submit the drop,
## then replay the tween against whichever control is still on-screen after.
## Released over no valid target ([code]target_container_id == 0[/code])
## instead cancels -- nothing was ever mutated, so the item simply snaps back
## to wherever [InventorySpatialGridControl] et al. already have it.
func _resolve_drag_release_at_current_target() -> void:
	var drag_state := interaction_controller.get_drag_state()
	var target_container_id := int(drag_state.get("target_container_id", 0))
	if target_container_id == 0:
		interaction_controller.cancel_drag()
		return
	var target_location: Dictionary = drag_state.get("target_location", {})
	var placement := _prepare_placement_animation(target_container_id, target_location)
	var result := interaction_controller.end_drag(target_container_id, target_location)
	_finish_placement_animation(placement, result)


## Ghost follow/resize + snapped cell-occupancy preview, driven purely by
## POLLING [method InventoryInteractionController.get_drag_state] every frame
## (see that method's own doc comment for why) rather than threading every
## one of these concerns through bespoke signal payloads.
func _update_drag_visuals() -> void:
	var pointer := get_local_mouse_position()
	drag_ghost.follow_pointer(pointer)
	if interaction_controller == null:
		return
	var drag_state := interaction_controller.get_drag_state()
	if drag_state.is_empty():
		_clear_active_preview()
		return
	var inv_id := int(drag_state.get("inventory_id", 0))
	var item_id := int(drag_state.get("item_id", 0))
	var rotated := bool(drag_state.get("rotated", false))
	var span := _resolve_drag_span(inv_id, item_id, rotated)
	var cell_px := tokens.grid_cell_px() if tokens != null else 1.0
	drag_ghost.set_footprint_px(Vector2(cell_px * maxi(span.x, 1), cell_px * maxi(span.y, 1)))
	_update_drag_preview(drag_state, span)


## Rotation-aware footprint span for [param item_id], shared by BOTH the
## pointer-drag path ([method _update_drag_visuals]) and the move-mode path
## ([method _on_move_mode_target_updated]) -- the one piece of per-frame/
## per-candidate math common to both, factored out so move-mode's preview can
## reuse it verbatim instead of forking the lookup (this file's header
## comment).
func _resolve_drag_span(inventory_id: int, item_id: int, rotated: bool) -> Vector2i:
	var identifier := _item_definition_identifier(inventory_id, item_id)
	var footprint: Vector2i = interaction_controller.footprint_lookup.get(identifier, Vector2i(1, 1))
	return Vector2i(footprint.y, footprint.x) if rotated else footprint


func _item_definition_identifier(inventory_id: int, item_id: int) -> String:
	if model == null or not model.has_snapshot(inventory_id):
		return ""
	for item_variant in model.get_snapshot(inventory_id).get_items():
		var item: Dictionary = item_variant
		if int(item.get("id", 0)) == item_id:
			return String(item.get("item_definition_identifier", ""))
	return ""


## Re-applies the snapped preview EVERY frame (each container control's own
## `set_drop_preview()` already clears its prior preview first, so this is
## idempotent and self-correcting even across a mid-drag pane rebuild that
## replaced the target's control instance) -- clearing whatever a DIFFERENT
## container was previously carrying when the hovered target moves to a new
## one.
func _update_drag_preview(drag_state: Dictionary, span: Vector2i) -> void:
	var target_container_id := int(drag_state.get("target_container_id", 0))
	if target_container_id != _preview_container_id and _preview_container_id != 0:
		_clear_preview_on(_preview_container_id)
	_preview_container_id = target_container_id
	if target_container_id == 0:
		return
	_apply_drop_preview(target_container_id, drag_state.get("target_location", {}) as Dictionary,
			drag_state.get("target_state", &"dragging"), span, int(drag_state.get("inventory_id", 0)))


## DESIGN.md §11.2's constant snapped cell-occupancy preview: dispatches to
## whichever container control is CURRENTLY hovered (independent of the
## dragged item's own home layout -- a spatial item hovered over a named
## slot for equip still previews as a slot, etc.), passing the
## rotation-aware footprint [param span] so a multi-cell footprint's exact
## occupied cell set is what gets restyled, not just the single cell under
## the pointer.
func _apply_drop_preview(container_id: int, location: Dictionary, state: StringName, span: Vector2i, inventory_id: int) -> void:
	var control := container_control(container_id)
	if control == null:
		return
	if control is InventorySpatialGridControl:
		var origin := Vector2i(int(location.get("x", 0)), int(location.get("y", 0)))
		(control as InventorySpatialGridControl).set_drop_preview(origin, span, state)
	elif control is InventoryNamedSlotsControl:
		(control as InventoryNamedSlotsControl).set_drop_preview(String(location.get("slot_identifier", "")), state)
	elif control is InventoryOrderedListControl:
		var item_id := _list_item_id_at_ordinal(inventory_id, container_id, int(location.get("ordinal", 0)))
		(control as InventoryOrderedListControl).set_drop_preview(item_id, state)


## [InventoryOrderedListControl.set_drop_preview]'s own contract is keyed by
## item id (0 == the trailing append zone), but a list-kind hover location
## only ever carries an ORDINAL (see [InventoryOrderedListControl]'s own
## `location_hover_entered` payload) -- this resolves the two. `0` (not
## found) correctly targets the append zone either way: a genuinely-empty
## ordinal (past the last real row) has no matching item, same as the
## append zone's own reported ordinal (`row_count()`).
func _list_item_id_at_ordinal(inventory_id: int, container_id: int, ordinal: int) -> int:
	if model == null or not model.has_snapshot(inventory_id):
		return 0
	for item_variant in model.get_snapshot(inventory_id).get_items():
		var item: Dictionary = item_variant
		var loc: Dictionary = item.get("location", {})
		if int(loc.get("container", -1)) != container_id:
			continue
		if String(loc.get("kind", "")) != "list":
			continue
		if int(loc.get("ordinal", -1)) == ordinal:
			return int(item.get("id", 0))
	return 0


func _clear_preview_on(container_id: int) -> void:
	var control := container_control(container_id)
	if control != null and control.has_method(&"clear_drop_preview"):
		control.call(&"clear_drop_preview")


func _clear_active_preview() -> void:
	if _preview_container_id != 0:
		_clear_preview_on(_preview_container_id)
	_preview_container_id = 0


func _unhandled_input(event: InputEvent) -> void:
	if interaction_controller == null:
		return
	if interaction_controller.handle_input_event(event):
		get_viewport().set_input_as_handled()
