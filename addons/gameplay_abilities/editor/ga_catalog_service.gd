class_name GACatalogService
extends RefCounted

## Pure, EditorInterface-free catalog selection/summary logic for the
## dashboard (tasks.md 2.1). Mirrors [GameplayAbilitiesDashboard]'s existing
## "pure logic, no EditorInterface" split -- every function here takes/
## returns plain data (String/Dictionary/Resource) so
## tests/gameplay_abilities/smoke/test_catalog_service.gd can call it
## directly, exactly like [method GameplayAbilitiesDashboard.scan_directory]
## already does for the legacy directory-scan path the catalog now
## supersedes as the dashboard's source of truth (design.md decisions 1/2).

## Mirrors the native default-catalog project setting registered in
## register_types.cpp -- see that file's own comment for why it is
## registered with `has_setting`/`set_initial_value` rather than assigned
## unconditionally.
const DEFAULT_CATALOG_SETTING := "gameplay_abilities/default_definition_catalog"

## The catalog's seven collections. Uses the same "definition kind"
## vocabulary [GameplayAbilitiesDashboard.KIND_ORDER] uses for its legacy
## per-file scan (tag/attribute/effect/ability/cue/target_schema), minus
## KIND_NETWORK_POLICY (the catalog carries no network-policy collection --
## see [GameplayDefinitionCatalog]'s own header comment) plus
## KIND_TAG_REACTION, the one collection unique to the catalog.
const KIND_TAG := "tag"
const KIND_ATTRIBUTE := "attribute"
const KIND_EFFECT := "effect"
const KIND_ABILITY := "ability"
const KIND_CUE := "cue"
const KIND_TARGET_SCHEMA := "target_schema"
const KIND_TAG_REACTION := "tag_reaction"

const KIND_ORDER: PackedStringArray = [
	KIND_TAG, KIND_ATTRIBUTE, KIND_EFFECT, KIND_ABILITY, KIND_CUE, KIND_TARGET_SCHEMA, KIND_TAG_REACTION,
]

const KIND_LABELS := {
	KIND_TAG: "Tags",
	KIND_ATTRIBUTE: "Attributes",
	KIND_EFFECT: "Effects",
	KIND_ABILITY: "Abilities",
	KIND_CUE: "Cues",
	KIND_TARGET_SCHEMA: "Target Schemas",
	KIND_TAG_REACTION: "Tag Reactions",
}

## [GameplayDefinitionCatalog] getter method name for each collection.
const KIND_GETTER := {
	KIND_TAG: "get_tag_definitions",
	KIND_ATTRIBUTE: "get_attribute_definitions",
	KIND_EFFECT: "get_effect_definitions",
	KIND_ABILITY: "get_ability_definitions",
	KIND_CUE: "get_cue_definitions",
	KIND_TARGET_SCHEMA: "get_target_data_schemas",
	KIND_TAG_REACTION: "get_tag_reactions",
}

## [GameplayDefinitionCatalog]'s own property name for each collection --
## identical spelling to [constant KIND_GETTER] minus the "get_" prefix
## (used by [GARewritePlanner]/[GAMigrationPlanner] as the
## `add_do_property`/`add_undo_property` property argument).
const KIND_PROPERTY := {
	KIND_TAG: "tag_definitions",
	KIND_ATTRIBUTE: "attribute_definitions",
	KIND_EFFECT: "effect_definitions",
	KIND_ABILITY: "ability_definitions",
	KIND_CUE: "cue_definitions",
	KIND_TARGET_SCHEMA: "target_data_schemas",
	KIND_TAG_REACTION: "tag_reactions",
}


## Reads the project setting without requiring it to already exist (a fresh
## headless test run may not have imported the native module's initial
## value yet). Never errors -- an unset/empty setting simply means "no
## project-default catalog resolves", matching the resolution order
## `GameplayAbilityComponent::configure()` documents: explicit override,
## else this project default, else no catalog at all.
static func project_default_path() -> String:
	if not ProjectSettings.has_setting(DEFAULT_CATALOG_SETTING):
		return ""
	return String(ProjectSettings.get_setting(DEFAULT_CATALOG_SETTING, ""))


## Loads and returns the catalog at [param path], or null for an empty path,
## a missing file, or a resource that fails to load/is not actually a
## catalog. Never throws -- a stale/deleted project-default setting degrades
## to "no catalog selected" rather than blocking the dashboard from opening.
static func load_catalog(path: String) -> Resource:
	if path.is_empty() or not ResourceLoader.exists(path):
		return null
	var resource: Resource = ResourceLoader.load(path)
	if not (resource is GameplayDefinitionCatalog):
		return null
	return resource


static func create_empty_catalog() -> Resource:
	return GameplayDefinitionCatalog.new()


## Filters an arbitrary resource-path list down to saved
## [GameplayDefinitionCatalog] resources. Paths are returned sorted and
## de-duplicated so editor startup never depends on filesystem traversal
## order. Missing and non-catalog resources are ignored.
static func find_catalog_paths(resource_paths: PackedStringArray) -> PackedStringArray:
	var result := PackedStringArray()
	for path in resource_paths:
		if result.has(path):
			continue
		if load_catalog(path) != null:
			result.append(path)
	result.sort()
	return result


## Chooses the catalog the editor dashboard should activate on startup.
## A configured project default always wins, including a stale path that the
## dashboard should surface rather than silently replacing. With no default,
## one saved catalog is unambiguous and safe to select automatically; zero or
## multiple catalogs require an explicit author choice.
static func initial_editor_catalog_path(
		p_project_default_path: String, saved_catalog_paths: PackedStringArray) -> String:
	if not p_project_default_path.is_empty():
		return p_project_default_path
	if saved_catalog_paths.size() == 1:
		return saved_catalog_paths[0]
	return ""


## Per-collection counts plus the total -- the dashboard's "summarize the
## selected catalog" panel (tasks.md 2.1). Every one of [constant KIND_ORDER]
## is always present, even when [param catalog] is null (all zero), so
## callers never need an extra `has()` check.
static func summarize(catalog: Resource) -> Dictionary:
	var counts: Dictionary = {}
	var total := 0
	for kind in KIND_ORDER:
		var count := 0
		if catalog != null:
			var getter: String = KIND_GETTER[kind]
			if catalog.has_method(getter):
				var entries: Array = catalog.call(getter)
				count = entries.size()
		counts[kind] = count
		total += count
	return {"counts": counts, "total": total}
