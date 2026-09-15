extends SceneTree
## Real native inventory, health/combat composition, discovery, Level Task,
## interaction policy and RaidAuthority; only filesystem failure uses a double.
## Poses are authored fixture placements, not a Sawmill traversal/playtest claim.
const V = preload("res://game/raid/progression/raid_progression_values.gd")
const StoreTests = preload("res://tests/raid/profile_store_contract.gd")
var checks: int = 0
var failures: int = 0
var _serial: int = 0
var _nodes: Array[Node] = []
var _deployment: RaidDeployment
var _combat: RaidCombatSession
var _progress: RaidProgression
var _policy: ZInteractionPolicyOwner
var _layout: ZSawmillYardLayout
var _move: ZPlayerLocomotion
var _encoder: RaidGameplayInput
var _store: ProfileStore
var _ops: StoreTests.FakeFileOperations
var _objective_id: int = 0
var _crate_map: Dictionary = {}

func _initialize() -> void:
	run.call_deferred()
func check(ok: bool, text: String) -> void:
	checks+=1
	if not ok: failures+=1;push_error("NATIVE_RAID_PROGRESSION: "+text)
func run() -> void:
	create_timer(50.0).timeout.connect(func(): push_error("native progression watchdog");quit(1))
	if not ClassDB.class_exists("LevelTaskRuntimeBridge") or not ClassDB.class_exists("InventoryAuthority"):
		print("NATIVE_RAID_PROGRESSION_BLOCKED missing_native_addons");quit(2);return
	_test_task()
	if failures==0: _test_inventory()
	if failures==0 and _setup(): _test_raid()
	await _cleanup()
	print("NATIVE_RAID_PROGRESSION_RESULT checks=",checks," failures=",failures)
	quit(0 if failures==0 else 1)
func _test_task() -> void:
	var bridge: Object=ClassDB.instantiate("LevelTaskRuntimeBridge")
	var compiled: Dictionary=bridge.call("compile_task_graph",SupplyRunGraph.definition())
	check(compiled.get("ok",false),"real Supply Run graph compile: "+str(compiled))
	if failures>0:return
	var task:=SupplyRunTask.new()
	check(task.configure("zerkov.raid.task.native"),"native host starts and explicitly acknowledges accept: "+String(task.last_error))
	if failures>0:return
	check(task.update_facts(false),"typed inventory fact")
	check(task.crate_committed(SupplyRunGraph.CRATES[0],1,1),"first native objective event: "+String(task.last_error))
	check(task.crate_committed(SupplyRunGraph.CRATES[0],2,2) and task.snapshot().searched_crates==1,"distinct crate dedup")
	check(task.crate_committed(SupplyRunGraph.CRATES[1],3,3),"second crate")
	check(task.crate_committed(SupplyRunGraph.CRATES[2],4,4),"third crate")
	check(not task.ready_to_extract(),"objective ownership still required")
	check(task.update_facts(true) and task.ready_to_extract(),"live inventory fact unlocks pending extraction request")
	check(task.extracted(SupplyRunGraph.ROAD_GATE),"host-acknowledged extraction and reward completion: "+String(task.last_error))
	check(task.snapshot().completion_token and task.snapshot().status=="succeeded" and not task.snapshot().resume_enabled,"native terminal completion and resume policy")
	task.release()
	var dead:=SupplyRunTask.new();check(dead.configure("zerkov.raid.task.dead"),"second isolated native task")
	check(dead.fail_raid(1,1) and dead.snapshot().status=="failed","native failure path cancels active objectives")
	dead.release()
func _seed_owner() -> RaidInventoryOwner:
	var owner:=RaidInventoryOwner.new();root.add_child(owner);_nodes.append(owner)
	check(owner.configure(),"native prepared inventory owner")
	var native:=owner.raid_authority();var id:=owner.raid_player_inventory_id
	var pocket:=_container(native.snapshot(id),ZerkovInventoryCatalog.CONTAINER_POCKETS)
	var secure:=_container(native.snapshot(id),ZerkovInventoryCatalog.CONTAINER_SECURE)
	var equipment:=_container(native.snapshot(id),ZerkovInventoryCatalog.CONTAINER_EQUIPMENT)
	var rows: Array=[
		[ZerkovInventoryCatalog.ITEM_BANDAGE,2,{"kind":"spatial","container":secure,"x":0,"y":0,"rotated":false}],
		[ZerkovInventoryCatalog.ITEM_AMMO_762,40,{"kind":"spatial","container":pocket,"x":0,"y":0,"rotated":false}],
		[ZerkovInventoryCatalog.ITEM_AKM,1,{"kind":"slot","container":equipment,"slot_identifier":String(EquippedItemReconciler.SLOT_PRIMARY)}]]
	for row in rows:
		var result:=native.insert_item(id,String(row[0]),row[1],row[2],7100003)
		check(result.get("accepted",false),"explicit test-only inventory seed")
	return owner
