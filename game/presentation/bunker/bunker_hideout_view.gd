class_name ZBunkerHideoutView
extends Control
## The production bunker presentation, also instantiated by native capture.
## Selection and lighting are local view state. There are no gameplay writes.
signal menu_requested
signal action_requested(command: StringName)
signal room_selected(room: String)
const HOME_ROOMS: Dictionary = {
	"storage": {"title":"STASH & LOADOUT", "detail":"Manage your carried equipment and stored supplies in the existing inventory workspace.", "action":&"loadout", "label":"OPEN STASH / LOADOUT"},
	"workshop": {"title":"WORKSHOP & PLANNING", "detail":"Review Sawmill, Supply Run and extraction before leaving. Crafting and upgrades are not available.", "action":&"maps", "label":"PLAN A RAID"},
	"medical": {"title":"MEDICAL CORNER", "detail":"Inspect your body and injuries in the existing health workspace. Medical crafting is not available.", "action":&"health", "label":"VIEW HEALTH"},
	"utilities": {"title":"UTILITY BAY", "detail":"Power and water systems are not simulated. The lighting switch below changes appearance only.", "action":&"", "label":"UTILITIES UNAVAILABLE"},
	"rest": {"title":"REST AREA", "detail":"Body and survival resources recover when returning home. Resting is not a separate action and never restores lost equipment.", "action":&"", "label":"RECOVERY ON RETURN"},
	"kitchen": {"title":"FIELD KITCHEN", "detail":"Cooking and production are not available. Manage carried rations and supplies through the stash.", "action":&"", "label":"COOKING UNAVAILABLE"},
}
var _campaign: bool = false
var _campaign_ready: bool = false
var _home_error: String = ""
var _facility_action: Button
var _profile: Label
var _notice: Label
var _status: Label
var _shortcuts: Dictionary = {}
var _interaction_allowed: Callable

## Bind before mounting. A standalone art preview never gains gameplay actions.
## Only values/intent callbacks enter this view; no inventory or save owner.
func configure_campaign(room: String, interaction_allowed: Callable) -> bool:
	if is_inside_tree() or _campaign or not HOME_ROOMS.has(room) or not interaction_allowed.is_valid(): return false
	_campaign = true
	current_room = room
	_interaction_allowed = interaction_allowed
	return true

func present_home(frame: Dictionary) -> bool:
	if not _campaign or not is_node_ready(): return false
	_campaign_ready = frame.get("mode") == "home" and frame.get("home_available") == true
	_home_error = String(frame.get("error", ""))
	_profile.text = "LOCAL PROFILE  /  GEN %d" % int(frame.get("profile_generation", 0))
	_notice.text = String(frame.get("notice", ""))
	_status.text = "LOCAL SAVE  /  SOLO" if _home_error.is_empty() else "LOCAL SAVE NEEDS ATTENTION"
	for command: StringName in _shortcuts:
		var target: Button = _shortcuts[command]
		target.disabled = not _campaign_ready or (command == &"maps" and not _home_error.is_empty())
	var retry := get_node("RetrySave") as Button
	retry.visible = not _home_error.is_empty()
	retry.disabled = not _campaign_ready
	_sync_campaign_room()
	return _campaign_ready

func _can_interact() -> bool:
	return not _campaign or (_campaign_ready and _interaction_allowed.is_valid() and _interaction_allowed.call())

func _request_action(command: StringName) -> void:
	if not _campaign or not _can_interact() or command.is_empty(): return
	if command == &"maps" and not _home_error.is_empty(): return
	action_requested.emit(command)

func _sync_campaign_room() -> void:
	if not _campaign or _facility_action == null: return
	var room: Dictionary = HOME_ROOMS[current_room]
	_heading.text = room.title
	_description.text = room.detail
	_number.text = "AREA " + str(_room_number()) + "  /  " + ("READY" if not String(room.action).is_empty() else "INACTIVE")
	_facility_action.text = room.label
	_facility_action.disabled = not _campaign_ready or String(room.action).is_empty() or (room.action == &"maps" and not _home_error.is_empty())

