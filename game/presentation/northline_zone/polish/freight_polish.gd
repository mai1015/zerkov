class_name ZFreightPolish
extends Node2D
## Local presentation-only treatment. Does not add/move gameplay collision,
## advance RaidClock, emit noise, infer loot or change authoritative world data.
## Fixed effects counts and a sampled clock; no per-frame node creation.
const AREA := Rect2(820, 470, 900, 470)
const WIND = preload("res://game/presentation/northline_zone/polish/anchored_wind.gdshader")
const PLANTS: Array[String] = ["weeds", "shrub", "fern"]
const MAX_PLANTS: int = 48
const MAX_DUST: int = 24
var world: Node2D
var enabled: bool = true
var motion_enabled: bool = true
var frozen: bool = false
var seconds: float = 0.0
var active: bool = true
var _sample: int = -1
var _wind: ShaderMaterial
var _plants: Array[Sprite2D] = []
var _handled_decals: Dictionary = {}
var _lamps: Array[PointLight2D] = []
var _original_prop_colors: Dictionary = {}
var _original_shadows: Dictionary = {}
var _ground: Node2D
var _details: Node2D
var _walls: Node2D
var _effects: Node2D

func configure(owner_world: Node2D) -> void:
	world = owner_world
	name = "FreightPolish"
	_wind = ShaderMaterial.new()
	_wind.shader = WIND
	_ground = Node2D.new()
	_ground.name = "FreightGroundStory"
	_ground.draw.connect(_draw_ground)
	world.add_child(_ground)
	world.move_child(_ground, 0) # After world floor; before y-sorted props.
	_details = Node2D.new()
	_details.name = "FreightFixtures"
	_details.draw.connect(_draw_fixtures)
	add_child(_details)
	_effects = Node2D.new()
	_effects.name = "BoundedAmbientEffects"
	_effects.draw.connect(_draw_motion)
	add_child(_effects)
	_walls = Node2D.new()
	_walls.name = "AuthoredLightOccluders"
	add_child(_walls)
	for building: Dictionary in world.layout["buildings"]:
		if building["id"] not in ["freight", "inspection", "receiving", "cold"]:
			continue
		for a: Array in building["walls"]:
			_occluder(Rect2(a[0], a[1], a[2], a[3]))
	# Rendering silhouettes derive from explicit cover footprints, never vice versa.
	for a: Array in world.layout["cover_rects"]:
		var r := Rect2(a[0], a[1], a[2], a[3])
		if Rect2(980, 530, 520, 226).intersects(r):
			_occluder(r)
	for child: Node in world.props_root.get_children():
		if not child is Node2D or not Rect2(980, 530, 520, 226).has_point(child.position):
			continue
		var sprite := child.get_node_or_null("SourceSprite") as Sprite2D
		if sprite == null:
			continue
		_original_prop_colors[sprite] = sprite.modulate
		# Replace the long generic polygon with a compact contact shadow.
		var shade := child.get_child(0) as Polygon2D
		if shade != null:
			_original_shadows[shade] = shade.polygon
	for decal: Dictionary in world.layout["decals"]:
		var at := Vector2(decal["at"][0], decal["at"][1])
		if decal["asset"] not in PLANTS or not AREA.has_point(at) or _plants.size() >= MAX_PLANTS:
			continue
		var r: Rect2 = world.asset_rect(decal["asset"])
		var sprite := Sprite2D.new()
		sprite.name = "WindPlant%d" % _plants.size()
		sprite.texture = world.atlas
		sprite.region_enabled = true
		sprite.region_filter_clip_enabled = true
		sprite.region_rect = r
		sprite.centered = false
		sprite.position = at
		sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		sprite.modulate = Color(decal["tint"])
		sprite.material = _wind
		sprite.set_instance_shader_parameter("sheet_height", r.size.y)
		sprite.set_instance_shader_parameter("phase_offset", fmod(at.x * 0.71 + at.y * 0.37, TAU))
		_ground.add_child(sprite)
		_plants.append(sprite)
		_handled_decals[_decal_key(decal)] = true
	# Local task lamps / damaged utility run. Shadows stop at solid authored walls.
	_lamp(Vector2(1110, 560), 125, Color("ffd09a"), 0.86)
	_lamp(Vector2(1380, 560), 110, Color("ffc888"), 0.78)
	_lamp(Vector2(1014, 700), 78, Color("dfb98b"), 0.58)
	_lamp(Vector2(1112, 778), 105, Color("9cbed0"), 0.45)
	apply_enabled()
	sample_at(0.0)

func _occluder(r: Rect2) -> void:
	var polygon := OccluderPolygon2D.new()
	polygon.polygon = PackedVector2Array([r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)])
	var node := LightOccluder2D.new()
	node.occluder = polygon
	node.occluder_light_mask = 2
	node.sdf_collision = false
	_walls.add_child(node)

