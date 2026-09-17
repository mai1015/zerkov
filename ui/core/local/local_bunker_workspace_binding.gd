class_name LocalBunkerWorkspaceBinding
extends LocalFlowBinding
## Read-only production composition for the three existing bunker layouts.
## Never calls their fixture build/clock/action handlers. The root owns routes;
## CharacterUIRuntime supplies immutable stock views, not an inventory handle.
const WORKSPACES := ["crafting", "build_mode", "session"]
const FACILITIES := [
	["Workbench", "workshop", "WORKSHOP", "mechanical-bench"],
	["Generator", "utilities", "POWER & WATER", "generator-skid-active"],
	["Watercollector", "medical", "MEDICAL", "medical-prep"],
	["Shelves", "storage", "STORAGE", "storage-rack"],
	["Bunk", "rest", "REST AREA", "field-cot"],
	["Radio", "kitchen", "KITCHEN", "cook-station"],
]
const SUPPLIES := [
	["Bandage", &"zerkov.item.medical.bandage"],
	["Splint", &"zerkov.item.medical.splint"],
]
var _runtime: CharacterUIRuntime
var _canvas: Control
var _art: ZBunkerHideoutWorld
var _stock: Dictionary = {}
var _selection: String = "workshop"
var _supply: int = 0

static func supports_workspace(route: String) -> bool:
	return route in WORKSPACES

func bind(screen: ZScreen, port: LocalGameUI) -> bool:
	if _screen != null or port == null or not supports_workspace(screen.app.current_route): return false
	_screen = screen
	_port = port
	_epoch = screen.app.local_epoch()
	_runtime = screen.app.character_runtime()
	if _runtime == null: return false
	_selection = port.bunker_room(_epoch)
	# Stop all fixture entrypoints before the first visible frame. Styling-only
	# functions recreate serialized panel borders but do not read fixture state.
	screen.set_process(false)
	screen.set_process_input(false)
	screen.set_process_unhandled_input(false)
	screen.set_process_unhandled_key_input(false)
	for node: Node in screen.find_children("*", "BaseButton", true, false):
		(node as BaseButton).disabled = true
	if screen.app.current_route == "crafting": screen.call("_install_scale_safe_styles")
	else: screen.call("_install_valid_styles")
	_canvas = Control.new()
	_canvas.name = "LocalWorkspaceCanvas"
	_canvas.size = Vector2(1920, 1080)
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var original := screen.get_children()
	screen.add_child(_canvas)
	for child: Node in original:
		if child is CanvasItem: child.reparent(_canvas, false)
	# The old floorplan is a different bunker. Use the same authored cutaway.
	for name: String in ["BunkerMap", "Floorplan", "FloorplanGlow", "Glow", "CompactWorkspace"]: _visible(name, false)
	var surface := SubViewport.new()
	surface.size = Vector2i(640, 360)
	surface.transparent_bg = true
	surface.handle_input_locally = false
	surface.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_canvas.add_child(surface)
	_art = load("res://game/presentation/bunker/bunker_world.tscn").instantiate() as ZBunkerHideoutWorld
	surface.add_child(_art)
	var raster := TextureRect.new()
	raster.name = "SharedBunkerMap"
	raster.texture = surface.get_texture()
	raster.size = Vector2(1920, 1080)
	raster.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	raster.mouse_filter = Control.MOUSE_FILTER_IGNORE
	raster.modulate.a = 0.20 if screen.app.current_route == "crafting" else 0.65
	_canvas.add_child(raster)
	_canvas.move_child(raster, 3)
	match screen.app.current_route:
		"crafting": _build_crafting()
		"build_mode": _build_facilities()
		"session": _build_session()
	var chrome := _node("TopChrome") as ZTopChrome
	chrome.title = {"crafting":"WORKSHOP", "build_mode":"FACILITIES", "session":"LOCAL SESSION"}[screen.app.current_route]
	chrome.level = "LOCAL CAMPAIGN"
	chrome.money = ""
	chrome.world_status = "SOLO / LOCAL SAVE"
	chrome.get_menu_action().disabled = false
	chrome.menu_requested.connect(_send.bind(&"pause"))
	# Resource/status strips have fixture values; absence is not zero currency,
	# full power, free capacity, or a running crafting queue.
	for name: String in ["Power", "Stash", "Water", "WaterStatus", "Crafting", "CraftingCount", "BuildBadge", "WorldBadge", "Money"]:
		(chrome.get_node(name) as CanvasItem).hide()
	_action(_canvas, "BackToBunker", "BACK TO BUNKER", Rect2(48, 1034, 250, 34), &"return_home")
	_screen.default_focus = _screen.get_path_to(_node("BackToBunker"))
	port.changed.connect(refresh)
	_runtime.inventory_view_changed.connect(_inventory_changed)
	_runtime.binding_invalidated.connect(_invalidated)
	refresh()
	return true

