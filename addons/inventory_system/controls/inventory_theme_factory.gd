class_name InventoryThemeFactory
extends RefCounted

## Builds the addon's default [Theme] resource in code (tasks.md 8.3's "author
## a .tres or build programmatically -- pick the more maintainable, explain").
##
## CHOICE: programmatic, not a hand-authored `.tres`. A `.tres` [Theme] is a
## flat, unstructured list of `type/item_name = value` lines with no comments,
## grouping, or derivation -- reviewing or diffing a change to one color
## across 10 Type Variations and ~10 states each (DESIGN.md §12) in that
## format is effectively unreviewable, and every derived value (§3.4's hover/
## pressed/disabled deltas) would have to be hand-computed and pasted in
## rather than computed once from the §3.2/§3.3 anchor colors. Building it in
## GDScript keeps DESIGN.md's token tables and this factory's code in
## 1:1-reviewable correspondence, computes every state-delta color from its
## anchor via [method Color.lightened]/[method Color.darkened] instead of
## duplicating pre-computed hex, and is trivially callable from a headless
## test with no `.tres` load path involved at all.
##
## Registers Theme Type Variations for every primitive DESIGN.md §3.1 names
## (`InventoryContainerPanel`, `InventoryItemCard`, `InventoryGridCell`,
## `InventorySlot`, `InventoryListRow`, `InventoryTooltip`,
## `InventoryContextMenu`, `InventoryActionBarEntry`, `InventoryDragGhost`,
## `InventoryModal`) with their §3.2/§3.3 base colors. The five primitives
## this wave's controls actually render dynamic per-item/per-container state
## for (`InventoryContainerPanel`, `InventoryItemCard`, `InventoryGridCell`,
## `InventorySlot`, `InventoryListRow`) additionally get one named StyleBox
## per DESIGN.md §12 state that applies to them (see [method state_stylebox_name]
## for the naming convention controls use to look these up) -- this IS the
## "state -> theme-variation mapping table" 8.7 asks for, expressed as data
## inside the [Theme] resource itself rather than a separate GDScript table,
## so a game can restyle or add states by editing the [Theme] alone.
##
## Radius/border/elevation-derived shadow constants (§3.7) and typography
## sizes (§3.5) are Theme constant/font_size items here, NOT
## [InventoryDesignTokens] fields -- DESIGN.md §3.1 assigns exactly those to
## the Theme, reserving [InventoryDesignTokens] for values Theme has no item
## for (motion, density, breakpoints, the base unit). See
## [InventoryDesignTokens]'s header comment for the other half of this split.

const TYPE_CONTAINER_PANEL: StringName = &"InventoryContainerPanel"
const TYPE_DISCOVERY_CONTAINER: StringName = &"InventoryDiscoveryContainer"
const TYPE_DISCOVERY_ENTRY: StringName = &"InventoryDiscoveryEntry"
const TYPE_ITEM_CARD: StringName = &"InventoryItemCard"
const TYPE_GRID_CELL: StringName = &"InventoryGridCell"
const TYPE_SLOT: StringName = &"InventorySlot"
const TYPE_LIST_ROW: StringName = &"InventoryListRow"
const TYPE_TOOLTIP: StringName = &"InventoryTooltip"
const TYPE_CONTEXT_MENU: StringName = &"InventoryContextMenu"
const TYPE_ACTION_BAR_ENTRY: StringName = &"InventoryActionBarEntry"
const TYPE_DRAG_GHOST: StringName = &"InventoryDragGhost"
const TYPE_MODAL: StringName = &"InventoryModal"

# -- §3.2 surface/structure colors -------------------------------------------
const COLOR_SURFACE := Color("#1b1e22")
const COLOR_SURFACE_RAISED := Color("#24272c")
const COLOR_SURFACE_POPOVER := Color("#2b2f35")
const COLOR_SURFACE_OVERLAY := Color(0.05098, 0.05490, 0.06275, 0.72)
const COLOR_GRID_LINE := Color("#4a4f57")
const COLOR_BORDER := Color("#3c414a")
const COLOR_TEXT_PRIMARY := Color("#e8e9ec")
const COLOR_TEXT_SECONDARY := Color("#a8acb3")
const COLOR_TEXT_DISABLED := Color("#6c7078")
const COLOR_CELL_FREE := Color(0, 0, 0, 0) # "transparent (= surface)" -- §3.2.
const COLOR_CELL_BLOCKED := Color("#171a1d")
const COLOR_CELL_FILTERED := Color(0.36078, 0.29020, 0.16471, 0.20)

# -- §3.3 semantic state colors -----------------------------------------------
const COLOR_ACCENT := Color("#d7a53a")
const COLOR_INFO := Color("#7cb3d9")
const COLOR_POSITIVE := Color("#5fbf72")
const COLOR_WARNING := Color("#d99a3f")
const COLOR_DANGER := Color("#c04a34")
const COLOR_PENDING := Color("#8a84c9")
const COLOR_PROTECTED := Color("#4fa9a3")
const COLOR_REDACTED := Color("#666a70")

# -- §3.7 radius/border ------------------------------------------------------
const RADIUS_NONE := 0
const RADIUS_SM := 2
const RADIUS_MD := 4
const BORDER_HAIRLINE := 1
const BORDER_STANDARD := 2
const BORDER_FOCUS := 2

# -- §3.4 focus ring -----------------------------------------------------
## `inventory.design.focus.ring_offset` (§3.4): the gap, in the same literal
## px unit as [constant BORDER_FOCUS]/[constant BORDER_STANDARD] above (this
## factory does not scale border/offset constants by [InventoryDesignTokens]
## today -- see [method build_default_theme]'s doc comment), between a
## control's own edge and its drawn focus ring (DESIGN.md §11.3). No Theme
## StyleBox item carries an "offset" concept (a stylebox border is drawn AT
## the control edge, not outside it), so this stays a plain factory constant
## a control's own `_draw()` reads directly, exactly like every other §3.7
## constant in this section.
const FOCUS_RING_OFFSET := 2

# -- §3.5 typography scale (px @ ui_scale 1.0) -- registered as custom
# font_size Theme items (any name is a valid Theme font_size key, not just
# "font_size") so a control looks these up by their DESIGN.md name directly,
# e.g. [code]card.get_theme_font_size(&"numeric_md", InventoryThemeFactory.TYPE_ITEM_CARD)[/code].
const TYPE_STEP_SIZES := {
	&"display": 28, &"heading": 20, &"subheading": 16,
	&"body_lg": 15, &"body_md": 13, &"body_sm": 11, &"caption": 10,
	&"numeric_lg": 16, &"numeric_md": 13, &"numeric_sm": 11,
}


## `"state_" + state.replace("-", "_")` -- the StyleBox item name a control
## looks up for [param state] (one of [InventoryPresentationModel]'s
## `STATE_*` tokens) within one of the five dynamically-styled Type
## Variations. Shared between this factory (which registers under these
## names) and every control that reads a state stylebox, so the two can never
## drift apart.
static func state_stylebox_name(state: StringName) -> StringName:
	return StringName("state_%s" % String(state).replace("-", "_"))


