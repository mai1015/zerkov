class_name InventoryItemCard
extends Control

## Shared item-card primitive (tasks.md 8.3; DESIGN.md §6.3, §12.1). A plain
## script-only [Control] (no companion `.tscn` -- see [InventorySpatialGridControl]'s
## header comment for why every control in this addon is authored this way),
## replaceable by extending this script or by registering an entirely
## different renderer for the same slot.
##
## Renders read-only content from a snapshot item Dictionary
## ([method InventorySnapshotResource.get_items]'s per-entry shape) plus
## [method InventoryPresentationModel.item_state]'s resolved state -- it never
## calls into an authority and never mutates canonical data. Content it
## cannot derive from the bare item Dictionary (durability fraction, display
## mass) is host-injectable via [method set_display_mass_mg]/[method
## set_display_durability_fraction]; see [InventoryPresentationModel]'s file
## header for why (mass/traits are catalog-side, not snapshot-side).
##
## Item art is resolved through
## [member InventoryPresentationModel.item_presentation_resolver]. Missing
## entries retain the matte slot and show a bounded, ellipsized identifier
## tail; state signifiers remain separate overlays.
##
## -- Visual state overlay (DESIGN.md §7/§11.2; visual-qa-2026-07-27.md
## finding 1) ---------------------------------------------------------------
## The overlay renders a drawn [Texture2D] from [InventoryStateIcons], tinted
## via [method InventoryThemeFactory.state_icon_color], NEVER the raw
## [InventoryStateGlyphs] token as literal text. Where DESIGN.md §11.2's Text
## column actually names a short phrase for a state this overlay shows (see
## [method _state_overlay_text]), that phrase renders alongside the icon;
## states whose §11.2 Text column is "--" or "on tooltip/inspect" only
## (`pending`, `accepted-flash`) stay icon-only here, matching that table.
## States with no icon at all (`normal`/`selected`) render neither -- the
## "shape-coded only" contract [InventoryStateGlyphs] documents is preserved.
##
## -- Background compositing priority (DESIGN.md §11.3; finding 7) ----------
## Exactly one Theme StyleBox is ever applied to [member _background] at a
## time, chosen by this precedence (highest first):
##   1. A host's drop-preview override ([method set_drop_preview_stylebox]) --
##      e.g. this card is a live drop target for an item dragging elsewhere;
##      the host's explicit choice always wins over anything this card would
##      otherwise compute.
##   2. `pressed` -- the primary button held down. Inserted ABOVE focus/hover
##      (not explicitly ordered by this wave's brief, which only names
##      "drop-preview > focus > hover > model state") because it is the most
##      immediate real-time input signal a player can give this control short
##      of a host override; showing "focus" or "hover" instead while a press
##      is physically held would read as a dropped/ignored input.
##   3. `focus` -- keyboard/gamepad focus (also draws the always-on §11.3
##      ring via [method _draw], independent of the StyleBox layer).
##   4. `hover` -- pointer over the control, no press/focus.
##   5. This item's own [method current_state] (`normal`/`selected`/`pending`/
##      `rejected`/... -- the full DESIGN.md §12 vocabulary this model can
##      resolve).
## The state OVERLAY (icon/text) and the durability/quantity/weight content
## are unaffected by this precedence -- they always reflect [method
## current_state] directly, never the hover/focus/pressed pseudo-state, so a
## hovered "pending" card still visibly reads as pending via its overlay even
## though its BACKGROUND momentarily shows the hover treatment.
##
## -- Motion (DESIGN.md §9) --------------------------------------------------
## Every animated transition below is gated on `tokens.reduced_motion_enabled`
## (read via dynamic `tokens.get(...)` -- see [method _reduced_motion]'s doc
## comment for why) and kills any prior tween of its own kind before starting
## a new one; every [Tween] is created via [method Node.create_tween] and so
## dies automatically with this node (Godot's own Tween/Node lifecycle -- no
## manual cleanup needed on `queue_free()`).
## - Rejection shake: triggered by [signal InventoryPresentationModel.rejection_feedback]
##   (never by comparing states across [method _refresh] calls -- see that
##   signal's own "fires exactly once per NEW rejection" contract, which a
##   state-transition comparison cannot replicate safely here: every
##   container control in this addon fully rebuilds its card children on
##   every `model_changed`, tests/inventory_system/presentation/... confirms
##   this via [InventorySpatialGridControl]/[InventoryOrderedListControl]'s
##   own `_rebuild()`, so a brand-new card instance's `_last_known_state`
##   always starts at `normal` regardless of whether THIS instance was
##   actually just rejected).
## - Pending pulse: a LEVEL check every [method _refresh] (not an edge/
##   transition check) -- see [method _update_motion_for_state]'s doc comment
##   for why a level check is correct here where it would be wrong for a
##   one-shot animation.
## - Accepted flash: edge-triggered by [signal
##   InventoryPresentationModel.accepted_feedback] (the accept branch's
##   mirror of `rejection_feedback`) via [method _on_accepted_feedback],
##   for exactly the same rebuild-safety reason as the shake.

