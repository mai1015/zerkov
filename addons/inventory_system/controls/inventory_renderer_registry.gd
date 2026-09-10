class_name InventoryRendererRegistry
extends RefCounted

## Maps ownership-layout identifiers (and optional per-container-definition
## overrides) to a replaceable container renderer (tasks.md 8.3;
## inventory-presentation spec, "Layout Renderer Registry").
##
## A "renderer" is either a [PackedScene] (instantiated with [method
## PackedScene.instantiate]) or a [Script] whose base class derives [Control]
## and exposes a zero-argument constructor (instantiated with [code]script.new()[/code]);
## [method instantiate_for] accepts either uniformly. Every built-in container
## control in this addon (`InventorySpatialGridControl`, `InventoryNamedSlotsControl`,
## `InventoryOrderedListControl`) is a plain typed-GDScript [Control] subclass
## with no companion `.tscn` (see those scripts' own header comments for why),
## so the default registrations are bare [Script] resources; a game may
## register a [PackedScene] instead without this class caring which.
##
## Games replace any entry with [method register_renderer] -- "no native
## transaction code changes" (inventory-presentation spec, "Game replaces a
## renderer"). Resolution is by container-definition-identifier override
## FIRST, then by layout kind, so a game can retarget one specific container
## definition (e.g. a bespoke "vault" grid) while every other spatial-grid
## container keeps using the addon default.

## Ownership-layout kind identifiers. Mirrors
## `InventoryContainerDefinition.LAYOUT_*` (native/resources/
## inventory_container_definition.h) as StringName tokens so this registry
## does not have to depend on the native enum's integer values matching
## anything -- callers pass the container's own declared layout kind, mapped
## to one of these three tokens by [method layout_kind_token].
const LAYOUT_SPATIAL_GRID: StringName = &"inventory.layout.spatial_grid"
const LAYOUT_NAMED_SLOTS: StringName = &"inventory.layout.named_slots"
const LAYOUT_ORDERED_LIST: StringName = &"inventory.layout.ordered_list"
## Never registered with a renderer by [method register_builtin_defaults] and
## never returned for a recognized `native_layout_kind` -- exists so an
## actually-unrecognized layout kind resolves to "no renderer" ([method
## renderer_for] returning [code]null[/code]) rather than silently aliasing
## onto one of the three built-ins ("unknown layout has no renderer",
## inventory-presentation spec). A game MAY register its own renderer against
## this token if it wants a deliberate fallback UI instead of the explicit
## unsupported-layout state.
const LAYOUT_UNKNOWN: StringName = &"inventory.layout.unknown"

## container_definition_identifier (String) -> PackedScene|Script. Checked
## before [member _by_layout].
var _by_container_definition: Dictionary = {}
## layout kind token (StringName) -> PackedScene|Script.
var _by_layout: Dictionary = {}


## `InventoryContainerDefinition.LAYOUT_SPATIAL_GRID`/`LAYOUT_NAMED_SLOTS`/
## `LAYOUT_ORDERED_LIST` (the native enum's `int` value, as read off a
## resolved `InventoryContainerDefinition` Resource) -> this registry's own
## StringName layout token. Returns [constant LAYOUT_UNKNOWN] for any value
## this addon's three built-in layouts do not declare (native/resources/
## inventory_container_definition.h's `LayoutKind` enum is exactly `{0, 1, 2}`
## today, so this is future-proofing against a later-added layout kind this
## registry has no default renderer for, not a currently-reachable case).
static func layout_kind_token(native_layout_kind: int) -> StringName:
	match native_layout_kind:
		0: # InventoryContainerDefinition.LAYOUT_SPATIAL_GRID
			return LAYOUT_SPATIAL_GRID
		1: # InventoryContainerDefinition.LAYOUT_NAMED_SLOTS
			return LAYOUT_NAMED_SLOTS
		2: # InventoryContainerDefinition.LAYOUT_ORDERED_LIST
			return LAYOUT_ORDERED_LIST
		_:
			return LAYOUT_UNKNOWN


