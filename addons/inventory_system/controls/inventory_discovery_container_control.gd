class_name InventoryDiscoveryContainerControl
extends Control

## Recipient-only staged-discovery renderer (DESIGN.md §12.11). It consumes
## one [InventoryDiscoveryContainerViewResource] plus the model's projected
## snapshot and emits captured Search/Scan/Cancel intent records. It never
## receives or calls an [InventoryAuthority], never decodes an opaque token,
## and never invents a footprint/location for an unknown entry.
##
## Revealed items are rendered through [InventoryItemCard], the same ordinary
## primitive every non-discovery layout uses. Unknown entries are separate
## token-keyed buttons with no select/context/open/drag signals, so ordinary
## item actions are structurally unreachable until the recipient snapshot
## actually reveals an item.

signal intent_requested(kind: StringName, args: Dictionary)

var model: InventoryPresentationModel
var inventory_id: int = 0
var discovery_view: InventoryDiscoveryContainerViewResource
var tokens: InventoryDesignTokens

var _background: Panel
var _header: Label
var _status: Label
var _summary: Label
var _container_progress_track: ColorRect
var _container_progress_fill: ColorRect
var _primary_action: Button
var _entry_buttons: Dictionary = {} # opaque token -> Button
var _entry_progress: Dictionary = {} # opaque token -> {track: ColorRect, fill: ColorRect}
var _revealed_cards: Array[InventoryItemCard] = []
var _dynamic_nodes: Array[Node] = []
var _last_progress_fraction: float = 0.0


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS
	focus_mode = Control.FOCUS_ALL
	_build_base_children()


func configure(
		p_model: InventoryPresentationModel,
		p_inventory_id: int,
		p_view: InventoryDiscoveryContainerViewResource,
		p_tokens: InventoryDesignTokens) -> void:
	model = p_model
	inventory_id = p_inventory_id
	discovery_view = p_view
	tokens = p_tokens if p_tokens != null else InventoryDesignTokens.new()
	_rebuild()


func container_token() -> int:
	return discovery_view.get_token() if discovery_view != null else 0


func disclosed_container_id() -> int:
	return discovery_view.get_container_id() if discovery_view != null else 0


func current_state() -> StringName:
	if model == null or discovery_view == null:
		return InventoryPresentationModel.STATE_INACCESSIBLE
	if model.is_disconnected():
		return InventoryPresentationModel.STATE_DISCONNECTED
	if model.is_resynchronizing() or model.discovery_needs_resync(inventory_id):
		return InventoryPresentationModel.STATE_RESYNCHRONIZING
	if discovery_view.get_stage() == InventoryDiscoveryContainerViewResource.STAGE_INDEXED:
		return InventoryPresentationModel.STATE_DISCOVERY_INDEXED
	return model.discovery_container_state(inventory_id, discovery_view.get_token())


func primary_action_button() -> Button:
	return _primary_action


func entry_button(entry_token: int) -> Button:
	return _entry_buttons.get(entry_token, null)


func entry_tokens() -> Array[int]:
	var result: Array[int] = []
	for token in _entry_buttons.keys():
		result.append(int(token))
	result.sort()
	return result


func revealed_item_cards() -> Array[InventoryItemCard]:
	return _revealed_cards.duplicate()


func card_for_item(item_id: int) -> InventoryItemCard:
	for card in _revealed_cards:
		if card.item_id == item_id:
			return card
	return null


func summary_text() -> String:
	return _summary.text


func status_text() -> String:
	return _status.text


func progress_fraction() -> float:
	return _last_progress_fraction


