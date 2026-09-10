class_name InventoryModal
extends Control

## Shipped modal primitive (tasks.md 8.3/8.5; DESIGN.md §9's "Modal open/
## close" motion row, §12.10's state matrix, §6.4/§11.3's scrim + focus-trap
## requirements) -- closes docs/inventory/visual-qa-2026-07-27.md finding 8's
## split-quantity gap: before this control existed, [InventoryTwoPaneView]'s
## `_on_split_quantity_requested` just showed a bare [InventoryQuantitySpinner]
## with no scrim, no focus trap, and (the actual reported defect) no reliable
## teardown when the pending split resolved via [method
## InventoryInteractionController.cancel] (e.g. Esc) rather than the
## spinner's own Confirm/Cancel buttons -- see [signal
## InventoryInteractionController.split_quantity_closed] for the other half
## of that fix.
##
## ARCHITECTURE DECISION (mirrors [InventoryContextMenu]'s identical header
## comment -- read that first): a [Control]/[CanvasItem]-based full-rect
## overlay, NOT a [Window]-based [PopupPanel]. DESIGN.md §9 requires the panel
## AND the scrim to independently scale/fade, and a [Window] has neither
## `modulate` nor a scale pivot. Because [InventoryThemeFactory] registers
## [constant InventoryThemeFactory.TYPE_MODAL] as a Theme Type Variation of
## `"PopupPanel"` and this control's actual native base is `Control` (its
## internal `_panel` child is a `PanelContainer`), automatic per-control theme
## resolution does not reach the registered `state_*`/`scrim_color` items --
## empirically verified identically to [InventoryContextMenu]'s own check.
## Every theme item here is therefore fetched by EXPLICIT type-name lookup
## (`get_theme_stylebox(name, InventoryThemeFactory.TYPE_MODAL)`,
## `get_theme_color(&"scrim_color", InventoryThemeFactory.TYPE_MODAL)`) and
## applied via `add_theme_stylebox_override`/direct property assignment. Do
## not change the Theme registrations to "fix" this -- see the task brief
## this file was introduced under for the full rationale.
##
## `set_content`'s contract (DESIGN.md leaves the exact replace-semantics to
## the implementation): a single content [Control] at a time. Calling [method
## set_content] again reparents the NEW control into this modal and calls
## `queue_free()` on whatever was previously set -- this method does not
## return the freed control (it is only pending deletion, end of frame, and
## must not be touched by the caller afterward).

## Esc pressed, or a mouse press on the scrim -- the HOST decides whether to
## actually close (a game may want to confirm discarding unsaved input
## first); call [method close] once it decides to.
signal dismiss_requested

var tokens: InventoryDesignTokens

var _scrim: ColorRect
var _panel: PanelContainer
var _panel_content: VBoxContainer
var _title_label: Label
var _content_control: Control
var _status_row: HBoxContainer
var _status_icon: TextureRect
var _status_label: Label
var _motion_tween: Tween
var _state: StringName = InventoryPresentationModel.STATE_NORMAL


func _init() -> void:
	# Deliberately NOT anchor-preset FULL_RECT: this addon's controls size
	# themselves from EXPLICIT host-assigned `.size` (matching
	# [InventoryTwoPaneView]'s own "no automatic Container/anchor layout"
	# convention, see that file's header comment) rather than Godot's
	# automatic anchor system -- anchors fighting an explicit `.size`
	# assignment is exactly what produces the engine's own "non-equal
	# opposite anchors" warning. The host is responsible for keeping this
	# control's `.size` in sync with whatever it should cover (typically the
	# full window/viewport rect); [method _update_layout] (on [signal
	# Control.resized]) re-centers [member _panel] and re-sizes [member
	# _scrim] to match whenever that happens.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	_build_children()
	resized.connect(_update_layout)


## Eagerly mirrors the Theme's `scrim_color`/panel StyleBox the moment a
## [Theme] resource actually becomes available on this control -- assigning
## `.theme` fires this synchronously, independent of the tree or of whether
## [method set_content]/[method apply_state]/[method present] have been
## called yet, so a caller that only ever calls [method set_title]/[method
## set_content] (never explicitly [method apply_state]) still sees the real
## themed scrim color from [method scrim_color] rather than [ColorRect]'s
## opaque-white engine default.
func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED:
		_refresh_theme_visuals()


