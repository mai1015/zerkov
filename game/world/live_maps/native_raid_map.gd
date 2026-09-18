class_name NativeRaidMap
extends RefCounted
## One root-owned preflight result. Saved native scene -> detached domain values.
## Historical review JSON and physics-server queries are never collision truth.
## Load before escrow; live sessions use this exact scene/geometry/marker snapshot.
const SOURCE_MANIFEST := "res://assets/world/northline_native/source_manifest.json"
const PATHS := {
	"northline":"res://game/world/live_maps/northline_live.tscn",
	"blackwater":"res://game/world/live_maps/blackwater_live.tscn",
}
const CACHE_PATHS := {
	"northline":"res://game/world/live_maps/cache/northline.json",
	"blackwater":"res://game/world/live_maps/cache/blackwater.json",
}
const CACHE_VERSION: int = 1
const MAX_NODES: int = 30_000
const MAX_RESOURCES: int = 256
static var last_error: StringName = &""
static var _cache_entries: Dictionary = {}
static var _open_attempts: int = 0
static var _preview_file_loads: int = 0
static var _grid_cache_hits: int = 0
static var _grid_bakes: int = 0
var _id: String = ""
var _bounds := Rect2()
var _revision: int = 1
var _scene: PackedScene
var _solids: Array[Dictionary] = []
var _anchors: Dictionary = {}
var _descriptor: Dictionary = {}
var _grid: ZNavigationGrid
var _files: Dictionary = {}

static func open(map_id: String) -> NativeRaidMap:
	last_error = &""
	_open_attempts += 1
	if not PATHS.has(map_id): last_error=&"map_unknown"; return null
	var map := NativeRaidMap.new()
	map._id=map_id
	if not map._load(true): return null
	return map


## Authoring/CI path. It deliberately ignores the committed navigation cache,
## performs a fresh bake from current authoritative collision, and returns the
## exact derived record that should be committed. Normal gameplay never calls it.
static func rebuild_cache_record(map_id: String) -> Dictionary:
	last_error = &""
	if not PATHS.has(map_id):
		last_error = &"map_unknown"
		return {}
	var map := NativeRaidMap.new()
	map._id = map_id
	if not map._load(false):
		return {}
	return map.runtime_cache_record()


## Lightweight briefing projection. It contains only derived presentation data
## and the validated baked-navigation payload; it never instantiates the map.
static func preview(map_id: String) -> Dictionary:
	last_error = &""
	if not PATHS.has(map_id):
		last_error = &"map_unknown"
		return {}
	var entry := _cache_for(map_id)
	if entry.is_empty():
		last_error = &"map_runtime_cache_invalid"
		return {}
	return entry.preview


static func loading_work_counts() -> Dictionary:
	return RaidProgressionValues.freeze({
		"open_attempts": _open_attempts,
		"preview_file_loads": _preview_file_loads,
		"grid_cache_hits": _grid_cache_hits,
		"grid_bakes": _grid_bakes,
	})

func id() -> String: return _id
func revision() -> int: return _revision
func bounds() -> Rect2: return _bounds
func descriptor() -> Dictionary: return _descriptor
func grid() -> ZNavigationGrid: return _grid
func position(key: String) -> Vector2: return _anchors.get(key,{}).get("at",Vector2.INF)
func approach(key: String) -> Vector2: return _anchors.get(key,{}).get("approach",position(key))
func anchors() -> Dictionary: return RaidProgressionValues.freeze(_anchors)
func solids() -> Array: return RaidProgressionValues.freeze(_solids)
func instantiate_visuals() -> Node2D: return _scene.instantiate() as Node2D


