class_name InventoryInteractionController
extends RefCounted

## Generic drag/drop, rotate/split/merge/swap/quick-transfer/auto-place/
## inspect/context-action, and keyboard/gamepad traversal controller (tasks.md
## 8.5, 8.6). Scene-free and authority-free, exactly like
## [InventoryPresentationModel] (this class's own file header mirrors that
## one's rationale): it holds a reference to [member model] and a duck-typed
## [member command_sink] (the same method surface as [code]InventoryAuthority[/code]
## -- `move_item`/`fits`/... -- so a networked client can substitute its own
## `submit_command_bytes` transport object without this class caring), and
## NEVER mutates canonical state directly. Every path that changes canonical
## state ends in exactly one [method InventoryPresentationModel.begin_intent]
## call followed by exactly one duck-typed command-sink method call followed
## by exactly one [method InventoryPresentationModel.apply_result] call (see
## [method _submit] -- every mutating entry point in this file funnels through
## it). A host [Control] (typically [InventoryTwoPaneView]) wires pointer
## press/hover/release signals from rendered container controls into this
## class's public methods and forwards raw [InputEvent]s to [method
## handle_input_event] -- this class does no pixel hit-testing and holds no
## [Control] reference of its own.
##
## -- Drag/drop validity (tasks.md 8.5) ---------------------------------------
## Hovering a candidate location queries validity via the command sink's
## side-effect-free `fits()` (layout/rotation/bounds/overlap/filter/count/
## nesting -- never mutating), `container_mass()`/`container_mass_capacity()`
## (mass-capacity preview, since `fits()` itself does not check mass -- see
## [method _would_exceed_mass_capacity]'s doc comment), plus cheap LOCAL
## checks against [member model] (is the container host-flagged read-only/
## inaccessible, is the target cell/slot already occupied). The result
## resolves to one of [InventoryDragGhost]'s `DROP_*` tokens, which the host
## then reflects on the ghost AND the target cell/slot/card via each
## container control's own `set_drop_preview`.
##
## -- Keyboard/gamepad traversal (tasks.md 8.6) -------------------------------
## Deterministic, snapshot-driven, NEVER dependent on scene-child order:
## - Spatial grid: directional adjacency from each item's ORIGIN cell only
##   (not full-footprint edge distance -- see [method _grid_directional_candidate]),
##   tie-broken by smallest x then smallest y.
## - Named slots / ordered list: declared-order / ordinal-order stepping that
##   WRAPS within the container.
## - Container-to-container: when a spatial/list direction search would leave
##   the current container with no in-container candidate, focus falls through
##   to the adjacent container in canonical order (pane-local ascending
##   container id, then across panes, leading pane before trailing) --
##   `down`/`right` moves forward, `up`/`left` moves backward. A dedicated
##   next/previous-container action (Tab/Shift+Tab by default) also jumps
##   directly, independent of directional input.
## - Focus memory: [method InventoryPresentationModel.remember_focus]/[method
##   InventoryPresentationModel.recall_focus] is consulted whenever focus
##   ENTERS a container (cross-container jump, or the initial focus-nothing
##   case); the remembered item is used only if it still resolves in that
##   SAME container and is not redacted (DESIGN.md §11.3's "verify the target
##   remains visible, enabled, allowed, and valid").
##
## Scope notes (documented, not hidden): normal (non-move-mode) traversal only
## ever lands on OCCUPIED targets (an item, or an occupied named slot) -- an
## empty destination is only ever reached as a MOVE-MODE placement preview
## once an item is picked up via [method activate]. Keyboard/gamepad
## move-mode candidate stepping stays WITHIN the item's current container in
## this wave; cross-container keyboard-driven moves go through quick-transfer
## (`inventory_quick_transfer`) or the auto-place context action instead.

# =============================================================================
# Signals
# =============================================================================

## Fires once per pointer/keyboard drag or move-mode start.
signal drag_started(inventory_id: int, item_id: int, footprint: Vector2i, rotated: bool)
## Fires whenever the current candidate target's validity state changes
## (including to [constant InventoryDragGhost.DROP_NONE] when hover leaves
## every candidate). Also used for move-mode candidate updates -- see
## [signal move_mode_updated].
signal drag_target_updated(state: StringName, container_id: int, location: Dictionary)
signal drag_ended
signal move_mode_started(inventory_id: int, item_id: int)
signal move_mode_updated(state: StringName, container_id: int, location: Dictionary)
signal move_mode_ended
## Fires once a drag/context-action split resolves a destination and needs a
## quantity from the host's quantity-picker UI (e.g. [InventoryQuantitySpinner]).
signal split_quantity_requested(inventory_id: int, item_id: int, min_value: int, max_value: int, default_value: int)
## Edge-triggered companion to [signal split_quantity_requested]: fires once a
## pending split RESOLVES, no matter which path resolved it (quantity-picker
## confirm/cancel button, [method cancel] via Esc, or a [member
## split_quantity_provider]'s own eventual [method confirm_split]/[method
## cancel_split] call) -- this is what lets a host tear down whatever UI it
## raised for [signal split_quantity_requested] regardless of resolution path
## (docs/inventory/visual-qa-2026-07-27.md finding 8's flow-sheet step 8: Esc
## cancelled the split on this controller, but the host's spinner popup only
## ever hid itself from its OWN Cancel-button signal, so it stayed visibly
## stuck onscreen). Emitted by [method confirm_split] whenever a split was
## actually pending, and by [method cancel_split] ONLY when [member
## _pending_split] was non-empty (a no-op [method cancel_split] call, e.g. a
## stray Esc with nothing pending, must never fire this). Never emitted by
## [method split_quantity_provider]'s own call path directly -- the provider
## calls [method confirm_split]/[method cancel_split] itself, which is where
## this always fires from.
signal split_quantity_closed
## Fires after EVERY command this class submits, win or lose -- a recording
## duck-typed sink is not required to observe submissions; tests may also
## just connect this signal. [param result] is the exact command-result
## Dictionary [member command_sink]'s method returned.
signal command_submitted(kind: StringName, args: Dictionary, result: Dictionary)
## [param anchor_global_position] is the exact pointer anchor for a secondary
## click, or [constant Vector2.INF] for keyboard/gamepad/touch callers that
## expect the host to resolve an on-screen fallback.
signal context_actions_requested(inventory_id: int, item_id: int, actions: Array, anchor_global_position: Vector2)
## Explicit context-menu merge targeting. Candidate ids are always sorted by
## canonical item identity; no scene-child order participates.
signal merge_mode_started(inventory_id: int, source_item_id: int, candidate_item_ids: Array)
signal merge_mode_updated(inventory_id: int, source_item_id: int, target_item_id: int, candidate_item_ids: Array)
signal merge_mode_ended
## Game-policy Drop handoff. The controller never invents an external owner;
## a resolver approves one through [method resolve_drop].
signal drop_policy_requested(request: Dictionary)
signal drop_policy_closed
signal inspect_requested(inventory_id: int, item_id: int, item_info: Dictionary)
## Fires when [method open_item]/[method open_selected] resolves and opens a
## real provided container (tasks.md 8.5's double-click/context-menu/
## keyboard-parity "open" affordance for a container-providing item, e.g. a
## backpack) -- [method InventoryPresentationModel.open_container] has ALREADY
## been called by the time this fires, so the container is guaranteed
## rendered on the very next [signal InventoryPresentationModel.model_changed]
## the host already reacts to; the host reacts to THIS signal by focusing/
## scrolling/highlighting that now-rendered section (this scene-free class
## has no [Control] of its own to do that itself).
signal container_opened(container_id: int)

# =============================================================================
# Input action names (tasks.md 8.6: "Godot input actions with default
# bindings registered by the view, overridable by the host"). Movement/
# activate/cancel reuse Godot's own built-in `ui_up`/`ui_down`/`ui_left`/
# `ui_right`/`ui_accept`/`ui_cancel` (already have sensible default bindings
# across keyboard/gamepad); only actions with no Godot built-in equivalent are
# registered here.
# =============================================================================

const ACTION_ROTATE: StringName = &"inventory_rotate"
## Held (not pressed-once) during a drag-press to request a SPLIT drag
## instead of a move drag -- the "modifier-drag" path (tasks.md 8.5).
const ACTION_SPLIT_MODIFIER: StringName = &"inventory_split_modifier"
const ACTION_QUICK_TRANSFER: StringName = &"inventory_quick_transfer"
const ACTION_AUTO_PLACE: StringName = &"inventory_auto_place"
const ACTION_INSPECT: StringName = &"inventory_inspect"
const ACTION_CONTEXT_MENU: StringName = &"inventory_context_menu"
const ACTION_NEXT_CONTAINER: StringName = &"inventory_next_container"
const ACTION_PREVIOUS_CONTAINER: StringName = &"inventory_previous_container"

const SIDE_LEFT: StringName = &"left"
const SIDE_RIGHT: StringName = &"right"

# Diagnostic id -> InventoryDragGhost.DROP_* (native/core/inv_status.h;
# mirrors InventoryPresentationModel's own _DIAGNOSTIC_REASON_TOKENS citation
# style, but resolved to a DROP-preview token instead of a rejection reason
# token -- these are two distinct vocabularies for two distinct moments, see
# InventoryDragGhost's header comment).
const _DIAGNOSTIC_DROP_STATES := {
	118: &"drop-filtered", # DiagnosticId::FILTER_TRAIT_MISMATCH
	123: &"drop-overweight", # DiagnosticId::MASS_CAPACITY_EXCEEDED
	122: &"drop-inaccessible", # DiagnosticId::ACCESS_DENIED
}

# =============================================================================
# Configuration
# =============================================================================

var model: InventoryPresentationModel
## Duck-typed: `InventoryAuthority`, `InventoryReplicaNode` (queries only --
## a replica has no mutation method, so every mutating path will simply find
## `has_method()` false and no-op), or a game's own networked-submission
## object exposing the same method names.
var command_sink: Object
## Kept for a host's convenience (e.g. footprint-px ghost sizing); this class
## does no geometry/pixel math itself.
var tokens: InventoryDesignTokens
@export var actor_id: int = 1
## String item_definition_identifier -> Vector2i(width, height), pre-rotation
## -- same catalog-side data [InventorySpatialGridControl] needs, supplied
## once here so `fits()` probes and ghost footprint sizing use the real
## per-item footprint instead of assuming 1x1.
var footprint_lookup: Dictionary = {}
## String item_definition_identifier -> bool allow_rotation -- catalog-side
## eligibility paired with [member footprint_lookup]. Missing entries remain
## optimistic (`true`) for backward compatibility with hosts that predate this
## lookup; an explicit `false` prevents the gesture layer from turning a ghost
## that authority can only reject with ITEM_FOOTPRINT_INVALID.
var rotation_lookup: Dictionary = {}
## String item_definition_identifier -> int unit_mass_mg -- catalog-side data
## (same as [InventoryItemCard.set_display_mass_mg]'s host-supplied value)
## needed ONLY for the drop-overweight preview check (see [method
## _would_exceed_mass_capacity]'s doc comment for why `fits()` cannot answer
## this on its own).
var mass_lookup: Dictionary = {}
## String item_definition_identifier -> int max_stack. This catalog-side
## lookup lets Merge… highlight only targets that can accept the complete
## source stack. Missing entries remain optimistic for backward-compatible
## hosts; authority still revalidates the chosen target.
var max_stack_lookup: Dictionary = {}
## Optional override for [signal split_quantity_requested]:
## [code]Callable(inventory_id: int, item_id: int, min_value: int,
## max_value: int, default_value: int) -> void[/code]. When valid, [method
## _begin_split_quantity] calls this INSTEAD OF emitting the signal -- the
## provider becomes responsible for eventually calling [method confirm_split]/
## [method cancel_split] itself, exactly like the signal's own default
## inline-spinner consumer (e.g. [InventoryTwoPaneView]'s built-in
## [InventoryQuantitySpinner] popup) would. Left invalid (the default), this
## class's behavior is byte-for-byte unchanged: the signal fires and whatever
## host already listens to it keeps working exactly as before -- this seam
## exists so a CommonUI-hosted screen can supersede the inline spinner with
## its own serialized modal ([InventoryCommonUiSplitDialog]) without this
## scene-free class needing to know CommonUI exists.
var split_quantity_provider: Callable = Callable()
## Optional game-owned policy seam:
## [code]Callable(request: Dictionary) -> int|Dictionary[/code]. A nonzero
## integer approves immediately. A Dictionary may return
## `{approved=true, external_owner=N}` or `{pending=true}`; pending requests
## are later resolved through [method resolve_drop]/[method cancel_drop].
## When invalid, Drop is intentionally absent from [method available_actions].
var drop_policy_resolver: Callable = Callable()

