extends SceneTree
## Real ProfileStore/CAS/codec, explicitly fake filesystem and inventory port.
## Native inventory ownership and native Level Task tested separately.
const V = preload("res://game/raid/progression/raid_progression_values.gd")
const StoreTests = preload("res://tests/raid/profile_store_contract.gd")
var checks: int = 0
var failures: int = 0
var serial: int = 0

class InventoryDouble extends SettlementInventoryPort:
	func validate_loadout(bytes: PackedByteArray) -> bool:
		var decoded := RaidProgressionValues.decode(bytes)
		return decoded.has("secure") and decoded.has("exposed")
	func validate_stash(bytes: PackedByteArray) -> bool:
		return RaidProgressionValues.decode(bytes).get("kind") == "stash"
	func plan(bytes: PackedByteArray, outcome: String) -> Dictionary:
		var loadout := RaidProgressionValues.decode(bytes)
		var lost: Array = []
		if outcome != "extracted":
			lost = loadout.exposed.duplicate(true)
			loadout.exposed = []
		var retained: Array = loadout.secure.duplicate(true)
		retained.append_array(loadout.exposed)
		return {"ok":true,"record":RaidProgressionValues.encode(loadout),"retained":retained,"lost":lost}

func _initialize() -> void:
	run.call_deferred()