func _room_number() -> String:
	for room: Dictionary in world.layout["rooms"]:
		if room.id == current_room: return String(room.number)
	return ""

const WorldScene = preload("res://game/presentation/bunker/bunker_world.tscn")
const LIGHTING = preload("res://game/presentation/bunker/bunker_lighting.gdshader")
const Style = preload("res://ui/theme/local_journey_style.gd")
const NAVIGATION = preload("res://ui/components/layout/navigation_chrome.tscn")
const CREAM := Style.TEXT
const MUTED := Style.MUTED
const ACCENT := Style.ACCENT
var world: ZBunkerHideoutWorld
var surface: SubViewport
var current_room := "workshop"
var emergency := false
var _material: ShaderMaterial
var _buttons: Dictionary = {}
var _heading: Label
var _description: Label
var _number: Label
var _hero: TextureRect
var _outline: Panel
var _light_button: Button
var _bold: Font
var _mono: Font

func _ready() -> void:
	name = "BunkerHideoutView"
	size = Vector2(1920, 1080)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_bold = load("res://assets/fonts/ChakraPetch-SemiBold.ttf")
	_mono = load("res://assets/fonts/IBMPlexMono-Regular.ttf")
	box(Rect2(0, 0, 1920, 1080), Style.BG)
	surface = SubViewport.new()
	surface.name = "PixelWorld640x360"
	surface.size = Vector2i(640, 360)
	surface.transparent_bg = true
	surface.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	surface.canvas_item_default_texture_filter = Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST
	add_child(surface)
	world = WorldScene.instantiate()
	surface.add_child(world)
	var raster := TextureRect.new()
	raster.name = "WorldAtExact3x"
	raster.texture = surface.get_texture()
	raster.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	raster.mouse_filter = Control.MOUSE_FILTER_IGNORE
	raster.size = Vector2(1920, 1080)
	raster.stretch_mode = TextureRect.STRETCH_SCALE
	_material = ShaderMaterial.new()
	_material.shader = LIGHTING
	raster.material = _material
	add_child(raster)
	_outline = Panel.new()
	_outline.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_outline.add_theme_stylebox_override("panel", style(Color.TRANSPARENT, Color(0.82, 0.63, 0.36, 0.38)))
	add_child(_outline)
	_build_header()
	_build_inspector()
	_build_footer()
	for room: Dictionary in world.layout["rooms"]:
		var at: Array = room["label_at"]
		label(String(room["number"]) + " / " + String(room["name"]), Rect2(at[0] * 3, at[1] * 3, 300, 20), 12, Color("c4c3af"))
	select_room(current_room)

func _build_header() -> void:
	if _campaign:
		var navigation := NAVIGATION.instantiate() as ZNavigationChrome
		navigation.name = "NavigationChrome"
		add_child(navigation)
		navigation.configure_local_sections("home", "bunker", "MENU")
		navigation.navigate_requested.connect(_section_requested)
		navigation.back_requested.connect(func():
			if _can_interact(): menu_requested.emit())
	else:
		box(Rect2(0, 0, 1920, 58), Color("0e1213"))
		box(Rect2(48, 57, 1824, 1), Color("303736"))
		label("ZERKOV", Rect2(48, 12, 180, 34), 27, CREAM, true)
		label("/     HIDEOUT", Rect2(212, 23, 220, 20), 12, MUTED)
		label("B1  /  SERVICE LEVEL", Rect2(780, 22, 400, 20), 12, MUTED)
		var menu := button("ESC  MENU", Rect2(1744, 14, 128, 32))
		menu.name = "Menu"
		menu.pressed.connect(func():
			if _can_interact(): menu_requested.emit())
	label("THE BUNKER", Rect2(48, 72, 330, 45), 36, CREAM, true)
	label("04", Rect2(378, 75, 80, 43), 33, ACCENT, true)
	label("A SHELTER BETWEEN RAIDS", Rect2(470, 94, 530, 20), 12, MUTED)
	_status = label("LOCAL SAVE  /  SOLO" if _campaign else "OFFLINE  /  VISUAL PREVIEW", Rect2(1552, 89, 340, 22), 12, ACCENT)
	_status.name = "SessionStatus"
	if _campaign:
		for entry: Array in [["CraftingWorkspace", "WORKSHOP", &"crafting", 1034, 156],
			["BuildWorkspace", "FACILITIES", &"build_mode", 1200, 156],
			["SessionWorkspace", "LOCAL SESSION", &"session", 1366, 166]]:
			var workspace := button(entry[1], Rect2(entry[3], 84, entry[4], 32))
			workspace.name = entry[0]
			workspace.disabled = true
			workspace.pressed.connect(_request_action.bind(entry[2]))
			_shortcuts[entry[2]] = workspace
		_profile = label("", Rect2(1552, 120, 320, 20), 11, MUTED)
		_profile.name = "LocalProfile"

