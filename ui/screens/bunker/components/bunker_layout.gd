extends RefCounted
## Explicit membership and geometry for the retained bunker-family workspaces.
## All controls come from authored feature scenes or compact_workspace.tscn.

static func node(screen: Control, path: String) -> Control:
	var refs: Dictionary = screen.get_meta("bunker_layout_refs")
	return refs.get(path) as Control

static func put(screen: Control, path: String, parent: Control, rect: Rect2) -> Control:
	var item := node(screen, path)
	if item.get_parent() != parent: item.reparent(parent, false)
	item.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	item.position = rect.position
	item.size = rect.size
	item.show()
	return item

static func pane(screen: Control, key: String, rect: Rect2, intrinsic: Vector2) -> Control:
	var scroll := put(screen, "CompactWorkspace/" + key, screen, rect)
	var content := node(screen, "CompactWorkspace/" + key + "/Content")
	content.custom_minimum_size = intrinsic
	return content

static func wire(button: Button, callback: Callable) -> void:
	if not button.pressed.is_connected(callback): button.pressed.connect(callback)

static func apply(screen: Control, view: Vector2) -> void:
	if not screen.has_meta("bunker_layout_refs"):
		var refs := {}
		for child in screen.find_children("*", "Control", true, false):
			refs[str(screen.get_path_to(child))] = child
		screen.set_meta("bunker_layout_refs", refs)
	for child in screen.get_children():
		if child is CanvasItem: child.hide()
	var workspace := node(screen, "CompactWorkspace")
	workspace.show()
	workspace.size = view
	for child in workspace.get_children():
		if child is Control: child.hide()
	var chrome: ZTopChrome = node(screen, "TopChrome")
	chrome.show()
	chrome.layout_for(view)
	var base_path := "FloorBase" if screen._route == "bunker" else ("Background" if screen._route == "crafting" else "BackgroundColor")
	put(screen, base_path, screen, Rect2(Vector2.ZERO, view))
	for i in range(5):
		var action: Button = node(screen, "CompactWorkspace/Route%d" % i)
		action.show()
		var route: String = action.get_meta("route")
		action.variant = "primary" if route == screen._route else "secondary"
		wire(action, screen.go.bind(route))
	put(screen, "CompactWorkspace/Rule", workspace, Rect2(16, 108, view.x - 32, 1))
	match screen._route:
		"crafting": crafting(screen, view)
		"session": session(screen, view)
		"build_mode": building(screen, view)
		_: bunker(screen, view)

static func floorplan(screen: Control, rect: Rect2) -> void:
	var frame := put(screen, "CompactWorkspace/MapFrame", screen, rect)
	var art := put(screen, "BunkerMap", screen, rect.grow(-8))
	screen.move_child(frame, art.get_index())
	art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	if screen._route == "bunker":
		var points := [Vector2(.12, .12), Vector2(.10, .67), Vector2(.54, .24), Vector2(.76, .43), Vector2(.53, .70), Vector2(.8, .91)]
		for i in range(6):
			var point: Vector2 = rect.position + points[i] * rect.size
			point.x = minf(point.x, rect.end.x - 104)
			point.y = minf(point.y, rect.end.y - 28)
			var badge := put(screen, "Marker%dBadge" % (i + 1), screen, Rect2(point, Vector2(104, 28)))
			put(screen, "Marker%dBadge/Hit" % (i + 1), badge, Rect2(0, 0, 104, 28))
			var number := put(screen, "Marker%dBadge/Number" % (i + 1), badge, Rect2(0, 0, 104, 28))
			number.text = "%d %s" % [i + 1, ["STORAGE", "MEDICAL", "UTILITIES", "AMMO", "FOOD", "EQUIPMENT"][i]]
		put(screen, "Player", screen, Rect2(rect.position + rect.size * Vector2(.36, .48), Vector2(24, 40)))
	elif screen._route == "session":
		put(screen, "HostSprite", screen, Rect2(rect.position + rect.size * Vector2(.36, .48), Vector2(24, 40)))
		var guest := put(screen, "GuestSprite", screen, Rect2(rect.position + rect.size * Vector2(.43, .52), Vector2(24, 40)))
		guest.visible = bool(screen.app.fixture_get("bunker_guest_present", true))