func _build_base_children() -> void:
	_background = Panel.new()
	_background.name = "Background"
	_background.theme_type_variation = InventoryThemeFactory.TYPE_DISCOVERY_CONTAINER
	_background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_background)

	_header = Label.new()
	_header.name = "Header"
	_header.theme_type_variation = InventoryThemeFactory.TYPE_DISCOVERY_CONTAINER
	_header.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_header.clip_text = true
	_header.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	add_child(_header)

	_status = Label.new()
	_status.name = "Status"
	_status.theme_type_variation = InventoryThemeFactory.TYPE_DISCOVERY_CONTAINER
	_status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_status)

	_summary = Label.new()
	_summary.name = "Summary"
	_summary.theme_type_variation = InventoryThemeFactory.TYPE_DISCOVERY_CONTAINER
	_summary.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_summary)

	_container_progress_track = ColorRect.new()
	_container_progress_track.name = "ProgressTrack"
	_container_progress_track.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_container_progress_track)

	_container_progress_fill = ColorRect.new()
	_container_progress_fill.name = "ProgressFill"
	_container_progress_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_container_progress_fill)

	_primary_action = Button.new()
	_primary_action.name = "PrimaryAction"
	_primary_action.theme_type_variation = InventoryThemeFactory.TYPE_ACTION_BAR_ENTRY
	_primary_action.focus_mode = Control.FOCUS_ALL
	_primary_action.icon_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_primary_action.expand_icon = true
	add_child(_primary_action)


func _rebuild() -> void:
	for token in _entry_buttons.keys():
		var button: Button = _entry_buttons[token]
		if is_instance_valid(button):
			remove_child(button)
			button.queue_free()
	for token in _entry_progress.keys():
		var pair: Dictionary = _entry_progress[token]
		for key in [&"track", &"fill"]:
			var rect: ColorRect = pair.get(key, null)
			if rect != null and is_instance_valid(rect):
				remove_child(rect)
				rect.queue_free()
	for card in _revealed_cards:
		if card != null and is_instance_valid(card):
			remove_child(card)
			card.queue_free()
	for node in _dynamic_nodes:
		if node != null and is_instance_valid(node):
			remove_child(node)
			node.queue_free()
	_entry_buttons.clear()
	_entry_progress.clear()
	_revealed_cards.clear()
	_dynamic_nodes.clear()

	if discovery_view == null:
		visible = false
		custom_minimum_size = Vector2.ZERO
		return
	visible = true

	var width := _snap(tokens.unit(42.0))
	var inset := _snap(tokens.unit(1.5))
	var gap := _snap(tokens.unit(1.0))
	var summary_gap := _snap(tokens.unit(0.5))
	var header_height := _snap(tokens.unit(3.0))
	var label_height := _snap(tokens.unit(2.5))
	var action_height := _snap(tokens.unit(6.0))
	var progress_height := _snap(tokens.unit(0.5))
	var content_width := width - inset * 2.0
	var running_y := inset

	_header.text = tr(discovery_view.get_shell_label())
	_header.tooltip_text = _header.text
	_header.position = Vector2(inset, running_y)
	_header.size = Vector2(content_width, header_height)
	running_y += header_height + summary_gap

	_status.visible = true
	_summary.visible = false
	_container_progress_track.visible = false
	_container_progress_fill.visible = false
	_primary_action.visible = false
	_last_progress_fraction = 0.0

	var state := current_state()
	match discovery_view.get_stage():
		InventoryDiscoveryContainerViewResource.STAGE_UNSEARCHED:
			_status.text = tr("Contents unknown")
			_layout_label(_status, inset, running_y, content_width, label_height)
			running_y += label_height + gap
			_configure_primary_action(
					tr("Search container"),
					InventoryStateIcons.icon_for(&"discovery_search"),
					InventoryPresentationModel.DISCOVERY_INTENT_SEARCH,
					discovery_view.get_token())
			_layout_primary_action(inset, running_y, content_width, action_height)
			running_y += action_height

		InventoryDiscoveryContainerViewResource.STAGE_SEARCHING:
			var elapsed := discovery_view.get_elapsed_ms()
			var duration := discovery_view.get_duration_ms()
			_status.text = _progress_text(tr("Searching"), elapsed, duration)
			_layout_label(_status, inset, running_y, content_width, label_height)
			running_y += label_height + summary_gap
			_last_progress_fraction = InventoryPresentationModel.discovery_progress(elapsed, duration)
			_layout_progress(
					_container_progress_track,
					_container_progress_fill,
					inset,
					running_y,
					content_width,
					progress_height,
					_last_progress_fraction)
			running_y += progress_height + gap
			_configure_primary_action(
					tr("Cancel search"),
					InventoryStateIcons.icon_for(&"discovery_cancel"),
					InventoryPresentationModel.DISCOVERY_INTENT_CANCEL,
					discovery_view.get_token())
			_layout_primary_action(inset, running_y, content_width, action_height)
			running_y += action_height

		InventoryDiscoveryContainerViewResource.STAGE_INDEXED:
			_status.text = tr("Indexed")
			_layout_label(_status, inset, running_y, content_width, label_height)
			running_y += label_height + summary_gap
			_summary.text = _indexed_summary()
			_summary.visible = true
			var summary_height := _snap(tokens.unit(3.0))
			_layout_label(_summary, inset, running_y, content_width, summary_height)
			running_y += summary_height + gap
			running_y = _build_indexed_contents(inset, running_y, content_width, action_height, progress_height, gap)

	if state == InventoryPresentationModel.STATE_PENDING:
		_primary_action.disabled = true
		_primary_action.text = tr("Pending")
		_primary_action.icon = InventoryStateIcons.icon_for(&"pending")
	elif state == InventoryPresentationModel.STATE_DISCONNECTED:
		_status.text = tr("Unavailable while disconnected")
		_primary_action.disabled = true
		for button_variant in _entry_buttons.values():
			(button_variant as Button).disabled = true
	elif state == InventoryPresentationModel.STATE_RESYNCHRONIZING:
		_status.text = tr("Resynchronizing")
		_primary_action.disabled = true
		for button_variant in _entry_buttons.values():
			(button_variant as Button).disabled = true

	running_y += inset
	size = Vector2(width, _snap(running_y))
	custom_minimum_size = size
	_background.position = Vector2.ZERO
	_background.size = size
	_apply_theme()
	call_deferred(&"_restore_focus")


