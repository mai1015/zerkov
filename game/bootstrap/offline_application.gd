extends Node
## Normal product entry. Offline first; Steam/networking is not initialized here.
const UI = preload("res://ui/main.tscn")
var session: OfflineBunkerSession
var _ui: Control
var _provider: OfflineBunkerUI
var _character: OfflineCharacterRuntime

func _ready() -> void:
	session = OfflineBunkerSession.new()
	session.name = "OfflineBunkerSession"
	add_child(session)
	session.start()
	_character = OfflineCharacterRuntime.new()
	_character.name = "OfflineCharacterPresentation"
	add_child(_character)
	_provider = OfflineBunkerUI.new()
	_provider.name = "OfflineBunkerUI"
	add_child(_provider)
	_provider.bind_callbacks(session.status, _command)
	session.changed.connect(_on_session_changed)
	_ui = UI.instantiate()
	_ui.name = "Main"
	_ui.inject_character_runtime(_character)
	_ui.inject_presentation_provider(_provider)
	add_child(_ui)

func _command(operation: StringName, expected_generation: int, value: int) -> bool:
	if expected_generation != session.generation():
		return false
	match operation:
		&"create":
			if not session.open_profile(true):
				return false
			_character.attach(session)
			_apply_volume()
			return true
		&"continue":
			if not session.open_profile(false):
				return false
			_character.attach(session)
			_apply_volume()
			return true
		&"close":
			if session.status().busy:
				return false
			_character.release()
			return session.close_profile()
		&"volume":
			if not session.set_volume(value, expected_generation):
				return false
			_apply_volume()
			return true
		&"quit":
			if session.status().busy:
				return false
			get_tree().quit()
			return true
	return false

func _apply_volume() -> void:
	AudioServer.set_bus_volume_linear(0, float(session.status().master_volume) / 100.0)

func _on_session_changed() -> void:
	_provider.notify_local_changed()