func _lamp(at: Vector2, radius: float, color: Color, energy: float) -> void:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0, 0.16, 0.62, 1])
	g.colors = PackedColorArray([Color(1,1,1,0.95), Color(1,1,1,0.65), Color(1,1,1,0.16), Color(1,1,1,0)])
	var texture := GradientTexture2D.new()
	texture.gradient = g
	texture.width = 128
	texture.height = 128
	texture.fill = GradientTexture2D.FILL_RADIAL
	texture.fill_from = Vector2(0.5,0.5)
	texture.fill_to = Vector2(1,0.5)
	var lamp := PointLight2D.new()
	lamp.position = at
	lamp.texture = texture
	lamp.texture_scale = radius / 64.0
	lamp.color = color
	lamp.energy = energy
	lamp.shadow_enabled = true
	lamp.shadow_item_cull_mask = 2
	lamp.shadow_filter = Light2D.SHADOW_FILTER_NONE
	lamp.set_meta("base_energy", energy)
	add_child(lamp)
	_lamps.append(lamp)

func handles_decal(decal: Dictionary) -> bool:
	return enabled and _handled_decals.has(_decal_key(decal))

func _decal_key(decal: Dictionary) -> String:
	return "%s:%s" % [decal["asset"], str(decal["at"])]

func set_enabled(value: bool) -> void:
	enabled = value
	apply_enabled()
	world.queue_redraw()

func apply_enabled() -> void:
	visible = enabled and active
	_ground.visible = enabled
	for sprite: Sprite2D in _original_prop_colors:
		sprite.modulate = _original_prop_colors[sprite] * (Color(0.88,0.93,1.0) if enabled else Color.WHITE)
	for shade: Polygon2D in _original_shadows:
		if enabled:
			var old: PackedVector2Array = _original_shadows[shade]
			var w: float = absf(old[0].x)
			shade.polygon = PackedVector2Array([Vector2(-w,-4), Vector2(w,-4), Vector2(w+4,3), Vector2(-w+2,3)])
		else:
			shade.polygon = _original_shadows[shade]
	for lamp: PointLight2D in _lamps:
		lamp.enabled = enabled and active
	_ground.queue_redraw()
	_details.queue_redraw()
	_effects.queue_redraw()

func update_camera(bounds: Rect2, is_overview: bool) -> void:
	active = not is_overview and bounds.intersects(AREA)
	visible = enabled and active
	for lamp: PointLight2D in _lamps:
		lamp.enabled = enabled and active and bounds.grow(140).has_point(lamp.position)

func freeze_at(value: float) -> bool:
	if not is_finite(value) or value < 0.0 or value > 86400.0:
		return false
	frozen = true
	return sample_at(value)

func sample_at(value: float) -> bool:
	if not is_finite(value) or value < 0.0 or value > 86400.0:
		return false
	seconds = value
	_sample = int(floor(seconds * 12.0))
	var visual_time := float(_sample) / 12.0 if motion_enabled else 0.0
	_wind.set_shader_parameter("visual_seconds", visual_time)
	_wind.set_shader_parameter("strength", 1.0 if motion_enabled else 0.0)
	# Slow intensity drift, not strobing. Bounded 96-100% output.
	for i: int in range(_lamps.size()):
		_lamps[i].energy = float(_lamps[i].get_meta("base_energy")) * (0.98 + 0.02 * sin(visual_time * 0.7 + i))
	_effects.queue_redraw()
	return true

func set_reduced_motion(value: bool) -> void:
	motion_enabled = not value
	sample_at(seconds)

func _process(delta: float) -> void:
	if not enabled or not active or frozen or not motion_enabled:
		return
	seconds = fmod(seconds + delta, 86400.0)
	var frame := int(floor(seconds * 12.0))
	if frame != _sample:
		sample_at(seconds)

func diagnostic_snapshot() -> Dictionary:
	return {"enabled": enabled, "active": active, "seconds": seconds, "sample": _sample,
		"plants": _plants.size(), "lights": _lamps.size(), "occluders": _walls.get_child_count(),
		"motion_enabled": motion_enabled, "frozen": frozen, "dust_budget": MAX_DUST}

