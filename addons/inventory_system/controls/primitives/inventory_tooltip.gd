class_name InventoryTooltip
extends PopupPanel

## Transient inspection surface (tasks.md 8.3; DESIGN.md §6.4, §12.6).
## Populates from a snapshot item Dictionary and the model's resolved state;
## never calls into an authority. [method show_for_item] only populates
## content -- it deliberately does NOT call [method Window.popup] itself
## (headless/no-viewport instantiation, this addon's test convention, must
## stay crash-free with no window backing yet); a host calls [method present]
## once the tooltip is parented into a live viewport.
##
## The state note row pairs a drawn [InventoryStateIcons] icon (tinted per
## [method InventoryThemeFactory.state_icon_color]) with its existing short
## text (visual-qa-2026-07-27.md finding 1 was about controls rendering the
## RAW glyph token as text; this tooltip's [member _state_label] already held
## real human-readable text, so the fix here is purely additive -- the icon
## alongside it, not a text replacement).

var tokens: InventoryDesignTokens

var _content: VBoxContainer
var _title_label: Label
var _body_label: Label
var _state_row: HBoxContainer
var _state_icon: TextureRect
var _state_label: Label
var _appear_tween: Tween

## DESIGN.md §10.3: translatable labels reserve +30% width headroom over
## their own baseline content width (see [method _fit_label_width]), capped
## at this max-width token so a single pathological string cannot blow the
## popup out arbitrarily wide. [InventoryDesignTokens] (the shared, do-not-
## edit-for-this-task resource -- see that script's own header comment)
## declares no max-width token of its own (only grid/card/pane-breakpoint
## units), so this stays a LOCAL constant, still expressed as a
## `tokens.unit()` multiple like every other geometry value in this addon
## rather than a literal pixel constant.
const MAX_CONTENT_WIDTH_UNITS := 26.0


func _init() -> void:
	theme_type_variation = InventoryThemeFactory.TYPE_TOOLTIP
	_build_children()


func _build_children() -> void:
	_content = VBoxContainer.new()
	_content.name = "Content"
	add_child(_content)

	_title_label = Label.new()
	_title_label.name = "Title"
	_content.add_child(_title_label)

	_body_label = Label.new()
	_body_label.name = "Body"
	_content.add_child(_body_label)

	_state_row = HBoxContainer.new()
	_state_row.name = "StateRow"
	_content.add_child(_state_row)

	_state_icon = TextureRect.new()
	_state_icon.name = "StateIcon"
	_state_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_state_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_state_icon.visible = false
	_state_row.add_child(_state_icon)

	_state_label = Label.new()
	_state_label.name = "StateNote"
	_state_row.add_child(_state_label)

	# DESIGN.md §10.3: no translatable text in a fixed-pixel-width container
	# that can overflow into neighboring UI (visual-qa-2026-07-27.md finding
	# 6) -- every label here truncates with an ellipsis instead. `clip_text`
	# must be set (not just `text_overrun_behavior`) so a long string's
	# intrinsic glyph width stops contributing to `get_minimum_size()`; see
	# [method _fit_label_width]'s doc comment for why that ordering matters.
	for label in [_title_label, _body_label, _state_label]:
		label.clip_text = true
		label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL


## [param item]: one entry of [method InventorySnapshotResource.get_items].
func show_for_item(model: InventoryPresentationModel, inventory_id: int, item: Dictionary, p_tokens: InventoryDesignTokens) -> void:
	tokens = p_tokens if p_tokens != null else InventoryDesignTokens.new()
	var item_id := int(item.get("id", 0))
	var state := model.item_state(inventory_id, item_id) if model != null else InventoryPresentationModel.STATE_NORMAL

	if state == InventoryPresentationModel.STATE_REDACTED:
		_title_label.text = "Redacted"
		_body_label.text = ""
	else:
		_title_label.text = String(item.get("item_definition_identifier", ""))
		_body_label.text = "Quantity: %d" % int(item.get("quantity", 1))

	_state_label.text = _state_note(model, state)

	# DESIGN.md §7/§11.2/finding 1: a drawn icon alongside the existing text
	# note above -- never the raw InventoryStateGlyphs token as text (this
	# label already held real human phrasing; only the icon is new here).
	var glyph := InventoryStateGlyphs.glyph_for_item_state(state)
	var state_icon_tex := InventoryStateIcons.icon_for(glyph)
	_state_icon.custom_minimum_size = Vector2(tokens.unit(1.0), tokens.unit(1.0))
	_state_icon.texture = state_icon_tex
	_state_icon.visible = state_icon_tex != null
	if state_icon_tex != null:
		_state_icon.modulate = InventoryThemeFactory.state_icon_color(state)

	# DESIGN.md §10.3: reserve headroom, then truncate; §10.3 also requires
	# the full string stay reachable via tooltip/inspect even for a label
	# THIS control itself had to truncate -- native [member Control.tooltip_text]
	# is the reachable fallback for that edge case (an over-long identifier
	# even beyond this popup's own reserved width).
	var max_width := tokens.unit(MAX_CONTENT_WIDTH_UNITS)
	for label in [_title_label, _body_label, _state_label]:
		_fit_label_width(label, max_width)
		label.tooltip_text = label.text


