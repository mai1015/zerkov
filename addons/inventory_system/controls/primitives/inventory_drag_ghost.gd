class_name InventoryDragGhost
extends Control

## Reusable drag-ghost primitive (tasks.md 8.5; DESIGN.md §12.9). Exists only
## while a pointer drag or keyboard/gamepad "move-mode" placement preview is
## active -- follows the pointer/preview position 1:1 (§9's motion table: drag
## ghost follow is `duration_instant` and unaffected by the reduced-motion
## setting) and shows the CURRENT drop-validity state as a non-color
## signifier: a drawn [InventoryStateIcons] icon in the corner (DESIGN.md
## §7/§11.2/§12.9), tinted per [method InventoryThemeFactory.state_icon_color]
## -- never color alone, and never the raw glyph-name token rendered as
## literal text (visual-qa-2026-07-27.md finding 1; a placeholder [Label]
## used to do exactly that here before real icon artwork existed).
##
## Renders read-only, host-driven state: [InventoryInteractionController]
## computes validity by querying the authority façade's side-effect-free
## `fits()`/access-derived checks (never mutating) and calls [method
## set_drop_state] here purely to reflect that already-computed result -- this
## primitive itself never calls into an authority and never mutates canonical
## data, matching every other primitive in this addon.

## DESIGN.md §12's drop-target state tokens this primitive actually renders
## (every OTHER §12 state is `n/a` for a drag ghost per §12.9's own table --
## it exists only while dragging).
const DROP_VALID: StringName = &"drop-valid"
const DROP_INVALID: StringName = &"drop-invalid"
const DROP_OCCUPIED: StringName = &"drop-occupied"
const DROP_FILTERED: StringName = &"drop-filtered"
const DROP_OVERWEIGHT: StringName = &"drop-overweight"
const DROP_INACCESSIBLE: StringName = &"drop-inaccessible"
## No candidate target currently hovered -- §12.9's "dragging (baseline)" row.
const DROP_NONE: StringName = &"dragging"

var tokens: InventoryDesignTokens

var _background: Panel
var _glyph_icon: TextureRect
var _quantity_badge: Panel
var _quantity_label: Label
var _glyph_token: StringName = &""
var _drop_state: StringName = DROP_NONE
var _staged_quantity: int = 0


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE # never itself a click/drop target -- it only follows the pointer/preview.
	theme_type_variation = InventoryThemeFactory.TYPE_DRAG_GHOST
	visible = false
	_build_children()


func _build_children() -> void:
	_background = Panel.new()
	_background.name = "Background"
	_background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_background.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_background)

	_glyph_icon = TextureRect.new()
	_glyph_icon.name = "DropGlyph"
	_glyph_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_glyph_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_glyph_icon.visible = false
	add_child(_glyph_icon)

	_quantity_badge = Panel.new()
	_quantity_badge.name = "StagedQuantityBadge"
	_quantity_badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_quantity_badge.visible = false
	add_child(_quantity_badge)

	_quantity_label = Label.new()
	_quantity_label.name = "Quantity"
	_quantity_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_quantity_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_quantity_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_quantity_badge.add_child(_quantity_label)


## Begins showing the ghost sized to [param footprint_px] (the caller --
## [InventoryInteractionController]'s host -- has already resolved the dragged
## item's footprint/rotation through [param p_tokens]' `unit()`, so this
## primitive itself never invents pixel geometry).
func begin(footprint_px: Vector2, p_tokens: InventoryDesignTokens = null) -> void:
	tokens = p_tokens if p_tokens != null else InventoryDesignTokens.new()
	# `custom_minimum_size` MUST be assigned before `size`: [Control]'s own
	# `size` setter clamps up to the CURRENT `custom_minimum_size` as a floor,
	# so setting `size` first would silently keep the PREVIOUS (larger) size
	# whenever this drag's footprint is SMALLER than the previous drag's --
	# this was the root cause of a stale, oversized ghost surviving into a
	# smaller-footprint drag (e.g. a 2x3 item's ghost persisting through a
	# following 1x1 drag): shrinking `size` first got clamped back up to the
	# still-large `custom_minimum_size`, and lowering `custom_minimum_size`
	# afterward does not retroactively shrink an already-resolved `size`.
	custom_minimum_size = footprint_px
	size = footprint_px
	_drop_state = DROP_NONE
	_staged_quantity = 0
	_quantity_badge.visible = false
	_position_glyph_icon()
	_position_quantity_badge()
	_apply_state_style()
	visible = true


## Re-sizes an already-active ghost (e.g. the dragged item was rotated
## mid-drag, swapping its footprint's width/height) without resetting its
## current drop state. Same "minimum size before size" ordering as [method
## begin] and for the identical reason (shrinking on rotate must not get
## clamped to the pre-rotation footprint).
func set_footprint_px(footprint_px: Vector2) -> void:
	custom_minimum_size = footprint_px
	size = footprint_px
	_position_glyph_icon()
	_position_quantity_badge()


