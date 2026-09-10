class_name InventoryNamedSlotsControl
extends Control

## Ownership-layout renderer for `NAMED_SLOTS` containers (tasks.md 8.3;
## DESIGN.md §6.2 filter-icon-hint rule, §12.3). Same script-only-[Control]
## authoring choice as [InventorySpatialGridControl] (see its header comment).
##
## The declared slot list (identifiers, and each slot's filter-hint text --
## [InventoryNamedSlot]'s `required_traits`/`filter_hint`-style authoring
## data) is catalog-side, not part of the snapshot DTO, exactly like
## [InventorySpatialGridControl]'s grid dimensions -- the host supplies it to
## [method configure].

signal intent_requested(kind: StringName, args: Dictionary)
## See [InventorySpatialGridControl]'s identical signals' doc comment
## (tasks.md 8.5 drag/drop wiring).
signal location_hover_entered(container_id: int, location: Dictionary)
signal location_hover_exited(container_id: int, location: Dictionary)
signal location_pointer_up(container_id: int, location: Dictionary)

var model: InventoryPresentationModel
var tokens: InventoryDesignTokens
var inventory_id: int = 0
var container_id: int = 0
## [code]Array[Dictionary{identifier: String, filter_hint: String (optional,
## shown as the empty-slot watermark per DESIGN.md §6.2)}][/code], in
## declared (authoring) order -- this control never reorders slots.
var slot_defs: Array = []

var _slot_panels: Dictionary = {} # String identifier -> Panel
var _watermarks: Dictionary = {} # String identifier -> Label
var _selection_overlays: Dictionary = {} # String identifier -> InventorySelectionOverlay
var _cards: Dictionary = {} # int item_id -> InventoryItemCard
var _card_slot_identifiers: Dictionary = {} # int item_id -> String slot identifier
var _drop_preview_targets: Array[Control] = []


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS


func configure(p_model: InventoryPresentationModel, p_inventory_id: int, p_container_id: int,
		p_slot_defs: Array, p_tokens: InventoryDesignTokens) -> void:
	if model != null and model.model_changed.is_connected(_on_model_changed):
		model.model_changed.disconnect(_on_model_changed)
	model = p_model
	inventory_id = p_inventory_id
	container_id = p_container_id
	slot_defs = p_slot_defs.duplicate(true)
	tokens = p_tokens if p_tokens != null else InventoryDesignTokens.new()
	if model != null:
		model.model_changed.connect(_on_model_changed)
	_rebuild()


func slot_count() -> int:
	return _slot_panels.size()


func card_count() -> int:
	return _cards.size()


func card_for_item(item_id: int) -> InventoryItemCard:
	return _cards.get(item_id, null)


## Public accessor for the (possibly empty) slot [Panel] named [param identifier]
## -- `null` if that identifier isn't declared or hasn't been built. See
## [method InventorySpatialGridControl.cell_panel_at]'s identical rationale.
func slot_panel_for(identifier: String) -> Control:
	return _slot_panels.get(identifier, null)


func focus_slot(identifier: String) -> bool:
	var card_item_id := -1
	for item_id in _card_slot_identifiers:
		if String(_card_slot_identifiers[item_id]) == identifier:
			card_item_id = item_id
			break
	if card_item_id >= 0:
		var card: InventoryItemCard = _cards.get(card_item_id, null)
		if card != null:
			card.grab_focus()
			return true
	var panel: Control = _slot_panels.get(identifier, null)
	if panel != null:
		panel.grab_focus()
		return true
	return false


## DESIGN.md §12.3 `drop-*` preview on the single slot named [param identifier]
## -- the occupying card if present, else the empty slot panel itself. See
## [method InventorySpatialGridControl.set_drop_preview]'s identical contract.
func set_drop_preview(identifier: String, state: StringName) -> void:
	clear_drop_preview()
	var stylebox_name := InventoryThemeFactory.state_stylebox_name(state)
	for item_id in _card_slot_identifiers:
		if String(_card_slot_identifiers[item_id]) != identifier:
			continue
		var card: InventoryItemCard = _cards.get(item_id, null)
		if card != null:
			_apply_drop_preview_stylebox(card, stylebox_name, InventoryThemeFactory.TYPE_ITEM_CARD)
		return
	var panel: Control = _slot_panels.get(identifier, null)
	if panel != null:
		_apply_drop_preview_stylebox(panel, stylebox_name, InventoryThemeFactory.TYPE_SLOT)


func clear_drop_preview() -> void:
	for control in _drop_preview_targets:
		if not is_instance_valid(control):
			continue
		if control is InventoryItemCard:
			(control as InventoryItemCard).clear_drop_preview_stylebox()
		else:
			control.remove_theme_stylebox_override(&"panel")
	_drop_preview_targets.clear()


## See [InventorySpatialGridControl._apply_drop_preview_stylebox]'s identical
## doc comment -- an occupying card's override must land on its own internal
## background Panel, not this outer control (previously inert; docs/inventory/
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


func _on_model_changed() -> void:
	_rebuild()


func _clear() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()
	_slot_panels.clear()
	_watermarks.clear()
	_selection_overlays.clear()
	_cards.clear()
	_card_slot_identifiers.clear()
	_drop_preview_targets.clear()


