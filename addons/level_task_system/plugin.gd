@tool
extends EditorPlugin

## Editor entry point for the Level Task System addon.
##
## The package deliberately installs no autoload.  Level/task ownership is
## supplied by the host game so multiple local sessions and dedicated-server
## tests can coexist in one process.  The main-screen workspace is a projection
## over the document model and degrades to a read-only native diagnostic.

const REQUIRED_CLASSES: PackedStringArray = [
	"LevelTaskSystemVersion",
	"LevelTaskLevelDefinition",
	"LevelTaskGraphDefinition",
	"LevelTaskConversationDefinition",
]

const Workspace := preload("res://addons/level_task_system/editor/workspace/lts_workspace.gd")

var _workspace: LtsWorkspace
var _native_extension_available := true


func _enter_tree() -> void:
	_native_extension_available = true
	for class_name_to_check in REQUIRED_CLASSES:
		if not ClassDB.class_exists(class_name_to_check):
			_native_extension_available = false
			push_warning(
				"LevelTaskSystem: native class '%s' is not registered. Build the addon's "
				% class_name_to_check
				+ "GDExtension for this platform (see addons/level_task_system/release_manifest.json)."
			)
	_workspace = Workspace.new()
	_workspace.name = "LevelTaskSystemWorkspace"
	_workspace.set_native_extension_available(_native_extension_available)
	_workspace.undo_redo = get_undo_redo()
	get_editor_interface().get_editor_main_screen().add_child(_workspace)
	_workspace.hide()


func _exit_tree() -> void:
	if _workspace != null:
		_workspace.queue_free()
		_workspace = null


func _has_main_screen() -> bool:
	return true


func _make_visible(visible: bool) -> void:
	if _workspace == null:
		return
	_workspace.visible = visible
	if visible:
		_workspace.call_deferred("grab_focus")


func _handles(object: Object) -> bool:
	if object == null:
		return false
	return not Workspace.supported_resource_kind(object).is_empty()


func _edit(object: Object) -> void:
	if _workspace == null or object == null:
		return
	var source_path := String(object.resource_path) if object is Resource else ""
	if _workspace.open_resource(object, source_path):
		_make_visible(true)


func _get_plugin_icon() -> Texture2D:
	if not Engine.is_editor_hint():
		return null
	var theme := get_editor_interface().get_editor_theme()
	if theme == null:
		return null
	for icon_name in [&"Graph", &"Node", &"Scene"]:
		if theme.has_icon(icon_name, &"EditorIcons"):
			return theme.get_icon(icon_name, &"EditorIcons")
	return null


func _get_plugin_name() -> String:
	return "Level Task System"
