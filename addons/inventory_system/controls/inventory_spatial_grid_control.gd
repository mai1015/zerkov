class_name InventorySpatialGridControl
extends Control

## Ownership-layout renderer for `SPATIAL_GRID` containers (tasks.md 8.3;
## DESIGN.md §6.2, §12.2). A plain script-only [Control] with no companion
## `.tscn`: every geometry value it draws is computed from
## [InventoryDesignTokens] at [method configure]/rebuild time, so there is
## nothing a hand-authored scene file would add except a second place for
## that math to drift from this script's own -- keeping it code-only means
## the renderer registry's default registration ([method
## InventoryRendererRegistry.register_builtin_defaults]) can hand out this
## [Script] object directly and a game replaces it exactly the same way,
## whether its own replacement is a script or a scene ([InventoryRendererRegistry]
## accepts either).
##
## Renders READ-ONLY from the current snapshot plus [method
## InventoryPresentationModel.item_state]/[method
## InventoryPresentationModel.container_state]; re-renders on [signal
## InventoryPresentationModel.model_changed]. Never calls into an authority;
## every interaction becomes an [signal intent_requested] emission for the
## host to submit.
##
## Grid dimensions and per-item footprint are catalog-side data
## ([InventoryContainerDefinition]/[InventoryItemDefinition]), NOT part of
## the snapshot DTO ([method InventorySnapshotResource.get_containers]/[method
## InventorySnapshotResource.get_items] deliberately carry neither) -- the
## host supplies them to [method configure] (typically resolved once from its
## own sealed [InventoryCatalog]). An item definition identifier missing from
## [member footprint_lookup] renders as 1x1 (a safe, visually-conservative
## default -- never a crash or a misplaced card) rather than requiring every
## caller to populate every identifier up front.

signal intent_requested(kind: StringName, args: Dictionary)
## tasks.md 8.5 drag/drop wiring -- [InventoryInteractionController] subscribes
## to these on every rendered container control (grid/slots/list alike) to
## learn which candidate location the pointer is over and where it was
## released, without doing its own pixel hit-testing. [param location] is
## always a Location Dictionary (docs/api.md's shape); the emitting control
## fills in only the fields meaningful for its own `kind`. The occupying item
## (if any) is deliberately NOT part of the payload -- the controller re-reads
## "what occupies this location right now" from the model's own current
## snapshot at the moment it acts, which stays correct even if something else
## changed the container between hover and use.
signal location_hover_entered(container_id: int, location: Dictionary)
signal location_hover_exited(container_id: int, location: Dictionary)
signal location_pointer_up(container_id: int, location: Dictionary)

var model: InventoryPresentationModel
var tokens: InventoryDesignTokens
var inventory_id: int = 0
var container_id: int = 0
var grid_width: int = 0
var grid_height: int = 0
## String item_definition_identifier -> Vector2i(width, height), pre-rotation.
var footprint_lookup: Dictionary = {}

var _cell_panels: Dictionary = {} # "x,y" String -> Panel
var _selection_overlays: Dictionary = {} # "x,y" -> InventorySelectionOverlay
var _cards: Dictionary = {} # int item_id -> InventoryItemCard
var _card_origins: Dictionary = {} # int item_id -> Vector2i, for _on_card_released/_on_card_hover
var _drop_preview_targets: Array[Control] = [] # panels/cards currently carrying a transient drop-preview override (see set_drop_preview)
## DESIGN.md §9's "Placement snap" tween (see [method animate_placement]) --
## a SINGLE reference is enough: every rebuild ([method _clear]) kills
## whatever is here first (a fresh card can only ever get its OWN new
## tween), and only one placement can be settling at a time per control.
var _placement_tween: Tween = null


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS


func configure(p_model: InventoryPresentationModel, p_inventory_id: int, p_container_id: int,
		p_grid_width: int, p_grid_height: int, p_tokens: InventoryDesignTokens, p_footprint_lookup: Dictionary = {}) -> void:
	if model != null and model.model_changed.is_connected(_on_model_changed):
		model.model_changed.disconnect(_on_model_changed)
	model = p_model
	inventory_id = p_inventory_id
	container_id = p_container_id
	grid_width = maxi(p_grid_width, 0)
	grid_height = maxi(p_grid_height, 0)
	tokens = p_tokens if p_tokens != null else InventoryDesignTokens.new()
	footprint_lookup = p_footprint_lookup
	if model != null:
		model.model_changed.connect(_on_model_changed)
	_rebuild()


func cell_count() -> int:
	return _cell_panels.size()


func card_count() -> int:
	return _cards.size()


func card_for_item(item_id: int) -> InventoryItemCard:
	return _cards.get(item_id, null)


## Public accessor for the empty-cell [Panel] at [param x], [param y] --
## `null` if out of bounds or the cell has not been built (e.g. a
## loading/inaccessible placeholder state). Used by [InventoryInteractionController]'s
## host for pixel-position ghost placement and by [method set_drop_preview].
func cell_panel_at(x: int, y: int) -> Control:
	return _cell_panels.get("%d,%d" % [x, y], null)


## Touch-safe/keyboard focus (tasks.md 8.6): every rendered cell/card is
## focusable so a host's [InventoryInteractionController] can move Godot's own
## focus alongside its own deterministic selection (screen readers and
## platform accessibility tooling key off [member Control.focus_mode]/
## [method Control.grab_focus], not just this addon's own selection state).
func focus_item(item_id: int) -> bool:
	var card: InventoryItemCard = _cards.get(item_id, null)
	if card == null:
		return false
	card.grab_focus()
	return true


## Applies the DESIGN.md §12.2/§12.1 `drop-*` preview state to every cell in
## the [param origin]..[param origin]+[param span] footprint (clamped to this
## grid's bounds): a free cell gets the state directly; a cell covered by an
## existing item's card gets it on that card instead (each card touched only
## once even if its footprint spans more than one covered cell). Purely a
## transient VIEW overlay -- never touches [member InventoryPresentationModel]
## and is cleared by [method clear_drop_preview] or the next [method _rebuild].
func set_drop_preview(origin: Vector2i, span: Vector2i, state: StringName) -> void:
	clear_drop_preview()
	var stylebox_name := InventoryThemeFactory.state_stylebox_name(state)
	var touched_cards: Dictionary = {} # int item_id -> true, de-dupes multi-cell overlap.
	for y in range(origin.y, origin.y + maxi(span.y, 1)):
		for x in range(origin.x, origin.x + maxi(span.x, 1)):
			if x < 0 or y < 0 or x >= grid_width or y >= grid_height:
				continue
			var covering_card := _card_covering(x, y)
			if covering_card != null:
				if touched_cards.has(covering_card.item_id):
					continue
				touched_cards[covering_card.item_id] = true
				_apply_drop_preview_stylebox(covering_card, stylebox_name, InventoryThemeFactory.TYPE_ITEM_CARD)
				continue
			var cell: Control = _cell_panels.get("%d,%d" % [x, y], null)
			if cell != null:
				_apply_drop_preview_stylebox(cell, stylebox_name, InventoryThemeFactory.TYPE_GRID_CELL)


func clear_drop_preview() -> void:
	for control in _drop_preview_targets:
		_clear_one_drop_preview_target(control)
	_drop_preview_targets.clear()


func _clear_one_drop_preview_target(control: Control) -> void:
	if not is_instance_valid(control):
		return
	if control is InventoryItemCard:
		(control as InventoryItemCard).clear_drop_preview_stylebox()
	else:
		control.remove_theme_stylebox_override(&"panel")