func _draw_ground() -> void:
	# Lower floor contrast; keep doors and routes unchanged.
	_ground.draw_rect(Rect2(988,536,504,212), Color(0.075,0.095,0.11,0.46))
	# Distinct cargo staging bays, without drawing false walls/colliders.
	for r: Rect2 in [Rect2(997,570,101,107), Rect2(1166,568,120,99), Rect2(1360,570,115,99)]:
		_ground.draw_rect(r, Color(0.15,0.17,0.16,0.13))
		_ground.draw_rect(r, Color(0.76,0.67,0.43,0.34), false, 1)
	# A clear worn loading lane through the south opening, ending at cargo.
	for x: int in [1100,1123]:
		_ground.draw_line(Vector2(x,759), Vector2(x,644), Color(0.19,0.21,0.20,0.42), 4)
		for y: int in range(650,759,7):
			_ground.draw_line(Vector2(x-2,y), Vector2(x+2,y+1), Color(0.55,0.54,0.42,0.16), 1)
	_ground.draw_string(ThemeDB.fallback_font, Vector2(1094,735), "04", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.81,0.73,0.50,0.50))
	# Small drip-fed puddle by the exterior utility run; not a giant glossy overlay.
	var water := PackedVector2Array([Vector2(1045,774),Vector2(1068,770),Vector2(1100,777),Vector2(1108,790),Vector2(1080,798),Vector2(1050,790)])
	_ground.draw_colored_polygon(water, Color(0.10,0.18,0.22,0.78))
	_ground.draw_polyline(PackedVector2Array([Vector2(1050,775),Vector2(1067,772),Vector2(1099,779)]),Color(0.40,0.53,0.54,0.42),1)
	# Cargo spill gathers around the broken pallet instead of filling every route.
	for i: int in range(12):
		var p := Vector2(1190 + (i*13)%41, 692+(i*7)%24)
		_ground.draw_rect(Rect2(p,Vector2(3+i%3,1+i%2)), Color(0.39,0.31,0.21,0.60))
	for i: int in range(7):
		var p := Vector2(1030+(i*19)%77, 689+(i*11)%26)
		_ground.draw_rect(Rect2(p, Vector2(3,2)), Color(0.65,0.61,0.46,0.56))
	# Scuffs and damp along the wall base; no full-screen noise or colour grading.
	_ground.draw_line(Vector2(1146,744), Vector2(1350,744),Color(0.02,0.04,0.05,0.34),3)
	for i: int in range(26):
		var x := 990+i*19
		_ground.draw_line(Vector2(x,540),Vector2(x+4,545+(i%4)),Color(0.015,0.025,0.03,0.30),1)

func _draw_fixtures() -> void:
	# Working lamps have physical housings; artwork is native Godot geometry.
	for x: int in [1110,1380]:
		_details.draw_rect(Rect2(x-13,521,26,6), Color("242e32"))
		_details.draw_rect(Rect2(x-10,524,20,2), Color("dec095"))
		_details.draw_line(Vector2(x,512),Vector2(x,522),Color("40494a"),1)
	# An abandoned dispatch notice; text is context, not a fabricated quest.
	_details.draw_rect(Rect2(1290,515,53,16),Color("313b3e"))
	_details.draw_rect(Rect2(1293,517,47,12),Color("80755a"))
	_details.draw_string(ThemeDB.fallback_font,Vector2(1296,526),"HOLD 04",HORIZONTAL_ALIGNMENT_LEFT,-1,7,Color("292e2c"))
	# Corroded pipe follows the facade and visibly terminates at the steam leak.
	_details.draw_polyline(PackedVector2Array([Vector2(1146,759),Vector2(1200,759),Vector2(1200,773)]),Color("283134"),4)
	_details.draw_polyline(PackedVector2Array([Vector2(1146,758),Vector2(1200,758),Vector2(1200,771)]),Color("756e53"),2)
	for x: int in range(1152,1201,16):
		_details.draw_rect(Rect2(x,756,2,6),Color("333a37"))
	# Doorjamb trim increases apparent height but never covers the opening.
	for x: int in [1079,1143,1349,1413]:
		_details.draw_rect(Rect2(x,736,2,19),Color("262e30"))
		_details.draw_line(Vector2(x+2,737),Vector2(x+2,752),Color("8e8869"),1)

func _draw_motion() -> void:
	var t := float(_sample) / 12.0 if motion_enabled else 0.0
	# Sparse dust only near actual warm task lamps, not across the whole screen.
	for i: int in range(MAX_DUST):
		var base := Vector2(1060+(i*29)%372,549+(i*43)%136)
		var at := base + Vector2(sin(t*0.55+i*2.3)*5, -fmod(t*2+i*3,17))
		_effects.draw_rect(Rect2(at.round(),Vector2.ONE),Color(0.80,0.72,0.53,0.14+0.12*sin(i+t*0.5)*sin(i+t*0.5)))
	# Six bounded steam puffs; no physics, pooled commands, no unbounded spawn.
	for i: int in range(6):
		var age := fmod(t*0.36 + float(i)/6.0,1.0)
		var at := Vector2(1200+age*12+sin(t*0.8+i)*2,770-age*32)
		var opacity := sin(age*PI) * 0.14
		_effects.draw_circle(at.round(),2.0+floor(age*4.0),Color(0.73,0.81,0.78,opacity))
	# Short loose cable at the damaged utility coupling; top remains pinned.
	_effects.draw_polyline(PackedVector2Array([Vector2(1178,759),Vector2(1178,766),Vector2(1179+round(sin(t*1.3)),772)]),Color("363e3b"),1)
	# Drips/ripples are localized and never interpreted as authoritative impacts.
	var ripple := fmod(t*0.65,1.0)
	_effects.draw_arc(Vector2(1073,784),2+floor(ripple*11),0,TAU,16,Color(0.58,0.66,0.59,(1-ripple)*0.30),1)
	for i: int in range(3):
		var at := Vector2(1145+fmod(t*3.0+i*23,85),797+sin(t*0.8+i*2)*4)
		_effects.draw_rect(Rect2(at.round(),Vector2(2,1)),Color(0.68,0.63,0.47,0.4))