## The icon-tint [Color] for [param state] -- one of [InventoryPresentationModel]'s
## `STATE_*` tokens OR one of [InventoryDragGhost]'s drag-only `drop-*` tokens
## (a distinct vocabulary, DESIGN.md §12.9) -- matching the exact color this
## factory already uses as that SAME state's stylebox OUTLINE/border color
## above (see [method _build_item_card]/[method _build_drag_ghost]), so an
## icon overlay a control modulates by this never drifts from its own state's
## border color into a second, independently-maintained color table.
## Deliberately keyed by STATE/DROP token, never by glyph NAME
## ([InventoryStateGlyphs]'s return value): several distinct states share one
## glyph (`lock_redacted` covers redacted/read-only/inaccessible/
## drop-inaccessible alike) but resolve to different semantic colors here, so
## a glyph-keyed table would be ambiguous where a state-keyed one is not.
## Falls back to [constant COLOR_TEXT_PRIMARY] for any token this table
## doesn't recognize (a state with no icon at all, e.g. `normal`/`selected`,
## never calls this -- callers only reach here once [method
## InventoryStateGlyphs.glyph_for_item_state]/the drag ghost's own drop-glyph
## lookup already produced a non-empty token).
static func state_icon_color(state: StringName) -> Color:
	match state:
		InventoryPresentationModel.STATE_ACCEPTED, &"drop-valid":
			return COLOR_POSITIVE
		InventoryPresentationModel.STATE_REJECTED, &"drop-invalid":
			return COLOR_DANGER
		InventoryPresentationModel.STATE_STALE_CORRECTED:
			return COLOR_INFO
		InventoryPresentationModel.STATE_REDACTED:
			return COLOR_REDACTED
		InventoryPresentationModel.STATE_READ_ONLY:
			return COLOR_TEXT_SECONDARY
		InventoryPresentationModel.STATE_DISCONNECTED:
			return COLOR_DANGER
		InventoryPresentationModel.STATE_RESYNCHRONIZING:
			return COLOR_INFO
		InventoryPresentationModel.STATE_PENDING:
			return COLOR_PENDING
		InventoryPresentationModel.STATE_DISCOVERY_UNSEARCHED:
			return COLOR_REDACTED
		InventoryPresentationModel.STATE_DISCOVERY_UNKNOWN:
			return COLOR_REDACTED
		InventoryPresentationModel.STATE_DISCOVERY_SEARCHING:
			return COLOR_INFO
		InventoryPresentationModel.STATE_DISCOVERY_INDEXED:
			return COLOR_PROTECTED
		InventoryPresentationModel.STATE_DISCOVERY_SCANNING:
			return COLOR_PENDING
		&"drop-occupied":
			return COLOR_WARNING
		&"drop-filtered":
			return COLOR_DANGER
		&"drop-overweight":
			return COLOR_WARNING
		&"drop-inaccessible":
			return COLOR_DANGER
		_:
			return COLOR_TEXT_PRIMARY


static func _lightened(color: Color, amount: float) -> Color:
	return color.lightened(amount) if amount >= 0.0 else color.darkened(-amount)


## §3.4's `delta_disabled`: -10% lightness, -80% chroma, 50% alpha.
static func _disabled_delta(color: Color) -> Color:
	var desaturated := Color.from_hsv(color.h, color.s * 0.2, color.v, color.a)
	var darkened := desaturated.darkened(0.10)
	darkened.a = 0.5
	return darkened


static func _box(bg: Color, border: Color, border_width: int, radius: int) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = bg
	box.border_color = border
	box.set_border_width_all(border_width)
	box.set_corner_radius_all(radius)
	return box


static func _outline_box(fill: Color, outline: Color, width: int, radius: int) -> StyleBoxFlat:
	var box := _box(fill, outline, width, radius)
	return box


## Builds the complete default [Theme]. [param tokens] supplies nothing to
## THIS build step today (every value below is a fixed DESIGN.md constant,
## not density/scale-dependent) but is accepted so a future revision can
## derive a scale-dependent Theme (e.g. border widths that grow with
## [member InventoryDesignTokens.ui_scale]) without changing every call site's
## signature.
static func build_default_theme(_tokens: InventoryDesignTokens = null) -> Theme:
	var theme := Theme.new()

	_build_container_panel(theme)
	_build_discovery_container(theme)
	_build_discovery_entry(theme)
	_build_item_card(theme)
	_build_grid_cell(theme)
	_build_slot(theme)
	_build_list_row(theme)
	_build_tooltip(theme)
	_build_context_menu(theme)
	_build_action_bar_entry(theme)
	_build_drag_ghost(theme)
	_build_modal(theme)

	return theme


static func _register_type_steps(theme: Theme, type_name: StringName) -> void:
	for step_name in TYPE_STEP_SIZES:
		theme.set_font_size(step_name, type_name, TYPE_STEP_SIZES[step_name])


static func _set_state_styles(theme: Theme, type_name: StringName, states: Dictionary) -> void:
	for state in states:
		theme.set_stylebox(state_stylebox_name(state), type_name, states[state])


# -- §12.5 InventoryContainerPanel -------------------------------------------
static func _build_container_panel(theme: Theme) -> void:
	var type_name := TYPE_CONTAINER_PANEL
	theme.set_type_variation(type_name, &"PanelContainer")
	theme.set_color(&"font_color", type_name, COLOR_TEXT_PRIMARY)
	theme.set_color(&"header_secondary_color", type_name, COLOR_TEXT_SECONDARY)
	_register_type_steps(theme, type_name)

	var normal := _box(COLOR_SURFACE, COLOR_BORDER, BORDER_STANDARD, RADIUS_NONE)
	theme.set_stylebox(&"panel", type_name, normal)

	_set_state_styles(theme, type_name, {
		InventoryPresentationModel.STATE_NORMAL: normal,
		&"focus": _outline_box(COLOR_SURFACE, COLOR_ACCENT, BORDER_FOCUS, RADIUS_NONE),
		&"stale-corrected": _outline_box(COLOR_SURFACE, COLOR_INFO, BORDER_STANDARD, RADIUS_NONE),
		InventoryPresentationModel.STATE_REDACTED: _outline_box(COLOR_REDACTED.darkened(0.3), COLOR_REDACTED, BORDER_STANDARD, RADIUS_NONE),
		InventoryPresentationModel.STATE_READ_ONLY: _outline_box(COLOR_SURFACE, COLOR_TEXT_SECONDARY, BORDER_HAIRLINE, RADIUS_NONE),
		&"disabled": _box(_disabled_delta(COLOR_SURFACE), _disabled_delta(COLOR_BORDER), BORDER_STANDARD, RADIUS_NONE),
		InventoryPresentationModel.STATE_DISCONNECTED: _outline_box(_disabled_delta(COLOR_SURFACE), COLOR_DANGER, BORDER_STANDARD, RADIUS_NONE),
		InventoryPresentationModel.STATE_RESYNCHRONIZING: _outline_box(COLOR_SURFACE, COLOR_INFO, BORDER_STANDARD, RADIUS_NONE),
		InventoryPresentationModel.STATE_LOADING: _box(COLOR_SURFACE, COLOR_BORDER.darkened(0.1), BORDER_HAIRLINE, RADIUS_NONE),
		InventoryPresentationModel.STATE_EMPTY: normal,
		&"overflow": _outline_box(COLOR_SURFACE, COLOR_WARNING, BORDER_HAIRLINE, RADIUS_NONE),
		InventoryPresentationModel.STATE_INACCESSIBLE: _outline_box(COLOR_SURFACE.darkened(0.1), COLOR_DANGER, BORDER_STANDARD, RADIUS_NONE),
		InventoryPresentationModel.STATE_OVERWEIGHT: _outline_box(COLOR_SURFACE, COLOR_WARNING, BORDER_STANDARD, RADIUS_NONE),
		# Ad hoc (not one of [InventoryPresentationModel]'s formal STATE_*
		# tokens, exactly like `stale-corrected` above) -- a transient
		# highlight [InventoryTwoPaneView] applies when tasks.md 8.5's
		# double-click/context-menu/keyboard "open" affordance opens this
		# container's section, so a player's eye lands on the right place
		# immediately. Same accent hue as the focus ring (§11.3/§3.3).
		&"opened": _outline_box(COLOR_SURFACE, COLOR_ACCENT, BORDER_STANDARD * 2, RADIUS_NONE),
	})


