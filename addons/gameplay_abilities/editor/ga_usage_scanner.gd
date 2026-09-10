class_name GAUsageScanner
extends RefCounted

## Pure reference-usage scanning for the dashboard's rename/delete flows
## (tasks.md 2.5, design.md decision 2 "Rename and delete first build a
## usage report ... across catalog-owned resources and known project
## resource files"). Walks already-loaded [Resource]/[Node] trees using
## [GAReferenceRegistry]'s explicit table -- it never guesses from property
## names, and it never decides policy about what to DO with a match (that is
## [GARewritePlanner]'s job) -- so this stays headlessly testable, see
## tests/gameplay_abilities/smoke/test_usage_scanner.gd.

const MAX_DEPTH := 8


## Appends one matched reference location to [param out]:
## {resource, resource_path, property, path, is_array, index}. `path` is a
## human-readable dotted/bracketed locator (e.g. "operand.tag" or
## "granted_tags[2]") for display in a usage report; `resource`/`property`/
## `index` are exactly what [GARewritePlanner] needs to rewrite the value.
static func _record_match(resource: Resource, resource_path: String, property: String, path: String,
		is_array: bool, index: int, out: Array) -> void:
	out.append({
		"resource": resource,
		"resource_path": resource_path,
		"property": property,
		"path": path,
		"is_array": is_array,
		"index": index,
	})


## Recursively walks [param resource]'s declared-storage properties, matching
## any of [param kinds]/[param identifier] against [GAReferenceRegistry]'s
## table, and recursing into every nested [Resource] / [Array] of [Resource]
## property regardless of whether the CONTAINING resource's class has any
## table entry of its own -- a [GameplayTagQueryResource] has no tag-valued
## property itself, but its `all_of`/`any_of`/`none_of` arrays hold
## [GameplayTagOperand] elements that do (see [GAReferenceRegistry].TABLE).
## `visited` guards against reference cycles by object instance id.
static func walk(resource: Resource, kinds: PackedStringArray, identifier: String, resource_path: String,
		out: Array, visited: Dictionary = {}, path_prefix: String = "", depth: int = 0) -> void:
	if resource == null or depth > MAX_DEPTH or identifier.is_empty():
		return
	var rid := resource.get_instance_id()
	if visited.has(rid):
		return
	visited[rid] = true

	var class_name_str := resource.get_class()
	for prop in resource.get_property_list():
		if int(prop.get("usage", 0)) & PROPERTY_USAGE_STORAGE == 0:
			continue
		var pname: String = prop["name"]
		if pname.is_empty():
			continue
		var value = resource.get(pname)

		var declared_kind := GAReferenceRegistry.lookup_by_class(class_name_str, pname)
		if not declared_kind.is_empty() and kinds.has(declared_kind):
			if typeof(value) == TYPE_STRING or typeof(value) == TYPE_STRING_NAME:
				if String(value) == identifier:
					_record_match(resource, resource_path, pname, "%s%s" % [path_prefix, pname], false, -1, out)
			elif typeof(value) == TYPE_PACKED_STRING_ARRAY:
				var arr: PackedStringArray = value
				for i in range(arr.size()):
					if arr[i] == identifier:
						_record_match(resource, resource_path, pname, "%s%s[%d]" % [path_prefix, pname, i], true, i, out)

		if value is Resource:
			walk(value, kinds, identifier, resource_path, out, visited, "%s%s." % [path_prefix, pname], depth + 1)
		elif value is Array:
			var nested: Array = value
			for i in range(nested.size()):
				if nested[i] is Resource:
					walk(nested[i], kinds, identifier, resource_path, out, visited,
						"%s%s[%d]." % [path_prefix, pname, i], depth + 1)


## Scans every definition owned by [param catalog] itself (task 2.5 "across
## catalog-owned resources") across all seven collections -- a
## [GameplayTagReactionDefinition]'s `operand.tag`/`effect_identifier` are
## catalog-owned references exactly like any other definition's fields.
static func scan_catalog(catalog: Resource, kinds: PackedStringArray, identifier: String) -> Array:
	var out: Array = []
	if catalog == null:
		return out
	var visited: Dictionary = {}
	var seen_getters: Dictionary = {}
	for getter in GACatalogService.KIND_GETTER.values():
		if seen_getters.has(getter) or not catalog.has_method(getter):
			continue
		seen_getters[getter] = true
		var entries: Array = catalog.call(getter)
		for entry in entries:
			if entry is Resource:
				var path: String = entry.resource_path if not entry.resource_path.is_empty() else "<%s>" % entry.get_class()
				walk(entry, kinds, identifier, path, out, visited)
	return out


