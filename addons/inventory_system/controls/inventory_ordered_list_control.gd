class_name InventoryOrderedListControl
extends Control

## Ownership-layout renderer for `ORDERED_LIST` containers (tasks.md 8.3;
## DESIGN.md §12.4). Same script-only-[Control] authoring choice as
## [InventorySpatialGridControl] (see its header comment).
##
## Unlike the spatial-grid/named-slots renderers, an ordered list needs no
## catalog-side layout data to render correctly: [code]location.ordinal[/code]
## (from the snapshot item Dictionary) is already a complete, dense ordering
## contract on its own (inventory-runtime spec), so [method configure] takes
## nothing beyond [param model]/[param inventory_id]/[param container_id].
## `overflow` (DESIGN.md §12.5's "+N more") is deliberately NOT rendered by
## this control in this wave: it is pure viewport-vs-content geometry that
## belongs to whatever [ScrollContainer] a host wraps this control in
## (tasks.md 8.4 two-pane composition, deferred), matching
## [InventoryPresentationModel.container_state]'s own documented omission of
## an `overflow` token.

signal intent_requested(kind: StringName, args: Dictionary)
## See [InventorySpatialGridControl]'s identical signals' doc comment
## (tasks.md 8.5 drag/drop wiring). `location.ordinal` on a row-sourced event
## is that row's CURRENT ordinal; the trailing append zone (see
## [method _rebuild]) reports `ordinal == row_count()` -- "insert after the
## last row" -- since DESIGN.md §12.4 has no per-row `drop-occupied` concept
## (a list drop is always an insertion, never an occupancy conflict).
signal location_hover_entered(container_id: int, location: Dictionary)
signal location_hover_exited(container_id: int, location: Dictionary)
signal location_pointer_up(container_id: int, location: Dictionary)

var model: InventoryPresentationModel
var tokens: InventoryDesignTokens
var inventory_id: int = 0
var container_id: int = 0

var _row_panels: Dictionary = {} # int item_id -> Panel
var _selection_overlays: Dictionary = {} # int item_id -> InventorySelectionOverlay
var _row_labels: Dictionary = {} # int item_id -> Label
var _row_icons: Dictionary = {} # int item_id -> TextureRect
var _append_zone: Control
var _drop_preview_targets: Array[Control] = []

## Row height, independent of grid-cell sizing (a list row is not a grid
## cell) -- chosen as a comfortable single-line text row at 2u, still a plain
## `unit * N` value.
const ROW_HEIGHT_UNITS := 2.0


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS


func configure(p_model: InventoryPresentationModel, p_inventory_id: int, p_container_id: int, p_tokens: InventoryDesignTokens) -> void:
	if model != null and model.model_changed.is_connected(_on_model_changed):
		model.model_changed.disconnect(_on_model_changed)
	model = p_model
	inventory_id = p_inventory_id
	container_id = p_container_id
	tokens = p_tokens if p_tokens != null else InventoryDesignTokens.new()
	if model != null:
		model.model_changed.connect(_on_model_changed)
	_rebuild()


func row_count() -> int:
	return _row_panels.size()


## Public accessor for the row [Panel] currently rendering [param item_id] --
## `null` if that item isn't rendered by this control right now. See
## [method InventorySpatialGridControl.cell_panel_at]'s identical rationale.
func row_panel_for(item_id: int) -> Control:
	return _row_panels.get(item_id, null)


## The drawn state-icon [Texture2D] currently shown on [param item_id]'s row
## (`null` if that item isn't rendered right now, or its state has no icon at
## all, e.g. `normal`/`selected`) -- test/inspection accessor proving a real
## texture renders, not raw glyph-token text (visual-qa-2026-07-27.md finding
## 1).
func row_state_icon_texture(item_id: int) -> Texture2D:
	var icon: TextureRect = _row_icons.get(item_id, null)
	return icon.texture if icon != null else null


