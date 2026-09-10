class_name GAReferenceRegistry
extends RefCounted

## Explicit per-(resource type, property name) declaration of which catalog
## reference kind an Inspector property holds (design.md decision 2: "the
## plugin does not guess solely from property names"; tasks.md 2.3).
## [GAReferenceInspectorPlugin] (Inspector pickers) and [GAUsageScanner]
## (rename/delete usage reports) both read this SAME table, so they can
## never disagree about what counts as a rewritable reference.
##
## Deliberately plain data + static lookups -- no Control/EditorInterface
## dependency -- so tests/gameplay_abilities/smoke/test_reference_registry.gd
## exercises it directly, exactly like [GameplayAbilitiesDashboard]'s own
## pure static methods.

# -- Reference kinds ----------------------------------------------------
# SCALAR kinds hold one StringName identifier; ARRAY kinds hold a
# PackedStringArray of identifiers. HIERARCHICAL kinds (tags) get the
# dotted-identifier tree picker ([GATagHierarchy]); every other kind gets a
# flat/grouped list ([GAPickerNavigation.group_by_first_segment]).

const KIND_TAG := "ref_tag" # scalar, hierarchical
const KIND_TAG_ARRAY := "ref_tag_array" # array, hierarchical
const KIND_ATTRIBUTE := "ref_attribute" # scalar, flat
const KIND_EFFECT := "ref_effect" # scalar, flat
const KIND_EFFECT_ARRAY := "ref_effect_array" # array, flat
const KIND_ABILITY := "ref_ability" # scalar, flat (no bound property yet -- see TABLE comment)
const KIND_ABILITY_ARRAY := "ref_ability_array" # array, flat (no bound property yet)
const KIND_CUE_ARRAY := "ref_cue_array" # array, flat
const KIND_TARGET_SCHEMA := "ref_target_schema" # scalar, flat

const HIERARCHICAL_KINDS: PackedStringArray = [KIND_TAG, KIND_TAG_ARRAY]
const ARRAY_KINDS: PackedStringArray = [KIND_TAG_ARRAY, KIND_EFFECT_ARRAY, KIND_ABILITY_ARRAY, KIND_CUE_ARRAY]

## Maps each reference kind to the [GameplayDefinitionCatalog] getter method
## that lists the identifiers it may resolve against. One Dictionary instead
## of a parallel switch statement, so adding a reference kind only ever
## touches this one map.
const CATALOG_GETTER := {
	KIND_TAG: "get_tag_definitions",
	KIND_TAG_ARRAY: "get_tag_definitions",
	KIND_ATTRIBUTE: "get_attribute_definitions",
	KIND_EFFECT: "get_effect_definitions",
	KIND_EFFECT_ARRAY: "get_effect_definitions",
	KIND_ABILITY: "get_ability_definitions",
	KIND_ABILITY_ARRAY: "get_ability_definitions",
	KIND_CUE_ARRAY: "get_cue_definitions",
	KIND_TARGET_SCHEMA: "get_target_data_schemas",
}

## The "definition kind" vocabulary [GameplayAbilitiesDashboard]/
## [GACatalogService] already use ("tag", "attribute", ...) mapped to every
## reference kind that resolves against that same catalog collection. Used
## by rename/delete (tasks.md 2.5): renaming a tag identifier must scan for
## BOTH scalar ([constant KIND_TAG]) and packed-array
## ([constant KIND_TAG_ARRAY]) occurrences, not just one.
const REFERENCE_KINDS_BY_DEFINITION_KIND := {
	"tag": [KIND_TAG, KIND_TAG_ARRAY],
	"attribute": [KIND_ATTRIBUTE],
	"effect": [KIND_EFFECT, KIND_EFFECT_ARRAY],
	"ability": [KIND_ABILITY, KIND_ABILITY_ARRAY],
	"cue": [KIND_CUE_ARRAY],
	"target_schema": [KIND_TARGET_SCHEMA],
}

