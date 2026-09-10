class_name InventoryStateIcons
extends RefCounted

## Drawn-icon registry for BOTH halves of DESIGN.md §7's icon set: state
## icons (the original scope -- see [InventoryStateGlyphs], which maps a
## presentation state to a glyph-name TOKEN such as
## `valid_check`/`invalid_x`/`lock_redacted`, which every control today still
## renders as literal placeholder [Label] text) AND action glyphs (§7.2's
## context-action/action-bar row, e.g. `rotate`/`split`/`inspect` -- visual-qa
## -2026-07-27.md §10.3/finding 1 residual: [InventoryContextActions] was
## rendering the raw glyph TOKEN string as button text instead of an icon).
## This class supplies a static lookup from either kind of token to a real
## hand-authored [Texture2D] (imported from the flat SVGs under
## `addons/inventory_system/controls/icons/`).
##
## This class does NOT depend on [InventoryStateGlyphs] and does not decide
## which state maps to which token -- that mapping is untouched and stays the
## single source of truth. Wiring each control's overlay to call
## [method icon_for] instead of instantiating a [Label] is deferred to a
## later pass (per this task's brief) for STATE tokens; ACTION tokens are
## already wired by [InventoryContextActions]. This registry simply exists,
## fully populated and independently testable
## (tests/inventory_system/icons/inv_icons_main.gd).
##
## Icons are drawn in flat white (`#FFFFFF`), not a CSS-style `currentColor`
## value -- Godot's SVG importer rasterizes to a plain bitmap at import time
## with no cascading "color" context for `currentColor` to resolve against
## (it would fall back to black), and a WHITE source texture is exactly what
## a runtime `modulate`/`self_modulate` tint needs: `white * state_color ==
## state_color` per channel, so a control can multiply one shared texture by
## whichever theme state color applies (`positive`/`danger`/`warning`/`info`/
## etc., DESIGN.md §3.3) without needing a separate texture per color. A
## black source would defeat this entirely (`black * anything == black`).
##
## [member TOKENS] is exactly the set of STATE glyph names actually
## referenced today: everything [InventoryStateGlyphs] maps for item AND
## container states, plus every icon DESIGN.md §11.2's per-state table names
## (`swap`/`merge`/`filter_blocked` are in §11.2 but not in
## [InventoryStateGlyphs]'s own dictionaries, since those two currently only
## cover item/container overlay states, not drag-drop feedback).
## [member ACTION_TOKENS] is the disjoint set of §7.2's context-action/
## action-bar row entries this addon currently has real call sites for
## (`rotate`/`split`/`quick_transfer`/`auto_place`/`inspect`/`context_more`/
## `nested_container_expand`); the remaining §7.2 rows (`weight`,
## `protected_secure`, `durability`, `drag_handle`) have no consuming control
## yet and are intentionally NOT added here (same "nothing invented ahead of
## a real caller" posture as the rest of this addon). No file exists under
## `icons/` that isn't listed in [member TOKENS] or [member ACTION_TOKENS],
## and nothing is listed in either without a matching file -- both
## directions are asserted by tests/inventory_system/icons/inv_icons_main.gd.

const ICON_DIR := "res://addons/inventory_system/controls/icons/"

## Every STATE token this registry resolves, in the same order as
## DESIGN.md §7.2's table where a token appears there, with the
## `InventoryStateGlyphs`-only additions (`pending`) appended. Public so
## tests (and, later, whichever control code wires this registry in) can
## enumerate the full set without reaching into [member _TEXTURES]' keys.
const TOKENS: Array[StringName] = [
	&"valid_check",
	&"invalid_x",
	&"swap",
	&"merge",
	&"filter_blocked",
	&"overweight_warning",
	&"lock_redacted",
	&"resync",
	&"disconnected",
	&"pending",
]

## Every ACTION-glyph token this registry resolves, in DESIGN.md §7.2 table
## order. See [InventoryContextActions] for the consumer that maps a
## caller-supplied `glyph` entry to one of these via [method icon_for].
const ACTION_TOKENS: Array[StringName] = [
	&"rotate",
	&"split",
	&"quick_transfer",
	&"auto_place",
	&"inspect",
	&"discovery_search",
	&"discovery_scan",
	&"discovery_cancel",
	&"context_more",
	&"nested_container_expand",
]

## token (StringName) -> Texture2D, preloaded once at script-parse time.
const _TEXTURES: Dictionary = {
	&"valid_check": preload("res://addons/inventory_system/controls/icons/valid_check.svg"),
	&"invalid_x": preload("res://addons/inventory_system/controls/icons/invalid_x.svg"),
	&"swap": preload("res://addons/inventory_system/controls/icons/swap.svg"),
	&"merge": preload("res://addons/inventory_system/controls/icons/merge.svg"),
	&"filter_blocked": preload("res://addons/inventory_system/controls/icons/filter_blocked.svg"),
	&"overweight_warning": preload("res://addons/inventory_system/controls/icons/overweight_warning.svg"),
	&"lock_redacted": preload("res://addons/inventory_system/controls/icons/lock_redacted.svg"),
	&"resync": preload("res://addons/inventory_system/controls/icons/resync.svg"),
	&"disconnected": preload("res://addons/inventory_system/controls/icons/disconnected.svg"),
	&"pending": preload("res://addons/inventory_system/controls/icons/pending.svg"),
	&"rotate": preload("res://addons/inventory_system/controls/icons/rotate.svg"),
	&"split": preload("res://addons/inventory_system/controls/icons/split.svg"),
	&"quick_transfer": preload("res://addons/inventory_system/controls/icons/quick_transfer.svg"),
	&"auto_place": preload("res://addons/inventory_system/controls/icons/auto_place.svg"),
	&"inspect": preload("res://addons/inventory_system/controls/icons/inspect.svg"),
	&"discovery_search": preload("res://addons/inventory_system/controls/icons/discovery_search.svg"),
	&"discovery_scan": preload("res://addons/inventory_system/controls/icons/discovery_scan.svg"),
	&"discovery_cancel": preload("res://addons/inventory_system/controls/icons/discovery_cancel.svg"),
	&"context_more": preload("res://addons/inventory_system/controls/icons/context_more.svg"),
	&"nested_container_expand": preload("res://addons/inventory_system/controls/icons/nested_container_expand.svg"),
}


## True if [param token] resolves to a drawn icon in this registry.
static func has_icon(token: StringName) -> bool:
	return _TEXTURES.has(token)


## The drawn [Texture2D] for [param token], or [code]null[/code] if no icon
## is registered for it -- never raises, matching [method
## InventoryStateGlyphs.glyph_for_item_state]'s "honest, never invents"
## posture: an unknown token is a clean null, not a placeholder texture.
static func icon_for(token: StringName) -> Texture2D:
	return _TEXTURES.get(token, null)