func focus_row(item_id: int) -> bool:
	var panel: Control = _row_panels.get(item_id, null)
	if panel == null:
		return false
	panel.grab_focus()
	return true


## DESIGN.md §12.4 `drop-valid`/etc. preview: an existing row (styled as an
## insertion-line indicator per §12.4's own "drop-valid: positive top/bottom
## insertion line" row -- approximated here, like every other state in this
## wave, by the row's own per-state StyleBox rather than a literal drawn
## line) or the trailing append zone when [param item_id] is `0`.
func set_drop_preview(item_id: int, state: StringName) -> void:
	clear_drop_preview()
	var stylebox_name := InventoryThemeFactory.state_stylebox_name(state)
	var target: Control = _row_panels.get(item_id, null) if item_id != 0 else _append_zone
	if target == null:
		return
	var stylebox := target.get_theme_stylebox(stylebox_name, InventoryThemeFactory.TYPE_LIST_ROW)
	if stylebox == null:
		return
	target.add_theme_stylebox_override(&"panel", stylebox)
	_drop_preview_targets.append(target)


func clear_drop_preview() -> void:
	for control in _drop_preview_targets:
		if is_instance_valid(control):
			control.remove_theme_stylebox_override(&"panel")
	_drop_preview_targets.clear()


func _on_model_changed() -> void:
	_rebuild()


func _clear() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()
	_row_panels.clear()
	_selection_overlays.clear()
	_row_labels.clear()
	_row_icons.clear()
	_append_zone = null
	_drop_preview_targets.clear()


