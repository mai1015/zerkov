# Godot authoring resources

This directory holds editor-visible item (`InventoryItemDefinition`), trait
(`InventoryTraitSchema`, `InventoryItemTraitValue`), container
(`InventoryContainerDefinition`, `InventoryNamedSlot`,
`InventoryContainerConstraints`), profile (`InventoryProfileDefinition`,
`InventoryProfileLimits`), and aggregate (`InventoryCatalogResource`)
Resources.

Resources are mutable authoring inputs. `InventoryCatalog`
(`native/godot/inventory_catalog.h`) validates and copies their values into a
sealed native catalog; a live Resource is never canonical authority state,
and mutating one after sealing never changes the sealed catalog's manifest
fingerprint (see `tests/integration/inventory_probe.gd`'s mutation-isolation
check).