# -- §12.11 InventoryDiscoveryContainer -------------------------------------
static func _build_discovery_container(theme: Theme) -> void:
	var type_name := TYPE_DISCOVERY_CONTAINER
	theme.set_type_variation(type_name, &"Panel")
	theme.set_color(&"font_color", type_name, COLOR_TEXT_PRIMARY)
	theme.set_color(&"secondary_font_color", type_name, COLOR_TEXT_SECONDARY)
	theme.set_color(&"progress_track_color", type_name, COLOR_BORDER)
	theme.set_color(&"progress_fill_color", type_name, COLOR_INFO)
	theme.set_color(&"unknown_color", type_name, COLOR_REDACTED)
	theme.set_color(&"indexed_color", type_name, COLOR_PROTECTED)
	_register_type_steps(theme, type_name)

	var normal := _box(COLOR_SURFACE, COLOR_BORDER, BORDER_STANDARD, RADIUS_NONE)
	theme.set_stylebox(&"panel", type_name, normal)
	_set_state_styles(theme, type_name, {
		InventoryPresentationModel.STATE_NORMAL: normal,
		InventoryPresentationModel.STATE_DISCOVERY_UNSEARCHED:
				_outline_box(COLOR_SURFACE, COLOR_REDACTED, BORDER_STANDARD, RADIUS_NONE),
		InventoryPresentationModel.STATE_DISCOVERY_SEARCHING:
				_outline_box(COLOR_SURFACE, COLOR_INFO, BORDER_STANDARD, RADIUS_NONE),
		InventoryPresentationModel.STATE_DISCOVERY_INDEXED:
				_outline_box(COLOR_SURFACE, COLOR_PROTECTED, BORDER_STANDARD, RADIUS_NONE),
		InventoryPresentationModel.STATE_PENDING:
				_outline_box(COLOR_SURFACE, COLOR_PENDING, BORDER_STANDARD, RADIUS_NONE),
		InventoryPresentationModel.STATE_STALE_CORRECTED:
				_outline_box(COLOR_SURFACE, COLOR_INFO, BORDER_STANDARD, RADIUS_NONE),
		InventoryPresentationModel.STATE_DISCONNECTED:
				_outline_box(_disabled_delta(COLOR_SURFACE), COLOR_DANGER, BORDER_STANDARD, RADIUS_NONE),
		InventoryPresentationModel.STATE_RESYNCHRONIZING:
				_outline_box(COLOR_SURFACE, COLOR_INFO, BORDER_STANDARD, RADIUS_NONE),
	})


# -- §12.11 InventoryDiscoveryEntry -----------------------------------------
static func _build_discovery_entry(theme: Theme) -> void:
	var type_name := TYPE_DISCOVERY_ENTRY
	theme.set_type_variation(type_name, &"Button")
	theme.set_color(&"font_color", type_name, COLOR_TEXT_PRIMARY)
	theme.set_color(&"font_disabled_color", type_name, COLOR_TEXT_DISABLED)
	theme.set_color(&"icon_normal_color", type_name, COLOR_REDACTED)
	theme.set_color(&"icon_hover_color", type_name, _lightened(COLOR_REDACTED, 0.05))
	theme.set_color(&"icon_pressed_color", type_name, _lightened(COLOR_REDACTED, -0.06))
	theme.set_color(&"icon_focus_color", type_name, COLOR_ACCENT)
	_register_type_steps(theme, type_name)

	var normal := _box(COLOR_SURFACE_RAISED, COLOR_REDACTED, BORDER_HAIRLINE, RADIUS_SM)
	theme.set_stylebox(&"normal", type_name, normal)
	theme.set_stylebox(&"hover", type_name,
			_box(_lightened(COLOR_SURFACE_RAISED, 0.05), _lightened(COLOR_REDACTED, 0.05), BORDER_HAIRLINE, RADIUS_SM))
	theme.set_stylebox(&"pressed", type_name,
			_box(_lightened(COLOR_SURFACE_RAISED, -0.06), _lightened(COLOR_REDACTED, -0.06), BORDER_HAIRLINE, RADIUS_SM))
	theme.set_stylebox(&"focus", type_name,
			_outline_box(COLOR_SURFACE_RAISED, COLOR_ACCENT, BORDER_FOCUS, RADIUS_SM))
	theme.set_stylebox(&"disabled", type_name,
			_box(_disabled_delta(COLOR_SURFACE_RAISED), _disabled_delta(COLOR_REDACTED), BORDER_HAIRLINE, RADIUS_SM))
	_set_state_styles(theme, type_name, {
		InventoryPresentationModel.STATE_DISCOVERY_UNKNOWN: normal,
		InventoryPresentationModel.STATE_DISCOVERY_SCANNING:
				_outline_box(COLOR_SURFACE_RAISED, COLOR_PENDING, BORDER_STANDARD, RADIUS_SM),
		InventoryPresentationModel.STATE_PENDING:
				_outline_box(COLOR_SURFACE_RAISED, COLOR_PENDING, BORDER_STANDARD, RADIUS_SM),
		InventoryPresentationModel.STATE_STALE_CORRECTED:
				_outline_box(COLOR_SURFACE_RAISED, COLOR_INFO, BORDER_STANDARD, RADIUS_SM),
		InventoryPresentationModel.STATE_DISCONNECTED:
				_outline_box(_disabled_delta(COLOR_SURFACE_RAISED), COLOR_DANGER, BORDER_HAIRLINE, RADIUS_SM),
		InventoryPresentationModel.STATE_RESYNCHRONIZING:
				_outline_box(COLOR_SURFACE_RAISED, COLOR_INFO, BORDER_HAIRLINE, RADIUS_SM),
	})


