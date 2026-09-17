@tool
class_name ZNavigationChrome
extends Control

## Reusable responsive navigation header for the authored Zerkov utility screens.
##
## The geometry and presentation nodes live in navigation_chrome.tscn. This
## controller only keeps exported values reflected in that hierarchy and
## forwards CommonButton activations as semantic requests for the owning
## screen or flow controller.

signal navigate_requested(route: String)
signal insurance_requested
signal back_requested

const TEXT := Color("e6e8e3")
const MUTED := Color("8b918a")
const ACCENT := Color("e8962e")

const CHARACTER_ROUTES := ["inventory", "health", "stats", "character"]

@export var active_route: String = "inventory":
	set(value):
		active_route = value
		_refresh_state()

@export var level_text: String = "◆ LVL 14":
	set(value):
		level_text = value
		_refresh_state()

@export var money_text: String = "$ 125,000":
	set(value):
		money_text = value
		_refresh_state()

@export var task_count: int = 2:
	set(value):
		task_count = value
		_refresh_state()

@onready var _character_button: CommonButton = $Character
@onready var _maps_button: CommonButton = $Maps
@onready var _tasks_button: CommonButton = $Tasks
@onready var _insurance_button: CommonButton = $Insurance
@onready var _settings_button: CommonButton = $Settings
@onready var _close_button: CommonButton = $Close

@onready var _tasks_label: Label = $TasksLabel
@onready var _task_count_label: Label = $TaskBadge/Count
@onready var _level_label: Label = $Level
@onready var _money_label: Label = $Money

@onready var _character_underline: ColorRect = $CharacterUnderline
@onready var _maps_underline: ColorRect = $MapsUnderline
@onready var _tasks_underline: ColorRect = $TasksUnderline
@onready var _settings_underline: ColorRect = $SettingsUnderline


var _authored: Dictionary = {}
var _local_sections: bool = false
var _local_mode: String = ""
var _local_back: String = "BACK"
var _local_width: float = 1920.0
var _bunker_button: CommonButton
const SectionStyle = preload("res://ui/theme/local_journey_style.gd")
const SectionButton = preload("res://ui/components/controls/zerkov_button.tscn")

func _ready() -> void:
	for node in get_children():
		if node is Control: _authored[node.name] = Rect2(node.position, node.size)
	ZThemeAdapter.apply_controls(self)
	if Engine.is_editor_hint():
		_refresh_state()
		return
	_connect_button(_character_button, Callable(self, "_on_character_triggered"))
	_connect_button(_maps_button, Callable(self, "_on_maps_triggered"))
	_connect_button(_tasks_button, Callable(self, "_on_tasks_triggered"))
	_connect_button(_insurance_button, Callable(self, "_on_insurance_triggered"))
	_connect_button(_settings_button, Callable(self, "_on_settings_triggered"))
	_connect_button(_close_button, Callable(self, "_on_close_triggered"))
	# The owning ZScreen refines this metadata with the generation-scoped gate.
	# Keep a truthful default on the shared CommonUI control for the brief period
	# before its screen context binds, without disabling or bypassing navigation.
	if _insurance_button != null:
		_insurance_button.set_meta("z_feature_action", &"insurance")
		_insurance_button.set_meta("z_feature_status", &"locked")
		_insurance_button.set_meta("z_feature_status_label", "LOCKED")
		_insurance_button.tooltip_text = "LOCKED · Insurance · Unavailable until the owning service is connected."
	_refresh_state()


func _connect_button(button: CommonButton, callback: Callable) -> void:
	if button != null and not button.triggered.is_connected(callback):
		button.triggered.connect(callback)


func _on_character_triggered() -> void:
	navigate_requested.emit("inventory")


func _on_maps_triggered() -> void:
	navigate_requested.emit("maps")


func _on_tasks_triggered() -> void:
	navigate_requested.emit("tasks")


func _on_insurance_triggered() -> void:
	insurance_requested.emit()


func _on_settings_triggered() -> void:
	navigate_requested.emit("settings")


func _on_close_triggered() -> void:
	back_requested.emit()


func _refresh_state() -> void:
	if not is_node_ready():
		return

	if _local_sections:
		_refresh_local_sections()
		return

	_level_label.text = level_text
	_money_label.text = money_text
	_task_count_label.text = str(maxi(task_count, 0))

	_set_route_state(_character_button, _character_underline, "inventory")
	_set_route_state(_maps_button, _maps_underline, "maps")
	_set_route_state(_tasks_button, _tasks_underline, "tasks")
	_set_route_state(_settings_button, _settings_underline, "settings")
	_tasks_label.add_theme_color_override("font_color", _route_color("tasks"))


func _set_route_state(button: CommonButton, underline: ColorRect, route: String) -> void:
	var selected := _is_route_selected(route)
	var color := _route_color(route)
	if button != null:
		button.add_theme_color_override("font_color", color)
	if underline != null:
		underline.visible = selected
		underline.color = TEXT if selected else Color.TRANSPARENT


func _is_route_selected(route: String) -> bool:
	var current := active_route.to_lower()
	if route == "inventory":
		return current in CHARACTER_ROUTES
	return current == route


func _route_color(route: String) -> Color:
	return TEXT if _is_route_selected(route) else MUTED

func get_focus_targets() -> Array[Control]:
	if _local_sections:
		var targets: Array[Control] = []
		for control: Control in [_bunker_button, _character_button, _tasks_button, _maps_button, _settings_button, _close_button]:
			if control != null and control.visible and not (control as BaseButton).disabled: targets.append(control)
		return targets
	return [_character_button, _maps_button, _tasks_button, _insurance_button, _settings_button, _close_button]

