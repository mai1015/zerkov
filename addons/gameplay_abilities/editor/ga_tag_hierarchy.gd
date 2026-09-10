class_name GATagHierarchy
extends RefCounted

## Pure hierarchy/search logic for the searchable hierarchical tag picker
## (tasks.md 2.2). No Tree/Popup/EditorInterface dependency -- [GAPickerPopup]
## and [GameplayAbilitiesDashboard] both call these same static functions,
## and tests/gameplay_abilities/smoke/test_tag_hierarchy_search.gd exercises
## them directly without an editor context.

## Builds a nested-Dictionary hierarchy from a flat list of dotted tag
## identifiers -- [code]state.control.stunned[/code] nests under
## [code]state.control[/code] under [code]state[/code]. Moved here (tasks.md
## 2.1/2.2 refactor) from
## [method GameplayAbilitiesDashboard.build_tag_hierarchy], which now
## forwards to this method so its own already-smoke-tested public API stays
## byte-for-byte the same. Each level is
## [code]{segment_name: {full, has_resource, children}}[/code]:
##   full:         the dotted identifier up to and including this segment
##   has_resource: true when this exact dotted path is one of the input
##                 identifiers (an actual definition exists); false for a
##                 purely intermediate segment with no backing resource.
##   children:     the same shape, one level deeper.
static func build_hierarchy(identifiers: PackedStringArray) -> Dictionary:
	var root: Dictionary = {}
	for raw_identifier in identifiers:
		var identifier := String(raw_identifier)
		if identifier.is_empty():
			continue
		var segments := identifier.split(".")
		var node := root
		var full := ""
		for i in range(segments.size()):
			var segment: String = segments[i]
			full = segment if full.is_empty() else "%s.%s" % [full, segment]
			if not node.has(segment):
				node[segment] = {"full": full, "has_resource": false, "children": {}}
			if i == segments.size() - 1:
				node[segment]["has_resource"] = true
			node = node[segment]["children"]
	return root


## Sorted segment keys for one hierarchy level -- the single place that
## decides display order, so [GAPickerPopup]'s Tree and [method flatten]
## below never disagree.
static func sorted_keys(node: Dictionary) -> Array:
	var keys := node.keys()
	keys.sort()
	return keys


## Flattens a hierarchy into the exact depth-first, alphabetically-sorted
## order a Tree view displays it in, as an Array of
## [code]{full, segment, has_resource, depth}[/code] rows. Drives
## [GAPickerPopup]'s Tree population and, headlessly, the keyboard
## up/down/home/end navigation math tests exercise without a live Tree
## control (see [GAPickerNavigation.move]).
static func flatten(hierarchy: Dictionary, depth: int = 0) -> Array:
	var rows: Array = []
	for segment in sorted_keys(hierarchy):
		var info: Dictionary = hierarchy[segment]
		rows.append({"full": info["full"], "segment": segment, "has_resource": info["has_resource"], "depth": depth})
		rows.append_array(flatten(info["children"], depth + 1))
	return rows


## Case-insensitive substring search over dotted identifiers. Returns a
## PRUNED hierarchy keeping only branches that contain at least one matching
## identifier, exactly like a filtered file tree. A segment whose OWN full
## path matches keeps its entire subtree visible (searching "state" should
## still show every descendant of "state"); a segment that only has a
## matching DESCENDANT keeps just that descendant's path. Blank
## [param query] returns [param hierarchy] unchanged.
static func filter(hierarchy: Dictionary, query: String) -> Dictionary:
	if query.strip_edges().is_empty():
		return hierarchy
	var needle := query.strip_edges().to_lower()
	var result: Dictionary = {}
	for segment in hierarchy:
		var info: Dictionary = hierarchy[segment]
		var self_match: bool = String(info["full"]).to_lower().findn(needle) != -1
		var filtered_children: Dictionary = info["children"] if self_match else filter(info["children"], query)
		if self_match or not filtered_children.is_empty():
			result[segment] = {
				"full": info["full"],
				"has_resource": info["has_resource"],
				"children": filtered_children,
			}
	return result


## Every identifier actually backed by a resource ([code]has_resource ==
## true[/code]) in depth-first order.
static func leaf_identifiers(hierarchy: Dictionary) -> PackedStringArray:
	var result := PackedStringArray()
	for row in flatten(hierarchy):
		if row["has_resource"]:
			result.append(row["full"])
	return result
