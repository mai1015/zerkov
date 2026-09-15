class_name ZExtractionMapStudyWorld
extends Node2D
## Additive environment study. No RaidAuthority, inventory, AI or settlement handles.
## Every texture region is derived from the supplied packs; geometry is authored in maps.json.
const ATLAS_PATH := "res://assets/world/map_studies/atlas.webp"
const MANIFEST_PATH := "res://assets/world/map_studies/atlas.json"
var layout: Dictionary = {}
var assets: Dictionary = {}
var atlas: Texture2D
var tactical: bool = false
var props_root: Node2D
var ambient: CanvasModulate
var active_id: String = ""

func configure(data: Dictionary) -> void:
	layout = data.duplicate(true)
	active_id = str(layout["id"])
	assets = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST_PATH))["assets"]
	atlas = load(ATLAS_PATH)
	for child: Node in get_children():
		remove_child(child)
		child.queue_free()
	props_root = Node2D.new()
	props_root.name = "AuthoredProps"
	props_root.y_sort_enabled = true
	add_child(props_root)
	for item: Dictionary in layout["props"]:
		_spawn_prop(item)
	for fence: Array in layout["fences"]:
		for x: int in range(int(fence[0]), int(fence[0] + fence[2]), 30):
			_spawn_prop({"id":"fence_%d_%d" % [x,fence[1]], "asset":"fence", "foot":[x+15,fence[1]], "flip":false, "tint":"b0b5a7"})
	for b: Dictionary in layout["buildings"]:
		_make_building(b)
	ambient = CanvasModulate.new()
	ambient.color = Color(0.86, 0.90, 0.83, 1.0) if active_id == "northline" else Color(0.84, 0.90, 0.87, 1.0)
	add_child(ambient)
	for fixture: Dictionary in layout["lights"]:
		_make_light(fixture)
	_make_collision()
	queue_redraw()

func _make_collision() -> void:
	var body := StaticBody2D.new()
	body.name = "AuthoredLayoutCollision"
	for entry: Array in layout["collision_rects"] + layout["cover_rects"]:
		var shape := RectangleShape2D.new()
		shape.size = Vector2(entry[2],entry[3])
		var node := CollisionShape2D.new()
		node.shape = shape
		node.position = Vector2(entry[0]+entry[2]/2.0,entry[1]+entry[3]/2.0)
		body.add_child(node)
	add_child(body)

func set_tactical(value: bool) -> void:
	tactical = value
	queue_redraw()

func asset_rect(id: String) -> Rect2:
	var a: Array = assets[id]["rect"]
	return Rect2(float(a[0]),float(a[1]),float(a[2]),float(a[3]))

func stamp(id: String, at: Vector2, tint: Color = Color.WHITE) -> void:
	var r := asset_rect(id)
	draw_texture_rect_region(atlas,Rect2(at,r.size),r,tint)

func _spawn_prop(item: Dictionary) -> void:
	var key: String = item["asset"]
	var r := asset_rect(key)
	var anchor := Node2D.new()
	anchor.name = str(item["id"]).replace(".","_")
	anchor.position = Vector2(item["foot"][0],item["foot"][1])
	# Pixel-aligned shadow sits on the prop's actual support plane.
	var shade := Polygon2D.new()
	var width := r.size.x * 0.44
	shade.polygon = PackedVector2Array([Vector2(-width,-5),Vector2(width,-5),Vector2(width+17,6),Vector2(-width+7,5)])
	shade.color = Color(0.035,0.055,0.055,0.36)
	anchor.add_child(shade)
	var sprite := Sprite2D.new()
	sprite.name = "SourceSprite"
	sprite.texture = atlas
	sprite.region_enabled = true
	sprite.region_rect = r
	sprite.region_filter_clip_enabled = true
	sprite.centered = false
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	sprite.position = Vector2(-floor(r.size.x/2),-r.size.y)
	sprite.flip_h = bool(item.get("flip",false))
	sprite.modulate = Color(str(item.get("tint","ffffff")))
	anchor.add_child(sprite)
	props_root.add_child(anchor)

