# Resource Authoring Guide

How to define trait schemas, items, containers, constraints, profiles, and
limits as editor-visible `.tres` resources (or built in code, as the contract
test suite does); how they are validated and registered; the identifier
rule they all share; and the editor's "Validate Inventory Catalog" tool.

Every class under `native/resources/` is pure data — none of them validate,
resolve references, or intern identifiers themselves. All of that happens in
`InventoryCatalog` (`native/godot/inventory_catalog.h`), which runs the exact
same core registry (`inv::DefinitionCatalog`) whether the call comes from a
game's own bootstrap code, the editor's validate tool, or a native test. See
[`api.md`](api.md) for the full property/enum reference of every resource
class named below.

## The 9 authoring resource types

| Class | Registers via | Role |
|---|---|---|
| `InventoryTraitSchema` | `register_trait_schema()` | Declares one trait identity: version, whether it is authority-affecting, and its payload budget. |
| `InventoryItemTraitValue` | (embedded in `InventoryItemDefinition.traits`) | One typed trait attached to an item — an opaque, already-canonical byte payload. |
| `InventoryItemDefinition` | `register_item()` | Stack limit, mass, spatial footprint, rotation permission, traits, and provided containers. |
| `InventoryNamedSlot` | (embedded in `InventoryContainerDefinition.named_slots`) | One stable slot on a `NAMED_SLOTS` container (e.g. `headwear`, `weapon_primary`). |
| `InventoryContainerConstraints` | (embedded in `InventoryContainerDefinition.constraints`) | Composable capacity/filter/access/nesting/retention/stack-split/auto-place/quick-transfer policy. |
| `InventoryContainerDefinition` | `register_container()` | One ownership layout (`SPATIAL_GRID` / `NAMED_SLOTS` / `ORDERED_LIST`) plus its constraints and enabled feature modules. |
| `InventoryProfileLimits` | (embedded in `InventoryProfileDefinition.limits`) | Per-inventory aggregate bounds (items/containers/references/nesting/mutable components). |
| `InventoryProfileDefinition` | `register_profile()` | An inventory's stable root containers, enabled command features, and aggregate limits. `InventoryAuthority.create_inventory()` instantiates one runtime per profile identifier. |
| `InventoryCatalogResource` | `register_catalog_resource()` | Aggregates the 4 top-level arrays above for one-call registration. |

## The identifier rule

Every `identifier`/trait-reference/feature-reference string in this addon
follows one grammar (`docs/inventory/contracts.md`, "Stable identifiers"):

```text
segment ("." segment)+
segment := [a-z][a-z0-9_]*
```

Lower-case dotted ASCII, at least 2 segments, at most 128 bytes and 8
segments. `game.item.stone` is valid; `stone` (not namespaced) and
`Game.Item.Stone` (uppercase) are not — both fail registration with
`STATUS_INVALID_IDENTIFIER`. Reserved roots: `inventory.*` (protocol),
`inventory.feature.*` (built-in feature modules), `inventory.trait.*`
(built-in trait schemas), `game.*` (repository reference content — the
convention this addon's own examples and the contract test suite use for
everything they author).

## Registering `enabled_features` correctly

A container's `enabled_features` must be a SUPERSET of every feature its
OWN layout and constraints structurally require — `seal()` computes this
same derivation internally (`native/core/inv_builtin_features.cpp`'s
`required_container_features()`) and rejects a container whose authored
`enabled_features` is missing anything it derives, with
`STATUS_INCOMPATIBLE_DEFINITION`/`FEATURE_REQUIRED` naming the missing
identifier. As a resource author, derive it yourself with this table:

| If the container has... | ...it must enable |
|---|---|
| `layout_kind == LAYOUT_SPATIAL_GRID` | `inventory.feature.spatial_grid` |
| `layout_kind == LAYOUT_NAMED_SLOTS` | `inventory.feature.named_slots` |
| `layout_kind == LAYOUT_ORDERED_LIST` | `inventory.feature.ordered_list` |
| `constraints.max_items > 0` | `inventory.feature.count_capacity` |
| `constraints.has_mass_capacity == true` | `inventory.feature.mass_capacity` |
| `constraints.required_traits`/`blocked_traits` non-empty (container OR any named slot) | `inventory.feature.filtering` |
| `constraints.allow_nesting == true` | `inventory.feature.nesting` |
| `constraints.access_mask != (ACCESS_INSERT\|ACCESS_REMOVE\|ACCESS_MOVE\|ACCESS_INSPECT)` | `inventory.feature.access` |
| `constraints.retention != RETENTION_NONE` | `inventory.feature.protected_retention` |
| `constraints.allow_stack_split == true` | `inventory.feature.stacking` |
| `constraints.allow_auto_placement == true` | `inventory.feature.auto_placement` |
| `constraints.allow_quick_transfer == true` | `inventory.feature.quick_transfer` (declarative only in V1 — see [`integration.md`](integration.md)) |
| `layout_kind == LAYOUT_SPATIAL_GRID` AND `grid_allow_rotation == true` | `inventory.feature.rotation` |

