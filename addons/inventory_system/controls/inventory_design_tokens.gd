class_name InventoryDesignTokens
extends Resource

## The non-Theme half of the `inventory.design.*` token namespace (DESIGN.md
## §3.1, point 2): "values Godot's [Theme] has no item for: motion durations/
## easings, density multipliers, breakpoints in units, and the base spacing
## unit." Everything ELSE in DESIGN.md §3 (colors, StyleBoxes, radius, border,
## font sizes) is a [Theme] item, applied through Theme Type Variations by
## [InventoryThemeFactory] -- see that script's header comment for why the
## split lands exactly here.
##
## Controls MUST derive every geometry value as [code]unit * N[/code] through
## this resource ([method unit], [method grid_cell_px], [method card_padding_px])
## -- never a literal pixel constant -- so a single [member ui_scale] change
## rescales the whole system (DESIGN.md §8, §10.2).
##
## [member density] is a per-session presentation setting, not baked into any
## one profile or snapshot (DESIGN.md §4: "the same snapshot renders in any
## density") -- this resource carries all three densities' multipliers and
## tracks which one is currently active, so switching density at runtime is
## just reassigning [member density] on the shared tokens instance every
## control already reads from.

enum Density {
	COMPACT,
	STANDARD,
	COMFORTABLE,
}

## `inventory.design.spacing.unit` (DESIGN.md §3.6): the base logical-px unit
## at [member ui_scale] == 1.0.
@export var base_unit_px: float = 8.0

@export_group("Density: grid cell size (units)", "grid_cell_units_")
## `inventory.design.spacing` density table (DESIGN.md §4): Compact = 4u.
@export var grid_cell_units_compact: float = 4.0
## Standard = 5u.
@export var grid_cell_units_standard: float = 5.0
## Comfortable = 6u (also the WCAG touch-target minimum, §8/§11.5).
@export var grid_cell_units_comfortable: float = 6.0

@export_group("Density: card padding (units)", "card_padding_units_")
@export var card_padding_units_compact: float = 0.5
@export var card_padding_units_standard: float = 1.0
@export var card_padding_units_comfortable: float = 1.5

@export_group("Density: default body type step", "default_body_type_step_")
## Names a `InventoryDesignTokens` typography step, applied by controls as
## the Theme font-size item to use for a primitive's default body text
## (DESIGN.md §3.5 names the sizes; §4 names which step is the default per
## density). Not a pixel value itself -- [InventoryThemeFactory] carries the
## actual sizes.
@export var default_body_type_step_compact: StringName = &"body_sm"
@export var default_body_type_step_standard: StringName = &"body_md"
@export var default_body_type_step_comfortable: StringName = &"body_lg"

## The ACTIVE density for this session. Desktop mouse/keyboard defaults to
## STANDARD; a host switches to COMFORTABLE for touch/gamepad-primary input
## or the accessibility "large targets" preference, and to COMPACT only as an
## explicit opt-in power-user setting (DESIGN.md §4 -- COMPACT is never a
## platform default).
@export var density: Density = Density.STANDARD

@export_group("Scale")
## One of the declared steps (DESIGN.md §10.2): 0.8, 0.9, 1.0, 1.1, 1.25, 1.5,
## 2.0. Not validated/snapped here -- a host picks the nearest declared step
## for the reported display scale/DPI before assigning this.
@export var ui_scale: float = 1.0
## Independent accessibility toggle (§10.2): multiplies ONLY the typography
## scale by +25%, never spacing/cell geometry. [InventoryThemeFactory] reads
## this when building font-size Theme items.
@export var large_text_enabled: bool = false

@export_group("Breakpoints (units)")
## `inventory.design.breakpoint.stacked_max_width_units` (§8): panes reflow
## from side-by-side to stacked below this width, in units at [member ui_scale].
@export var stacked_max_width_units: float = 100.0

@export_group("Motion durations (ms)", "duration_")
## `inventory.design.motion.duration_instant` (§3.8).
@export var duration_instant_ms: int = 0
@export var duration_fast_ms: int = 80
@export var duration_base_ms: int = 140
@export var duration_slow_ms: int = 220
@export var duration_deliberate_ms: int = 320

@export_group("Motion easing")
## `inventory.design.motion.ease_standard`.
@export var ease_standard_transition: Tween.TransitionType = Tween.TRANS_CUBIC
@export var ease_standard_type: Tween.EaseType = Tween.EASE_OUT
## `inventory.design.motion.ease_emphasized_decelerate`.
@export var ease_emphasized_decelerate_transition: Tween.TransitionType = Tween.TRANS_QUINT
@export var ease_emphasized_decelerate_type: Tween.EaseType = Tween.EASE_OUT
## `inventory.design.motion.ease_emphasized_accelerate`.
@export var ease_emphasized_accelerate_transition: Tween.TransitionType = Tween.TRANS_QUINT
@export var ease_emphasized_accelerate_type: Tween.EaseType = Tween.EASE_IN
## `inventory.design.motion.ease_linear` -- looping pulses only (§3.8).
@export var ease_linear_transition: Tween.TransitionType = Tween.TRANS_LINEAR
@export var ease_linear_type: Tween.EaseType = Tween.EASE_IN_OUT

## `inventory.design.motion.reduced_motion_enabled`: read once per
## presentation session from the game's accessibility setting (or OS-level
## "reduce motion"). Gates every §9 motion row except drag-ghost follow and
## the focus ring (DESIGN.md §9's own carve-out).
@export var reduced_motion_enabled: bool = false


## `unit_effective` (§10.2): [code]unit_base * ui_scale[/code].
func unit_effective() -> float:
	return base_unit_px * ui_scale


## [code]N * unit_effective()[/code] -- the one primitive every geometry value
## in a control must be expressed through (DESIGN.md §8's "no hard-coded
## pixel geometry" rule).
func unit(multiple: float) -> float:
	return multiple * unit_effective()


func grid_cell_units() -> float:
	match density:
		Density.COMPACT:
			return grid_cell_units_compact
		Density.COMFORTABLE:
			return grid_cell_units_comfortable
		_:
			return grid_cell_units_standard


func grid_cell_px() -> float:
	return unit(grid_cell_units())


func card_padding_units() -> float:
	match density:
		Density.COMPACT:
			return card_padding_units_compact
		Density.COMFORTABLE:
			return card_padding_units_comfortable
		_:
			return card_padding_units_standard


func card_padding_px() -> float:
	return unit(card_padding_units())


func default_body_type_step() -> StringName:
	match density:
		Density.COMPACT:
			return default_body_type_step_compact
		Density.COMFORTABLE:
			return default_body_type_step_comfortable
		_:
			return default_body_type_step_standard


## Typography scale multiplier applied on top of a Theme font-size item
## (§10.2's independent large-text toggle): 1.25 when [member large_text_enabled],
## else 1.0.
func type_scale() -> float:
	return 1.25 if large_text_enabled else 1.0


## Milliseconds for [param token], one of `&"instant"`, `&"fast"`, `&"base"`,
## `&"slow"`, `&"deliberate"`. 0 (== instant) for an unrecognized token.
## [member reduced_motion_enabled] is NOT applied here -- whether a given
## animated element even plays under reduced motion is a per-element policy
## (DESIGN.md §9's table), decided by the caller, not this lookup.
func duration_ms(token: StringName) -> int:
	match token:
		&"fast":
			return duration_fast_ms
		&"base":
			return duration_base_ms
		&"slow":
			return duration_slow_ms
		&"deliberate":
			return duration_deliberate_ms
		_:
			return duration_instant_ms