func _build_indexed_contents(
		inset: float,
		start_y: float,
		content_width: float,
		entry_height: float,
		progress_height: float,
		gap: float) -> float:
	var running_y := start_y
	var ordinal := 1
	for entry_variant in discovery_view.get_entries():
		var entry: InventoryDiscoveryEntryResource = entry_variant
		var token := entry.get_token()
		var button := Button.new()
		button.name = "UnknownEntry_%d" % token
		button.theme_type_variation = InventoryThemeFactory.TYPE_DISCOVERY_ENTRY
		button.focus_mode = Control.FOCUS_ALL
		button.icon_alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.expand_icon = true
		button.position = Vector2(inset, running_y)
		button.size = Vector2(content_width, entry_height)
		button.custom_minimum_size = button.size
		button.tooltip_text = tr("Unknown item %d") % ordinal
		button.focus_entered.connect(
				_on_discovery_focus_entered.bind(InventoryPresentationModel.DISCOVERY_INTENT_SCAN, token))
		add_child(button)
		if entry.get_stage() == InventoryDiscoveryEntryResource.STAGE_SCANNING:
			button.text = tr("Cancel scan · Unknown item %d") % ordinal
			button.icon = InventoryStateIcons.icon_for(&"discovery_cancel")
			button.pressed.connect(_request_intent.bind(
					InventoryPresentationModel.DISCOVERY_INTENT_CANCEL, token))
			var track := ColorRect.new()
			track.name = "ProgressTrack_%d" % token
			track.mouse_filter = Control.MOUSE_FILTER_IGNORE
			add_child(track)
			var fill := ColorRect.new()
			fill.name = "ProgressFill_%d" % token
			fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
			add_child(fill)
			var fraction := InventoryPresentationModel.discovery_progress(
					entry.get_elapsed_ms(), entry.get_duration_ms())
			_layout_progress(
					track,
					fill,
					inset + tokens.unit(1.0),
					running_y + entry_height - progress_height - tokens.unit(0.5),
					content_width - tokens.unit(2.0),
					progress_height,
					fraction)
			_entry_progress[token] = {&"track": track, &"fill": fill}
			button.tooltip_text = "%s. %s" % [
				button.tooltip_text,
				_progress_text(tr("Scanning"), entry.get_elapsed_ms(), entry.get_duration_ms()),
			]
		else:
			button.text = tr("Scan · Unknown item %d") % ordinal
			button.icon = InventoryStateIcons.icon_for(&"discovery_scan")
			button.pressed.connect(_request_intent.bind(
					InventoryPresentationModel.DISCOVERY_INTENT_SCAN, token))
		_entry_buttons[token] = button
		running_y += entry_height + gap
		ordinal += 1

	var snapshot := model.get_snapshot(inventory_id) if model != null else null
	if snapshot != null and discovery_view.get_container_id() > 0:
		for item_variant in snapshot.get_items():
			var item: Dictionary = item_variant
			var location: Dictionary = item.get("location", {})
			if int(location.get("container", -1)) != discovery_view.get_container_id():
				continue
			var card := InventoryItemCard.new()
			card.name = "RevealedItem_%d" % int(item.get("id", 0))
			card.configure(model, inventory_id, item, tokens)
			card.position = Vector2(inset, running_y)
			var card_size := card.custom_minimum_size
			if card_size.x <= 0.0 or card_size.y <= 0.0:
				card_size = Vector2(content_width, tokens.unit(4.0))
			# InventoryItemCard's 3u minimum covers its icon slot, while its
			# ordinary display-name label intentionally occupies the next
			# 0.75u below that slot. Spatial/slot hosts provide at least 4u
			# cells; this disclosure row must provide the same floor or the
			# name escapes the card background.
			var card_height := maxf(card_size.y, tokens.unit(4.0))
			card.size = Vector2(content_width, _snap(card_height))
			card.custom_minimum_size = card.size
			card.pressed.connect(_forward_item_intent.bind(&"select"))
			card.double_clicked.connect(_forward_item_intent.bind(&"open"))
			card.context_requested.connect(_forward_context_intent)
			add_child(card)
			_revealed_cards.append(card)
			running_y += card.size.y + gap

	if discovery_view.get_item_count() == 0:
		var empty := Label.new()
		empty.name = "Empty"
		empty.theme_type_variation = InventoryThemeFactory.TYPE_DISCOVERY_CONTAINER
		empty.text = tr("No items")
		empty.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_layout_label(empty, inset, running_y, content_width, tokens.unit(2.5))
		add_child(empty)
		_dynamic_nodes.append(empty)
		running_y += tokens.unit(2.5) + gap
	return running_y