func _make_building(b: Dictionary) -> void:
	var a: Array = b["rect"]
	var x: float=a[0]; var y: float=a[1]; var w: float=a[2]; var h: float=a[3]
	var r := asset_rect(b["wall"])
	# North walls have source-art south faces. Side/front walls are deliberately cut away.
	for px: int in range(int(x),int(x+w),int(r.size.x)):
		var wall := Sprite2D.new()
		wall.texture=atlas; wall.region_enabled=true;wall.region_rect=r
		wall.region_filter_clip_enabled=true;wall.centered=false
		wall.position=Vector2(px,y-r.size.y+6)
		wall.modulate=Color("aeafa1")
		wall.texture_filter=CanvasItem.TEXTURE_FILTER_NEAREST
		add_child(wall)
	var title := Label.new()
	title.position=Vector2(x+10,y-34)
	title.text=b["name"]
	title.add_theme_font_size_override("font_size",8)
	title.add_theme_color_override("font_color",Color("e2d8b1"))
	title.add_theme_color_override("font_shadow_color",Color.BLACK)
	title.add_theme_constant_override("shadow_offset_x",1)
	title.add_theme_constant_override("shadow_offset_y",1)
	title.mouse_filter=Control.MOUSE_FILTER_IGNORE
	add_child(title)

func _make_light(data: Dictionary) -> void:
	var gradient := Gradient.new()
	gradient.offsets=PackedFloat32Array([0,0.20,0.65,1])
	gradient.colors=PackedColorArray([Color(1,1,1,0.85),Color(1,1,1,0.32),Color(1,1,1,0.06),Color(1,1,1,0)])
	var tex := GradientTexture2D.new()
	tex.gradient=gradient;tex.width=128;tex.height=128
	tex.fill=GradientTexture2D.FILL_RADIAL
	tex.fill_from=Vector2(0.5,0.5);tex.fill_to=Vector2(1,0.5)
	var light:=PointLight2D.new()
	light.texture=tex;light.texture_scale=float(data["radius"])/64.0
	light.position=Vector2(data["at"][0],data["at"][1])
	light.color=Color(data["color"]);light.energy=1.10
	add_child(light)