## Emitted on a primary click, so an owning container control can decide what
## that means (select, and/or an eventual drag start once 8.5 wires it) --
## this primitive itself only ever reports the raw interaction, never selects
## or submits intent on its own, keeping "who owns interaction policy" with
## the container per tasks.md 8.3.
signal pressed(item_id: int)
## Emitted on primary-button RELEASE over this card (tasks.md 8.5: a card is
## also a valid DROP target -- merge/swap/equip-replace). Same "raw
## interaction only" contract as [signal pressed]: the owning container
## control decides what a release over an occupied location means.
signal released(item_id: int)
## Emitted in ADDITION TO (not instead of) [signal pressed] when the platform
## reports this press as the second half of a double-click
## ([InputEventMouseButton.double_click], engine/OS double-click-interval
## timing -- this primitive invents no timing of its own): both clicks of a
## double-click still `pressed` (an ordinary select each time, tasks.md 8.5's
## "single click still selects" contract; the second click's harmless re-arm
## of a potential drag never actually starts one since it releases again
## with no intervening movement), and the second ALSO fires this signal. The
## owning container control decides what a double-click means (e.g. opening
## a provided container) exactly like every other raw signal here -- this
## primitive itself never opens/inspects/selects on its own.
signal double_clicked(item_id: int)
## Emitted on secondary-button press with the exact pointer anchor in global
## coordinates. It never toggles primary pressed state and therefore cannot
## arm a drag; the owning controller decides whether idle context or cancel
## precedence applies.
signal context_requested(item_id: int, anchor_global_position: Vector2)

var model: InventoryPresentationModel
var tokens: InventoryDesignTokens
var inventory_id: int = 0
var item_id: int = 0

var _item_data: Dictionary = {}
var _display_mass_mg: int = -1
var _display_durability_fraction: float = -1.0

var _background: Panel
var _icon_region: ColorRect
var _icon_texture: TextureRect
var _icon_fallback: Label
var _name_label: Label
var _weight_label: Label
var _protected_label: Label
var _quantity_badge: Label
var _durability_bar: ColorRect
var _durability_label: Label
var _state_overlay_icon: TextureRect
var _state_overlay_label: Label

# -- Interaction/compositing state (DESIGN.md §11.3, §12.1; finding 7) -------
var _is_hovered: bool = false
var _is_pressed: bool = false
var _has_focus_ring: bool = false
var _drop_preview_active: bool = false
var _last_known_state: StringName = InventoryPresentationModel.STATE_NORMAL

# -- Motion (DESIGN.md §9) ----------------------------------------------------
var _shake_tween: Tween
var _shake_origin_x: float = 0.0
var _flash_tween: Tween
var _pulse_tween: Tween


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	# A placing container ([InventorySpatialGridControl]/[InventoryNamedSlotsControl])
	# already sets this externally too (redundant, not conflicting) -- setting
	# it here as well keeps this primitive self-sufficient/testable standalone
	# without requiring a host to opt it into focus first.
	focus_mode = Control.FOCUS_ALL
	theme_type_variation = InventoryThemeFactory.TYPE_ITEM_CARD
	_build_children()
	mouse_entered.connect(_on_mouse_entered)
	mouse_exited.connect(_on_mouse_exited)
	focus_entered.connect(_on_focus_entered)
	focus_exited.connect(_on_focus_exited)


## [param item]: one entry of [method InventorySnapshotResource.get_items]
## ([code]{id, item_definition_identifier, quantity, location,
## mutable_components, provided_containers}[/code]).
func configure(p_model: InventoryPresentationModel, p_inventory_id: int, item: Dictionary, p_tokens: InventoryDesignTokens) -> void:
	if model != null:
		if model.model_changed.is_connected(_on_model_changed):
			model.model_changed.disconnect(_on_model_changed)
		if model.rejection_feedback.is_connected(_on_rejection_feedback):
			model.rejection_feedback.disconnect(_on_rejection_feedback)
		if model.accepted_feedback.is_connected(_on_accepted_feedback):
			model.accepted_feedback.disconnect(_on_accepted_feedback)
	model = p_model
	inventory_id = p_inventory_id
	_item_data = item.duplicate(true)
	item_id = int(_item_data.get("id", 0))
	tokens = p_tokens if p_tokens != null else InventoryDesignTokens.new()
	if model != null:
		model.model_changed.connect(_on_model_changed)
		model.rejection_feedback.connect(_on_rejection_feedback)
		model.accepted_feedback.connect(_on_accepted_feedback)
	_apply_layout()
	_refresh()


