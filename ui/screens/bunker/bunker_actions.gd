extends ZScreen

## Shared UI-only actions for four authored bunker-family scenes.
## Route and preview state arrive through ZUIContext. Fixture crafting entries
## use absolute ticks so leaving a screen does not pause the sample queue.

const DESIGN_SIZE := Vector2(1920.0, 1080.0)
const BG := Color("0a0b0a")
const PANEL := Color("0e100f")
const CANVAS := Color("141414")
const DARK := Color(0.027, 0.035, 0.035, 0.88)
const TEXT := Color("e6e8e3")
const SOFT := Color("b7bcb4")
const MUTED := Color("8b918a")
const BORDER := Color("2a2a2a")
const LINE := Color(1.0, 1.0, 1.0, 0.12)
const SUBTLE := Color(1.0, 1.0, 1.0, 0.08)
const ACCENT := Color("e8962e")
const HOVER := Color("f2b15a")
const GREEN := Color("5fd36b")
const RED := Color("d9483b")
const YELLOW := Color("e9d35a")
const BLUE := Color("4c8dff")

var _route: String = "bunker"
var _selected_station: int = 4
var _selected_recipe: int = 0
var _recipe_filter: String = "CRAFTABLE"
var _build_category: String = "STATIONS"
var _build_selection: String = "WORKBENCH"
var _preview_valid: bool = true
var _build_rotation: int = 0
var _craft_quantity: int = 3
var _craft_status_labels: Array = []
var _craft_progress_bars: Array = []
var _heading_fonts: Dictionary = {}
var _compact_craft_tab: String = "RECIPE"

func _bind_top_chrome() -> void:
	var chrome: ZTopChrome = get_node("TopChrome")
	if not chrome.menu_requested.is_connected(_on_menu):
		chrome.menu_requested.connect(_on_menu)


func _process(_delta: float) -> void:
	if _route == "crafting":
		_update_crafting_clock()


## ---------- Shared native primitives ----------

func _on_menu() -> void:
	go("pause")


## ---------- Shared state ----------

func _ensure_state() -> void:
	preload("res://ui/dev/fixtures/bunker_fixture.gd").initialize(app.state)

func _max_players() -> int:
	var worlds: Array = app.state.get("frontflow_worlds", [])
	var selected: int = int(app.state.get("frontflow_selected_world", 0))
	if selected >= 0 and selected < worlds.size(): return int(worlds[selected].get("max_players", 4))
	return 4


func _craft_queue() -> Array:
	var queue: Array = app.state.get("bunker_craft_queue", [])
	return queue


func _save_craft_queue(queue: Array) -> void:
	app.state["bunker_craft_queue"] = queue


func _queue_entry(name: String, asset: String, duration_ms: int) -> Dictionary:
	var queue: Array = _craft_queue()
	var now: int = Time.get_ticks_msec()
	var start_at: int = now
	if not queue.is_empty():
		var last: Dictionary = queue[queue.size() - 1]
		var queued_finish: int = int(last.get("finish_at", now))
		if queued_finish > start_at:
			start_at = queued_finish
	var serial: int = int(app.state.get("bunker_craft_serial", 0)) + 1
	app.state["bunker_craft_serial"] = serial
	return {"id": "craft_%d" % serial, "name": name, "asset": asset, "started_at": start_at, "finish_at": start_at + duration_ms, "duration": duration_ms, "claimed": false}


func _format_remaining(milliseconds: int) -> String:
	var seconds: int = maxi(0, int(ceil(float(milliseconds) / 1000.0)))
	var minutes: int = seconds / 60
	var remainder: int = seconds % 60
	return "%02d:%02d" % [minutes, remainder]


func _format_code() -> String:
	var stamp: int = Time.get_ticks_msec() % 65536
	return "ZK-%04X" % stamp


func _rebuild_route() -> void:
	app.state["bunker_selected_station"] = _selected_station
	refresh_view()


func _on_station(station_id: int) -> void:
	if station_id == 6:
		toast("Equipment unlocks at Bunker LVL 4.")
		return
	_selected_station = station_id
	if station_id == 2:
		toast("Medical station selected.")
	elif station_id == 4:
		toast("Ammunition bench selected.")
	_rebuild_route()


func _on_upgrade_station() -> void:
	toast("Upgrade needs Car battery ×1 and Coal ×2.")


