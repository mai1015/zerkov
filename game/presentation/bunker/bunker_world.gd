class_name ZBunkerHideoutWorld
extends Node2D
## Authored cutaway presentation. Wall union, face projection and sprite depth
## come from the kit contract. No physics, inventory, power or crafting owner.
const KIT_PATH := "res://game/presentation/bunker/bunker_kit.json"
const LAYOUT_PATH := "res://game/presentation/bunker/bunker_layout.json"
const ATLAS_PATH := "res://assets/world/bunker/bunker_atlas.webp"
const W := 640
const H := 360
var kit: Dictionary = {}
var layout: Dictionary = {}
var assets: Dictionary = {}
var footprints: Array[Rect2] = []
var plan := PackedByteArray()
var _atlas_image: Image
var selected_room := "workshop"
var valid := false

func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	kit = JSON.parse_string(FileAccess.get_file_as_string(KIT_PATH))
	layout = JSON.parse_string(FileAccess.get_file_as_string(LAYOUT_PATH))
	if kit.get("schema_version") != 1 or layout.get("schema_version") != 1:
		push_error("BUNKER_DATA_SCHEMA")
		return
	var atlas := load(ATLAS_PATH) as Texture2D
	if atlas == null:
		push_error("BUNKER_ATLAS_MISSING")
		return
	_atlas_image = atlas.get_image()
	for key: String in kit["assets"]:
		var r: Array = kit["assets"][key]["rect"]
		var region := AtlasTexture.new()
		region.atlas = atlas
		region.region = Rect2(r[0], r[1], r[2], r[3])
		region.filter_clip = true
		assets[key] = region
	plan.resize(W * H)
	plan.fill(0)
	for r: Array in layout["walls"]:
		_fill_plan(r, 1)
	for r: Array in layout["openings"]:
		_fill_plan(r, 0)
	_build_walls()
	for p: Array in layout["props"]:
		_place_prop(p)
	for p: Array in layout["fixtures"]:
		_place_fixture(p)
	valid = true
	queue_redraw()

func _fill_plan(r: Array, value: int) -> void:
	for y: int in range(int(r[1]), int(r[1] + r[3])):
		for x: int in range(int(r[0]), int(r[0] + r[2])):
			plan[y * W + x] = value

func _solid(x: int, y: int) -> bool:
	return x >= 0 and x < W and y >= 0 and y < H and plan[y * W + x] == 1

func _source_pixel(id: String, x: int, y: int) -> Color:
	var r: Array = kit["assets"][id]["rect"]
	return _atlas_image.get_pixel(int(r[0]) + posmod(x, int(r[2])), int(r[1]) + y)

func _build_walls() -> void:
	# Summed-area table: exact eight-pixel square erosion, including T/X joins.
	var sums := PackedInt32Array()
	sums.resize((W + 1) * (H + 1))
	sums.fill(0)
	for y: int in range(H):
		var row := 0
		for x: int in range(W):
			row += int(plan[y * W + x])
			sums[(y + 1) * (W + 1) + x + 1] = sums[y * (W + 1) + x + 1] + row
	var cap := Image.create(W, H, false, Image.FORMAT_RGBA8)
	cap.fill(Color.TRANSPARENT)
	var faces: Dictionary = {}
	for y: int in range(H):
		for x: int in range(W):
			if not _solid(x, y):
				continue
			var core := false
			if x >= 8 and x + 8 < W and y >= 8 and y + 8 < H:
				var stride := W + 1
				var count: int = sums[(y + 9) * stride + x + 9] - sums[(y - 8) * stride + x + 9] - sums[(y + 9) * stride + x - 8] + sums[(y - 8) * stride + x - 8]
				core = count == 289
			cap.set_pixel(x, y, _source_pixel("wall-core" if core else "wall-cap", x, y % 16))
			if _solid(x, y + 1):
				continue
			if not faces.has(y):
				var face := Image.create(W, 40, false, Image.FORMAT_RGBA8)
				face.fill(Color.TRANSPARENT)
				faces[y] = face
			var face: Image = faces[y]
			var face_id := "wall-face-painted" if y < 100 else "wall-face-plain"
			if x % 80 < 16:
				face_id = "wall-face-joint"
			for row: int in range(40):
				if y + row + 1 >= H or _solid(x, y + row + 1):
					break
				var pixel: Color = _source_pixel(face_id, x, row)
				if row >= 37:
					pixel = _source_pixel("wall-base", x, row - 37)
				face.set_pixel(x, row, pixel)
	for y: int in faces:
		var sprite := Sprite2D.new()
		sprite.name = "WallFace_%d" % y
		sprite.texture = ImageTexture.create_from_image(faces[y])
		sprite.centered = false
		sprite.position.y = y + 1
		sprite.z_index = y + 40
		add_child(sprite)
	var rim := Sprite2D.new()
	rim.name = "WallPlanUnion"
	rim.texture = ImageTexture.create_from_image(cap)
	rim.centered = false
	rim.z_index = 500
	add_child(rim)

