class_name LocalUIHost
extends "res://ui/main.gd"
## Production composition supplies the existing host's provider and Character
## runtime. The additional port contains values and commands, not game owners.
var _local_game_port: LocalGameUI
func inject_local_game_ui(port: LocalGameUI) -> bool:
	if is_inside_tree() or _local_game_port != null or port == null or port.snapshot().is_empty(): return false
	_local_game_port = port
	return true
func local_game_ui() -> LocalGameUI:
	return null if qa_mode or prototype_fixture_mode else _local_game_port
func _refresh_unbound_production_screen() -> void:
	# Local screen bindings update in place after one complete frame publication.
	if _local_game_port == null: super._refresh_unbound_production_screen()
