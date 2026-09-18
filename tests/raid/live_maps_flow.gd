extends SceneTree
## Normal product UI and native gameplay. Isolated real files, manual test tick
## pacing only. No scene forcing, teleport, seeded test gear or invented result.
class FailOnceIO:
	extends GodotProfileFileOperations
	var fail_next_write: bool = false
	var failures_injected: int = 0
	func _init(ns: StringName) -> void: super(ns)
	func write_temp(slot: StringName, bytes: PackedByteArray) -> Dictionary:
		if fail_next_write:
			fail_next_write=false;failures_injected+=1
			return {"ok":false,"reason":&"injected_live_map_write_failure"}
		return super.write_temp(slot,bytes)
const EXACT := Vector2i(1920,1080)
const Exact1080CaptureGuard = preload("res://game/presentation/exact_1080_capture_guard.gd")
var checks: int = 0
var failures: int = 0
var game: LocalGame
var store: ProfileStore
var ops: FailOnceIO
var test_namespace: String
var map_id: String
var scenario: String
var output: String
var aborted: bool = false
var loading_route_seen: bool = false
var loading_home_preserved: bool = false
var loading_started_before_preflight: bool = false

func _initialize() -> void: call_deferred("run")
func check(ok: bool, note: String) -> bool:
	checks+=1
	if not ok:failures+=1;push_error("LIVE_MAP_FLOW_ASSERT: "+note)
	return ok
func settle() -> void:
	for _i in range(8): await process_frame
	await create_timer(.03).timeout
func key(code: Key) -> void:
	for down:bool in [true,false]:
		var e:=InputEventKey.new();e.keycode=code;e.physical_keycode=code;e.pressed=down
		root.push_input(e)
	await settle()
func click(path: String) -> bool:
	var control:=game._ui.screen.get_node_or_null(path) as Control
	if not check(control!=null and control.is_visible_in_tree(),"visible control "+path):return false
	for down:bool in [true,false]:
		var e:=InputEventMouseButton.new();e.position=control.get_global_rect().get_center();e.button_index=MOUSE_BUTTON_LEFT;e.pressed=down
		root.push_input(e)
	await settle();return failures==0
func route(expected: String) -> bool:
	print("LIVE_MAP_STAGE map=",map_id," scenario=",scenario," route=",game._ui.current_route," mode=",game._mode," error=",game.last_error)
	return check(game._ui.current_route==expected and game.last_error.is_empty(),"normal route "+expected) \
		and check(game._ui.fixture_provider_for_test()==null,"no fixture provider")
func capture(label: String) -> void:
	if output.is_empty() or DisplayServer.get_name()=="headless":return
	await settle();await RenderingServer.frame_post_draw
	var image:=root.get_texture().get_image()
	check(Exact1080CaptureGuard.accepts(root,root,image),"physical native capture "+label)
	if not Exact1080CaptureGuard.accepts(root,root,image):
		return
	var saved:=image.save_png(output.path_join(map_id+"-"+label+"-1080.png"))
	check(saved==OK,"raw renderer PNG")

func observe_loading(frame: Dictionary, expected_home_id: int, open_attempts: int) -> void:
	if frame.get("mode") != "deploying" or game == null or game._ui == null \
			or game._ui.current_route != "deploying":
		return
	loading_route_seen = true
	loading_home_preserved = game._home != null \
		and game._home.get_instance_id() == expected_home_id and game._session == null
	loading_started_before_preflight = int(NativeRaidMap.loading_work_counts().open_attempts) == open_attempts

func _valid_test_namespace(value: String) -> bool:
	if not value.begins_with("livemaps_") or value.length()<12 or value.length()>64:return false
	for c in value:
		if c not in "abcdefghijklmnopqrstuvwxyz0123456789_":return false
	return true