# container_id -> {side, inventory_id, layout, grid_width, grid_height,
# slot_identifiers, max_entries} -- see [method set_containers].
var _containers: Dictionary = {}
var _pane_container_order: Dictionary = {} # StringName side -> Array[int], ascending.
var _pane_inventory: Dictionary = {} # StringName side -> int

var _drag: Dictionary = {}
## {} or {inventory_id, item_id, kind, press_position: Vector2} -- an ARMED
## pointer press that has not yet moved past [method update_pointer_position]'s
## threshold (tasks.md 8.5's press-hold-drag rework: a bare press/release with
## no intervening movement is a plain click/select, never a drag). Distinct
## from [member _drag] itself, which only ever holds a CONFIRMED, actually
## visible drag -- [method is_dragging] stays false the whole time a press is
## merely armed.
var _pointer_arm: Dictionary = {}
var _move_mode: Dictionary = {}
var _merge_mode: Dictionary = {}
var _pending_split: Dictionary = {}
var _pending_drop: Dictionary = {}
var _touch_hold_candidate: Dictionary = {}


func configure(p_model: InventoryPresentationModel, p_command_sink: Object, p_tokens: InventoryDesignTokens = null, p_actor_id: int = 1) -> void:
	model = p_model
	command_sink = p_command_sink
	tokens = p_tokens
	actor_id = p_actor_id


## [param containers]: [code]Array[Dictionary{container_id: int, layout:
## StringName ("spatial"|"named_slots"|"ordered_list"), grid_width: int,
## grid_height: int, slot_identifiers: Array[String], max_entries: int}][/code]
## -- exactly what [InventoryTwoPaneView] already resolves via its own
## `container_info_resolver` to configure the rendered container controls;
## this call just also hands a slimmed view of that resolution here so this
## class never needs a [Control]/catalog reference of its own.
func set_containers(side: StringName, inventory_id: int, containers: Array) -> void:
	for cid in _pane_container_order.get(side, []):
		_containers.erase(cid)
	var ids: Array[int] = []
	for entry_variant in containers:
		var entry: Dictionary = entry_variant
		var cid := int(entry.get("container_id", 0))
		if cid == 0:
			continue
		ids.append(cid)
		_containers[cid] = {
			"side": side, "inventory_id": inventory_id,
			"layout": StringName(entry.get("layout", &"spatial")),
			"grid_width": int(entry.get("grid_width", 0)),
			"grid_height": int(entry.get("grid_height", 0)),
			"slot_identifiers": (entry.get("slot_identifiers", []) as Array).duplicate(),
			"max_entries": int(entry.get("max_entries", 0)),
		}
	ids.sort()
	_pane_container_order[side] = ids
	_pane_inventory[side] = inventory_id


func set_footprint_lookup(lookup: Dictionary) -> void:
	footprint_lookup = lookup.duplicate(true)


func set_rotation_lookup(lookup: Dictionary) -> void:
	rotation_lookup = lookup.duplicate(true)


func set_mass_lookup(lookup: Dictionary) -> void:
	mass_lookup = lookup.duplicate(true)


func set_max_stack_lookup(lookup: Dictionary) -> void:
	max_stack_lookup = lookup.duplicate(true)


func container_id_for_item(inventory_id: int, item_id: int) -> int:
	var item := _find_item(inventory_id, item_id)
	if item.is_empty():
		return 0
	return int((item.get("location", {}) as Dictionary).get("container", -1))


# =============================================================================
# Selection / focus memory
# =============================================================================

## Called by a host when a raw pointer click already invoked [method
## InventoryPresentationModel.select] itself (e.g. a container control's own
## `intent_requested(&select, ...)`) -- records focus memory for the
## container without re-emitting a redundant selection change.
func note_selection(inventory_id: int, item_id: int) -> void:
	var item := _find_item(inventory_id, item_id)
	if item.is_empty():
		return
	var container_id := int((item.get("location", {}) as Dictionary).get("container", -1))
	if container_id > 0:
		model.remember_focus(container_id, str(item_id))


func _select(inventory_id: int, item_id: int) -> void:
	model.select(inventory_id, item_id)
	note_selection(inventory_id, item_id)


# =============================================================================
# Drag lifecycle (tasks.md 8.5)
# =============================================================================

func is_dragging() -> bool:
	return not _drag.is_empty()


func begin_drag(inventory_id: int, item_id: int) -> bool:
	return _begin_drag_internal(inventory_id, item_id, &"move")


## Modifier-drag entry point (tasks.md 8.5: "split (modifier-drag or context
## action)"); a host calls this instead of [method begin_drag] when its own
## split-modifier check ([constant ACTION_SPLIT_MODIFIER]) is held at
## drag-press time.
func begin_split_drag(inventory_id: int, item_id: int) -> bool:
	return _begin_drag_internal(inventory_id, item_id, &"split")


## Immediate counterpart to the press-time Alt/Option arm path. Kept
## separate from the legacy [method begin_split_drag] API, whose callers
## expect the arbitrary-quantity picker after choosing a destination.
func begin_half_split_drag(inventory_id: int, item_id: int) -> bool:
	return _begin_drag_internal(inventory_id, item_id, &"split_half")


## Context-action entry point for split -- both this and [method
## begin_split_drag] terminate in the SAME drag/drop state machine; only the
## entry trigger differs (a context-menu press instead of a pointer
## press-and-hold).
func begin_split_from_context(inventory_id: int, item_id: int) -> bool:
	return _begin_drag_internal(inventory_id, item_id, &"split")


## Point-in-time snapshot of the active drag -- {} if [method is_dragging] is
## false. Lets a host derive its own per-frame visuals (ghost resize on
## mid-drag rotate, the DESIGN.md §11.2 constant snapped cell-occupancy
## preview) purely by POLLING this every frame it already polls the pointer
## position for, rather than this scene-free class threading every one of a
## host's rendering concerns through bespoke signal payloads.
func get_drag_state() -> Dictionary:
	return _drag.duplicate(true)


## Pointer press-and-hold ARMING (tasks.md 8.5's press-hold-drag rework): a
## press on an eligible item only ARMS a potential drag -- it does NOT start
## one (contrast [method begin_drag], which still starts a real drag
## immediately, unchanged, for every OTHER caller: keyboard/gamepad flows,
## context-action split, and this suite's own direct tests). The host calls
## this from its pointer-press handler instead of [method begin_drag]/[method
## begin_split_drag], remembers nothing else itself, and drives the rest via
## [method update_pointer_position]/[method release_pointer_arm]. Eligibility
## is checked NOW (same rules as [method _begin_drag_internal]) so an
## ineligible press (read-only/redacted item, or a quantity-1 item under
## [param split]) never arms at all -- it still resolves as a plain
## click/select once released, exactly like today.
func arm_pointer_drag(inventory_id: int, item_id: int, press_position: Vector2, split: bool = false) -> bool:
	if model == null or is_dragging() or is_move_mode_active() or is_merge_mode_active():
		return false
	var item := _find_item(inventory_id, item_id)
	if item.is_empty():
		return false
	if model.is_item_read_only(item_id) or model.item_state(inventory_id, item_id) == InventoryPresentationModel.STATE_REDACTED:
		return false
	if split and int(item.get("quantity", 1)) <= 1:
		return false
	_pointer_arm = {
		"inventory_id": inventory_id, "item_id": item_id,
		"kind": (&"split_half" if split else &"move"),
		"press_position": press_position,
	}
	return true


func is_drag_armed() -> bool:
	return not _pointer_arm.is_empty()


## Host calls this every pointer-motion sample while [method is_drag_armed]
## (a no-op otherwise, including once ALREADY dragging -- promotion happens
## exactly once). Promotes the armed press into a real drag -- the exact same
## state [method begin_drag] would have entered, [signal drag_started] and
## all -- the first time [param position] has moved [param threshold_px] or
## more from the original press position. Returns true the one time that
## promotion happens (most hosts don't need the return value; tests find it
## convenient to assert on).
func update_pointer_position(position: Vector2, threshold_px: float = 4.0) -> bool:
	if _pointer_arm.is_empty():
		return false
	var press_position: Vector2 = _pointer_arm.get("press_position", position)
	if position.distance_to(press_position) < threshold_px:
		return false
	var inv_id := int(_pointer_arm["inventory_id"])
	var item_id := int(_pointer_arm["item_id"])
	var kind: StringName = _pointer_arm["kind"]
	_pointer_arm = {}
	return _begin_drag_internal(inv_id, item_id, kind)


## Host calls this on pointer release whenever [method update_pointer_position]
## never promoted the arm into a real drag -- i.e., a plain press-then-release
## with no intervening movement past the threshold, tasks.md 8.5's "single
## click still selects" requirement. A no-op if nothing is armed.
func release_pointer_arm() -> void:
	_pointer_arm = {}


func _begin_drag_internal(inventory_id: int, item_id: int, kind: StringName) -> bool:
	if model == null or is_dragging() or is_move_mode_active() or is_merge_mode_active():
		return false
	var item := _find_item(inventory_id, item_id)
	if item.is_empty():
		return false
	if model.is_item_read_only(item_id) or model.item_state(inventory_id, item_id) == InventoryPresentationModel.STATE_REDACTED:
		return false
	if (kind == &"split" or kind == &"split_half") and int(item.get("quantity", 1)) <= 1:
		return false
	var source_quantity := int(item.get("quantity", 1))
	var staged_quantity := int(source_quantity / 2) if kind == &"split_half" else source_quantity
	var location: Dictionary = item.get("location", {})
	_drag = {
		"inventory_id": inventory_id, "item_id": item_id,
		"container_id": int(location.get("container", -1)),
		"kind": kind,
		"quantity": staged_quantity,
		"rotated": bool(location.get("rotated", false)),
		"target_container_id": 0, "hover_location": {}, "target_location": {},
		"target_state": &"dragging", "occupant_item_id": 0,
		"provider_item_id": 0,
	}
	var identifier := String(item.get("item_definition_identifier", ""))
	var footprint: Vector2i = footprint_lookup.get(identifier, Vector2i(1, 1))
	drag_started.emit(inventory_id, item_id, footprint, bool(_drag["rotated"]))
	return true


