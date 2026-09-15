class_name ZNorthlineZoneWorld
extends "res://game/presentation/map_studies/map_study_world.gd"
## Full environment only. Shared asset stamps and native collision, no raid owners.
## Floor, walls, cover and water barriers come from the same checked authoring data.
var overview_mode: bool = false
var visible_bounds := Rect2(0,0,2688,1792)

func _make_building(b: Dictionary) -> void:
	var a: Array = b["rect"]
	var source := asset_rect(str(b["wall"]))
	for wall_data: Array in b["walls"]:
		# North-facing projection is only drawn where the authored wall actually exists.
		if absf(float(wall_data[1]) - float(a[1]) + 4) > 0.1 or float(wall_data[3]) > 8.1:
			continue
		for x: int in range(int(wall_data[0]), int(wall_data[0] + wall_data[2]), int(source.size.x)):
			var width := minf(source.size.x, wall_data[0] + wall_data[2] - x)
			var sprite := Sprite2D.new()
			sprite.texture = atlas
			sprite.region_enabled = true
			sprite.region_rect = Rect2(source.position, Vector2(width, source.size.y))
			sprite.region_filter_clip_enabled = true
			sprite.centered = false
			sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
			sprite.position = Vector2(x, a[1] - source.size.y + 4)
			sprite.modulate = Color("b4b4a4")
			add_child(sprite)
	var title := Label.new()
	title.position = Vector2(a[0] + 10, a[1] - 41)
	title.text = str(b["name"])
	title.add_theme_font_size_override("font_size", 9)
	title.add_theme_color_override("font_color", Color("e1d5b0"))
	title.add_theme_color_override("font_shadow_color", Color.BLACK)
	title.add_theme_constant_override("shadow_offset_x", 1)
	title.add_theme_constant_override("shadow_offset_y", 1)
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title.add_to_group("northline_building_labels")
	add_child(title)

func set_overview(value: bool) -> void:
	overview_mode = value
	for child: Node in get_children():
		if child is Label:
			child.visible = not value
	queue_redraw()

