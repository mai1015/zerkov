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
	return [_character_button, _maps_button, _tasks_button, _insurance_button, _settings_button, _close_button]

func layout_for(view: Vector2) -> void:
	if not is_node_ready(): return
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
