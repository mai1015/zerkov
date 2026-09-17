extends "res://tools/migrate_northline_freight.gd"
## One-time native resource authoring, never loaded by the runtime scene.
## The existing freight reference, original images and legacy layout are read-only.
const OUT := "res://game/world/northline_native/zone/"
const MAP_BOUNDS := Rect2(0, 0, 2688, 1792)
var walls_saved: Dictionary = {}
var geometry: Dictionary = {}

func save_new(resource: Resource, path: String) -> void:
	if FileAccess.file_exists(path):
		require(false, "refusing existing authored resource: " + path)
		return
	require(ResourceSaver.save(resource, path, ResourceSaver.FLAG_CHANGE_PATH) == OK, "save " + path)

func ground_set() -> void:
	terrain = TileSet.new()
	terrain.resource_name = "Northline original 48px surfaces"
	terrain.tile_size = Vector2i(48,48)
	terrain.add_custom_data_layer()
	terrain.set_custom_data_layer_name(0,"surface")
	terrain.set_custom_data_layer_type(0,TYPE_STRING)
	for key: String in ["grass","dirt","concrete","concrete_crack","concrete_grey","road","road_crack","paving","hospital_floor","metal_floor"]:
		var a: Dictionary = manifest.assets[key]
		var sid := int(a.source_index)
		var src: TileSetAtlasSource
		if terrain.has_source(sid):
			src = terrain.get_source(sid)
		else:
			src = TileSetAtlasSource.new()
			src.texture = sheet(sid)
			src.texture_region_size = Vector2i(48,48)
			terrain.add_source(src,sid)
		var cell := Vector2i(int(a.source_rect[0])/48, int(a.source_rect[1])/48)
		if not src.has_tile(cell): src.create_tile(cell)
		src.get_tile_data(cell,0).set_custom_data("surface",key)
	save_new(terrain, OUT+"ground.tres")
	terrain = load(OUT+"ground.tres")

func fill(parent: Node, name_text: String, key: String, area: Rect2, tint: Color, vary := true) -> void:
	var clip := area.intersection(MAP_BOUNDS)
	if not clip.has_area(): return
	var mask := polygon(parent, rect_poly(Rect2(Vector2.ZERO,clip.size)), Color.WHITE, name_text+"Bounds")
	mask.position = clip.position
	mask.clip_children = CanvasItem.CLIP_CHILDREN_ONLY
	var tiles := TileMapLayer.new()
	tiles.tile_set = terrain
	tiles.scale = Vector2.ONE/3.0
	tiles.position = area.position-clip.position
	tiles.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	tiles.modulate = tint
	tiles.navigation_enabled = false
	tiles.collision_enabled = false
	tiles.rendering_quadrant_size = 32
	attach(mask,tiles,name_text)
	var start := Vector2i(floor((clip.position.x-area.position.x)/16),floor((clip.position.y-area.position.y)/16))
	var end := Vector2i(ceil((clip.end.x-area.position.x)/16),ceil((clip.end.y-area.position.y)/16))
	for y: int in range(start.y,end.y):
		for x: int in range(start.x,end.x):
			var key_used := key
			var cell := absi((int(area.position.x+x*16)*7381+int(area.position.y+y*16)*1933+int(layout.seed))%97)
			if vary and key == "road" and cell%7 == 0: key_used="road_crack"
			if vary and key == "concrete" and cell%9 == 0: key_used="concrete_crack"
			var a: Dictionary = manifest.assets[key_used]
			tiles.set_cell(Vector2i(x,y),int(a.source_index),Vector2i(int(a.source_rect[0])/48,int(a.source_rect[1])/48))

func make_prop(key: String) -> PackedScene:
	# Keep previously editor-authored prototypes; never regenerate them on load.
	var retained := DIR+"props/"+key+".tscn"
	if FileAccess.file_exists(retained): return load(retained)
	return super.make_prop(key)

