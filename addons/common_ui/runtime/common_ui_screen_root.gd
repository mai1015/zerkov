@tool
class_name CommonUIScreenRoot
extends Control

## Default UI layers a consumer project can drop in and start using.
##
## Before this scene existed only the reference example created layers, so a new
## project began with none. Instancing [code]common_ui_screen_root.tscn[/code]
## (or this node) gives a project the four standard [CommonUILayer]s -- hud,
## menu, modal, and popup -- plus an [ActionBar], and installs the default input
## configuration when the runtime has none. A game may add its own layers
## alongside these or replace the scene entirely.

const CommonDialogScene := preload("res://addons/common_ui/controls/common_dialog.tscn")

## Layers created on ready, lowest priority first. Ordered so higher-priority
## layers are added later and therefore draw on top.
const _LAYERS := [
	[CommonUIDefaults.LAYER_HUD, CommonUIDefaults.PRIORITY_HUD],
	[CommonUIDefaults.LAYER_MENU, CommonUIDefaults.PRIORITY_MENU],
	[CommonUIDefaults.LAYER_MODAL, CommonUIDefaults.PRIORITY_MODAL],
	[CommonUIDefaults.LAYER_POPUP, CommonUIDefaults.PRIORITY_POPUP],
]

## Installs [method CommonUIDefaults.build_default_config] when the runtime has
## no input configuration yet. Turn off when the project supplies its own.
@export var install_default_config: bool = true
## Adds a shared [ActionBar] across the bottom of the screen.
@export var show_action_bar: bool = true

var action_bar: ActionBar
var _layers: Dictionary = {}


func _get_runtime() -> CommonUIRuntime:
	if Engine.is_editor_hint() or not is_inside_tree():
		return null
	return get_node_or_null(^"/root/CommonUI") as CommonUIRuntime


func _init() -> void:
	if name.is_empty():
		name = "CommonUIScreenRoot"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	# The root itself must not eat pointer input meant for the screens inside it.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	for entry in _LAYERS:
		_add_layer(entry[0], entry[1])


func _add_layer(id: StringName, priority: int) -> void:
	var layer := CommonUILayer.new()
	layer.name = String(id).capitalize() + "Layer"
	layer.layer_id = id
	layer.layer_priority = priority
	layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(layer)
	_layers[id] = layer


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	# Every CommonUILayer already makes itself pause-immune (see
	# CommonUILayer.pause_immune), but this covers the root's other direct
	# children -- the ActionBar -- which default to PROCESS_MODE_INHERIT and
	# would otherwise freeze along with the rest of the paused game even though
	# the layers above them keep animating and routing input.
	process_mode = Node.PROCESS_MODE_ALWAYS
	var runtime := _get_runtime()
	if runtime == null:
		push_error("CommonUIScreenRoot requires the CommonUI autoload.")
		return
	if install_default_config and runtime.get_input_config() == null:
		runtime.set_input_config(CommonUIDefaults.build_default_config())

	if show_action_bar and action_bar == null:
		action_bar = ActionBar.new()
		action_bar.name = "ActionBar"
		action_bar.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
		add_child(action_bar)


# --- Layer access ----------------------------------------------------------

## The layer registered under [param id], or null. Use the
## [code]CommonUIDefaults.LAYER_*[/code] constants.
func layer(id: StringName) -> CommonUILayer:
	return _layers.get(id, null)


func hud_layer() -> CommonUILayer:
	return layer(CommonUIDefaults.LAYER_HUD)


func menu_layer() -> CommonUILayer:
	return layer(CommonUIDefaults.LAYER_MENU)


func modal_layer() -> CommonUILayer:
	return layer(CommonUIDefaults.LAYER_MODAL)


func popup_layer() -> CommonUILayer:
	return layer(CommonUIDefaults.LAYER_POPUP)


# --- Convenience transactions ----------------------------------------------

## Pushes any screen onto a named layer. Awaits the stack transaction and returns
## its result dictionary.
func push_to(layer_id: StringName, source: Variant, options: Dictionary = {}) -> Dictionary:
	var target := layer(layer_id)
	if target == null:
		return {"status": CommonUIStackRequest.Status.ERROR,
			"error": "No layer '%s'." % layer_id}
	return await target.push_screen(source, options)


## Opens a [CommonDialog] on the modal layer, suspending every context beneath
## it. Returns the dialog so the caller can await its [signal CommonDialog.confirmed]
## or [signal CommonDialog.dismissed]; the dialog closes itself on either.
func open_dialog(p_title: String, p_message: String, p_confirm := "OK",
		p_cancel := "Cancel", p_show_cancel := true) -> CommonDialog:
	var dialog: CommonDialog = CommonDialogScene.instantiate()
	dialog.configure(p_title, p_message, p_confirm, p_cancel, p_show_cancel)
	# Collected before the push so the dialog suspends them on activation.
	dialog.set_lower_contexts(_active_lower_contexts())
	var modal := modal_layer()
	dialog.confirmed.connect(func() -> void: modal.pop_screen(), CONNECT_ONE_SHOT)
	dialog.dismissed.connect(func() -> void: modal.pop_screen(), CONNECT_ONE_SHOT)
	await modal.push_screen(dialog)
	return dialog


## Context handles opened by the routing-active screens in the hud and menu
## layers, i.e. everything a modal should suspend while it is open.
func _active_lower_contexts() -> Array[CommonUIContextHandle]:
	var handles: Array[CommonUIContextHandle] = []
	for layer_id in [CommonUIDefaults.LAYER_HUD, CommonUIDefaults.LAYER_MENU]:
		var target := layer(layer_id)
		if target == null:
			continue
		var screen := target.get_top_screen()
		if screen == null or not screen.is_routing_active():
			continue
		var handle := screen.get_context_handle()
		if handle != null and handle.is_active():
			handles.append(handle)
	return handles
