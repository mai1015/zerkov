extends SceneTree
## ONE-TIME authoring migration. Not referenced by any runtime scene.
## Source sheet pixels are never decoded/modified here: native TileSetAtlasSource
## and Sprite2D regions refer directly to the original PNG textures.
const DIR := "res://game/world/northline_native/"
const BOUNDS := Rect2(864,448,832,432)
var manifest: Dictionary
var layout: Dictionary
var sector: Node2D
var terrain: TileSet
var sheets: Dictionary = {}
var prop_scenes: Dictionary = {}
var failures: int = 0

func _initialize() -> void:
	call_deferred("run")

func require(ok: bool, why: String) -> void:
	if not ok:
		failures += 1
		push_error("NATIVE_MIGRATION: " + why)

func attach(parent: Node, child: Node, name_text: String) -> Node:
	child.name = name_text
	parent.add_child(child)
	child.owner = sector
	return child

func rect_poly(rect: Rect2) -> PackedVector2Array:
	return PackedVector2Array([rect.position, Vector2(rect.end.x,rect.position.y), rect.end, Vector2(rect.position.x,rect.end.y)])

func polygon(parent: Node, points: PackedVector2Array, color: Color, name_text: String) -> Polygon2D:
	var p := Polygon2D.new()
	p.polygon = points
	p.color = color
	attach(parent,p,name_text)
	return p

func line(parent: Node, points: PackedVector2Array, color: Color, width: float, name_text: String) -> void:
	var n := Line2D.new()
	n.points = points
	n.width = width
	n.default_color = color
	attach(parent,n,name_text)

func rect(parent: Node, value: Rect2, color: Color, name_text: String) -> void:
	polygon(parent,rect_poly(value),color,name_text)

func label(parent: Node, text: String, at: Vector2, px: int, color: Color, name_text: String) -> void:
	var n := Label.new()
	n.text = text
	n.position = at
	n.add_theme_font_size_override("font_size",px)
	n.add_theme_color_override("font_color",color)
	n.mouse_filter = Control.MOUSE_FILTER_IGNORE
	attach(parent,n,name_text)

func raw_rect(value: Array) -> Rect2:
	return Rect2(value[0],value[1],value[2],value[3])

func sheet(id: int) -> Texture2D:
	if not sheets.has(id):
		sheets[id] = load("res://assets/world/northline_native/sources/sheet_%d.png" % id)
	return sheets[id]

func make_terrain() -> void:
	terrain = TileSet.new()
	terrain.resource_name = "Northline original 48px ground"
	terrain.tile_size = Vector2i(48,48)
	terrain.add_custom_data_layer()
	terrain.set_custom_data_layer_name(0,"surface")
	terrain.set_custom_data_layer_type(0,TYPE_STRING)
	for key: String in ["grass","dirt","concrete","concrete_crack","concrete_grey","road","road_crack","paving"]:
		var a: Dictionary = manifest.assets[key]
		var sid := int(a.source_index)
		var source: TileSetAtlasSource
		if terrain.has_source(sid):
			source = terrain.get_source(sid)
		else:
			source = TileSetAtlasSource.new()
			source.texture = sheet(sid)
			source.texture_region_size = Vector2i(48,48)
			source.use_texture_padding = true
			terrain.add_source(source,sid)
		var c := Vector2i(int(a.source_rect[0])/48,int(a.source_rect[1])/48)
		source.create_tile(c)
		source.get_tile_data(c,0).set_custom_data("surface",key)
	require(ResourceSaver.save(terrain,DIR+"tilesets/ground.tres",ResourceSaver.FLAG_CHANGE_PATH) == OK,"save ground TileSet")

	terrain = load(DIR+"tilesets/ground.tres")