## Authoring output for tools/build_live_map_cache.gd. This is derived data;
## deployment still validates source hashes and geometry before accepting it.
func runtime_cache_record() -> Dictionary:
	if _grid == null or not _grid.is_baked() or _descriptor.is_empty():
		return {}
	var geometry: Array = []
	for solid: Dictionary in _solids:
		if solid.has("rect"):
			var rect: Rect2 = solid.rect
			geometry.append({
				"rect": [rect.position.x, rect.position.y, rect.size.x, rect.size.y],
				"water": bool(solid.walking_only),
			})
		else:
			var points: Array = []
			for point: Vector2 in solid.polygon:
				points.append([point.x, point.y])
			geometry.append({"polygon": points, "water": true})
	var anchors: Dictionary = {}
	var keys: Array[String] = SupplyRunGraph.crates_for(_id)
	keys.append(SupplyRunGraph.exit_for(_id))
	for key: String in keys:
		var at := position(key)
		anchors[key] = [at.x, at.y]
	return {
		"version": CACHE_VERSION,
		"map_id": _id,
		"bounds": [_bounds.size.x, _bounds.size.y],
		"descriptor_digest": String(_descriptor.digest),
		"geometry": geometry,
		"anchors": anchors,
		"navigation": _grid.baked_cache_record(),
	}


