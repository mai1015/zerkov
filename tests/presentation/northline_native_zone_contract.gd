extends SceneTree
## Native saved level and collision. Legacy JSON is a comparison fixture ONLY.
const VIEW = preload("res://game/presentation/northline_native/zone_review.tscn")
const Exact1080CaptureGuard = preload("res://game/presentation/exact_1080_capture_guard.gd")
const EXACT := Vector2i(1920,1080)
var output := ""
var edited := ""
var mode := "full"
var checks := 0
var failures := 0
var metrics: Dictionary = {}

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, label: String) -> void:
	checks+=1
	if not ok:
		failures+=1
		push_error("NATIVE_ZONE_ASSERT: "+label)

func frames() -> void:
	for _i:int in range(4):await process_frame
	if DisplayServer.get_name()!="headless":await RenderingServer.frame_post_draw

func key(code: int, down := true) -> void:
	var e:=InputEventKey.new();e.keycode=code;e.physical_keycode=code;e.pressed=down
	Input.parse_input_event(e);await process_frame

func click(at: Vector2) -> void:
	for down: bool in [true,false]:
		var e:=InputEventMouseButton.new();e.position=at;e.global_position=at;e.button_index=MOUSE_BUTTON_LEFT;e.pressed=down
		root.push_input(e)
	await frames()

func capture(name_text: String) -> void:
	if output.is_empty() or DisplayServer.get_name()=="headless":return
	await frames()
	var image:=root.get_texture().get_image()
	check(Exact1080CaptureGuard.accepts(root,root,image),"actual output "+name_text)
	if not Exact1080CaptureGuard.accepts(root,root,image):
		return
	var result:=image.save_png(output.path_join(name_text+".png"))
	check(result==OK,"save raw native "+name_text)

func all_nodes(node: Node) -> Array[Node]:
	var result: Array[Node]=[]
	for child:Node in node.get_children():
		result.append(child);result.append_array(all_nodes(child))
	return result

func find_prop(world: Node, id: String) -> Node2D:
	for group: Node in world.get_node("WorldProps").get_children():
		for node: Node in group.get_children():
			if node.get_meta("legacy_prop_id","")==id:return node
	return null

func body_rect(body: Node2D) -> Rect2:
	var c:CollisionShape2D=body.get_node("CollisionShape2D")
	var size:Vector2=(c.shape as RectangleShape2D).size
	return Rect2(c.global_position-size/2,size)

func old_rect(a: Array) -> Rect2:
	return Rect2(a[0],a[1],a[2],a[3])