func _build_children() -> void:
	_scrim = ColorRect.new()
	_scrim.name = "Scrim"
	_scrim.mouse_filter = Control.MOUSE_FILTER_STOP
	# Sized/positioned explicitly by [method _update_layout] on every resize
	# -- NOT anchor-preset (see [method _init]'s doc comment for why this
	# whole control avoids Godot's automatic anchor layout in favor of
	# explicit `tokens`-derived geometry, matching [InventoryTwoPaneView]'s
	# own convention); anchors fighting an explicit `.size` assignment is
	# exactly what produces the engine's "non-equal opposite anchors"
	# warning.
	_scrim.gui_input.connect(_on_scrim_gui_input)
	add_child(_scrim)

	_panel = PanelContainer.new()
	_panel.name = "Panel"
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_panel.theme_type_variation = InventoryThemeFactory.TYPE_MODAL
	add_child(_panel)

	_panel_content = VBoxContainer.new()
	_panel_content.name = "PanelContent"
	_panel.add_child(_panel_content)

	_title_label = Label.new()
	_title_label.name = "Title"
	# DESIGN.md §10.3 ellipsis+tooltip contract -- MUST precede any `.text =`
	# assignment, matching every other primitive's identical ordering rule
	# (see [InventoryTooltip._fit_label_width]'s doc comment for why).
	_title_label.clip_text = true
	_title_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_panel_content.add_child(_title_label)

	_status_row = HBoxContainer.new()
	_status_row.name = "StatusRow"
	_status_row.visible = false
	_panel_content.add_child(_status_row)

	_status_icon = TextureRect.new()
	_status_icon.name = "StatusIcon"
	_status_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_status_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_status_icon.visible = false
	_status_row.add_child(_status_icon)

	_status_label = Label.new()
	_status_label.name = "StatusText"
	_status_label.clip_text = true
	_status_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_status_row.add_child(_status_label)


## §10.3 ellipsis+tooltip; [param p_tokens], when supplied, becomes [member
## tokens] (the same "populate also carries tokens" convention every other
## primitive in this addon uses).
func set_title(text: String, p_tokens: InventoryDesignTokens = null) -> void:
	if p_tokens != null:
		tokens = p_tokens
	_title_label.text = text
	_title_label.tooltip_text = text


## See this file's header comment for the replace contract. Re-setting the
## SAME control instance already hosted here is a safe no-op (just re-runs
## layout) rather than freeing the very control the caller just passed back
## in -- lets a host reuse one content control (e.g. one shared
## [InventoryQuantitySpinner]) across repeated [method set_content] calls
## without re-instantiating it each time.
func set_content(control: Control) -> void:
	if control == _content_control:
		_update_layout()
		return
	if _content_control != null and is_instance_valid(_content_control):
		_panel_content.remove_child(_content_control)
		_content_control.queue_free()
	_content_control = control
	if control != null:
		_panel_content.add_child(control)
		# Always right after the title (index 0) -- [member _status_row] was
		# added once in [method _build_children] and stays the trailing child
		# either way, so this keeps title -> content -> status row order
		# regardless of how many times content is replaced.
		_panel_content.move_child(control, 1)
	_update_layout()


func content() -> Control:
	return _content_control


## Shows this modal centered over its own current rect, focuses the first
## focusable control inside [method content] (§11.3), then animates it open.
## A no-op outside the tree -- [method set_title]/[method set_content]/
## [method apply_state] remain fully headless-drivable without a live
## viewport, matching [InventoryTooltip.present]'s convention.
func present() -> void:
	if not is_inside_tree():
		return
	_refresh_theme_visuals()
	visible = true
	_update_layout()
	var focusables := _focusable_descendants(_content_control)
	if not focusables.is_empty():
		(focusables[0] as Control).grab_focus()
	animate_open()


## The host's actual "close" action (e.g. after deciding what to do with
## [signal dismiss_requested], or after a successful confirm) -- runs [method
## animate_close], which ends hidden either way (tween or instant).
func close() -> void:
	if not visible:
		return
	animate_close()


func _update_layout() -> void:
	_scrim.size = size
	_scrim.position = Vector2.ZERO
	var panel_size := _panel.get_combined_minimum_size()
	_panel.size = panel_size
	_panel.position = ((size - panel_size) * 0.5).round()


func _on_scrim_gui_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
		dismiss_requested.emit()