func refresh() -> void:
	if _screen == null or not is_instance_valid(_screen) or not _screen.is_inside_tree(): return
	var frame := _port.snapshot()
	if frame.is_empty() or frame.get("epoch") != _epoch or frame.get("mode") != "home" or frame.get("home_available") != true:
		_screen.hide()
		return
	_stock = stock_from_views(_runtime.inventory_view(&"profile"), _runtime.inventory_view(&"raid"))
	match _screen.app.current_route:
		"crafting": _refresh_crafting()
		"build_mode": _refresh_facility()
		"session":
			_text_at("SessionPanel/LocalProfile", "PROFILE GENERATION %d\n\n%s\n\n%s" % [int(frame.profile_generation),
				"%d projected item stacks" % int(_stock.stacks) if _stock.ready else "Inventory temporarily unavailable", String(frame.notice)])

func _inventory_changed(_scope: StringName, _view: InventoryView) -> void:
	refresh()

func _invalidated(_reason: StringName) -> void:
	refresh()

## Unique native identity, not row count or an assumed initial kit. Both scopes
## must be current; a missing view is unknown, not an empty inventory.
static func stock_from_views(profile: InventoryView, raid: InventoryView) -> Dictionary:
	var missing := {"ready":false, "stacks":0, "quantities":{}, "names":{}}
	if profile == null or raid == null or not profile.is_ready() or not raid.is_ready(): return missing
	if profile.generation() != raid.generation() or profile.actor_id().canonical_key() != raid.actor_id().canonical_key(): return missing
	var seen: Dictionary = {}
	var quantities: Dictionary = {}
	var names: Dictionary = {}
	for view: InventoryView in [profile, raid]:
		for container: InventoryView.ContainerRecord in view.containers():
			# Never aggregate a previously opened world crate/corpse as home stock.
			if container.kind() in [InventoryView.ContainerKind.CRATE, InventoryView.ContainerKind.CORPSE]: continue
			for item: InventoryView.ItemRecord in container.items():
				var key := "%d:%d" % [container.inventory_id(), item.instance_id()]
				if seen.has(key): continue
				seen[key] = true
				var id := String(item.content_id())
				quantities[id] = int(quantities.get(id, 0)) + item.quantity()
				names[id] = item.display_name()
	return {"ready":true, "stacks":seen.size(), "quantities":quantities, "names":names}

func _build_crafting() -> void:
	_text_at("RecipePanel/Title", "MEDICAL SUPPLIES")
	_text_at("RecipePanel/Count", "2 stock types")
	for path: String in ["RecipePanel/Level", "RecipePanel/FilterAll", "RecipePanel/FilterCraftable", "RecipePanel/FilterMeds", "RecipePanel/FilterTools",
		"RecipePanel/StashHint", "RecipePanel/UpgradePanel", "RecipePanel/RecipeBandage/Count", "DetailPanel/Ingredients",
		"DetailPanel/StatTime", "DetailPanel/StatQuantity", "DetailPanel/StatTotal", "DetailPanel/QuantityMinus", "DetailPanel/QuantityPlus",
		"DetailPanel/MissingPanel", "DetailPanel/CraftFooter", "QueuePanel/QueueBandage", "QueuePanel/QueueSplint", "QueuePanel/Slot",
		"QueuePanel/StashTitle", "QueuePanel/StashDetail", "QueuePanel/StashRule", "QueuePanel/Stash", "HintRow"]: _visible(path, false)
	for name: String in ["Painkillers", "Antiseptic", "MedKit", "Water"]: _visible("RecipePanel/Recipe" + name, false)
	for index in range(SUPPLIES.size()):
		var prefix := "RecipePanel/Recipe" + String(SUPPLIES[index][0])
		_visible(prefix + "/Availability", false)
		_select_button(prefix + "/Hit", _choose_supply.bind(index))
	_text_at("DetailPanel/Description", "View the medical supplies currently projected from your stash and carried containers. This is not a crafting recipe.")
	var detail := _node("DetailPanel") as Control
	var description := _node("DetailPanel/Description") as Label
	description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	description.size = Vector2(760, 108)
	_add_label(detail, "SupplyStock", "", Rect2(32, 200, 740, 100), 24)
	_add_label(detail, "ServiceStatus", "CRAFTING UNAVAILABLE\n\nRecipes, ingredient consumption, timed production and collection are not implemented. No queue runs while you raid.", Rect2(32, 370, 740, 180), 16)
	var craft := _node("DetailPanel/CraftNow") as Button
	craft.text = "CRAFTING UNAVAILABLE"
	craft.disabled = true
	craft.tooltip_text = "No authoritative crafting service is connected."
	_action(detail, "OpenLoadout", "MANAGE SUPPLIES IN STASH / LOADOUT", Rect2(32, 600, 680, 44), &"loadout")
	_text_at("QueuePanel/Title", "PRODUCTION")
	_text_at("QueuePanel/Detail", "UNAVAILABLE")
	_add_label(_node("QueuePanel") as Control, "QueueStatus", "No active crafting service.\n\nExisting supplies are read from your live inventory; production quantities and completion times are not guessed.", Rect2(24, 68, 420, 220), 15)