## Test/inspection accessors -- proving populated content, not pixels.
func title_text() -> String:
	return _title_label.text


func body_text() -> String:
	return _body_label.text


func state_note_text() -> String:
	return _state_label.text


## The drawn [Texture2D] this tooltip's state row currently shows (`null`
## for a state with no icon at all, e.g. `normal`).
func state_icon_texture() -> Texture2D:
	return _state_icon.texture


## DESIGN.md §10.3: reserve +30% width headroom over [param label]'s own
## current (baseline) content width, capped at [param max_width]. Must run
## AFTER [param label].text is assigned and AFTER `clip_text` is already
## `true` (set once in [method _build_children]) -- [member Label.clip_text]
## is what stops a long string's glyph width from being folded into
## [method Control.get_minimum_size] at all, so [member
## Control.custom_minimum_size] below is the ONLY width [param label] ends
## up reporting upward; without `clip_text` first, Godot's own
## `Control.size` setter clamps back up to the text's full intrinsic width
## the next time geometry is touched, silently undoing this reservation
## (this is the exact mechanism visual-qa-2026-07-27.md finding 6 caught).
func _fit_label_width(label: Label, max_width: float) -> void:
	var natural_width := 0.0
	var font := label.get_theme_font(&"font")
	if font != null:
		var font_size := label.get_theme_font_size(&"font_size")
		natural_width = font.get_string_size(label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	var reserved_width := natural_width * 1.3 if natural_width > 0.0 else max_width
	label.custom_minimum_size.x = minf(reserved_width, max_width)


func _state_note(model: InventoryPresentationModel, state: StringName) -> String:
	match state:
		InventoryPresentationModel.STATE_REDACTED:
			return "Redacted"
		InventoryPresentationModel.STATE_PENDING:
			return "Pending"
		InventoryPresentationModel.STATE_READ_ONLY:
			return "Read-only"
		InventoryPresentationModel.STATE_DISCONNECTED:
			return "Disconnected"
		InventoryPresentationModel.STATE_RESYNCHRONIZING:
			return "Resynchronizing"
		InventoryPresentationModel.STATE_REJECTED:
			var rejection := model.get_last_rejection() if model != null else {}
			return "Rejected: %s" % String(rejection.get("reason_token", &""))
		InventoryPresentationModel.STATE_STALE_CORRECTED:
			return "Updated"
		_:
			return ""


## Convenience for a host that already has a live viewport; safe to skip in
## headless tests, which only exercise [method show_for_item]'s content.
func present(at_position: Vector2i = Vector2i.ZERO) -> void:
	if not is_inside_tree():
		return
	position = at_position
	popup()
	animate_appear()


## DESIGN.md §9 "Tooltip appear: fade + 8px rise, duration_fast; reduced:
## instant appearance, no fade/rise." Split out from [method present] (which
## requires a live viewport via [method Window.popup]) so a headless test can
## drive it directly. Animates [member _content], not this control itself:
## [PopupPanel] extends [Window], which is NOT a [CanvasItem] (no `modulate`,
## no float-based `position` to tween) -- [member _content] is a plain
## [Control] child and the correct thing to fade/rise here regardless.
func animate_appear() -> void:
	if _reduced_motion():
		_content.modulate.a = 1.0
		return
	_kill_appear_tween()
	# DESIGN.md's literal "8px rise" IS exactly one spacing unit at the
	# reference scale (`inventory.design.spacing.unit` = 8px @ ui_scale 1.0,
	# §3.6) -- `tokens.unit(1.0)` expresses that same distance as a proper
	# token multiple instead of a raw pixel literal, so it still rescales
	# with `ui_scale` like every other geometry value in this addon.
	var rise := tokens.unit(1.0) if tokens != null else 8.0
	var base_y := _content.position.y
	_content.modulate.a = 0.0
	_content.position.y = base_y + rise
	_appear_tween = create_tween()
	_appear_tween.set_parallel(true)
	_appear_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_appear_tween.tween_property(_content, "modulate:a", 1.0, _duration_seconds(&"fast"))
	_appear_tween.tween_property(_content, "position:y", base_y, _duration_seconds(&"fast"))


func is_appear_animating() -> bool:
	return _appear_tween != null and _appear_tween.is_valid() and _appear_tween.is_running()


func _kill_appear_tween() -> void:
	if _appear_tween != null and _appear_tween.is_valid():
		_appear_tween.kill()
	_content.modulate.a = 1.0


## See [InventoryItemCard]'s identical helper's doc comment for why this is
## a dynamic `tokens.get(...)` lookup rather than direct field access.
func _reduced_motion() -> bool:
	return tokens != null and bool(tokens.get("reduced_motion_enabled"))


func _duration_seconds(token: StringName) -> float:
	return (tokens.duration_ms(token) / 1000.0) if tokens != null else 0.0