func _on_use_station() -> void:
	if _selected_station == 2:
		go("crafting")
	elif _selected_station == 1:
		go("inventory")
	elif _selected_station == 5:
		app.state["bunker_water"] = int(app.state.get("bunker_water", 0)) + 4
		toast("Collected 4 clean water into stash.")
	else:
		toast("Station interface is a local prototype.")


## ---------- Shared build mode actions ----------

func _on_build_category(category: String) -> void:
	_build_category = category
	toast("Build category: %s" % category)
	_rebuild_route()


func _on_build_item(selection: String) -> void:
	if selection in ["ARMORY RACK", "GREENHOUSE"]:
		toast("Unlock a higher bunker level to build this module.")
		return
	_build_selection = selection
	_preview_valid = selection != "GENERATOR"
	toast("Placing %s." % selection)
	_rebuild_route()


func _on_toggle_preview() -> void:
	_preview_valid = not _preview_valid
	toast("Placement %s." % ("valid" if _preview_valid else "blocked by wall"))
	_rebuild_route()


func _on_place_building() -> void:
	if not _preview_valid:
		toast("Cannot place here: blocked by wall.")
		return
	app.confirm("PLACE %s?" % _build_selection, "Spend $1,200 and Gun parts ×1 on this valid grid cell.", Callable(self, "_confirm_place_building"))


func _confirm_place_building() -> void:
	app.state["bunker_placed"] = int(app.state.get("bunker_placed", 7)) + 1
	toast("%s placed (mock)." % _build_selection)
	_rebuild_route()


func _on_rotate_building() -> void:
	_build_rotation = (_build_rotation + 1) % 4
	toast("Rotated %s°." % str(_build_rotation * 90))
	_rebuild_route()


func _on_exit_build() -> void:
	go("bunker")


## ---------- Shared crafting actions ----------

func _update_crafting_clock() -> void:
	var queue: Array = _craft_queue()
	var now: int = Time.get_ticks_msec()
	for i in range(mini(queue.size(), _craft_status_labels.size())):
		var data: Dictionary = queue[i]
		var remaining: int = int(data.get("finish_at", now)) - now
		var done: bool = remaining <= 0
		var status: Label = _craft_status_labels[i]
		if done and status.text != "READY":
			call_deferred("_rebuild_route")
			return
		status.text = "READY" if done else "%s left" % _format_remaining(remaining)
		status.add_theme_color_override("font_color", GREEN if done else MUTED)
		var progress: ProgressBar = _craft_progress_bars[i]
		var duration: int = maxi(1, int(data.get("duration", 1)))
		progress.value = 100.0 if done else clampf(100.0 - float(remaining) / float(duration) * 100.0, 0.0, 100.0)
		if done:
			progress.add_theme_stylebox_override("fill", _progress_style(GREEN))


func _progress_style(color: Color) -> StyleBoxFlat:
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = color
	return style


func _on_recipe_filter(filter_name: String) -> void:
	_recipe_filter = filter_name
	toast("Recipe filter: %s" % filter_name)
	_rebuild_route()


func _on_recipe_selected(index: int) -> void:
	_selected_recipe = index
	toast("Recipe selected.")
	_rebuild_route()


func _on_quantity(delta: int) -> void:
	_craft_quantity = clampi(_craft_quantity + delta, 1, 3)
	_rebuild_route()


func _recipe_data() -> Array:
	return [
		["Bandage", "item_bottle.png", 45000, "stops light bleed · +40 HP over 10 s", 2],
		["Splint", "item_tape.png", 90000, "stabilizes a fractured limb", 1],
		["Painkillers", "item_potion.png", 120000, "temporary pain relief", 1],
		["Antiseptic", "item_bottle.png", 180000, "cleans wounds · missing ingredients", 1],
		["Med kit · field", "item_box.png", 480000, "field treatment · requires station LVL 3", 1],
		["Clean water", "item_cup.png", 20000, "purified water · crafting ingredient", 1]
	][_selected_recipe]


func _on_craft_now() -> void:
	if _selected_recipe in [3, 4]:
		toast("This recipe requires missing materials or a station upgrade.")
		return
	var queue: Array = _craft_queue()
	if queue.size() >= 2:
		toast("Crafting queue is full.")
		return
	var recipe = _recipe_data()
	var quantity: int = mini(_craft_quantity, 2) if _selected_recipe == 0 else _craft_quantity
	var entry: Dictionary = _queue_entry("%s ×%d" % [recipe[0], recipe[4] * quantity], recipe[1], recipe[2] * quantity)
	queue.append(entry)
	_save_craft_queue(queue)
	toast("%s queued. It keeps running while you raid." % recipe[0])
	_rebuild_route()