## Esc does NOT mark the event handled -- unlike [InventoryContextMenu]'s
## identical-looking Esc branch, this modal is typically hosted underneath a
## [InventoryTwoPaneView] whose OWN `_unhandled_input` forwards the same Esc
## to [method InventoryInteractionController.handle_input_event] ->  [method
## InventoryInteractionController.cancel] -> the ACTUAL split-teardown path
## (see [signal InventoryInteractionController.split_quantity_closed]).
## Swallowing the event here would risk starving that path depending on
## engine `_unhandled_input` delivery order between sibling/ancestor nodes;
## emitting [signal dismiss_requested] without consuming the event costs
## nothing (both paths are idempotent -- see [method
## InventoryInteractionController.cancel_split]'s own doc comment) and removes
## the ordering risk entirely.
func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed(&"ui_cancel"):
		dismiss_requested.emit()
		return
	if event.is_action_pressed(&"ui_focus_next"):
		if _advance_trapped_focus(1):
			get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed(&"ui_focus_prev"):
		if _advance_trapped_focus(-1):
			get_viewport().set_input_as_handled()


## §11.3 "focus-trapped": Tab/Shift-Tab cycle only among [method content]'s
## own focusable descendants, wrapping at each end, instead of Godot's default
## focus traversal (which walks the whole scene tree and would happily escape
## this modal into whatever the host has underneath the scrim). LIMITATION,
## documented honestly: this recomputes a flat descendant list on every Tab
## press and ignores any custom `focus_next`/`focus_previous` neighbor
## assignment those descendants might carry -- adequate for the simple
## single-row content (e.g. [InventoryQuantitySpinner]) this wave hosts, not a
## general nested-focus-group solution.
func _advance_trapped_focus(direction: int) -> bool:
	var focusables := _focusable_descendants(_content_control)
	if focusables.is_empty():
		return false
	var viewport := get_viewport()
	var current: Control = viewport.gui_get_focus_owner() if viewport != null else null
	var idx := focusables.find(current)
	if idx < 0:
		var target: Control = focusables[0] if direction > 0 else focusables[focusables.size() - 1]
		target.grab_focus()
		return true
	var next_idx := (idx + direction + focusables.size()) % focusables.size()
	(focusables[next_idx] as Control).grab_focus()
	return true


func _focusable_descendants(root: Node) -> Array:
	var result: Array = []
	if root == null:
		return result
	_collect_focusable(root, result)
	return result


func _collect_focusable(node: Node, result: Array) -> void:
	for child in node.get_children():
		if child is Control:
			var c: Control = child
			if c.visible and c.focus_mode != Control.FOCUS_NONE:
				result.append(c)
		_collect_focusable(child, result)


## DESIGN.md §9 "Modal open/close: panel scale (~0.92->1.0, pivot center) +
## fade, scrim alpha fade, duration_base; reduced: instant show/hide for BOTH
## modal and scrim." Split out from [method present] so a headless test can
## drive it directly, exactly like [method InventoryTooltip.animate_appear].
## Guarded by [method Node.is_inside_tree] independent of the reduced-motion
## setting -- [method Node.create_tween] hard-requires a live tree, so a
## headless caller that never adds this control to a running [SceneTree] gets
## the same instant-apply behavior reduced motion would give it, rather than
## an engine error.
func animate_open() -> void:
	visible = true
	if _reduced_motion() or not is_inside_tree():
		_panel.modulate.a = 1.0
		_panel.scale = Vector2.ONE
		_scrim.modulate.a = 1.0
		return
	_kill_tween()
	_panel.pivot_offset = _panel.size * 0.5
	_panel.modulate.a = 0.0
	_panel.scale = Vector2(0.92, 0.92)
	_scrim.modulate.a = 0.0
	var duration := _duration_seconds(&"base")
	_motion_tween = create_tween()
	_motion_tween.set_parallel(true)
	if tokens != null:
		_motion_tween.set_trans(tokens.ease_standard_transition).set_ease(tokens.ease_standard_type)
	_motion_tween.tween_property(_panel, "modulate:a", 1.0, duration)
	_motion_tween.tween_property(_panel, "scale", Vector2.ONE, duration)
	_motion_tween.tween_property(_scrim, "modulate:a", 1.0, duration)


