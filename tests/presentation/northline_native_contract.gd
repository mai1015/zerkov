extends SceneTree
## Actual native scenes and renderer, no runtime map generator or fixture art.
const VIEW = preload("res://game/presentation/northline_native/freight_review.tscn")
const Exact1080CaptureGuard = preload("res://game/presentation/exact_1080_capture_guard.gd")
const EXACT := Vector2i(1920,1080)
var checks:=0
var failures:=0
var output:=""
var mode:="full"
var edited:=""

func _initialize()->void:
	call_deferred("run")

func check(ok:bool,why:String)->void:
	checks+=1
	if not ok:
		failures+=1
		push_error("NATIVE_FREIGHT_ASSERT: "+why)

func frames()->void:
	for _i:int in range(4):await process_frame
	if DisplayServer.get_name()!="headless":await RenderingServer.frame_post_draw

func key(code:int,pressed:bool)->void:
	var event:=InputEventKey.new();event.keycode=code;event.physical_keycode=code;event.pressed=pressed
	Input.parse_input_event(event)
	await process_frame

func capture(name_text:String)->void:
	if output.is_empty() or DisplayServer.get_name()=="headless":return
	await frames()
	var image:=root.get_texture().get_image()
	check(Exact1080CaptureGuard.accepts(root,root,image),"physical output guard "+name_text)
	if not Exact1080CaptureGuard.accepts(root,root,image):
		return
	var save_result := image.save_png(output.path_join(name_text+".png"))
	check(save_result==OK,"native PNG "+name_text)

func world_rect(body:StaticBody2D)->Rect2:
	var shape:CollisionShape2D=body.get_node("CollisionShape2D")
	return Rect2(shape.global_position-(shape.shape as RectangleShape2D).size/2,(shape.shape as RectangleShape2D).size)

func descendants(node:Node)->Array[Node]:
	var result:Array[Node]=[]
	for child:Node in node.get_children():
		result.append(child)
		result.append_array(descendants(child))
	return result