func _build_inspector() -> void:
	var panel := Panel.new()
	panel.name = "FacilityInspector"
	panel.position = Vector2(1552, 148)
	panel.size = Vector2(320, 820)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_theme_stylebox_override("panel", style(Style.PANEL, Style.LINE))
	add_child(panel)
	label("FACILITIES", Rect2(1576, 168, 220, 26), 16, CREAM, true)
	label("06", Rect2(1820, 170, 36, 22), 13, MUTED)
	var index := 0
	for room: Dictionary in world.layout["rooms"]:
		var id: String = room["id"]
		var b := button(String(room["number"]) + "     " + String(room["name"]), Rect2(1576, 210 + index * 43, 272, 35))
		b.name = "Select_" + id
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.pressed.connect(_choose_room.bind(id))
		_buttons[id] = b
		index += 1
	box(Rect2(1576, 482, 272, 1), Style.LINE)
	_number = label("", Rect2(1576, 500, 272, 20), 11, ACCENT)
	_heading = label("", Rect2(1576, 528, 272, 64), 25, CREAM, true)
	_heading.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box(Rect2(1576, 598, 272, 174), Color("0b1112"))
	_hero = TextureRect.new()
	_hero.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_hero.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hero.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	add_child(_hero)
	_description = label("", Rect2(1576, 794, 272, 100), 12, MUTED)
	_description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	if _campaign:
		_description.position.y = 782
		_description.size.y = 88
		_facility_action = button("", Rect2(1576, 870, 272, 36))
		_facility_action.name = "FacilityAction"
		_facility_action.disabled = true
		_facility_action.pressed.connect(func(): _request_action(HOME_ROOMS[current_room].action))
	_light_button = button("PREVIEW LIGHTS / STANDARD" if _campaign else "LIGHTS  /  STANDARD", Rect2(1576, 914, 272, 32))
	_light_button.name = "LightingPreview"
	_light_button.pressed.connect(toggle_lighting)

func _build_footer() -> void:
	box(Rect2(0, 998, 1920, 82), Style.BG)
	box(Rect2(48, 998, 1824, 1), Style.LINE)
	if _campaign:
		label("YOUR BUNKER", Rect2(48, 1008, 320, 25), 18, CREAM, true)
		label("Select a room, then choose its action", Rect2(48, 1043, 360, 22), 11, MUTED)
		_notice = label("", Rect2(436, 1009, 510, 58), 11, MUTED)
		_notice.name = "LocalNotice"
		_notice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		for item: Array in [["LocalLoadout", &"loadout", "TAB  STASH / LOADOUT", 980],
			["LocalDeploy", &"maps", "M  RAID BRIEFING", 1280], ["LocalTasks", &"tasks", "T  TASKS", 1580]]:
			var shortcut := button(item[2], Rect2(item[3], 1017, 280, 36))
			shortcut.name = item[0]
			shortcut.pressed.connect(_request_action.bind(item[1]))
			_shortcuts[item[1]] = shortcut
		var retry := button("RETRY SAVE", Rect2(1332, 118, 200, 26))
		retry.name = "RetrySave"
		retry.hide()
		retry.pressed.connect(_request_action.bind(&"retry_save"))
		return
	label("INSPECT YOUR HIDEOUT", Rect2(48, 1018, 340, 27), 18, CREAM, true)
	label("Click a room or facility to inspect", Rect2(400, 1022, 450, 22), 12, MUTED)
	label("BUILD  /  CRAFT  /  UPGRADE", Rect2(1110, 1014, 400, 20), 12, MUTED)
	label("Systems locked — layout inspection only", Rect2(1110, 1039, 650, 20), 11, MUTED)
	label("BUNKER 04", Rect2(1760, 1021, 120, 22), 13, ACCENT)