func fill(parent: Node, name_text: String, key: String, area: Rect2, tint: Color, vary := true) -> void:
	var clipped := area.intersection(BOUNDS)
	if not clipped.has_area():
		return
	# Native clipping keeps partial border tiles inside their authored room/yard.
	# The TileMap data itself is saved, and is never rebuilt when the scene loads.
	var mask := polygon(parent,rect_poly(Rect2(Vector2.ZERO,clipped.size)),Color.WHITE,name_text+"Bounds")
	mask.position = clipped.position
	mask.clip_children = CanvasItem.CLIP_CHILDREN_ONLY
	var tiles := TileMapLayer.new()
	tiles.tile_set = terrain
	tiles.scale = Vector2.ONE/3.0
	tiles.position = area.position-clipped.position
	tiles.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	tiles.modulate = tint
	tiles.collision_enabled = false
	tiles.navigation_enabled = false
	attach(mask,tiles,name_text)
	var start := Vector2i(floor((clipped.position.x-area.position.x)/16),floor((clipped.position.y-area.position.y)/16))
	var end := Vector2i(ceil((clipped.end.x-area.position.x)/16),ceil((clipped.end.y-area.position.y)/16))
	for y: int in range(start.y,end.y):
		for x: int in range(start.x,end.x):
			var chosen := key
			var hash_cell := absi((int(area.position.x+x*16)*7381+int(area.position.y+y*16)*1933+int(layout.seed))%97)
			if vary and key == "road" and hash_cell%7 == 0:
				chosen = "road_crack"
			if vary and key == "concrete" and hash_cell%9 == 0:
				chosen = "concrete_crack"
			var a: Dictionary = manifest.assets[chosen]
			tiles.set_cell(Vector2i(x,y),int(a.source_index),Vector2i(int(a.source_rect[0])/48,int(a.source_rect[1])/48))

func make_prop(key: String) -> PackedScene:
	if prop_scenes.has(key):
		return prop_scenes[key]
	var a: Dictionary = manifest.assets[key]
	var root_prop := Node2D.new()
	root_prop.name = key.to_pascal_case()
	root_prop.set_meta("source_asset",key)
	root_prop.set_meta("source_pixels_per_world_unit",3)
	var w := float(a.size[0])
	var h := float(a.size[1])
	var shadow := Polygon2D.new()
	shadow.name = "ContactShadow"
	shadow.polygon = PackedVector2Array([Vector2(-w*.44,-4),Vector2(w*.44,-4),Vector2(w*.44+4,3),Vector2(-w*.44+2,3)])
	shadow.color = Color(0.035,0.055,0.055,0.36)
	root_prop.add_child(shadow);shadow.owner=root_prop
	var s := Sprite2D.new()
	s.name="SourceSprite"
	s.texture=sheet(int(a.source_index))
	s.region_enabled=true
	s.region_filter_clip_enabled=true
	# This is inspector-visible region metadata only; original PNG is unchanged.
	s.region_rect=Rect2(float(a.source_rect[0])+float(a.trim[0])*3,float(a.source_rect[1])+float(a.trim[1])*3,w*3,h*3)
	s.centered=false
	s.position=Vector2(-floor(w/2),-h)
	s.scale=Vector2.ONE/3.0
	s.texture_filter=CanvasItem.TEXTURE_FILTER_NEAREST
	root_prop.add_child(s);s.owner=root_prop
	var body := StaticBody2D.new()
	body.name="Footprint"
	body.collision_layer=1
	body.collision_mask=1
	root_prop.add_child(body);body.owner=root_prop
	var cs := CollisionShape2D.new()
	cs.name="CollisionShape2D"
	var shape := RectangleShape2D.new()
	shape.size=Vector2(a.footprint[0],a.footprint[1])
	cs.shape=shape
	cs.position=Vector2(0,-float(a.footprint[1])/2)
	body.add_child(cs);cs.owner=root_prop
	var occluder := LightOccluder2D.new()
	occluder.name="FootOccluder"
	var poly := OccluderPolygon2D.new()
	poly.polygon=rect_poly(Rect2(-float(a.footprint[0])/2,-float(a.footprint[1]),float(a.footprint[0]),float(a.footprint[1])))
	occluder.occluder=poly
	occluder.occluder_light_mask=2
	occluder.sdf_collision=false
	root_prop.add_child(occluder);occluder.owner=root_prop
	var packed := PackedScene.new()
	require(packed.pack(root_prop)==OK,"pack prop "+key)
	require(ResourceSaver.save(packed,DIR+"props/"+key+".tscn")==OK,"save prop "+key)
	root_prop.free()
	packed=load(DIR+"props/"+key+".tscn")
	prop_scenes[key]=packed
	return packed

