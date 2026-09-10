class_name InventoryContextMenu
extends PanelContainer

## Shipped context-menu primitive (tasks.md 8.3/8.5; DESIGN.md §9's "Context
## menu open" motion row, §12.7's state matrix) -- closes docs/inventory/
## visual-qa-2026-07-27.md finding 8's main gap: before this control existed,
## the ONLY context menu anywhere in the base addon was an ad hoc [PopupMenu]
## built by the QA driver itself (tests/inventory_system/visual_qa/
## inv_visual_qa_main.gd), and no shipped code ever consumed
## [method InventoryInteractionController.available_actions]/[signal
## InventoryInteractionController.context_actions_requested] to build a real,
## themed menu.
##
## ARCHITECTURE DECISION (see the task brief that introduced this file for
## the full rationale -- summarized here since it drives every theme lookup
## below): this is a [PanelContainer]/[CanvasItem]-based [Control], NOT a
## [Window]-based [PopupMenu]/[PopupPanel]. DESIGN.md §9 requires fade+scale
## motion and a [Window] is not a [CanvasItem] -- it has no `modulate` and no
## scale pivot ([InventoryTooltip.animate_appear]'s own doc comment documents
## this identical limitation, which is why THAT primitive has to animate its
## content child instead of itself; a menu with real per-entry Buttons has no
## such single "content child" to substitute). Because
## [InventoryThemeFactory] registers [constant InventoryThemeFactory.TYPE_CONTEXT_MENU]
## as a Theme Type Variation of `"PopupMenu"` (DESIGN.md §3.1's own mapping
## table), and this control's actual native base is `PanelContainer`, Godot's
## AUTOMATIC per-control theme resolution (bare `theme_type_variation` +
## `get_theme_stylebox(name)`) walks `PanelContainer`'s own native class
## chain, not `PopupMenu`'s -- empirically verified (a bare automatic "panel"
## lookup returns a DIFFERENT StyleBox object than an explicit
## `get_theme_stylebox(&"panel", InventoryThemeFactory.TYPE_CONTEXT_MENU)`
## lookup against the exact same [Theme]). Every theme item this control
## reads is therefore fetched by EXPLICIT type-name lookup and applied via
## `add_theme_stylebox_override` -- see [method apply_state]. `theme_type_variation`
## is still assigned (documentational/for any game-side Theme that DOES
## define a matching automatic entry) but this control never depends on it
## resolving anything on its own.
##
## Entries render as [Button]s under [constant InventoryThemeFactory.TYPE_ACTION_BAR_ENTRY]
## -- DESIGN.md §12.7's per-entry hover/pressed/focus/disabled rows describe
## PER-ENTRY affordances, but [InventoryThemeFactory] only registers a single
## PANEL-level `state_*` StyleBox set under [constant
## InventoryThemeFactory.TYPE_CONTEXT_MENU] (one box for the whole menu per
## named state, matching the QA driver's own state-sheet convention); there is
## no dedicated per-entry-button Theme type for this primitive. Reusing the
## already-fully-populated [constant InventoryThemeFactory.TYPE_ACTION_BAR_ENTRY]
## variation gives each entry real, free native Button hover/pressed/disabled/
## focus switching (derived from the same §3.4 state-delta anchors DESIGN.md
## §12.7 names) instead of inventing a second theme surface for this wave.

## [param action_id]: the pressed entry's caller-supplied `id`.
signal action_selected(action_id: StringName)
signal dismissed

var tokens: InventoryDesignTokens

var _entry_list: VBoxContainer
var _entry_buttons: Dictionary = {} # StringName action_id -> Button
var _open_tween: Tween

const _EMPTY_ENTRY_ID: StringName = &"__inventory_context_menu_empty__"

## DESIGN.md §10.3's own headroom-then-cap convention ([method
## InventoryTooltip._fit_label_width]), reused here as a per-entry WIDTH
## FLOOR/ceiling rather than a label max-width: see [method _reserve_entry_width]'s
## doc comment for why a floor is what THIS primitive actually needs.
const _ENTRY_MAX_WIDTH_UNITS := 24.0
const _ENTRY_MIN_WIDTH_UNITS := 10.0


func _init() -> void:
	# STOP (PanelContainer's own default) is load-bearing, not incidental: it
	# is what makes a press anywhere inside this menu's own rect -- including
	# blank space between entries -- get absorbed by Godot's GUI input system
	# before it would otherwise reach [method _unhandled_input] below, so only
	# a press genuinely OUTSIDE this menu ever reaches the outside-press
	# dismiss check.
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	theme_type_variation = InventoryThemeFactory.TYPE_CONTEXT_MENU
	_build_children()


func _build_children() -> void:
	_entry_list = VBoxContainer.new()
	_entry_list.name = "Entries"
	add_child(_entry_list)