# -- §12.1 InventoryItemCard --------------------------------------------------
static func _build_item_card(theme: Theme) -> void:
	var type_name := TYPE_ITEM_CARD
	theme.set_type_variation(type_name, &"Control")
	theme.set_color(&"font_color", type_name, COLOR_TEXT_PRIMARY)
	theme.set_color(&"secondary_font_color", type_name, COLOR_TEXT_SECONDARY)
	theme.set_color(&"positive_color", type_name, COLOR_POSITIVE)
	theme.set_color(&"warning_color", type_name, COLOR_WARNING)
	theme.set_color(&"danger_color", type_name, COLOR_DANGER)
	theme.set_color(&"protected_color", type_name, COLOR_PROTECTED)
	theme.set_constant(&"corner_radius", type_name, RADIUS_SM)
	_register_type_steps(theme, type_name)

	var normal := _box(COLOR_SURFACE_RAISED, COLOR_BORDER, BORDER_STANDARD, RADIUS_SM)
	theme.set_stylebox(&"panel", type_name, normal)

	_set_state_styles(theme, type_name, {
		InventoryPresentationModel.STATE_NORMAL: normal,
		&"hover": _box(_lightened(COLOR_SURFACE_RAISED, 0.05), _lightened(COLOR_BORDER, 0.05), BORDER_STANDARD, RADIUS_SM),
		&"focus": _outline_box(COLOR_SURFACE_RAISED, COLOR_ACCENT, BORDER_FOCUS, RADIUS_SM),
		InventoryPresentationModel.STATE_SELECTED: _outline_box(COLOR_SURFACE_RAISED, COLOR_ACCENT, BORDER_STANDARD * 2, RADIUS_SM),
		&"pressed": _box(_lightened(COLOR_SURFACE_RAISED, -0.06), _lightened(COLOR_BORDER, -0.06), BORDER_STANDARD, RADIUS_SM),
		&"dragging": _box(COLOR_SURFACE_RAISED, COLOR_BORDER, BORDER_STANDARD, RADIUS_SM),
		&"drop-valid": _outline_box(COLOR_SURFACE_RAISED, COLOR_POSITIVE, BORDER_STANDARD, RADIUS_SM),
		&"drop-invalid": _outline_box(COLOR_SURFACE_RAISED, COLOR_DANGER, BORDER_STANDARD * 2, RADIUS_SM),
		&"drop-occupied": _outline_box(COLOR_SURFACE_RAISED, COLOR_WARNING, BORDER_STANDARD, RADIUS_SM),
		&"drop-filtered": _outline_box(CELL_FILTERED_WASH(), COLOR_DANGER, BORDER_STANDARD, RADIUS_SM),
		# `drop-overweight`/`drop-inaccessible` are the DRAG-PREVIEW states (the
		# controller's `_DIAGNOSTIC_DROP_STATES` diagnostic->DROP_* mapping,
		# InventoryDragGhost's own `DROP_OVERWEIGHT`/`DROP_INACCESSIBLE`
		# constants) -- a DISTINCT vocabulary from the container-scoped
		# `STATE_OVERWEIGHT`/`STATE_INACCESSIBLE` tokens registered right below
		# (which style a container that genuinely IS overweight/inaccessible as
		# an ongoing condition, never an item card). Registering under the
		# `state_*` name `state_stylebox_name()` derives from the STATE_* tokens
		# alone previously left `state_drop_overweight`/`state_drop_inaccessible`
		# -- what the drop-preview lookup actually asks for -- unregistered, so
		# both states silently rendered baseline (docs/inventory/
		# visual-qa-2026-07-27.md finding 2).
		&"drop-overweight": _outline_box(COLOR_SURFACE_RAISED, COLOR_WARNING, BORDER_STANDARD, RADIUS_SM),
		&"drop-inaccessible": _outline_box(COLOR_SURFACE_RAISED.darkened(0.1), COLOR_DANGER, BORDER_STANDARD, RADIUS_SM),
		InventoryPresentationModel.STATE_OVERWEIGHT: _outline_box(COLOR_SURFACE_RAISED, COLOR_WARNING, BORDER_STANDARD, RADIUS_SM),
		InventoryPresentationModel.STATE_INACCESSIBLE: _outline_box(COLOR_SURFACE_RAISED.darkened(0.1), COLOR_DANGER, BORDER_STANDARD, RADIUS_SM),
		InventoryPresentationModel.STATE_PENDING: _outline_box(COLOR_SURFACE_RAISED, COLOR_PENDING, BORDER_STANDARD, RADIUS_SM),
		InventoryPresentationModel.STATE_ACCEPTED: _outline_box(COLOR_SURFACE_RAISED, COLOR_POSITIVE, BORDER_STANDARD, RADIUS_SM),
		InventoryPresentationModel.STATE_REJECTED: _outline_box(COLOR_SURFACE_RAISED, COLOR_DANGER, BORDER_STANDARD, RADIUS_SM),
		InventoryPresentationModel.STATE_STALE_CORRECTED: _outline_box(COLOR_SURFACE_RAISED, COLOR_INFO, BORDER_STANDARD, RADIUS_SM),
		InventoryPresentationModel.STATE_REDACTED: _box(COLOR_REDACTED.darkened(0.4), COLOR_REDACTED, BORDER_STANDARD, RADIUS_SM),
		InventoryPresentationModel.STATE_READ_ONLY: _box(COLOR_SURFACE_RAISED, COLOR_TEXT_SECONDARY, BORDER_HAIRLINE, RADIUS_SM),
		&"disabled": _box(_disabled_delta(COLOR_SURFACE_RAISED), _disabled_delta(COLOR_BORDER), BORDER_STANDARD, RADIUS_SM),
		&"loading": _box(_lightened(COLOR_SURFACE_RAISED, -0.03), COLOR_BORDER, BORDER_HAIRLINE, RADIUS_SM),
		InventoryPresentationModel.STATE_DISCONNECTED: _box(_disabled_delta(COLOR_SURFACE_RAISED), COLOR_DANGER, BORDER_STANDARD, RADIUS_SM),
		InventoryPresentationModel.STATE_RESYNCHRONIZING: _outline_box(COLOR_SURFACE_RAISED, COLOR_INFO, BORDER_STANDARD, RADIUS_SM),
	})


static func CELL_FILTERED_WASH() -> Color:
	return COLOR_CELL_FILTERED