func layout_for(view: Vector2) -> void:
	if not is_node_ready(): return
	if _local_sections:
		_local_width = view.x
		_refresh_local_sections()
		return
	var compact := view.x < 1920 or view.y < 1080
	custom_minimum_size.x = 0
	size = Vector2(view.x, 56)
	for node_name in _authored:
		var node: Control = get_node(NodePath(node_name))
		node.position = _authored[node_name].position
		node.size = _authored[node_name].size
	$Insurance.visible = not compact
	$TaskBadge.visible = not compact
	$Level.visible = not compact or view.x >= 1120
	$TasksLabel.text = "TASKS · %d" % task_count if compact else "TASKS"
	if compact:
		_rect("Logo", Rect2(20, 18, 88, 20))
		var x := 132.0
		for entry in [["Character", 120], ["Maps", 76], ["Tasks", 102], ["Settings", 108]]:
			_rect(entry[0], Rect2(x, 0, entry[1], 56))
			_rect(entry[0] + "Underline", Rect2(x, 54, entry[1], 1))
			if entry[0] == "Tasks": _rect("TasksLabel", Rect2(x, 0, entry[1], 56))
			x += entry[1] + 4
		_rect("Level", Rect2(view.x - 340, 14, 90, 28))
		_rect("Money", Rect2(view.x - 246, 14, 116, 28))
		_rect("Close", Rect2(view.x - 120, 12, 104, 32))
	_rect("Header", Rect2(0, 0, view.x, 56))
	_rect("HeaderRule", Rect2(0, 55, view.x, 1))
	_refresh_state()

func _rect(node_name: String, rect: Rect2) -> void:
	var node: Control = get_node(NodePath(node_name))
	node.position = rect.position
	node.size = rect.size


## Production-only top-level navigation. The same scene serves home, raid and
## menu contexts; detailed actions remain in each page. No gameplay ownership.
func configure_local_sections(mode: String, route: String, back: String) -> void:
	if not is_node_ready(): return
	_local_sections = true
	_local_mode = mode
	_local_back = back
	if _bunker_button == null:
		_bunker_button = SectionButton.instantiate() as CommonButton
		_bunker_button.name = "Bunker"
		_bunker_button.show_glyph = false
		_bunker_button.text = "BUNKER"
		add_child(_bunker_button)
		_bunker_button.triggered.connect(func():
			if _local_mode == "home": navigate_requested.emit("bunker"))
	active_route = route

func _refresh_local_sections() -> void:
	if _bunker_button == null: return
	custom_minimum_size.x = 0
	size = Vector2(_local_width, 56)
	_rect("Header", Rect2(0, 0, _local_width, 56))
	$Header.add_theme_stylebox_override("panel", SectionStyle.panel(SectionStyle.BG, Color.TRANSPARENT))
	_rect("HeaderRule", Rect2(48, 55, maxf(_local_width - 96, 0), 1))
	$HeaderRule.color = SectionStyle.LINE
	_rect("Logo", Rect2(48, 16, 112, 24))
	# Never restore fixture insurance/currency/level chrome in a local reflow.
	for name: String in ["Insurance", "Money", "TasksLabel", "TaskBadge", "CharacterUnderline", "MapsUnderline", "TasksUnderline", "SettingsUnderline"]:
		(get_node(name) as CanvasItem).hide()
	_insurance_button.disabled = true
	_bunker_button.visible = _local_mode == "home"
	var live := _local_mode in ["home", "raid"]
	_character_button.visible = live
	_tasks_button.visible = live
	_maps_button.visible = live
	_character_button.text = "CHARACTER"
	_tasks_button.text = "TASKS"
	_maps_button.text = "MAP" if _local_mode == "raid" else "BRIEFING"
	_settings_button.text = "SETTINGS"
	var section := active_route
	if section in CHARACTER_ROUTES: section = "inventory"
	elif section in ["crafting", "build_mode", "session"]: section = "bunker"
	elif section == "controls": section = "settings"
	var x := 220.0
	var visible_buttons: Array[Control] = []
	for entry: Array in [[_bunker_button, "bunker", 132.0], [_character_button, "inventory", 166.0],
		[_tasks_button, "tasks", 126.0], [_maps_button, "maps", 154.0], [_settings_button, "settings", 148.0]]:
		var button := entry[0] as CommonButton
		if not button.visible: continue
		button.position = Vector2(x, 0)
		button.size = Vector2(entry[2], 56)
		button.disabled = false
		SectionStyle.section_button(button, section == entry[1])
		visible_buttons.append(button)
		x += float(entry[2]) + 12.0
	_level_label.text = "IN RAID / SOLO" if _local_mode == "raid" else ("BUNKER / LOCAL" if _local_mode == "home" else "LOCAL GAME")
	_level_label.add_theme_font_override("font", SectionStyle.MONO)
	_level_label.add_theme_font_size_override("font_size", 12)
	_level_label.add_theme_color_override("font_color", SectionStyle.MUTED)
	_level_label.visible = _local_width >= 1600
	_rect("Level", Rect2(_local_width - 480, 14, 230, 28))
	_rect("Close", Rect2(_local_width - 248, 12, 200, 32))
	_close_button.text = "ESC / " + _local_back
	SectionStyle.button(_close_button)
	visible_buttons.append(_close_button)
	# Deliberate tab traversal, while each page keeps its own vertical graph.
	for index in range(visible_buttons.size()):
		var button := visible_buttons[index]
		var previous := visible_buttons[(index - 1 + visible_buttons.size()) % visible_buttons.size()]
		var next := visible_buttons[(index + 1) % visible_buttons.size()]
		button.focus_neighbor_left = button.get_path_to(previous)
		button.focus_neighbor_right = button.get_path_to(next)