## Toggles the DRAGGED item's rotation for validity re-checking against the
## current hover target -- nothing is submitted; the item's real location is
## untouched until [method end_drag]/[method confirm_split] (tasks.md 8.5:
## "R while dragging ... flip the ghost's local rotated flag").
func _rotate_drag() -> bool:
	if not _item_allows_rotation(int(_drag["inventory_id"]), int(_drag["item_id"])):
		return false
	_drag["rotated"] = not bool(_drag["rotated"])
	if int(_drag.get("target_container_id", 0)) != 0:
		# Revalidate from the RAW hovered cell. `target_location` is the
		# effective placement and already carries the previous orientation;
		# feeding it back here used to leave downstream consumers observing
		# that stale orientation even though `_compute_drop_state()` received
		# the newly-flipped flag separately.
		var hover_location := (_drag.get("hover_location", _drag.get("target_location", {})) as Dictionary).duplicate(true)
		update_drag_target(int(_drag["target_container_id"]), hover_location)
	return true


func update_drag_target(container_id: int, location: Dictionary) -> void:
	if not is_dragging():
		return
	var hover_location := location.duplicate(true)
	var target_location := _effective_drag_location(hover_location, bool(_drag["rotated"]))
	var result := _compute_drop_state(
			int(_drag["inventory_id"]), int(_drag["item_id"]), container_id,
			target_location, bool(_drag["rotated"]), int(_drag.get("quantity", 0)),
			_drag.get("kind", &"move") == &"split_half")
	_drag["target_container_id"] = container_id
	_drag["hover_location"] = hover_location
	_drag["target_location"] = target_location
	_drag["target_state"] = result["state"]
	_drag["occupant_item_id"] = int(result.get("occupant_item_id", 0))
	_drag["provider_item_id"] = int(result.get("provider_item_id", 0))
	drag_target_updated.emit(result["state"], container_id, target_location)


## Only clears if [param container_id]/[param location] name the CURRENT
## target -- a fast pointer can generate exit-then-enter for a different
## location out of order; ignoring a stale exit avoids a one-frame
## "no candidate" flicker.
func clear_drag_target(container_id: int, location: Dictionary) -> void:
	if not is_dragging():
		return
	if int(_drag.get("target_container_id", 0)) != container_id:
		return
	if (_drag.get("hover_location", _drag.get("target_location", {})) as Dictionary) != location:
		return
	_drag["target_container_id"] = 0
	_drag["hover_location"] = {}
	_drag["target_location"] = {}
	_drag["target_state"] = &"dragging"
	_drag["occupant_item_id"] = 0
	_drag["provider_item_id"] = 0
	drag_target_updated.emit(&"dragging", container_id, location)


## Converts a control's raw hover location into the canonical placement
## represented by the CURRENT drag state. Spatial controls deliberately emit
## `rotated: false` for empty cells because they cannot know what is being
## dragged; keeping that raw value as `target_location` made the drag snapshot
## and [signal drag_target_updated] disagree with the orientation actually
## passed to `fits()`.
func _effective_drag_location(location: Dictionary, rotated: bool) -> Dictionary:
	var effective := location.duplicate(true)
	if String(effective.get("kind", "")) == "spatial":
		effective["rotated"] = rotated
	return effective


## Release over [param container_id]/[param location]. Recomputes validity
## fresh at release time (never trusting a possibly-stale last hover) --
## rejects LOCALLY (no command submitted, "cancel path restores nothing
## because nothing mutated") unless the fresh check resolves valid/occupied.
## Returns the submitted command's result Dictionary, `{"awaiting_quantity":
## true}` for a split awaiting [method confirm_split], or `{}` when nothing
## was submitted.
func end_drag(container_id: int, location: Dictionary) -> Dictionary:
	if not is_dragging():
		return {}
	var drag_copy: Dictionary = _drag.duplicate(true)
	_drag = {}
	drag_ended.emit()

	var target_location := _effective_drag_location(location, bool(drag_copy["rotated"]))
	var result := _compute_drop_state(
			int(drag_copy["inventory_id"]), int(drag_copy["item_id"]), container_id,
			target_location, bool(drag_copy["rotated"]), int(drag_copy.get("quantity", 0)),
			drag_copy.get("kind", &"move") == &"split_half")
	var state: StringName = result["state"]
	if state != &"drop-valid" and state != &"drop-occupied":
		return {}

	if drag_copy["kind"] == &"split_half":
		var inventory_id := int(drag_copy["inventory_id"])
		var item_id := int(drag_copy["item_id"])
		var staged_quantity := int(drag_copy.get("quantity", 0))
		if state != &"drop-valid" or staged_quantity <= 0:
			return {}
		return _submit(inventory_id, &"split", [item_id],
				func(cmd_id: int) -> Dictionary:
					return command_sink.call(&"split_stack", inventory_id, item_id, staged_quantity, target_location, actor_id, cmd_id))

	if drag_copy["kind"] == &"split":
		return _begin_split_quantity(drag_copy, container_id, target_location)

	return _resolve_and_submit_drop(int(drag_copy["inventory_id"]), int(drag_copy["item_id"]), container_id, target_location,
			bool(drag_copy["rotated"]), int(result.get("occupant_item_id", 0)),
			int(result.get("provider_item_id", 0)))


func cancel_drag() -> void:
	if not is_dragging():
		return
	_drag = {}
	drag_ended.emit()


func _begin_split_quantity(drag_copy: Dictionary, container_id: int, location: Dictionary) -> Dictionary:
	var inventory_id := int(drag_copy["inventory_id"])
	var item_id := int(drag_copy["item_id"])
	var item := _find_item(inventory_id, item_id)
	var quantity := int(item.get("quantity", 1))
	_pending_split = {
		"inventory_id": inventory_id, "item_id": item_id,
		"dest_container_id": container_id, "dest_location": location.duplicate(true),
	}
	var default_value := maxi(1, int(quantity / 2))
	var max_value := maxi(quantity - 1, 1)
	if split_quantity_provider.is_valid():
		split_quantity_provider.call(inventory_id, item_id, 1, max_value, default_value)
	else:
		split_quantity_requested.emit(inventory_id, item_id, 1, max_value, default_value)
	return {"awaiting_quantity": true}


func confirm_split(quantity: int) -> Dictionary:
	if _pending_split.is_empty():
		return {}
	var state: Dictionary = _pending_split
	_pending_split = {}
	split_quantity_closed.emit()
	var inv_id := int(state["inventory_id"])
	var item_id := int(state["item_id"])
	var dest_location: Dictionary = state["dest_location"]
	return _submit(inv_id, &"split", [item_id],
			func(cmd_id: int) -> Dictionary: return command_sink.call(&"split_stack", inv_id, item_id, quantity, dest_location, actor_id, cmd_id))


## Edge-triggered (see [signal split_quantity_closed]'s doc comment): a no-op
## call with nothing pending must NOT fire the signal, so a host that always
## calls [method cancel]/[method cancel_split] defensively (e.g. on every Esc,
## whether or not a split happens to be pending) never gets a spurious
## teardown signal for UI it never raised.
func cancel_split() -> void:
	if _pending_split.is_empty():
		return
	_pending_split = {}
	split_quantity_closed.emit()


func has_pending_split() -> bool:
	return not _pending_split.is_empty()


## The current pending split's destination location, or an empty Dictionary
## if none is pending -- lets a [member split_quantity_provider] (e.g. a
## CommonUI modal standing in for the inline spinner) resolve the split-off
## stack to the SAME destination the originating drag/context-action already
## chose, without reaching into this class's private [member _pending_split]
## state.
func pending_split_destination() -> Dictionary:
	return (_pending_split.get("dest_location", {}) as Dictionary).duplicate(true)


# =============================================================================
# Direct (non-drag) actions
# =============================================================================

## R: while dragging/in move-mode, flips the LOCAL preview rotation (no
## command); otherwise rotates the currently selected item in place. The
## discrete path probes the flipped placement with the authority's
## side-effect-free `fits()` query first: an item that cannot turn at its
## current cell is a silent no-op, not a rejected command/rejection shake.
func rotate_selected() -> bool:
	if is_dragging():
		return _rotate_drag()
	if is_move_mode_active():
		if not _item_allows_rotation(int(_move_mode["inventory_id"]), int(_move_mode["item_id"])):
			return false
		_move_mode["rotated"] = not bool(_move_mode["rotated"])
		_revalidate_move_mode_target()
		return true
	if model == null:
		return false
	var sel := model.get_selection()
	if sel.is_empty():
		return false
	var inv_id := int(sel.get("inventory_id", 0))
	var item_id := int(sel.get("item_id", 0))
	var item := _find_item(inv_id, item_id)
	if item.is_empty() or model.is_item_read_only(item_id):
		return false
	if not _item_allows_rotation(inv_id, item_id):
		return false
	var location: Dictionary = item.get("location", {})
	if String(location.get("kind", "")) != "spatial":
		return false
	var new_rotated := not bool(location.get("rotated", false))
	if not _rotation_fits_current_location(inv_id, item_id, item, location, new_rotated):
		return false
	_submit(inv_id, &"rotate", [item_id],
			func(cmd_id: int) -> Dictionary: return command_sink.call(&"rotate_item", inv_id, item_id, new_rotated, actor_id, cmd_id))
	return true


## Side-effect-free discrete-rotate preflight. A network submission sink may
## intentionally expose mutations without local derived queries; preserve the
## historical authority-final behavior for such sinks by treating a missing
## `fits()` method as unknown/allowed. Every local-authority host (including
## InventoryCommonUiScreen) exposes `fits()`, so ordinary bounds/overlap/
## container-policy failures stop here without creating an intent or
## rejection-feedback animation.
func _rotation_fits_current_location(inventory_id: int, item_id: int,
		item: Dictionary, location: Dictionary, rotated: bool) -> bool:
	if command_sink == null or not command_sink.has_method(&"fits"):
		return true
	var probe := location.duplicate(true)
	probe["rotated"] = rotated
	var identifier := String(item.get("item_definition_identifier", ""))
	var quantity := int(item.get("quantity", 1))
	var result: Dictionary = command_sink.call(
			&"fits", inventory_id, identifier, probe, quantity, item_id)
	return bool(result.get("ok", false))


func _item_allows_rotation(inventory_id: int, item_id: int) -> bool:
	var item := _find_item(inventory_id, item_id)
	if item.is_empty():
		return false
	var identifier := String(item.get("item_definition_identifier", ""))
	return bool(rotation_lookup.get(identifier, true))


func quick_transfer_selected() -> bool:
	if model == null:
		return false
	var sel := model.get_selection()
	if sel.is_empty():
		return false
	var inv_id := int(sel.get("inventory_id", 0))
	var item_id := int(sel.get("item_id", 0))
	if model.is_item_read_only(item_id):
		return false
	var other_side := _other_side_for_inventory(inv_id)
	if other_side.is_empty():
		return false
	var dest_inventory_id := int(_pane_inventory.get(other_side, 0))
	_submit(inv_id, &"quick_transfer", [item_id],
			func(cmd_id: int) -> Dictionary: return command_sink.call(&"quick_transfer_item", inv_id, dest_inventory_id, item_id, false, actor_id, cmd_id))
	return true


func auto_place_selected() -> bool:
	if model == null:
		return false
	var sel := model.get_selection()
	if sel.is_empty():
		return false
	var inv_id := int(sel.get("inventory_id", 0))
	var item_id := int(sel.get("item_id", 0))
	if model.is_item_read_only(item_id):
		return false
	_submit(inv_id, &"auto_place", [item_id],
			func(cmd_id: int) -> Dictionary: return command_sink.call(&"auto_place_item", inv_id, item_id, 0, actor_id, cmd_id))
	return true


