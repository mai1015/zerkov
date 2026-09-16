class_name OfflineBunkerUI
extends ZUIPresentationProvider
## Narrow UI capability: immutable status + declared user intents. The root's
## callback owns all profile/native work. No filesystem path or authority escapes.
signal local_changed
var _status_reader: Callable
var _command_sink: Callable

func bind_callbacks(reader: Callable, sink: Callable) -> bool:
	if is_initialized() or not reader.is_valid() or not sink.is_valid():
		return false
	_status_reader = reader
	_command_sink = sink
	return start_unavailable(1, &"pre_raid_only")

func local_status() -> Dictionary:
	return _status_reader.call() if is_active() and _status_reader.is_valid() else {"open": false, "disk_status": "blocked", "error": "session_closed"}

func request(operation: StringName, expected_generation: int, value: int = 0) -> bool:
	if not is_active() or not _command_sink.is_valid():
		return false
	return bool(_command_sink.call(operation, expected_generation, value))

func route_available(route: String) -> bool:
	if not is_active():
		return false
	if route in ["main_menu", "settings", "pause"]:
		return true
	return route == "bunker" and bool(local_status().open)

func notify_local_changed() -> void:
	local_changed.emit()