func run()->void:
	for arg:String in OS.get_cmdline_user_args():
		if arg.begins_with("--output="):output=arg.trim_prefix("--output=")
		if arg.begins_with("--mode="):mode=arg.trim_prefix("--mode=")
		if arg.begins_with("--edited="):edited=arg.trim_prefix("--edited=")
	create_timer(100).timeout.connect(func(): check(false,"watchdog"); finish())
	root.borderless=true;root.size=EXACT
	await frames()
	check(root.size==EXACT and root.get_visible_rect().size==Vector2(EXACT),"exact native target")
	if DisplayServer.get_name()!="headless":check(Exact1080CaptureGuard.accepts(root,root,root.get_texture().get_image()),"guard before scene mount")
	if failures>0:finish();return
	if mode=="editor_reopen":
		var value=load(edited).instantiate()
		root.add_child(value)
		await frames()
		var t:TileMapLayer=value.get_node("Terrain/FreightFloorBounds/FreightFloor")
		check(t.get_used_cells().size()==447,"real editor UI erased and saved one of 448 tiles")
		var p:Node2D=value.get_node("WorldProps/northline_zone_prop_0052")
		check(p.position==Vector2(1031,597),"real Inspector edit persisted across processes")
		check(p.get_node("Footprint/CollisionShape2D").global_position==p.position+Vector2(0,-3),"Inspector move retained attached footprint")
		value.queue_free();await frames();finish();return
	if mode=="reopen":
		var value=load(edited).instantiate()
		root.add_child(value)
		await frames()
		var t:TileMapLayer=value.get_node("Terrain/FreightFloorBounds/FreightFloor")
		check(t.get_cell_source_id(Vector2i(5,5))==12,"painted cell survives another process")
		var p:Node2D=value.get_node("WorldProps/northline_zone_prop_0052")
		check(p.position==Vector2(1031,597),"moved reusable prop survives another process")
		check(p.get_node("Footprint/CollisionShape2D").global_position==p.position+Vector2(0,-3),"moved prop carries its collider")
		value.queue_free();await frames();finish();return
	var view=VIEW.instantiate()
	root.add_child(view)
	await frames()
	var sector:Node2D=view.sector
	check(sector.get_script()==null,"static saved sector has no runtime generator")
	var nodes:=descendants(sector)
	var maps:Array[TileMapLayer]=[]
	for node:Node in nodes:
		if node is TileMapLayer:maps.append(node)
		if not str(node.name).begins_with("Review") and node!=view.walker and not view.walker.is_ancestor_of(node):
			check(node.get_script()==null,"native authored node "+str(node.name))
	check(maps.size()>=8,"terrain and wall TileMapLayers")
	var cells:=0
	for tiles:TileMapLayer in maps:
		cells+=tiles.get_used_cells().size()
		check(tiles.scale==Vector2.ONE/3,"logical scale separate from source resolution")
	check(cells>2000,"saved tile placement data")
	check(view.camera.zoom==Vector2(3,3),"one 48px source tile occupies 48 render pixels")
	check(Vector2(EXACT)/view.camera.zoom==Vector2(640,360),"unchanged 640x360 WORLD coverage (not a render surface)")
	check(root.find_children("*","SubViewport",true,false).is_empty(),"no low resolution render pass")
	var ground:TileSet=load("res://game/world/northline_native/tilesets/ground.tres")
	check(ground.tile_size==Vector2i(48,48),"native original-size tile grid")
	check(sector.get_node("Terrain/FreightFloorBounds/FreightFloor").tile_set==ground,"scene uses the editable shared external TileSet")
	for id:int in [10,12,14,17,18,19,20,49,60,62,147]:
		var path:="res://assets/world/northline_native/sources/sheet_%d.png"%id
		var original:=Image.new()
		check(original.load_png_from_buffer(FileAccess.get_file_as_bytes(path))==OK,"decode PNG test reference %d"%id)
		var imported:Image=(load(path) as Texture2D).get_image()
		check(original.get_size()==Vector2i(768,768) and imported.get_size()==original.get_size(),"original full sheet dimensions %d"%id)
		check(original.get_data()==imported.get_data(),"native imported RGBA unchanged %d"%id)
		check(not imported.has_mipmaps(),"no sprite mipmaps %d"%id)
	var old:Dictionary=JSON.parse_string(FileAccess.get_file_as_string("res://game/presentation/northline_zone/zone.json"))
	var found_solids:Array[Rect2]=[]
	for node:Node in nodes:
		if node is StaticBody2D and node.has_meta("legacy_rect"):
			found_solids.append(world_rect(node))
	var expected_solids:=0
	for a:Array in old.collision_rects:
		var r:=Rect2(a[0],a[1],a[2],a[3])
		if not (sector.get_meta("authored_world_bounds") as Rect2).intersects(r):continue
		expected_solids+=1;check(found_solids.has(r),"exact existing wall/fence footprint "+str(r))
	check(found_solids.size()==expected_solids,"no duplicate wall collision authority")
	var expected_props:=0
	var art:Dictionary=JSON.parse_string(FileAccess.get_file_as_string("res://assets/world/map_studies/atlas.json"))
	for p:Dictionary in old.props:
		var at:=Vector2(p.foot[0],p.foot[1])
		if not (sector.get_meta("authored_world_bounds") as Rect2).has_point(at):continue
		expected_props+=1
		var instance:Node2D=sector.get_node("WorldProps/"+str(p.id).replace(".","_"))
		var a:Dictionary=art.assets[p.asset]
		check(instance.position==at,"preserved prop placement "+str(p.id))
		var shape:CollisionShape2D=instance.get_node("Footprint/CollisionShape2D")
		check(shape.shape.size==Vector2(a.footprint[0],a.footprint[1]) and shape.position==Vector2(0,-float(a.footprint[1])/2),"preserved prop collider "+str(p.id))
		check(not instance.scene_file_path.is_empty(),"reusable prop scene "+str(p.id))
	check(expected_props==49,"all 49 source placements retained")
	await capture("northline-native-entrance-1080")
	view.frame_at(Vector2(1288,638));await frames();await capture("northline-native-warehouse-1080")
	view.inspect_annex();await frames();await capture("northline-native-inspection-1080")
	view.reset_camera();await frames()
	var at:Vector2=view.camera.position
	await key(KEY_D,true)
	for _i:int in range(8):await physics_frame
	await key(KEY_D,false)
	check(view.camera.position.x>at.x,"actual camera input")
	await key(KEY_HOME,true);await key(KEY_HOME,false)
	check(view.camera.position==Vector2(1184,650),"native Home reset")
	await key(KEY_P,true);await key(KEY_P,false)
	check(view.walking and view.walker.enabled,"native walkthrough toggle")
	view.walker.enabled=false
	view.walker.position=Vector2(1112,795)
	await physics_frame;await physics_frame
	var clear:=true
	for _i:int in range(42):
		if view.walker.move_and_collide(Vector2(0,-4))!=null:clear=false;break
	check(clear and view.walker.position.y<635,"retained south loading doorway remains traversable")
	view.walker.position=Vector2(1060,551)
	await physics_frame
	check(view.walker.move_and_collide(Vector2(0,-32))!=null,"north wall blocks the actual CharacterBody")
	view.walker.position=Vector2(1112,790)
	view.walker.enabled=true
	await key(KEY_D,true)
	for _i:int in range(12):await physics_frame
	await key(KEY_D,false)
	check(view.walker.position.x>1115,"actual movement input with native scene collision")
	view.walker.enabled=false
	view.walker.position=Vector2(1112,790);view.walker.show_frame(false,0)
	view.frame_at(Vector2(1184,650));await frames();await capture("northline-native-walkthrough-1080")
	view.set_walking(false)
	var pristine=(load("res://game/world/northline_native/freight_sector.tscn") as PackedScene).instantiate(PackedScene.GEN_EDIT_STATE_MAIN)
	var tiles:TileMapLayer=pristine.get_node("Terrain/FreightFloorBounds/FreightFloor")
	tiles.set_cell(Vector2i(5,5),12,Vector2i(2,9))
	var moved:Node2D=pristine.get_node("WorldProps/northline_zone_prop_0052")
	moved.position=Vector2(1031,597)
	var saved:=PackedScene.new()
	check(saved.pack(pristine)==OK,"pack an edited native scene without rerunning migration")
	check(not edited.is_empty() and ResourceSaver.save(saved,edited)==OK,"save a painted tile and moved prop")
	pristine.free()
	var readback=ResourceLoader.load(edited,"",ResourceLoader.CACHE_MODE_IGNORE).instantiate()
	check(readback.get_node("Terrain/FreightFloorBounds/FreightFloor").get_cell_source_id(Vector2i(5,5))==12,"tile edit roundtrip")
	check(readback.get_node("WorldProps/northline_zone_prop_0052").position==Vector2(1031,597),"prop edit roundtrip")
	readback.free()
	view.queue_free();await frames();finish()

func finish()->void:
	print("NATIVE_FREIGHT_RESULT checks=%d failures=%d mode=%s"%[checks,failures,mode])
	quit(0 if failures==0 else 1)
