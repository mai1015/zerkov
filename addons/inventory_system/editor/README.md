# Inventory editor tools

This directory holds `plugin.gd`, the addon's `EditorPlugin` entry point: a
"Validate Inventory Catalog" Project > Tools menu action that runs
`InventoryCatalog.validate_resource()` (the same runtime-side validator a
game calls before registering) over a user-selected `InventoryCatalogResource`
or every one found under `res://`, printing bounded, stable-path diagnostics
(`{status_code, diagnostic, detail, identifier, source}`).

Manifest inspection, layout previews, and richer authoring workflows remain
reserved for a later slice. Editor acceptance never replaces runtime
authority validation -- `validate_resource()` never registers into a live
catalog, and a game's own `InventoryCatalog.register_*()`/`seal()` calls
re-validate everything regardless of what the editor already accepted.