## The explicit registration table (design.md decision 2; tasks.md 2.3
## "Property support is DECLARED per resource type + property name +
## reference kind"). Each row is {resource_class, property, kind}.
## `resource_class` is matched against [method Object.get_class] -- every
## resource type listed here is a direct [Resource] subclass with no further
## subclassing in this addon, so exact string equality (not an `is` chain)
## is sufficient and keeps this table plain data with no class references
## that would force this script to fail to parse if the native module were
## ever unavailable.
##
## KIND_ABILITY/KIND_ABILITY_ARRAY have no row yet: no shipped resource
## currently references an ability by identifier (abilities are entered via
## input/gameplay-event triggers, never referenced FROM another definition).
## The kinds stay declared in [constant CATALOG_GETTER] and
## [constant REFERENCE_KINDS_BY_DEFINITION_KIND] above so
## [GAReferencePickerProperty]/[GAReferenceArrayPickerProperty] and the
## usage scanner already support them the moment a future property needs
## one -- only this table needs a new row, per this class's whole purpose.
const TABLE: Array[Dictionary] = [
	# Tags -- scalar.
	{"resource_class": "GameplayTagOperand", "property": "tag", "kind": KIND_TAG},
	{"resource_class": "GameplayAbilityTrigger", "property": "gameplay_event_tag", "kind": KIND_TAG},
	# Tags -- packed array.
	{"resource_class": "GameplayEffectDefinition", "property": "granted_tags", "kind": KIND_TAG_ARRAY},
	{"resource_class": "GameplayAbilityDefinition", "property": "owned_tags", "kind": KIND_TAG_ARRAY},
	# Attributes -- scalar. GameplayModifierDeclaration.target_attribute MUST
	# resolve against attribute_definitions only (spec.md "Author selects a
	# modifier target"), never tags -- this is the exact case design.md
	# decision 2 calls out by name.
	{"resource_class": "GameplayModifierDeclaration", "property": "target_attribute", "kind": KIND_ATTRIBUTE},
	# Effects -- scalar.
	{"resource_class": "GameplayAbilityDefinition", "property": "cost_effect", "kind": KIND_EFFECT},
	{"resource_class": "GameplayAbilityDefinition", "property": "cooldown_effect", "kind": KIND_EFFECT},
	{"resource_class": "GameplayStackingPolicy", "property": "overflow_effect", "kind": KIND_EFFECT},
	{"resource_class": "GameplayTagReactionDefinition", "property": "effect_identifier", "kind": KIND_EFFECT},
	# Effects -- packed array.
	{"resource_class": "GameplayAbilityDefinition", "property": "commit_effects", "kind": KIND_EFFECT_ARRAY},
	# Cues -- packed array.
	{"resource_class": "GameplayEffectDefinition", "property": "cue_identifiers", "kind": KIND_CUE_ARRAY},
	# Target-data schemas -- scalar.
	{"resource_class": "GameplayAbilityDefinition", "property": "target_schema", "kind": KIND_TARGET_SCHEMA},
]


static func lookup_by_class(resource_class: String, property: String) -> String:
	for row in TABLE:
		if row["resource_class"] == resource_class and row["property"] == property:
			return row["kind"]
	return ""


## Convenience wrapper over [method lookup_by_class] for a live [param object]
## -- what [GAReferenceInspectorPlugin]._parse_property actually calls.
static func lookup(object: Object, property: String) -> String:
	if object == null:
		return ""
	return lookup_by_class(object.get_class(), property)


static func class_has_any_reference_property(resource_class: String) -> bool:
	for row in TABLE:
		if row["resource_class"] == resource_class:
			return true
	return false


static func is_hierarchical(kind: String) -> bool:
	return HIERARCHICAL_KINDS.has(kind)


static func is_array_kind(kind: String) -> bool:
	return ARRAY_KINDS.has(kind)


static func catalog_getter_for_kind(kind: String) -> String:
	return String(CATALOG_GETTER.get(kind, ""))


