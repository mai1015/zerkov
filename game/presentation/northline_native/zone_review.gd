extends Node2D
## Inspection UI only. The level is a saved scene, not rebuilt from JSON.
## Logical world coordinates are preserved; rendering uses the native output.
const EXACT := Vector2i(1920,1080)
const DETAIL_ZOOM := Vector2(3,3)
const OVERVIEW_ZOOM := Vector2(0.5,0.5)
@onready var world: Node2D = $NorthlineWorld
@onready var camera: Camera2D = $Camera2D
@onready var walker: CharacterBody2D = $NorthlineWorld/WorldProps/ReviewWalker
@onready var district_markers: Array[Node] = $NorthlineWorld/DistrictMarkers.get_children()
var overview := false
var walking := false
var dragging := false
var routes_visible := false
var district_index := 3
var last_detail := Vector2(1288,638)
var _lights: Array[PointLight2D] = []
var _labels: Array[Label] = []
var _exit_labels: Array[Label] = []
var _last_light_bounds := Rect2()

func _ready() -> void:
	$HUD/Top/Overview.pressed.connect(toggle_overview)
	$HUD/Top/Walk.pressed.connect(toggle_walk)
	$HUD/Top/Routes.pressed.connect(toggle_routes)
	for i: int in range(district_markers.size()):
		var b := $HUD/Districts.get_node("D%d"%i) as Button
		b.text = str(district_markers[i].get_meta("title"))
		b.pressed.connect(select_district.bind(i))
		var label := Label.new()
		label.text = b.text
		label.add_theme_font_size_override("font_size",15)
		label.add_theme_color_override("font_color",Color("f0d99e"))
		label.add_theme_color_override("font_shadow_color",Color("121c18"))
		label.add_theme_constant_override("shadow_outline_size",8)
		label.mouse_filter=Control.MOUSE_FILTER_IGNORE
		$HUD/Annotations.add_child(label);_labels.append(label)
	for marker: Node2D in $NorthlineWorld/ReviewExitMarkers.get_children():
		var label := Label.new()
		label.text = "+ " + str(marker.get_meta("title"))
		label.add_theme_font_size_override("font_size",13)
		label.add_theme_color_override("font_color",Color("b9d5b9"))
		label.add_theme_color_override("font_shadow_color",Color("121c18"))
		label.add_theme_constant_override("shadow_outline_size",6)
		label.mouse_filter=Control.MOUSE_FILTER_IGNORE
		$HUD/Annotations.add_child(label);_exit_labels.append(label)
	for node: Node in world.get_node("Lighting").get_children():
		if node is PointLight2D: _lights.append(node)
	set_overview(true)

func bounds() -> Rect2:
	return world.get_meta("authored_world_bounds")

func world_at(screen_at: Vector2) -> Vector2:
	return (screen_at-Vector2(EXACT)/2.0)/camera.zoom+camera.position

func screen_at(world_at_position: Vector2) -> Vector2:
	return (world_at_position-camera.position)*camera.zoom+Vector2(EXACT)/2.0

func frame_at(at: Vector2) -> void:
	var half := Vector2(EXACT)/camera.zoom/2.0
	var area := bounds()
	camera.position = area.get_center() if overview else at.clamp(area.position+half,area.end-half).round()
	camera.force_update_scroll()
	update_lights()
	update_annotations()

func set_overview(value: bool) -> void:
	dragging=false
	if value and not overview: last_detail=camera.position
	overview=value
	camera.zoom=OVERVIEW_ZOOM if value else DETAIL_ZOOM
	walker.enabled=walking and not value
	walker.visible=walking and not value
	world.get_node("ReviewRoutes").visible=routes_visible
	frame_at(bounds().get_center() if value else last_detail)
	$HUD/Districts.visible=value
	refresh()

func toggle_overview() -> void:
	set_overview(not overview)

func select_district(index: int) -> void:
	if index<0 or index>=district_markers.size():return
	district_index=index
	set_walking(false)
	if overview:set_overview(false)
	frame_at((district_markers[index] as Node2D).global_position)
	last_detail=camera.position
	refresh()