func check(ok: bool, text: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error("RAID_PROGRESSION: " + text)
func run() -> void:
	_test_countdown()
	_test_persistence()
	_test_population_persistence()
	_test_active_recovery()
	_test_malformed_state()
	_test_deployment_prepare_faults()
	for action: String in ["write:write_temp", "replace:backup_temp:backup", "replace:write_temp:primary"]:
		for after: bool in [false,true]:
			_test_fault(action,after)
	print("RAID_PROGRESSION_RESULT checks=",checks," failures=",failures)
	quit(0 if failures == 0 else 1)

func _fixture() -> Dictionary:
	serial += 1
	var ops := StoreTests.FakeFileOperations.new("task7_"+str(serial))
	var store := ProfileStore.new()
	check(store.configure_with_trusted_operations("zerkov.profile.task7",ops),"existing store configured")
	var payload := {"project":{}, "domains":{V.LOADOUT:V.encode({"secure":[{"definition":"safe","quantity":1}],"exposed":[{"definition":"rifle","quantity":1}]}),V.STASH:V.encode({"kind":"stash"})}}
	check(store.save_profile(payload,0,1).committed,"initial profile")
	var service := RaidSettlementService.new()
	check(service.configure(store,InventoryDouble.new()),"settlement service configured")
	return {"ops":ops,"store":store,"service":service,"payload":payload}
func _terminal(outcome: String = "extracted") -> Dictionary:
	return {"outcome":outcome,"tick":99,"audit_available":true,"audit_digest":V.digest({"test":true}),"stats":{"kills":0},"health":{"alive":outcome!="dead"},"task":{"status":"succeeded"}}
func _test_countdown() -> void:
	var timer := ExtractionCountdown.new()
	check(not timer.configure(0,100) and timer.configure(3,10),"bounded authored duration")
	check(not timer.advance(2,true,true,true,false,true,false).ok,"cannot skip clock tick")
	var first := timer.advance(1,true,true,true,false,true,false)
	check(first.counting and first.countdown_remaining==3,"first eligible tick starts")
	for i in range(100): check(timer.snapshot()==first,"HUD poll no progression")
	check(timer.advance(2,true,true,true,true,false,false).interruption=="damaged","damage interrupts")
	check(timer.advance(3,true,true,true,false,true,false).counting,"restart explicitly requested")
	check(timer.advance(4,true,false,true,false,false,false).interruption=="ineligible","losing objective interrupts")
	check(timer.advance(5,true,true,true,false,true,false).counting,"reacquire/start")
	check(timer.advance(6,true,true,false,false,false,false).interruption=="left_zone","exit interrupts")
	timer.advance(7,true,true,true,false,true,false)
	check(timer.advance(8,true,true,true,false,true,true).interruption=="cancelled","cancel beats simultaneous start")
	timer.advance(9,true,true,true,false,true,false)
	check(timer.advance(10,true,true,true,false,false,false).outcome=="timeout","timeout canonical deadline")
	check(not timer.advance(11,true,true,true,false,true,false).ok,"terminal once only")
	for dead: bool in [false,true]:
		var t := ExtractionCountdown.new();t.configure(2,100)
		t.advance(1,true,true,true,false,true,false);t.advance(2,true,true,true,false,false,false)
		check(t.advance(3,not dead,true,true,false,false,false).outcome==("dead" if dead else "extracted"),"same-tick death wins extraction")
func _test_persistence() -> void:
	var f := _fixture()
	check(not f.service.deploy("bad",1).ok,"invalid request")
	check(not f.service.deploy("zerkov.request.deploy.one",2).ok,"stale selected generation")
	var deployment: Dictionary = f.service.deploy("zerkov.request.deploy.one",1)
	check(deployment.ok and deployment.committed and deployment.can_instantiate,"identity persisted before roster exposure")
	var raid: String = deployment.deployment.raid_id
	var before: Dictionary = f.store.load_profile()
	var retry: Dictionary = f.service.deploy("zerkov.request.deploy.one",1)
	check(retry.ok and retry.replayed and not retry.can_instantiate,"retry cannot create second live raid/resume")
	check(f.store.load_profile().generation==before.generation,"deploy retry no write")
	check(not f.service.deploy("zerkov.request.deploy.other",2).ok,"active profile locked")
	check(not f.service.summary(raid).ok,"preparation is not a summary")
	var terminal := _terminal()
	var prepared: Dictionary = f.service.prepare(raid,terminal,f.payload.domains[V.LOADOUT])
	check(prepared.ok and prepared.prepared and not prepared.committed,"prepare durable plan not final result")
	check(not f.service.summary(raid).ok and RaidSummaryView.from_committed(prepared)==null,"pending result hidden")
	check(f.service.prepare(raid,terminal,f.payload.domains[V.LOADOUT]).replayed,"prepare retry exactly once")
	check(not f.service.prepare(raid,_terminal("dead"),f.payload.domains[V.LOADOUT]).ok,"conflicting outcome same identity rejected")
	var committed: Dictionary = f.service.commit(raid)
	check(committed.ok and committed.committed and committed.receipt.outcome=="extracted","profile-backed result")
	check(committed.profile_generation==4 and committed.receipt.profile_generation==4,"three CAS boundaries after initial profile")
	check(f.service.commit(raid).replayed and f.store.load_profile().generation==4,"commit ack loss cannot duplicate")
	check(f.service.deploy("zerkov.request.deploy.one",1).status==&"already_settled","completed deployment request cannot rerun")
	var receipts: Dictionary = f.service.summary(raid)
	var view:=RaidSummaryView.from_committed(receipts)
	check(view!=null and view.snapshot().final and view.snapshot().retained.is_read_only(),"only committed records produce immutable summary values")
	var changed: Dictionary=receipts.duplicate(true)
	changed.receipt.retained.clear()
	check(not view.snapshot().retained.is_empty(),"later caller mutation cannot change summary")
	check(receipts.receipt.lost.is_empty() and not receipts.receipt.valuation_available and receipts.receipt.currency_reward==0,"no invented loss or valuation")
	var checkpoint: Dictionary = f.store.load_profile()
	check(f.store.close(),"release store for process-like replacement")
	var replacement := ProfileStore.new();check(replacement.configure_with_trusted_operations("zerkov.profile.task7",f.ops),"reopen existing bytes")
	var service := RaidSettlementService.new();service.configure(replacement,InventoryDouble.new())
	check(service.summary(raid).receipt==receipts.receipt and replacement.load_profile().fingerprint==checkpoint.fingerprint,"fresh owner restores exact committed result/profile")
	check(service.recover().status==&"no_active_raid","completed does not recover twice")
	check(replacement.close(),"replacement cleanup")
func _test_population_persistence() -> void:
	var f := _fixture()
	var population := {"version":1,"map_id":"sawmill","seed":17,"map_identity":"a".repeat(64),"digest":"b".repeat(64)}
	var changed := population.duplicate(true); changed["digest"]="c".repeat(64)
	check(V.valid_population_descriptor(population),"closed population descriptor")
	for invalid: Variant in [{}, {"version":1,"map_id":"sawmill","seed":0,"map_identity":"a".repeat(64),"digest":"b".repeat(64)},
		{"version":2,"map_id":"sawmill","seed":17,"map_identity":"a".repeat(64),"digest":"b".repeat(64)},
		{"version":1,"map_id":"foreign","seed":17,"map_identity":"a".repeat(64),"digest":"b".repeat(64)},
		{"version":1,"map_id":"sawmill","seed":17,"map_identity":"bad","digest":"b".repeat(64)}]:
		check(not V.valid_population_descriptor(invalid),"malformed population descriptor rejected")
	var wrong_map := population.duplicate(true); wrong_map["map_id"]="northline"
	check(f.service.deploy("zerkov.request.deploy.population.wrong_map",1,{},wrong_map).get("reason") \
		== &"deployment_population_map_invalid", "population descriptor is bound to selected map")
	var deployed: Dictionary = f.service.deploy("zerkov.request.deploy.population",1,{},population)
	check(deployed.ok and deployed.deployment.population==population,"population pinned before live owner")
	var generation: int = int(f.store.load_profile().generation)
	var replay: Dictionary = f.service.deploy("zerkov.request.deploy.population",1,{},population)
	check(replay.ok and replay.replayed and f.store.load_profile().generation==generation,
		"identical population retry performs no write")
	check(f.service.deploy("zerkov.request.deploy.population",1,{},changed).get("reason")==&"deployment_population_conflict",
		"same request cannot change population plan")
	var raid: String = deployed.deployment.raid_id
	check(f.service.prepare(raid,_terminal(),f.payload.domains[V.LOADOUT]).ok,"population deployment prepares")
	var committed: Dictionary = f.service.commit(raid)
	check(committed.ok and committed.receipt.population==population,"receipt preserves population identity")
	check(f.service.deploy("zerkov.request.deploy.population",1,{},changed).get("reason")==&"deployment_population_conflict",
		"history retry cannot change population identity")
	check(f.store.close(),"population fixture close")
	var replacement := ProfileStore.new()
	check(replacement.configure_with_trusted_operations("zerkov.profile.task7",f.ops),"population fixture reopen")
	var service := RaidSettlementService.new(); service.configure(replacement,InventoryDouble.new())
	check(service.summary(raid).receipt.population==population,"fresh owner restores population descriptor")
	check(replacement.close(),"population replacement close")

func _test_active_recovery() -> void:
	var f := _fixture()
	var deployed: Dictionary = f.service.deploy("zerkov.request.deploy.crash",1)
	var raid: String = deployed.deployment.raid_id
	var result: Dictionary = f.service.recover()
	check(result.ok and result.receipt.outcome=="abandoned","no unproven midraid resume")
	var loadout := V.decode(f.store.load_profile().payload.domains[V.LOADOUT])
	check(loadout.exposed.is_empty() and loadout.secure.size()==1,"crash loss applies to escrow, secure retained")
	check(not result.receipt.audit_available,"no invented actual raid duration/audit")
	check(f.service.recover().status==&"no_active_raid","crash recovery idempotent")
	f.store.close()
func _test_fault(action: String, after: bool) -> void:
	var f := _fixture()
	var deployment: Dictionary = f.service.deploy("zerkov.request.deploy.fault",1)
	var raid: String = deployment.deployment.raid_id
	check(f.service.prepare(raid,_terminal(),f.payload.domains[V.LOADOUT]).ok,"fault prepared checkpoint")
	if after: f.ops.fail_after(action)
	else: f.ops.fail_before(action)
	var attempted: Dictionary = f.service.commit(raid)
	check(f.store.close(),"crash/restart writer lease")
	var replacement := ProfileStore.new()
	check(replacement.configure_with_trusted_operations("zerkov.profile.task7",f.ops),"reopen after write fault")
	var service := RaidSettlementService.new();service.configure(replacement,InventoryDouble.new())
	var recovery := service.recover()
	var final := service.summary(raid)
	check(recovery.ok and final.ok and final.committed,"recover interrupted save: "+action+str(after))
	check(final.receipt.outcome=="extracted" and replacement.load_profile().generation==4,"no duplicate value / lost prepared plan")
	check(service.commit(raid).replayed,"post-recovery acknowledgement is replay")
	check(replacement.close(),"fault fixture cleanup")


func _test_malformed_state() -> void:
	for malformed: Variant in [true, {}, {"version":1,"next_sequence":2,"history":{},"active":{"phase":"prepared"}}]:
		var f:=_fixture()
		var loaded: Dictionary=f.store.load_profile()
		var payload: Dictionary=loaded.payload.duplicate(true)
		payload.project[V.STATE_KEY]=malformed
		check(f.store.save_profile(payload,loaded.generation,loaded.generation+1).committed,"fixture has valid outer profile checksum")
		check(not f.service.recover().ok,"semantic active schema fails closed without indexing missing keys")
		f.store.close()
	var f:=_fixture()
	var deployed: Dictionary=f.service.deploy("zerkov.request.deploy.semantic",1)
	var loaded: Dictionary=f.store.load_profile()
	var altered: Dictionary=loaded.payload.duplicate(true)
	altered.project["unrelated_change"]=true
	check(f.store.save_profile(altered,2,3).committed,"external writer fixture")
	check(not f.service.prepare(deployed.deployment.raid_id,_terminal(),f.payload.domains[V.LOADOUT]).ok,"profile generation cannot drift during escrow")
	f.store.close()

func _test_deployment_prepare_faults() -> void:
	for phase: String in ["deployment","prepare"]:
		for point: String in ["write:write_temp","replace:backup_temp:backup","replace:write_temp:primary"]:
			for after: bool in [false,true]:
				var f:=_fixture()
				var raid: String=V.ids(f.store.profile_id(),1).raid_id
				if phase=="prepare":check(f.service.deploy("zerkov.request.deploy.matrix",1).ok,"prepare fault deployment")
				if after:f.ops.fail_after(point)
				else:f.ops.fail_before(point)
				var result: Dictionary=f.service.deploy("zerkov.request.deploy.matrix",1) if phase=="deployment" else f.service.prepare(raid,_terminal(),f.payload.domains[V.LOADOUT])
				f.store.close()
				var store:=ProfileStore.new();check(store.configure_with_trusted_operations("zerkov.profile.task7",f.ops),"reopen interrupted checkpoint")
				var service:=RaidSettlementService.new();service.configure(store,InventoryDouble.new())
				var recovered:=service.recover()
				check(recovered.ok,"recover at "+phase+":"+point+":"+str(after))
				var loaded_after:=store.load_profile()
				if recovered.get("status")==&"no_active_raid":
					check(loaded_after.generation==1,"uncommitted deployment did not allocate or lose anything")
				else:
					check(recovered.committed and recovered.receipt.outcome in ["abandoned","extracted"],"only persisted outcome or explicit no-resume policy")
					check(service.commit(raid).replayed and loaded_after.generation==4,"checkpoint recovery applies value once")
				store.close()