func source_sprite(parent: Node, key: String, at: Vector2, tint: Color, name_text: String) -> void:
	var a: Dictionary=manifest.assets[key]
	var s:=Sprite2D.new()
	s.texture=sheet(int(a.source_index))
	s.centered=false
	s.region_enabled=true
	s.region_filter_clip_enabled=true
	s.region_rect=Rect2(float(a.source_rect[0])+float(a.trim[0])*3,float(a.source_rect[1])+float(a.trim[1])*3,float(a.size[0])*3,float(a.size[1])*3)
	s.position=at
	s.scale=Vector2.ONE/3.0
	s.modulate=tint
	s.texture_filter=CanvasItem.TEXTURE_FILTER_NEAREST
	attach(parent,s,name_text)

func solid(parent: Node, r: Rect2, name_text: String, with_art := true) -> void:
	# Exact old footprints, including off-grid widths/positions, are native shapes.
	# Visual and physical parts move together as one editable wall segment.
	var body:=StaticBody2D.new()
	body.position=r.position
	body.set_meta("legacy_rect",r)
	attach(parent,body,name_text)
	var collision:=CollisionShape2D.new()
	var shape:=RectangleShape2D.new()
	shape.size=r.size;collision.shape=shape;collision.position=r.size/2
	attach(body,collision,"CollisionShape2D")
	var occluder:=LightOccluder2D.new()
	var op:=OccluderPolygon2D.new();op.polygon=rect_poly(Rect2(Vector2.ZERO,r.size))
	occluder.occluder=op;occluder.occluder_light_mask=2;occluder.sdf_collision=false
	attach(body,occluder,"LightOccluder2D")
	if with_art:
		rect(body,Rect2(Vector2.ZERO,r.size),Color("50584f"),"Cap")
		line(body,PackedVector2Array([Vector2.ZERO,Vector2(r.size.x,0)]),Color("88907b"),1,"CapEdge")

func make_wall_faces(parent:Node,b:Dictionary) -> void:
	var a:Dictionary=manifest.assets[str(b.wall)]
	var tile_set:=TileSet.new()
	tile_set.tile_size=Vector2i(48,96)
	var src:=TileSetAtlasSource.new()
	src.texture=sheet(int(a.source_index));src.texture_region_size=Vector2i(48,48)
	var first:=Vector2i(int(a.source_rect[0])/48,int(a.source_rect[1])/48)
	src.create_tile(first,Vector2i(1,2));src.create_tile(first+Vector2i(1,0),Vector2i(1,2))
	tile_set.add_source(src,0)
	var path:=DIR+"tilesets/"+str(b.wall)+".tres"
	require(ResourceSaver.save(tile_set,path,ResourceSaver.FLAG_CHANGE_PATH)==OK,"wall TileSet")
	tile_set = load(path)
	var i:=0
	for v:Array in b.walls:
		var wr:=raw_rect(v)
		if not is_equal_approx(wr.position.y,float(b.rect[1])-4) or wr.size.y>8.1:
			continue
		var bounds:=polygon(parent,rect_poly(Rect2(0,0,wr.size.x,32)),Color.WHITE,"NorthFaceBounds%d"%i)
		bounds.position=Vector2(wr.position.x,float(b.rect[1])-28)
		bounds.clip_children=CanvasItem.CLIP_CHILDREN_ONLY
		var tiles:=TileMapLayer.new()
		tiles.tile_set=tile_set;tiles.scale=Vector2.ONE/3
		tiles.navigation_enabled=false;tiles.collision_enabled=false
		tiles.texture_filter=CanvasItem.TEXTURE_FILTER_NEAREST;tiles.modulate=Color("b4b4a4")
		attach(bounds,tiles,"WallFaces")
		for x:int in range(int(ceil(wr.size.x/16))):
			tiles.set_cell(Vector2i(x,0),0,first+Vector2i(x%2,0))
		i+=1

func make_light(parent:Node,at:Vector2,radius:float,color:Color,energy:float,name_text:String,shadow:=true)->void:
	var g:=Gradient.new()
	g.offsets=PackedFloat32Array([0,.16,.62,1]);g.colors=PackedColorArray([Color(1,1,1,.95),Color(1,1,1,.65),Color(1,1,1,.16),Color(1,1,1,0)])
	var t:=GradientTexture2D.new();t.gradient=g;t.width=256;t.height=256
	t.fill=GradientTexture2D.FILL_RADIAL;t.fill_from=Vector2(.5,.5);t.fill_to=Vector2(1,.5)
	var lamp:=PointLight2D.new();lamp.texture=t;lamp.texture_scale=radius/128
	lamp.position=at;lamp.color=color;lamp.energy=energy;lamp.shadow_enabled=shadow;lamp.shadow_item_cull_mask=2
	attach(parent,lamp,name_text)