static func _file_contains_text(path: String, needle: String) -> bool:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return false
	var text := file.get_as_text()
	file.close()
	return text.find(needle) != -1


static func _walk_scene_node(node: Node, kinds: PackedStringArray, identifier: String, resource_path: String,
		out: Array, visited: Dictionary) -> void:
	for prop in node.get_property_list():
		if int(prop.get("usage", 0)) & PROPERTY_USAGE_STORAGE == 0:
			continue
		var pname: String = prop["name"]
		var value = node.get(pname)
		if value is Resource:
			walk(value, kinds, identifier, resource_path, out, visited, "%s.%s." % [node.name, pname])
		elif value is Array:
			var nested: Array = value
			for i in range(nested.size()):
				if nested[i] is Resource:
					walk(nested[i], kinds, identifier, resource_path, out, visited,
						"%s.%s[%d]." % [node.name, pname, i])
	for child in node.get_children():
		_walk_scene_node(child, kinds, identifier, resource_path, out, visited)


## Scans a caller-supplied list of already-resolved project resource paths
## (task 2.5 "and project resource files"). `.tres`/`.res` files are loaded
## and walked directly; `.tscn` files are instantiated (safe headlessly --
## no EditorInterface involved, matches [method PackedScene.instantiate]'s
## own documented behavior) and every node's declared-storage properties are
## walked the same way, so e.g. a legacy
## `GameplayAbilityComponent.effect_definitions[i].granted_tags` embedded
## directly in a scene is found exactly like a catalog-owned effect's would
## be.
##
## A file that textually CONTAINS [param identifier] but whose structural
## walk finds no declared-table match is reported under `unsupported` rather
## than silently dropped -- the identifier may only appear in a comment, an
## unrelated resource name, or a property [GAReferenceRegistry] does not
## declare, and spec.md "A reference cannot be rewritten safely" requires
## blocking rather than guessing in that case.
static func scan_project_files(paths: PackedStringArray, kinds: PackedStringArray, identifier: String) -> Dictionary:
	var supported: Array = []
	var unsupported: Array = []
	if identifier.is_empty():
		return {"supported": supported, "unsupported": unsupported}

	for raw_path in paths:
		var path := String(raw_path)
		if not _file_contains_text(path, identifier):
			continue

		var matches: Array = []
		if path.ends_with(".tres") or path.ends_with(".res"):
			var resource: Resource = ResourceLoader.load(path)
			if resource != null:
				walk(resource, kinds, identifier, path, matches)
		elif path.ends_with(".tscn"):
			var packed: PackedScene = ResourceLoader.load(path)
			if packed != null:
				var root := packed.instantiate(PackedScene.GEN_EDIT_STATE_DISABLED)
				if root != null:
					_walk_scene_node(root, kinds, identifier, path, matches, {})
					root.queue_free()

		if matches.is_empty():
			unsupported.append({
				"resource": null, "resource_path": path, "property": "",
				"path": "(text match, no declared reference found)", "is_array": false, "index": -1,
			})
		else:
			supported.append_array(matches)

	return {"supported": supported, "unsupported": unsupported}


## Combines a catalog-owned scan and a project-file scan into one report:
## {supported, unsupported, blocked}. `blocked` is true whenever
## `unsupported` is non-empty -- callers (the dashboard, tests) treat that as
## "do not offer an automatic rewrite" per spec.md "A reference cannot be
## rewritten safely".
static func usage_report(catalog: Resource, kinds: PackedStringArray, identifier: String,
		project_paths: PackedStringArray = PackedStringArray()) -> Dictionary:
	var supported: Array = scan_catalog(catalog, kinds, identifier)
	var project_result := scan_project_files(project_paths, kinds, identifier)
	supported.append_array(project_result["supported"])
	var unsupported: Array = project_result["unsupported"]
	return {"supported": supported, "unsupported": unsupported, "blocked": not unsupported.is_empty()}