## Returns the inspected item's snapshot Dictionary plus its resolved
## `"state"` -- never submits anything (inspect never touches canonical
## state); also fires [signal inspect_requested] so a host can pin a tooltip.
func inspect_selected() -> Dictionary:
	if model == null:
		return {}
	var sel := model.get_selection()
	if sel.is_empty():
		return {}
	var inv_id := int(sel.get("inventory_id", 0))
	var item_id := int(sel.get("item_id", 0))
	var item := _find_item(inv_id, item_id)
	if item.is_empty():
		return {}
	var result := item.duplicate(true)
	result["state"] = model.item_state(inv_id, item_id)
	inspect_requested.emit(inv_id, item_id, result)
	return result


## Resolves [param item_id]'s "open" action target (tasks.md 8.5's pointer
## double-click-to-open affordance / DESIGN.md §11.3 non-pointer parity): the
## smallest-id (this addon's canonical-ordering convention) of [param
## item_id]'s own `provided_containers` (see [InventorySnapshotResource.get_items]'s
## per-item shape) that CURRENTLY resolves as a real container in [param
## inventory_id]'s snapshot -- `0` if the item provides none, or (defensively;
## verified against native/core/inv_runtime_state.cpp's `create_item`, which
## materializes every provided container unconditionally and only ever
## alongside its provider item, regardless of where that item is placed/
## equipped) none of its provided ids still resolve there.
func resolve_open_container(inventory_id: int, item_id: int) -> int:
	var item := _find_item(inventory_id, item_id)
	if item.is_empty():
		return 0
	var provided: Array = item.get("provided_containers", [])
	if provided.is_empty():
		return 0
	var candidate_ids: Array[int] = []
	for provided_id in provided:
		candidate_ids.append(int(provided_id))
	candidate_ids.sort()
	var snapshot := model.get_snapshot(inventory_id) if model != null else null
	if snapshot == null:
		return 0
	var known_container_ids: Dictionary = {}
	for container_variant in snapshot.get_containers():
		known_container_ids[int((container_variant as Dictionary).get("id", 0))] = true
	for candidate_id in candidate_ids:
		if known_container_ids.has(candidate_id):
			return candidate_id
	return 0


## Opens [param item_id]'s provided container (see [method
## resolve_open_container]) and fires [signal container_opened] so the host
## can focus/scroll/highlight it. Falls back to [method inspect_selected]'s
## same "never touches canonical state" inspect path -- mirroring [method
## perform_action]'s own `inspect` entry -- when nothing resolves to open
## (this item provides no container, or provides one that no longer
## resolves). Returns the opened container id, or `0` on the inspect
## fallback.
func open_item(inventory_id: int, item_id: int) -> int:
	if model == null:
		return 0
	var container_id := resolve_open_container(inventory_id, item_id)
	if container_id == 0:
		inspect_selected()
		return 0
	model.open_container(container_id)
	container_opened.emit(container_id)
	return container_id


## [method open_item] operating on the CURRENT selection -- the context-menu/
## keyboard-parity entry point (tasks.md 8.5/DESIGN.md §11.3); a pointer
## double-click instead calls [method open_item] directly with the
## double-clicked card's own (inventory_id, item_id), independent of whatever
## is currently selected (though by the time a double-click's SECOND press
## reaches this, the first press has already selected the same item -- see
## [InventoryTwoPaneView]'s wiring).
func open_selected() -> int:
	if model == null:
		return 0
	var sel := model.get_selection()
	if sel.is_empty():
		return 0
	return open_item(int(sel.get("inventory_id", 0)), int(sel.get("item_id", 0)))


## Generic dispatcher for a context-menu press naming one of [method
## available_actions]' `id` tokens, operating on the CURRENT selection.
func perform_action(action_id: StringName) -> bool:
	if action_id != &"cancel":
		if model == null:
			return false
		var current_selection := model.get_selection()
		if current_selection.is_empty():
			return false
		var current_inventory_id := int(current_selection.get("inventory_id", 0))
		var current_item_id := int(current_selection.get("item_id", 0))
		var offered := false
		for action_variant in available_actions(current_inventory_id, current_item_id):
			var action: Dictionary = action_variant
			if StringName(action.get("id", &"")) == action_id \
					and bool(action.get("enabled", false)):
				offered = true
				break
		if not offered:
			return false
	match action_id:
		&"inspect":
			return not inspect_selected().is_empty()
		&"open":
			return open_selected() != 0
		&"rotate":
			return rotate_selected()
		&"split":
			if model == null:
				return false
			var sel := model.get_selection()
			if sel.is_empty():
				return false
			return begin_split_from_context(int(sel.get("inventory_id", 0)), int(sel.get("item_id", 0)))
		&"merge":
			if model == null:
				return false
			var sel := model.get_selection()
			if sel.is_empty():
				return false
			return begin_merge_from_context(int(sel.get("inventory_id", 0)), int(sel.get("item_id", 0)))
		&"drop":
			return request_drop_selected()
		&"quick_transfer":
			return quick_transfer_selected()
		&"auto_place":
			return auto_place_selected()
		&"cancel":
			return cancel()
		_:
			return false


## Client-side AFFORDANCE heuristics only -- authority remains the sole trust
## boundary. Rotation eligibility uses the host-supplied [member
## rotation_lookup]; the controller still has no direct catalog dependency,
## and the side-effect-free preflight in [method rotate_selected] remains the
## final geometry/container-policy check before a discrete rotate is
## submitted.
func available_actions(inventory_id: int, item_id: int) -> Array:
	if model == null:
		return []
	var item := _find_item(inventory_id, item_id)
	if item.is_empty():
		return []
	var state := model.item_state(inventory_id, item_id)
	var actions: Array = []
	if state != InventoryPresentationModel.STATE_REDACTED:
		actions.append({"id": &"inspect", "label": "Inspect", "glyph": &"inspect", "enabled": true})
	# "open" is a pure navigation action (no canonical mutation, same as
	# inspect), so it uses inspect's OWN gate (not-redacted only) rather than
	# the stricter `interactive` gate below (rotate/split/... genuinely need
	# a mutable item) -- a read-only/pending container-providing item (e.g.
	# an in-flight equip) can still be opened to look inside.
	if state != InventoryPresentationModel.STATE_REDACTED and not (item.get("provided_containers", []) as Array).is_empty():
		actions.append({"id": &"open", "label": "Open", "glyph": &"nested_container_expand", "enabled": true})

	var interactive := _item_is_interactive(inventory_id, item_id)
	var location: Dictionary = item.get("location", {})
	if interactive and String(location.get("kind", "")) == "spatial" \
			and _item_allows_rotation(inventory_id, item_id):
		actions.append({"id": &"rotate", "label": "Rotate", "glyph": &"rotate", "enabled": true})
	if interactive and int(item.get("quantity", 1)) > 1:
		actions.append({"id": &"split", "label": "Split…", "glyph": &"split", "enabled": true})
	if interactive and not _compatible_merge_targets(inventory_id, item_id).is_empty():
		actions.append({"id": &"merge", "label": "Merge…", "glyph": &"merge", "enabled": true})
	if interactive and drop_policy_resolver.is_valid() and command_sink != null \
			and command_sink.has_method(&"drop_item"):
		actions.append({"id": &"drop", "label": "Drop", "enabled": true})
	if interactive and not _other_side_for_inventory(inventory_id).is_empty():
		actions.append({"id": &"quick_transfer", "label": "Quick Transfer", "glyph": &"quick_transfer", "enabled": true})
	if interactive:
		actions.append({"id": &"auto_place", "label": "Auto Place", "glyph": &"auto_place", "enabled": true})
	if state == InventoryPresentationModel.STATE_PENDING:
		actions.append({"id": &"cancel", "label": "Cancel", "enabled": true})
	return actions


func _item_is_interactive(inventory_id: int, item_id: int) -> bool:
	if model == null or _find_item(inventory_id, item_id).is_empty() \
			or model.is_item_read_only(item_id):
		return false
	var state := model.item_state(inventory_id, item_id)
	return state != InventoryPresentationModel.STATE_REDACTED \
			and state != InventoryPresentationModel.STATE_PENDING \
			and state != InventoryPresentationModel.STATE_READ_ONLY \
			and state != InventoryPresentationModel.STATE_DISCONNECTED \
			and state != InventoryPresentationModel.STATE_RESYNCHRONIZING


# =============================================================================
# Explicit merge target mode
# =============================================================================

func is_merge_mode_active() -> bool:
	return not _merge_mode.is_empty()


func get_merge_mode_state() -> Dictionary:
	return _merge_mode.duplicate(true)


func begin_merge_from_context(inventory_id: int, item_id: int) -> bool:
	if model == null or is_dragging() or is_move_mode_active() or is_merge_mode_active() \
			or has_pending_split() or has_pending_drop():
		return false
	if not _item_is_interactive(inventory_id, item_id):
		return false
	var candidates := _compatible_merge_targets(inventory_id, item_id)
	if candidates.is_empty():
		return false
	_merge_mode = {
		"inventory_id": inventory_id,
		"source_item_id": item_id,
		"candidate_item_ids": candidates.duplicate(),
		"target_index": 0,
	}
	merge_mode_started.emit(inventory_id, item_id, candidates.duplicate())
	_emit_merge_mode_update()
	return true


func choose_merge_target(inventory_id: int, target_item_id: int) -> bool:
	if not is_merge_mode_active() or inventory_id != int(_merge_mode.get("inventory_id", 0)):
		return false
	var source_item_id := int(_merge_mode.get("source_item_id", 0))
	var candidates := _compatible_merge_targets(inventory_id, source_item_id)
	if target_item_id not in candidates:
		_merge_mode["candidate_item_ids"] = candidates
		if candidates.is_empty():
			_end_merge_mode(true)
		else:
			_merge_mode["target_index"] = clampi(
					int(_merge_mode.get("target_index", 0)), 0, candidates.size() - 1)
			_emit_merge_mode_update()
		return false
	_merge_mode = {}
	merge_mode_ended.emit()
	_submit(inventory_id, &"merge", [source_item_id, target_item_id],
			func(cmd_id: int) -> Dictionary:
				return command_sink.call(&"merge_stacks", inventory_id,
						source_item_id, target_item_id, actor_id, cmd_id))
	return true


func _compatible_merge_targets(inventory_id: int, source_item_id: int) -> Array:
	var source := _find_item(inventory_id, source_item_id)
	if source.is_empty() or model == null \
			or not _item_is_interactive(inventory_id, source_item_id):
		return []
	var definition_id := String(source.get("item_definition_identifier", ""))
	var source_quantity := int(source.get("quantity", 1))
	var max_stack := int(max_stack_lookup.get(definition_id, 0))
	var snapshot := model.get_snapshot(inventory_id)
	if snapshot == null:
		return []
	var candidates: Array = []
	for item_variant in snapshot.get_items():
		var item: Dictionary = item_variant
		var candidate_id := int(item.get("id", 0))
		if candidate_id == source_item_id \
				or String(item.get("item_definition_identifier", "")) != definition_id:
			continue
		if not _item_is_interactive(inventory_id, candidate_id):
			continue
		if max_stack > 0 and source_quantity + int(item.get("quantity", 1)) > max_stack:
			continue
		candidates.append(candidate_id)
	candidates.sort()
	return candidates


