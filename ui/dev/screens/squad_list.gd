extends "res://ui/screens/raid/raid_screen.gd"

## Authored squad-list review screen controller.
##
## The review plate, rows, bars, and speaker mark are authored in
## squad_list.tscn. This controller only synchronizes inherited raid state and
## queues the existing responsive detail layout.

func build() -> void:
	reset_adaptive_layout()
	_sync_mock_state()
	_ring_nodes.clear()
	_blink_nodes.clear()
	_fade_groups.clear()
	_crosshair = null
	_squad_countdown = null
	queue_adaptive_layout()
