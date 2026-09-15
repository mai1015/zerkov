class_name ZNorthlineZoneView
extends Control
## Separate review scene: overview, camera exploration and collision walkthrough.
## None of these controls is an admission path to the production raid authority.
const World = preload("res://game/presentation/northline_zone/zone_world.gd")
const Overlay = preload("res://game/presentation/northline_zone/zone_overlay.gd")
const Walker = preload("res://game/presentation/northline_zone/review_walker.gd")
const OUTPUT := Vector2i(1920,1080)
const WORLD := Vector2i(640,360)
var data: Dictionary
var world: Node2D
var surface: SubViewport
var camera: Camera2D
var overlay: Control
var walker: CharacterBody2D
var overview: bool = false
var walk_mode: bool = false
var routes_visible: bool = false
var dragging: bool = false
var drag_distance: float = 0
var sector_index: int = 3
var last_detail_position := Vector2(1288,638)
var overview_button: Button
var walking_button: Button
var routes_button: Button
var subtitle: Label
var footer: Label
var sector_buttons: Array[Button] = []

func _ready() -> void:
	data = JSON.parse_string(FileAccess.get_file_as_string("res://game/presentation/northline_zone/zone.json"))
	mouse_filter = Control.MOUSE_FILTER_PASS
	var bg := ColorRect.new()
	bg.color = Color("131e18")
	bg.size = Vector2(OUTPUT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	surface = SubViewport.new()
	surface.name = "World640x360"
	surface.size = WORLD
	surface.canvas_item_default_texture_filter = Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST
	surface.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	surface.transparent_bg = true
	add_child(surface)
	world = World.new()
	surface.add_child(world)
	world.configure(data)
	camera = Camera2D.new()
	camera.position_smoothing_enabled = false
	camera.zoom = Vector2.ONE
	surface.add_child(camera)
	walker = Walker.new()
	walker.position = Vector2(data["spawn"][0],data["spawn"][1])
	world.props_root.add_child(walker)
	walker.visible = false
	var image := TextureRect.new()
	image.name = "NativeWorld3x"
	image.texture = surface.get_texture()
	image.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	image.stretch_mode = TextureRect.STRETCH_SCALE
	image.size = Vector2(OUTPUT)
	image.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(image)
	overlay = Overlay.new()
	overlay.view = self
	overlay.size = Vector2(OUTPUT)
	add_child(overlay)
	panel(Rect2(0,0,1920,86),Color(0.023,0.04,0.031,0.97))
	panel(Rect2(0,1014,1920,66),Color(0.023,0.04,0.031,0.97))
	label("ZERKOV  /  NORTHLINE EXCLUSION ZONE",Vector2(30,11),25,Color("e7e1c9"))
	subtitle = label("",Vector2(32,49),13,Color("a5b49c"))
	overview_button = button("M  FULL MAP",Rect2(1245,22,206,38))
	overview_button.pressed.connect(toggle_overview)
	walking_button = button("P  WALKTHROUGH",Rect2(1464,22,228,38))
	walking_button.pressed.connect(toggle_walk)
	routes_button = button("TAB  ROUTES",Rect2(1705,22,183,38))
	routes_button.pressed.connect(toggle_routes)
	for i: int in range(data["sectors"].size()):
		var name_text: String = str(data["sectors"][i]["name"])
		var b := button(name_text,Rect2(30,104+i*40,247,34))
		b.pressed.connect(select_sector.bind(i))
		sector_buttons.append(b)
	footer = label("",Vector2(30,1031),13,Color("b8c1ae"))
	select_sector(3)
	toggle_overview()

func panel(r: Rect2, c: Color) -> void:
	var p := ColorRect.new()
	p.position = r.position
	p.size = r.size
	p.color = c
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(p)

func label(text: String, at: Vector2, px: int, c: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.position = at
	l.add_theme_font_size_override("font_size",px)
	l.add_theme_color_override("font_color",c)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(l)
	return l

func button(text: String, r: Rect2) -> Button:
	var b := Button.new()
	b.text = text
	b.position = r.position
	b.size = r.size
	b.add_theme_font_size_override("font_size",13)
	for state: String in ["normal","hover","pressed","focus"]:
		var style := StyleBoxFlat.new()
		style.bg_color = Color(0.1,0.15,0.116,0.97) if state in ["hover","pressed"] else Color(0.035,0.065,0.045,0.94)
		style.set_border_width_all(1)
		style.border_color = Color("d7b677") if state in ["hover","pressed","focus"] else Color("4b6350")
		b.add_theme_stylebox_override(state,style)
	b.add_theme_color_override("font_color",Color("d3d7bd"))
	add_child(b)
	return b

func select_sector(index: int) -> void:
	if index < 0 or index >= data["sectors"].size():
		return
	sector_index = index
	if overview:
		toggle_overview()
	if walk_mode:
		toggle_walk()
	var at: Array = data["sectors"][index]["at"]
	camera.position = Vector2(at[0],at[1])
	pan(Vector2.ZERO)
	refresh_text()

func toggle_overview() -> void:
	dragging = false
	if overview:
		overview = false
		camera.zoom = Vector2.ONE
		camera.position = last_detail_position
		pan(Vector2.ZERO)
	else:
		last_detail_position = camera.position
		overview = true
		camera.zoom = Vector2.ONE / 6.0
		camera.position = Vector2(1344,896)
		camera.force_update_scroll()
	walker.enabled = walk_mode and not overview
	world.set_overview(overview)
	world.update_visible_bounds(Rect2(camera.position-Vector2(320,180)/camera.zoom,Vector2(WORLD)/camera.zoom))
	for b: Button in sector_buttons:
		b.visible = overview
	refresh_text()

func toggle_walk() -> void:
	walk_mode = not walk_mode
	walker.enabled = walk_mode
	walker.animate = walk_mode
	walker.visible = walk_mode
	if walk_mode and overview:
		toggle_overview()
	if walk_mode:
		camera.position = walker.position
		pan(Vector2.ZERO)
	refresh_text()

func toggle_routes() -> void:
	routes_visible = not routes_visible
	refresh_text()

func pan(offset: Vector2) -> void:
	if overview:
		return
	var limit := Vector2(data["size"][0]-320,data["size"][1]-180)
	camera.position = (camera.position+offset).clamp(Vector2(320,180),limit).round()
	camera.force_update_scroll()
	world.update_visible_bounds(Rect2(camera.position-Vector2(320,180),Vector2(WORLD)))
	overlay.queue_redraw()

func overview_at(screen_position: Vector2) -> Vector2:
	return (screen_position-Vector2(960,540))/(camera.zoom*3.0)+camera.position

func refresh_text() -> void:
	if subtitle == null:
		return
	subtitle.text = "2688 x 1792 WORLD PX  /  16x ORIGINAL AREA  /  9 DISTRICTS  /  19 INTERIORS" if overview else str(data["sectors"][sector_index]["name"]) + "    |    " + str(data["sectors"][sector_index]["description"])
	overview_button.text = "M  RETURN TO DETAIL" if overview else "M  FULL MAP"
	walking_button.text = "P  CAMERA MODE" if walk_mode else "P  WALKTHROUGH"
	routes_button.text = "TAB  HIDE ROUTES" if routes_visible else "TAB  ROUTES"
	footer.text = ("Click map / sector: inspect   |   Outlined box: one normal camera view.  " if overview else "WASD: " + ("walk   SHIFT: faster   " if walk_mode else "pan   Drag: inspect   ") + "Q / E: sector   M: full map   ") + "|   ENVIRONMENT REVIEW - no live AI, combat, loot or extraction."
	overlay.queue_redraw()

func _process(delta: float) -> void:
	if camera == null:
		return
	if dragging and not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		dragging = false
	if walk_mode and not overview:
		camera.position = walker.position.round()
		pan(Vector2.ZERO)
	elif not overview:
		var input := Vector2(float(Input.is_physical_key_pressed(KEY_D))-float(Input.is_physical_key_pressed(KEY_A)),float(Input.is_physical_key_pressed(KEY_S))-float(Input.is_physical_key_pressed(KEY_W)))
		if input != Vector2.ZERO:
			pan(input.normalized()*delta*(720 if Input.is_physical_key_pressed(KEY_SHIFT) else 250))

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.physical_keycode:
			KEY_M: toggle_overview()
			KEY_P: toggle_walk()
			KEY_TAB: toggle_routes()
			KEY_Q: select_sector(posmod(sector_index-1,data["sectors"].size()))
			KEY_E: select_sector((sector_index+1)%data["sectors"].size())
		get_viewport().set_input_as_handled()
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if overview and event.pressed:
			var at := overview_at(event.position)
			if Rect2(0,0,data["size"][0],data["size"][1]).has_point(at):
				last_detail_position = at
				toggle_overview()
		elif not walk_mode:
			dragging = event.pressed
	if event is InputEventMouseMotion and dragging and not overview and not walk_mode:
		pan(-event.relative/3.0)
