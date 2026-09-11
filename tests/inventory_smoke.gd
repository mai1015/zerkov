extends SceneTree
## Scoped inventory regression test.
## Run with: godot --headless --path . --script res://tests/inventory_smoke.gd

var failures: int = 0
var checks: int = 0
var app: Control


func _initialize() -> void:
	call_deferred("run")


func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("INVENTORY_TEST: " + message)


func settle() -> void:
	await process_frame
	await process_frame


func _contains_id(values: Array, item_id: String) -> bool:
	for value in values:
		if value is Dictionary and str((value as Dictionary).get("id", "")) == item_id:
			return true
	return false


func run() -> void:
	root.size = Vector2i(1920, 1080)
	app = load("res://ui/main.tscn").instantiate()
	# Historical authored-interaction regression. Production Character routes
	# now receive immutable runtime views; this suite intentionally exercises the
	# clearly gated local preview provider.
	app.prototype_fixture_mode = true
	root.add_child(app)
	await settle()

	app.navigate("inventory", false)
	await settle()
	var screen: Control = app.screen
	check(app.current_route == "inventory", "gear route opens")
	check(screen._grids.size() == 4, "gear route owns pockets, rig, backpack and stash grids")
	for grid in screen._grids:
		check(grid.get_cell_size() == 74, "inventory grid keeps 74px cells")

	var stash_grid: Control = screen._grid_for_source("stash")
	var pack_grid: Control = screen._grid_for_source("backpack")
	check(stash_grid != null and pack_grid != null, "stash and backpack grids are addressable")
	var ammo: Dictionary = screen._items_for("stash")[11]
	var shotgun: Dictionary = screen._items_for("stash")[17]
	screen._set_compatibility("7.62x39")
	check(stash_grid._modulate_for_item(ammo).a > 0.9, "compatible ammo stays bright")
	check(stash_grid._modulate_for_item(shotgun).a < 0.5, "mismatched weapon/ammo dims")

	var selected: Dictionary = screen._items_for("stash")[0]
	screen._on_grid_selected(selected, "stash")
	check(is_instance_valid(screen._tooltip), "item selection opens tooltip")
	screen._close_tip()

	# Ctrl-click semantics: the screen callback uses the selected loadout
	# destination and persists the transfer into app.state.
	var quick_item: Dictionary = screen._items_for("stash")[0]
	stash_grid._slot_quick_move(quick_item)
	await settle()
	check(not _contains_id(screen._items_for("stash"), str(quick_item.get("id"))), "quick move removes source item")
	check(_contains_id(screen._items_for("backpack"), str(quick_item.get("id"))), "quick move adds target item")

	# Drag/drop bounds and occupancy are enforced by the native grid before
	# the screen mutates its local arrays.
	stash_grid = screen._grid_for_source("stash")
	pack_grid = screen._grid_for_source("backpack")
	var drag_item: Dictionary = screen._items_for("stash")[0]
	var payload: Dictionary = {
		"type": "inventory_item",
		"item": drag_item.duplicate(true),
		"source": "stash",
		"item_id": str(drag_item.get("id", "")),
	}
	pack_grid._drop_data(Vector2(-4, -4), payload)
	await settle()
	check(_contains_id(screen._items_for("stash"), str(drag_item.get("id"))), "out-of-bounds drop is rejected")
	var destination: Vector2i = pack_grid.find_first_fit(drag_item)
	check(destination.x >= 0, "target grid reports an available fit")
	pack_grid._drop_data(Vector2(destination.x * 74 + 4, destination.y * 74 + 4), payload)
	await settle()
	check(not _contains_id(screen._items_for("stash"), str(drag_item.get("id"))), "valid drag removes source item")
	check(_contains_id(screen._items_for("backpack"), str(drag_item.get("id"))), "valid drag adds target item")

	screen._swap_container("rig")
	await settle()
	check(screen._inventory_data().get("rig_size") == [5, 3], "rig swap resizes to 5x3")
	screen._swap_container("backpack")
	await settle()
	check(screen._inventory_data().get("backpack_size") == [7, 6], "backpack swap resizes to 7x6")

	app.navigate("health", false)
	await settle()
	var health: Control = app.screen
	var before_meds: int = int(app.state.get("med_count", 2))
	var heal_key := InputEventKey.new()
	heal_key.keycode = KEY_Y
	heal_key.physical_keycode = KEY_Y
	heal_key.pressed = true
	health._unhandled_input(heal_key)
	await settle()
	check(bool(app.state.get("quick_healed", false)), "quick heal persists local treated state")
	check(int(app.state.get("med_count", 0)) == max(0, before_meds - 1), "quick heal consumes one med")

	app.navigate("stats", false)
	await settle()
	check(app.screen.find_children("*", "ColorRect", true, false).size() >= 20, "stats contains native ruler marks")

	print("INVENTORY_TEST_COMPLETE checks=", checks, " failures=", failures)
	app.queue_free()
	await settle()
	quit(0 if failures == 0 else 1)