static func bunker(screen: Control, view: Vector2) -> void:
	var left := view.x - 544
	var map_height := floorf((view.y - 188) * .56)
	floorplan(screen, Rect2(16, 124, left, map_height))
	var station_y := 140 + map_height
	var list := pane(screen, "CompactStations", Rect2(16, station_y, left, view.y - station_y - 76), Vector2(left - 16, 344))
	var stations := put(screen, "Stations", list, Rect2(0, 0, left - 16, 344))
	ZLayoutSnapshot.layout_value(node(screen, "Stations/SectionTitle"), "text", "STATIONS · 5 / 6")
	node(screen, "Stations/SectionDetail").hide()
	node(screen, "Stations/SectionRule").hide()
	for i in range(6):
		var key := "Stations/Row%d" % (i + 1)
		var row := put(screen, key, stations, Rect2(0, 32 + i * 44, left - 24, 36))
		for part in ["Number", "Name", "Level", "Hit"]:
			var child := node(screen, key + "/" + part)
			child.position.y = 0
			child.size.y = 36
		node(screen, key + "/Name").size.x = left - 148
		node(screen, key + "/Level").position.x = left - 96
		node(screen, key + "/Hit").size = row.size
	node(screen, "Stations/Progress").hide()
	var details := pane(screen, "CompactStationDetails", Rect2(view.x - 512, 124, 496, view.y - 200), Vector2(480, 610))
	put(screen, "StationDetails", details, Rect2(0, 0, 480, 610))
	var upgrade := put(screen, "StationDetails/UpgradeAction", screen, Rect2(view.x - 512, view.y - 60, 324, 44))
	upgrade.visible = screen._selected_station == 4
	node(screen, "StationDetails/AltUseAction").hide()
	var use: Button = put(screen, "StationDetails/UseAction", screen, Rect2(view.x - 180, view.y - 60, 164, 44))
	ZLayoutSnapshot.button_variant(use, "primary")
	put(screen, "Hint", screen, Rect2(16, view.y - 52, left, 24))
	ZLayoutSnapshot.layout_value(node(screen, "Hint"), "text", "B BUILD    M DEPLOY    WHEEL SCROLL")

static func session(screen: Control, view: Vector2) -> void:
	var left := view.x - 544
	floorplan(screen, Rect2(16, 124, left, view.y - 252))
	var content := pane(screen, "CompactSession", Rect2(view.x - 512, 124, 496, view.y - 200), Vector2(480, 758))
	var panel := put(screen, "SessionPanel", content, Rect2(0, 0, 480, 758))
	node(screen, "SessionPanel/FriendsBox").size.y = 224
	node(screen, "SessionPanel/SquadRules").position.y = 659
	var deploy: Button = put(screen, "CompactWorkspace/Deploy", screen, Rect2(view.x - 512, view.y - 60, 496, 44))
	deploy.variant = "primary"
	wire(deploy, screen._on_deploy)
	var leave: Button = put(screen, "CompactWorkspace/Leave", screen, Rect2(16, view.y - 60, 224, 44))
	leave.text = "BACK TO BUNKER"
	wire(leave, screen.go.bind("bunker"))
	put(screen, "FooterHint", screen, Rect2(16, view.y - 116, left, 48))
	ZLayoutSnapshot.layout_value(node(screen, "FooterHint"), "text", "WORLD · " + str(screen.app.fixture_get("bunker_privacy", "INVITE ONLY")) + "\nLOOT STAYS WITH YOUR CHARACTER")

static func building(screen: Control, view: Vector2) -> void:
	var map_width := view.x - 380
	var rect := Rect2(16, 124, map_width, view.y - 264)
	floorplan(screen, rect)
	var preview := node(screen, "Preview")
	put(screen, "Preview", screen, Rect2(rect.position + rect.size * Vector2(.38, .48), preview.size))
	var catalog := pane(screen, "CompactBuildCatalog", Rect2(view.x - 348, 124, 332, view.y - 200), Vector2(312, 1240))
	var categories := ["All", "Stations", "Power", "Storage", "Comfort", "Decor"]
	for i in range(categories.size()):
		var key: String = "Category" + categories[i]
		var segment := put(screen, key, catalog, Rect2((i % 3) * 104, (i / 3) * 40, 100, 32))
		put(screen, key + "/Label", segment, Rect2(0, 0, 100, 32))
		put(screen, key + "/Hit", segment, Rect2(0, 0, 100, 32))
	var y := 96.0
	for suffix in ["Workbench", "Generator", "Watercollector", "Shelves", "Bunk", "Radio", "Armoryrack", "Greenhouse"]:
		var key: String = "Card" + suffix
		var card := node(screen, key)
		if card.modulate.a == 0: continue
		put(screen, key, catalog, Rect2(0, y, 308, 127))
		put(screen, key + "/Hit", card, Rect2(0, 0, 308, 127))
		y += 139
	catalog.custom_minimum_size.y = y
	var rotate: Button = put(screen, "PlacementPanel/Rotate", screen, Rect2(view.x - 348, view.y - 60, 156, 44))
	rotate.text = "R ROTATE · %d°" % (screen._build_rotation * 90)
	put(screen, "PlacementPanel/Place", screen, Rect2(view.x - 184, view.y - 60, 168, 44))
	put(screen, "PlacementPanel/Title", screen, Rect2(16, view.y - 128, map_width, 24))
	put(screen, "PlacedHint", screen, Rect2(16, view.y - 100, map_width, 24))
	var exit: Button = put(screen, "CompactWorkspace/ExitBuild", screen, Rect2(16, view.y - 60, 160, 44))
	wire(exit, screen._on_exit_build)