func _test_inventory() -> void:
	var source:=_seed_owner();var original:=source.raid_authority().make_persistence_record(source.raid_player_inventory_id)
	var adapter:=NativeSettlementInventory.new();check(adapter.configure(source.catalog()),"native settlement catalog")
	check(adapter.validate_loadout(original),"native persistence validation")
	var extracted:=adapter.plan(original,"extracted")
	check(extracted.get("ok",false) and extracted.record==original and extracted.lost.is_empty(),"extract preserves entire native record")
	var dead:=adapter.plan(original,"dead")
	check(dead.get("ok",false),"one native death settlement transaction: "+str(dead.get("diagnostic",{})))
	if failures>0:return
	check(dead.retained==[{"definition":String(ZerkovInventoryCatalog.ITEM_BANDAGE),"quantity":2}],"secure contents retained")
	check(dead.lost.size()==2 and adapter.validate_loadout(dead.record),"unsecured equipment/ammunition lost, result still valid native record")
	check(source.raid_authority().make_persistence_record(source.raid_player_inventory_id)==original,"planning did not mutate live owner")
	var repeat:=adapter.plan(dead.record,"dead")
	check(repeat.get("ok",false) and repeat.lost.is_empty(),"native retained plan is repeat-safe")
func _setup() -> bool:
	var source:=_seed_owner()
	_ops=StoreTests.FakeFileOperations.new("native_task7")
	_store=ProfileStore.new();check(_store.configure_with_trusted_operations("zerkov.profile.native_task7",_ops),"real ProfileStore")
	var payload: Dictionary={"project":{},"domains":{V.LOADOUT:source.raid_authority().make_persistence_record(1),V.STASH:source.profile_authority().make_persistence_record(1)}}
	check(_store.save_profile(payload,0,1).committed,"immutable selected generation")
	_deployment=RaidDeployment.new()
	check(_deployment.begin(root,_store,"zerkov.request.deploy.native",1,42),"persisted deployment then owner construction: "+String(_deployment.last_error))
	if failures>0:return false
	_nodes.append(_deployment.inventory)
	var raid:=_deployment.raid;var owner:=_deployment.inventory
	_layout=load("res://game/world/sawmill/sawmill_yard_layout.tres") as ZSawmillYardLayout
	check(_layout!=null,"authored Sawmill layout")
	_move=ZPlayerLocomotion.new();_move.configure(raid.admission().actor_id,Vector2(32,32),ZPlayerFacing.Facing4.EAST)
	check(_move.register_with_authority(raid,raid.generation()),"real locomotion phase")
	_combat=RaidCombatSession.new();root.add_child(_combat);_nodes.append(_combat)
	var roster: Array[Dictionary]=[{"actor_id":raid.admission().actor_id,"source":int(ZRaidIntent.Source.PLAYER),"movement":_move,"movement_handler":ZPlayerLocomotion.DEFAULT_PHASE_HANDLER_ID,"inventory":owner,"natural_melee":false}]
	check(_combat.start(raid,roster),"combat baseline composition: "+String(_combat.last_error))
	var targets:=ZInteractionTargetIndex.build_from_sawmill_layout(_layout)
	var bake:=ZOccluderBake.bake(_layout.structures,_layout.size_cells)
	check(targets.ok and bake.ok,"real target/occluder data")
	_policy=ZInteractionPolicyOwner.new()
	check(_policy.configure(raid.generation(),targets.targets,bake.segments) and _policy.register_with_authority(raid,raid.generation()),"single interaction policy owner")
	for index in range(3):
		var id: int=owner.world_crate_inventory_id if index==0 else owner.raid_authority().create_inventory(String(ZerkovInventoryCatalog.PROFILE_WORLD_CRATE))
		_crate_map[SupplyRunGraph.CRATES[index]]=id
	var first: int=_crate_map[SupplyRunGraph.CRATES[0]]
	var native:=owner.raid_authority()
	var root_container:=int(native.snapshot(first).get_containers()[0].id)
	var inserted:=native.insert_item(first,String(ZerkovInventoryCatalog.ITEM_SUPPLY_CRATE),1,{"kind":"spatial","container":root_container,"x":0,"y":0,"rotated":false},7100003)
	check(inserted.get("accepted",false),"authored objective crate fixture (not profile fallback)")
	for item: Dictionary in native.snapshot(first).get_items():
		if item.item_definition_identifier==String(ZerkovInventoryCatalog.ITEM_SUPPLY_CRATE):_objective_id=item.id
	_progress=RaidProgression.new()
	check(_progress.bind(raid,owner,_combat,_policy,_crate_map,1000,3,_move),"task7 composition: "+String(_progress.last_error))
	_encoder=RaidGameplayInput.new()
	check(_encoder.configure(raid.admission().session_id,raid.admission().actor_id,raid.admission().authority_epoch,raid.generation()),"single input sequence owner")
	check(raid.transition(RaidAuthority.Lifecycle.ACTIVE,raid.generation()),"activate persisted deployment")
	return failures==0