func static_dressing(parent:Node)->void:
	rect(parent,Rect2(988,536,504,212),Color(.075,.095,.11,.46),"InteriorShade")
	var i:=0
	for r:Rect2 in [Rect2(997,570,101,107),Rect2(1166,568,120,99),Rect2(1360,570,115,99)]:
		rect(parent,r,Color(.15,.17,.16,.13),"CargoBay%d"%i)
		var pts:=rect_poly(r);pts.append(pts[0]);line(parent,pts,Color(.76,.67,.43,.34),1,"CargoBayEdge%d"%i);i+=1
	for x:int in [1100,1123]:
		line(parent,PackedVector2Array([Vector2(x,759),Vector2(x,644)]),Color(.19,.21,.20,.42),4,"WheelTrack%d"%x)
		for y:int in range(650,759,7):
			line(parent,PackedVector2Array([Vector2(x-2,y),Vector2(x+2,y+1)]),Color(.55,.54,.42,.16),1,"Tread%d_%d"%[x,y])
	polygon(parent,PackedVector2Array([Vector2(1045,774),Vector2(1068,770),Vector2(1100,777),Vector2(1108,790),Vector2(1080,798),Vector2(1050,790)]),Color(.10,.18,.22,.78),"PipePuddle")
	line(parent,PackedVector2Array([Vector2(1146,758),Vector2(1200,758),Vector2(1200,771)]),Color("756e53"),2,"UtilityPipe")
	for x:int in [1110,1380]:
		rect(parent,Rect2(x-13,521,26,6),Color("242e32"),"LampHousing%d"%x)
		rect(parent,Rect2(x-10,524,20,2),Color("dec095"),"LampTube%d"%x)
	rect(parent,Rect2(1290,515,53,16),Color("313b3e"),"DispatchSignBack")
	rect(parent,Rect2(1293,517,47,12),Color("80755a"),"DispatchSignFace")
	label(parent,"HOLD 04",Vector2(1296,517),7,Color("292e2c"),"DispatchSignText")
	for x:int in range(880,1680,56):
		rect(parent,Rect2(x,816,24,2),Color("a7a084"),"RoadDash%d"%x)
	for y:int in [774,858]:
		line(parent,PackedVector2Array([Vector2(864,y),Vector2(1696,y)]),Color("8b947f"),1,"RoadEdge%d"%y)
	for b:Dictionary in layout.buildings:
		if b.id not in ["freight","inspection"]:continue
		for gap:Array in b.doors.get("s",[]):
			var x:float=b.rect[0]+gap[0];var y:float=b.rect[1]+b.rect[3]
			rect(parent,Rect2(x-float(gap[1])/2,y-7,gap[1],14),Color("55594c"),"Threshold%d_%d"%[x,y])
			for ix:int in range(int(x-float(gap[1])/2),int(x+float(gap[1])/2)-5,8):
				line(parent,PackedVector2Array([Vector2(ix,y-6),Vector2(ix+5,y+4)]),Color("a99e63"),2,"Stripe%d_%d"%[ix,y])

