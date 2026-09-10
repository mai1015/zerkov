@tool
class_name LtsDrawer
extends PanelContainer

## Bottom drawer fixture with native TabBar navigation and bounded content.
## The drawer is read-only in this showcase; product document commands remain
## outside the visual component.

signal tab_changed(tab_index: int)

const LtsComponentState := preload("res://addons/level_task_system/editor/components/lts_component_state.gd")
const LtsComponentTheme := preload("res://addons/level_task_system/editor/components/lts_component_theme.gd")

var _state: StringName = LtsComponentState.DEFAULT
var _tab_bar: TabBar
var _content_label: Label
var _built := false


func _init() -> void:
	theme_type_variation = &"LevelTaskDrawer"
	focus_mode = Control.FOCUS_ALL


func _ready() -> void:
	_built = true
	_build()


func setup(state: Variant = LtsComponentState.DEFAULT) -> LtsDrawer:
	_state = LtsComponentState.normalize(state)
	_build()
	return self


func set_state(value: Variant) -> void:
	_state = LtsComponentState.normalize(value)
	_apply_state()


func get_state() -> StringName:
	return _state


func _build() -> void:
	if not _built and not is_inside_tree():
		return
	if _tab_bar != null:
		return
	var column := VBoxContainer.new()
	column.name = "DrawerColumn"
	add_child(column)
	_tab_bar = TabBar.new()
	_tab_bar.name = "DrawerTabs"
	_tab_bar.focus_mode = Control.FOCUS_ALL
	_tab_bar.add_tab("Findings")
	_tab_bar.add_tab("Simulation")
	_tab_bar.add_tab("Trace")
	_tab_bar.tab_changed.connect(_on_tab_changed)
	column.add_child(_tab_bar)
	_content_label = Label.new()
	_content_label.name = "DrawerContent"
	_content_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_content_label.custom_minimum_size = Vector2(0, 48)
	column.add_child(_content_label)
	_apply_state()


func _on_tab_changed(index: int) -> void:
	tab_changed.emit(index)
	_apply_state()


func _apply_state() -> void:
	if _content_label == null:
		return
	var normalized := LtsComponentState.normalize(_state)
	var tab_name := "Findings"
	if _tab_bar.current_tab >= 0 and _tab_bar.current_tab < _tab_bar.tab_count:
		tab_name = _tab_bar.get_tab_title(_tab_bar.current_tab)
	match normalized:
		LtsComponentState.DEFAULT:
			_content_label.text = "%s drawer content: 2 findings" % tab_name
		LtsComponentState.HOVER:
			_content_label.text = "%s tab preview (hover)" % tab_name
		LtsComponentState.ACTIVE:
			_content_label.text = "%s tab active: selected trace is visible" % tab_name
		LtsComponentState.FOCUS:
			_content_label.text = "%s tab keyboard focus" % tab_name
		LtsComponentState.DISABLED:
			_content_label.text = "Drawer unavailable: native extension is read-only"
		LtsComponentState.LOADING:
			_content_label.text = "%s: Loading trace..." % tab_name
		LtsComponentState.EMPTY:
			_content_label.text = "%s: No runtime activity" % tab_name
		LtsComponentState.ERROR:
			_content_label.text = "%s: Error LTS-DRAWER-001" % tab_name
	_content_label.tooltip_text = _content_label.text
	_tab_bar.tooltip_text = "Findings, simulator controls, and read-only trace"
	var tabs_blocked := normalized == LtsComponentState.DISABLED or normalized == LtsComponentState.LOADING
	_tab_bar.focus_mode = Control.FOCUS_NONE if tabs_blocked else Control.FOCUS_ALL
	_tab_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE if tabs_blocked else Control.MOUSE_FILTER_STOP
	LtsComponentTheme.preview_style(self, normalized, &"panel", &"PanelContainer")