static func crafting(screen: Control, view: Vector2) -> void:
	var recipes := pane(screen, "CompactRecipes", Rect2(16, 124, 300, view.y - 200), Vector2(280, 650))
	var panel := put(screen, "RecipePanel", recipes, Rect2(0, 0, 280, 650))
	node(screen, "RecipePanel/Count").hide()
	node(screen, "RecipePanel/StashHint").hide()
	node(screen, "RecipePanel/Level").hide()
	node(screen, "RecipePanel/Title").size.x = 280
	var filters := ["All", "Craftable", "Meds", "Tools"]
	for i in range(4):
		var key: String = "RecipePanel/Filter" + filters[i]
		var segment := put(screen, key, panel, Rect2((i % 2) * 140, 32 + (i / 2) * 40, 132, 32))
		put(screen, key + "/Label", segment, Rect2(0, 0, 132, 32))
		put(screen, key + "/Hit", segment, Rect2(0, 0, 132, 32))
	var y := 120.0
	for suffix in ["Bandage", "Splint", "Painkillers", "Antiseptic", "MedKit", "Water"]:
		var key: String = "RecipePanel/Recipe" + suffix
		var row := node(screen, key)
		if not row.visible: continue
		put(screen, key, panel, Rect2(0, y, 276, 56))
		put(screen, key + "/Hit", row, Rect2(0, 0, 276, 56))
		for child in row.get_children():
			if child is Label:
				child.clip_text = true
				child.size.x = maxf(8, 272 - child.position.x)
		y += 68
	var upgrade := node(screen, "RecipePanel/UpgradePanel")
	upgrade.position = Vector2(0, y + 16)
	upgrade.size.x = 276
	recipes.custom_minimum_size.y = y + 76
	var width := view.x - 348
	var recipe_tab: Button = put(screen, "CompactWorkspace/RecipeTab", screen, Rect2(332, 124, 148, 36))
	var queue_tab: Button = put(screen, "CompactWorkspace/QueueTab", screen, Rect2(488, 124, 180, 36))
	wire(recipe_tab, screen._compact_select_tab.bind("RECIPE"))
	wire(queue_tab, screen._compact_select_tab.bind("QUEUE"))
	recipe_tab.variant = "primary" if screen._compact_craft_tab == "RECIPE" else "secondary"
	queue_tab.variant = "primary" if screen._compact_craft_tab == "QUEUE" else "secondary"
	var detail := pane(screen, "CompactCraftDetail", Rect2(332, 176, width, view.y - 252), Vector2(width - 16, 610))
	var queue := pane(screen, "CompactCraftQueue", Rect2(332, 176, width, view.y - 252), Vector2(width - 16, 610))
	detail.get_parent().visible = screen._compact_craft_tab == "RECIPE"
	queue.get_parent().visible = screen._compact_craft_tab == "QUEUE"
	put(screen, "QueuePanel", queue, Rect2(0, 0, 480, 610))
	var detail_panel := put(screen, "DetailPanel", detail, Rect2(0, 0, width - 24, 610))
	node(screen, "DetailPanel/Title").size.x = width - 24
	node(screen, "DetailPanel/Description").position = Vector2(0, 36)
	node(screen, "DetailPanel/Description").size.x = width - 24
	ZLayoutSnapshot.layout_value(node(screen, "DetailPanel/Description"), "horizontal_alignment", HORIZONTAL_ALIGNMENT_LEFT)
	node(screen, "DetailPanel/Rule").hide()
	var ingredients := node(screen, "DetailPanel/Ingredients")
	ingredients.position = Vector2(0, 88)
	ingredients.size = Vector2(width - 24, 280)
	node(screen, "DetailPanel/Ingredients/Arrow").hide()
	for i in range(3):
		var prefix: String = ["DuctTape", "Cloth", "Water"][i]
		node(screen, "DetailPanel/Ingredients/" + prefix).position = Vector2(i * 160, 32)
		node(screen, "DetailPanel/Ingredients/" + prefix + "Name").position = Vector2(i * 160, 112)
	node(screen, "DetailPanel/Ingredients/Output").position = Vector2(0, 196)
	node(screen, "DetailPanel/Ingredients/OutputName").position = Vector2(92, 210)
	node(screen, "DetailPanel/StatTime").position = Vector2(0, 384)
	node(screen, "DetailPanel/StatQuantity").position = Vector2(275, 384)
	node(screen, "DetailPanel/QuantityMinus").position = Vector2(280, 408)
	node(screen, "DetailPanel/QuantityPlus").position = Vector2(331, 408)
	node(screen, "DetailPanel/StatTotal").position = Vector2(0, 448)
	node(screen, "DetailPanel/MissingPanel").position = Vector2(0, 518)
	node(screen, "DetailPanel/MissingPanel").size.x = width - 24
	node(screen, "DetailPanel/CraftFooter").hide()
	var craft := put(screen, "DetailPanel/CraftNow", screen, Rect2(view.x - 256, view.y - 60, 240, 44))
	ZLayoutSnapshot.button_variant(craft, "primary")
	var leave: Button = put(screen, "CompactWorkspace/Leave", screen, Rect2(16, view.y - 60, 300, 44))
	leave.text = "LEAVE STATION"
	wire(leave, screen.go.bind("bunker"))
	var collect: Button = put(screen, "CompactWorkspace/Collect", screen, Rect2(332, view.y - 60, 208, 44))
	wire(collect, screen._compact_collect_all)