func _tick() -> bool:
	if failures>0:return false
	var raid:=_deployment.raid
	var ok:=raid.advance_one(raid.generation())
	check(ok,"raid tick: "+String(raid.last_error)+" / "+String(_progress.last_error))
	if not ok:return false
	check(_progress.after_tick(),"post-tick lifecycle: "+String(_progress.last_error))
	return failures==0
func _intent(target: String, cancel: bool=false) -> void:
	var raid:=_deployment.raid
	var intent:=_encoder.build_progression_intent(raid.last_processed_tick+1,&"raid_cancel" if cancel else &"interaction",{} if cancel else {"target_id":target})
	check(intent!=null and raid.enqueue_intent(intent,raid.generation()),"canonical progression input")
func _place(anchor_id: String) -> void:
	# Test-owned authored pose fixture, not player teleport capability or traversal evidence.
	var anchor:=_layout.anchor(anchor_id)
	check(_move.teleport(_layout.cell_center(anchor.approach_cell)),"fixture placement through authoritative movement owner")
func _test_raid() -> void:
	var raid:=_deployment.raid
	_intent(SupplyRunGraph.CRATES[0]);if not _tick():return
	check(_progress.snapshot().task.searched_crates==0,"distant interaction cannot complete objective")
	var paused:=_progress.snapshot()
	raid.clock.pause();raid.request_clock_ticks(10,raid.generation())
	check(raid.drain_requested_ticks(raid.generation())==0 and _progress.snapshot()==paused,"paused queued ticks do not advance searches or timer")
	raid.clock.clear_pending();raid.clock.resume()
	for key: String in SupplyRunGraph.CRATES:
		_place(key);_intent(key);if not _tick():return
		var evaluated:=_policy.evaluate_for_actor(raid.admission().actor_id,StringName(key),ZInteractionKind.CRATE,raid.generation())
		check(_progress.snapshot().searching==key,"native search began for "+key+": "+str(_progress.snapshot())+" policy="+String(evaluated.reason))
		if failures>0:return
		var before: int=_progress.snapshot().task.searched_crates
		for elapsed in range(53):
			if not _tick():return
		check(_progress.snapshot().task.searched_crates==before,"native search cannot complete early")
		if not _tick():return
		check(_progress.snapshot().task.searched_crates==before+1,"sealed 900ms search completes at 54 canonical ticks: "+str(_progress.snapshot()))
		_intent(key);if not _tick():return
		check(_progress.snapshot().task.searched_crates==before+1,"repeated crate open does not recount")
	_place(SupplyRunGraph.ROAD_GATE);_intent(SupplyRunGraph.ROAD_GATE);if not _tick():return
	check(not _progress.snapshot().clock.counting,"three crates alone insufficient without retained supply")
	_transfer_objective(true)
	_intent(SupplyRunGraph.ROAD_GATE);if not _tick():return
	check(raid.lifecycle==RaidAuthority.Lifecycle.EXTRACTING and _progress.snapshot().clock.counting,"eligible Road Gate countdown")
	_transfer_objective(false)
	if not _tick():return
	check(raid.lifecycle==RaidAuthority.Lifecycle.ACTIVE and _progress.snapshot().clock.interruption=="ineligible","losing item interrupts extraction")
	_transfer_objective(true);_intent(SupplyRunGraph.ROAD_GATE);if not _tick():return
	_intent("",true);if not _tick():return
	check(not _progress.snapshot().clock.counting,"explicit cancellation")
	_intent(SupplyRunGraph.ROAD_GATE);if not _tick():return
	for elapsed in range(3):
		if not _tick():return
	check(raid.lifecycle==RaidAuthority.Lifecycle.SETTLING and _progress.terminal_record().outcome=="extracted","one canonical extracted outcome")
	check(_progress.snapshot().task.completion_token and not _progress.snapshot().summary_final,"native task complete but summary not prematurely final")
	check(not _deployment.settlement.summary(raid.raid_id().canonical_key()).ok,"no durable summary before settlement")
	_ops.fail_before("write:write_temp")
	var failed:=_progress.finish(_deployment.settlement)
	check(not failed.ok and raid.lifecycle==RaidAuthority.Lifecycle.SETTLING,"write failure leaves resumable settlement not gameplay")
	var final:=_progress.finish(_deployment.settlement)
	check(final.ok and final.committed and raid.lifecycle==RaidAuthority.Lifecycle.COMPLETED,"retry completes canonical profile and raid")
	if failures>0:return
	check(final.receipt.task.status=="succeeded" and final.receipt.retained.size()>0,"committed task and retained native loadout")
	check(_deployment.settlement.commit(raid.raid_id().canonical_key()).replayed,"lost result acknowledgement replays")
	check(_progress.finish(_deployment.settlement).receipt==final.receipt,"post-commit controller retry returns the same result")
	check(not raid.advance_one(raid.generation()),"completed raid cannot mutate profile result")
	var loaded:=_store.load_profile();var native:=NativeSettlementInventory.new();native.configure()
	check(native.validate_loadout(loaded.payload.domains[V.LOADOUT]),"settled native inventory reloads")
	check(_store.close(),"close writer")
	var reopened:=ProfileStore.new();reopened.configure_with_trusted_operations("zerkov.profile.native_task7",_ops)
	var reader:=RaidSettlementService.new();reader.configure(reopened,native)
	check(reader.summary(raid.raid_id().canonical_key()).receipt==final.receipt,"fresh service displays exact committed summary")
	reopened.close()
