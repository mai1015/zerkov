extends SceneTree
## Stable exact-output entrypoint; the input driver never substitutes gameplay.
const EXACT_SIZE := Vector2i(1920, 1080)
const Driver = preload("res://tests/equipment/equipment_ui_driver.gd")
var _driver: RefCounted

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	# Native macOS applies the physical window size on the next display frame.
	root.borderless = true
	root.size = EXACT_SIZE
	await process_frame
	_driver = Driver.new()
	await _driver.run(self)