func _choose_supply(index: int) -> void:
	if not _screen.accepts_input() or index < 0 or index >= SUPPLIES.size(): return
	_supply = index
	_refresh_crafting()

func _refresh_crafting() -> void:
	for row: Array in SUPPLIES:
		var id := String(row[1])
		var copy := "%d IN PROJECTED STOCK" % int(_stock.quantities.get(id, 0)) if _stock.ready else "STOCK UNAVAILABLE"
		_text_at("RecipePanel/Recipe" + String(row[0]) + "/Duration", copy)
	var selected: Array = SUPPLIES[_supply]
	_text_at("DetailPanel/Title", String(selected[0]).to_upper())
	_text_at("DetailPanel/SupplyStock", "%d AVAILABLE IN PROJECTED INVENTORY" % int(_stock.quantities.get(String(selected[1]), 0)) if _stock.ready else "INVENTORY UNAVAILABLE")

func _build_facilities() -> void:
	for child: Node in _canvas.get_children():
		var name := String(child.name)
		if child is CanvasItem and (name.begins_with("Grid") or name.begins_with("PowerArc") or name.begins_with("Category") or name in ["Preview", "InvalidPreview", "StorageMarker", "UtilitiesMarker", "CardArmoryrack", "CardGreenhouse", "FooterHint"]):
			child.hide()
	_text_at("PlacedHint", "EXISTING BUNKER LAYOUT / CONSTRUCTION UNAVAILABLE")
	for index in range(FACILITIES.size()):
		var row: Array = FACILITIES[index]
		var prefix := "Card" + String(row[0])
		var card := _node(prefix) as Control
		card.position.x = 48 + index * 226
		_text_at(prefix + "/Title", row[2])
		_text_at(prefix + "/Size", "INSTALLED AREA")
		_text_at(prefix + "/Cost", "NO PURCHASE ACTION")
		_text_at(prefix + "/Detail", "Inspect facility")
		_visible(prefix + "/Sprite/Label", false)
		var icon := TextureRect.new()
		icon.texture = _art.assets[row[3]]
		icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		icon.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_node(prefix + "/Sprite").add_child(icon)
		_select_button(prefix + "/Hit", _choose_facility.bind(String(row[1])))
	_text_at("PlacementPanel/Subtitle", "READ-ONLY / CURRENT LAYOUT")
	for path: String in ["SizeLabel", "SizeValue", "CostLabel", "CostValue", "PowerLabel", "PowerValue", "UnlocksLabel", "UnlocksValue", "RuleCost", "RulePower", "RuleUnlocks"]: _visible("PlacementPanel/" + path, false)
	var panel := _node("PlacementPanel") as Control
	panel.position = Vector2(1392, 94)
	panel.size = Vector2(480, 650)
	(_node("PlacementPanel/Title") as Control).position = Vector2(24, 16)
	(_node("PlacementPanel/Title") as Control).size.x = 432
	(_node("PlacementPanel/Subtitle") as Control).position = Vector2(24, 42)
	(_node("PlacementPanel/Subtitle") as Control).size.x = 432
	for index in range(2):
		var disabled := _node("PlacementPanel/" + ("Place" if index == 0 else "Rotate")) as Button
		disabled.position = Vector2(24, 434 + 54 * index)
		disabled.size = Vector2(432, 44)
		disabled.tooltip_text = "Read-only authored layout; no construction service is connected."
	_add_label(panel, "FacilityStatus", "", Rect2(24, 84, 432, 230), 15)
	(_node("PlacementPanel/Place") as Button).text = "CONSTRUCTION UNAVAILABLE"
	(_node("PlacementPanel/Rotate") as Button).text = "LAYOUT READ-ONLY"
	_action(panel, "FacilityRoute", "", Rect2(24, 330, 432, 42), &"loadout")

func _choose_facility(room: String) -> void:
	if not _screen.accepts_input() or not ZBunkerHideoutView.HOME_ROOMS.has(room): return
	_selection = room
	_port.remember_bunker_room(room, _epoch)
	_refresh_facility()