# -- §12.2 InventoryGridCell --------------------------------------------------
static func _build_grid_cell(theme: Theme) -> void:
	var type_name := TYPE_GRID_CELL
	theme.set_type_variation(type_name, &"Control")
	theme.set_color(&"grid_line_color", type_name, COLOR_GRID_LINE)

	var normal := _box(COLOR_CELL_FREE, COLOR_GRID_LINE, BORDER_HAIRLINE, RADIUS_NONE)
	theme.set_stylebox(&"panel", type_name, normal)

	_set_state_styles(theme, type_name, {
		InventoryPresentationModel.STATE_NORMAL: normal,
		&"hover": _box(COLOR_CELL_FREE, _lightened(COLOR_GRID_LINE, 0.05), BORDER_HAIRLINE, RADIUS_NONE),
		&"focus": _outline_box(COLOR_CELL_FREE, COLOR_ACCENT, BORDER_FOCUS, RADIUS_NONE),
		&"drop-valid": _outline_box(COLOR_CELL_FREE, COLOR_POSITIVE, BORDER_STANDARD, RADIUS_NONE),
		&"drop-invalid": _outline_box(COLOR_CELL_FREE, COLOR_DANGER, BORDER_STANDARD, RADIUS_NONE),
		&"drop-filtered": _outline_box(CELL_FILTERED_WASH(), COLOR_DANGER, BORDER_STANDARD, RADIUS_NONE),
		# See InventoryItemCard's identical `drop-overweight`/`drop-inaccessible`
		# comment above -- same wrong-name defect, same fix.
		&"drop-overweight": _outline_box(COLOR_CELL_FREE, COLOR_WARNING, BORDER_STANDARD, RADIUS_NONE),
		&"drop-inaccessible": _outline_box(COLOR_CELL_FREE, COLOR_DANGER, BORDER_STANDARD, RADIUS_NONE),
		InventoryPresentationModel.STATE_OVERWEIGHT: _outline_box(COLOR_CELL_FREE, COLOR_WARNING, BORDER_STANDARD, RADIUS_NONE),
		InventoryPresentationModel.STATE_INACCESSIBLE: _outline_box(COLOR_CELL_FREE, COLOR_DANGER, BORDER_STANDARD, RADIUS_NONE),
		InventoryPresentationModel.STATE_REDACTED: _box(COLOR_REDACTED.darkened(0.4), COLOR_REDACTED, BORDER_HAIRLINE, RADIUS_NONE),
		InventoryPresentationModel.STATE_READ_ONLY: _box(COLOR_CELL_FREE, COLOR_TEXT_SECONDARY, BORDER_HAIRLINE, RADIUS_NONE),
		InventoryPresentationModel.STATE_EMPTY: normal,
		&"disabled": _box(COLOR_CELL_BLOCKED, _disabled_delta(COLOR_GRID_LINE), BORDER_HAIRLINE, RADIUS_NONE),
		&"loading": _box(_lightened(COLOR_SURFACE, 0.03), COLOR_GRID_LINE, BORDER_HAIRLINE, RADIUS_NONE),
		InventoryPresentationModel.STATE_DISCONNECTED: _box(_disabled_delta(COLOR_CELL_FREE), _disabled_delta(COLOR_GRID_LINE), BORDER_HAIRLINE, RADIUS_NONE),
		InventoryPresentationModel.STATE_RESYNCHRONIZING: _outline_box(CELL_FILTERED_WASH(), COLOR_INFO, BORDER_HAIRLINE, RADIUS_NONE),
	})


# -- §12.3 InventorySlot ------------------------------------------------------
static func _build_slot(theme: Theme) -> void:
	var type_name := TYPE_SLOT
	theme.set_type_variation(type_name, &"Control")
	theme.set_color(&"font_color", type_name, COLOR_TEXT_DISABLED)
	_register_type_steps(theme, type_name)

	var normal := _box(COLOR_SURFACE, COLOR_BORDER, BORDER_STANDARD, RADIUS_SM)
	theme.set_stylebox(&"panel", type_name, normal)

	_set_state_styles(theme, type_name, {
		InventoryPresentationModel.STATE_NORMAL: normal,
		InventoryPresentationModel.STATE_EMPTY: normal,
		&"hover": _box(_lightened(COLOR_SURFACE, 0.05), _lightened(COLOR_BORDER, 0.05), BORDER_STANDARD, RADIUS_SM),
		&"focus": _outline_box(COLOR_SURFACE, COLOR_ACCENT, BORDER_FOCUS, RADIUS_SM),
		InventoryPresentationModel.STATE_SELECTED: _outline_box(COLOR_SURFACE, COLOR_ACCENT, BORDER_STANDARD * 2, RADIUS_SM),
		&"pressed": _box(_lightened(COLOR_SURFACE, -0.06), _lightened(COLOR_BORDER, -0.06), BORDER_STANDARD, RADIUS_SM),
		&"drop-valid": _outline_box(COLOR_SURFACE, COLOR_POSITIVE, BORDER_STANDARD, RADIUS_SM),
		&"drop-invalid": _outline_box(COLOR_SURFACE, COLOR_DANGER, BORDER_STANDARD, RADIUS_SM),
		&"drop-occupied": _outline_box(COLOR_SURFACE, COLOR_WARNING, BORDER_STANDARD, RADIUS_SM),
		&"drop-filtered": _outline_box(CELL_FILTERED_WASH(), COLOR_DANGER, BORDER_STANDARD, RADIUS_SM),
		# See InventoryItemCard's identical `drop-overweight`/`drop-inaccessible`
		# comment above -- same wrong-name defect, same fix.
		&"drop-overweight": _outline_box(COLOR_SURFACE, COLOR_WARNING, BORDER_STANDARD, RADIUS_SM),
		&"drop-inaccessible": _outline_box(COLOR_SURFACE.darkened(0.1), COLOR_DANGER, BORDER_STANDARD, RADIUS_SM),
		InventoryPresentationModel.STATE_OVERWEIGHT: _outline_box(COLOR_SURFACE, COLOR_WARNING, BORDER_STANDARD, RADIUS_SM),
		InventoryPresentationModel.STATE_INACCESSIBLE: _outline_box(COLOR_SURFACE.darkened(0.1), COLOR_DANGER, BORDER_STANDARD, RADIUS_SM),
		InventoryPresentationModel.STATE_PENDING: _outline_box(COLOR_SURFACE, COLOR_PENDING, BORDER_STANDARD, RADIUS_SM),
		InventoryPresentationModel.STATE_ACCEPTED: _outline_box(COLOR_SURFACE, COLOR_POSITIVE, BORDER_STANDARD, RADIUS_SM),
		InventoryPresentationModel.STATE_REJECTED: _outline_box(COLOR_SURFACE, COLOR_DANGER, BORDER_STANDARD, RADIUS_SM),
		InventoryPresentationModel.STATE_STALE_CORRECTED: _outline_box(COLOR_SURFACE, COLOR_INFO, BORDER_STANDARD, RADIUS_SM),
		InventoryPresentationModel.STATE_REDACTED: _box(COLOR_REDACTED.darkened(0.4), COLOR_REDACTED, BORDER_STANDARD, RADIUS_SM),
		InventoryPresentationModel.STATE_READ_ONLY: _box(COLOR_SURFACE, COLOR_TEXT_SECONDARY, BORDER_HAIRLINE, RADIUS_SM),
		&"disabled": _box(_disabled_delta(COLOR_SURFACE), _disabled_delta(COLOR_BORDER), BORDER_STANDARD, RADIUS_SM),
		&"loading": _box(_lightened(COLOR_SURFACE, -0.03), COLOR_BORDER, BORDER_HAIRLINE, RADIUS_SM),
		InventoryPresentationModel.STATE_DISCONNECTED: _box(_disabled_delta(COLOR_SURFACE), COLOR_DANGER, BORDER_STANDARD, RADIUS_SM),
		InventoryPresentationModel.STATE_RESYNCHRONIZING: _outline_box(COLOR_SURFACE, COLOR_INFO, BORDER_STANDARD, RADIUS_SM),
	})


