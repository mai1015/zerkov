class_name InventoryItemDetails
extends VBoxContainer

## Accessible, persistent content for the Inspect action (DESIGN.md §12.6).
## Unlike [InventoryTooltip], this control is intended to live inside a
## focus-trapping host such as [InventoryModal] or a CommonUI modal screen.
## It resolves presentation-only name/description/icon data through
## [InventoryPresentationModel.item_presentation] and combines it with the
## canonical snapshot fields supplied in [param item]. It never queries or
## mutates authority state.

signal close_requested

var tokens: InventoryDesignTokens

var _summary_row: HBoxContainer
var _icon: TextureRect
var _summary: VBoxContainer
var _category_label: Label
var _description_label: Label
var _stats: GridContainer
var _quantity_value: Label
var _mass_value: Label
var _footprint_value: Label
var _location_value: Label
var _state_value: Label
var _identifier_value: Label
var _close_button: Button
var _display_name: String = ""


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build_children()


func _build_children() -> void:
	_summary_row = HBoxContainer.new()
	_summary_row.name = "Summary"
	add_child(_summary_row)

	_icon = TextureRect.new()
	_icon.name = "Icon"
	_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_summary_row.add_child(_icon)

	_summary = VBoxContainer.new()
	_summary.name = "Copy"
	_summary.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_summary_row.add_child(_summary)

	_category_label = Label.new()
	_category_label.name = "Category"
	_category_label.clip_text = true
	_category_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_summary.add_child(_category_label)

	_description_label = Label.new()
	_description_label.name = "Description"
	_description_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_description_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_summary.add_child(_description_label)

	_stats = GridContainer.new()
	_stats.name = "Stats"
	_stats.columns = 2
	add_child(_stats)

	_quantity_value = _add_stat_row("Quantity", "QuantityValue")
	_mass_value = _add_stat_row("Mass", "MassValue")
	_footprint_value = _add_stat_row("Footprint", "FootprintValue")
	_location_value = _add_stat_row("Location", "LocationValue")
	_state_value = _add_stat_row("State", "StateValue")
	_identifier_value = _add_stat_row("Definition", "IdentifierValue")

	var actions := HBoxContainer.new()
	actions.name = "Actions"
	actions.alignment = BoxContainer.ALIGNMENT_END
	add_child(actions)

	_close_button = Button.new()
	_close_button.name = "CloseButton"
	_close_button.text = "Close"
	_close_button.focus_mode = Control.FOCUS_ALL
	_close_button.pressed.connect(func() -> void: close_requested.emit())
	actions.add_child(_close_button)


func _add_stat_row(label_text: String, value_name: String) -> Label:
	var label := Label.new()
	label.text = label_text
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stats.add_child(label)

	var value := Label.new()
	value.name = value_name
	value.clip_text = true
	value.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	value.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_stats.add_child(value)
	return value


## [param item] is one entry from
## [method InventorySnapshotResource.get_items], optionally augmented with
## the controller's resolved `"state"` field.
func populate(model: InventoryPresentationModel, inventory_id: int,
		item: Dictionary, footprint_lookup: Dictionary = {},
		mass_lookup: Dictionary = {},
		p_tokens: InventoryDesignTokens = null) -> void:
	tokens = p_tokens if p_tokens != null else InventoryDesignTokens.new()
	custom_minimum_size = Vector2(tokens.unit(38.0), tokens.unit(20.0))
	_icon.custom_minimum_size = Vector2(tokens.unit(10.0), tokens.unit(10.0))
	# Give the wrapping description a real width before Containers ask it for
	# a minimum height. With a zero-width first layout pass, Godot wraps
	# nearly every glyph onto its own line and can inflate the modal far past
	# the viewport before the outer minimum width is applied.
	_summary.custom_minimum_size.x = tokens.unit(24.0)
	_description_label.custom_minimum_size.x = tokens.unit(24.0)
	_description_label.size.x = tokens.unit(24.0)
	_close_button.custom_minimum_size.y = tokens.unit(6.0)

	var identifier := String(item.get("item_definition_identifier", ""))
	var presentation := model.item_presentation(StringName(identifier)) \
			if model != null else {}
	_display_name = String(presentation.get("display_name", identifier))
	var category := String(presentation.get("category", "unknown"))
	_category_label.text = category.replace("_", " ").to_upper()
	_category_label.tooltip_text = category
	var description := String(presentation.get("description", ""))
	_description_label.text = description if not description.is_empty() \
			else "No additional description is available."

	_icon.texture = presentation.get("icon", null) as Texture2D
	_icon.visible = _icon.texture != null

	var quantity := maxi(int(item.get("quantity", 1)), 1)
	_quantity_value.text = str(quantity)

	var unit_mass_mg := int(mass_lookup.get(identifier, 0))
	_mass_value.text = _mass_text(unit_mass_mg, quantity)

	var footprint: Vector2i = footprint_lookup.get(identifier, Vector2i.ONE)
	var location: Dictionary = item.get("location", {})
	var rotated := bool(location.get("rotated", false))
	var oriented := Vector2i(footprint.y, footprint.x) if rotated else footprint
	_footprint_value.text = "%d × %d cells%s" % [
		maxi(oriented.x, 1), maxi(oriented.y, 1),
		" · Rotated" if rotated else "",
	]
	_location_value.text = _location_text(location)
	_state_value.text = _state_text(
			StringName(item.get("state",
					model.item_state(inventory_id, int(item.get("id", 0)))
					if model != null else InventoryPresentationModel.STATE_NORMAL)))
	_identifier_value.text = identifier
	_identifier_value.tooltip_text = identifier


func _mass_text(unit_mass_mg: int, quantity: int) -> String:
	if unit_mass_mg <= 0:
		return "Unknown"
	var total := unit_mass_mg * quantity
	if quantity > 1:
		return "%d mg total · %d mg each" % [total, unit_mass_mg]
	return "%d mg" % total


func _location_text(location: Dictionary) -> String:
	match String(location.get("kind", "")):
		"spatial":
			return "Grid · row %d, column %d" % [
				int(location.get("y", 0)) + 1,
				int(location.get("x", 0)) + 1,
			]
		"slot":
			return "Slot · %s" % String(location.get("slot", ""))
		"list":
			return "List · position %d" % (int(location.get("ordinal", 0)) + 1)
		_:
			return "Unplaced"


func _state_text(state: StringName) -> String:
	var value := String(state).trim_prefix("inventory.state.")
	return value.replace("_", " ").replace("-", " ").capitalize()


func display_name() -> String:
	return _display_name


func close_button() -> Button:
	return _close_button


func quantity_text() -> String:
	return _quantity_value.text


func mass_text() -> String:
	return _mass_value.text


func footprint_text() -> String:
	return _footprint_value.text


func description_text() -> String:
	return _description_label.text