func _load(use_navigation_cache: bool = true) -> bool:
	var manifest: Variant = JSON.parse_string(FileAccess.get_file_as_string(SOURCE_MANIFEST))
	if not manifest is Dictionary or not manifest.get("sources") is Array: return _fail(&"map_original_manifest_invalid")
	for row: Dictionary in manifest.sources:
		var path := "res://"+String(row.path)
		if not path.begins_with("res://assets/world/northline_native/sources/") or FileAccess.get_sha256(path)!=row.sha256:
			return _fail(&"map_original_source_missing_or_changed")
	if not _dependencies(String(PATHS[_id])): return false
	_scene=ResourceLoader.load(PATHS[_id],"PackedScene",ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	if _scene == null: return _fail(&"map_scene_unavailable")
	var root := _scene.instantiate() as Node2D
	if root == null: return _fail(&"map_root_invalid")
	var ok := _inspect(root)
	root.free()
	if not ok: return false
	var probe := build_movement(0)
	if probe == null: return false
	var cells := Vector2i(_bounds.size/float(ZWorldUnits.SOURCE_TILE_PIXELS))
	_grid = null
	if use_navigation_cache:
		var cache_entry := _cache_for(_id)
		var navigation: Dictionary = cache_entry.get("navigation", {})
		_grid = ZNavigationGrid.restore_baked_cache(
			navigation, probe, cells, _revision, "zerkov.level." + _id, true, 4.0)
		if _grid != null:
			_grid_cache_hits += 1
	if _grid == null:
		_grid_bakes += 1
		_grid = ZNavigationGrid.bake_from_movement_world(
			probe, cells, _revision, "zerkov.level." + _id, true, 4.0)
	if _grid == null: return _fail(ZNavigationGrid.last_error)
	var path_service:=ZNavigationPathService.new()
	if not path_service.configure(_grid,_revision): return _fail(path_service.last_error)
	var start:=ZWorldUnits.godot_to_tile(position("player")).vector2i_value
	var targets:=interaction_targets()
	if targets.size()!=4:return _fail(&"map_interaction_targets_invalid")
	var segments:=occluders()
	for key: String in _anchors:
		var at:=approach(key)
		if not probe.query_placement_px(at,Vector2(8,8)).get("ok",false):
			return _fail(StringName("map_anchor_blocked_"+key))
		var target:=ZWorldUnits.godot_to_tile(at).vector2i_value
		var path:=path_service.request_path(start,target,_revision,8192)
		if not path.is_ok(): return _fail(StringName("map_anchor_unreachable_"+key))
		if SupplyRunGraph.crates_for(_id).has(key):
			var request:=ZInteractionRequest.create(ZEntityId.from_parts(PackedStringArray(["preflight"])),at,StringName(key),ZInteractionKind.CRATE)
			if not ZInteractionPolicy.evaluate(request,targets,segments).allowed:
				return _fail(StringName("map_crate_approach_occluded_"+key))
	var digest_parts: Array = [_id,str(_revision),str(_bounds)]
	var names:=_files.keys();names.sort()
	for name: String in names: digest_parts.append(name+":"+String(_files[name]))
	# Source-byte identity also covers anchors and native geometry, not only art.
	_descriptor=RaidProgressionValues.freeze({"id":_id,"revision":_revision,"digest":"\n".join(digest_parts).sha256_text()})
	return true

func _dependencies(path: String) -> bool:
	if _files.has(path): return true
	if _files.size()>=MAX_RESOURCES or not path.begins_with("res://") or ".." in path:
		return _fail(&"map_dependency_invalid")
	if path.get_extension() not in ["tscn","tres","png"]: return _fail(&"map_executable_dependency_forbidden")
	var hash := FileAccess.get_sha256(path)
	if hash.is_empty(): return _fail(&"map_dependency_missing")
	_files[path]=hash
	if path.ends_with(".png"): return true
	for dependency: String in ResourceLoader.get_dependencies(path):
		var resource_path:=dependency.get_slice("::",dependency.get_slice_count("::")-1)
		if not _dependencies(resource_path): return false
	return true

func _inspect(root: Node2D) -> bool:
	if root.get_script()!=null or root.transform!=Transform2D.IDENTITY or root.get_meta("map_id","")!=_id:
		return _fail(&"map_root_contract_invalid")
	var environment:=root.get_node_or_null("Environment") as Node2D
	if environment==null: return _fail(&"map_environment_missing")
	var bounds_value:Variant=root.get_meta("world_bounds",null)
	if not bounds_value is Rect2 or bounds_value.position!=Vector2.ZERO or bounds_value.size.x<=0 or bounds_value.size.y<=0:
		return _fail(&"map_bounds_invalid")
	_bounds=bounds_value
	if not _bounds.size.is_finite() or _bounds.size.x>4096 or _bounds.size.y>4096 or Vector2(Vector2i(_bounds.size/32)*32)!=_bounds.size:
		return _fail(&"map_bounds_invalid")
	var movement_only:Variant=root.get_meta("movement_only",null)
	if not movement_only is PackedStringArray: return _fail(&"map_collision_roles_missing")
	for path: String in movement_only:
		if not environment.get_node_or_null(path) is StaticBody2D: return _fail(&"map_collision_role_unknown")
	var stack: Array[Node] = [root]
	var visited: int = 0
	while not stack.is_empty():
		var n:Node=stack.pop_back();visited+=1
		if visited>MAX_NODES or n.get_script()!=null: return _fail(&"map_runtime_script_or_budget")
		if n is CharacterBody2D or n is RigidBody2D or n is Area2D: return _fail(&"map_unowned_physics")
		if n is TileMapLayer and n.collision_enabled and n.tile_set!=null and n.tile_set.get_physics_layers_count()>0:
			return _fail(&"map_unbound_tile_collision")
		if n is StaticBody2D:
			if n.collision_layer not in [0,1]: return _fail(&"map_unrecognized_collision_layer")
			if n.collision_layer==1:
				var body_path:=String(environment.get_path_to(n))
				var walking_only:bool=movement_only.has(body_path)
				var count:=0
				for child:Node in n.get_children():
					if child is CollisionShape2D and not child.disabled:
						if not child.shape is RectangleShape2D: return _fail(&"map_unsupported_shape")
						var tx:=_transform_to(root,child)
						if not tx.is_finite() or not is_zero_approx(tx.x.y) or not is_zero_approx(tx.y.x): return _fail(&"map_rotated_rectangle")
						var size:Vector2=child.shape.size
						var one:=tx*(-size/2);var two:=tx*(size/2)
						var rect:=Rect2(Vector2(minf(one.x,two.x),minf(one.y,two.y)),Vector2(absf(two.x-one.x),absf(two.y-one.y)))
						if not rect.has_area() or not _bounds.grow(64).encloses(rect): return _fail(&"map_shape_outside_bounds")
						_solids.append({"id":_solid_id(String(root.get_path_to(child))),"rect":rect,"walking_only":walking_only})
						count+=1
					elif child is CollisionPolygon2D and not child.disabled:
						# Sloped river polygons are actual authored geometry, not their AABB.
						if not walking_only or child.build_mode!=CollisionPolygon2D.BUILD_SOLIDS: return _fail(&"map_polygon_role_invalid")
						var points:PackedVector2Array=_transform_to(root,child)*child.polygon
						if ZConvexCollider.compile_px(points).is_empty(): return _fail(&"map_nonconvex_polygon")
						for point:Vector2 in points:
							if not _bounds.grow(64).has_point(point):return _fail(&"map_polygon_outside_bounds")
						_solids.append({"id":_solid_id(String(root.get_path_to(child))),"polygon":points,"walking_only":true})
						count+=1
				if count<1: return _fail(&"map_empty_blocker")
		if n is Marker2D and n.has_meta("gameplay_id"):
			var key:=String(n.get_meta("gameplay_id"))
			if _anchors.has(key): return _fail(&"map_anchor_duplicate")
			var at:=_transform_to(root,n).origin
			var approach_node:=n.get_node_or_null("Approach") as Marker2D
			var row:Dictionary={"at":at,"approach":_transform_to(root,approach_node).origin if approach_node!=null else at}
			if n.has_meta("zone_cells"): row["zone_cells"]=n.get_meta("zone_cells")
			if not at.is_finite() or not _bounds.has_point(at): return _fail(&"map_anchor_outside_bounds")
			_anchors[key]=row
		stack.append_array(n.get_children())
	if _solids.is_empty() or _solids.size()>ZMovementWorld2D.MAX_STATIC_COLLIDERS: return _fail(&"map_solid_budget")
	var required:Array[String]=["player","scav","mutant"]
	required.append_array(SupplyRunGraph.crates_for(_id));required.append(SupplyRunGraph.exit_for(_id))
	if _anchors.size()!=required.size(): return _fail(&"map_anchor_set_invalid")
	for key:String in required:
		if not _anchors.has(key): return _fail(&"map_required_anchor_missing")
	_solids.sort_custom(func(a:Dictionary,b:Dictionary)->bool:return String(a.id)<String(b.id))
	_solids.make_read_only();_anchors=RaidProgressionValues.freeze(_anchors)
	return true

func build_movement(generation: int) -> ZMovementWorld2D:
	var world:=ZMovementWorld2D.new()
	if not world.configure(_bounds,generation,"zerkov.level."+_id): _fail(world.last_error);return null
	for solid:Dictionary in _solids:
		var ok:bool=world.add_static_polygon_px(solid.id,solid.polygon,generation) if solid.has("polygon") else world.add_static_collider_px(solid.id,solid.rect,generation)
		if not ok: _fail(world.last_error);return null
	return world

func interaction_targets() -> Dictionary:
	var targets:Dictionary={}
	for key:String in SupplyRunGraph.crates_for(_id):
		targets[key]=ZInteractionTargetState.create_point(StringName(key),ZInteractionKind.CRATE,position(key))
	var exit_id:=SupplyRunGraph.exit_for(_id)
	if not _anchors.get(exit_id,{}).get("zone_cells") is Rect2i: _fail(&"map_exit_zone_missing");return {}
	var exit:=ZInteractionTargetState.create_zone(StringName(exit_id),position(exit_id),_anchors[exit_id].zone_cells)
	if not exit.validate().is_empty(): _fail(&"map_exit_zone_invalid");return {}
	targets[exit_id]=exit
	return targets

func occluders() -> Array[ZerkovOccluderSegment]:
	var result:Array[ZerkovOccluderSegment]=[]
	for solid:Dictionary in _solids:
		if solid.walking_only:continue
		var r:Rect2=solid.rect
		var corners:Array[Vector2]=[r.position,Vector2(r.end.x,r.position.y),r.end,Vector2(r.position.x,r.end.y)]
		for i in range(4):
			var a:=ZWorldUnits.godot_to_vision(corners[i]);var b:=ZWorldUnits.godot_to_vision(corners[(i+1)%4])
			result.append(ZerkovOccluderSegment.create(String(solid.id)+".e"+str(i),ZOccluderBake.MASK_STRUCTURE,a.vector2i_value,b.vector2i_value,[String(solid.id)]))
	return result

func obstructions() -> Array[Dictionary]:
	var result:Array[Dictionary]=[]
	for solid:Dictionary in _solids:
		if solid.walking_only:continue
		var r:Rect2=solid.rect
		var id:=ZObstructionId.from_parts(PackedStringArray([_id,String(solid.id).sha256_text().substr(0,24)]))
		result.append({"obstruction_id":id.canonical_key(),"geometry_revision":_revision,"min_raw":ZWorldUnits.godot_to_canonical(r.position).vector2i_value,
			"max_raw":ZWorldUnits.godot_to_canonical(r.end).vector2i_value,"collision_layer":2,"enabled":true})
	return result

static func _cache_for(map_id: String) -> Dictionary:
	if _cache_entries.has(map_id):
		return _cache_entries[map_id]
	if not CACHE_PATHS.has(map_id):
		return {}
	_preview_file_loads += 1
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(CACHE_PATHS[map_id]))
	if not parsed is Dictionary:
		return {}
	var decoded := _decode_cache(map_id, parsed)
	if decoded.is_empty():
		return {}
	_cache_entries[map_id] = decoded
	return decoded