# -- §12.4 InventoryListRow ---------------------------------------------------
static func _build_list_row(theme: Theme) -> void:
	var type_name := TYPE_LIST_ROW
	theme.set_type_variation(type_name, &"Control")
	theme.set_color(&"font_color", type_name, COLOR_TEXT_PRIMARY)
	_register_type_steps(theme, type_name)

	var normal := _box(COLOR_SURFACE_RAISED, COLOR_SURFACE_RAISED, 0, RADIUS_NONE)
	theme.set_stylebox(&"panel", type_name, normal)

	_set_state_styles(theme, type_name, {
		InventoryPresentationModel.STATE_NORMAL: normal,
		&"hover": _box(_lightened(COLOR_SURFACE_RAISED, 0.05), _lightened(COLOR_SURFACE_RAISED, 0.05), 0, RADIUS_NONE),
		&"focus": _outline_box(COLOR_SURFACE_RAISED, COLOR_ACCENT, BORDER_FOCUS, RADIUS_NONE),
		InventoryPresentationModel.STATE_SELECTED: _box_left_bar(COLOR_SURFACE_RAISED, COLOR_ACCENT),
		&"pressed": _box(_lightened(COLOR_SURFACE_RAISED, -0.06), _lightened(COLOR_SURFACE_RAISED, -0.06), 0, RADIUS_NONE),
		&"dragging": _box(_lightened(COLOR_SURFACE_RAISED, -0.03), COLOR_SURFACE_RAISED, 0, RADIUS_NONE),
		&"drop-valid": _outline_box(COLOR_SURFACE_RAISED, COLOR_POSITIVE, BORDER_STANDARD, RADIUS_NONE),
		&"drop-invalid": _outline_box(COLOR_SURFACE_RAISED, COLOR_DANGER, BORDER_STANDARD, RADIUS_NONE),
		&"drop-filtered": _outline_box(CELL_FILTERED_WASH(), COLOR_DANGER, BORDER_STANDARD, RADIUS_NONE),
		# See InventoryItemCard's identical `drop-overweight`/`drop-inaccessible`
		# comment above -- same wrong-name defect, same fix.
		&"drop-overweight": _outline_box(COLOR_SURFACE_RAISED, COLOR_WARNING, BORDER_STANDARD, RADIUS_NONE),
		&"drop-inaccessible": _outline_box(COLOR_SURFACE_RAISED.darkened(0.1), COLOR_DANGER, BORDER_STANDARD, RADIUS_NONE),
		InventoryPresentationModel.STATE_OVERWEIGHT: _outline_box(COLOR_SURFACE_RAISED, COLOR_WARNING, BORDER_STANDARD, RADIUS_NONE),
		InventoryPresentationModel.STATE_INACCESSIBLE: _outline_box(COLOR_SURFACE_RAISED.darkened(0.1), COLOR_DANGER, BORDER_STANDARD, RADIUS_NONE),
		InventoryPresentationModel.STATE_PENDING: _outline_box(COLOR_SURFACE_RAISED, COLOR_PENDING, BORDER_HAIRLINE, RADIUS_NONE),
		InventoryPresentationModel.STATE_ACCEPTED: _outline_box(COLOR_SURFACE_RAISED, COLOR_POSITIVE, BORDER_HAIRLINE, RADIUS_NONE),
		InventoryPresentationModel.STATE_REJECTED: _outline_box(COLOR_SURFACE_RAISED, COLOR_DANGER, BORDER_HAIRLINE, RADIUS_NONE),
		InventoryPresentationModel.STATE_STALE_CORRECTED: _outline_box(COLOR_SURFACE_RAISED, COLOR_INFO, BORDER_HAIRLINE, RADIUS_NONE),
		InventoryPresentationModel.STATE_REDACTED: _box(COLOR_REDACTED.darkened(0.4), COLOR_REDACTED, 0, RADIUS_NONE),
		InventoryPresentationModel.STATE_READ_ONLY: _box(COLOR_SURFACE_RAISED, COLOR_TEXT_SECONDARY, 0, RADIUS_NONE),
		&"disabled": _box(_disabled_delta(COLOR_SURFACE_RAISED), _disabled_delta(COLOR_SURFACE_RAISED), 0, RADIUS_NONE),
		&"loading": _box(_lightened(COLOR_SURFACE_RAISED, -0.03), COLOR_SURFACE_RAISED, 0, RADIUS_NONE),
		InventoryPresentationModel.STATE_DISCONNECTED: _box(_disabled_delta(COLOR_SURFACE_RAISED), COLOR_DANGER, 0, RADIUS_NONE),
		InventoryPresentationModel.STATE_RESYNCHRONIZING: _outline_box(COLOR_SURFACE_RAISED, COLOR_INFO, BORDER_HAIRLINE, RADIUS_NONE),
	})


## §12.4 "selected: 3px accent bar at leading edge" -- a left border wide
## enough to read as a distinct bar rather than a hairline outline.
static func _box_left_bar(bg: Color, bar_color: Color) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = bg
	box.border_color = bar_color
	box.border_width_left = 3
	return box


# -- Base-color-only Type Variations (§6.4, §12.6-§12.10; full per-state
# coverage for these five is 8.4/8.5/8.6 (two-pane composition, drag/drop,
# context menu/action-bar wiring), all explicitly deferred past this wave). -