## Revalidates a live Merge… target set after snapshot/model changes. The
## current target identity is retained when it still qualifies; otherwise
## traversal resumes at the nearest surviving canonical index. An empty set
## closes the mode and restores the source only if it still exists.
func refresh_merge_mode() -> bool:
	if not is_merge_mode_active():
		return false
	var inventory_id := int(_merge_mode.get("inventory_id", 0))
	var source_item_id := int(_merge_mode.get("source_item_id", 0))
	var old_candidates: Array = _merge_mode.get("candidate_item_ids", [])
	var old_index := clampi(
			int(_merge_mode.get("target_index", 0)),
			0,
			maxi(old_candidates.size() - 1, 0))
	var old_target := int(old_candidates[old_index]) if not old_candidates.is_empty() else 0
	var candidates := _compatible_merge_targets(inventory_id, source_item_id)
	if candidates.is_empty():
		_end_merge_mode(true)
		return false
	_merge_mode["candidate_item_ids"] = candidates
	var retained_index := candidates.find(old_target)
	_merge_mode["target_index"] = retained_index if retained_index >= 0 \
			else clampi(old_index, 0, candidates.size() - 1)
	_emit_merge_mode_update()
	return true


func _step_merge_target(delta: int) -> bool:
	if not is_merge_mode_active():
		return false
	var candidates: Array = _merge_mode.get("candidate_item_ids", [])
	if candidates.is_empty():
		_end_merge_mode(true)
		return false
	var index := wrapi(int(_merge_mode.get("target_index", 0)) + delta, 0, candidates.size())
	_merge_mode["target_index"] = index
	var inventory_id := int(_merge_mode.get("inventory_id", 0))
	_select(inventory_id, int(candidates[index]))
	_emit_merge_mode_update()
	return true


func _emit_merge_mode_update() -> void:
	if not is_merge_mode_active():
		return
	var candidates: Array = _merge_mode.get("candidate_item_ids", [])
	if candidates.is_empty():
		return
	var index := clampi(int(_merge_mode.get("target_index", 0)), 0, candidates.size() - 1)
	merge_mode_updated.emit(
			int(_merge_mode.get("inventory_id", 0)),
			int(_merge_mode.get("source_item_id", 0)),
			int(candidates[index]),
			candidates.duplicate())


func _end_merge_mode(restore_source_selection: bool) -> void:
	if not is_merge_mode_active():
		return
	var state := _merge_mode
	_merge_mode = {}
	merge_mode_ended.emit()
	if restore_source_selection:
		var inventory_id := int(state.get("inventory_id", 0))
		var source_item_id := int(state.get("source_item_id", 0))
		if not _find_item(inventory_id, source_item_id).is_empty():
			_select(inventory_id, source_item_id)


# =============================================================================
# Game-owned Drop policy handoff
# =============================================================================

func has_pending_drop() -> bool:
	return not _pending_drop.is_empty()


func request_drop_selected() -> bool:
	if model == null or command_sink == null \
			or not command_sink.has_method(&"drop_item") \
			or not drop_policy_resolver.is_valid() or has_pending_drop():
		return false
	var selection := model.get_selection()
	if selection.is_empty():
		return false
	var inventory_id := int(selection.get("inventory_id", 0))
	var item_id := int(selection.get("item_id", 0))
	var item := _find_item(inventory_id, item_id)
	if item.is_empty() or not _item_is_interactive(inventory_id, item_id):
		return false
	var snapshot := model.get_snapshot(inventory_id)
	if snapshot == null:
		return false
	_pending_drop = {
		"inventory_id": inventory_id,
		"item_id": item_id,
		"expected_revision": int(snapshot.get_revision()),
		"focus_origin": selection.duplicate(true),
	}
	drop_policy_requested.emit(_pending_drop.duplicate(true))
	var response: Variant = drop_policy_resolver.call(_pending_drop.duplicate(true))
	if typeof(response) == TYPE_INT:
		if int(response) > 0:
			resolve_drop(int(response))
			return true
		cancel_drop()
		return false
	if typeof(response) == TYPE_DICTIONARY:
		var decision: Dictionary = response
		if bool(decision.get("pending", false)):
			return true
		var external_owner := int(decision.get("external_owner", 0))
		if bool(decision.get("approved", external_owner > 0)) and external_owner > 0:
			resolve_drop(external_owner)
			return true
	cancel_drop()
	return false


func resolve_drop(external_owner: int) -> Dictionary:
	if not has_pending_drop():
		return {}
	if external_owner <= 0 or model == null or command_sink == null \
			or not command_sink.has_method(&"drop_item"):
		cancel_drop()
		return {}
	var request := _pending_drop
	_pending_drop = {}
	drop_policy_closed.emit()
	var inventory_id := int(request.get("inventory_id", 0))
	var item_id := int(request.get("item_id", 0))
	var snapshot := model.get_snapshot(inventory_id)
	if snapshot == null or int(snapshot.get_revision()) != int(request.get("expected_revision", -1)) \
			or _find_item(inventory_id, item_id).is_empty():
		_restore_drop_focus(request)
		return {}
	return _submit(inventory_id, &"drop", [item_id],
			func(cmd_id: int) -> Dictionary:
				return command_sink.call(&"drop_item", inventory_id, item_id,
						external_owner, actor_id, cmd_id))


func cancel_drop() -> void:
	if not has_pending_drop():
		return
	var request := _pending_drop
	_pending_drop = {}
	drop_policy_closed.emit()
	_restore_drop_focus(request)


func _restore_drop_focus(request: Dictionary) -> void:
	if model == null:
		return
	var origin: Dictionary = request.get("focus_origin", {})
	var inventory_id := int(origin.get("inventory_id", 0))
	var item_id := int(origin.get("item_id", 0))
	if inventory_id == 0 or item_id == 0 \
			or _find_item(inventory_id, item_id).is_empty():
		return
	var state := model.item_state(inventory_id, item_id)
	if state == InventoryPresentationModel.STATE_REDACTED \
			or state == InventoryPresentationModel.STATE_DISCONNECTED \
			or state == InventoryPresentationModel.STATE_RESYNCHRONIZING:
		return
	_select(inventory_id, item_id)


## Idle-only exact-item context entry shared by secondary click, touch hold,
## and selection-based keyboard/gamepad requests. Active direct-manipulation
## or modal state consumes the request as Cancel and never opens a second
## interaction surface.
func request_context_actions(inventory_id: int, item_id: int,
		anchor_global_position: Vector2 = Vector2.INF) -> bool:
	if is_dragging() or is_drag_armed() or is_move_mode_active() \
			or is_merge_mode_active() or has_pending_split() or has_pending_drop():
		return cancel()
	if model == null or _find_item(inventory_id, item_id).is_empty():
		return false
	_select(inventory_id, item_id)
	context_actions_requested.emit(
			inventory_id, item_id, available_actions(inventory_id, item_id),
			anchor_global_position)
	return true


# =============================================================================
# Touch (tasks.md 8.6: "press-and-hold opens context actions")
# =============================================================================

## The HOST owns hold-duration timing (this scene-free class has no
## [Node]/timer of its own) -- it calls this on touch-down, then [method
## trigger_touch_hold] once its own timer elapses, or [method
## cancel_touch_hold] on early release/excessive movement.
func begin_touch_hold(inventory_id: int, item_id: int) -> void:
	_touch_hold_candidate = {"inventory_id": inventory_id, "item_id": item_id}


func cancel_touch_hold() -> void:
	_touch_hold_candidate = {}


func trigger_touch_hold() -> bool:
	if _touch_hold_candidate.is_empty():
		return false
	var inv_id := int(_touch_hold_candidate.get("inventory_id", 0))
	var item_id := int(_touch_hold_candidate.get("item_id", 0))
	_touch_hold_candidate = {}
	return request_context_actions(inv_id, item_id)


# =============================================================================
# Cancel (ESC / right-click / B button)
# =============================================================================

func cancel() -> bool:
	if is_dragging():
		cancel_drag()
		return true
	if is_drag_armed():
		release_pointer_arm()
		return true
	if has_pending_split():
		cancel_split()
		return true
	if has_pending_drop():
		cancel_drop()
		return true
	if is_merge_mode_active():
		_end_merge_mode(true)
		return true
	if is_move_mode_active():
		_end_move_mode()
		return true
	if not _touch_hold_candidate.is_empty():
		cancel_touch_hold()
		return true
	if model != null and not model.get_selection().is_empty():
		model.clear_selection()
		return true
	return false


# =============================================================================
# Keyboard/gamepad move-mode (tasks.md 8.6: "select -> activate -> move-mode
# with directional placement preview -> confirm/cancel")
# =============================================================================

func is_move_mode_active() -> bool:
	return not _move_mode.is_empty()


## Enter (nothing selected -> false; selected + idle -> enters move-mode) or
## confirm (move-mode active -> submits the candidate placement) move-mode.
##
## DECISION (tasks.md 8.5's "open" affordance, DESIGN.md §11.3 non-pointer
## parity): a focused container-providing item's "open" does NOT also
## trigger here on `ui_accept`/gamepad-accept -- this method's existing
## selected-item contract ("idle -> enters move-mode") is unconditional and
## depended on by every existing keyboard/gamepad flow (a player must still
## be able to pick UP a backpack via Enter/accept to relocate it, not just
## look inside it), so overloading the SAME action per-item would make one
## of the two behaviors unreachable for a container-providing item. "open" is
## therefore CONTEXT-MENU-ONLY (see [method available_actions]'/[method
## perform_action]'s `open` entry) -- reachable via [constant ACTION_CONTEXT_MENU]
## on any input device, satisfying §11.3's parity requirement without
## touching this method's own contract.
func activate() -> bool:
	if is_merge_mode_active():
		var candidates: Array = _merge_mode.get("candidate_item_ids", [])
		if candidates.is_empty():
			return false
		var index := clampi(int(_merge_mode.get("target_index", 0)), 0, candidates.size() - 1)
		return choose_merge_target(int(_merge_mode.get("inventory_id", 0)), int(candidates[index]))
	if is_move_mode_active():
		return _confirm_move_mode()
	if model == null or is_dragging():
		return false
	var sel := model.get_selection()
	if sel.is_empty():
		return false
	var inv_id := int(sel.get("inventory_id", 0))
	var item_id := int(sel.get("item_id", 0))
	var item := _find_item(inv_id, item_id)
	if item.is_empty() or model.is_item_read_only(item_id):
		return false
	var location: Dictionary = item.get("location", {})
	_move_mode = {
		"inventory_id": inv_id, "item_id": item_id,
		"container_id": int(location.get("container", -1)),
		"candidate_container_id": int(location.get("container", -1)),
		"candidate_location": location.duplicate(true),
		"rotated": bool(location.get("rotated", false)),
	}
	move_mode_started.emit(inv_id, item_id)
	_revalidate_move_mode_target()
	return true


func _confirm_move_mode() -> bool:
	var state: Dictionary = _move_mode
	_move_mode = {}
	move_mode_ended.emit()
	var candidate_container_id := int(state["candidate_container_id"])
	var candidate_location: Dictionary = state["candidate_location"]
	var result := _compute_drop_state(int(state["inventory_id"]), int(state["item_id"]), candidate_container_id, candidate_location, bool(state["rotated"]))
	var drop_state: StringName = result["state"]
	if drop_state != &"drop-valid" and drop_state != &"drop-occupied":
		return false
	_resolve_and_submit_drop(int(state["inventory_id"]), int(state["item_id"]), candidate_container_id, candidate_location,
			bool(state["rotated"]), int(result.get("occupant_item_id", 0)),
			int(result.get("provider_item_id", 0)))
	return true