static func _decode_cache(map_id: String, record: Dictionary) -> Dictionary:
	var bounds_value: Variant = record.get("bounds")
	var geometry_value: Variant = record.get("geometry")
	var anchors_value: Variant = record.get("anchors")
	var navigation_value: Variant = record.get("navigation")
	if int(record.get("version", -1)) != CACHE_VERSION \
			or String(record.get("map_id", "")) != map_id \
			or not bounds_value is Array or bounds_value.size() != 2 \
			or not geometry_value is Array or not anchors_value is Dictionary \
			or not navigation_value is Dictionary:
		return {}
	var extent := Vector2(float(bounds_value[0]), float(bounds_value[1]))
	var bounds := Rect2(Vector2.ZERO, extent)
	if not extent.is_finite() or extent.x <= 0 or extent.y <= 0 \
			or extent.x > 4096 or extent.y > 4096 \
			or Vector2(Vector2i(extent / 32.0) * 32) != extent:
		return {}
	if geometry_value.is_empty() or geometry_value.size() > ZMovementWorld2D.MAX_STATIC_COLLIDERS:
		return {}
	var geometry: Array = []
	for value: Variant in geometry_value:
		if not value is Dictionary:
			return {}
		var row: Dictionary = value
		if not row.get("water") is bool:
			return {}
		if row.has("rect"):
			var raw_rect: Variant = row.rect
			if not raw_rect is Array or raw_rect.size() != 4:
				return {}
			var rect := Rect2(float(raw_rect[0]), float(raw_rect[1]), float(raw_rect[2]), float(raw_rect[3]))
			if not rect.position.is_finite() or not rect.size.is_finite() \
					or not rect.has_area() or not bounds.grow(64).encloses(rect):
				return {}
			geometry.append({
				"rect": Rect2(rect.position / extent, rect.size / extent),
				"water": bool(row.water),
			})
		elif row.has("polygon"):
			var raw_polygon: Variant = row.polygon
			if not raw_polygon is Array or raw_polygon.size() < 3 or raw_polygon.size() > 64:
				return {}
			var points: Array[Vector2] = []
			for raw_point: Variant in raw_polygon:
				if not raw_point is Array or raw_point.size() != 2:
					return {}
				var point := Vector2(float(raw_point[0]), float(raw_point[1]))
				if not point.is_finite() or not bounds.grow(64).has_point(point):
					return {}
				points.append(point / extent)
			geometry.append({"polygon": points, "water": true})
		else:
			return {}
	var required: Array[String] = SupplyRunGraph.crates_for(map_id)
	required.append(SupplyRunGraph.exit_for(map_id))
	if anchors_value.size() != required.size():
		return {}
	var anchors: Dictionary = {}
	for key: String in required:
		var raw_anchor: Variant = anchors_value.get(key)
		if not raw_anchor is Array or raw_anchor.size() != 2:
			return {}
		var at := Vector2(float(raw_anchor[0]), float(raw_anchor[1]))
		if not at.is_finite() or not bounds.has_point(at):
			return {}
		anchors[key] = at
	var descriptor_digest := String(record.get("descriptor_digest", ""))
	if descriptor_digest.length() != 64:
		return {}
	var preview: Dictionary = RaidProgressionValues.freeze({
		"map_id": map_id,
		"bounds": bounds,
		"geometry": geometry,
		"anchors": anchors,
		"descriptor_digest": descriptor_digest,
	})
	return {"preview": preview, "navigation": navigation_value.duplicate(true)}


static func _transform_to(root: Node2D, node: Node2D) -> Transform2D:
	var result:=Transform2D.IDENTITY
	var current:Node=node
	while current!=root and current is Node2D:
		result=current.transform*result;current=current.get_parent()
	return result

func _solid_id(path: String) -> String:
	return "zerkov.solid."+_id+".s"+path.sha256_text().substr(0,24)

static func _fail(reason: StringName) -> bool:
	last_error=reason
	return false
