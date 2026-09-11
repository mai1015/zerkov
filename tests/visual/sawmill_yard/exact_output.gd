extends RefCounted
## Argument-only guard. Negative cases never open or resize a screen.

const EXACT_SIZE := Vector2i(1920, 1080)
const WORLD_SIZE := Vector2i(640, 360)
const WORLD_SCALE: int = 3


static func accepts_arguments(arguments: PackedStringArray) -> bool:
	var resolution_count := 0
	for index in arguments.size():
		var argument := arguments[index]
		if argument == "--resolution":
			resolution_count += 1
			if index + 1 >= arguments.size() or arguments[index + 1] != "1920x1080":
				return false
		elif argument.begins_with("--resolution="):
			return false
	return resolution_count == 1


static func accepts_window(window: Window) -> bool:
	# Godot removes --resolution from OS.get_cmdline_args(). The external
	# runner validates its command before launch; in-engine validation reads
	# the resulting native Window and every captured framebuffer instead.
	return window.size == EXACT_SIZE


static func overrides_are_exact(arguments: PackedStringArray) -> bool:
	for argument in arguments:
		if argument.begins_with("--resolution"):
			return accepts_arguments(arguments)
	return true
