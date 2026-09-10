@tool
extends EditorPlugin


func _enter_tree() -> void:
	if not ClassDB.class_exists(&"WeaponSystemVersion"):
		push_error(
			"Weapon System 0.1.0 requires its matching native Godot 4.7 "
			+ "GDExtension artifact. Core-only builds do not register editor classes."
		)


func _exit_tree() -> void:
	pass