## Ends hidden either way (tween-driven or instant) -- safe to call headless
## (see [method animate_open]'s identical tree guard).
func animate_close() -> void:
	_kill_tween()
	if _reduced_motion() or not is_inside_tree():
		_finish_close()
		return
	_panel.pivot_offset = _panel.size * 0.5
	var duration := _duration_seconds(&"base")
	_motion_tween = create_tween()
	_motion_tween.set_parallel(true)
	if tokens != null:
		_motion_tween.set_trans(tokens.ease_standard_transition).set_ease(tokens.ease_standard_type)
	_motion_tween.tween_property(_panel, "modulate:a", 0.0, duration)
	_motion_tween.tween_property(_panel, "scale", Vector2(0.92, 0.92), duration)
	_motion_tween.tween_property(_scrim, "modulate:a", 0.0, duration)
	_motion_tween.chain().tween_callback(_finish_close)


func _finish_close() -> void:
	visible = false
	_panel.modulate.a = 1.0
	_panel.scale = Vector2.ONE
	_scrim.modulate.a = 1.0


func is_animating() -> bool:
	return _motion_tween != null and _motion_tween.is_valid() and _motion_tween.is_running()


func _kill_tween() -> void:
	if _motion_tween != null and _motion_tween.is_valid():
		_motion_tween.kill()


## Swaps this modal's WHOLE panel background via the [method
## InventoryThemeFactory.state_stylebox_name] explicit-lookup convention
## (same "one named panel StyleBox per state" registration [InventoryContextMenu]
## uses -- see this file's header comment), re-applies [member scrim_color]'s
## themed value, and -- for the states §12.10's signifier column names as
## having a MODAL-level (not content-level) status banner: rejected/
## stale-corrected/disconnected/resynchronizing -- populates [method
## status_text] with a drawn [InventoryStateIcons] icon alongside real human
## text (§11.2, never color/icon alone). Every OTHER §12.10 state
## (pending/accepted-flash/read-only/disabled/loading/overflow) describes a
## signifier that lives on the HOSTED CONTENT itself (the confirm button's
## spinner, a field's own lock glyph, ...), which this generic host control
## has no way to reach into -- honestly left to the content control's own
## primitive/state wiring rather than faked here.
func apply_state(state: StringName) -> void:
	_state = state
	_refresh_theme_visuals()


func _refresh_theme_visuals() -> void:
	var stylebox := get_theme_stylebox(InventoryThemeFactory.state_stylebox_name(_state), InventoryThemeFactory.TYPE_MODAL)
	if stylebox == null:
		stylebox = get_theme_stylebox(&"panel", InventoryThemeFactory.TYPE_MODAL)
	if stylebox != null:
		_panel.add_theme_stylebox_override(&"panel", stylebox)
	_scrim.color = get_theme_color(&"scrim_color", InventoryThemeFactory.TYPE_MODAL)

	var note := _status_note(_state)
	_status_label.text = note
	_status_label.tooltip_text = note
	var icon_tex: Texture2D = null
	if not note.is_empty():
		icon_tex = InventoryStateIcons.icon_for(InventoryStateGlyphs.glyph_for_item_state(_state))
	_status_icon.texture = icon_tex
	_status_icon.visible = icon_tex != null
	if icon_tex != null:
		_status_icon.modulate = InventoryThemeFactory.state_icon_color(_state)
	_status_row.visible = not note.is_empty()
	_update_layout()


func _status_note(state: StringName) -> String:
	match state:
		InventoryPresentationModel.STATE_REJECTED:
			return "Rejected"
		InventoryPresentationModel.STATE_STALE_CORRECTED:
			return "Baseline changed — reopen"
		InventoryPresentationModel.STATE_DISCONNECTED:
			return "Disconnected — action unavailable"
		InventoryPresentationModel.STATE_RESYNCHRONIZING:
			return "Resynchronizing"
		_:
			return ""


func _reduced_motion() -> bool:
	return tokens != null and bool(tokens.get("reduced_motion_enabled"))


func _duration_seconds(token: StringName) -> float:
	return (tokens.duration_ms(token) / 1000.0) if tokens != null else 0.0


# =============================================================================
# Test/inspection accessors -- proving populated content and real API state,
# not pixels (matching every other primitive in this addon).
# =============================================================================

func title_text() -> String:
	return _title_label.text


func scrim_color() -> Color:
	return _scrim.color


func status_text() -> String:
	return _status_label.text


func status_icon_texture() -> Texture2D:
	return _status_icon.texture


func current_panel_stylebox() -> StyleBox:
	return _panel.get_theme_stylebox(&"panel")
