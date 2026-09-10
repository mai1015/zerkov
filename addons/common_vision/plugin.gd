@tool
extends EditorPlugin

## Common Vision owns no autoload. Games explicitly create one world per
## session so dedicated servers and multi-world tests remain isolated.

const REQUIRED_CLASSES: PackedStringArray = [
	"CommonVisionVersion",
	"CommonVisionWorld2D",
]


func _enter_tree() -> void:
	for required_class in REQUIRED_CLASSES:
		if not ClassDB.class_exists(required_class):
			push_warning(
				"CommonVision: native class '%s' is unavailable. Build the "
				% required_class
				+ "matching GDExtension artifact; see release_manifest.json."
			)


func _get_plugin_name() -> String:
	return "CommonVision"
