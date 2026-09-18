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
const MAX_NODES: int = 30_000
const MAX_RESOURCES: int = 256
static var last_error: StringName = &""
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
	if not PATHS.has(map_id): last_error=&"map_unknown"; return null
	var map := NativeRaidMap.new()
	map._id=map_id
	if not map._load(): return null
	return map

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

func _load() -> bool:
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
	_grid=ZNavigationGrid.bake_from_movement_world(probe,cells,_revision,"zerkov.level."+_id,true,4.0)
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
