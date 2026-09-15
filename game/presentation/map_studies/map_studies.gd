class_name ZExtractionMapStudies
extends Control
## Preview-only camera input. This scene is not mounted in the production raid.
const World = preload("res://game/presentation/map_studies/map_study_world.gd")
const OUTPUT := Vector2i(1920,1080)
const WORLD := Vector2i(640,360)
var maps: Array=[]
var map_index:int=0
var point_index:int=0
var surface:SubViewport
var world:ZExtractionMapStudyWorld
var camera:Camera2D
var heading:Label
var detail:Label
var footer:Label
var map_buttons:Array[Button]=[]
var poi_buttons:Array[Button]=[]
var tactical_button:Button
var tactical:bool=false
var dragging:bool=false

func _ready() -> void:
	maps=JSON.parse_string(FileAccess.get_file_as_string("res://game/presentation/map_studies/maps.json"))["maps"]
	mouse_filter=Control.MOUSE_FILTER_PASS
	surface=SubViewport.new();surface.name="World640x360";surface.size=WORLD
	surface.canvas_item_default_texture_filter=Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST
	surface.render_target_update_mode=SubViewport.UPDATE_ALWAYS
	add_child(surface)
	world=World.new();surface.add_child(world)
	camera=Camera2D.new();camera.position_smoothing_enabled=false;camera.zoom=Vector2.ONE;surface.add_child(camera)
	var image:=TextureRect.new();image.name="NativeWorld3x";image.texture=surface.get_texture();image.texture_filter=CanvasItem.TEXTURE_FILTER_NEAREST
	image.expand_mode=TextureRect.EXPAND_IGNORE_SIZE;image.stretch_mode=TextureRect.STRETCH_SCALE
	image.size=Vector2(OUTPUT);image.mouse_filter=Control.MOUSE_FILTER_IGNORE;add_child(image)
	var vignette:=ColorRect.new();vignette.size=Vector2(OUTPUT);vignette.mouse_filter=Control.MOUSE_FILTER_IGNORE
	var shader:=Shader.new();shader.code="shader_type canvas_item; void fragment(){vec2 d=UV-vec2(0.5); float a=smoothstep(0.28,0.71,length(d));COLOR=vec4(0.025,0.045,0.04,a*0.50);}"
	var mat:=ShaderMaterial.new();mat.shader=shader;vignette.material=mat;add_child(vignette)
	_panel(Rect2(0,0,1920,85),Color(0.028,0.045,0.043,0.95))
	_panel(Rect2(0,1018,1920,62),Color(0.028,0.045,0.043,0.96))
	heading=_label("",Vector2(32,12),26,Color("e3dfc8"))
	detail=_label("",Vector2(32,47),13,Color("9fac9f"))
	for i:int in range(2):
		var b:=_button("0%d  %s" % [i+1,maps[i]["title"]],Rect2(1270+i*305,24,280,36))
		b.pressed.connect(select_map.bind(i));map_buttons.append(b)
	footer=_label("",Vector2(32,1034),13,Color("adb7a7"))
	tactical_button=_button("TAB  ROUTE STUDY",Rect2(1680,1030,208,34));tactical_button.pressed.connect(toggle_tactical)
	for i:int in range(3):
		var b:=_button("",Rect2(32+i*260,94,246,30));b.pressed.connect(select_point.bind(i));poi_buttons.append(b)
	select_map(0)

func _panel(r:Rect2,c:Color) -> void:
	var p:=ColorRect.new();p.position=r.position;p.size=r.size;p.color=c;p.mouse_filter=Control.MOUSE_FILTER_IGNORE;add_child(p)

func _label(text:String,at:Vector2,size_px:int,c:Color) -> Label:
	var l:=Label.new();l.text=text;l.position=at;l.add_theme_font_size_override("font_size",size_px);l.add_theme_color_override("font_color",c);l.mouse_filter=Control.MOUSE_FILTER_IGNORE;add_child(l);return l

func _button(text:String,r:Rect2) -> Button:
	var b:=Button.new();b.text=text;b.position=r.position;b.size=r.size;b.add_theme_font_size_override("font_size",13)
	for state:String in ["normal","hover","pressed","focus"]:
		var style:=StyleBoxFlat.new();style.bg_color=Color("24332e") if state in ["hover","pressed"] else Color(0.06,0.09,0.075,0.90)
		style.set_border_width_all(1);style.border_color=Color("a9976a") if state in ["hover","focus","pressed"] else Color("546155")
		b.add_theme_stylebox_override(state,style)
	b.add_theme_color_override("font_color",Color("d1d5be"));add_child(b);return b

func select_map(index:int) -> void:
	if index<0 or index>=maps.size():return
	map_index=index;world.configure(maps[index]);world.set_tactical(tactical)
	heading.text="ZERKOV  /  " + maps[index]["title"]
	detail.text=maps[index]["subtitle"] + "   |   ORIGINAL ENVIRONMENT STUDY"
	for i:int in range(3):poi_buttons[i].text="%d  %s" % [i+1,maps[index]["camera_points"][i]["name"]]
	for i:int in range(2):map_buttons[i].disabled=i==index
	select_point(0)

func select_point(index:int) -> void:
	if index<0 or index>=maps[map_index]["camera_points"].size():return
	point_index=index
	var at:Array=maps[map_index]["camera_points"][index]["at"]
	camera.position=Vector2(at[0],at[1]).round();camera.force_update_scroll()
	_refresh_footer()

func toggle_tactical() -> void:
	tactical=not tactical;world.set_tactical(tactical)
	tactical_button.text="TAB  HIDE ROUTES" if tactical else "TAB  ROUTE STUDY"
	_refresh_footer()

func _refresh_footer() -> void:
	footer.text="WASD / drag: inspect    Q / E: sector    1 / 2: map    |    " + ("AMBER: exposed / TEAL: covered. Proposed exits, no active extraction." if tactical else "Art + layout preview. No live combat, loot or extraction.")

func _process(delta:float) -> void:
	if camera==null:return
	var movement:=Vector2(float(Input.is_physical_key_pressed(KEY_D))-float(Input.is_physical_key_pressed(KEY_A)),float(Input.is_physical_key_pressed(KEY_S))-float(Input.is_physical_key_pressed(KEY_W)))
	if movement!=Vector2.ZERO:pan(movement.normalized()*180*delta)

func pan(offset:Vector2) -> void:
	var size:Array=maps[map_index]["size"]
	camera.position=(camera.position+offset).clamp(Vector2(320,180),Vector2(size[0]-320,size[1]-180)).round()
	camera.force_update_scroll()

func _unhandled_input(event:InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.physical_keycode:
			KEY_1: select_map(0)
			KEY_2: select_map(1)
			KEY_TAB: toggle_tactical()
			KEY_Q: select_point(posmod(point_index-1,3))
			KEY_E: select_point((point_index+1)%3)
	if event is InputEventMouseButton and event.button_index==MOUSE_BUTTON_LEFT:dragging=event.pressed
	if event is InputEventMouseMotion and dragging:pan(-event.relative/3.0)