## Shows the fixed split-off quantity captured when Alt/Option armed the
## drag. Zero hides the badge for ordinary whole-item movement.
func set_staged_quantity(quantity: int) -> void:
	_staged_quantity = maxi(quantity, 0)
	_quantity_label.text = "x%d" % _staged_quantity
	_quantity_badge.visible = _staged_quantity > 0
	_position_quantity_badge()


func staged_quantity() -> int:
	return _staged_quantity


func is_staged_quantity_visible() -> bool:
	return _quantity_badge.visible


## Host calls this every pointer-motion/preview-move step while dragging --
## [param center_position] is the point the ghost should be CENTERED on; its
## own top-left is derived from that and the current [member size]. 1:1,
## no tween/easing, matching §9's drag-ghost-follow carve-out.
func follow_pointer(center_position: Vector2) -> void:
	position = center_position - size * 0.5


## [param state]: one of this class's `DROP_*` constants, or [constant DROP_NONE]
## when no candidate target is currently hovered.
func set_drop_state(state: StringName) -> void:
	if _drop_state == state:
		return
	_drop_state = state
	_apply_state_style()


func current_drop_state() -> StringName:
	return _drop_state


func end() -> void:
	visible = false
	_drop_state = DROP_NONE


## Test/inspection accessors -- proving the applied StyleBox/icon actually
## changed, not just this primitive's own recorded state.
func current_background_stylebox() -> StyleBox:
	return _background.get_theme_stylebox(&"panel")


## The glyph TOKEN (e.g. `"valid_check"`) this ghost's corner icon currently
## renders, or `""` at baseline (no candidate target hovered) -- kept as a
## plain string accessor (rather than removed outright) so existing coverage
## asserting "some non-empty signifier renders for every drop state" keeps
## working even though the VISUAL representation is now a drawn icon, not
## text (visual-qa-2026-07-27.md finding 1).
func drop_glyph_text() -> String:
	return String(_glyph_token)


## The drawn [Texture2D] this ghost's corner icon currently shows (`null` at
## baseline).
func drop_glyph_icon_texture() -> Texture2D:
	return _glyph_icon.texture


func _apply_state_style() -> void:
	var type_name := InventoryThemeFactory.TYPE_DRAG_GHOST
	var lookup_state := _drop_state if _drop_state != DROP_NONE else InventoryPresentationModel.STATE_NORMAL
	var stylebox := get_theme_stylebox(InventoryThemeFactory.state_stylebox_name(lookup_state), type_name)
	if stylebox == null:
		stylebox = get_theme_stylebox(&"panel", type_name)
	if stylebox != null:
		_background.add_theme_stylebox_override(&"panel", stylebox)

	_glyph_token = _glyph_for_drop_state(_drop_state)
	var icon := InventoryStateIcons.icon_for(_glyph_token)
	_glyph_icon.texture = icon
	_glyph_icon.visible = icon != null
	if icon != null:
		_glyph_icon.modulate = InventoryThemeFactory.state_icon_color(_drop_state)


## DESIGN.md §12.9's "corner glyph" -- top-right, sized/inset in token units
## independent of this ghost's own (possibly multi-cell) footprint size,
## rather than the full-rect-centered placement a placeholder Label used
## before real icon artwork existed.
func _position_glyph_icon() -> void:
	var icon_size := tokens.unit(1.5) if tokens != null else 24.0
	var margin := tokens.unit(0.25) if tokens != null else 4.0
	_glyph_icon.size = Vector2(icon_size, icon_size)
	_glyph_icon.position = Vector2(size.x - icon_size - margin, margin)


func _position_quantity_badge() -> void:
	if _quantity_badge == null:
		return
	var badge_size := Vector2(
			tokens.unit(2.0) if tokens != null else 32.0,
			tokens.unit(1.25) if tokens != null else 20.0)
	var margin := tokens.unit(0.25) if tokens != null else 4.0
	_quantity_badge.size = badge_size
	_quantity_badge.position = Vector2(
			maxf(size.x - badge_size.x - margin, 0.0),
			maxf(size.y - badge_size.y - margin, 0.0))
	_quantity_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var stylebox := get_theme_stylebox(&"panel", InventoryThemeFactory.TYPE_CONTEXT_MENU)
	if stylebox != null:
		_quantity_badge.add_theme_stylebox_override(&"panel", stylebox)


## DESIGN.md §12.9's "corner glyph" column, by drop state. Mirrors
## [InventoryStateGlyphs]' item/container tables but keyed by this primitive's
## OWN `DROP_*` vocabulary (drop-preview states are never one of
## [InventoryPresentationModel]'s item/container `STATE_*` tokens -- they are
## a distinct, transient, drag-only vocabulary introduced by tasks.md 8.5).
static func _glyph_for_drop_state(state: StringName) -> StringName:
	match state:
		DROP_VALID:
			return &"valid_check"
		DROP_INVALID:
			return &"invalid_x"
		DROP_OCCUPIED:
			return &"swap"
		DROP_FILTERED:
			return &"filter_blocked"
		DROP_OVERWEIGHT:
			return &"overweight_warning"
		DROP_INACCESSIBLE:
			return &"lock_redacted"
		_:
			return &""