func _on_craft_water() -> void:
	var queue: Array = _craft_queue()
	if queue.size() >= 2:
		toast("Crafting queue is full.")
		return
	queue.append(_queue_entry("Clean water", "item_cup.png", 20000))
	_save_craft_queue(queue)
	toast("Clean water queued for 00:20.")
	_rebuild_route()


func _on_collect_queue(id: String) -> void:
	var queue: Array = _craft_queue()
	for i in range(queue.size() - 1, -1, -1):
		var data: Dictionary = queue[i]
		if str(data.get("id", "")) == id:
			if int(data.get("finish_at", 0)) > Time.get_ticks_msec():
				toast("This craft is still running.")
				return
			var collected: Array = app.state.get("bunker_collected", [])
			collected.append(data.get("name", "Craft"))
			app.state["bunker_collected"] = collected
			queue.remove_at(i)
			break
	_save_craft_queue(queue)
	toast("Craft collected into stash.")
	_rebuild_route()


func _on_stash_click() -> void:
	go("inventory")


func _unhandled_input(event: InputEvent) -> void:
	if not accepts_input(): return
	if not event is InputEventKey or not event.pressed or event.echo: return
	if is_instance_valid(app.modal) or is_instance_valid(app.picker): return
	var viewport = get_viewport()
	var handled = true
	match event.keycode:
		KEY_B:
			go("bunker" if _route == "build_mode" else "build_mode")
		KEY_E:
			if _route in ["bunker", "session"]: _on_use_station()
			else: handled = false
		KEY_R:
			if _route == "build_mode": _on_rotate_building()
			else: handled = false
		KEY_SPACE:
			if _route == "crafting": _on_craft_now()
			else: handled = false
		KEY_F:
			if _route == "crafting":
				for entry in _craft_queue().duplicate():
					if int(entry.get("finish_at", 0)) <= Time.get_ticks_msec(): _on_collect_queue(str(entry["id"]))
			else: handled = false
		_: handled = false
	if handled: viewport.set_input_as_handled()


func _on_upgrade_recipe() -> void:
	toast("Medical station upgrade needs 2 more parts.")


## ---------- Shared session actions ----------

func _on_privacy(option: String) -> void:
	app.state["bunker_privacy"] = option
	var worlds: Array = app.state.get("frontflow_worlds", [])
	var selected: int = int(app.state.get("frontflow_selected_world", 0))
	if selected >= 0 and selected < worlds.size(): worlds[selected]["privacy"] = option
	toast("Session privacy: %s" % option)
	_rebuild_route()


func _on_copy_code() -> void:
	DisplayServer.clipboard_set(str(app.state.get("bunker_code", "ZK-7F2Q")))
	toast("World code copied.")


func _on_new_code() -> void:
	app.state["bunker_code"] = _format_code()
	toast("New world code generated.")
	_rebuild_route()


func _on_invite(friend: String) -> void:
	var invited: Array = app.state.get("bunker_invited", [])
	if not invited.has(friend): invited.append(friend)
	app.state["bunker_invited"] = invited
	toast("Invite sent to %s (mock)." % friend)
	_rebuild_route()


func _on_empty_slot() -> void:
	toast("Invite a friend from the list to fill this slot.")


func _on_kick_guest() -> void:
	app.confirm("KICK KEVIN_J?", "This removes the guest from your mock world.", Callable(self, "_confirm_kick_guest"))


func _confirm_kick_guest() -> void:
	app.state["bunker_guest_present"] = false
	toast("KEVIN_J was kicked from the world.")
	_rebuild_route()


func _on_deploy() -> void:
	app.state["deploy_source"] = "session"
	toast("Deploying squad…")
	go("deploying")


func layout_compact(view: Vector2) -> void:
	preload("res://ui/screens/bunker/components/bunker_layout.gd").apply(self, view)

func _compact_select_tab(tab: String) -> void:
	_compact_craft_tab = tab
	_rebuild_route()


func _compact_collect_all() -> void:
	for entry in _craft_queue().duplicate():
		if int(entry.get("finish_at", 0)) <= Time.get_ticks_msec(): _on_collect_queue(str(entry["id"]))
