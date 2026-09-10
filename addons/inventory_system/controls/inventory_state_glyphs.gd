class_name InventoryStateGlyphs
extends RefCounted

## Non-color state signifiers (DESIGN.md §11.2's per-state table, §7.2's
## required V1 icon inventory). §13 defers actual icon artwork production;
## until then every control renders the GLYPH NAME as placeholder text (a
## [Label]) instead of an icon, per this addon's task brief ("use a Label/
## placeholder texture keyed by glyph name"). Swapping in real icons later is
## then a matter of mapping these same glyph-name keys to a
## [Texture2D]/[TextureRect] instead of a [Label] inside each primitive,
## without touching the state -> glyph mapping itself.
##
## Only §7.2's DECLARED icon names are ever returned; a state with no
## dedicated icon in that table (e.g. `pending`, which §11.2 calls only an
## "in-flight glyph" without naming one) falls back to the state token itself
## as its own placeholder text, which is still honest (never invents an icon
## name DESIGN.md never declared) and still satisfies "never color alone".

const _ITEM_STATE_GLYPHS := {
	InventoryPresentationModel.STATE_ACCEPTED: &"valid_check",
	InventoryPresentationModel.STATE_REJECTED: &"invalid_x",
	InventoryPresentationModel.STATE_STALE_CORRECTED: &"resync",
	InventoryPresentationModel.STATE_REDACTED: &"lock_redacted",
	InventoryPresentationModel.STATE_READ_ONLY: &"lock_redacted",
	InventoryPresentationModel.STATE_DISCONNECTED: &"disconnected",
	InventoryPresentationModel.STATE_RESYNCHRONIZING: &"resync",
	InventoryPresentationModel.STATE_OVERWEIGHT: &"overweight_warning",
	InventoryPresentationModel.STATE_INACCESSIBLE: &"lock_redacted",
	InventoryPresentationModel.STATE_PENDING: &"pending", # No dedicated §7.2 icon; honest state-token fallback.
}

const _CONTAINER_STATE_GLYPHS := {
	InventoryPresentationModel.STATE_REDACTED: &"lock_redacted",
	InventoryPresentationModel.STATE_READ_ONLY: &"lock_redacted",
	InventoryPresentationModel.STATE_DISCONNECTED: &"disconnected",
	InventoryPresentationModel.STATE_RESYNCHRONIZING: &"resync",
	InventoryPresentationModel.STATE_OVERWEIGHT: &"overweight_warning",
	InventoryPresentationModel.STATE_INACCESSIBLE: &"lock_redacted",
}


## "" for a state that renders no overlay glyph at all (`normal`, `selected`,
## `empty`, `loading` -- selection/hover are shape-coded via border, loading
## is a skeleton shape, per DESIGN.md §12.1).
static func glyph_for_item_state(state: StringName) -> StringName:
	return _ITEM_STATE_GLYPHS.get(state, &"")


static func glyph_for_container_state(state: StringName) -> StringName:
	return _CONTAINER_STATE_GLYPHS.get(state, &"")
