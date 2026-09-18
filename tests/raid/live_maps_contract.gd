extends SceneTree
## Component/negative contracts. Persistence uses explicit fake file/inventory
## ports; the separate input-flow suite uses the real production native owners.
const V = preload("res://game/raid/progression/raid_progression_values.gd")
const Fixtures = preload("res://tests/raid/raid_progression_contract.gd")
var checks: int = 0
var failures: int = 0
func _initialize() -> void: call_deferred("run")
func check(ok: bool, label: String) -> void:
	checks+=1
	if not ok:failures+=1;push_error("LIVE_MAP_CONTRACT_ASSERT: "+label)
func run() -> void:
	_test_convex()
	_test_swept_navigation()
	_test_capacity()
	_test_session_start_admission()
	_test_map_preflight()
	_test_pinned_persistence()
	print("LIVE_MAP_CONTRACT_RESULT checks=",checks," failures=",failures)
	quit(0 if failures==0 else 1)

func _test_convex() -> void:
	var rect:=PackedVector2Array([Vector2(64,64),Vector2(128,64),Vector2(128,128),Vector2(64,128)])
	var inverse:=rect.duplicate();inverse.reverse()
	check(not ZConvexCollider.compile_px(rect).is_empty(),"convex rectangle accepted")
	for bad:PackedVector2Array in [PackedVector2Array(),PackedVector2Array([Vector2.ZERO,Vector2.ONE]),PackedVector2Array([Vector2.ZERO,Vector2(10,0),Vector2(5,0)]),PackedVector2Array([Vector2.ZERO,Vector2(10,0),Vector2(5,3),Vector2(10,10),Vector2(0,10)]),PackedVector2Array([Vector2.ZERO,Vector2(10,0),Vector2.INF]),PackedVector2Array([Vector2.ZERO,Vector2(10,0),Vector2(10,0),Vector2(0,10)])]:
		check(ZConvexCollider.compile_px(bad).is_empty(),"malformed/concave/duplicate polygon rejected")
	var actor:=ZEntityId.from_parts(PackedStringArray(["convex","test"]))
	for points:PackedVector2Array in [rect,inverse]:
		for start:Vector2 in [Vector2(40,80),Vector2(144,80),Vector2(80,40),Vector2(80,144),Vector2(40,40)]:
			var plain:=ZMovementWorld2D.new();var poly:=ZMovementWorld2D.new()
			plain.configure(Rect2(0,0,256,256),1);poly.configure(Rect2(0,0,256,256),1)
			plain.add_static_collider_px("solid",Rect2(64,64,64,64),1)
			check(poly.add_static_polygon_px("solid",points,1),"valid polygon injection")
			check(plain.register_actor(actor,start,Vector2(8,8),1) and poly.register_actor(actor,start,Vector2(8,8),1),"comparison bodies")
			for tick:int in range(1,100):
				var velocity:=Vector2(((tick*13)%11-5)*150.0,((tick*17)%13-6)*150.0)
				var a:=plain.resolve_actor_step(actor,tick,velocity,1);var b:=poly.resolve_actor_step(actor,tick,velocity,1)
				check(a.ok and b.ok and a.resolved_position_micro==b.resolved_position_micro and a.blocked_axes==b.blocked_axes,"exact polygon rectangle matches existing resolver")
			var before:=poly.digest()
			check(not poly.resolve_actor_step(actor,1,Vector2.ONE,1).ok and not poly.resolve_actor_step(actor,101,Vector2.ONE,2).ok and poly.digest()==before,"replay/generation inert")
			check(poly.seal(1),"seal polygon world")
			before=poly.digest()
			check(not poly.add_static_polygon_px("late",rect,1) and not poly.resolve_actor_step(actor,101,Vector2.ONE,1).ok and poly.digest()==before,"sealed world rejects late geometry/movement")
	# A sloped bank must not be replaced with its bounding box.
	var river:=ZMovementWorld2D.new();river.configure(Rect2(0,0,256,256),1)
	check(river.add_static_polygon_px("bank",PackedVector2Array([Vector2(80,32),Vector2(128,32),Vector2(176,192),Vector2(128,192)]),1),"sloped bank")
	check(river.query_placement_px(Vector2(88,176),Vector2(8,8)).ok,"outside polygon inside AABB is dry walkable bank")
	check(not river.query_placement_px(Vector2(138,150),Vector2(8,8)).ok,"actual river interior blocks")
	check(river.register_actor(actor,Vector2(48,150),Vector2(8,8),1),"dry-bank spawn")
	var hit:=river.resolve_actor_step(actor,1,Vector2(12000,0),1)
	check(hit.ok and hit.corrected and river.query_placement_px(river.actor_position_px(actor),Vector2(8,8)).ok,"fast movement cannot tunnel through sloped river")
	# Rational extrema near integer boundaries cannot overflow cross products.
	for row:Array in [[1,3,2,6,0],[-1,3,0,1,-1],[800000000000000001,400000000,800000000000000000,400000000,1],[-800000000000000001,400000000,-800000000000000000,400000000,-1]]:
		check(ZConvexCollider._compare(row[0],row[1],row[2],row[3])==row[4],"exact bounded rational comparison")
	var narrow:={"planes":[[-4,0,-1],[4,0,3],[0,1,10],[0,-1,10]]}
	check(ZConvexCollider.axis_limits(narrow,Vector2i.ZERO,Vector2i.ZERO,true)==[0,1],"sub-microunit interval still blocks continuous sweep")
	var tangent:={"planes":[[-4,0,-1],[4,0,1],[0,1,10],[0,-1,10]]}
	check(ZConvexCollider.axis_limits(tangent,Vector2i.ZERO,Vector2i.ZERO,true).is_empty(),"zero-width contact is not overlap")

