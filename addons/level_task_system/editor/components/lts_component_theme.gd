extends RefCounted

## Theme and icon helpers shared by the editor primitives.
##
## No visual token is authored here. Every lookup deliberately walks the
## control's inherited theme. In the actual editor the showcase root adopts
## EditorInterface.get_editor_theme(); in a headless/runtime process the
## normal project fallback chain remains intact.

const EDITOR_ICONS: StringName = &"EditorIcons"
const TYPE_EDITOR: StringName = &"Editor"
const TYPE_LABEL: StringName = &"Label"
const TYPE_BUTTON: StringName = &"Button"
const TYPE_LINE_EDIT: StringName = &"LineEdit"
const TYPE_PANEL: StringName = &"PanelContainer"
const TYPE_GRAPH_EDIT: StringName = &"GraphEdit"
const TYPE_GRAPH_NODE: StringName = &"GraphNode"
const ComponentState := preload("res://addons/level_task_system/editor/components/lts_component_state.gd")


static func inherit_editor_theme(control: Control) -> void:
	if control == null or not Engine.is_editor_hint():
		return
	var editor_theme := EditorInterface.get_editor_theme()
	if editor_theme != null:
		control.theme = editor_theme


static func resolve_icon(control: Control, preferred: Array, fallback: StringName = &"Node") -> Texture2D:
	if control == null:
		return null
	for icon_name in preferred:
		if control.has_theme_icon(icon_name, EDITOR_ICONS):
			return control.get_theme_icon(icon_name, EDITOR_ICONS)
	if control.has_theme_icon(fallback, EDITOR_ICONS):
		return control.get_theme_icon(fallback, EDITOR_ICONS)
	return null


static func state_icon(control: Control, state: Variant) -> Texture2D:
	var preferred: Array = [ComponentState.icon_name(state)]
	match ComponentState.normalize(state):
		ComponentState.ERROR:
			preferred.append(&"Warning")
			preferred.append(&"StatusError")
		ComponentState.DISABLED:
			preferred.append(&"Lock")
		ComponentState.LOADING:
			preferred.append(&"Progress1")
			preferred.append(&"Reload")
		ComponentState.EMPTY:
			preferred.append(&"Folder")
			preferred.append(&"File")
		ComponentState.ACTIVE:
			preferred.append(&"Check")
			preferred.append(&"StatusSuccess")
		_:
			preferred.append(&"Node")
			preferred.append(&"File")
	return resolve_icon(control, preferred, &"Node")


static func semantic_color(control: Control, semantic_name: StringName, fallback_name: StringName = &"font_color", fallback_type: StringName = TYPE_LABEL) -> Color:
	if control == null:
		return Color()
	if control.has_theme_color(semantic_name, TYPE_EDITOR):
		return control.get_theme_color(semantic_name, TYPE_EDITOR)
	if control.has_theme_color(fallback_name, fallback_type):
		return control.get_theme_color(fallback_name, fallback_type)
	return control.get_theme_color(&"font_color")


static func state_color(control: Control, state: Variant) -> Color:
	match ComponentState.normalize(state):
		ComponentState.ERROR:
			return semantic_color(control, &"error_color")
		ComponentState.EMPTY:
			return semantic_color(control, &"font_color_secondary")
		ComponentState.LOADING:
			return semantic_color(control, &"accent_color")
		ComponentState.ACTIVE, ComponentState.FOCUS:
			return semantic_color(control, &"accent_color")
		ComponentState.DISABLED:
			if control.has_theme_color(&"font_disabled_color", TYPE_BUTTON):
				return control.get_theme_color(&"font_disabled_color", TYPE_BUTTON)
			return semantic_color(control, &"font_color_disabled")
		_:
			return control.get_theme_color(&"font_color")


static func apply_state_text(label: Label, state: Variant, text: String) -> void:
	if label == null:
		return
	label.text = text
	label.tooltip_text = text
	label.remove_theme_color_override(&"font_color")
	var normalized := ComponentState.normalize(state)
	if normalized == ComponentState.ERROR \
			or normalized == ComponentState.EMPTY \
			or normalized == ComponentState.LOADING \
			or normalized == ComponentState.ACTIVE \
			or normalized == ComponentState.FOCUS:
		label.add_theme_color_override(&"font_color", state_color(label, normalized))


static func style_candidates(state: Variant) -> Array[StringName]:
	match ComponentState.normalize(state):
		ComponentState.HOVER:
			return [&"hover", &"normal"]
		ComponentState.ACTIVE:
			return [&"pressed", &"selected", &"panel_selected", &"focus", &"normal"]
		ComponentState.FOCUS:
			return [&"focus", &"panel_focus", &"normal"]
		ComponentState.DISABLED:
			return [&"disabled", &"read_only", &"normal"]
		_:
			return [&"normal", &"panel"]


static func preview_style(control: Control, state: Variant, target_item: StringName = &"normal", type_name: StringName = &"") -> void:
	## Showcase cells are static samples, so an explicit state needs to be
	## visible without requiring a pointer to hover every cell. The style is
	## still the native state StyleBox resolved from the inherited theme.
	if control == null:
		return
	for item_name in style_candidates(state):
		var available := control.has_theme_stylebox(item_name, type_name)
		if not available:
			available = control.has_theme_stylebox(item_name)
		if not available:
			continue
		var stylebox: StyleBox = control.get_theme_stylebox(item_name, type_name) if not type_name.is_empty() else control.get_theme_stylebox(item_name)
		if stylebox != null:
			control.add_theme_stylebox_override(target_item, stylebox)
		return


static func clear_preview_style(control: Control, target_item: StringName) -> void:
	if control != null:
		control.remove_theme_stylebox_override(target_item)


static func theme_separation(control: Control, type_name: StringName = &"VBoxContainer") -> int:
	if control == null:
		return 0
	return control.get_theme_constant(&"separation", type_name)


static func graph_port_color(control: Control) -> Color:
	if control == null:
		return Color()
	if control.has_theme_color(&"port_color", TYPE_GRAPH_NODE):
		return control.get_theme_color(&"port_color", TYPE_GRAPH_NODE)
	if control.has_theme_color(&"activity", TYPE_GRAPH_EDIT):
		return control.get_theme_color(&"activity", TYPE_GRAPH_EDIT)
	return semantic_color(control, &"accent_color")