## Host-supplied catalog-derived mass in milligrams (see class doc comment);
## [code]-1[/code] (default) hides the weight tag entirely.
func set_display_mass_mg(mass_mg: int) -> void:
	_display_mass_mg = mass_mg
	_refresh()


## Host-supplied durability, 0.0-1.0; negative (default) hides the bar.
func set_display_durability_fraction(fraction: float) -> void:
	_display_durability_fraction = fraction
	_refresh()


## Applies [param stylebox] directly to this card's internal [member
## _background] Panel -- the ONLY child that ever actually draws a "panel"
## StyleBox (see [method _apply_state_style]); an override applied to this
## OUTER card control itself is inert, since the outer control never draws
## its own background. Used EXCLUSIVELY by a container control's own
## `set_drop_preview()` (DESIGN.md §11.2's continuous snapped drop-target
## preview, tasks.md 8.5) to restyle an occupied cell's covering card without
## reaching into this primitive's private state -- a plain per-item STATE
## restyle instead goes through [method _apply_state_style] as always.
## Outranks every OTHER background source (hover/focus/pressed/model state --
## see this class's own doc comment on compositing priority) until [method
## clear_drop_preview_stylebox] (or a fresh [method configure]) restores
## normal compositing.
func set_drop_preview_stylebox(stylebox: StyleBox) -> void:
	_drop_preview_active = true
	_background.add_theme_stylebox_override(&"panel", stylebox)


func clear_drop_preview_stylebox() -> void:
	_drop_preview_active = false
	_background.remove_theme_stylebox_override(&"panel")
	_apply_effective_background()


func current_state() -> StringName:
	return model.item_state(inventory_id, item_id) if model != null else InventoryPresentationModel.STATE_NORMAL


## The [StyleBox] currently applied to this card's background -- test/
## inspection accessor proving a state (or hover/focus/pressed/drop-preview)
## change actually flipped the applied Theme item, not just this card's own
## recorded flags.
func current_background_stylebox() -> StyleBox:
	return _background.get_theme_stylebox(&"panel")


## The human-readable text this card's state overlay currently shows (""
## when the current state carries no §11.2 Text-column phrase, e.g.
## icon-only `pending`/`accepted-flash`, or no overlay at all).
func state_overlay_text() -> String:
	return _state_overlay_label.text


## True while EITHER the overlay icon or its accompanying text is visible.
func state_overlay_visible() -> bool:
	return _state_overlay_icon.visible or _state_overlay_label.visible


## The drawn [Texture2D] this card's state overlay currently shows (`null`
## for a state with no icon at all, e.g. `normal`/`selected`).
func state_overlay_icon_texture() -> Texture2D:
	return _state_overlay_icon.texture


func is_hovered() -> bool:
	return _is_hovered


func is_pressed_visual() -> bool:
	return _is_pressed


## True while this card's always-on §11.3 focus ring is being drawn (see
## [method _draw]) -- the compositing-state accessor a test uses instead of
## reading pixels to prove focus actually renders.
func is_focus_ring_visible() -> bool:
	return _has_focus_ring


## The single-line display name currently shown below the icon slot (empty
## when no icon resolved -- see [method fallback_label_text] for that case).
func name_label_text() -> String:
	return _name_label.text


## The bounded, ellipsized identifier-tail text shown INSIDE the icon slot
## when the presentation resolver has no icon for this item at all.
func fallback_label_text() -> String:
	return _icon_fallback.text


func is_pending_pulse_active() -> bool:
	return _pulse_tween != null and _pulse_tween.is_valid()


func is_rejection_shake_active() -> bool:
	return _shake_tween != null and _shake_tween.is_valid() and _shake_tween.is_running()


func is_accepted_flash_active() -> bool:
	return _flash_tween != null and _flash_tween.is_valid() and _flash_tween.is_running()


func _on_model_changed() -> void:
	_refresh()