func _place_prop(p: Array) -> void:
	var id: String = p[1]
	var record: Dictionary = kit["assets"][id]
	var anchor: Array = record["anchor"]
	var sprite := Sprite2D.new()
	sprite.name = String(p[0]).replace(".", "_")
	sprite.texture = assets[id]
	sprite.centered = false
	sprite.position = Vector2(p[2] - anchor[0], p[3] - anchor[1])
	sprite.z_index = int(p[3])
	add_child(sprite)
	var fp: Array = record["footprint"]
	if fp.size() == 4:
		footprints.append(Rect2(sprite.position + Vector2(fp[0], fp[1]), Vector2(fp[2], fp[3])))

func _place_fixture(p: Array) -> void:
	var sprite := Sprite2D.new()
	var id: String = p[1]
	sprite.name = String(p[0]).replace(".", "_")
	sprite.texture = assets[id]
	sprite.centered = false
	sprite.position = Vector2(float(p[2]) - sprite.texture.get_width() * 0.5, float(p[3]))
	sprite.z_index = 96 if float(p[3]) < 100 else 264
	add_child(sprite)

func _draw() -> void:
	if not valid:
		return
	# Native 16px phase never restarts at a room boundary.
	for y: int in range(48, 320, 16):
		for x: int in range(32, 496, 16):
			var id := "floor-concrete-a"
			for room: Dictionary in layout["rooms"]:
				var r: Array = room["rect"]
				if Rect2(r[0], r[1], r[2], r[3]).has_point(Vector2(x + 8, y + 8)):
					id = String(room["material"]) + ("-b" if (x * 7 + y * 11) % 80 == 0 else "-a")
			if id.begins_with("floor-steel"):
				id = "floor-steel-tread" if x % 64 == 0 else "floor-steel-plain"
			draw_texture(assets[id], Vector2(x, y))
	for p: Array in layout["overlays"]:
		draw_texture(assets[p[0]], Vector2(p[1], p[2]))
	# Quiet amber threshold paint; it is not navigation/collision data.
	for r: Array in layout["openings"]:
		for x: int in range(int(r[0]), int(r[0] + r[2]), 8):
			draw_line(Vector2(x, r[1] + 17), Vector2(x + 4, r[1] + 21), Color("b08a43"), 2)
	for fp: Rect2 in footprints:
		draw_rect(Rect2(fp.position + Vector2(-2, 3), fp.size + Vector2(4, 3)), Color(0, 0, 0, 0.28))
	# Staging lane and exit guide stay in the negative space between equipment.
	draw_line(Vector2(208, 200), Vector2(320, 200), Color(0.7, 0.61, 0.4, 0.25), 1)
	for y: int in [280, 290, 300]:
		draw_polyline(PackedVector2Array([Vector2(266, y), Vector2(272, y + 3), Vector2(278, y)]), Color("b79658"), 1)

## Free floor in 640x360 world space: outside the wall plan, which already has
## its doorways carved out, and clear of the prop footprints the props declare.
func is_walkable(point: Vector2) -> bool:
	if not valid or _solid(int(floorf(point.x)), int(floorf(point.y))):
		return false
	for footprint: Rect2 in footprints:
		if footprint.has_point(point):
			return false
	return true


func room_at(point: Vector2) -> String:
	for room: Dictionary in layout.get("rooms", []):
		var r: Array = room["rect"]
		if Rect2(r[0], r[1], r[2], r[3]).has_point(point):
			return room["id"]
	return ""