func _refresh_facility() -> void:
	var room: Dictionary = ZBunkerHideoutView.HOME_ROOMS[_selection]
	_text_at("PlacementPanel/Title", room.title)
	_text_at("PlacementPanel/FacilityStatus", String(room.detail) + "\n\nThe facility is part of the authored map. Placement, prices, power simulation and upgrades are unavailable.")
	var action := _node("PlacementPanel/FacilityRoute") as Button
	var command: StringName = &"crafting" if _selection == "workshop" else room.action
	# Replace only our route connection, never enable a construction callback.
	for connection: Dictionary in action.pressed.get_connections():
		var cb: Callable = connection.callable
		if cb.get_object() == self: action.pressed.disconnect(cb)
	action.disabled = command.is_empty()
	action.text = "OPEN WORKSHOP" if _selection == "workshop" else room.label
	if not command.is_empty(): action.pressed.connect(_send.bind(command))

func _build_session() -> void:
	for name: String in ["StorageMarker", "MedicalMarker", "UtilitiesMarker", "AmmoMarker", "FoodMarker", "HostSprite", "GuestSprite", "GuestName", "JoinToast", "FooterHint"]: _visible(name, false)
	for name: String in ["Subtitle", "PrivacyInviteOnly", "PrivacyFriends", "CodeRow", "NewCode", "FriendsMeta", "FriendsRule", "FriendsBox", "SquadRules", "Players/Guest", "Players/EmptySlot", "Players/Host/Role"]: _visible("SessionPanel/" + name, false)
	_text_at("SessionPanel/Title", "LOCAL SESSION")
	_text_at("SessionPanel/WhoCanJoin", "CONNECTION MODE")
	_text_at("SessionPanel/PrivacyClosed/Label", "OFFLINE / SOLO")
	_text_at("SessionPanel/Policy", "This campaign is stored on this computer. Online joining, invite codes and friend presence are unavailable.")
	(_node("SessionPanel/Policy") as Label).autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	(_node("SessionPanel/Policy") as Control).size.y = 60
	(_node("SessionPanel/Occupancy") as Control).position.y = 174
	(_node("SessionPanel/Players") as Control).position.y = 204
	(_node("SessionPanel/Players") as Control).size.y = 60
	_text_at("SessionPanel/Occupancy", "LOCAL OPERATOR / 1 PLAYER")
	_text_at("SessionPanel/Players/Host/Name", "LOCAL OPERATOR")
	# Remove remaining authored host metadata instead of showing assumed level/ping.
	for child: Node in _node("SessionPanel/Players/Host").get_children():
		if child is CanvasItem and child.name != &"Name": child.hide()
	_text_at("SessionPanel/FriendsTitle", "CAMPAIGN")
	var panel := _node("SessionPanel") as Control
	_add_label(panel, "LocalProfile", "", Rect2(24, 420, 432, 220), 16)
	_action(panel, "OpenLoadout", "STASH / LOADOUT", Rect2(24, 670, 432, 42), &"loadout")
	_action(panel, "PlanRaid", "RAID BRIEFING", Rect2(24, 722, 432, 42), &"maps")
	_action(panel, "OpenWorkshop", "WORKSHOP", Rect2(24, 774, 208, 42), &"crafting")
	_action(panel, "OpenFacilities", "FACILITIES", Rect2(248, 774, 208, 42), &"build_mode")

func fit_workspace(view: Vector2) -> void:
	if _canvas == null: return
	var ratio := minf(view.x / 1920.0, view.y / 1080.0)
	_canvas.scale = Vector2.ONE * ratio
	_canvas.position = (view - Vector2(1920, 1080) * ratio) * 0.5

func _node(path: String) -> Node:
	return _canvas.get_node(path)

func _visible(path: String, visible: bool) -> void:
	var node := _canvas.get_node_or_null(path) as CanvasItem
	if node != null: node.visible = visible

func _text_at(path: String, copy: String) -> void:
	var node := _node(path)
	if node is Label: node.text = copy

func _add_label(parent: Control, id: String, copy: String, rect: Rect2, font_size: int) -> void:
	var label := Label.new()
	label.name = id
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.position = rect.position
	label.size = rect.size
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override("font_size", font_size)
	label.text = copy
	parent.add_child(label)

func _action(parent: Control, id: String, copy: String, rect: Rect2, command: StringName) -> void:
	var button := _screen.btn(parent, copy, rect, _send.bind(command))
	button.name = id

func _select_button(path: String, callback: Callable) -> void:
	var button := _node(path) as BaseButton
	button.disabled = false
	button.pressed.connect(callback)

func _exit_tree() -> void:
	if is_instance_valid(_runtime):
		if _runtime.inventory_view_changed.is_connected(_inventory_changed): _runtime.inventory_view_changed.disconnect(_inventory_changed)
		if _runtime.binding_invalidated.is_connected(_invalidated): _runtime.binding_invalidated.disconnect(_invalidated)
	super._exit_tree()