## [param actions]: same shape as [method InventoryInteractionController.available_actions]'
## return value -- [code]Array[Dictionary{id: StringName, label: String, glyph:
## StringName (optional), enabled: bool (default true)}][/code]. An empty
## array renders DESIGN.md §12.7's "empty" row: a single disabled "No actions
## available" entry, never a blank/zero-height menu.
func populate(actions: Array, p_tokens: InventoryDesignTokens = null) -> void:
	tokens = p_tokens if p_tokens != null else InventoryDesignTokens.new()
	for child in _entry_list.get_children():
		_entry_list.remove_child(child)
		child.queue_free()
	_entry_buttons.clear()

	if actions.is_empty():
		var empty_button := _make_entry_button({"id": _EMPTY_ENTRY_ID, "label": "No actions available", "enabled": false})
		_entry_list.add_child(empty_button)
		_reserve_entry_width(empty_button)
		_entry_buttons[_EMPTY_ENTRY_ID] = empty_button
	else:
		for entry_variant in actions:
			var entry: Dictionary = entry_variant
			var action_id := StringName(entry.get("id", &""))
			if String(action_id).is_empty():
				continue
			var button := _make_entry_button(entry)
			_entry_list.add_child(button)
			_reserve_entry_width(button)
			_entry_buttons[action_id] = button

	apply_state(InventoryPresentationModel.STATE_NORMAL)