## §12.6 InventoryTooltip -- every applicable row uses the `state_*`
## convention uniformly (including `normal`): unlike [Button], [PopupPanel]
## has no native per-state style switching this addon would otherwise
## collide with, so there is no reason to special-case any row the way
## [method _build_action_bar_entry] must for its [Button] base.
static func _build_tooltip(theme: Theme) -> void:
	var type_name := TYPE_TOOLTIP
	theme.set_type_variation(type_name, &"PopupPanel")
	theme.set_color(&"font_color", type_name, COLOR_TEXT_PRIMARY)
	_register_type_steps(theme, type_name)

	var normal := _box(COLOR_SURFACE_POPOVER, COLOR_BORDER, BORDER_HAIRLINE, RADIUS_MD)
	theme.set_stylebox(&"panel", type_name, normal)
	_set_state_styles(theme, type_name, {
		InventoryPresentationModel.STATE_NORMAL: normal,
		&"stale-corrected": _outline_box(COLOR_SURFACE_POPOVER, COLOR_INFO, BORDER_HAIRLINE, RADIUS_MD),
		InventoryPresentationModel.STATE_REDACTED: _box(COLOR_REDACTED.darkened(0.4), COLOR_REDACTED, BORDER_HAIRLINE, RADIUS_MD),
		InventoryPresentationModel.STATE_READ_ONLY: _box(COLOR_SURFACE_POPOVER, COLOR_TEXT_SECONDARY, BORDER_HAIRLINE, RADIUS_MD),
		&"loading": _box(_lightened(COLOR_SURFACE_POPOVER, -0.03), COLOR_BORDER, BORDER_HAIRLINE, RADIUS_MD),
		InventoryPresentationModel.STATE_DISCONNECTED: _box(_disabled_delta(COLOR_SURFACE_POPOVER), COLOR_DANGER, BORDER_HAIRLINE, RADIUS_MD),
		&"overflow": _outline_box(COLOR_SURFACE_POPOVER, COLOR_WARNING, BORDER_HAIRLINE, RADIUS_MD),
		InventoryPresentationModel.STATE_RESYNCHRONIZING: _outline_box(COLOR_SURFACE_POPOVER, COLOR_INFO, BORDER_HAIRLINE, RADIUS_MD),
	})


## §12.7 InventoryContextMenu -- same "uniform `state_*`" rationale as
## [method _build_tooltip] ([PopupMenu] base, not [Button]).
static func _build_context_menu(theme: Theme) -> void:
	var type_name := TYPE_CONTEXT_MENU
	theme.set_type_variation(type_name, &"PopupMenu")
	theme.set_color(&"font_color", type_name, COLOR_TEXT_PRIMARY)
	_register_type_steps(theme, type_name)

	var normal := _box(COLOR_SURFACE_POPOVER, COLOR_BORDER, BORDER_HAIRLINE, RADIUS_MD)
	theme.set_stylebox(&"panel", type_name, normal)
	_set_state_styles(theme, type_name, {
		InventoryPresentationModel.STATE_NORMAL: normal,
		&"hover": _box(_lightened(COLOR_SURFACE_POPOVER, 0.05), COLOR_BORDER, BORDER_HAIRLINE, RADIUS_MD),
		&"focus": _outline_box(COLOR_SURFACE_POPOVER, COLOR_ACCENT, BORDER_FOCUS, RADIUS_MD),
		InventoryPresentationModel.STATE_SELECTED: _outline_box(COLOR_SURFACE_POPOVER, COLOR_ACCENT, BORDER_STANDARD, RADIUS_MD),
		&"pressed": _box(_lightened(COLOR_SURFACE_POPOVER, -0.06), COLOR_BORDER, BORDER_HAIRLINE, RADIUS_MD),
		InventoryPresentationModel.STATE_PENDING: _outline_box(COLOR_SURFACE_POPOVER, COLOR_PENDING, BORDER_HAIRLINE, RADIUS_MD),
		InventoryPresentationModel.STATE_REJECTED: _outline_box(COLOR_SURFACE_POPOVER, COLOR_DANGER, BORDER_HAIRLINE, RADIUS_MD),
		InventoryPresentationModel.STATE_READ_ONLY: _box(COLOR_SURFACE_POPOVER, COLOR_TEXT_SECONDARY, BORDER_HAIRLINE, RADIUS_MD),
		&"disabled": _box(_disabled_delta(COLOR_SURFACE_POPOVER), _disabled_delta(COLOR_BORDER), BORDER_HAIRLINE, RADIUS_MD),
		InventoryPresentationModel.STATE_EMPTY: normal,
		&"loading": _box(_lightened(COLOR_SURFACE_POPOVER, -0.03), COLOR_BORDER, BORDER_HAIRLINE, RADIUS_MD),
		InventoryPresentationModel.STATE_DISCONNECTED: _box(_disabled_delta(COLOR_SURFACE_POPOVER), COLOR_DANGER, BORDER_HAIRLINE, RADIUS_MD),
		&"overflow": _outline_box(COLOR_SURFACE_POPOVER, COLOR_WARNING, BORDER_HAIRLINE, RADIUS_MD),
		InventoryPresentationModel.STATE_RESYNCHRONIZING: _outline_box(COLOR_SURFACE_POPOVER, COLOR_INFO, BORDER_HAIRLINE, RADIUS_MD),
	})


## §12.8 InventoryActionBarEntry -- a [Button], so `normal`/`hover`/`pressed`/
## `disabled`/`focus` stay on [Button]'s OWN native theme-item names (Godot
## switches these automatically from the control's own interaction state);
## only the custom states Godot has no native concept of (pending/
## accepted-flash/rejected/read-only/disconnected/resynchronizing) use the
## `state_*` convention, matching every other dynamically-styled primitive.
static func _build_action_bar_entry(theme: Theme) -> void:
	var type_name := TYPE_ACTION_BAR_ENTRY
	theme.set_type_variation(type_name, &"Button")
	theme.set_color(&"font_color", type_name, COLOR_TEXT_PRIMARY)
	_register_type_steps(theme, type_name)
	var normal := _box(COLOR_SURFACE_RAISED, COLOR_BORDER, BORDER_HAIRLINE, RADIUS_SM)
	theme.set_stylebox(&"normal", type_name, normal)
	theme.set_stylebox(&"hover", type_name, _box(_lightened(COLOR_SURFACE_RAISED, 0.05), COLOR_BORDER, BORDER_HAIRLINE, RADIUS_SM))
	theme.set_stylebox(&"pressed", type_name, _box(_lightened(COLOR_SURFACE_RAISED, -0.06), COLOR_BORDER, BORDER_HAIRLINE, RADIUS_SM))
	theme.set_stylebox(&"disabled", type_name, _box(_disabled_delta(COLOR_SURFACE_RAISED), _disabled_delta(COLOR_BORDER), BORDER_HAIRLINE, RADIUS_SM))
	theme.set_stylebox(&"focus", type_name, _outline_box(COLOR_SURFACE_RAISED, COLOR_ACCENT, BORDER_FOCUS, RADIUS_SM))

	_set_state_styles(theme, type_name, {
		InventoryPresentationModel.STATE_PENDING: _outline_box(COLOR_SURFACE_RAISED, COLOR_PENDING, BORDER_HAIRLINE, RADIUS_SM),
		InventoryPresentationModel.STATE_ACCEPTED: _outline_box(COLOR_SURFACE_RAISED, COLOR_POSITIVE, BORDER_HAIRLINE, RADIUS_SM),
		InventoryPresentationModel.STATE_REJECTED: _outline_box(COLOR_SURFACE_RAISED, COLOR_DANGER, BORDER_HAIRLINE, RADIUS_SM),
		InventoryPresentationModel.STATE_READ_ONLY: _box(COLOR_SURFACE_RAISED, COLOR_TEXT_SECONDARY, BORDER_HAIRLINE, RADIUS_SM),
		InventoryPresentationModel.STATE_DISCONNECTED: _box(_disabled_delta(COLOR_SURFACE_RAISED), COLOR_DANGER, BORDER_HAIRLINE, RADIUS_SM),
		InventoryPresentationModel.STATE_RESYNCHRONIZING: _outline_box(COLOR_SURFACE_RAISED, COLOR_INFO, BORDER_HAIRLINE, RADIUS_SM),
	})