A profile's own `enabled_features` is NOT cross-checked against its
containers this way — it is only validated to name known feature module
identifiers. It is the list `InventoryAuthority.has_feature()`/
`InventoryReplicaNode.has_feature()` read, so author it to include every
feature a game's own bridge or UI needs to query with `has_feature()`
(typically the union of every root container's own `enabled_features`, as
`tests/inventory_system/contract/inv_contract_main.gd`'s fixture does).

## Built-in feature modules and trait schemas

`InventoryCatalog.register_builtin_definitions()` registers 13 feature
modules that back the derivations above without a game authoring them
(`inventory.feature.count_capacity`, `mass_capacity`, `filtering`, `nesting`,
`access`, `protected_retention`, `auto_placement`, `quick_transfer`,
`rotation`, and the 3 layout features — 13 total, `native/core/
inv_builtin_features.cpp`) plus 5 built-in trait schemas
(`inventory.trait.equipment`, `category`, `durability`, `ammunition`,
`integration`). Call it at most once before `seal()`, typically first.

`inventory.feature.discovery` is deliberately opt-in. Registering a
`InventoryCatalogResource` with a non-empty `discovery_policies` array adds
that feature automatically without changing non-discovery catalog bytes.

## Validation timing: immediate vs. deferred to `seal()`

Not every check happens at `register_*()` time — this matters when
interpreting a `validate_resource()` finding or when authoring a catalog in
pieces:

- **Immediate** (at `register_*()`): identifier grammar, schema version
  bounds, spatial-grid dimensions, named-slot cardinality, ordered-list
  capacity, a profile's `root_containers` non-emptiness, and duplicate-
  identifier collisions.
- **Deferred to `seal()`**: whether a trait reference (item trait value,
  container/slot required/blocked trait) actually names a REGISTERED trait
  schema; whether a container's `enabled_features` covers every structurally
  required feature; the feature-module dependency graph; and whether a
  profile's `root_containers` actually name registered containers.

This is why `InventoryCatalog.validate_resource()` on a single
`InventoryItemDefinition` with an unknown trait reference reports
`STATUS_OK` — a bare single-resource `validate_resource()` call never seals
its scratch catalog. To see the deferred check fire, validate a full
`InventoryCatalogResource` instead: that path DOES seal its scratch catalog,
and the seal diagnostic is the LAST entry in the returned array. See
`tests/inventory_system/contract/inv_contract_main.gd`'s
`_test_validate_resource_diagnostics()` for the executable proof of both the
immediate cases (bad identifier, a zero-dimension "ambiguous" spatial grid,
a duplicate identifier) and this deferred case.

## Building and sealing a catalog (quickstart)

```gdscript
var item := InventoryItemDefinition.new()
item.identifier = &"game.item.ration"
item.max_stack = 10
item.unit_mass_mg = 150
item.footprint_width = 1
item.footprint_height = 1

var constraints := InventoryContainerConstraints.new()
constraints.allow_stack_split = true

var container := InventoryContainerDefinition.new()
container.identifier = &"game.container.pouch"
container.layout_kind = InventoryContainerDefinition.LAYOUT_ORDERED_LIST
container.ordered_list_max_entries = 20
container.constraints = constraints
container.enabled_features = PackedStringArray(["inventory.feature.ordered_list", "inventory.feature.stacking"])

var profile := InventoryProfileDefinition.new()
profile.identifier = &"game.profile.simple"
profile.root_containers = PackedStringArray(["game.container.pouch"])
profile.enabled_features = PackedStringArray(["inventory.feature.ordered_list", "inventory.feature.stacking"])

var catalog_resource := InventoryCatalogResource.new()
catalog_resource.items = [item]
catalog_resource.containers = [container]
catalog_resource.profiles = [profile]

var catalog := InventoryCatalog.new()
catalog.register_builtin_definitions()
for finding in catalog.register_catalog_resource(catalog_resource):
    assert(int(finding["status_code"]) == InventoryCatalog.STATUS_OK, str(finding))
var seal_result := catalog.seal()
assert(int(seal_result["status_code"]) == InventoryCatalog.STATUS_OK, str(seal_result))
# catalog is now sealed and ready for InventoryAuthority.set_catalog() --
# see integration.md's Quickstart for the rest of the pipeline through to
# a UI reading a snapshot.
```

After `seal()`, mutating `item`/`container`/`profile`/`constraints` in place
has NO effect on `catalog` — registration validated and COPIED their field
values into the native catalog; the Resource objects themselves are never
retained. This is the 7.2 mutation-isolation guarantee, exercised
exhaustively (every field of every resource type, mutated after seal) by
`tests/inventory_system/contract/inv_contract_main.gd`'s
`_test_mutation_isolation()`.

## Staged discovery authoring

Create an `InventoryDiscoveryPolicy`, add it to
`InventoryCatalogResource.discovery_policies`, assign its identifier to the
staged container's `discovery_policy_identifier`, and enable
`inventory.feature.discovery` on both the container and profile. Containers
with an empty policy identifier remain instant-open, including when they
share a profile with staged roots. Durations are fixed checked milliseconds;
zero is accepted only with the matching explicit instant flag. See
[`discovery.md`](discovery.md) for the field table and
[`examples/inventory/extraction_catalog.gd`](../../../examples/inventory/extraction_catalog.gd)
for a mixed instant/staged catalog.

## The editor validator

The `InventorySystem` `EditorPlugin` (`addons/inventory_system/editor/
plugin.gd`) adds a **Project > Tools > Validate Inventory Catalog** menu
item. It walks a user-selected `InventoryCatalogResource` (the current
FileSystem-dock selection, if it names one) or, absent that, every
`InventoryCatalogResource` found under `res://`, and prints bounded, stable-
path diagnostics via `InventoryCatalog.validate_resource()` — the SAME
runtime-side validator a game calls before registering. **Editor acceptance
never replaces runtime authority validation**: `validate_resource()` never
registers into a live catalog, and a game's own `register_*()`/`seal()`
calls re-validate everything regardless of what the editor already accepted.
