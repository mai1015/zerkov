class_name GAReferenceInspectorPlugin
extends EditorInspectorPlugin

## Registers [GAReferencePickerProperty]/[GAReferenceArrayPickerProperty] for
## every property [GAReferenceRegistry] declares (tasks.md 2.2/2.3) --
## support is looked up from that explicit table, never guessed from the
## property name alone (design.md decision 2: "the plugin does not guess
## solely from property names"). Constructed once in `plugin.gd` and given
## the SAME [GAActiveCatalogContext] the dashboard updates, so every picker
## anywhere in the Inspector reflects the dashboard's current catalog
## selection (design.md decision 2's "same catalog").


var _catalog_context: GAActiveCatalogContext


func _init(catalog_context: GAActiveCatalogContext = null) -> void:
	_catalog_context = catalog_context


func _can_handle(object: Object) -> bool:
	if object == null:
		return false
	return GAReferenceRegistry.class_has_any_reference_property(object.get_class())


func _parse_property(object: Object, _type: Variant.Type, name: String, _hint_type: int,
		_hint_string: String, _usage_flags: int, _wide: bool) -> bool:
	var kind := GAReferenceRegistry.lookup(object, name)
	if kind.is_empty():
		return false
	if GAReferenceRegistry.is_array_kind(kind):
		add_property_editor(name, GAReferenceArrayPickerProperty.new(kind, _catalog_context))
	else:
		add_property_editor(name, GAReferencePickerProperty.new(kind, _catalog_context))
	return true