func _test_swept_navigation() -> void:
	var world:=ZMovementWorld2D.new();world.configure(Rect2(0,0,160,96),1)
	world.add_static_collider_px("thin",Rect2(62,0,4,96),1)
	var before:=world.digest()
	var grid:=ZNavigationGrid.bake_from_movement_world(world,Vector2i(5,3),1,"test",true)
	check(grid!=null and grid.is_walkable(Vector2i(1,1)) and grid.is_walkable(Vector2i(2,1)),"thin wall between free cell centres")
	check(not grid.can_traverse(Vector2i(1,1),Vector2i(2,1)) and not grid.can_traverse(Vector2i(2,1),Vector2i(1,1)),"swept edge blocks both directions")
	var paths:=ZNavigationPathService.new();paths.configure(grid,1)
	check(not paths.request_path(Vector2i(0,1),Vector2i(4,1),1).is_ok(),"no advisory path through sealed thin wall")
	check(world.digest()==before,"bake/queries never mutate collision truth")
	var door:=ZMovementWorld2D.new();door.configure(Rect2(0,0,160,160),1)
	door.add_static_collider_px("upper",Rect2(62,0,4,60),1)
	door.add_static_collider_px("lower",Rect2(62,100,4,60),1)
	var open_grid:=ZNavigationGrid.bake_from_movement_world(door,Vector2i(5,5),1,"door",true)
	paths=ZNavigationPathService.new();paths.configure(open_grid,1)
	var path:=paths.request_path(Vector2i(0,0),Vector2i(4,0),1)
	check(path.is_ok(),"swept navigation detours through the real doorway")
	for i:int in range(1,path.cells.size()):check(open_grid.can_traverse(path.cells[i-1],path.cells[i]),"every returned segment is collision-verified")
	var again:=ZNavigationGrid.bake_from_movement_world(door,Vector2i(5,5),1,"door",true)
	check(again.digest()==open_grid.digest(),"swept edge identity deterministic")

func _test_capacity() -> void:
	var world:=ZMovementWorld2D.new();world.configure(Rect2(0,0,4096,4096),1)
	for i:int in ZMovementWorld2D.MAX_STATIC_COLLIDERS:
		check(world.add_static_collider_px("s%04d"%i,Rect2(16+(i%32)*48,16+(i/32)*48,8,8),1),"bounded native map capacity")
	var before:=world.geometry_digest()
	check(not world.add_static_collider_px("overflow",Rect2(2000,2000,8,8),1) and world.last_error==&"collider_limit","capacity+1 rejected")
	check(world.geometry_digest()==before,"overflow leaves geometry unchanged")

func _test_session_start_admission() -> void:
	var session:=LocalRaidSession.new()
	# Off-tree admission must fail before even looking at map content.
	check(not session.start(null,"unused",0,0,"northline"),"off-tree start rejected")
	check(session.map_id=="sawmill" and session.native_map==null and not session._started,"off-tree rejection retains prior map state")
	root.add_child(session)
	check(not session.start(null,"unused",0,0,"not_a_map"),"unknown map rejected before deployment")
	check(session.map_id=="sawmill" and session.native_map==null and session.deployment==null,"invalid selection does not create escrow")
	# Isolated lifecycle guard; the input-flow suite separately runs real sessions.
	var pinned:=NativeRaidMap.new()
	session.map_id="northline";session.native_map=pinned;session._started=true
	check(not session.start(null,"unused",0,0,"blackwater"),"second start rejected before map preflight")
	check(session.last_error==&"local_raid_already_started" and session.map_id=="northline" and session.native_map==pinned and session.deployment==null,"second start cannot replace session map or geometry")
	check(session.camera==null,"rejected starts allocate no orphan camera")
	session.free()