func _draw() -> void:
	if layout.is_empty() or atlas == null:
		return
	var sz: Array = layout["size"]
	_tiled("grass", Rect2(0, 0, sz[0], sz[1]), Color("8f947f"), true)
	for patch: Dictionary in layout["surfaces"]:
		var a: Array = patch["rect"]
		_tiled(str(patch["tile"]), Rect2(a[0], a[1], a[2], a[3]), Color(str(patch["tint"])), true)
	for water: Array in layout.get("water_rects", []):
		var r := Rect2(water[0], water[1], water[2], water[3])
		draw_rect(r.grow(4), Color("3d4d49"))
		draw_rect(r, Color("324a47"))
		for y: int in range(int(r.position.y) + 5, int(r.end.y), 11):
			draw_line(Vector2(r.position.x + 9, y), Vector2(r.end.x - 8, y), Color("466058"), 1)
	for rail: Array in layout["rails"]:
		var x: int = rail[0]
		var y: int = rail[1]
		var width: int = rail[2]
		draw_rect(Rect2(x, y - 17, width, 42), Color("555c51"))
		for px: int in range(x, x + width, 14):
			draw_rect(Rect2(px, y - 11, 5, 30), Color("665e4c"))
			draw_rect(Rect2(px + 1, y - 10, 3, 1), Color("8d8062"))
		for ry: int in [y - 5, y + 11]:
			draw_rect(Rect2(x, ry, width, 3), Color("232d2e"))
			draw_line(Vector2(x, ry), Vector2(x + width, ry), Color("aaa48b"), 1)
	for road: Array in layout["roads"]:
		var r := Rect2(road[0], road[1], road[2], road[3])
		if road[4] == "h":
			for x: int in range(int(r.position.x) + 16, int(r.end.x) - 24, 56):
				draw_rect(Rect2(x, r.get_center().y, 24, 2), Color("a7a084"))
			draw_line(r.position + Vector2(0, 6), Vector2(r.end.x, r.position.y + 6), Color("8b947f"), 1)
		else:
			for y: int in range(int(r.position.y) + 16, int(r.end.y) - 24, 56):
				draw_rect(Rect2(r.get_center().x, y, 2, 24), Color("a7a084"))
	for parking: Array in layout.get("parking", []):
		for x: int in range(int(parking[0]), int(parking[0] + parking[2]), 48):
			draw_line(Vector2(x, parking[1]), Vector2(x, parking[1] + parking[3]), Color("8b8e79"), 1)
	for building: Dictionary in layout["buildings"]:
		var a: Array = building["rect"]
		var r := Rect2(a[0], a[1], a[2], a[3])
		draw_rect(r.grow(7), Color("182523"))
		_tiled(str(building["floor"]), r, Color("bbbcae"), true)
		for d: int in range(14):
			var alpha := 0.27 * (1.0 - float(d) / 14)
			draw_rect(Rect2(r.position + Vector2(0, d), Vector2(r.size.x, 1)), Color(0.01, 0.025, 0.022, alpha))
			draw_rect(Rect2(r.position + Vector2(d, 0), Vector2(1, r.size.y)), Color(0.01, 0.025, 0.022, alpha))
		for wall: Array in building["walls"]:
			var wr := Rect2(wall[0], wall[1], wall[2], wall[3])
			draw_rect(wr, Color("50584f"))
			draw_line(wr.position, Vector2(wr.end.x, wr.position.y), Color("88907b"), 1)
		for gap: Array in building["doors"].get("s", []):
			var gx: float = r.position.x + float(gap[0])
			var gw: float = gap[1]
			draw_rect(Rect2(gx - gw / 2, r.end.y - 7, gw, 14), Color("55594c"))
			for ix: int in range(int(gx - gw / 2), int(gx + gw / 2) - 5, 8):
				draw_line(Vector2(ix, r.end.y - 6), Vector2(ix + 5, r.end.y + 4), Color("a99e63"), 2)
	for item: Dictionary in layout["decals"]:
		stamp(str(item["asset"]), Vector2(item["at"][0], item["at"][1]), Color(str(item["tint"])))
	if not overview_mode:
		for label: Dictionary in layout["labels"]:
			draw_string(ThemeDB.fallback_font, Vector2(label["at"][0], label["at"][1]), str(label["text"]), HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Color("b9bda1"))
	# Boundary is visible as a concrete edge, not an invisible restriction.
	draw_rect(Rect2(6, 6, sz[0] - 12, sz[1] - 12), Color("667468"), false, 5)
	# Render the open gates back over the edge from their underlying surface.
	for r: Rect2 in [Rect2(0,758,14,128),Rect2(2674,278,14,116),Rect2(1810,1778,96,14)]:
		_tiled("road", r, Color("9da998"), false)

func update_visible_bounds(bounds: Rect2) -> void:
	if visible_bounds != bounds:
		visible_bounds = bounds
		queue_redraw()
	for child: Node in get_children():
		if child is PointLight2D:
			child.enabled = not overview_mode and bounds.grow(110).has_point(child.position)

func _tiled(id: String, r: Rect2, tint: Color, variation: bool) -> void:
	# Cull source quads, not just draw calls: keep atlas phase anchored in world space.
	var clip := r.intersection(visible_bounds.grow(16))
	if not clip.has_area():
		return
	var source := asset_rect(id)
	var start_x := int(r.position.x) + maxi(0, int(floor((clip.position.x-r.position.x)/16))) * 16
	var start_y := int(r.position.y) + maxi(0, int(floor((clip.position.y-r.position.y)/16))) * 16
	for y: int in range(start_y, int(clip.end.y), 16):
		for x: int in range(start_x, int(clip.end.x), 16):
			var chosen := source
			var cell: int = absi((x*7381+y*1933+int(layout["seed"]))%97)
			if id == "road" and cell%7 == 0:
				chosen = asset_rect("road_crack")
			if id == "concrete" and cell%9 == 0:
				chosen = asset_rect("concrete_crack")
			var tile_size := Vector2(minf(16,r.end.x-x),minf(16,r.end.y-y))
			var shade := 0.94+float(cell%7)*0.009 if variation else 1.0
			draw_texture_rect_region(atlas,Rect2(Vector2(x,y),tile_size),Rect2(chosen.position,tile_size),Color(tint.r*shade,tint.g*shade,tint.b*shade,tint.a))