func _rebuild() -> void:
	_clear()
	if model == null:
		return
	var cell_px := tokens.grid_cell_px()

	var state := model.container_state(inventory_id, container_id)
	if state == InventoryPresentationModel.STATE_LOADING or state == InventoryPresentationModel.STATE_INACCESSIBLE \
			or state == InventoryPresentationModel.STATE_DISCONNECTED or state == InventoryPresentationModel.STATE_RESYNCHRONIZING:
		custom_minimum_size = Vector2(cell_px * maxf(slot_defs.size(), 1.0), cell_px)
		_render_placeholder(state)
		return

	custom_minimum_size = Vector2(cell_px * slot_defs.size(), cell_px)

	var snapshot := model.get_snapshot(inventory_id)
	var items: Array = snapshot.get_items() if snapshot != null else []

	for index in range(slot_defs.size()):
		var slot: Dictionary = slot_defs[index]
		var identifier := String(slot.get("identifier", ""))
		var slot_position := Vector2(cell_px * index, 0.0)

		var panel := Panel.new()
		panel.name = "Slot_%s" % identifier
		panel.theme_type_variation = InventoryThemeFactory.TYPE_SLOT
		panel.position = slot_position
		panel.size = Vector2(cell_px, cell_px)
		panel.mouse_filter = Control.MOUSE_FILTER_STOP
		panel.focus_mode = Control.FOCUS_ALL
		var slot_location := {"kind": "slot", "container": container_id, "slot_identifier": identifier}
		panel.mouse_entered.connect(func(): location_hover_entered.emit(container_id, slot_location))
		panel.mouse_exited.connect(func(): location_hover_exited.emit(container_id, slot_location))
		panel.gui_input.connect(_on_slot_gui_input.bind(slot_location))
		add_child(panel)
		_slot_panels[identifier] = panel

		var watermark := Label.new()
		watermark.name = "Watermark_%s" % identifier
		watermark.text = String(slot.get("filter_hint", identifier))
		watermark.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		watermark.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		watermark.position = slot_position
		watermark.size = Vector2(cell_px, cell_px)
		watermark.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(watermark)
		_watermarks[identifier] = watermark

		var occupying_item := _find_item_in_slot(items, identifier)
		watermark.visible = occupying_item.is_empty()
		if occupying_item.is_empty():
			continue

		var item_id := int(occupying_item.get("id", 0))
		var card := InventoryItemCard.new()
		# add_child() BEFORE configure() -- see InventorySpatialGridControl's
		# identical comment: theme resolution needs the card inside the tree.
		add_child(card)
		card.configure(model, inventory_id, occupying_item, tokens)
		card.focus_mode = Control.FOCUS_ALL
		card.pressed.connect(_on_card_pressed)
		card.released.connect(_on_card_released.bind(identifier))
		card.double_clicked.connect(_on_card_double_clicked)
		card.context_requested.connect(_on_card_context_requested)
		card.position = slot_position
		card.size = Vector2(cell_px, cell_px)
		_cards[item_id] = card
		_card_slot_identifiers[item_id] = identifier
		card.mouse_entered.connect(func(): location_hover_entered.emit(container_id, slot_location))
		card.mouse_exited.connect(func(): location_hover_exited.emit(container_id, slot_location))

		if model.is_selected(inventory_id, item_id):
			var overlay := InventorySelectionOverlay.new()
			overlay.position = slot_position
			overlay.size = Vector2(cell_px, cell_px)
			add_child(overlay)
			overlay.refresh(true, InventoryThemeFactory.TYPE_ITEM_CARD)


func _find_item_in_slot(items: Array, slot_identifier: String) -> Dictionary:
	for item_variant in items:
		var item: Dictionary = item_variant
		var location: Dictionary = item.get("location", {})
		if int(location.get("container", -1)) != container_id:
			continue
		if String(location.get("kind", "")) != "slot":
			continue
		if String(location.get("slot_identifier", "")) == slot_identifier:
			return item
	return {}


func _render_placeholder(state: StringName) -> void:
	var label := Label.new()
	label.name = "ContainerPlaceholder"
	label.text = String(state)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(label)


func _on_card_pressed(item_id: int) -> void:
	model.select(inventory_id, item_id)
	intent_requested.emit(&"select", {"inventory_id": inventory_id, "item_id": item_id})


func _on_card_context_requested(item_id: int, anchor_global_position: Vector2) -> void:
	intent_requested.emit(&"context", {
		"inventory_id": inventory_id,
		"item_id": item_id,
		"anchor_global_position": anchor_global_position,
	})


## See [InventorySpatialGridControl._on_card_double_clicked]'s identical doc
## comment (tasks.md 8.5's double-click-to-open affordance).
func _on_card_double_clicked(item_id: int) -> void:
	intent_requested.emit(&"open", {"inventory_id": inventory_id, "item_id": item_id})


func _on_card_released(item_id: int, identifier: String) -> void:
	location_pointer_up.emit(container_id, {"kind": "slot", "container": container_id, "slot_identifier": identifier})


func _on_slot_gui_input(event: InputEvent, location: Dictionary) -> void:
	var mb := event as InputEventMouseButton
	if mb != null and mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed:
		location_pointer_up.emit(container_id, location)
