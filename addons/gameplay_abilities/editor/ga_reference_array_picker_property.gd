class_name GAReferenceArrayPickerProperty
extends EditorProperty

## Packed-array reference picker (tasks.md 2.2 "packed tag properties",
## 2.3's array-valued attribute/effect/cue kinds): shows each currently
## serialized identifier as a removable row, plus an "+ Add" button that
## opens the same [GAPickerPopup] the scalar picker
## ([GAReferencePickerProperty]) uses. Orphan entries (tasks.md 2.4) render
## with their exact original value and [method EditorProperty.set_draw_warning]
## the same way the scalar picker does, and are never dropped from the array
## just because they are unresolved -- only an explicit "x" click removes
## one.

var _kind: String
var _catalog_context: GAActiveCatalogContext
var _rows_box: VBoxContainer
var _add_button: Button
var _popup: GAPickerPopup


func _init(kind: String = "", catalog_context: GAActiveCatalogContext = null) -> void:
	_kind = kind
	_catalog_context = catalog_context

	var vbox := VBoxContainer.new()
	_rows_box = VBoxContainer.new()
	vbox.add_child(_rows_box)

	_add_button = Button.new()
	_add_button.text = "+ Add"
	_add_button.pressed.connect(_open_popup)
	vbox.add_child(_add_button)

	add_child(vbox)
	add_focusable(_add_button)


func _current_catalog() -> Resource:
	return _catalog_context.get_catalog() if _catalog_context != null else null


func _update_property() -> void:
	var object := get_edited_object()
	var property := get_edited_property()
	if object == null:
		return
	var current: PackedStringArray = object.get(property)
	# Same factoring as GAReferencePickerProperty: the orphan decision is a
	# plain static function (GAReferenceRegistry.describe_array_entries) so
	# it stays headlessly testable; this method only paints the result.
	var rows := GAReferenceRegistry.describe_array_entries(_current_catalog(), _kind, current)
	var any_orphan := false

	for child in _rows_box.get_children():
		child.queue_free()

	for i in range(rows.size()):
		var row_info: Dictionary = rows[i]
		var identifier := String(row_info["identifier"])
		var is_orphan := bool(row_info["is_orphan"])
		any_orphan = any_orphan or is_orphan

		var row := HBoxContainer.new()
		var label := Label.new()
		label.text = identifier
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		if is_orphan:
			# Exact original value stays; only the affordance changes
			# (tasks.md 2.4) -- never mutate `current` here.
			label.add_theme_color_override("font_color", Color(0.94, 0.68, 0.2))
			label.tooltip_text = "'%s' was not found in the active catalog." % identifier
		row.add_child(label)

		var remove_button := Button.new()
		remove_button.text = "x"
		remove_button.tooltip_text = "Remove"
		remove_button.pressed.connect(_on_remove_pressed.bind(i))
		row.add_child(remove_button)

		_rows_box.add_child(row)

	# set_draw_warning is per-property (not per-row); surfaced once when any
	# entry in the array is orphaned, same signal the scalar picker gives.
	set_draw_warning(any_orphan)


func _open_popup() -> void:
	var known := GAReferenceRegistry.identifiers_in_catalog(_current_catalog(), _kind)
	if _popup == null:
		_popup = GAPickerPopup.new()
		_popup.identifier_picked.connect(_on_identifier_added)
		add_child(_popup)
	if GAReferenceRegistry.is_hierarchical(_kind):
		_popup.configure_hierarchical(known, false)
	else:
		_popup.configure_flat(known, false)
	_popup.popup_search()


func _on_identifier_added(identifier: String) -> void:
	var object := get_edited_object()
	var property := get_edited_property()
	if object == null:
		return
	var current: PackedStringArray = object.get(property)
	if current.has(identifier):
		# Duplicate selections are reported, not silently added twice
		# (spec.md "duplicate or incompatible selections are reported before
		# save or validation").
		push_warning("GAReferenceArrayPickerProperty: '%s' is already present in '%s'." % [identifier, property])
		return
	var updated := current.duplicate()
	updated.append(identifier)
	emit_changed(property, updated)


func _on_remove_pressed(index: int) -> void:
	var object := get_edited_object()
	var property := get_edited_property()
	if object == null:
		return
	var current: PackedStringArray = object.get(property)
	if index < 0 or index >= current.size():
		return
	var updated := current.duplicate()
	updated.remove_at(index)
	emit_changed(property, updated)