func _test_map_preflight() -> void:
	check(NativeRaidMap.open("../northline")==null,"map catalog rejects arbitrary path")
	for id:String in ["northline","blackwater"]:
		var map:=NativeRaidMap.open(id)
		check(map!=null,"authored production-sized-player map preflight "+id)
		if map==null:continue
		check(V.valid_map_descriptor(map.descriptor()) and map.descriptor().is_read_only(),"immutable closed descriptor")
		check(map.solids().size()==(694 if id=="northline" else 189),"every authored solid accounted")
		check(map.occluders().size()<RaidVisionActorRegistry.MAX_SEGMENTS and map.obstructions().size()<BodyHitboxWorld2D.MAX_OBSTRUCTIONS,"all sight/shot geometry within explicit budgets")
		check(map.anchors().size()==7 and map.grid().is_baked(),"explicit finite gameplay anchor set")
		var world:=map.build_movement(3)
		for key:String in map.anchors():
			check(world.query_placement_px(map.approach(key),Vector2(8,8)).ok,"production actor can stand at approach")
		# Mutate only fresh disposable instances; never modify authored resources.
		var scene:=map.instantiate_visuals();scene.get_node("GameplayAnchors/player").set_meta("gameplay_id","scav")
		var invalid:=NativeRaidMap.new();invalid._id=id
		check(not invalid._inspect(scene),"duplicate/omitted stable gameplay anchor rejected")
		scene.free()
		var foreign:=SupplyRunGraph.crates_for("blackwater" if id=="northline" else "northline")[0]
		check(not map.interaction_targets().has(foreign),"foreign map target cannot bind")

func _test_pinned_persistence() -> void:
	var fixtures:=Fixtures.new()
	for id:String in ["sawmill","northline","blackwater"]:
		var selected:Dictionary={} if id=="sawmill" else {"id":id,"revision":1,"digest":"a".repeat(64)}
		for phase:String in ["deployed","prepared","committed"]:
			var f:Dictionary=fixtures._fixture()
			var req:="zerkov.request.live."+id+"."+phase
			var deployed:Dictionary=f.service.deploy(req,1,selected)
			check(deployed.ok,"map-bound escrow")
			var raid:String=deployed.deployment.raid_id
			check(deployed.deployment.get("map",{})==selected,"escrow pins descriptor")
			var before:String=f.store.load_profile().fingerprint
			var other:Dictionary={"id":"blackwater" if id!="blackwater" else "northline","revision":1,"digest":"b".repeat(64)}
			check(f.service.deploy(req,1,other).get("reason")==&"deployment_map_conflict","same deployment request cannot switch map")
			check(f.store.load_profile().fingerprint==before,"map-conflicting retry writes nothing")
			check(f.service.deploy(req,1,selected).replayed,"identical retry never allocates a second raid")
			if phase!="deployed":check(f.service.prepare(raid,fixtures._terminal(),f.payload.domains[V.LOADOUT]).ok,"prepare pinned map")
			if phase=="committed":check(f.service.commit(raid).ok,"commit pinned map")
			check(f.store.close(),"simulate process shutdown at each checkpoint")
			var store:=ProfileStore.new();store.configure_with_trusted_operations("zerkov.profile.task7",f.ops)
			var service:=RaidSettlementService.new();service.configure(store,Fixtures.InventoryDouble.new())
			check(service.recover().ok,"recover without loading map scene")
			var final:=service.summary(raid)
			check(final.ok and final.receipt.get("map",{})==selected,"receipt keeps original map after restart")
			check(final.receipt.outcome==("abandoned" if phase=="deployed" else "extracted"),"existing recovery policy preserved")
			check(V.valid_receipt(final.receipt) and RaidSummaryView.from_committed(final)!=null,"legacy/new summary validation")
			before=store.load_profile().fingerprint
			check(service.deploy(req,1,other).get("reason")==&"deployment_map_conflict" and store.load_profile().fingerprint==before,"history retry cannot reattribute settled result")
			if id!="sawmill":
				for bad:Variant in [null,{}, {"id":id,"revision":true,"digest":"a".repeat(64)},{"id":"foreign","revision":1,"digest":"a".repeat(64)},{"id":id,"revision":1,"digest":"bad"}]:
					var receipt:Dictionary=final.receipt.duplicate(true);receipt.map=bad
					check(not V.valid_receipt(receipt),"malformed optional map field never ignored")
			store.close()
	check(fixtures.failures==0,"fixture baseline assertions")
	fixtures.free()
