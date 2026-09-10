extends "res://ui/screens/raid/raid_screen.gd"

## Authored reload review screen controller.
##
## The plate and ring are authored in reload.tscn. This controller preserves
## raid.gd's live reload state and animation while binding the static ring and
## retaining the inherited compact layout.

func build() -> void:
	reset_adaptive_layout()
	_sync_mock_state()
	_ring_nodes.clear()
	_blink_nodes.clear()
	_fade_groups.clear()
	_crosshair = null
	_squad_countdown = null
	_reload_active = true
	if _reload_progress < 0.05:
		_reload_progress = 0.58

	var ring: Control = get_node("ReviewPlate/ReloadRing") as Control
	_ring_nodes.append(ring)
	ring.call("set_progress", _reload_progress)
	queue_adaptive_layout()