## Best-effort DIRECT hook: this signal names the exact items a rejection
## touched, so this card only ever shakes for a rejection that actually
## concerns it (see this class's own doc comment on why this signal, not a
## state-transition comparison, drives the shake).
func _on_rejection_feedback(info: Dictionary) -> void:
	var items: Array = info.get("items", [])
	if item_id in items:
		_play_rejection_shake()


## Same direct-hook pattern as [method _on_rejection_feedback], via the
## accept branch's mirror signal -- fires exactly once per newly accepted
## command, so the flash cannot spuriously re-trigger on unrelated
## container rebuilds the way state-transition detection could.
func _on_accepted_feedback(info: Dictionary) -> void:
	var items: Array = info.get("items", [])
	if item_id in items:
		_play_accepted_flash()


func _gui_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb == null:
		return
	if mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
		context_requested.emit(item_id, mb.global_position)
		accept_event()
		return
	if mb.button_index != MOUSE_BUTTON_LEFT:
		return
	if mb.pressed:
		_is_pressed = true
		_apply_effective_background()
		pressed.emit(item_id)
		if mb.double_click:
			double_clicked.emit(item_id)
		accept_event()
	else:
		_is_pressed = false
		_apply_effective_background()
		released.emit(item_id)
		accept_event()


func _on_mouse_entered() -> void:
	_is_hovered = true
	_apply_effective_background()


func _on_mouse_exited() -> void:
	_is_hovered = false
	_apply_effective_background()


func _on_focus_entered() -> void:
	_has_focus_ring = true
	_apply_effective_background()
	queue_redraw()


func _on_focus_exited() -> void:
	_has_focus_ring = false
	_apply_effective_background()
	queue_redraw()


## DESIGN.md §11.3: the focus ring is drawn directly, never via a StyleBox --
## "the ring is never suppressed" is a hard rule there, and a Theme override
## could otherwise style a StyleBox-based ring away entirely. Always
## `duration_instant` (no tween): appears/disappears the same frame focus
## changes (see [method _on_focus_entered]/[method _on_focus_exited]'s
## `queue_redraw()`), per §9's own focus-ring carve-out ("unaffected by the
## [reduced-motion] setting; focus must never lag input").
func _draw() -> void:
	if not _has_focus_ring:
		return
	var offset := float(InventoryThemeFactory.FOCUS_RING_OFFSET)
	var rect := Rect2(Vector2.ZERO, size).grow(offset)
	var ring_width := InventoryThemeFactory.BORDER_FOCUS
	draw_rect(rect, InventoryThemeFactory.COLOR_ACCENT, false, ring_width)
	_draw_focus_corner_ticks(rect)


## Four short L-shaped ticks, one per corner of [param rect], extending
## further outward -- DESIGN.md §11.3's "corner tick marks" additional
## non-color signifier distinguishing focus from mere hover (a hover-only
## card never reaches this method: [method _draw] returns early unless
## [member _has_focus_ring]).
func _draw_focus_corner_ticks(rect: Rect2) -> void:
	var tick_length := tokens.unit(0.5) if tokens != null else 4.0
	var width := InventoryThemeFactory.BORDER_FOCUS
	var color := InventoryThemeFactory.COLOR_ACCENT
	var corners := [
		[rect.position, -1.0, -1.0],
		[Vector2(rect.end.x, rect.position.y), 1.0, -1.0],
		[Vector2(rect.position.x, rect.end.y), -1.0, 1.0],
		[rect.end, 1.0, 1.0],
	]
	for corner_data in corners:
		var corner: Vector2 = corner_data[0]
		var sign_x: float = corner_data[1]
		var sign_y: float = corner_data[2]
		draw_line(corner, corner + Vector2(sign_x * tick_length, 0.0), color, width)
		draw_line(corner, corner + Vector2(0.0, sign_y * tick_length), color, width)


