class_name ZAdaptive
extends RefCounted

const KIT = preload("res://ui/theme/tokens.gd")

## Readable native-pixel workspaces. The content retains its intrinsic size;
## only the enclosing viewport shrinks, so a short window scrolls, not squashes.
static func pane(host: Control, bounds: Rect2, content_size: Vector2, pane_name: String = "") -> Control:
	var scroll = ScrollContainer.new()
	scroll.name = pane_name if not pane_name.is_empty() else "AdaptivePane"
	scroll.position = bounds.position
	scroll.size = bounds.size
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.follow_focus = true
	scroll.mouse_filter = Control.MOUSE_FILTER_STOP
	scroll.clip_contents = true
	scroll.set_meta("adaptive_pane", true)
	host.add_child(scroll)
	var content = Control.new()
	content.name = "Content"
	content.custom_minimum_size = content_size
	content.size = content_size
	content.mouse_filter = Control.MOUSE_FILTER_PASS
	scroll.add_child(content)
	for scrollbar in [scroll.get_v_scroll_bar(), scroll.get_h_scroll_bar()]:
		for item in [["scroll", Color(1, 1, 1, 0.04)], ["grabber", KIT.MUTED], ["grabber_highlight", KIT.ACCENT], ["grabber_pressed", KIT.HOVER]]:
			var style = StyleBoxFlat.new()
			style.bg_color = item[1]
			# StyleBox margins determine a scrollbar's minimum cross-axis width.
			style.content_margin_left = 4
			style.content_margin_right = 4
			style.content_margin_top = 4
			style.content_margin_bottom = 4
			scrollbar.add_theme_stylebox_override(item[0], style)
	return content

static func move_nodes(nodes: Array, content: Control, offset: Vector2) -> void:
	for node in nodes:
		if not is_instance_valid(node) or not node is Control or node == content:
			continue
		var origin: Vector2 = node.position
		var original_size: Vector2 = node.size
		node.reparent(content, false)
		node.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
		node.position = origin - offset
		node.size = original_size

## Authored membership replaces geometry-based discovery for feature panes.
static func move_group(source: Control, group: String, origin: Vector2, content: Control) -> Array:
	var nodes: Array = []
	for node in source.get_children():
		if node is Control and str(node.get_meta("compact_group", "")) == group:
			nodes.append(node)
	move_nodes(nodes, content, origin)
	return nodes

static func backdrop(screen: Control, view: Vector2) -> void:
	for node in screen.get_children():
		if node is Control and (node.get_meta("z_backdrop", false) or (node.position.is_equal_approx(Vector2.ZERO) and node.size.x >= 1919 and node.size.y >= 1079)):
			node.size = view
			node.mouse_filter = Control.MOUSE_FILTER_IGNORE