func _configure_primary_action(
		label: String,
		icon_texture: Texture2D,
		kind: StringName,
		target_token: int) -> void:
	_primary_action.visible = true
	_primary_action.disabled = false
	_primary_action.text = label
	_primary_action.tooltip_text = label
	_primary_action.icon = icon_texture
	for connection in _primary_action.pressed.get_connections():
		_primary_action.pressed.disconnect(connection["callable"])
	for connection in _primary_action.focus_entered.get_connections():
		_primary_action.focus_entered.disconnect(connection["callable"])
	_primary_action.pressed.connect(_request_intent.bind(kind, target_token))
	_primary_action.focus_entered.connect(_on_discovery_focus_entered.bind(kind, target_token))


func _layout_primary_action(x: float, y: float, width: float, height: float) -> void:
	_primary_action.position = Vector2(x, y)
	_primary_action.size = Vector2(width, height)
	_primary_action.custom_minimum_size = _primary_action.size


func _layout_label(label: Label, x: float, y: float, width: float, height: float) -> void:
	label.position = Vector2(x, y)
	label.size = Vector2(width, _snap(height))


func _layout_progress(
		track: ColorRect,
		fill: ColorRect,
		x: float,
		y: float,
		width: float,
		height: float,
		fraction: float) -> void:
	track.visible = true
	fill.visible = true
	track.position = Vector2(_snap(x), _snap(y))
	track.size = Vector2(_snap(width), _snap(height))
	fill.position = track.position
	fill.size = Vector2(_snap(width * clampf(fraction, 0.0, 1.0)), track.size.y)


func _request_intent(kind: StringName, target_token: int) -> void:
	if model == null:
		return
	var request_id := model.begin_discovery_intent(inventory_id, kind, target_token)
	if request_id == 0:
		return
	var captured := model.get_discovery_pending(request_id)
	intent_requested.emit(kind, {
		"request_id": request_id,
		"inventory_id": inventory_id,
		"target_token": int(captured.get("target_token", 0)),
		"expected_inventory_revision": int(captured.get("expected_inventory_revision", -1)),
		"expected_discovery_revision": int(captured.get("expected_discovery_revision", -1)),
	})


func _forward_item_intent(item_id: int, kind: StringName) -> void:
	intent_requested.emit(kind, {"inventory_id": inventory_id, "item_id": item_id})