func _build_children() -> void:
	_background = Panel.new()
	_background.name = "Background"
	_background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_background.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_background)

	_icon_region = ColorRect.new()
	_icon_region.name = "IconRegion"
	_icon_region.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_icon_region.color = Color(1, 1, 1, 0.08)
	add_child(_icon_region)

	_icon_texture = TextureRect.new()
	_icon_texture.name = "ItemIcon"
	_icon_texture.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_icon_texture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_icon_texture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	add_child(_icon_texture)

	_icon_fallback = Label.new()
	_icon_fallback.name = "ItemIconFallback"
	_icon_fallback.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_icon_fallback.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_icon_fallback.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	# DESIGN.md §10.3/visual-qa-2026-07-27.md finding 4: last-resort fallback
	# shown only when the presentation resolver has no icon for this item at
	# all -- a single-line, ellipsized identifier TAIL (see _refresh()),
	# never a word-wrapped raw dotted identifier. `autowrap_mode` is
	# deliberately left at its OFF default here (it used to be
	# AUTOWRAP_WORD_SMART -- exactly finding 4's defect, "Wi/dg/et" wrapping
	# inside the icon box); `clip_text`/`text_overrun_behavior` below replace
	# wrapping with ellipsis truncation instead.
	_icon_fallback.clip_text = true
	_icon_fallback.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	add_child(_icon_fallback)

	# DESIGN.md §10.3/finding 4: the item's display name when the
	# presentation resolver DID supply one, rendered BELOW the icon slot
	# (never word-wrapped inside it) -- single line, ellipsized, full string
	# always reachable via `tooltip_text`. See _apply_layout()'s doc comment
	# for why this sits just past the fixed 3u icon slot rather than
	# stretching with the card's own (possibly multi-cell/larger) outer size.
	_name_label = Label.new()
	_name_label.name = "ItemName"
	_name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_name_label.clip_text = true
	_name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	add_child(_name_label)

	_weight_label = Label.new()
	_weight_label.name = "WeightTag"
	_weight_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_weight_label.visible = false
	add_child(_weight_label)

	_protected_label = Label.new()
	_protected_label.name = "ProtectedMarker"
	_protected_label.text = "protected_secure"
	_protected_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_protected_label.visible = false
	add_child(_protected_label)

	_quantity_badge = Label.new()
	_quantity_badge.name = "QuantityBadge"
	_quantity_badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_quantity_badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	add_child(_quantity_badge)

	_durability_bar = ColorRect.new()
	_durability_bar.name = "DurabilityBar"
	_durability_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_durability_bar.visible = false
	add_child(_durability_bar)

	_durability_label = Label.new()
	_durability_label.name = "DurabilityLabel"
	_durability_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_durability_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_durability_label.visible = false
	add_child(_durability_label)

	# DESIGN.md §7/§11.2/finding 1: the state overlay is a drawn ICON
	# (InventoryStateIcons, tinted per InventoryThemeFactory.state_icon_color)
	# plus, only for the states whose §11.2 Text column actually names one
	# (see _state_overlay_text()), a short human-readable caption -- never
	# the raw InventoryStateGlyphs token string a Label used to render
	# literally.
	_state_overlay_icon = TextureRect.new()
	_state_overlay_icon.name = "StateOverlayIcon"
	_state_overlay_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_state_overlay_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_state_overlay_icon.visible = false
	add_child(_state_overlay_icon)

	_state_overlay_label = Label.new()
	_state_overlay_label.name = "StateOverlay"
	_state_overlay_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_state_overlay_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_state_overlay_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_state_overlay_label.clip_text = true
	_state_overlay_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	add_child(_state_overlay_label)


