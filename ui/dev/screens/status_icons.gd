extends "res://ui/screens/raid/raid_screen.gd"

## Authored status-effects review screen controller.
##
## The plate, icon marks, labels, and notes are authored in status_icons.tscn.
## This controller only synchronizes inherited raid state and queues the
## existing responsive detail layout.

func build() -> void:
	reset_adaptive_layout()
	_sync_mock_state()
	_ring_nodes.clear()
	_blink_nodes.clear()
	_fade_groups.clear()
	_crosshair = null
	_squad_countdown = null
	queue_adaptive_layout()