## §10.3's `clip_text`/`OVERRUN_TRIM_ELLIPSIS` contract (set in [method
## _make_entry_button]) suppresses [Button]'s own text-driven contribution to
## its `get_minimum_size()` -- exactly the mechanism [method
## InventoryTooltip._fit_label_width]'s doc comment documents -- which is
## fine for [InventoryContextActions] (its buttons are width-capped by an
## OUTER host layout that provides real width regardless) but WRONG here:
## THIS menu's own panel sizes itself from [method
## Control.get_combined_minimum_size] of exactly these buttons (see [method
## present]), so an icon-less entry (the §12.7 "No actions available" empty
## row, which carries no glyph) would otherwise collapse toward zero width --
## empirically confirmed while building this control (visual QA's empty-state
## cell rendered as an invisible sliver before this fix). Must run AFTER
## [param button]'s `.text`/`.icon` are already assigned and it is already a
## child of a themed ancestor (font/font_size lookups need a resolvable
## theme) -- both true by the time [method populate] calls this, right after
## `_entry_list.add_child(button)`.
func _reserve_entry_width(button: Button) -> void:
	var natural_width := 0.0
	var font := button.get_theme_font(&"font")
	if font != null:
		var font_size := button.get_theme_font_size(&"font_size")
		natural_width = font.get_string_size(button.text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	var icon_allowance := tokens.unit(2.0) if button.icon != null else 0.0
	var padding := tokens.unit(2.0) # button content margins + icon/text gap, approximated.
	var reserved := natural_width + icon_allowance + padding
	var min_width := tokens.unit(_ENTRY_MIN_WIDTH_UNITS)
	var max_width := tokens.unit(_ENTRY_MAX_WIDTH_UNITS)
	button.custom_minimum_size.x = clampf(reserved, min_width, max_width)


func _make_entry_button(entry: Dictionary) -> Button:
	var action_id := StringName(entry.get("id", &""))
	var label := String(entry.get("label", String(action_id)))
	var button := Button.new()
	button.name = String(action_id) if not String(action_id).is_empty() else "Entry"
	button.theme_type_variation = InventoryThemeFactory.TYPE_ACTION_BAR_ENTRY
	# DESIGN.md §7/§11.2/finding 1's class of defect: the glyph TOKEN never
	# belongs in the button's own text -- text is the label alone, the glyph
	# (when non-null) resolves through the shared drawn-icon registry exactly
	# like [InventoryContextActions.populate] already does.
	button.text = label
	var glyph := StringName(entry.get("glyph", &""))
	var icon_texture := InventoryStateIcons.icon_for(glyph)
	if icon_texture != null:
		button.icon = icon_texture
	# DESIGN.md §10.3 ellipsis + tooltip contract, same as every other
	# primitive in this addon.
	button.clip_text = true
	button.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	button.tooltip_text = label
	# §12.7 "disabled: entry desaturated, not hidden" -- `Button.disabled`
	# keeps the entry visible (native disabled StyleBox/font color), never
	# removes it.
	button.disabled = not bool(entry.get("enabled", true))
	button.focus_mode = Control.FOCUS_ALL
	if action_id != _EMPTY_ENTRY_ID:
		button.pressed.connect(_on_entry_pressed.bind(action_id))
	return button


## Positions this menu with its top-left corner at [param anchor_global_position],
## clamped so its full rect stays inside the immediate parent [Control]'s rect
## (falls back to unclamped when the parent isn't a [Control], e.g. a headless
## test that never added this to a real layout parent), shows it, focuses the
## first enabled entry (§11.3), then animates it open. A no-op outside the
## tree (headless [method populate] calls remain fully drivable without a
## live viewport, matching [InventoryTooltip.present]'s own convention).
func present(anchor_global_position: Vector2) -> void:
	if not is_inside_tree():
		return
	size = get_combined_minimum_size()
	var target := anchor_global_position
	var parent_control := get_parent() as Control
	if parent_control != null:
		var parent_rect := Rect2(parent_control.global_position, parent_control.size)
		target.x = clampf(target.x, parent_rect.position.x, maxf(parent_rect.position.x, parent_rect.end.x - size.x))
		target.y = clampf(target.y, parent_rect.position.y, maxf(parent_rect.position.y, parent_rect.end.y - size.y))
	global_position = target
	visible = true
	_focus_first_enabled_entry()
	animate_open()


func dismiss() -> void:
	if not visible:
		return
	_kill_open_tween()
	visible = false
	dismissed.emit()


## DESIGN.md §9 "Context menu open: fade + scale from anchor, duration_fast;
## reduced: instant appearance." The anchor corner is this menu's own
## top-left ([member Control.pivot_offset] at [constant Vector2.ZERO]) -- the
## exact point [method present] already positions at the caller-supplied
## anchor, so scaling in from that corner reads as growing out of the
## anchor regardless of which corner of the parent rect [method present]'s own
## clamping ultimately placed it against. Split out from [method present] (see
## that method's own doc comment) so a headless test can drive it directly,
## exactly like [method InventoryTooltip.animate_appear].
func animate_open() -> void:
	if _reduced_motion():
		modulate.a = 1.0
		scale = Vector2.ONE
		return
	_kill_open_tween()
	pivot_offset = Vector2.ZERO
	modulate.a = 0.0
	scale = Vector2(0.9, 0.9)
	var duration := _duration_seconds(&"fast")
	_open_tween = create_tween()
	_open_tween.set_parallel(true)
	if tokens != null:
		_open_tween.set_trans(tokens.ease_standard_transition).set_ease(tokens.ease_standard_type)
	_open_tween.tween_property(self, "modulate:a", 1.0, duration)
	_open_tween.tween_property(self, "scale", Vector2.ONE, duration)


func is_open_animating() -> bool:
	return _open_tween != null and _open_tween.is_valid() and _open_tween.is_running()


func _kill_open_tween() -> void:
	if _open_tween != null and _open_tween.is_valid():
		_open_tween.kill()
	modulate.a = 1.0
	scale = Vector2.ONE


## §11.3 focus visibility: keyboard/gamepad opening of this menu must not
## strand focus nowhere -- the first ENABLED entry (never a disabled one,
## and never the §12.7 empty-row placeholder, which is itself disabled)
## receives it.
func _focus_first_enabled_entry() -> void:
	for child in _entry_list.get_children():
		var button := child as Button
		if button != null and not button.disabled:
			button.grab_focus()
			return


func _on_entry_pressed(action_id: StringName) -> void:
	action_selected.emit(action_id)
	dismiss()


## Esc dismisses while open; a mouse press outside this menu's own rect
## dismisses it too (see [method _init]'s doc comment for why a press
## genuinely INSIDE the menu never reaches here at all). Both paths mark the
## event handled so the same click/key press that closed the menu doesn't
## ALSO immediately act on whatever control sits underneath it -- matching
## native [PopupMenu]'s own outside-click-dismiss behavior.
func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed(&"ui_cancel"):
		dismiss()
		get_viewport().set_input_as_handled()
		return
	var mb := event as InputEventMouseButton
	if mb != null and mb.pressed:
		if not get_global_rect().has_point(mb.global_position):
			dismiss()
			get_viewport().set_input_as_handled()


## Swaps this menu's WHOLE panel background via the [method
## InventoryThemeFactory.state_stylebox_name] explicit-lookup convention
## (DESIGN.md §12.7's state matrix is registered as one named panel StyleBox
## per state, not per entry -- see this file's header comment) -- used by the
## component/visual-QA harnesses to drive every §12.7 state sheet cell from
## this control's own real API instead of a fallback override applied from
## outside.
func apply_state(state: StringName) -> void:
	var stylebox := get_theme_stylebox(InventoryThemeFactory.state_stylebox_name(state), InventoryThemeFactory.TYPE_CONTEXT_MENU)
	if stylebox == null:
		stylebox = get_theme_stylebox(&"panel", InventoryThemeFactory.TYPE_CONTEXT_MENU)
	if stylebox != null:
		add_theme_stylebox_override(&"panel", stylebox)


func _reduced_motion() -> bool:
	return tokens != null and bool(tokens.get("reduced_motion_enabled"))


func _duration_seconds(token: StringName) -> float:
	return (tokens.duration_ms(token) / 1000.0) if tokens != null else 0.0


# =============================================================================
# Test/inspection accessors -- proving populated content and real API state,
# not pixels (matching every other primitive in this addon).
# =============================================================================

func entry_count() -> int:
	return _entry_buttons.size()


func entry_button(action_id: StringName) -> Button:
	return _entry_buttons.get(action_id, null)


func is_entry_enabled(action_id: StringName) -> bool:
	var button: Button = _entry_buttons.get(action_id, null)
	return button != null and not button.disabled


## The currently-applied "panel" StyleBox -- proves [method apply_state]
## actually swapped it (matching [InventoryDragGhost.current_background_stylebox]'s
## identical rationale), since this control IS the [PanelContainer] itself
## (unlike [InventoryModal], whose panel is a separate child control).
func current_panel_stylebox() -> StyleBox:
	return get_theme_stylebox(&"panel")