## All geometry is [code]tokens.unit(N)[/code] (DESIGN.md §6.3's 3u icon slot
## is the anchor every other offset is expressed relative to); the durability
## strip's 0.25u height/quantity-badge/weight-tag insets approximate
## DESIGN.md's literal small pixel constants (a "2px strip", tight badge
## insets) as the nearest quarter-unit multiple rather than a raw pixel
## literal, so this control has NO literal pixel constant anywhere in its
## layout code, matching this wave's "geometry as unit*N only" rule even for
## the small values DESIGN.md itself expresses as bare px.
## Sets this card's MINIMUM size and internal content layout only -- it does
## NOT force [member Control.size]. A card's outer size is the placing
## container's decision (e.g. [InventorySpatialGridControl] sizes it to the
## item's full multi-cell footprint span, and even a single-cell footprint is
## always at least one grid-cell wide/tall, which DESIGN.md §4's density
## table (4u/5u/6u) guarantees is bigger than this fixed 3u icon slot); the
## fixed-3u icon slot and the badges/bars anchored to it stay pinned to this
## control's top-left corner regardless of how much larger the outer
## footprint is, matching DESIGN.md §6.3's icon slot being a fixed size, not
## a stretched one. [member _name_label] below is positioned the same way --
## pinned just past the icon slot's own fixed bottom edge, not stretched to
## the outer footprint -- which is exactly the at-least-1u slack §4's density
## table guarantees exists there for every declared density.
func _apply_layout() -> void:
	var icon_size := tokens.unit(3.0)
	custom_minimum_size = Vector2(icon_size, icon_size)

	_icon_region.position = Vector2.ZERO
	_icon_region.size = Vector2(icon_size, icon_size)
	_icon_texture.position = Vector2.ZERO
	_icon_texture.size = Vector2(icon_size, icon_size)
	_icon_fallback.position = Vector2(tokens.unit(0.25), tokens.unit(0.25))
	_icon_fallback.size = Vector2(tokens.unit(2.5), tokens.unit(2.5))

	_name_label.position = Vector2(0.0, icon_size)
	_name_label.size = Vector2(icon_size, tokens.unit(0.75))

	_weight_label.position = Vector2(tokens.unit(0.25), tokens.unit(0.25))
	_weight_label.size = Vector2(tokens.unit(1.5), tokens.unit(0.75))

	_protected_label.position = Vector2(tokens.unit(1.75), tokens.unit(0.25))
	_protected_label.size = Vector2(tokens.unit(1.25), tokens.unit(0.75))

	_quantity_badge.position = Vector2(tokens.unit(1.5), tokens.unit(2.0))
	_quantity_badge.size = Vector2(tokens.unit(1.5), tokens.unit(0.75))

	_durability_bar.position = Vector2(0.0, tokens.unit(2.75))
	_durability_bar.size = Vector2(icon_size, tokens.unit(0.25))

	_durability_label.position = Vector2(0.0, tokens.unit(1.75))
	_durability_label.size = Vector2(icon_size, tokens.unit(0.75))

	# State overlay: a fixed icon square on the left of the band, human text
	# (when §11.2 names one, see _state_overlay_text()) filling the rest.
	# When a state is icon-only, _apply_state_overlay() re-centers the icon
	# across the full band width instead (band width 3u, icon 1u -> centered
	# offset (3-1)/2 = 1u exactly, see that method's comment).
	_state_overlay_icon.position = Vector2(0.0, tokens.unit(1.0))
	_state_overlay_icon.size = Vector2(tokens.unit(1.0), tokens.unit(1.0))
	_state_overlay_label.position = Vector2(tokens.unit(1.0), tokens.unit(1.0))
	_state_overlay_label.size = Vector2(icon_size - tokens.unit(1.0), tokens.unit(1.0))


func _refresh() -> void:
	if model == null:
		return
	var state := current_state()

	var quantity := int(_item_data.get("quantity", 1))
	_quantity_badge.text = "x%d" % quantity
	_quantity_badge.visible = quantity > 1

	var definition_id := StringName(_item_data.get("item_definition_identifier", ""))
	var presentation := model.item_presentation(definition_id)
	var icon_tex := presentation.get("icon", null) as Texture2D
	_icon_texture.texture = icon_tex
	_icon_texture.visible = icon_tex != null
	_icon_fallback.visible = not _icon_texture.visible
	_name_label.visible = _icon_texture.visible

	if _icon_texture.visible:
		# DESIGN.md §10.3/finding 4: icon resolved -- single-line display name
		# below it, full string always reachable via tooltip even where this
		# label itself had to truncate.
		var display_name := String(presentation.get("display_name", definition_id))
		_name_label.text = display_name
		_name_label.tooltip_text = display_name
	else:
		# Resolver absent/miss: bounded, ellipsized identifier TAIL -- never
		# the full dotted identifier wrapped into the icon area (finding 4).
		var full_identifier := String(definition_id)
		var segments := full_identifier.split(".")
		_icon_fallback.text = segments[-1] if not segments.is_empty() else full_identifier
		_icon_fallback.tooltip_text = full_identifier

	if _display_mass_mg >= 0:
		_weight_label.text = "weight %d" % _display_mass_mg
		_weight_label.visible = true
	else:
		_weight_label.visible = false

	if _display_durability_fraction >= 0.0:
		var fraction := clampf(_display_durability_fraction, 0.0, 1.0)
		_durability_bar.visible = true
		_durability_label.visible = true
		_durability_label.text = "durability %d%%" % int(round(fraction * 100.0))
		_durability_bar.color = _durability_color(fraction)
		_durability_bar.size.x = tokens.unit(3.0) * fraction
	else:
		_durability_bar.visible = false
		_durability_label.visible = false

	_apply_state_overlay(state)
	_apply_effective_background()
	_update_motion_for_state(state)

	_last_known_state = state


func _durability_color(fraction: float) -> Color:
	if fraction >= 0.66:
		return InventoryThemeFactory.COLOR_POSITIVE
	if fraction >= 0.33:
		return InventoryThemeFactory.COLOR_WARNING
	return InventoryThemeFactory.COLOR_DANGER


