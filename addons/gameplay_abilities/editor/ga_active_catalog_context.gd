class_name GAActiveCatalogContext
extends RefCounted

## Shared holder for "the catalog the dashboard currently has selected"
## (design.md decision 2: "Attribute, effect, ability, cue, and
## target-schema references use searchable flat/grouped definition pickers
## from the SAME catalog"). `plugin.gd` creates the one instance and gives it
## to both [GameplayAbilitiesDashboard] (which calls [method set_catalog]
## whenever its own selection changes -- the default project catalog on
## startup, or an explicitly opened/created catalog) and
## [GAReferenceInspectorPlugin] (which calls [method get_catalog] every time
## it builds a picker property). Neither side polls the other; a picker
## opened anywhere in the Inspector always reflects the dashboard's current
## selection because they share this one object.

signal catalog_changed(catalog: Resource)

var _catalog: Resource = null


func get_catalog() -> Resource:
	return _catalog


func set_catalog(catalog: Resource) -> void:
	if _catalog == catalog:
		return
	_catalog = catalog
	catalog_changed.emit(_catalog)
