extends "res://ui/screens/bunker/bunker.gd"
## Retain the existing CommonActivatableScreen lifecycle and navigation owner.
## Replace only the desktop bunker presentation; other bunker-family routes
## and their feature gates remain unchanged. No fixture mutation is introduced.
const HIDEOUT = preload("res://game/presentation/bunker/bunker_hideout_view.tscn")

func build() -> void:
	super.build()
	for child: Node in get_children():
		if child is CanvasItem:
			child.visible = false
	var view := get_node_or_null("BunkerHideoutView")
	if view == null:
		view = HIDEOUT.instantiate()
		add_child(view)
		view.menu_requested.connect(_on_menu)
	view.visible = true

## The production map has its own fit policy; generic bunker reflow must not
## restore the retired NavigationChrome/station hierarchy over it.
func _apply_adaptive_layout() -> void:
	if _local_binding != null and _local_binding.layout_home(get_viewport_rect().size):
		_adaptive_queued = false
		_adaptive_applied = true
		return
	super._apply_adaptive_layout()