## Every declared reference kind that reads the SAME catalog collection as
## [param kind] (e.g. KIND_TAG and KIND_TAG_ARRAY both read
## `tag_definitions`) -- used by [GAUsageScanner] so a scan for "does
## anything reference this tag identifier" covers scalar and packed-array
## properties in one pass.
static func kinds_sharing_catalog_getter(kind: String) -> PackedStringArray:
	var getter := catalog_getter_for_kind(kind)
	var result := PackedStringArray()
	if getter.is_empty():
		return result
	for other_kind in CATALOG_GETTER:
		if CATALOG_GETTER[other_kind] == getter:
			result.append(other_kind)
	return result


## The reference kind(s) (see [constant REFERENCE_KINDS_BY_DEFINITION_KIND])
## for a "definition kind" string ("tag", "attribute", "effect", "ability",
## "cue", "target_schema" -- the same vocabulary
## [GameplayAbilitiesDashboard.KIND_ORDER]/[GACatalogService.KIND_ORDER]
## use).
static func reference_kinds_for_definition_kind(definition_kind: String) -> PackedStringArray:
	var result := PackedStringArray()
	for kind in REFERENCE_KINDS_BY_DEFINITION_KIND.get(definition_kind, []):
		result.append(String(kind))
	return result


## Resolves [param catalog]'s collection for [param kind] into a flat,
## unsorted list of identifiers -- what every picker searches/filters and
## what orphan detection (tasks.md 2.4) checks a serialized value against.
## Returns an empty array (never null/error) for a null catalog or an
## unrecognized kind, so callers never need an extra guard.
static func identifiers_in_catalog(catalog: Resource, kind: String) -> PackedStringArray:
	var result := PackedStringArray()
	if catalog == null:
		return result
	var getter := catalog_getter_for_kind(kind)
	if getter.is_empty() or not catalog.has_method(getter):
		return result
	var entries: Array = catalog.call(getter)
	for entry in entries:
		if entry != null and entry.has_method("get_identifier"):
			result.append(String(entry.call("get_identifier")))
	return result


## Pure "what should a scalar reference picker show" decision (tasks.md 2.4
## "Orphan Reference Preservation") -- deliberately factored out of
## [method GAReferencePickerProperty._update_property] so it stays
## headlessly testable: [EditorProperty] cannot be instantiated outside a
## running editor process (Godot itself rejects it -- "Class 'EditorProperty'
## can only be instantiated by editor" -- even under `godot --headless`),
## so this is the one place the actual orphan/known/empty decision can be
## exercised directly, see
## tests/gameplay_abilities/smoke/test_orphan_preservation.gd. Returns
## [code]{display_text, is_orphan, tooltip}[/code]; `display_text` is ALWAYS
## [param value] verbatim when non-empty -- never coerced, cleared, or
## replaced, matching spec.md "it does not replace the value with the first
## available tag".
static func describe_scalar_value(catalog: Resource, kind: String, value: String) -> Dictionary:
	if value.is_empty():
		return {"display_text": "(none)", "is_orphan": false, "tooltip": ""}
	var known := identifiers_in_catalog(catalog, kind)
	if known.has(value):
		return {"display_text": value, "is_orphan": false, "tooltip": value}
	return {
		"display_text": value,
		"is_orphan": true,
		"tooltip": (
			"'%s' was not found in the active catalog. Choose a replacement from the picker "
			% value + "or clear it explicitly -- it will not be changed automatically."
		),
	}


## Same pure factoring as [method describe_scalar_value], for
## [GAReferenceArrayPickerProperty]'s packed-array display: one
## [code]{identifier, is_orphan}[/code] row per entry, in the original array
## order (never reordered, deduplicated, or dropped).
static func describe_array_entries(catalog: Resource, kind: String, values: PackedStringArray) -> Array:
	var known := identifiers_in_catalog(catalog, kind)
	var rows: Array = []
	for raw_value in values:
		var identifier := String(raw_value)
		rows.append({"identifier": identifier, "is_orphan": not known.has(identifier)})
	return rows