## DESIGN.md §9's "Placement snap" motion: on an ACCEPTED drop that settles
## [param item_id] into one of THIS grid's cells (see
## [InventoryTwoPaneView._prepare_placement_animation]/[method
## InventoryTwoPaneView._finish_placement_animation], the only caller),
## tweens its ALREADY-REBUILT card's position from [param from_position] (the
## drop-release point, in this control's own local space) to the position
## [method _build_cards] already placed it at, over `duration_base` /
## `ease_emphasized_decelerate` (§3.8) -- a no-op if [param item_id] has no
## rendered card (e.g. it was merged away and no longer exists as its own
## item).
##
## [member InventoryDesignTokens.reduced_motion_enabled]: no interpolation --
## the card stays at its already-final position and instead gets a static
## border-emphasis hold (the same `accepted-flash` state stylebox [method
## set_drop_preview] uses for other states, applied here via the SAME [method
## _apply_drop_preview_stylebox] mechanism) for `duration_slow`, exactly
## DESIGN.md §9's reduced-motion row for this element ("Instant placement; a
## static border-emphasis hold ... replaces the tween").
##
## Kill-safe: any tween from a PRIOR call is killed before starting a new one
## (a second accepted drop landing mid-tween must not fight the first), and
## [method _clear] (every [signal InventoryPresentationModel.model_changed]
## rebuild, including the one that destroys the very card a tween targets)
## kills it too, so a stale tween never touches a freed [InventoryItemCard].
func animate_placement(item_id: int, from_position: Vector2) -> void:
	var card: InventoryItemCard = _cards.get(item_id, null)
	if card == null:
		return
	_kill_placement_tween()
	var final_position := card.position

	if tokens != null and tokens.reduced_motion_enabled:
		card.position = final_position
		_apply_drop_preview_stylebox(card, InventoryThemeFactory.state_stylebox_name(InventoryPresentationModel.STATE_ACCEPTED), InventoryThemeFactory.TYPE_ITEM_CARD)
		_placement_tween = create_tween()
		_placement_tween.tween_interval(tokens.duration_ms(&"slow") / 1000.0)
		_placement_tween.finished.connect(_on_placement_hold_finished.bind(card))
		return

	card.position = from_position
	_placement_tween = create_tween()
	_placement_tween.set_trans(tokens.ease_emphasized_decelerate_transition)
	_placement_tween.set_ease(tokens.ease_emphasized_decelerate_type)
	_placement_tween.tween_property(card, "position", final_position, tokens.duration_ms(&"base") / 1000.0)


## Test/inspection accessor -- the live placement tween (if any), so a
## headless check can [method Tween.custom_step] it without waiting on real
## frames.
func placement_tween() -> Tween:
	return _placement_tween


func _kill_placement_tween() -> void:
	if _placement_tween != null and _placement_tween.is_valid():
		_placement_tween.kill()
	_placement_tween = null


## The reduced-motion hold's own cleanup -- unlike [method clear_drop_preview]
## (a blanket sweep of EVERY currently-tracked preview target) this clears
## and untracks ONLY [param card], so an unrelated drop-preview that happens
## to start on a different cell/card during the hold's [code]duration_slow[/code]
## window is never touched.
func _on_placement_hold_finished(card: Control) -> void:
	_clear_one_drop_preview_target(card)
	_drop_preview_targets.erase(card)


## A covering card's override must land on ITS OWN internal background Panel,
## not this outer [InventoryItemCard] control (which never draws a "panel"
## StyleBox itself) -- see [method InventoryItemCard.set_drop_preview_stylebox]'s
## doc comment; this was previously landing on the outer control and was
## therefore silently inert for every occupied-cell preview (docs/inventory/
## visual-qa-2026-07-27.md finding 2 / its set_drop_preview item).
func _apply_drop_preview_stylebox(control: Control, stylebox_name: StringName, type_name: StringName) -> void:
	var stylebox := control.get_theme_stylebox(stylebox_name, type_name)
	if stylebox == null:
		return
	if control is InventoryItemCard:
		(control as InventoryItemCard).set_drop_preview_stylebox(stylebox)
	else:
		control.add_theme_stylebox_override(&"panel", stylebox)
	_drop_preview_targets.append(control)