func _draw() -> void:
	if layout.is_empty() or atlas==null:return
	var sz: Array=layout["size"]
	_tiled(str(layout["base"]),Rect2(0,0,sz[0],sz[1]),Color("8b907b"),true)
	for patch: Dictionary in layout["surfaces"]:
		var a: Array=patch["rect"]
		_tiled(patch["tile"],Rect2(a[0],a[1],a[2],a[3]),Color(patch["tint"]),true)
	for rail: Array in layout["rails"]:
		var x: int=rail[0];var y: int=rail[1];var width: int=rail[2]
		draw_rect(Rect2(x,y-17,width,42),Color("555c51"))
		for px: int in range(x,x+width,14):
			draw_rect(Rect2(px,y-11,5,30),Color("665e4c"));draw_rect(Rect2(px+1,y-10,3,1),Color("8d8062"))
		for ry: int in [y-5,y+11]:
			draw_rect(Rect2(x,ry,width,3),Color("232d2e"));draw_line(Vector2(x,ry),Vector2(x+width,ry),Color("aaa48b"),1)
	for road: Array in layout["roads"]:
		var r:=Rect2(road[0],road[1],road[2],road[3])
		if road[4]=="h":
			for px: int in range(int(r.position.x+12),int(r.end.x),52):
				draw_rect(Rect2(px,r.get_center().y,23,2),Color("a19a76"))
			draw_line(r.position+Vector2(0,7),Vector2(r.end.x,r.position.y+7),Color("9d9f8a"),1)
		else:
			for py: int in range(int(r.position.y+12),int(r.end.y),52):
				draw_rect(Rect2(r.get_center().x,py,2,23),Color("a19a76"))
	# Zebra crossing is authored road geometry, not an overlay screenshot.
	if active_id=="mercury":
		for px: int in range(302,374,10):draw_rect(Rect2(px,267,5,12),Color("929a8c"))
		for py: int in range(291,348,10):draw_rect(Rect2(385,py,12,5),Color("929a8c"))
	else:
		for px: int in range(118,397,40):
			draw_line(Vector2(px,345),Vector2(px,389),Color("a5a181"),1)
	for b: Dictionary in layout["buildings"]:
		var a: Array=b["rect"];var r:=Rect2(a[0],a[1],a[2],a[3])
		draw_rect(r.grow(7),Color("182523"))
		_tiled(b["floor"],r,Color("bbbcae"),true)
		# Directional contact shadows along the north/west boundaries.
		for d: int in range(14):
			draw_rect(Rect2(r.position+Vector2(0,d),Vector2(r.size.x,1)),Color(0.01,0.025,0.022,0.30*(1-float(d)/14)))
			draw_rect(Rect2(r.position+Vector2(d,0),Vector2(1,r.size.y)),Color(0.01,0.025,0.022,0.25*(1-float(d)/14)))
		for c: Array in _wall_rects(b):
			var cr:=Rect2(c[0],c[1],c[2],c[3])
			draw_rect(cr,Color("48504a"));draw_line(cr.position,Vector2(cr.end.x,cr.position.y),Color("7c806c"),1)
		var door_x: float=r.position.x+r.size.x*float(b["door"])
		draw_rect(Rect2(door_x-20,r.end.y-7,40,14),Color("55594c"))
		for ix: int in range(int(door_x-20),int(door_x+20),8):draw_line(Vector2(ix,r.end.y-6),Vector2(ix+5,r.end.y+4),Color("a99e63"),2)
	for item: Dictionary in layout["decals"]:
		stamp(item["asset"],Vector2(item["at"][0],item["at"][1]),Color(item["tint"]))
	for label: Dictionary in layout["labels"]:
		draw_string(ThemeDB.fallback_font,Vector2(label["at"][0],label["at"][1]),label["text"],HORIZONTAL_ALIGNMENT_LEFT,-1,9,Color("bcc0a3"))
	if tactical:
		for route: Dictionary in layout["routes"]:
			var pts:=PackedVector2Array()
			for p: Array in route["points"]:pts.append(Vector2(p[0],p[1]))
			draw_polyline(pts,Color(0.86,0.68,0.34,0.75) if route["name"].begins_with("Fast") or route["name"].begins_with("Street") else Color(0.35,0.78,0.71,0.75),2)
		for item: Dictionary in layout["pois"]:
			var at:=Vector2(item["at"][0],item["at"][1])
			draw_circle(at,6,Color("d7b06c"));draw_string(ThemeDB.fallback_font,at+Vector2(10,-5),item["name"],HORIZONTAL_ALIGNMENT_LEFT,-1,9,Color("fff1c9"))
		for e: Dictionary in layout["exits"]:
			var at:=Vector2(e["at"][0],e["at"][1]);draw_rect(Rect2(at-Vector2(8,8),Vector2(16,16)),Color("6fb59d"),false,2)
			draw_string(ThemeDB.fallback_font,at+Vector2(12,-6),e["name"],HORIZONTAL_ALIGNMENT_LEFT,-1,9,Color("b8e2ca"))

func _wall_rects(b: Dictionary) -> Array:
	var a: Array=b["rect"];var x:float=a[0];var y:float=a[1];var w:float=a[2];var h:float=a[3];var door:float=b["door"]
	var result:Array=[[x-5,y,10,h],[x,y+h-5,w*door-22,10],[x+w*door+22,y+h-5,w*(1-door)-22,10]]
	if b["side_door"]:result += [[x+w-5,y,10,h*.5-20],[x+w-5,y+h*.5+20,10,h*.5-20]]
	else:result.append([x+w-5,y,10,h])
	return result

func _tiled(id:String,r:Rect2,tint:Color,variation:bool) -> void:
	var source:=asset_rect(id)
	for y:int in range(int(r.position.y),int(r.end.y),16):
		for x:int in range(int(r.position.x),int(r.end.x),16):
			var chosen:=source
			var cell:int=absi((x*7381+y*1933+int(layout["seed"]))%97)
			if id=="road" and cell%7==0:chosen=asset_rect("road_crack")
			if id=="concrete" and cell%9==0:chosen=asset_rect("concrete_crack")
			var size:=Vector2(minf(16,r.end.x-x),minf(16,r.end.y-y))
			var shade:=0.94+float(cell%7)*0.009 if variation else 1.0
			draw_texture_rect_region(atlas,Rect2(Vector2(x,y),size),Rect2(chosen.position,size),Color(tint.r*shade,tint.g*shade,tint.b*shade,tint.a))
