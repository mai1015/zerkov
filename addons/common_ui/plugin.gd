@tool
extends EditorPlugin

## Installs the CommonUI autoload and refuses to enable without the native
## runtime.
##
## The addon has no script implementation of its authoritative services, so a
## missing or incompatible GDExtension artifact is reported as an error instead
## of silently selecting a behaviourally different backend.

const AUTOLOAD_NAME := "CommonUI"
const AUTOLOAD_SCENE := "res://addons/common_ui/runtime/common_ui_autoload.tscn"

## True only when this plugin instance was the one that added the autoload,
## i.e. the project had no prior "autoload/CommonUI" setting. A project may
## instead hand-declare the autoload directly in project.godot (as this
## repository does, so headless runs never depend on an editor pass) -- that
## declaration must survive disabling the plugin, not be stripped by it.
var _added_autoload := false


func _enter_tree() -> void:
	if not CommonUIBoot.is_native_runtime_available():
		push_error(CommonUIBoot.describe_missing_runtime())
		return
	if not ProjectSettings.has_setting("autoload/" + AUTOLOAD_NAME):
		add_autoload_singleton(AUTOLOAD_NAME, AUTOLOAD_SCENE)
		_added_autoload = true


func _exit_tree() -> void:
	if _added_autoload and ProjectSettings.has_setting("autoload/" + AUTOLOAD_NAME):
		remove_autoload_singleton(AUTOLOAD_NAME)
	_added_autoload = false


func _get_plugin_name() -> String:
	return "CommonUI"