func _card_covering(x: int, y: int) -> InventoryItemCard:
	for item_id in _card_origins:
		var origin: Vector2i = _card_origins[item_id]
		var card: InventoryItemCard = _cards.get(item_id, null)
		if card == null:
			continue
		var cell_px := tokens.grid_cell_px() if tokens != null else 1.0
		var span := Vector2i(maxi(int(round(card.size.x / cell_px)), 1), maxi(int(round(card.size.y / cell_px)), 1))
		if x >= origin.x and x < origin.x + span.x and y >= origin.y and y < origin.y + span.y:
			return card
	return null


func _on_model_changed() -> void:
	_rebuild()


func _clear() -> void:
	# MUST precede freeing the children below -- a live placement tween
	# targets a card this loop is about to `queue_free()`; killing it first
	# (this file's own "kill-safe on control teardown" contract, [method
	# animate_placement]'s doc comment) means it never gets a chance to step
	# a freed object.
	_kill_placement_tween()
	for child in get_children():
		remove_child(child)
		child.queue_free()
	_cell_panels.clear()
	_selection_overlays.clear()
	_cards.clear()
	_card_origins.clear()
	_drop_preview_targets.clear()


func _rebuild() -> void:
	_clear()
	if model == null:
		return
	var cell_px := tokens.grid_cell_px()

	var state := model.container_state(inventory_id, container_id)
	if state == InventoryPresentationModel.STATE_LOADING or state == InventoryPresentationModel.STATE_INACCESSIBLE \
			or state == InventoryPresentationModel.STATE_DISCONNECTED or state == InventoryPresentationModel.STATE_RESYNCHRONIZING:
		custom_minimum_size = Vector2(cell_px * maxi(grid_width, 1), cell_px * maxi(grid_height, 1))
		_render_placeholder(state)
		return

	custom_minimum_size = Vector2(cell_px * grid_width, cell_px * grid_height)
	_build_cells(cell_px)
	_build_cards(cell_px)


func _render_placeholder(state: StringName) -> void:
	var label := Label.new()
	label.name = "ContainerPlaceholder"
	label.text = String(state)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(label)


func _build_cells(cell_px: float) -> void:
	for y in range(grid_height):
		for x in range(grid_width):
			var cell := Panel.new()
			cell.name = "Cell_%d_%d" % [x, y]
			cell.theme_type_variation = InventoryThemeFactory.TYPE_GRID_CELL
			cell.position = Vector2(x * cell_px, y * cell_px)
			cell.size = Vector2(cell_px, cell_px)
			cell.mouse_filter = Control.MOUSE_FILTER_STOP
			cell.focus_mode = Control.FOCUS_ALL
			var location := {"kind": "spatial", "container": container_id, "x": x, "y": y, "rotated": false}
			cell.mouse_entered.connect(func(): location_hover_entered.emit(container_id, location))
			cell.mouse_exited.connect(func(): location_hover_exited.emit(container_id, location))
			cell.gui_input.connect(_on_cell_gui_input.bind(location))
			add_child(cell)
			_cell_panels["%d,%d" % [x, y]] = cell

			var overlay := InventorySelectionOverlay.new()
			overlay.position = cell.position
			overlay.size = cell.size
			add_child(overlay)
			overlay.refresh(false, InventoryThemeFactory.TYPE_GRID_CELL)
			_selection_overlays["%d,%d" % [x, y]] = overlay


