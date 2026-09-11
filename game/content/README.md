# Content boundary

Zerkov-owned catalogs and authored Resources live here. Runtime content IDs
use lower-case `zerkov.*` namespaces and must be validated before registration.
No sibling add-on source or private state is copied into this directory.

## Asset registry

asset_registry.json is the deterministic source of truth for the curated
runtime asset set. ZerkovAssetRegistry loads it without deriving aliases,
frame geometry, crops, or content IDs from filenames. entries(), get_asset()
and resolve_alias() return deep copies, and validation is performed during
load so callers cannot mutate the indexed data.

Each entry records its exact res://assets/ path when imported, source-root and
source-relative provenance, applicable SHA-256 digests, family/kind, filtering
and mipmap policy, license status/reference, and optional explicit atlas
metadata. Locally present source bytes are verified against their recorded
digest; unavailable external provenance is marked explicitly rather than
claimed available. pending_unimported rows identify approved-slice source
sheets that are not yet in the repository; they do not provide runtime paths.

The six UI background rows preserve the source root and exact `Background UI/`
relative paths. The Sawmill source is a 1000x800 pixel-art prop sheet with
nearest filtering and no mipmaps; slicing remains task 9.3.

The manifest intentionally keeps the current add-on/art distribution blockers
visible. Registry presence is not license clearance. Import presets and
runtime slicing remain the responsibility of tasks 9.2 and 9.3.