## DESIGN.md §7/§11.2/finding 1: icon (never raw token text) plus, only where
## §11.2's Text column names a short phrase for [param state], that phrase.
func _apply_state_overlay(state: StringName) -> void:
	var glyph := InventoryStateGlyphs.glyph_for_item_state(state)
	var icon := InventoryStateIcons.icon_for(glyph)
	_state_overlay_icon.texture = icon
	_state_overlay_icon.visible = icon != null
	if icon != null:
		_state_overlay_icon.modulate = InventoryThemeFactory.state_icon_color(state)

	var text := _state_overlay_text(state)
	_state_overlay_label.text = text
	_state_overlay_label.visible = not text.is_empty()

	if icon != null and text.is_empty():
		# Icon-only state: re-center across the full band width (band 3u,
		# icon 1u -> centered offset (3-1)/2 = 1u exactly).
		_state_overlay_icon.position.x = tokens.unit(1.0)
	else:
		_state_overlay_icon.position.x = 0.0


## DESIGN.md §11.2's short human-readable Text column, for the states THIS
## overlay renders (the [InventoryStateGlyphs.glyph_for_item_state]
## vocabulary -- `normal`/`selected` never reach here, they carry no glyph at
## all). "" for a state §11.2 marks "--" or "on tooltip/inspect" only
## (`accepted-flash`, `pending`) -- those stay icon-only here;
## [InventoryTooltip] is the documented surface for their text (see that
## script's own `_state_note`, which this mirrors for the states that DO
## belong on this overlay).
func _state_overlay_text(state: StringName) -> String:
	match state:
		InventoryPresentationModel.STATE_REJECTED:
			var rejection := model.get_last_rejection() if model != null else {}
			return "Rejected: %s" % String(rejection.get("reason_token", &""))
		InventoryPresentationModel.STATE_STALE_CORRECTED:
			return "Updated"
		InventoryPresentationModel.STATE_REDACTED:
			return "Redacted"
		InventoryPresentationModel.STATE_READ_ONLY:
			return "Read-only"
		InventoryPresentationModel.STATE_DISCONNECTED:
			return "Disconnected"
		InventoryPresentationModel.STATE_RESYNCHRONIZING:
			return "Resynchronizing"
		_:
			return ""


## Chooses which single Theme StyleBox governs [member _background] right
## now, per this class's own doc comment on compositing priority, and
## applies it via [method _apply_state_style]. A no-op while a host's
## drop-preview override is active (see [method set_drop_preview_stylebox]).
func _apply_effective_background() -> void:
	if _drop_preview_active:
		return
	var lookup_state := current_state()
	if _is_pressed:
		lookup_state = &"pressed"
	elif _has_focus_ring:
		lookup_state = &"focus"
	elif _is_hovered:
		lookup_state = &"hover"
	_apply_state_style(lookup_state)


func _apply_state_style(state: StringName) -> void:
	var type_name := InventoryThemeFactory.TYPE_ITEM_CARD
	var stylebox := get_theme_stylebox(InventoryThemeFactory.state_stylebox_name(state), type_name)
	if stylebox == null:
		stylebox = get_theme_stylebox(InventoryThemeFactory.state_stylebox_name(InventoryPresentationModel.STATE_NORMAL), type_name)
	if stylebox != null:
		_background.add_theme_stylebox_override(&"panel", stylebox)


# =============================================================================
# Motion (DESIGN.md §9)
# =============================================================================

## Dynamic (not direct-field) access to `tokens.reduced_motion_enabled` --
## intentional per this wave's brief: [InventoryDesignTokens] is owned by a
## CONCURRENTLY active agent this task must not edit, and this specific
## field may not have landed there yet when this file was authored.
## `Object.get()` degrades to `false` (motion plays) if the field is absent,
## never crashes. Replace with direct `tokens.reduced_motion_enabled` once
## that field is confirmed stable across this wave.
func _reduced_motion() -> bool:
	return tokens != null and bool(tokens.get("reduced_motion_enabled"))


## Seconds for DESIGN.md §3.8's [param token] (`&"fast"`/`&"base"`/`&"slow"`/
## `&"deliberate"`), read from [InventoryDesignTokens]'s own already-landed
## [method InventoryDesignTokens.duration_ms] -- a stable, pre-existing method
## on that shared resource (unlike the still-in-flight
## `reduced_motion_enabled` field above), so direct access is fine here.
func _duration_seconds(token: StringName) -> float:
	return (tokens.duration_ms(token) / 1000.0) if tokens != null else 0.0