func run()->void:
	if FileAccess.file_exists(DIR+"freight_sector.tscn"):
		push_error("Migration is create-only. Existing native scene is the authored truth; use a fresh destination checkout.")
		quit(2);return
	manifest=JSON.parse_string(FileAccess.get_file_as_string("res://assets/world/map_studies/atlas.json"))
	layout=JSON.parse_string(FileAccess.get_file_as_string("res://game/presentation/northline_zone/zone.json"))
	make_terrain()
	sector=Node2D.new();sector.name="FreightSector"
	sector.set_meta("authored_world_bounds",BOUNDS)
	sector.set_meta("source_pixels_per_world_unit",3)
	sector.set_meta("migration_snapshot","36e363625861e3fe3758c345181a66891facdabd")
	sector.set_meta("runtime_layout_generator",false)
	var ground:=attach(sector,Node2D.new(),"Terrain")
	fill(ground,"Grass","grass",BOUNDS,Color("8f947f"))
	var i:=0
	for a:Dictionary in layout.surfaces:
		fill(ground,"Surface%d_%s"%[i,a.tile],str(a.tile),raw_rect(a.rect),Color(a.tint));i+=1
	var architecture:=attach(sector,Node2D.new(),"Architecture")
	for b:Dictionary in layout.buildings:
		if b.id not in ["freight","inspection"]:continue
		var building:=attach(architecture,Node2D.new(),str(b.id).to_pascal_case())
		fill(ground,str(b.id).to_pascal_case()+"Floor",str(b.floor),raw_rect(b.rect),Color("bbbcae"))
		make_wall_faces(building,b)
		label(building,str(b.name),Vector2(float(b.rect[0])+10,float(b.rect[1])-41),9,Color("e1d5b0"),"BuildingName")
		var wi:=0
		for w:Array in b.walls:
			solid(building,raw_rect(w),"WallSegment%02d"%wi);wi+=1
	var detail:=attach(sector,Node2D.new(),"GroundDetails")
	var di:=0
	for d:Dictionary in layout.decals:
		var at:=Vector2(d.at[0],d.at[1])
		if not BOUNDS.has_point(at):continue
		source_sprite(detail,str(d.asset),at,Color(d.tint),"Decal_%03d_%s"%[di,d.asset]);di+=1
	static_dressing(detail)
	var props:=attach(sector,Node2D.new(),"WorldProps") as Node2D
	props.y_sort_enabled=true
	for p:Dictionary in layout.props:
		var at:=Vector2(p.foot[0],p.foot[1])
		if not BOUNDS.has_point(at):continue
		var node:=make_prop(str(p.asset)).instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
		node.position=at
		attach(props,node,str(p.id).replace(".","_"))
		sector.set_editable_instance(node,true)
		node.get_node("SourceSprite").flip_h=bool(p.flip)
		node.get_node("SourceSprite").modulate=Color(p.tint)
		node.set_meta("legacy_prop_id",p.id)
		if not p.get("solid",true):node.get_node("Footprint").collision_layer=0
	var fences:=attach(sector,Node2D.new(),"FenceLine")
	for a:Array in layout.fences:
		if not BOUNDS.intersects(Rect2(a[0],float(a[1])-5,a[2],8)):continue
		for x:int in range(int(a[0]),int(a[0]+a[2]),30):
			source_sprite(fences,"fence",Vector2(x,float(a[1])-15),Color("b0b5a7"),"Fence%d_%d"%[x,a[1]])
		solid(fences,Rect2(a[0],float(a[1])-5,a[2],8),"FenceCollision%d"%a[0],false)
	var lighting:=attach(sector,Node2D.new(),"Lighting")
	var ambient:=CanvasModulate.new();ambient.color=Color(.84,.90,.87,1);attach(lighting,ambient,"OvercastAmbient")
	make_light(lighting,Vector2(1110,560),125,Color("ffd09a"),.86,"TaskLampWest")
	make_light(lighting,Vector2(1380,560),110,Color("ffc888"),.78,"TaskLampEast")
	make_light(lighting,Vector2(1014,700),78,Color("dfb98b"),.58,"WorkLamp")
	make_light(lighting,Vector2(1112,778),105,Color("9cbed0"),.45,"DoorLight")
	var anchors:=attach(sector,Node2D.new(),"Anchors")
	for entry:Array in [["FreightCamera",Vector2(1288,638)],["EntranceCamera",Vector2(1184,650)],["InspectionCamera",Vector2(1376,652)],["WalkStart",Vector2(1112,795)],["SouthDoorWest",Vector2(1112,750)],["SouthDoorEast",Vector2(1382,750)]]:
		var marker:=Marker2D.new();marker.position=entry[1];attach(anchors,marker,entry[0])
	var packed:=PackedScene.new();require(packed.pack(sector)==OK,"pack native sector")
	require(ResourceSaver.save(packed,DIR+"freight_sector.tscn")==OK,"save native sector")
	print("NATIVE_MIGRATION_RESULT props=",prop_scenes.size()," decals=",di," failures=",failures)
	sector.free()
	quit(0 if failures==0 else 1)
