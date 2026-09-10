class_name InventoryPendingOverlay
extends Control

## Reusable "pending" (in-flight authoritative command) decoration --
## DESIGN.md §12's `pending` row: "dashed outline + in-flight glyph, label on
## inspect", approximated here by the `state_pending` StyleBox plus a drawn
## [InventoryStateIcons] icon (real dashed-outline drawing is deferred per
## DESIGN.md §13). §11.2's "label on inspect" phrasing is deliberate: the
## "Pending" TEXT lives on [InventoryTooltip]/inspect surfaces, not baked
## into this overlay -- this stays icon-only, matching visual-qa-2026-07-27.md
## finding 1's fix (a Label used to render the raw `InventoryStateGlyphs`
## token string literally here instead). Same reuse shape as
## [InventorySelectionOverlay]: any primitive adds one as a full-rect child
## and calls [method refresh] whenever the model's pending state for it might
## have changed.

var _panel: Panel
var _glyph_icon: TextureRect


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# See InventorySelectionOverlay._init()'s comment: deliberately not
	# full-rect anchored on this outer control, which callers position/size
	# explicitly as a sibling of the primitive it decorates.
	visible = false
	_panel = Panel.new()
	_panel.name = "PendingPanel"
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_panel)

	_glyph_icon = TextureRect.new()
	_glyph_icon.name = "PendingGlyph"
	_glyph_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_glyph_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_glyph_icon.texture = InventoryStateIcons.icon_for(InventoryStateGlyphs.glyph_for_item_state(InventoryPresentationModel.STATE_PENDING))
	_glyph_icon.modulate = InventoryThemeFactory.state_icon_color(InventoryPresentationModel.STATE_PENDING)
	# Centered, inset by a size FRACTION rather than a `tokens.unit()` value:
	# this reusable primitive is always sized by its own caller to the exact
	# token-derived footprint it decorates (see class doc comment above), so
	# an anchor fraction stays proportionate to that footprint without this
	# primitive needing its own [InventoryDesignTokens] reference/parameter.
	_glyph_icon.anchor_left = 0.25
	_glyph_icon.anchor_top = 0.25
	_glyph_icon.anchor_right = 0.75
	_glyph_icon.anchor_bottom = 0.75
	add_child(_glyph_icon)


## [param type_name]: which Theme Type Variation to pull the `pending` state
## StyleBox from -- [constant InventoryThemeFactory.TYPE_ITEM_CARD] by
## default; pass TYPE_GRID_CELL/TYPE_SLOT/TYPE_LIST_ROW to match whichever
## primitive this overlay decorates.
func refresh(active: bool, type_name: StringName = &"InventoryItemCard") -> void:
	visible = active
	if not active:
		return
	var stylebox := get_theme_stylebox(
			InventoryThemeFactory.state_stylebox_name(InventoryPresentationModel.STATE_PENDING), type_name)
	if stylebox != null:
		_panel.add_theme_stylebox_override(&"panel", stylebox)


## Test/inspection accessor -- proving a real drawn texture renders here, not
## raw glyph-token text.
func glyph_icon_texture() -> Texture2D:
	return _glyph_icon.texture