func _build_cards(cell_px: float) -> void:
	var snapshot := model.get_snapshot(inventory_id)
	if snapshot == null:
		return
	var items: Array = snapshot.get_items()
	var sorted_items := items.duplicate()
	sorted_items.sort_custom(func(a, b): return int((a as Dictionary).get("id", 0)) < int((b as Dictionary).get("id", 0)))

	for item_variant in sorted_items:
		var item: Dictionary = item_variant
		var location: Dictionary = item.get("location", {})
		if int(location.get("container", -1)) != container_id:
			continue
		if String(location.get("kind", "")) != "spatial":
			continue

		var item_id := int(item.get("id", 0))
		var card := InventoryItemCard.new()
		# add_child() BEFORE configure(): configure() -> _refresh() ->
		# _apply_state_style() resolves this card's per-state StyleBox via
		# get_theme_stylebox(), which cascades up the CanvasItem parent chain
		# to find this control's own assigned `theme` -- that cascade only
		# works once the card is actually inside the tree. Configuring first
		# would silently resolve against the engine's default Theme instead
		# (every state looking identical), not this addon's InventoryTheme.
		add_child(card)
		card.configure(model, inventory_id, item, tokens)
		card.focus_mode = Control.FOCUS_ALL
		card.pressed.connect(_on_card_pressed)
		card.released.connect(_on_card_released)
		card.double_clicked.connect(_on_card_double_clicked)
		card.context_requested.connect(_on_card_context_requested)

		var identifier := String(item.get("item_definition_identifier", ""))
		var footprint: Vector2i = footprint_lookup.get(identifier, Vector2i(1, 1))
		var rotated := bool(location.get("rotated", false))
		var span := Vector2i(footprint.y, footprint.x) if rotated else footprint

		var x := int(location.get("x", 0))
		var y := int(location.get("y", 0))
		card.position = Vector2(x * cell_px, y * cell_px)
		card.size = Vector2(cell_px * maxi(span.x, 1), cell_px * maxi(span.y, 1))
		_cards[item_id] = card
		_card_origins[item_id] = Vector2i(x, y)

		var card_location := {"kind": "spatial", "container": container_id, "x": x, "y": y, "rotated": rotated}
		card.mouse_entered.connect(func(): location_hover_entered.emit(container_id, card_location))
		card.mouse_exited.connect(func(): location_hover_exited.emit(container_id, card_location))

		if model.is_selected(inventory_id, item_id):
			var overlay := InventorySelectionOverlay.new()
			overlay.position = card.position
			overlay.size = card.size
			add_child(overlay)
			overlay.refresh(true, InventoryThemeFactory.TYPE_ITEM_CARD)


func _on_card_pressed(item_id: int) -> void:
	model.select(inventory_id, item_id)
	intent_requested.emit(&"select", {"inventory_id": inventory_id, "item_id": item_id})


func _on_card_context_requested(item_id: int, anchor_global_position: Vector2) -> void:
	intent_requested.emit(&"context", {
		"inventory_id": inventory_id,
		"item_id": item_id,
		"anchor_global_position": anchor_global_position,
	})


## Tasks.md 8.5's double-click-to-open affordance -- purely forwards the raw
## interaction (this control does no opening/navigation itself, same "who
## owns interaction policy" split as every other intent here); the host
## resolves whether [param item_id] actually provides an openable container.
func _on_card_double_clicked(item_id: int) -> void:
	intent_requested.emit(&"open", {"inventory_id": inventory_id, "item_id": item_id})


func _on_card_released(item_id: int) -> void:
	var origin: Vector2i = _card_origins.get(item_id, Vector2i(-1, -1))
	if origin.x < 0:
		return
	var snapshot := model.get_snapshot(inventory_id) if model != null else null
	var actual_rotated := false
	if snapshot != null:
		for item_variant in snapshot.get_items():
			var item: Dictionary = item_variant
			if int(item.get("id", 0)) == item_id:
				actual_rotated = bool((item.get("location", {}) as Dictionary).get("rotated", false))
				break
	location_pointer_up.emit(container_id, {"kind": "spatial", "container": container_id, "x": origin.x, "y": origin.y, "rotated": actual_rotated})


func _on_cell_gui_input(event: InputEvent, location: Dictionary) -> void:
	var mb := event as InputEventMouseButton
	if mb != null and mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed:
		location_pointer_up.emit(container_id, location)