func run() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--output="):output=arg.trim_prefix("--output=")
		if arg.begins_with("--edited="):edited=arg.trim_prefix("--edited=")
		if arg.begins_with("--mode="):mode=arg.trim_prefix("--mode=")
	root.borderless=true;root.size=EXACT
	create_timer(150).timeout.connect(func():check(false,"bounded native watchdog");finish())
	await frames()
	check(root.size==EXACT and root.get_visible_rect().size==Vector2(EXACT),"native 1920x1080")
	if DisplayServer.get_name()!="headless":check(Exact1080CaptureGuard.accepts(root,root,root.get_texture().get_image()),"output before mount")
	if failures:finish();return
	if mode=="reopen":
		var scene=load(edited).instantiate()
		root.add_child(scene);await frames()
		check(scene.get_node("Terrain/FreightFloorBounds/FreightFloor").get_cell_source_id(Vector2i(5,5))==12,"painted tile reopened")
		var p:=find_prop(scene,"northline.zone.prop.0052")
		check(p!=null and p.position==Vector2(1031,597),"moved prop reopened")
		if p!=null:check(p.get_node("Footprint/CollisionShape2D").global_position==p.position+Vector2(0,-3),"collider follows reopened prop")
		scene.queue_free();await frames();finish();return
	var view=VIEW.instantiate()
	root.add_child(view);await frames()
	var world:Node2D=view.world
	check(world.get_script()==null,"saved world has no generator")
	check(root.find_children("*","SubViewport",true,false).is_empty(),"no low resolution world render")
	check(view.overview and view.district_markers.size()==9,"starts in nine-district overview")
	var legacy:Dictionary=JSON.parse_string(FileAccess.get_file_as_string("res://game/presentation/northline_zone/zone.json"))
	var atlas:Dictionary=JSON.parse_string(FileAccess.get_file_as_string("res://assets/world/map_studies/atlas.json"))
	var geometry:Array[Rect2]=[]
	var tiles_count:=0;var cells_count:=0;var buildings_count:=0;var scripts_count:=0
	for n:Node in all_nodes(world):
		if n==view.walker or view.walker.is_ancestor_of(n):continue
		if n.get_script()!=null:scripts_count+=1
		if n.has_meta("legacy_building_id"):buildings_count+=1
		if n is TileMapLayer:
			tiles_count+=1;cells_count+=n.get_used_cells().size()
			check(n.tile_set.resource_path.begins_with("res://game/world/northline_native/"),"shared external TileSet")
			check(n.scale==Vector2.ONE/3,"original-density layer scale")
		if n is StaticBody2D and n.has_meta("legacy_rect"):geometry.append(body_rect(n))
	check(scripts_count==0,"all authored map nodes native/script-free")
	check(buildings_count==19,"all 19 native interiors")
	check(tiles_count>=50 and cells_count>25000,"complete saved terrain rather than small slice")
	check(geometry.size()==legacy.collision_rects.size(),"no missing/duplicate static solids")
	for a:Array in legacy.collision_rects:check(geometry.has(old_rect(a)),"retained exact wall/fence/boundary "+str(a))
	var solid_props:=0
	for p:Dictionary in legacy.props:
		var node:=find_prop(world,str(p.id))
		check(node!=null,"retained prop "+str(p.id))
		if node==null:continue
		check(node.position==Vector2(p.foot[0],p.foot[1]),"unchanged prop placement")
		check(not node.scene_file_path.is_empty(),"reusable prop scene")
		var a:Dictionary=atlas.assets[str(p.asset)]
		var c:CollisionShape2D=node.get_node("Footprint/CollisionShape2D")
		check(c.shape.size==Vector2(a.footprint[0],a.footprint[1]) and c.position==Vector2(0,-float(a.footprint[1])/2),"unchanged prop footprint")
		var is_solid:bool=p.get("solid",true)
		check((node.get_node("Footprint").collision_layer==1)==is_solid,"preserved solid/decorative role")
		if is_solid:solid_props+=1
	check(solid_props==528 and legacy.props.size()==541,"all 541 placements / 528 solid props")
	check(world.get_node("GroundDetails").get_child_count()==1814,"all original ground details")
	check(world.get_node("ReviewExitMarkers").get_child_count()==4,"four review exits, not extraction triggers")
	for row:Dictionary in JSON.parse_string(FileAccess.get_file_as_string("res://assets/world/northline_native/source_manifest.json")).sources:
		var path:="res://"+str(row.path)
		var original:=Image.new()
		check(original.load_png_from_buffer(FileAccess.get_file_as_bytes(path))==OK,"decode original")
		var imported:Image=(load(path) as Texture2D).get_image()
		check(original.get_data()==imported.get_data() and original.get_size()==imported.get_size(),"original native RGBA retained")
	metrics={"tile_layers":tiles_count,"saved_cells":cells_count,"interiors":buildings_count,"props":541,"solid_props":solid_props,"static_solids":geometry.size()}
	print("NATIVE_ZONE_METRICS ",JSON.stringify(metrics))
	await capture("northline-native-full-map-1080")
	for i:int in range(9):
		view.select_district(i);await frames()
		check(view.camera.zoom==Vector2(3,3),"detail source density")
		check(Vector2(EXACT)/view.camera.zoom==Vector2(640,360),"same logical camera footprint")
		await capture("northline-native-"+str(legacy.sectors[i].id)+"-1080")
	view.set_overview(true);view.toggle_routes();await frames();await capture("northline-native-routes-1080")
	view.toggle_routes()
	await click(Vector2(120,281))
	check(not view.overview and view.district_index==4,"actual district-button input")
	root.gui_release_focus()
	await key(KEY_M);await key(KEY_M,false);check(view.overview,"actual overview key")
	await key(KEY_P);await key(KEY_P,false);check(view.walking and not view.overview,"actual walk-mode key")
	view.walker.enabled=false
	view.walker.position=Vector2(104,824);await physics_frame;await physics_frame
	view.walker.enabled=true
	await key(KEY_D)
	for _i:int in range(10):await physics_frame
	await key(KEY_D,false)
	check(view.walker.position.x>106,"actual movement input")
	view.walker.enabled=false;view.walker.animate=false
	for route:Dictionary in legacy.native_walk_routes:
		var points:Array=route.points
		view.walker.position=Vector2(points[0][0],points[0][1]);await physics_frame;await physics_frame
		var clear:=true;var steps:=0
		for point:Array in points.slice(1):
			var target:=Vector2(point[0],point[1])
			while view.walker.position.distance_to(target)>0.1 and steps<5000:
				steps+=1
				var hit=view.walker.move_and_collide((target-view.walker.position).limit_length(8))
				if hit!=null:
					clear=false;print("NATIVE_ZONE_ROUTE_BLOCKED ",route.id," at ",view.walker.position," collider ",hit.get_collider());break
			if not clear:break
		check(clear and steps<5000,"native cross-map collision route "+str(route.id))
		print("NATIVE_ZONE_ROUTE id=",route.id," steps=",steps," clear=",clear)
	view.walker.position=Vector2(360,52);await physics_frame
	check(view.walker.move_and_collide(Vector2(0,-80))!=null,"closed boundary still blocks")
	view.walker.position=Vector2(1112,790);view.walker.show_frame(false,0)
	view.select_district(3);view.set_walking(true);view.walker.enabled=false;view.frame_at(Vector2(1184,650));await frames()
	await capture("northline-native-walkthrough-1080")
	var pristine=(load("res://game/world/northline_native/zone/northline_world.tscn") as PackedScene).instantiate(PackedScene.GEN_EDIT_STATE_MAIN)
	pristine.get_node("Terrain/FreightFloorBounds/FreightFloor").set_cell(Vector2i(5,5),12,Vector2i(2,9))
	var moved:=find_prop(pristine,"northline.zone.prop.0052")
	check(moved!=null,"editor-test prop present")
	if moved!=null:moved.position=Vector2(1031,597)
	var packed:=PackedScene.new()
	check(packed.pack(pristine)==OK,"pack edited saved level")
	check(not edited.is_empty() and ResourceSaver.save(packed,edited)==OK,"save edit without generator")
	pristine.free();view.queue_free();await frames();finish()

func finish() -> void:
	print("NATIVE_ZONE_RESULT checks=%d failures=%d mode=%s"%[checks,failures,mode])
	quit(0 if failures==0 else 1)