func wall_set(key: String) -> TileSet:
	if walls_saved.has(key): return walls_saved[key]
	var a: Dictionary = manifest.assets[key]
	var t := TileSet.new()
	t.resource_name = key.replace("_"," ") + " original source"
	t.tile_size = Vector2i(48,96)
	var src := TileSetAtlasSource.new()
	src.texture = sheet(int(a.source_index))
	src.texture_region_size = Vector2i(48,48)
	var first := Vector2i(int(a.source_rect[0])/48,int(a.source_rect[1])/48)
	src.create_tile(first,Vector2i(1,2))
	src.create_tile(first+Vector2i(1,0),Vector2i(1,2))
	t.add_source(src,0)
	save_new(t, OUT+key+".tres")
	walls_saved[key] = load(OUT+key+".tres")
	return walls_saved[key]

func rect_key(r: Rect2) -> String:
	return "%s,%s,%s,%s" % [r.position.x,r.position.y,r.size.x,r.size.y]

func add_wall(parent: Node, r: Rect2, name_text: String, building: Dictionary = {}) -> void:
	var key := rect_key(r)
	require(not geometry.has(key),"no duplicate authored collision " + key)
	geometry[key] = true
	solid(parent,r,name_text,not building.is_empty())
	if building.is_empty() or not is_equal_approx(r.position.y,float(building.rect[1])-4) or r.size.y>8.1: return
	# Wall-face TileMap travels with its actual segment/collider in the editor.
	var body := parent.get_node(name_text) as Node2D
	var mask := polygon(body,rect_poly(Rect2(0,0,r.size.x,32)),Color.WHITE,"FaceBounds")
	mask.position=Vector2(0,-24)
	mask.clip_children=CanvasItem.CLIP_CHILDREN_ONLY
	var tiles := TileMapLayer.new()
	tiles.tile_set=wall_set(str(building.wall))
	tiles.scale=Vector2.ONE/3.0
	tiles.texture_filter=CanvasItem.TEXTURE_FILTER_NEAREST
	tiles.modulate=Color("b4b4a4")
	tiles.collision_enabled=false;tiles.navigation_enabled=false
	attach(mask,tiles,"WallFaces")
	var a: Dictionary=manifest.assets[str(building.wall)]
	var first:=Vector2i(int(a.source_rect[0])/48,int(a.source_rect[1])/48)
	for x: int in range(int(ceil(r.size.x/16))): tiles.set_cell(Vector2i(x,0),0,first+Vector2i(x%2,0))

func district(at: Vector2) -> String:
	var best := "";var distance := INF
	for d: Dictionary in layout.sectors:
		var ds := at.distance_squared_to(Vector2(d.at[0],d.at[1]))
		if ds<distance: distance=ds;best=str(d.id)
	return best

func roads_and_rails(parent: Node) -> void:
	var index := 0
	for water: Array in layout.water_rects:
		var r:=raw_rect(water)
		rect(parent,r.grow(4),Color("3d4d49"),"Bank%d"%index)
		rect(parent,r,Color("324a47"),"Water%d"%index)
		for y: int in range(int(r.position.y)+5,int(r.end.y),11):
			line(parent,PackedVector2Array([Vector2(r.position.x+9,y),Vector2(r.end.x-8,y)]),Color("466058"),1,"Current%d_%d"%[index,y])
		index+=1
	for rail: Array in layout.rails:
		var x:int=rail[0];var y:int=rail[1];var w:int=rail[2]
		rect(parent,Rect2(x,y-17,w,42),Color("555c51"),"TrackBed%d"%y)
		for px:int in range(x,x+w,14):
			rect(parent,Rect2(px,y-11,5,30),Color("665e4c"),"Sleeper%d_%d"%[y,px])
		for ry:int in [y-5,y+11]:
			rect(parent,Rect2(x,ry,w,3),Color("232d2e"),"Rail%d"%ry)
			line(parent,PackedVector2Array([Vector2(x,ry),Vector2(x+w,ry)]),Color("aaa48b"),1,"RailHighlight%d"%ry)
	index=0
	for road: Array in layout.roads:
		var r:=raw_rect(road.slice(0,4))
		if road[4]=="h":
			for x:int in range(int(r.position.x)+16,int(r.end.x)-24,56):rect(parent,Rect2(x,r.get_center().y,24,2),Color("a7a084"),"Road%d_Dash%d"%[index,x])
			line(parent,PackedVector2Array([r.position+Vector2(0,6),Vector2(r.end.x,r.position.y+6)]),Color("8b947f"),1,"RoadEdge%d"%index)
		else:
			for y:int in range(int(r.position.y)+16,int(r.end.y)-24,56):rect(parent,Rect2(r.get_center().x,y,2,24),Color("a7a084"),"Road%d_Dash%d"%[index,y])
		index+=1
	index=0
	for parking: Array in layout.parking:
		for x:int in range(int(parking[0]),int(parking[0]+parking[2]),48):
			line(parent,PackedVector2Array([Vector2(x,parking[1]),Vector2(x,parking[1]+parking[3])]),Color("8b8e79"),1,"Parking%d_%d"%[index,x])
		index+=1