func _rebuild() -> void:
	_clear()
	if model == null:
		return
	var row_height := tokens.unit(ROW_HEIGHT_UNITS)
	var row_width := tokens.unit(12.0) # A reasonable default content width; a host normally stretches this control to its own container width via layout anchors instead.

	var state := model.container_state(inventory_id, container_id)
	if state == InventoryPresentationModel.STATE_LOADING or state == InventoryPresentationModel.STATE_INACCESSIBLE \
			or state == InventoryPresentationModel.STATE_DISCONNECTED or state == InventoryPresentationModel.STATE_RESYNCHRONIZING:
		custom_minimum_size = Vector2(row_width, row_height)
		_render_placeholder(state, row_width, row_height)
		return

	var snapshot := model.get_snapshot(inventory_id)
	var items: Array = snapshot.get_items() if snapshot != null else []
	var rows: Array = []
	for item_variant in items:
		var item: Dictionary = item_variant
		var location: Dictionary = item.get("location", {})
		if int(location.get("container", -1)) != container_id:
			continue
		if String(location.get("kind", "")) != "list":
			continue
		rows.append(item)
	rows.sort_custom(func(a, b):
		var loc_a: Dictionary = (a as Dictionary).get("location", {})
		var loc_b: Dictionary = (b as Dictionary).get("location", {})
		return int(loc_a.get("ordinal", 0)) < int(loc_b.get("ordinal", 0)))

	custom_minimum_size = Vector2(row_width, row_height * (maxi(rows.size(), 1) + 1)) # +1 row for the trailing append zone.

	for index in range(rows.size()):
		var item: Dictionary = rows[index]
		var item_id := int(item.get("id", 0))
		var row_position := Vector2(0.0, row_height * index)

		var panel := Panel.new()
		panel.name = "Row_%d" % item_id
		panel.theme_type_variation = InventoryThemeFactory.TYPE_LIST_ROW
		panel.position = row_position
		panel.size = Vector2(row_width, row_height)
		panel.mouse_filter = Control.MOUSE_FILTER_STOP
		panel.focus_mode = Control.FOCUS_ALL
		var row_location := {"kind": "list", "container": container_id, "ordinal": index}
		panel.mouse_entered.connect(func(): location_hover_entered.emit(container_id, row_location))
		panel.mouse_exited.connect(func(): location_hover_exited.emit(container_id, row_location))
		add_child(panel)
		_row_panels[item_id] = panel

		# DESIGN.md §10.3: `clip_text`/`text_overrun_behavior` just below must
		# be set BEFORE this label's `.size =` further down -- they stop the
		# label's intrinsic (full, untruncated) text width from feeding
		# `get_minimum_size()`; without that, Godot's own `Control.size`
		# setter clamps size back UP to the intrinsic width the moment it's
		# assigned, silently overflowing this row into its neighbors for any
		# identifier longer than the row (visual-qa-2026-07-27.md finding 6,
		# localization sheet row c). The full untruncated string stays
		# reachable via native [member Control.tooltip_text] on `panel`
		# (set below) -- the real [InventoryTooltip] popup's hover wiring is
		# an [InventoryTwoPaneView] (host) concern out of this change's
		# ownership scope, see this change's own report.

		var row_state := model.item_state(inventory_id, item_id)
		var glyph := InventoryStateGlyphs.glyph_for_item_state(row_state)
		var row_icon_tex := InventoryStateIcons.icon_for(glyph)

		# DESIGN.md §7/§11.2/finding 1: a drawn icon in a fixed leading slot,
		# never the raw glyph token baked into the row's text (a bracketed
		# `"[%s] "` token prefix used to render literally here).
		var icon_size := tokens.unit(1.0)
		var icon_margin := tokens.unit(0.5) # also the vertical centering offset: row_height(2u) - icon_size(1u), halved, = 0.5u exactly.
		var icon_rect := TextureRect.new()
		icon_rect.name = "RowStateIcon_%d" % item_id
		icon_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon_rect.texture = row_icon_tex
		icon_rect.visible = row_icon_tex != null
		if row_icon_tex != null:
			icon_rect.modulate = InventoryThemeFactory.state_icon_color(row_state)
		icon_rect.position = row_position + Vector2(icon_margin, icon_margin)
		icon_rect.size = Vector2(icon_size, icon_size)
		add_child(icon_rect)
		_row_icons[item_id] = icon_rect

		var state_label := Label.new()
		state_label.name = "RowStateOverlay_%d" % item_id
		state_label.clip_text = true
		state_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		var identifier := String(item.get("item_definition_identifier", ""))
		var quantity := int(item.get("quantity", 1))
		var text := "%s  x%d" % [identifier, quantity]
		# DESIGN.md §11.2's short human-readable Text column, where this row's
		# state names one (icon-only states, e.g. pending/accepted-flash, add
		# nothing here -- see _row_state_text()'s own doc comment).
		var state_text := _row_state_text(row_state)
		if not state_text.is_empty():
			text = "%s -- %s" % [text, state_text]
		state_label.text = text
		state_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		# Reserve the same leading inset regardless of whether THIS row's
		# state actually has an icon, so the text column stays aligned across
		# rows with mixed icon presence: icon_margin(0.5u) + icon_size(1u) +
		# a small gap(0.25u) = 1.75u.
		var label_inset := tokens.unit(1.75)
		state_label.position = row_position + Vector2(label_inset, 0.0)
		state_label.size = Vector2(row_width - label_inset - tokens.unit(0.5), row_height)
		state_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(state_label)
		_row_labels[item_id] = state_label
		panel.tooltip_text = text

		if model.is_selected(inventory_id, item_id):
			var overlay := InventorySelectionOverlay.new()
			overlay.position = row_position
			overlay.size = Vector2(row_width, row_height)
			add_child(overlay)
			overlay.refresh(true, InventoryThemeFactory.TYPE_LIST_ROW)

		panel.gui_input.connect(_on_row_gui_input.bind(item_id))

	_build_append_zone(row_width, row_height, rows.size())