func _forward_context_intent(item_id: int, anchor_global_position: Vector2) -> void:
	intent_requested.emit(&"context", {
		"inventory_id": inventory_id,
		"item_id": item_id,
		"anchor_global_position": anchor_global_position,
	})


func _on_discovery_focus_entered(kind: StringName, token: int) -> void:
	if model != null:
		model.remember_discovery_focus(inventory_id, kind, token)


func _restore_focus() -> void:
	if model == null or not is_inside_tree():
		return
	var remembered := model.recall_discovery_focus(inventory_id)
	var token := int(remembered.get("token", 0))
	if _entry_buttons.has(token):
		(_entry_buttons[token] as Button).grab_focus()
		model.clear_discovery_focus_recovery(inventory_id)
		return
	if discovery_view != null and discovery_view.get_token() == token and _primary_action.visible:
		_primary_action.grab_focus()
		model.clear_discovery_focus_recovery(inventory_id)
		return
	var recovery := model.get_discovery_focus_recovery(inventory_id)
	var replacement := int(recovery.get("replacement_token", 0))
	if _entry_buttons.has(replacement):
		(_entry_buttons[replacement] as Button).grab_focus()
		model.clear_discovery_focus_recovery(inventory_id)
	elif _primary_action.visible and not _primary_action.disabled:
		_primary_action.grab_focus()
		model.clear_discovery_focus_recovery(inventory_id)


func _indexed_summary() -> String:
	match discovery_view.get_layout_kind():
		InventoryDiscoveryContainerViewResource.LAYOUT_SPATIAL_GRID:
			return tr("Grid %d × %d · %d items") % [
				discovery_view.get_width(),
				discovery_view.get_height(),
				discovery_view.get_item_count(),
			]
		InventoryDiscoveryContainerViewResource.LAYOUT_NAMED_SLOTS:
			return tr("Slots capacity %d · %d items") % [
				discovery_view.get_capacity(),
				discovery_view.get_item_count(),
			]
		InventoryDiscoveryContainerViewResource.LAYOUT_ORDERED_LIST:
			return tr("List capacity %d · %d items") % [
				discovery_view.get_capacity(),
				discovery_view.get_item_count(),
			]
	return tr("Indexed · %d items") % discovery_view.get_item_count()


func _progress_text(prefix: String, elapsed_ms: int, duration_ms: int) -> String:
	if duration_ms <= 0:
		return tr("%s unavailable") % prefix
	return tr("%s — %d / %d ms") % [
		prefix,
		clampi(elapsed_ms, 0, duration_ms),
		duration_ms,
	]


func _apply_theme() -> void:
	var state := current_state()
	var stylebox := _background.get_theme_stylebox(
			InventoryThemeFactory.state_stylebox_name(state),
			InventoryThemeFactory.TYPE_DISCOVERY_CONTAINER)
	if stylebox != null:
		_background.add_theme_stylebox_override(&"panel", stylebox)
	var track_color := _background.get_theme_color(
			&"progress_track_color", InventoryThemeFactory.TYPE_DISCOVERY_CONTAINER)
	var fill_color := _background.get_theme_color(
			&"progress_fill_color", InventoryThemeFactory.TYPE_DISCOVERY_CONTAINER)
	_container_progress_track.color = track_color
	_container_progress_fill.color = fill_color
	for pair_variant in _entry_progress.values():
		var pair: Dictionary = pair_variant
		(pair[&"track"] as ColorRect).color = track_color
		(pair[&"fill"] as ColorRect).color = fill_color
	for token in _entry_buttons.keys():
		var button: Button = _entry_buttons[token]
		var entry_state := model.discovery_entry_state(inventory_id, int(token)) \
				if model != null else InventoryPresentationModel.STATE_DISCOVERY_UNKNOWN
		var entry_style := button.get_theme_stylebox(
				InventoryThemeFactory.state_stylebox_name(entry_state),
				InventoryThemeFactory.TYPE_DISCOVERY_ENTRY)
		if entry_style != null:
			button.add_theme_stylebox_override(&"normal", entry_style)


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and _background != null:
		_apply_theme()


func _snap(value: float) -> float:
	var unit := tokens.unit_effective() if tokens != null else 1.0
	return round(value / unit) * unit
