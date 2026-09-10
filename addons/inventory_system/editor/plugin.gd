@tool
extends EditorPlugin

## Editor entry point for the InventorySystem addon.
##
## Like GameplayAbilities, this addon has no process-global runtime
## autoload: inventory authority/replica state belongs to whichever
## InventoryAuthority/InventoryReplicaNode nodes a game scene creates, so
## there is no singleton for this plugin to install. It registers editor-time
## tooling only -- a "Validate Inventory Catalog" Project > Tools menu action
## (task 3.9).

const REQUIRED_CLASSES: PackedStringArray = [
	"InventoryCatalog",
]

const VALIDATE_MENU_ITEM := "Validate Inventory Catalog"


func _enter_tree() -> void:
	for class_name_to_check in REQUIRED_CLASSES:
		if not ClassDB.class_exists(class_name_to_check):
			push_warning(
				"InventorySystem: native class '%s' is not registered. Build the addon's "
				% class_name_to_check
				+ "GDExtension for this platform (see addons/inventory_system/release_manifest.json)."
			)
	add_tool_menu_item(VALIDATE_MENU_ITEM, _on_validate_catalog_requested)


func _exit_tree() -> void:
	remove_tool_menu_item(VALIDATE_MENU_ITEM)


func _get_plugin_name() -> String:
	return "InventorySystem"


## Walks a user-selected InventoryCatalogResource (the current FileSystem-dock
## selection, if it names one) or, absent that, every InventoryCatalogResource
## found under res://, and prints bounded, stable-path diagnostics --
## {resource path, identifier, status_code} per finding -- via
## InventoryCatalog.validate_resource(), the SAME runtime-side validator a
## game calls before registering (native/godot/inventory_catalog.h). Editor
## acceptance never replaces that runtime validation
## (native/resources/README.md); this tool exists only to surface the same
## findings earlier, during authoring.
func _on_validate_catalog_requested() -> void:
	if not ClassDB.class_exists("InventoryCatalog"):
		push_error("InventorySystem: cannot validate -- the InventoryCatalog native class is not registered. "
				+ "Build the GDExtension first (see addons/inventory_system/release_manifest.json).")
		return

	var targets: Array[String] = _selected_catalog_paths()
	var scanned_whole_project := false
	if targets.is_empty():
		targets = _find_all_catalog_paths("res://")
		scanned_whole_project = true

	if targets.is_empty():
		print("InventorySystem validate: no InventoryCatalogResource selected or found under res://.")
		return

	# InventoryCatalog is RefCounted (native/godot/inventory_catalog.h); a
	# fresh instance is only ever used for its validate_resource() seam here
	# -- never registered into, never sealed.
	var validator: Object = ClassDB.instantiate(&"InventoryCatalog")

	var total_checked := 0
	var total_findings := 0
	var total_errors := 0
	for path in targets:
		var resource: Resource = load(path)
		if resource == null or resource.get_class() != "InventoryCatalogResource":
			continue
		total_checked += 1
		var findings: Array = validator.call(&"validate_resource", resource)
		for finding_variant in findings:
			var finding: Dictionary = finding_variant
			total_findings += 1
			var status_code: int = int(finding.get("status_code", 0))
			if status_code != 0:
				total_errors += 1
			print("  [%s] %s identifier='%s' status_code=%d diagnostic=%d detail=%d source='%s'" % [
				"ERROR" if status_code != 0 else "ok",
				path,
				str(finding.get("identifier", "")),
				status_code,
				int(finding.get("diagnostic", 0)),
				int(finding.get("detail", 0)),
				str(finding.get("source", "")),
			])

	print("InventorySystem validate: %s, %d catalog(s) checked, %d finding(s), %d error(s)." % [
		"selection" if not scanned_whole_project else "res:// scan",
		total_checked,
		total_findings,
		total_errors,
	])


func _selected_catalog_paths() -> Array[String]:
	var result: Array[String] = []
	for path in EditorInterface.get_selected_paths():
		var resource: Resource = load(path)
		if resource != null and resource.get_class() == "InventoryCatalogResource":
			result.append(path)
	return result


func _find_all_catalog_paths(dir_path: String) -> Array[String]:
	var result: Array[String] = []
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return result
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if not entry.begins_with("."):
			var full_path := dir_path.path_join(entry)
			if dir.current_is_dir():
				result.append_array(_find_all_catalog_paths(full_path))
			elif entry.ends_with(".tres") or entry.ends_with(".res"):
				var resource: Resource = load(full_path)
				if resource != null and resource.get_class() == "InventoryCatalogResource":
					result.append(full_path)
		entry = dir.get_next()
	dir.list_dir_end()
	return result