func _end_move_mode() -> void:
	if not is_move_mode_active():
		return
	_move_mode = {}
	move_mode_ended.emit()


func _revalidate_move_mode_target() -> void:
	if not is_move_mode_active():
		return
	var result := _compute_drop_state(int(_move_mode["inventory_id"]), int(_move_mode["item_id"]),
			int(_move_mode["candidate_container_id"]), _move_mode["candidate_location"], bool(_move_mode["rotated"]))
	move_mode_updated.emit(result["state"], int(_move_mode["candidate_container_id"]), (_move_mode["candidate_location"] as Dictionary).duplicate(true))


## Move-mode candidate stepping stays WITHIN the item's current container
## this wave (see this file's header "Scope notes").
func _step_move_mode_candidate(direction: StringName) -> bool:
	var container_id := int(_move_mode["candidate_container_id"])
	var info: Dictionary = _containers.get(container_id, {})
	var loc: Dictionary = _move_mode["candidate_location"]
	match StringName(info.get("layout", &"spatial")):
		&"spatial":
			var x := int(loc.get("x", 0))
			var y := int(loc.get("y", 0))
			match direction:
				&"right": x += 1
				&"left": x -= 1
				&"down": y += 1
				&"up": y -= 1
				_: return false
			var width := int(info.get("grid_width", 0))
			var height := int(info.get("grid_height", 0))
			if width > 0:
				x = clampi(x, 0, maxi(width - 1, 0))
			if height > 0:
				y = clampi(y, 0, maxi(height - 1, 0))
			_move_mode["candidate_location"] = {"kind": "spatial", "container": container_id, "x": x, "y": y, "rotated": bool(_move_mode["rotated"])}
		&"named_slots":
			var identifiers: Array = info.get("slot_identifiers", [])
			if identifiers.is_empty():
				return false
			var next_identifier := _slot_step(identifiers, String(loc.get("slot_identifier", "")), direction)
			_move_mode["candidate_location"] = {"kind": "slot", "container": container_id, "slot_identifier": next_identifier}
		&"ordered_list":
			var ordinal := int(loc.get("ordinal", 0))
			var max_ordinal := _list_item_count(int(_move_mode["inventory_id"]), container_id)
			var step := 1 if (direction == &"down" or direction == &"right") else -1
			ordinal = clampi(ordinal + step, 0, max_ordinal)
			_move_mode["candidate_location"] = {"kind": "list", "container": container_id, "ordinal": ordinal}
		_:
			return false
	_revalidate_move_mode_target()
	return true


func _list_item_count(inventory_id: int, container_id: int) -> int:
	var count := 0
	for item_variant in _items_in_container(inventory_id, container_id):
		if String((item_variant as Dictionary).get("location", {}).get("kind", "")) == "list":
			count += 1
	return count


func get_move_mode_state() -> Dictionary:
	return _move_mode.duplicate(true)


# =============================================================================
# Keyboard/gamepad neighbor traversal (tasks.md 8.6, "normal" -- non-move-mode)
# =============================================================================

func move_focus(direction: StringName) -> bool:
	if model == null:
		return false
	if is_merge_mode_active():
		return _step_merge_target(1 if (direction == &"down" or direction == &"right") else -1)
	if is_move_mode_active():
		return _step_move_mode_candidate(direction)
	if is_dragging():
		return false
	var sel := model.get_selection()
	if sel.is_empty():
		return _focus_first_overall()
	var inv_id := int(sel.get("inventory_id", 0))
	var item_id := int(sel.get("item_id", 0))
	var item := _find_item(inv_id, item_id)
	if item.is_empty():
		return _focus_first_overall()
	var loc: Dictionary = item.get("location", {})
	var container_id := int(loc.get("container", -1))
	var info: Dictionary = _containers.get(container_id, {})
	if info.is_empty():
		return _focus_first_overall()

	match StringName(info.get("layout", &"spatial")):
		&"spatial":
			var items := _items_in_container(inv_id, container_id)
			var origin := Vector2i(int(loc.get("x", 0)), int(loc.get("y", 0)))
			var candidate := _grid_directional_candidate(items, origin, direction)
			if candidate.is_empty():
				return _fallthrough_to_adjacent_container(direction)
			_select(inv_id, int(candidate.get("id", 0)))
			return true
		&"named_slots":
			return _navigate_slots(inv_id, container_id, String(loc.get("slot_identifier", "")), direction)
		&"ordered_list":
			var items := _items_sorted_by_ordinal(inv_id, container_id)
			var target := _list_navigate(items, item_id, direction)
			if target.is_empty():
				return _fallthrough_to_adjacent_container(direction)
			_select(inv_id, int(target.get("id", 0)))
			return true
		_:
			return false


func move_focus_next_container() -> bool:
	return _jump_container(1)


func move_focus_previous_container() -> bool:
	return _jump_container(-1)


## Ranks every candidate in [param direction] by (1) nearest along the
## primary axis first -- the item most directly "in the way" wins over one
## that is merely better column/row-aligned but farther away -- then (2)
## smallest perpendicular offset, then (3) the documented tie-break: smallest
## x then y of the item's origin cell. Adjacency is computed from each item's
## ORIGIN cell only, not full-footprint edge distance (a documented
## simplification -- rectangular items still participate correctly, just
## addressed by their own origin).
func _grid_directional_candidate(items: Array, current_origin: Vector2i, direction: StringName) -> Dictionary:
	var candidates: Array = []
	for item_variant in items:
		var item: Dictionary = item_variant
		var loc: Dictionary = item.get("location", {})
		var ox := int(loc.get("x", 0))
		var oy := int(loc.get("y", 0))
		if ox == current_origin.x and oy == current_origin.y:
			continue
		var axis_delta := 0
		var off_delta := 0
		match direction:
			&"right":
				axis_delta = ox - current_origin.x
				off_delta = absi(oy - current_origin.y)
			&"left":
				axis_delta = current_origin.x - ox
				off_delta = absi(oy - current_origin.y)
			&"down":
				axis_delta = oy - current_origin.y
				off_delta = absi(ox - current_origin.x)
			&"up":
				axis_delta = current_origin.y - oy
				off_delta = absi(ox - current_origin.x)
			_:
				continue
		if axis_delta <= 0:
			continue
		candidates.append({"item": item, "off": off_delta, "axis": axis_delta, "x": ox, "y": oy})
	if candidates.is_empty():
		return {}
	candidates.sort_custom(func(a, b):
		if a["axis"] != b["axis"]:
			return a["axis"] < b["axis"]
		if a["off"] != b["off"]:
			return a["off"] < b["off"]
		if a["x"] != b["x"]:
			return a["x"] < b["x"]
		return a["y"] < b["y"])
	return candidates[0]["item"]


func _navigate_slots(inv_id: int, container_id: int, current_identifier: String, direction: StringName) -> bool:
	var info: Dictionary = _containers.get(container_id, {})
	var slots: Array = info.get("slot_identifiers", [])
	if slots.is_empty():
		return _fallthrough_to_adjacent_container(direction)
	var identifier := current_identifier
	for i in range(slots.size()):
		identifier = _slot_step(slots, identifier, direction)
		var occupant := _item_in_slot(inv_id, container_id, identifier)
		if not occupant.is_empty():
			_select(inv_id, int(occupant.get("id", 0)))
			return true
	return _fallthrough_to_adjacent_container(direction)


## Declared-slot-order stepping, WRAPPING within the container (tasks.md 8.6
## "wrap rules") -- `down`/`right` steps forward, `up`/`left` steps backward.
func _slot_step(slots: Array, current_identifier: String, direction: StringName) -> String:
	var idx := slots.find(current_identifier)
	if idx < 0:
		idx = 0
	var step := 1 if (direction == &"down" or direction == &"right") else -1
	var next_idx := (idx + step + slots.size()) % slots.size()
	return String(slots[next_idx])


## Ordinal-order stepping, WRAPPING within the container (tasks.md 8.6 "wrap
## rules").
func _list_navigate(items: Array, current_item_id: int, direction: StringName) -> Dictionary:
	if items.is_empty():
		return {}
	var idx := -1
	for i in range(items.size()):
		if int((items[i] as Dictionary).get("id", 0)) == current_item_id:
			idx = i
			break
	if idx < 0:
		return items[0]
	var step := 1 if (direction == &"down" or direction == &"right") else -1
	var next_idx := (idx + step + items.size()) % items.size()
	return items[next_idx]


## `down`/`right` falls through to the NEXT container in canonical order;
## `up`/`left` falls through to the PREVIOUS one (tasks.md 8.6
## "cross-container jump").
func _fallthrough_to_adjacent_container(direction: StringName) -> bool:
	if direction == &"down" or direction == &"right":
		return move_focus_next_container()
	if direction == &"up" or direction == &"left":
		return move_focus_previous_container()
	return false


func _jump_container(step: int) -> bool:
	var order := _flattened_container_order()
	if order.is_empty():
		return false
	var current_container_id := _current_container_id()
	var start_idx := order.find(current_container_id)
	if start_idx < 0:
		start_idx = -1 if step > 0 else order.size()
	var idx := start_idx
	for i in range(order.size()):
		idx = (idx + step + order.size()) % order.size()
		var cid: int = order[idx]
		var inv_id := int((_containers.get(cid, {}) as Dictionary).get("inventory_id", 0))
		if _enter_container(cid, inv_id, step < 0):
			return true
	return false


func _current_container_id() -> int:
	if model == null:
		return -1
	var sel := model.get_selection()
	if sel.is_empty():
		return -1
	var item := _find_item(int(sel.get("inventory_id", 0)), int(sel.get("item_id", 0)))
	if item.is_empty():
		return -1
	return int((item.get("location", {}) as Dictionary).get("container", -1))


## Pane-local canonical container order (ascending container id), then
## across panes -- leading (`left`) before trailing (`right`), matching
## DESIGN.md §11.3's pane-order rule -- then across any ADDITIONAL side name
## a host registers via [method set_containers] beyond this addon's own two
## (e.g. a CommonUI adapter's windowed/opened-container view registered under
## its own unique side identifier), in the order each such side was FIRST
## registered ([member _pane_container_order]'s own Dictionary insertion
## order, which GDScript preserves and re-registering an EXISTING side never
## disturbs). `left`/`right` always sort first regardless of registration
## order, matching every pre-existing ordering expectation exactly -- only
## traversal reaching sides BEYOND those two is new behavior here (previously
## `move_focus_next_container`/`move_focus_previous_container` silently
## stopped at `right`'s last container, never reaching a third side at all).
func _flattened_container_order() -> Array[int]:
	var ids: Array[int] = []
	for cid in _pane_container_order.get(SIDE_LEFT, []):
		ids.append(cid)
	for cid in _pane_container_order.get(SIDE_RIGHT, []):
		ids.append(cid)
	for side in _pane_container_order:
		if side == SIDE_LEFT or side == SIDE_RIGHT:
			continue
		for cid in _pane_container_order[side]:
			ids.append(cid)
	return ids


func _enter_container(container_id: int, inventory_id: int, prefer_last: bool) -> bool:
	var remembered := model.recall_focus(container_id)
	if not remembered.is_empty() and remembered.is_valid_int():
		var remembered_id := int(remembered)
		if _is_focus_eligible(inventory_id, remembered_id, container_id):
			_select(inventory_id, remembered_id)
			return true
	var target := _last_focus_target(inventory_id, container_id) if prefer_last else _first_focus_target(inventory_id, container_id)
	if target.is_empty():
		return false
	_select(inventory_id, int(target.get("id", 0)))
	return true


