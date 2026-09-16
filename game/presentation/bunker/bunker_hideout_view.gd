class_name ZBunkerHideoutView
extends Control
## The production bunker presentation, also instantiated by native capture.
## Selection and lighting are local view state. There are no gameplay writes.
signal menu_requested
## Emitted with a room id when the operator walks up to that room's station.
signal station_entered(room_id: String)
signal station_left
const WorldScene = preload("res://game/presentation/bunker/bunker_world.tscn")
const LIGHTING = preload("res://game/presentation/bunker/bunker_lighting.gdshader")
const CREAM := Color("e6e3d5")
const MUTED := Color("858e89")
const ACCENT := Color("d1a05c")
var world: ZBunkerHideoutWorld
var surface: SubViewport
var current_room := "workshop"
var emergency := false
var operator: ZBunkerOperator
var _station_room: String = ""
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
	box(Rect2(0, 0, 1920, 1080), Color("080c0d"))
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
	select_room("workshop")


## Put the operator in the hideout so it can be walked rather than only
## inspected. Presentation only; the bunker runs no raid authority.
func enable_walk(at: Vector2 = Vector2(264, 150)) -> bool:
	if operator != null or world == null or not world.valid:
		return false
	var walker := ZBunkerOperator.new()
	walker.name = "Operator"
	world.add_child(walker)
	if not walker.configure(world, _nearest_free(at)):
		walker.queue_free()
		return false
	operator = walker
	set_process(true)
	return true


## The authored spawn may sit inside a prop footprint after a layout edit, so
## settle onto the closest free floor rather than starting the walk stuck.
func _nearest_free(at: Vector2) -> Vector2:
	if world.is_walkable(at):
		return at
	for radius: int in range(1, 64):
		for step: int in range(0, 360, 15):
			var probe := at + Vector2(radius, 0).rotated(deg_to_rad(step))
			if world.is_walkable(probe):
				return probe
	return at


func _process(delta: float) -> void:
	if operator == null:
		return
	var direction := Vector2(
		float(Input.is_physical_key_pressed(KEY_D)) - float(Input.is_physical_key_pressed(KEY_A)),
		float(Input.is_physical_key_pressed(KEY_S)) - float(Input.is_physical_key_pressed(KEY_W)))
	operator.walk(direction, delta)
	var room := world.room_at(operator.position)
	# Following the operator keeps the inspector describing where they stand.
	if room != _station_room:
		_station_room = room
		if room.is_empty():
			station_left.emit()
		else:
			select_room(room)
			station_entered.emit(room)

func _build_header() -> void:
	box(Rect2(0, 0, 1920, 58), Color("0e1213"))
	box(Rect2(48, 57, 1824, 1), Color("303736"))
	label("ZERKOV", Rect2(48, 12, 180, 34), 27, CREAM, true)
	label("/     HIDEOUT", Rect2(212, 23, 220, 20), 12, MUTED)
	label("B1  /  SERVICE LEVEL", Rect2(780, 22, 400, 20), 12, MUTED)
	var menu := button("ESC  MENU", Rect2(1744, 14, 128, 32))
	menu.name = "Menu"
	menu.pressed.connect(func(): menu_requested.emit())
	label("THE BUNKER", Rect2(48, 72, 330, 45), 36, CREAM, true)
	label("04", Rect2(378, 75, 80, 43), 33, ACCENT, true)
	label("A SHELTER BETWEEN RAIDS", Rect2(470, 94, 430, 20), 12, MUTED)
	label("OFFLINE  /  VISUAL PREVIEW", Rect2(1552, 89, 340, 22), 12, ACCENT)

func _build_inspector() -> void:
	var panel := Panel.new()
	panel.name = "FacilityInspector"
	panel.position = Vector2(1552, 148)
	panel.size = Vector2(320, 820)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_theme_stylebox_override("panel", style(Color("101718"), Color("303b3a")))
	add_child(panel)
	label("FACILITIES", Rect2(1576, 168, 220, 26), 16, CREAM, true)
	label("06", Rect2(1820, 170, 36, 22), 13, MUTED)
	var index := 0
	for room: Dictionary in world.layout["rooms"]:
		var id: String = room["id"]
		var b := button(String(room["number"]) + "     " + String(room["name"]), Rect2(1576, 210 + index * 43, 272, 35))
		b.name = "Select_" + id
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.pressed.connect(select_room.bind(id))
		_buttons[id] = b
		index += 1
	box(Rect2(1576, 482, 272, 1), Color("303b3a"))
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
	_light_button = button("LIGHTS  /  STANDARD", Rect2(1576, 914, 272, 32))
	_light_button.name = "LightingPreview"
	_light_button.pressed.connect(toggle_lighting)

func _build_footer() -> void:
	box(Rect2(0, 998, 1920, 82), Color("0c1112"))
	box(Rect2(48, 998, 1824, 1), Color("303b3a"))
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
		b.add_theme_stylebox_override("normal", style(Color("292820") if key == id else Color("101718"), Color("8e7145") if key == id else Color("293130")))
	return true

func toggle_lighting() -> void:
	emergency = not emergency
	_material.set_shader_parameter("emergency", emergency)
	_light_button.text = "LIGHTS  /  EMERGENCY" if emergency else "LIGHTS  /  STANDARD"

func _gui_input(event: InputEvent) -> void:
	if not is_visible_in_tree():
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		var id := world.room_at(event.position / 3.0)
		if not id.is_empty():
			select_room(id)
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
	node.add_theme_stylebox_override("normal", style(Color("141b1c"), Color("36403e")))
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
