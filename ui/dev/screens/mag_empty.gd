extends "res://ui/screens/raid/raid_screen.gd"

## Authored magazine-empty review screen controller.
##
## The review plate and prompt are authored in mag_empty.tscn. This controller
## keeps raid state and inherited blinking behavior bound to those nodes while
## retaining the inherited compact layout.

func build() -> void:
	reset_adaptive_layout()
	_sync_mock_state()
	_ring_nodes.clear()
	_blink_nodes.clear()
	_fade_groups.clear()
	_crosshair = null
	_squad_countdown = null
	_blink_nodes.append(get_node("ReviewPlate/ReloadPrompt") as Control)
	queue_adaptive_layout()