func select_room(id: String) -> bool:
	if not _buttons.has(id):
		return false
	var room: Dictionary = {}
	for item: Dictionary in world.layout["rooms"]:
		if item["id"] == id:
			room = item
	current_room = id
	_number.text = "AREA " + String(room["number"]) + "  /  INSPECTION"
	_heading.text = room["title"]
	_description.text = room["description"]
	_hero.texture = world.assets[room["station"]]
	# Integer 4x preview of an existing asset; the world remains exact 3x.
	_hero.size = _hero.texture.get_size() * 4
	_hero.position = Vector2(1712, 685) - _hero.size * 0.5
	var r: Array = room["rect"]
	_outline.position = Vector2(r[0] * 3 + 3, r[1] * 3 + 3)
	_outline.size = Vector2(r[2] * 3 - 6, r[3] * 3 - 6)
	for key: String in _buttons:
		var b: Button = _buttons[key]
		b.add_theme_color_override("font_color", ACCENT if key == id else MUTED)
		b.add_theme_stylebox_override("normal", style(Color("292820") if key == id else Style.PANEL, Color("8e7145") if key == id else Color("293130")))
	_sync_campaign_room()
	return true

func _choose_room(id: String) -> void:
	if not _can_interact(): return
	if select_room(id) and _campaign: room_selected.emit(id)

func toggle_lighting() -> void:
	if not _can_interact(): return
	emergency = not emergency
	_material.set_shader_parameter("emergency", emergency)
	_light_button.text = ("PREVIEW LIGHTS / " if _campaign else "LIGHTS  /  ") + ("EMERGENCY" if emergency else "STANDARD")

func _gui_input(event: InputEvent) -> void:
	if not is_visible_in_tree() or not _can_interact():
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		var id := world.room_at(event.position / 3.0)
		if not id.is_empty():
			_choose_room(id)
			accept_event()

func box(rect: Rect2, color: Color) -> ColorRect:
	var node := ColorRect.new()
	node.position = rect.position
	node.size = rect.size
	node.color = color
	node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(node)
	return node

func label(text: String, rect: Rect2, font_size: int, color: Color, bold := false) -> Label:
	var node := Label.new()
	node.position = rect.position
	node.size = rect.size
	node.text = text
	node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	node.add_theme_font_override("font", _bold if bold else _mono)
	node.add_theme_font_size_override("font_size", font_size)
	node.add_theme_color_override("font_color", color)
	add_child(node)
	return node

func button(text: String, rect: Rect2) -> Button:
	var node := Button.new()
	node.position = rect.position
	node.size = rect.size
	node.text = text
	node.add_theme_font_override("font", _mono)
	node.add_theme_font_size_override("font_size", 12)
	node.add_theme_color_override("font_color", MUTED)
	node.add_theme_color_override("font_hover_color", CREAM)
	node.add_theme_color_override("font_focus_color", CREAM)
	node.add_theme_stylebox_override("normal", style(Style.PANEL, Style.LINE))
	node.add_theme_stylebox_override("hover", style(Color("303329"), ACCENT))
	node.add_theme_stylebox_override("pressed", style(Color("383326"), ACCENT))
	node.add_theme_stylebox_override("focus", style(Color.TRANSPARENT, ACCENT))
	add_child(node)
	return node

func style(fill: Color, border: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = fill
	s.border_color = border
	s.set_border_width_all(1)
	s.content_margin_left = 12
	s.content_margin_right = 12
	return s


func _section_requested(route: String) -> void:
	var command: StringName = {"bunker":&"return_home", "inventory":&"loadout", "tasks":&"tasks", "maps":&"maps", "settings":&"controls"}.get(route, &"")
	_request_action(command)