## A trailing drop target -- "insert after the last row" -- so a list
## container can accept a drop even when it has no rows to drop ONTO yet
## (an empty list, or appending past the current last entry). Never itself
## selectable/pressable (no `select` intent); purely a release/hover target.
func _build_append_zone(row_width: float, row_height: float, row_count: int) -> void:
	var zone := Panel.new()
	zone.name = "AppendZone"
	zone.theme_type_variation = InventoryThemeFactory.TYPE_LIST_ROW
	zone.position = Vector2(0.0, row_height * row_count)
	zone.size = Vector2(row_width, row_height)
	zone.mouse_filter = Control.MOUSE_FILTER_STOP
	zone.focus_mode = Control.FOCUS_ALL
	var zone_location := {"kind": "list", "container": container_id, "ordinal": row_count}
	zone.mouse_entered.connect(func(): location_hover_entered.emit(container_id, zone_location))
	zone.mouse_exited.connect(func(): location_hover_exited.emit(container_id, zone_location))
	zone.gui_input.connect(func(event: InputEvent):
		var mb := event as InputEventMouseButton
		if mb != null and mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed:
			location_pointer_up.emit(container_id, zone_location))
	add_child(zone)
	_append_zone = zone


## DESIGN.md §11.2's short human-readable Text column, for the item-scoped
## states a list row's own state overlay can show (mirrors
## [InventoryItemCard]'s identical private helper -- duplicated rather than
## shared, matching this addon's existing per-primitive convention, e.g.
## [InventoryTooltip]'s own `_state_note` vs [InventoryDragGhost]'s own
## `_glyph_for_drop_state`). "" for a state with no dedicated Text entry
## there (icon-only, e.g. pending/accepted-flash -- pending's own text lives
## on tooltip/inspect per §11.2, not this row).
func _row_state_text(state: StringName) -> String:
	match state:
		InventoryPresentationModel.STATE_REJECTED:
			var rejection := model.get_last_rejection() if model != null else {}
			return "Rejected: %s" % String(rejection.get("reason_token", &""))
		InventoryPresentationModel.STATE_STALE_CORRECTED:
			return "Updated"
		InventoryPresentationModel.STATE_REDACTED:
			return "Redacted"
		InventoryPresentationModel.STATE_READ_ONLY:
			return "Read-only"
		InventoryPresentationModel.STATE_DISCONNECTED:
			return "Disconnected"
		InventoryPresentationModel.STATE_RESYNCHRONIZING:
			return "Resynchronizing"
		_:
			return ""


func _render_placeholder(state: StringName, row_width: float, row_height: float) -> void:
	var label := Label.new()
	label.name = "ContainerPlaceholder"
	label.text = String(state)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.size = Vector2(row_width, row_height)
	add_child(label)


func _on_row_gui_input(event: InputEvent, item_id: int) -> void:
	var mb := event as InputEventMouseButton
	if mb == null:
		return
	if mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
		intent_requested.emit(&"context", {
			"inventory_id": inventory_id,
			"item_id": item_id,
			"anchor_global_position": mb.global_position,
		})
		accept_event()
		return
	if mb.button_index != MOUSE_BUTTON_LEFT:
		return
	if mb.pressed:
		model.select(inventory_id, item_id)
		intent_requested.emit(&"select", {"inventory_id": inventory_id, "item_id": item_id})
		# Tasks.md 8.5's double-click-to-open affordance -- an ordered-list row
		# has no [InventoryItemCard] child of its own to detect this (unlike
		# the spatial-grid/named-slots renderers), so it reads
		# [InputEventMouseButton.double_click] directly here instead of via a
		# card signal; same "forward the raw interaction, host resolves
		# meaning" contract either way.
		if mb.double_click:
			intent_requested.emit(&"open", {"inventory_id": inventory_id, "item_id": item_id})
		return
	var snapshot := model.get_snapshot(inventory_id) if model != null else null
	var ordinal := 0
	if snapshot != null:
		for item_variant in snapshot.get_items():
			var item: Dictionary = item_variant
			if int(item.get("id", 0)) == item_id:
				ordinal = int((item.get("location", {}) as Dictionary).get("ordinal", 0))
				break
	location_pointer_up.emit(container_id, {"kind": "list", "container": container_id, "ordinal": ordinal})