func set_walking(value: bool) -> void:
	walking=value
	if value and overview:set_overview(false)
	walker.enabled=value and not overview
	walker.animate=value
	walker.visible=value and not overview
	if value:frame_at(walker.position)
	refresh()

func toggle_walk() -> void:
	set_walking(not walking)

func toggle_routes() -> void:
	routes_visible=not routes_visible
	world.get_node("ReviewRoutes").visible=routes_visible
	refresh()

func update_lights() -> void:
	var area:=Rect2(camera.position-Vector2(EXACT)/camera.zoom/2,Vector2(EXACT)/camera.zoom)
	if area==_last_light_bounds:return
	_last_light_bounds=area
	for light:PointLight2D in _lights:
		var radius:=light.texture.get_width()*light.texture_scale/2.0
		light.enabled=not overview and area.grow(radius).has_point(light.global_position)

func update_annotations() -> void:
	for i:int in range(_labels.size()):
		_labels[i].visible=overview
		_labels[i].position=screen_at((district_markers[i] as Node2D).global_position)+Vector2(8,-18)
	var markers:=world.get_node("ReviewExitMarkers").get_children()
	for i:int in range(_exit_labels.size()):
		_exit_labels[i].visible=overview
		_exit_labels[i].position=screen_at((markers[i] as Node2D).global_position)+Vector2(-8,-20)
	var box:Line2D=$HUD/Footprint
	box.visible=overview
	var r:=Rect2(screen_at(last_detail-Vector2(320,180)),Vector2(640,360)*camera.zoom)
	box.points=PackedVector2Array([r.position,Vector2(r.end.x,r.position.y),r.end,Vector2(r.position.x,r.end.y),r.position])

func refresh() -> void:
	$HUD/Top/Overview.text="M  RETURN TO DETAIL" if overview else "M  FULL MAP"
	$HUD/Top/Walk.text="P  CAMERA" if walking else "P  WALKTHROUGH"
	$HUD/Top/Routes.text="TAB  HIDE ROUTES" if routes_visible else "TAB  ROUTES"
	$HUD/Top/Subtitle.text="ALL 9 DISTRICTS  /  19 INTERIORS  /  ORIGINAL SHEETS  /  SAVED GODOT TILEMAPS" if overview else str(district_markers[district_index].get_meta("title"))+"   |   NATIVE 1920 x 1080 / ORIGINAL SOURCE DETAIL"
	$HUD/Bottom/Help.text=("Click map / district: inspect   |   Outlined box: normal camera footprint" if overview else "WASD: %s   SHIFT: faster   Q/E: district   M: full map"%("walk" if walking else "pan / drag"))+"    |    ENVIRONMENT REVIEW - no live raid / loot / extraction"

func _process(delta: float) -> void:
	if dragging and not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):dragging=false
	if overview:return
	if walking:frame_at(walker.position)
	elif not dragging:
		var move:=Vector2(float(Input.is_physical_key_pressed(KEY_D))-float(Input.is_physical_key_pressed(KEY_A)),float(Input.is_physical_key_pressed(KEY_S))-float(Input.is_physical_key_pressed(KEY_W)))
		if not move.is_zero_approx():frame_at(camera.position+move.normalized()*delta*(600.0 if Input.is_physical_key_pressed(KEY_SHIFT) else 180.0))

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.physical_keycode:
			KEY_M:toggle_overview()
			KEY_HOME:set_overview(true)
			KEY_P:toggle_walk()
			KEY_TAB:toggle_routes()
			KEY_Q:select_district(posmod(district_index-1,district_markers.size()))
			KEY_E:select_district((district_index+1)%district_markers.size())
			_:return
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and event.button_index==MOUSE_BUTTON_LEFT:
		if overview and event.pressed:
			var at:=world_at(event.position)
			if bounds().has_point(at):
				var best:=0;var distance:=INF
				for i:int in range(district_markers.size()):
					var d:=at.distance_squared_to((district_markers[i] as Node2D).global_position)
					if d<distance:distance=d;best=i
				select_district(best);frame_at(at)
		elif not walking:dragging=event.pressed
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and dragging and not walking and not overview:
		frame_at(camera.position-event.relative/DETAIL_ZOOM)
		get_viewport().set_input_as_handled()