func run() -> void:
	if DirAccess.dir_exists_absolute(OUT):
		push_error("FULL_NATIVE_MIGRATION: output exists; saved editor work will not be replaced")
		quit(2);return
	manifest=JSON.parse_string(FileAccess.get_file_as_string("res://assets/world/map_studies/atlas.json"))
	layout=JSON.parse_string(FileAccess.get_file_as_string("res://game/presentation/northline_zone/zone.json"))
	require(Vector2(layout["size"][0],layout["size"][1])==MAP_BOUNDS.size,"fixed authored geometry")
	for row: Dictionary in JSON.parse_string(FileAccess.get_file_as_string("res://assets/world/northline_native/source_manifest.json")).sources:
		require(FileAccess.file_exists("res://"+str(row.path)),"original PNG required")
	if failures: quit(2);return
	DirAccess.make_dir_recursive_absolute(OUT)
	ground_set()
	sector=Node2D.new();sector.name="NorthlineWorld"
	sector.texture_filter=CanvasItem.TEXTURE_FILTER_NEAREST
	sector.set_meta("authored_world_bounds",MAP_BOUNDS)
	sector.set_meta("runtime_layout_generator",false)
	sector.set_meta("source_pixels_per_world_unit",3)
	sector.set_meta("migration_snapshot","36e363625861e3fe3758c345181a66891facdabd")
	var g:=attach(sector,Node2D.new(),"Terrain")
	fill(g,"Grass","grass",MAP_BOUNDS,Color("8f947f"))
	var i:=0
	for row:Dictionary in layout.surfaces:
		fill(g,"Surface%02d_%s"%[i,row.tile],str(row.tile),raw_rect(row.rect),Color(row.tint));i+=1
	roads_and_rails(attach(sector,Node2D.new(),"Infrastructure"))
	var buildings:=attach(sector,Node2D.new(),"Buildings")
	for d:Dictionary in layout.sectors:attach(buildings,Node2D.new(),str(d.id).to_pascal_case())
	for b:Dictionary in layout.buildings:
		var r:=raw_rect(b.rect)
		var building:=attach(buildings.get_node(district(r.get_center()).to_pascal_case()),Node2D.new(),str(b.id).to_pascal_case())
		building.set_meta("legacy_building_id",str(b.id));building.set_meta("floor_bounds",r)
		fill(g,str(b.id).to_pascal_case()+"Floor",str(b.floor),r,Color("bbbcae"))
		label(building,str(b.name),r.position+Vector2(10,-41),9,Color("e1d5b0"),"BuildingName")
		i=0
		for a:Array in b.walls: add_wall(building,raw_rect(a),"WallSegment%02d"%i,b);i+=1
		for gap:Array in b.doors.get("s",[]):
			var gx:float=r.position.x+gap[0];var gw:float=gap[1]
			rect(building,Rect2(gx-gw/2,r.end.y-7,gw,14),Color("55594c"),"DoorThreshold%d"%int(gx))
			for px:int in range(int(gx-gw/2),int(gx+gw/2)-5,8):
				line(building,PackedVector2Array([Vector2(px,r.end.y-6),Vector2(px+5,r.end.y+4)]),Color("a99e63"),2,"ThresholdStripe%d"%px)
	var details:=attach(sector,Node2D.new(),"GroundDetails")
	i=0
	for d:Dictionary in layout.decals:
		source_sprite(details,str(d.asset),Vector2(d.at[0],d.at[1]),Color(d.tint),"Decal%04d_%s"%[i,d.asset]);i+=1
	static_dressing(attach(sector,Node2D.new(),"FreightDressing"))
	var props:=attach(sector,Node2D.new(),"WorldProps") as Node2D
	props.y_sort_enabled=true
	for d:Dictionary in layout.sectors:
		var group:=attach(props,Node2D.new(),str(d.id).to_pascal_case()) as Node2D
		group.y_sort_enabled=true
	for p:Dictionary in layout.props:
		var at:=Vector2(p.foot[0],p.foot[1])
		var instance:=make_prop(str(p.asset)).instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE) as Node2D
		instance.position=at
		attach(props.get_node(district(at).to_pascal_case()),instance,str(p.id).replace(".","_"))
		sector.set_editable_instance(instance,true)
		instance.get_node("SourceSprite").flip_h=bool(p.flip)
		instance.get_node("SourceSprite").modulate=Color(p.tint)
		instance.set_meta("legacy_prop_id",str(p.id))
		if not p.get("solid",true):instance.get_node("Footprint").collision_layer=0
	var boundary:=attach(sector,Node2D.new(),"BoundaryAndFences")
	for f:Array in layout.fences:
		for x:int in range(int(f[0]),int(f[0]+f[2]),30):
			source_sprite(boundary,"fence",Vector2(x,f[1]-15),Color("b0b5a7"),"Fence_%d_%d"%[x,f[1]])
	i=0
	for a:Array in layout.collision_rects:
		var r:=raw_rect(a)
		if not geometry.has(rect_key(r)):add_wall(boundary,r,"BoundarySegment%03d"%i)
		i+=1
	var lights:=attach(sector,Node2D.new(),"Lighting")
	var ambient:=CanvasModulate.new();ambient.color=Color(.84,.90,.87,1);attach(lights,ambient,"OvercastAmbient")
	i=0
	for l:Dictionary in layout.lights:
		var at:=Vector2(l.at[0],l.at[1])
		if Rect2(988,532,512,224).has_point(at):continue
		make_light(lights,at,float(l.radius),Color(l.color),1.10,"DistrictLamp%02d"%i,false);i+=1
	make_light(lights,Vector2(1110,560),125,Color("ffd09a"),.86,"TaskLampWest")
	make_light(lights,Vector2(1380,560),110,Color("ffc888"),.78,"TaskLampEast")
	make_light(lights,Vector2(1014,700),78,Color("dfb98b"),.58,"WorkLamp")
	make_light(lights,Vector2(1112,778),105,Color("9cbed0"),.45,"DoorLight")
	var districts:=attach(sector,Node2D.new(),"DistrictMarkers")
	for d:Dictionary in layout.sectors:
		var marker:=Marker2D.new();marker.position=Vector2(d.at[0],d.at[1])
		marker.set_meta("title",str(d.name));marker.set_meta("description",str(d.description));attach(districts,marker,str(d.id).to_pascal_case())
	var exits:=attach(sector,Node2D.new(),"ReviewExitMarkers")
	for e:Dictionary in layout.exits:
		var marker:=Marker2D.new();marker.position=Vector2(e.at[0],e.at[1]);marker.set_meta("title",str(e.name));attach(exits,marker,str(e.id).to_pascal_case())
	var spawns:=attach(sector,Node2D.new(),"SpawnMarkers")
	for j:int in range(layout.spawn_points.size()):
		var at:Array=layout.spawn_points[j];var marker:=Marker2D.new();marker.position=Vector2(at[0],at[1]);attach(spawns,marker,"Spawn%d"%j)
	var routes:=attach(sector,Node2D.new(),"ReviewRoutes") as Node2D
	routes.visible=false;routes.z_index=100
	i=0
	for r:Dictionary in layout.routes:
		var pts:=PackedVector2Array()
		for at:Array in r.points:pts.append(Vector2(at[0],at[1]))
		line(routes,pts,Color(.86,.68,.34,.80),2,"Route%d"%i);i+=1
	var packed:=PackedScene.new();require(packed.pack(sector)==OK,"pack whole zone")
	save_new(packed,OUT+"northline_world.tscn")
	print("FULL_NATIVE_AUTHOR_RESULT props=",layout.props.size()," buildings=",layout.buildings.size()," solids=",geometry.size()," failures=",failures)
	sector.free();quit(0 if failures==0 else 1)
