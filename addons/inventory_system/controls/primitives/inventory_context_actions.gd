class_name InventoryContextActions
extends VBoxContainer

## Context-action list stub (tasks.md 8.3; DESIGN.md §12.7-§12.8). Renders a
## themed [Button] per entry from a caller-supplied action list and emits
## [signal action_pressed] -- it never submits a command itself, matching
## every other control in this addon ("NO direct authority calls").
##
## [method populate] accepts the caller's own action list directly (the
## richer source: allowed-command metadata derived from catalog access
## masks/enabled features, which is composition-layer work, tasks.md 8.4/8.5,
## explicitly deferred past this wave). [method populate_from_model] is a
## conservative FALLBACK that derives only what [InventoryPresentationModel]
## alone can know for one item -- currently just "inspect" (always available
## unless the item is redacted) and "cancel" (only while a pending intent
## exists for it) -- so this primitive is still genuinely usable standalone
## before richer metadata plumbing exists.

## [param action_id] is the caller-supplied `id` from the pressed entry's
## Dictionary.
signal action_pressed(action_id: StringName)

var tokens: InventoryDesignTokens
var _buttons: Dictionary = {} # StringName action_id -> Button


func _init() -> void:
	pass


## [param actions]: [code]Array[Dictionary{id: StringName, label: String,
## enabled: bool (default true), glyph: StringName (optional, DESIGN.md §7.2
## name)}][/code], in the order they should render.
func populate(actions: Array, p_tokens: InventoryDesignTokens = null) -> void:
	tokens = p_tokens if p_tokens != null else InventoryDesignTokens.new()
	for child in get_children():
		remove_child(child)
		child.queue_free()
	_buttons.clear()

	for entry_variant in actions:
		var entry: Dictionary = entry_variant
		var action_id := StringName(entry.get("id", &""))
		if String(action_id).is_empty():
			continue
		var button := Button.new()
		button.name = String(action_id)
		button.theme_type_variation = InventoryThemeFactory.TYPE_ACTION_BAR_ENTRY
		var glyph := StringName(entry.get("glyph", &""))
		var label := String(entry.get("label", String(action_id)))
		# DESIGN.md §12.8 "icon + label": the glyph TOKEN never belongs in
		# button text (visual-qa-2026-07-27.md finding 1's class of defect --
		# a raw glyph-name string rendered as literal Label/Button text). Text
		# is the label alone; the glyph resolves through the shared drawn-icon
		# registry and becomes `Button.icon` instead, same as every other
		# control this addon wires to [InventoryStateIcons]. A glyph with no
		# registered icon yet (e.g. "cancel", which has no §7.2 entry) simply
		# renders with no icon -- [method InventoryStateIcons.icon_for]
		# returns null rather than inventing one.
		button.text = label
		var icon_texture := InventoryStateIcons.icon_for(glyph)
		if icon_texture != null:
			button.icon = icon_texture
		# DESIGN.md §10.3: a translated label that still overflows its
		# available width truncates with an ellipsis and stays reachable in
		# full via tooltip -- the same `clip_text` + `OVERRUN_TRIM_ELLIPSIS` +
		# `tooltip_text` contract [InventoryTooltip]'s own labels use (see
		# that script's [method InventoryTooltip._fit_label_width] doc
		# comment for why `clip_text` must be set at all). This button does
		# NOT mirror that primitive's "+30% headroom, then clamp" sizing step:
		# headroom reservation exists to keep a *container* from silently
		# regrowing to a long string's full intrinsic width (the exact
		# regression visual-qa-2026-07-27.md finding 6 caught); a [Button] in
		# an [InventoryContextActions] [VBoxContainer] is instead naturally
		# width-capped by its parent/host layout, so plain ellipsis + tooltip
		# fallback is the complete fix here -- there is no fixed-width
		# container geometry to protect from regrowing.
		button.clip_text = true
		button.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		button.tooltip_text = label
		button.disabled = not bool(entry.get("enabled", true))
		button.pressed.connect(_on_button_pressed.bind(action_id))
		add_child(button)
		_buttons[action_id] = button


func populate_from_model(model: InventoryPresentationModel, inventory_id: int, item_id: int, p_tokens: InventoryDesignTokens = null) -> void:
	var state := model.item_state(inventory_id, item_id) if model != null else InventoryPresentationModel.STATE_NORMAL
	var actions: Array = []
	if state != InventoryPresentationModel.STATE_REDACTED:
		actions.append({"id": &"inspect", "label": "Inspect", "glyph": &"inspect", "enabled": true})
	if state == InventoryPresentationModel.STATE_PENDING:
		actions.append({"id": &"cancel", "label": "Cancel", "enabled": true})
	populate(actions, p_tokens)


func is_action_enabled(action_id: StringName) -> bool:
	var button: Button = _buttons.get(action_id, null)
	return button != null and not button.disabled


func action_count() -> int:
	return _buttons.size()


func _on_button_pressed(action_id: StringName) -> void:
	action_pressed.emit(action_id)