## DESIGN.md §11.3: focus restoration must verify the target remains
## "visible, enabled, allowed, and valid" -- interpreted here as: still present
## in the snapshot, still located in the SAME container this memory belongs
## to (it may have moved elsewhere since), and not redacted.
func _is_focus_eligible(inventory_id: int, item_id: int, container_id: int) -> bool:
	var item := _find_item(inventory_id, item_id)
	if item.is_empty():
		return false
	if int((item.get("location", {}) as Dictionary).get("container", -1)) != container_id:
		return false
	return model.item_state(inventory_id, item_id) != InventoryPresentationModel.STATE_REDACTED


func _first_focus_target(inventory_id: int, container_id: int) -> Dictionary:
	return _edge_focus_target(inventory_id, container_id, true)


func _last_focus_target(inventory_id: int, container_id: int) -> Dictionary:
	return _edge_focus_target(inventory_id, container_id, false)


## Row-major (top-left -> bottom-right) for a grid, declared order for named
## slots, ordinal order for a list -- DESIGN.md §11.3's tab-order rule.
func _edge_focus_target(inventory_id: int, container_id: int, first: bool) -> Dictionary:
	var info: Dictionary = _containers.get(container_id, {})
	match StringName(info.get("layout", &"spatial")):
		&"spatial":
			var items := _items_in_container(inventory_id, container_id)
			if items.is_empty():
				return {}
			items.sort_custom(func(a, b):
				var la: Dictionary = (a as Dictionary).get("location", {})
				var lb: Dictionary = (b as Dictionary).get("location", {})
				if int(la.get("y", 0)) != int(lb.get("y", 0)):
					return int(la.get("y", 0)) < int(lb.get("y", 0))
				return int(la.get("x", 0)) < int(lb.get("x", 0)))
			return items[0] if first else items[items.size() - 1]
		&"named_slots":
			var slots: Array = (info.get("slot_identifiers", []) as Array).duplicate()
			if not first:
				slots.reverse()
			for identifier in slots:
				var occupant := _item_in_slot(inventory_id, container_id, String(identifier))
				if not occupant.is_empty():
					return occupant
			return {}
		&"ordered_list":
			var items := _items_sorted_by_ordinal(inventory_id, container_id)
			if items.is_empty():
				return {}
			return items[0] if first else items[items.size() - 1]
		_:
			return {}


func _focus_first_overall() -> bool:
	for cid in _flattened_container_order():
		var inv_id := int((_containers.get(cid, {}) as Dictionary).get("inventory_id", 0))
		if _enter_container(cid, inv_id, false):
			return true
	return false


# =============================================================================
# Raw InputEvent dispatch (tasks.md 8.6)
# =============================================================================

func handle_input_event(event: InputEvent) -> bool:
	var mb := event as InputEventMouseButton
	if mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_RIGHT:
		return cancel()
	if event.is_action_pressed(&"ui_cancel"):
		return cancel()
	if event.is_action_pressed(&"ui_accept"):
		return activate()
	if _event_action_pressed(event, ACTION_ROTATE):
		return rotate_selected()
	if _event_action_pressed(event, ACTION_QUICK_TRANSFER):
		return quick_transfer_selected()
	if _event_action_pressed(event, ACTION_AUTO_PLACE):
		return auto_place_selected()
	if _event_action_pressed(event, ACTION_INSPECT):
		return not inspect_selected().is_empty()
	if _event_action_pressed(event, ACTION_CONTEXT_MENU):
		return _request_context_menu_for_selection()
	if _event_action_pressed(event, ACTION_NEXT_CONTAINER):
		return move_focus_next_container()
	if _event_action_pressed(event, ACTION_PREVIOUS_CONTAINER):
		return move_focus_previous_container()
	if event.is_action_pressed(&"ui_up"):
		return move_focus(&"up")
	if event.is_action_pressed(&"ui_down"):
		return move_focus(&"down")
	if event.is_action_pressed(&"ui_left"):
		return move_focus(&"left")
	if event.is_action_pressed(&"ui_right"):
		return move_focus(&"right")
	return false


## Guards a custom `inventory_*` [constant ACTION_*] lookup so an unregistered
## action (the remaining `The InputMap action "inventory_*" doesn't exist`
## noise docs/inventory/visual-qa-2026-07-27.md finding 8 flagged in the
## `inventory_common_ui` suite log -- a host/suite that never called [method
## ensure_default_input_actions]) is skipped silently instead of Godot's own
## [method InputEvent.is_action_pressed] emitting an engine error for an
## unknown action name. Built-in `ui_*` actions above are NEVER routed through
## this helper -- they always exist (Godot registers them itself) and guarding
## them would be pure overhead for a case that can't occur.
func _event_action_pressed(event: InputEvent, action: StringName) -> bool:
	return InputMap.has_action(action) and event.is_action_pressed(action)


func _request_context_menu_for_selection() -> bool:
	if model == null:
		return false
	var sel := model.get_selection()
	if sel.is_empty():
		return false
	var inv_id := int(sel.get("inventory_id", 0))
	var item_id := int(sel.get("item_id", 0))
	return request_context_actions(inv_id, item_id)


## Registers this class's custom input actions with reasonable default
## bindings, ONLY if the action name is not already defined (a host/project
## that pre-defines the same action names in Project Settings' Input Map --
## or has already called this once -- is never overwritten). Idempotent;
## safe to call from every [InventoryTwoPaneView.configure] or once at boot.
## Gamepad bindings for [constant ACTION_NEXT_CONTAINER]/[constant
## ACTION_PREVIOUS_CONTAINER] were a flagged gap (this class's own default
## bindings covered every other action but these two). The console convention
## for "cycle" actions like this is the shoulder-button pair -- confirmed by
## this repository's own CommonUI addon, whose `TAB_NEXT`/`TAB_PREVIOUS`
## defaults (`addons/common_ui/runtime/common_ui_defaults.gd`) bind
## `JOY_BUTTON_RIGHT_SHOULDER`/`JOY_BUTTON_LEFT_SHOULDER` ("LB/RB") for
## exactly this "cycle forward/back through a set" shape, with the doc
## comment "shoulder buttons are the console convention for cycling tabs".
## Both shoulder buttons are already claimed on THIS class by [constant
## ACTION_QUICK_TRANSFER] (right) and [constant ACTION_SPLIT_MODIFIER] (left)
## -- reusing them here would silently starve container-cycling of the
## physical button entirely, since [method handle_input_event] checks actions
## in a fixed order and returns on the first match, so a shoulder-button press
## would always resolve to quick-transfer/split-modifier first. This binds the
## analog trigger pair (L2/R2 -- `JOY_AXIS_TRIGGER_LEFT`/`JOY_AXIS_TRIGGER_RIGHT`)
## instead: physically adjacent to the shoulder buttons (same "front bumper
## pair" gamepad region a player already associates with LB/RB-style
## cycling), but a distinct physical input with no existing binding on this
## class to collide with.
static func ensure_default_input_actions() -> void:
	_ensure_action(ACTION_ROTATE, [_key_event(KEY_R), _joy_event(JOY_BUTTON_Y)])
	_ensure_action(ACTION_SPLIT_MODIFIER, [_key_event(KEY_ALT), _joy_event(JOY_BUTTON_LEFT_SHOULDER)])
	_ensure_action(ACTION_QUICK_TRANSFER, [_key_event(KEY_F), _joy_event(JOY_BUTTON_RIGHT_SHOULDER)])
	_ensure_action(ACTION_AUTO_PLACE, [_key_event(KEY_G), _joy_event(JOY_BUTTON_X)])
	_ensure_action(ACTION_INSPECT, [_key_event(KEY_I)])
	_ensure_action(ACTION_CONTEXT_MENU, [_key_event(KEY_C), _joy_event(JOY_BUTTON_BACK)])
	_ensure_action(ACTION_NEXT_CONTAINER, [_key_event(KEY_TAB, false), _joy_axis_event(JOY_AXIS_TRIGGER_RIGHT)])
	_ensure_action(ACTION_PREVIOUS_CONTAINER, [_key_event(KEY_TAB, true), _joy_axis_event(JOY_AXIS_TRIGGER_LEFT)])


static func _ensure_action(action: StringName, events: Array) -> void:
	if InputMap.has_action(action):
		return
	InputMap.add_action(action)
	for event in events:
		InputMap.action_add_event(action, event)


static func _key_event(keycode: Key, shift: bool = false) -> InputEventKey:
	var event := InputEventKey.new()
	event.keycode = keycode
	event.shift_pressed = shift
	return event


static func _joy_event(button: JoyButton) -> InputEventJoypadButton:
	var event := InputEventJoypadButton.new()
	event.button_index = button
	return event


static func _joy_axis_event(axis: JoyAxis) -> InputEventJoypadMotion:
	var event := InputEventJoypadMotion.new()
	event.axis = axis
	event.axis_value = 1.0
	return event


# =============================================================================
# Drop-target validity + command routing (shared by drag-drop and move-mode)
# =============================================================================