func run() -> void:
	root.borderless=true;root.size=EXACT
	var args:=OS.get_cmdline_user_args()
	if args.size()<4 or args[0] not in ["run","verify","cleanup"] or not _valid_test_namespace(args[1]) or args[2] not in ["sawmill","northline","blackwater"]:
		push_error("LIVE_MAP_BAD_ARGS");quit(2);return
	test_namespace=args[1];map_id=args[2];scenario=args[3]
	if args[0]=="run" and scenario not in ["launch","extract","death"]:
		push_error("LIVE_MAP_BAD_SCENARIO");quit(2);return
	if args.size()>4:output=args[4]
	ops=FailOnceIO.new(StringName(test_namespace));store=ProfileStore.new()
	if not check(store.configure_with_trusted_operations(LocalCampaignContent.PROFILE_ID,ops),"isolated local store"):await finish();return
	if args[0]=="cleanup":
		for slot in ProfileFileOperations.ALL_SLOTS:check(ops.remove_slot(slot).get("ok",false),"remove only test slot")
		await finish();return
	if args[0]=="verify":
		var loaded:=store.load_profile()
		check(loaded.ok and loaded.fingerprint==scenario,"independent-process exact profile")
		var state:Dictionary=loaded.get("payload",{}).get("project",{}).get(RaidProgressionValues.STATE_KEY,{})
		check(RaidProgressionValues.valid_state(state) and state.active.is_empty(),"settled profile, no restored live raid")
		for bytes:PackedByteArray in state.history.values():
			var receipt:=RaidProgressionValues.decode(bytes)
			check(receipt.get("map",{}).get("id","sawmill")==map_id,"receipt retained original map identity")
		await finish();return
	create_timer(840).timeout.connect(func():check(false,"bounded watchdog");quit(1))
	if not check(store.load_profile().get("reason")==&"profile_missing","new save test_namespace; driver seeds no items"):await finish();return
	game=load("res://game/bootstrap/local/local_game.tscn").instantiate()
	game.configure_test_store(store,false);root.add_child(game);await settle()
	if not route("title"):await finish();return
	await key(KEY_ENTER)
	if not route("main_menu") or not await click("MenuPlay/Hit") or not route("bunker"):await finish();return
	if not await click("BunkerHideoutView/LocalDeploy") or not route("maps"):await finish();return
	var generation:int=store.load_profile().generation
	var index:int=["sawmill","northline","blackwater"].find(map_id)
	var selection_work:=NativeRaidMap.loading_work_counts()
	if not await click("ZoneHit"+str(index)):await finish();return
	var selected_work:=NativeRaidMap.loading_work_counts()
	if not check(game._selected_map==map_id and game._map_error.is_empty(),"actual briefing map selection: "+game._map_error):await finish();return
	check(game._native_map==null and int(selected_work.open_attempts)==int(selection_work.open_attempts),
		"briefing selection never instantiates or preflights the native map")
	if map_id!="sawmill":
		check(not game._map_geometry.is_empty() and game._map_extent.x>0 and game._map_extent.y>0,
			"native briefing uses committed lightweight tactical preview")
	check(store.load_profile().generation==generation,"briefing selection did not reserve or rewrite gear")
	check(game._ui_port.snapshot().map_id==map_id,"map-scoped UI frame")
	await capture("briefing")
	var home_epoch:=game._epoch
	var home_id:int=game._home.get_instance_id()
	var preflight_work:=NativeRaidMap.loading_work_counts()
	var loading_observer:=observe_loading.bind(home_id,int(preflight_work.open_attempts))
	game.published.connect(loading_observer)
	if not await click("Deploy") or not route("hud"):await finish();return
	if game.published.is_connected(loading_observer):
		game.published.disconnect(loading_observer)
	check(loading_route_seen and loading_home_preserved and loading_started_before_preflight,
		"real loading screen renders before map preflight, save, teardown, or escrow")
	var deployed_work:=NativeRaidMap.loading_work_counts()
	if map_id=="sawmill":
		check(int(deployed_work.open_attempts)==int(preflight_work.open_attempts),
			"Sawmill deployment requires no native-map preflight")
	else:
		check(int(deployed_work.open_attempts)==int(preflight_work.open_attempts)+1 \
			and int(deployed_work.grid_cache_hits)==int(preflight_work.grid_cache_hits)+1 \
			and int(deployed_work.grid_bakes)==int(preflight_work.grid_bakes),
			"deployment loads once behind the loading screen and restores the verified navigation cache")
	check(game._session.map_id==map_id and game._session.ai!=null,"real map-bound raid and AI")
	check(game._world.size==(EXACT if map_id!="sawmill" else Vector2i(640,360)),"source-preserving render target")
	check(game._session._world_scene.find_children("*","CharacterBody2D",true,false).is_empty(),"no inspection walker")
	check(not game._ui_port.request(&"select_sawmill",home_epoch),"stale home epoch cannot change raid map")
	game._ui_port.request(&"select_blackwater" if map_id!="blackwater" else &"select_northline",game._epoch)
	await settle()
	check(game._session.map_id==map_id,"current-epoch selection also inert while active")
	var descriptor:Dictionary=game._session.deployment.deployment.get("map",{})
	check(descriptor==game._native_map.descriptor() if map_id!="sawmill" else descriptor.is_empty(),"escrow pins actual preflight descriptor")
	await capture("raid")
	if scenario=="launch":
		for _i in range(8):check(game.advance(),"native tick")
	elif scenario=="extract":
		ops.fail_next_write=true
		var driver=load("res://tests/local/local_flow_player_driver.gd").new()
		if not await driver.extract(game,self,Callable(self,"check"),true):await finish();return
		check(ops.failures_injected==1,"one settlement-write fault, not outcome injection")
		check(game._summary.get("map",{})==descriptor,"committed receipt pins same map")
		await capture("extracted")
		var before:=store.load_profile()
		if not await click("BackBunker") or not route("bunker"):await finish();return
		check(store.load_profile().generation==before.generation,"return home does not settle again")
		if not await click("BunkerHideoutView/LocalDeploy") or not route("maps"):await finish();return
		if not await click("ZoneHit"+str(index)) or not await click("Deploy") or not route("hud"):await finish();return
		check(game._session.combat.health.actor_snapshot(game._session.raid.admission().actor_id).alive,"second live actor restored under existing home policy")
	elif scenario=="death":
		var driver=load("res://tests/local/local_flow_player_driver.gd").new()
		if not await driver.die_from_enemy(game,self,Callable(self,"check")):await finish();return
		check(game._summary.get("map",{})==descriptor,"death receipt pins same map")
		await capture("death")
	# Normal shutdown of a running session leaves escrow for actual restart recovery.
	if not check(game.shutdown(),"application shutdown"):await finish();return
	game.queue_free();await settle();game=null
	store=ProfileStore.new();ops=FailOnceIO.new(StringName(test_namespace))
	check(store.configure_with_trusted_operations(LocalCampaignContent.PROFILE_ID,ops),"reopen real files")
	var campaign:=LocalCampaign.new()
	if not check(campaign.open(store),"actual-file recovery "+String(campaign.last_error)):await finish();return
	var loaded:=store.load_profile();var state:Dictionary=loaded.payload.project[RaidProgressionValues.STATE_KEY]
	check(state.active.is_empty(),"no hidden live raid after recovery")
	for bytes:PackedByteArray in state.history.values():
		check(RaidProgressionValues.decode(bytes).get("map",{}).get("id","sawmill")==map_id,"restart never attributes result to another map")
	print("LIVE_MAP_FINGERPRINT ",loaded.fingerprint)
	await finish()

func finish() -> void:
	if game!=null and is_instance_valid(game):
		check(game.shutdown(),"shutdown after test "+String(game.last_error))
		game.queue_free();await settle();game=null
	if store!=null and store.is_configured():store.close()
	print("LIVE_MAP_FLOW_RESULT checks=",checks," failures=",failures," map=",map_id," case=",scenario)
	quit(0 if failures==0 else 1)
