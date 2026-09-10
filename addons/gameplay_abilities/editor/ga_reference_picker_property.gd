class_name GAReferencePickerProperty
extends EditorProperty

## Scalar reference picker (tasks.md 2.2/2.3): one StringName property backed
## by a [GAReferenceRegistry] reference kind. Hierarchical for
## [constant GAReferenceRegistry.KIND_TAG] (dotted tag identifiers, full
## tree); flat/grouped for every other kind (attribute/effect/ability/cue/
## target-schema).
##
## Orphan handling (tasks.md 2.4, spec.md "Orphan Reference Preservation"):
## if the currently serialized identifier is non-empty and NOT found in the
## active catalog, [method _update_property] shows the EXACT original value
## with [method EditorProperty.set_draw_warning] plus an explanatory tooltip
## -- it never calls [method EditorProperty.emit_changed] itself, so opening
## or refreshing the Inspector can never clear, coerce, or rewrite a stale
## value. Repair only happens through [method _on_identifier_picked]/
## [method _on_clear_pressed], both of which run through
## [method EditorProperty.emit_changed] -- the normal undoable Inspector
## path the base [EditorProperty] class wires into
## [EditorUndoRedoManager] automatically.

var _kind: String
var _catalog_context: GAActiveCatalogContext
var _button: Button
var _clear_button: Button
var _popup: GAPickerPopup


func _init(kind: String = "", catalog_context: GAActiveCatalogContext = null) -> void:
	_kind = kind
	_catalog_context = catalog_context

	var hbox := HBoxContainer.new()
	_button = Button.new()
	_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_button.clip_text = true
	_button.text = "(none)"
	_button.pressed.connect(_open_popup)
	hbox.add_child(_button)

	_clear_button = Button.new()
	_clear_button.text = "x"
	_clear_button.tooltip_text = "Clear"
	_clear_button.pressed.connect(_on_clear_pressed)
	hbox.add_child(_clear_button)

	add_child(hbox)
	add_focusable(_button)


func _current_catalog() -> Resource:
	return _catalog_context.get_catalog() if _catalog_context != null else null


func _update_property() -> void:
	var object := get_edited_object()
	var property := get_edited_property()
	if object == null:
		return
	var value := String(object.get(property))
	# The actual orphan/known/empty DECISION lives in
	# GAReferenceRegistry.describe_scalar_value -- a plain static function --
	# specifically so it stays headlessly testable even though this glue
	# class itself cannot be instantiated outside a running editor (see that
	# method's own doc comment). This method only paints the result.
	var description := GAReferenceRegistry.describe_scalar_value(_current_catalog(), _kind, value)

	_button.text = String(description["display_text"])
	_button.tooltip_text = String(description["tooltip"])
	_clear_button.disabled = value.is_empty()
	set_draw_warning(bool(description["is_orphan"]))


func _open_popup() -> void:
	var known := GAReferenceRegistry.identifiers_in_catalog(_current_catalog(), _kind)
	if _popup == null:
		_popup = GAPickerPopup.new()
		_popup.identifier_picked.connect(_on_identifier_picked)
		_popup.cleared.connect(_on_clear_pressed)
		add_child(_popup)
	if GAReferenceRegistry.is_hierarchical(_kind):
		_popup.configure_hierarchical(known)
	else:
		_popup.configure_flat(known)
	_popup.popup_search()


func _on_identifier_picked(identifier: String) -> void:
	emit_changed(get_edited_property(), StringName(identifier))


func _on_clear_pressed() -> void:
	emit_changed(get_edited_property(), StringName())