static func _build_drag_ghost(theme: Theme) -> void:
	var type_name := TYPE_DRAG_GHOST
	theme.set_type_variation(type_name, &"Control")
	theme.set_color(&"font_color", type_name, COLOR_TEXT_PRIMARY)
	_register_type_steps(theme, type_name)

	var baseline := _box(COLOR_SURFACE_RAISED, COLOR_ACCENT, BORDER_STANDARD, RADIUS_SM)
	baseline.bg_color.a = 0.8 # §12.9 "dragging (baseline): elevation.2, 80% opacity".
	theme.set_stylebox(&"panel", type_name, baseline)

	# §12.9's drop-* rows (the only non-`n/a` states this primitive ever shows
	# -- it exists only while dragging, so `normal`/`hover`/`focus`/etc. never
	# apply and are deliberately absent here, matching the table's own "n/a"
	# entries for every state row it doesn't list).
	_set_state_styles(theme, type_name, {
		InventoryPresentationModel.STATE_NORMAL: baseline, # "dragging (baseline)" fallback when no candidate target is hovered.
		# [InventoryDragGhost]'s own `_apply_state_style()` remaps its `DROP_NONE`
		# (== `&"dragging"`) to the STATE_NORMAL lookup name above -- registered
		# here TOO, under the literal `&"dragging"` name itself, purely so this
		# Theme's own registration is complete/self-consistent under EITHER
		# name a caller might reasonably look up (both resolve to the exact
		# same baseline StyleBox instance; the ghost's real runtime lookup is
		# unaffected either way).
		&"dragging": baseline,
		&"drop-valid": _outline_box(baseline.bg_color, COLOR_POSITIVE, BORDER_STANDARD, RADIUS_SM),
		&"drop-invalid": _outline_box(baseline.bg_color, COLOR_DANGER, BORDER_STANDARD * 2, RADIUS_SM),
		&"drop-occupied": _outline_box(baseline.bg_color, COLOR_WARNING, BORDER_STANDARD, RADIUS_SM),
		&"drop-filtered": _outline_box(CELL_FILTERED_WASH(), COLOR_DANGER, BORDER_STANDARD, RADIUS_SM),
		# See InventoryItemCard's identical `drop-overweight`/`drop-inaccessible`
		# comment (in [method _build_item_card]) -- same wrong-name defect, same
		# fix; this ghost's own `_apply_state_style()` looks up EXACTLY these
		# `drop-*` names (its `_drop_state` IS one of [InventoryDragGhost]'s own
		# `DROP_*` constants), so the `STATE_OVERWEIGHT`/`STATE_INACCESSIBLE`-keyed
		# entries below never applied to this primitive at all.
		&"drop-overweight": _outline_box(baseline.bg_color, COLOR_WARNING, BORDER_STANDARD, RADIUS_SM),
		&"drop-inaccessible": _outline_box(baseline.bg_color.darkened(0.1), COLOR_DANGER, BORDER_STANDARD, RADIUS_SM),
		InventoryPresentationModel.STATE_OVERWEIGHT: _outline_box(baseline.bg_color, COLOR_WARNING, BORDER_STANDARD, RADIUS_SM),
		InventoryPresentationModel.STATE_INACCESSIBLE: _outline_box(baseline.bg_color.darkened(0.1), COLOR_DANGER, BORDER_STANDARD, RADIUS_SM),
	})


## §12.10 InventoryModal -- uniform `state_*` convention like Tooltip/
## ContextMenu ([PopupPanel] base, no native per-state switching to collide
## with).
static func _build_modal(theme: Theme) -> void:
	var type_name := TYPE_MODAL
	theme.set_type_variation(type_name, &"PopupPanel")
	theme.set_color(&"font_color", type_name, COLOR_TEXT_PRIMARY)
	_register_type_steps(theme, type_name)

	var normal := _box(COLOR_SURFACE_POPOVER, COLOR_BORDER, BORDER_STANDARD, RADIUS_MD)
	theme.set_stylebox(&"panel", type_name, normal)
	theme.set_color(&"scrim_color", type_name, COLOR_SURFACE_OVERLAY)

	_set_state_styles(theme, type_name, {
		InventoryPresentationModel.STATE_NORMAL: normal,
		&"focus": _outline_box(COLOR_SURFACE_POPOVER, COLOR_ACCENT, BORDER_FOCUS, RADIUS_MD),
		InventoryPresentationModel.STATE_PENDING: _outline_box(COLOR_SURFACE_POPOVER, COLOR_PENDING, BORDER_STANDARD, RADIUS_MD),
		InventoryPresentationModel.STATE_ACCEPTED: _outline_box(COLOR_SURFACE_POPOVER, COLOR_POSITIVE, BORDER_STANDARD, RADIUS_MD),
		InventoryPresentationModel.STATE_REJECTED: _outline_box(COLOR_SURFACE_POPOVER, COLOR_DANGER, BORDER_STANDARD, RADIUS_MD),
		&"stale-corrected": _outline_box(COLOR_SURFACE_POPOVER, COLOR_INFO, BORDER_STANDARD, RADIUS_MD),
		InventoryPresentationModel.STATE_READ_ONLY: _box(COLOR_SURFACE_POPOVER, COLOR_TEXT_SECONDARY, BORDER_HAIRLINE, RADIUS_MD),
		&"disabled": _box(_disabled_delta(COLOR_SURFACE_POPOVER), _disabled_delta(COLOR_BORDER), BORDER_STANDARD, RADIUS_MD),
		&"loading": _box(_lightened(COLOR_SURFACE_POPOVER, -0.03), COLOR_BORDER, BORDER_HAIRLINE, RADIUS_MD),
		InventoryPresentationModel.STATE_DISCONNECTED: _box(_disabled_delta(COLOR_SURFACE_POPOVER), COLOR_DANGER, BORDER_STANDARD, RADIUS_MD),
		&"overflow": _outline_box(COLOR_SURFACE_POPOVER, COLOR_WARNING, BORDER_HAIRLINE, RADIUS_MD),
		InventoryPresentationModel.STATE_RESYNCHRONIZING: _outline_box(COLOR_SURFACE_POPOVER, COLOR_INFO, BORDER_STANDARD, RADIUS_MD),
	})