func _transfer_objective(to_player: bool) -> void:
	# Real native command from trusted fixture host; task adapter only sees the
	# resulting ownership snapshot. No objective boolean is written into task state.
	var owner:=_deployment.inventory;var native:=owner.raid_authority()
	var crate: int=_crate_map[SupplyRunGraph.CRATES[0]]
	var destination: int=owner.raid_player_inventory_id if to_player else crate
	var container: int=_container(native.snapshot(destination),ZerkovInventoryCatalog.CONTAINER_POCKETS) if to_player else int(native.snapshot(crate).get_containers()[0].id)
	var result:=native.loot_item(crate if to_player else owner.raid_player_inventory_id,destination,_objective_id,{"kind":"spatial","container":container,"x":1 if to_player else 0,"y":0,"rotated":false},7100003)
	check(result.get("accepted",false),"canonical objective ownership transfer: "+str(result.get("status",{})))
func _container(snapshot: InventorySnapshotResource, definition: StringName) -> int:
	for row: Dictionary in snapshot.get_containers():
		if int(row.provider_item)==0 and StringName(row.container_definition_identifier)==definition:return int(row.id)
	return 0
func _cleanup() -> void:
	if _progress!=null:_progress.release()
	if _combat!=null:_combat.release()
	if _deployment!=null and _deployment.raid!=null:_deployment.raid.teardown(_deployment.raid.generation())
	if _store!=null and _store.is_configured():_store.close()
	for node in _nodes:
		if is_instance_valid(node):node.queue_free()
	await process_frame