## Resolves to `{"state": StringName (one of InventoryDragGhost's DROP_*
## tokens), "occupant_item_id": int, "provider_item_id": int,
## "dest_inventory_id": int}`. [param staged_quantity] is nonzero for an
## Alt/Option half split and drives mass/count/fits preview without changing
## the source snapshot. [param empty_only] prevents the half-split accelerator
## from becoming an implicit partial merge or container transfer.
func _compute_drop_state(dragged_inventory_id: int, dragged_item_id: int,
		dest_container_id: int, dest_location: Dictionary, rotated: bool,
		staged_quantity: int = 0, empty_only: bool = false) -> Dictionary:
	var dest_inventory_id := _inventory_id_for_container(dest_container_id)
	if dest_inventory_id == 0 or model == null:
		return {"state": &"drop-invalid", "occupant_item_id": 0, "provider_item_id": 0, "dest_inventory_id": 0}

	if model.container_state(dest_inventory_id, dest_container_id) == InventoryPresentationModel.STATE_INACCESSIBLE:
		return {"state": &"drop-inaccessible", "occupant_item_id": 0, "provider_item_id": 0, "dest_inventory_id": dest_inventory_id}
	if model.is_container_read_only(dest_container_id):
		return {"state": &"drop-invalid", "occupant_item_id": 0, "provider_item_id": 0, "dest_inventory_id": dest_inventory_id}

	var occupant_id := _occupant_at_location(dest_inventory_id, dest_container_id, dest_location)
	if empty_only and occupant_id != 0:
		return {"state": &"drop-invalid", "occupant_item_id": occupant_id, "provider_item_id": 0, "dest_inventory_id": dest_inventory_id}
	if occupant_id != 0 and occupant_id != dragged_item_id:
		var occupant := _find_item(dest_inventory_id, occupant_id)
		if not (occupant.get("provided_containers", []) as Array).is_empty():
			# A container-providing card has semantic precedence over the
			# occupied-location merge/swap path. Missing preview support is a
			# failed insertion, never permission to swap the provider away.
			if command_sink == null or not command_sink.has_method(&"preview_transfer_item_to_provider"):
				return {"state": &"drop-invalid", "occupant_item_id": occupant_id, "provider_item_id": occupant_id, "dest_inventory_id": dest_inventory_id}
			var preview: Dictionary = command_sink.call(
					&"preview_transfer_item_to_provider", dragged_inventory_id,
					dest_inventory_id, dragged_item_id, occupant_id, actor_id)
			if bool(preview.get("valid", false)):
				return {"state": &"drop-valid", "occupant_item_id": occupant_id, "provider_item_id": occupant_id, "dest_inventory_id": dest_inventory_id}
			return {
				"state": _drop_state_from_status(preview.get("status", {}) as Dictionary),
				"occupant_item_id": occupant_id,
				"provider_item_id": occupant_id,
				"dest_inventory_id": dest_inventory_id,
			}
		return {"state": &"drop-occupied", "occupant_item_id": occupant_id, "provider_item_id": 0, "dest_inventory_id": dest_inventory_id}
	if occupant_id == dragged_item_id and occupant_id != 0:
		return {"state": &"drop-valid", "occupant_item_id": 0, "provider_item_id": 0, "dest_inventory_id": dest_inventory_id} # dropped back onto its own cell -- a harmless no-op target.

	var item := _find_item(dragged_inventory_id, dragged_item_id)
	var identifier := String(item.get("item_definition_identifier", ""))
	var quantity := staged_quantity if staged_quantity > 0 else int(item.get("quantity", 1))

	if _would_exceed_mass_capacity(dest_inventory_id, dest_container_id, identifier, quantity):
		return {"state": &"drop-overweight", "occupant_item_id": 0, "provider_item_id": 0, "dest_inventory_id": dest_inventory_id}

	if String(dest_location.get("kind", "")) == "list":
		# Ordered lists have no per-row occupancy concept (DESIGN.md §12.4);
		# authority remains the final arbiter on capacity.
		return {"state": &"drop-valid", "occupant_item_id": 0, "provider_item_id": 0, "dest_inventory_id": dest_inventory_id}

	if command_sink == null or not command_sink.has_method(&"fits"):
		return {"state": &"drop-invalid", "occupant_item_id": 0, "provider_item_id": 0, "dest_inventory_id": dest_inventory_id}

	var probe_location: Dictionary = dest_location.duplicate(true)
	if String(probe_location.get("kind", "")) == "spatial":
		probe_location["rotated"] = rotated

	var ignored_item_id := 0 if empty_only else dragged_item_id
	var fits_result: Dictionary = command_sink.call(&"fits", dest_inventory_id, identifier, probe_location, quantity, ignored_item_id)
	if bool(fits_result.get("ok", false)):
		return {"state": &"drop-valid", "occupant_item_id": 0, "provider_item_id": 0, "dest_inventory_id": dest_inventory_id}

	var status: Dictionary = fits_result.get("status", {})
	return {"state": _drop_state_from_status(status), "occupant_item_id": 0, "provider_item_id": 0, "dest_inventory_id": dest_inventory_id}


func _drop_state_from_status(status: Dictionary) -> StringName:
	var diagnostic := int(status.get("diagnostic", 0))
	return _DIAGNOSTIC_DROP_STATES.get(diagnostic, &"drop-invalid")


## `fits()` deliberately does NOT check mass capacity (native/core/
## inv_runtime_state.cpp's `InventoryRuntime::fits()` calls only
## `validate_placement()`/`validate_nesting_target()` -- layout/rotation/
## bounds/overlap/slot-filter/count/nesting/container-trait-filter; mass is a
## POLICY-phase check applied only during a real command's full transaction
## pipeline, tasks.md 5.8). The drop-overweight PREVIEW therefore has to be
## derived here from the same two side-effect-free derived queries a pane
## header already uses: `container_mass_capacity()` (the bound, when the
## feature is enabled) and `container_mass()` (current usage). Approximation,
## documented: when the destination IS the item's own current container (an
## in-place rearrange), this does not subtract the item's own already-counted
## mass from `current`, so a full container can read as "overweight" for a
## same-container move that would actually be a net-zero mass change --
## authority's own real command remains the final, correct arbiter either way.
func _would_exceed_mass_capacity(dest_inventory_id: int, dest_container_id: int, item_identifier: String, quantity: int) -> bool:
	if command_sink == null or not command_sink.has_method(&"container_mass_capacity") or not command_sink.has_method(&"container_mass"):
		return false
	var unit_mass := int(mass_lookup.get(item_identifier, 0))
	if unit_mass <= 0:
		return false
	var capacity_result: Dictionary = command_sink.call(&"container_mass_capacity", dest_inventory_id, dest_container_id)
	if not bool(capacity_result.get("ok", false)):
		return false
	var mass_result: Dictionary = command_sink.call(&"container_mass", dest_inventory_id, dest_container_id)
	if not bool(mass_result.get("ok", false)):
		return false
	var incoming_mg := unit_mass * maxi(quantity, 1)
	var capacity_mg := int(capacity_result.get("mass_capacity_mg", 0))
	var current_mg := int(mass_result.get("mass_mg", 0))
	return current_mg + incoming_mg > capacity_mg


func _occupant_at_location(inventory_id: int, container_id: int, location: Dictionary) -> int:
	var snapshot := model.get_snapshot(inventory_id) if model != null else null
	if snapshot == null:
		return 0
	var kind := String(location.get("kind", ""))
	for item_variant in snapshot.get_items():
		var item: Dictionary = item_variant
		var loc: Dictionary = item.get("location", {})
		if int(loc.get("container", -1)) != container_id:
			continue
		if String(loc.get("kind", "")) != kind:
			continue
		match kind:
			"spatial":
				if int(loc.get("x", -1)) == int(location.get("x", -2)) and int(loc.get("y", -1)) == int(location.get("y", -2)):
					return int(item.get("id", 0))
			"slot":
				if String(loc.get("slot_identifier", "")) == String(location.get("slot_identifier", "")):
					return int(item.get("id", 0))
			_:
				pass
	return 0


## Merge (same-inventory, same item definition) / swap (same-inventory,
## occupied, different item) / equip (empty named slot) / move (empty
## spatial cell) / loot (cross-inventory, any destination kind) -- see this
## file's header for why cross-inventory occupied targets fall through to
## `loot_item` rather than a dedicated cross-inventory merge/swap command
## (neither exists as a single typed command spanning two inventories).
func _resolve_and_submit_drop(inventory_id: int, item_id: int,
		dest_container_id: int, dest_location: Dictionary, rotated: bool,
		occupant_item_id: int, provider_item_id: int = 0) -> Dictionary:
	var item := _find_item(inventory_id, item_id)
	var dest_inventory_id := _inventory_id_for_container(dest_container_id)
	if dest_inventory_id == 0:
		return {}

	var probe_location: Dictionary = dest_location.duplicate(true)
	if String(probe_location.get("kind", "")) == "spatial":
		probe_location["rotated"] = rotated

	if provider_item_id != 0:
		if command_sink == null or not command_sink.has_method(&"transfer_item_to_provider"):
			return {}
		return _submit(inventory_id, &"targeted_provider_transfer", [item_id, provider_item_id],
				func(cmd_id: int) -> Dictionary:
					return command_sink.call(&"transfer_item_to_provider", inventory_id,
							dest_inventory_id, item_id, provider_item_id, actor_id, cmd_id))

	if occupant_item_id != 0 and occupant_item_id != item_id and dest_inventory_id == inventory_id:
		var occupant := _find_item(inventory_id, occupant_item_id)
		if String(occupant.get("item_definition_identifier", "")) == String(item.get("item_definition_identifier", "")):
			return _submit(inventory_id, &"merge", [item_id, occupant_item_id],
					func(cmd_id: int) -> Dictionary: return command_sink.call(&"merge_stacks", inventory_id, item_id, occupant_item_id, actor_id, cmd_id))
		return _submit(inventory_id, &"swap", [item_id, occupant_item_id],
				func(cmd_id: int) -> Dictionary: return command_sink.call(&"swap_items", inventory_id, item_id, occupant_item_id, actor_id, cmd_id))

	if dest_inventory_id != inventory_id:
		return _submit(inventory_id, &"loot", [item_id],
				func(cmd_id: int) -> Dictionary: return command_sink.call(&"loot_item", inventory_id, dest_inventory_id, item_id, probe_location, actor_id, cmd_id))

	if String(probe_location.get("kind", "")) == "slot":
		return _submit(inventory_id, &"equip", [item_id],
				func(cmd_id: int) -> Dictionary: return command_sink.call(&"equip_item", inventory_id, item_id, dest_container_id, String(probe_location.get("slot_identifier", "")), actor_id, cmd_id))

	return _submit(inventory_id, &"move", [item_id],
			func(cmd_id: int) -> Dictionary: return command_sink.call(&"move_item", inventory_id, item_id, probe_location, actor_id, cmd_id))


## The SOLE mutation funnel (this file's header): [method
## InventoryPresentationModel.begin_intent], exactly one duck-typed
## command-sink call, exactly one [method InventoryPresentationModel.apply_result].
func _submit(inventory_id: int, kind: StringName, items: Array, submit_callable: Callable, ghost_placement: Dictionary = {}) -> Dictionary:
	var pending_id := model.begin_intent(kind, {"inventory_id": inventory_id, "items": items, "ghost_placement": ghost_placement})
	var result: Dictionary = submit_callable.call(pending_id)
	model.apply_result(result)
	command_submitted.emit(kind, {"inventory_id": inventory_id, "items": items.duplicate()}, result)
	return result


func _inventory_id_for_container(container_id: int) -> int:
	return int((_containers.get(container_id, {}) as Dictionary).get("inventory_id", 0))


func _other_side_for_inventory(inventory_id: int) -> StringName:
	var side := _side_for_inventory(inventory_id)
	if side.is_empty():
		return &""
	var other := SIDE_RIGHT if side == SIDE_LEFT else SIDE_LEFT
	var other_inventory := int(_pane_inventory.get(other, 0))
	if other_inventory == 0 or other_inventory == inventory_id:
		return &""
	return other


func _side_for_inventory(inventory_id: int) -> StringName:
	for side in _pane_inventory:
		if int(_pane_inventory[side]) == inventory_id:
			return side
	return &""


# =============================================================================
# Snapshot lookup helpers
# =============================================================================

func _find_item(inventory_id: int, item_id: int) -> Dictionary:
	var snapshot := model.get_snapshot(inventory_id) if model != null else null
	if snapshot == null:
		return {}
	for item_variant in snapshot.get_items():
		var item: Dictionary = item_variant
		if int(item.get("id", 0)) == item_id:
			return item
	return {}


func _items_in_container(inventory_id: int, container_id: int) -> Array:
	var snapshot := model.get_snapshot(inventory_id) if model != null else null
	if snapshot == null:
		return []
	var result: Array = []
	for item_variant in snapshot.get_items():
		var item: Dictionary = item_variant
		if int((item.get("location", {}) as Dictionary).get("container", -1)) == container_id:
			result.append(item)
	return result


func _items_sorted_by_ordinal(inventory_id: int, container_id: int) -> Array:
	var rows: Array = []
	for item_variant in _items_in_container(inventory_id, container_id):
		var item: Dictionary = item_variant
		if String((item.get("location", {}) as Dictionary).get("kind", "")) == "list":
			rows.append(item)
	rows.sort_custom(func(a, b):
		return int((a as Dictionary).get("location", {}).get("ordinal", 0)) < int((b as Dictionary).get("location", {}).get("ordinal", 0)))
	return rows


func _item_in_slot(inventory_id: int, container_id: int, identifier: String) -> Dictionary:
	for item_variant in _items_in_container(inventory_id, container_id):
		var item: Dictionary = item_variant
		var loc: Dictionary = item.get("location", {})
		if String(loc.get("kind", "")) != "slot":
			continue
		if String(loc.get("slot_identifier", "")) == identifier:
			return item
	return {}