## Pending pulse (level check) -- accepted flash and rejection shake are
## edge-triggered elsewhere ([method _on_accepted_feedback] / [method
## _on_rejection_feedback]); see this class's own doc comment for why the
## pulse alone uses a level check.
func _update_motion_for_state(state: StringName) -> void:
	# Pending pulse (§9): a LEVEL check, not an edge/transition check -- every
	# container control in this addon fully rebuilds its card children on
	# every model_changed, so a brand-new card node's very first _refresh()
	# must still start the pulse correctly if the item is ALREADY pending,
	# not just on a transition into it. A looping animation restarting its
	# phase on rebuild is imperceptible; that is not true of the one-shot
	# shake/flash, which is why those do not use a level check.
	if state == InventoryPresentationModel.STATE_PENDING and not _reduced_motion():
		_ensure_pending_pulse()
	else:
		_stop_pending_pulse()

	# Accepted flash: edge-triggered by [method _on_accepted_feedback] via
	# [signal InventoryPresentationModel.accepted_feedback] (the accept
	# branch's mirror of `rejection_feedback`), NOT by state-transition
	# comparison here -- container rebuilds recreate cards with
	# [member _last_known_state] at its `normal` default, which a transition
	# check would misread as a fresh accept while the marker TTL is live.


func _ensure_pending_pulse() -> void:
	if _pulse_tween != null and _pulse_tween.is_valid() and _pulse_tween.is_running():
		return
	_pulse_tween = create_tween()
	_pulse_tween.set_loops()
	_pulse_tween.set_trans(Tween.TRANS_LINEAR).set_ease(Tween.EASE_IN_OUT)
	var duration := _duration_seconds(&"slow")
	_pulse_tween.tween_property(_background, "modulate:a", 0.5, duration)
	_pulse_tween.tween_property(_background, "modulate:a", 1.0, duration)


func _stop_pending_pulse() -> void:
	if _pulse_tween != null and _pulse_tween.is_valid():
		_pulse_tween.kill()
	_pulse_tween = null
	_background.modulate.a = 1.0


## DESIGN.md §9 "Rejection shake ... small horizontal oscillation,
## duration_deliberate / custom shake curve; reduced: no shake, instant
## return to origin plus a static danger-colored outline held duration_slow
## and the invalid_x icon + rejection text -- motion is removed, not merely
## shortened." The static outline/icon/text half of that reduced-motion
## equivalent is already rendered unconditionally by [method
## _apply_state_style]/[method _apply_state_overlay] above (for exactly as
## long as [InventoryPresentationModel]'s own rejection-feedback TTL keeps
## `rejected` the resolved state) -- this method only ever owns whether the
## ANIMATED oscillation additionally plays on top of that.
func _play_rejection_shake() -> void:
	if _reduced_motion():
		return
	_kill_shake_tween()
	_shake_origin_x = position.x
	var duration := _duration_seconds(&"deliberate")
	var amplitude := tokens.unit(0.5) if tokens != null else 4.0
	_shake_tween = create_tween()
	_shake_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_shake_tween.tween_property(self, "position:x", _shake_origin_x - amplitude, duration * 0.15)
	_shake_tween.tween_property(self, "position:x", _shake_origin_x + amplitude, duration * 0.3)
	_shake_tween.tween_property(self, "position:x", _shake_origin_x - amplitude * 0.6, duration * 0.25)
	_shake_tween.tween_property(self, "position:x", _shake_origin_x + amplitude * 0.3, duration * 0.2)
	_shake_tween.tween_property(self, "position:x", _shake_origin_x, duration * 0.1)


func _kill_shake_tween() -> void:
	if _shake_tween != null and _shake_tween.is_valid():
		_shake_tween.kill()
		position.x = _shake_origin_x


## DESIGN.md §9 "Accepted flash ... brief highlight on commit, duration_fast;
## reduced: static valid_check icon shown for duration_slow then removed --
## no flash/opacity animation." The static icon half is already rendered
## unconditionally by [method _apply_state_overlay] above for exactly as
## long as the model's own accepted-marker TTL keeps `accepted-flash` the
## resolved state -- this method only ever owns the animated highlight on
## top of that, and is a no-op entirely under reduced motion.
func _play_accepted_flash() -> void:
	if _reduced_motion():
		return
	_kill_flash_tween()
	var duration := _duration_seconds(&"fast")
	_background.modulate = InventoryThemeFactory.COLOR_POSITIVE
	_flash_tween = create_tween()
	_flash_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_flash_tween.tween_property(_background, "modulate", Color.WHITE, duration)


func _kill_flash_tween() -> void:
	if _flash_tween != null and _flash_tween.is_valid():
		_flash_tween.kill()
	_background.modulate = Color.WHITE
