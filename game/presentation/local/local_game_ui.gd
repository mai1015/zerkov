class_name LocalGameUI
extends Node
## UI-facing intent/value port. Never contains a profile, actor, inventory,
## authority, or file handle. The root alone consumes requested commands.
signal changed
signal requested(command: StringName, epoch: int)
var _frame: Dictionary = {}
var _epoch: int = 0
var _serial: int = 0
var _dispatching: bool = false
var _released: bool = false
const COMMANDS: Array[StringName] = [&"create", &"continue", &"loadout", &"maps", &"tasks", &"deploy", &"resume", &"pause", &"interact", &"cancel", &"return_home", &"retry_save", &"quit", &"health", &"controls", &"abandon"]
const ROUTE_COMMANDS: Dictionary = {"bunker":&"return_home", "inventory":&"loadout", "health":&"health",
	"maps":&"maps", "tasks":&"tasks", "hud":&"resume", "pause":&"pause", "settings":&"controls", "controls":&"controls"}

func publish(frame: Dictionary) -> bool:
	if _released or typeof(frame.get("epoch")) != TYPE_INT or int(frame.epoch) < _epoch \
		or typeof(frame.get("serial")) != TYPE_INT or int(frame.serial) <= _serial \
		or typeof(frame.get("mode")) != TYPE_STRING:
		return false
	_epoch = frame.epoch
	_serial = frame.serial
	_frame = RaidProgressionValues.freeze(frame)
	changed.emit()
	return true

func snapshot() -> Dictionary:
	return _frame

func request(command: StringName, epoch: int) -> bool:
	if _released or _dispatching or epoch != _epoch or not COMMANDS.has(command) or _frame.is_empty(): return false
	_dispatching = true
	requested.emit(command, epoch)
	_dispatching = false
	return true

func release() -> void:
	_released = true
	_frame = {}
	changed.emit()


static func route_command(route: String) -> StringName:
	return ROUTE_COMMANDS.get(route, &"")
