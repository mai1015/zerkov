# Asset registry validation — task 9.1

Validated 2026-09-10 on task/ef2136a6 in the isolated worktree.

## Scope

The validation covers the deterministic manifest at game/content/asset_registry.json, the typed loader and validator at game/content/zerkov_asset_registry.gd, and the focused contract at tests/raid/asset_registry_contract.gd. The narrow registry documentation update is in game/content/README.md.

No assets, Godot import metadata, project settings, UI consumers, TileSets, slicing outputs, vendored add-ons, truth specs, Forge files, or tasks.md were changed.

## Registry result

ASSET_REGISTRY_RESULT checks=1413 failures=0 entries=74 imported=62 pending=12 atlases=7 warnings=64 negative_probes=21

Manifest SHA-256: `46da7a8974cd2131de8af4631900649bdeb8304814eb9d96d22a3f9c9a7c44fd` (62 runtime hashes and 22 locally present source hashes reverified).

Independent re-review probes: `ADVERSARIAL_REVIEW_RESULT checks=26 failures=0` and `EXTRA_RESULT checks=13 failures=0`, including near-integer schema and atlas values through loader normalization.

The contract exercises deterministic SHA-256 fingerprinting, defensive copies (including direct returned-entry mutation), exact aliases and collision rejection, strict path confinement and field types, runtime and local-source byte/hash verification, positive and bounded atlas metadata with exact frame enumeration, case-insensitive forbidden-source rejection, canonical content links and license references, filtering and mipmap fields, pending-entry behavior, and exact integer-only validation for schema, versions, atlas grids, frame counts, and frame order. All 21 independent negative probes are permanent contract cases.

The manifest contains 62 imported runtime entries and 12 explicitly pending or unimported external-sheet entries. Pending entries have no runtime path or runtime hash. The three approved distribution blockers remain surfaced and are not cleared.

The six UI background provenance rows use source root `/Volumes/Data/Assets/zerkov/UI/UI` with `Background UI/<filename>` relative paths, and each locally available source digest matches its runtime digest. The Sawmill row is explicitly the 1000x800 pixel-art prop sheet with nearest filtering and mipmaps disabled; slicing remains task 9.3.

## Regression and diagnostics

All named Godot diagnostics exited zero:

- Editor import scan completed without parse or import errors.
- ADDON_SMOKE_RESULT checks=155 failures=0
- COMMON_UI_INTEGRATION_RESULT checks=76 failures=0
- UI_TEST_COMPLETE checks=944 failures=0
- INVENTORY_CATALOG_RESULT checks=537 failures=0 findings=37
- COMBAT_CONTENT_RESULT checks=79 failures=0 weapon_count=1
- Python JSON parsing and git diff --check passed.

## Packaging and blockers

- Vendor unit tests passed: 4 tests OK.
- Destination vendor snapshots passed for all six packages.
- Source vendor check remains blocked by pre-existing level_task_system drift: expected 172 files and digest 638c...d6c, found 175 files and digest dabd...676f.
- Distribution license validation intentionally remains blocked by inventory_system, weapon_system, and zerkov-handoff-and-original-art.

This evidence establishes the task-9.1 registry contract only. Import presets remain task 9.2, selected-sheet slicing remains task 9.3, and TileSet/runtime consumer wiring remains outside this change.