## Registers [param renderer] ([PackedScene] or [Script]) for [param layout_kind]
## (one of this class's `LAYOUT_*` tokens, or a game-defined
## [StringName] for a game-supplied layout kind). Overwrites any existing
## registration for the same token -- "a game replaces any entry" is meant
## literally, including a built-in default.
func register_renderer(layout_kind: StringName, renderer: Variant) -> void:
	_by_layout[layout_kind] = renderer


## Registers [param renderer] for exactly one container-definition-identifier,
## overriding whatever [method register_renderer] would otherwise resolve for
## that container's layout kind.
func register_renderer_for_container_definition(container_definition_identifier: String, renderer: Variant) -> void:
	_by_container_definition[container_definition_identifier] = renderer


func unregister_renderer(layout_kind: StringName) -> void:
	_by_layout.erase(layout_kind)


func unregister_renderer_for_container_definition(container_definition_identifier: String) -> void:
	_by_container_definition.erase(container_definition_identifier)


## True if some renderer (container-definition override or layout-kind
## default) would resolve for [param container_info].
func has_renderer_for(container_info: Dictionary) -> bool:
	return _resolve(container_info) != null


## [param container_info]: [code]{container_definition_identifier: String,
## layout_kind: int}[/code]. NOTE: a snapshot's own container entries (
## [method InventorySnapshotResource.get_containers]) carry
## `container_definition_identifier` but NOT `layout_kind` -- that lives on
## the catalog-side `InventoryContainerDefinition` Resource, not the runtime
## snapshot DTO. Composing this Dictionary from a resolved container
## definition (or any other source of its declared layout) is the caller's
## job (deferred composition work, tasks.md 8.4); this registry only resolves
## once the caller already has both fields, and also accepts a pre-resolved
## `layout_kind_token: StringName` key instead of `layout_kind: int` if the
## caller already computed one via [method layout_kind_token]. Returns the
## registered [PackedScene]/[Script], or [code]null[/code] if neither the
## container-definition override nor the layout-kind default is registered
## ("unknown layout has no renderer" -- inventory-presentation spec).
func renderer_for(container_info: Dictionary) -> Variant:
	return _resolve(container_info)


func _resolve(container_info: Dictionary) -> Variant:
	var identifier := String(container_info.get("container_definition_identifier", ""))
	if not identifier.is_empty() and _by_container_definition.has(identifier):
		return _by_container_definition[identifier]
	var layout_token: StringName
	if container_info.has("layout_kind_token"):
		layout_token = container_info["layout_kind_token"]
	else:
		layout_token = layout_kind_token(int(container_info.get("layout_kind", 0)))
	return _by_layout.get(layout_token, null)


## Instantiates the renderer resolved for [param container_info]. Returns
## [code]null[/code] (an explicit unsupported-layout signal -- "does not
## display a misleading mutable fallback", inventory-presentation spec) when
## no renderer resolves, OR when the resolved resource is neither a
## [PackedScene] nor an instantiable [Control]-deriving [Script] -- this
## method never raises a script error for a malformed registration, it just
## fails to produce a control.
func instantiate_for(container_info: Dictionary) -> Control:
	var renderer: Variant = _resolve(container_info)
	if renderer == null:
		return null
	if renderer is PackedScene:
		var instance: Node = (renderer as PackedScene).instantiate()
		return instance as Control
	if renderer is Script:
		var script: Script = renderer
		if not script.can_instantiate():
			return null
		var instance: Variant = script.new()
		return instance as Control
	return null


## Registers this addon's three built-in container controls
## (`InventorySpatialGridControl`, `InventoryNamedSlotsControl`,
## `InventoryOrderedListControl`) against their matching `LAYOUT_*` token.
## Called once by a host that wants the shipped defaults; a game that wants
## to replace one or all of them calls [method register_renderer] afterward
## (or instead, if it wants no defaults at all).
func register_builtin_defaults() -> void:
	register_renderer(LAYOUT_SPATIAL_GRID, InventorySpatialGridControl)
	register_renderer(LAYOUT_NAMED_SLOTS, InventoryNamedSlotsControl)
	register_renderer(LAYOUT_ORDERED_LIST, InventoryOrderedListControl)
