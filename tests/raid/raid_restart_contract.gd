extends SceneTree
## Real process/file replacement contract. Each mode runs in a fresh Godot
## process, using a runner-generated isolated namespace (never live profiles).
## Terminal metadata is a labelled fixture; native raid execution is separate.
const V=preload("res://game/raid/progression/raid_progression_values.gd")
const PROFILE="zerkov.profile.restart_contract"
const REQUEST="zerkov.request.restart_contract.deploy"
var checks: int=0
var failures: int=0
func _initialize() -> void:
	run.call_deferred()
func check(ok: bool, text: String) -> bool:
	checks+=1
	if not ok: failures+=1;push_error("RAID_RESTART: "+text)
	return ok
func run() -> void:
	var args:=OS.get_cmdline_user_args()
	if args.size()<2 or args[0] not in ["prepare","recover","verify","cleanup"] \
		or not args[1].begins_with("task7_") or args[1].length()!=38 or not args[1].substr(6).is_valid_hex_number():
		push_error("invalid restart fixture invocation");quit(2);return
	var mode: String=args[0]
	var operations:=GodotProfileFileOperations.new(StringName(args[1]))
	var store:=ProfileStore.new()
	if not check(store.configure_with_trusted_operations(PROFILE,operations),"real filesystem store configures"):
		quit(1);return
	if mode=="cleanup":
		for slot in ProfileFileOperations.ALL_SLOTS:
			check(operations.remove_slot(slot).get("ok",false),"delete only isolated fixture slot")
		store.close()
		print("RAID_RESTART_CLEANUP checks=",checks," failures=",failures)
		quit(failures);return
	var native:=NativeSettlementInventory.new()
	if not check(native.configure(),"real native inventory catalog"):
		quit(1);return
	var service:=RaidSettlementService.new();service.configure(store,native)
	var ids:=V.ids(PROFILE,1)
	var input_digest: String=""
	if mode=="prepare":
		if not check(not store.load_profile().ok,"unique namespace starts empty"):
			quit(1);return
		var owner:=RaidInventoryOwner.new();root.add_child(owner)
		if not check(owner.configure(),"native fixture inventory"):
			quit(1);return
		var snapshot:=owner.raid_authority().snapshot(1)
		var secure: int=0
		for container: Dictionary in snapshot.get_containers():
			if container.container_definition_identifier==String(ZerkovInventoryCatalog.CONTAINER_SECURE):secure=int(container.id)
		var inserted:=owner.raid_authority().insert_item(1,String(ZerkovInventoryCatalog.ITEM_BANDAGE),2,
			{"kind":"spatial","container":secure,"x":0,"y":0,"rotated":false},7100003)
		if not check(inserted.get("accepted",false),"explicit native persistence-only fixture"):
			quit(1);return
		var domains: Dictionary={V.LOADOUT:owner.raid_authority().make_persistence_record(1),V.STASH:owner.profile_authority().make_persistence_record(1)}
		var result:=store.save_profile({"project":{},"domains":domains},0,1)
		check(result.committed and result.verified and not result.durable,"actual file flush, no directory-fsync claim")
		var deployment:=service.deploy(REQUEST,1)
		if not check(deployment.ok and deployment.deployment.raid_id==ids.raid_id,"deployment bytes committed"):
			quit(1);return
		var terminal: Dictionary={"outcome":"extracted","tick":100,"audit_available":true,
			"audit_digest":V.digest({"fixture":"restart-contract-not-gameplay"}),"stats":{"kills":0},"health":{"alive":true},"task":{"status":"succeeded"}}
		var prepared:=service.prepare(ids.raid_id,terminal,domains[V.LOADOUT])
		if not check(prepared.ok and prepared.prepared and not prepared.committed,"prepared record on actual disk"):
			quit(1);return
		input_digest=prepared.receipt.input_digest
		check(store.load_profile().generation==3 and not service.summary(ids.raid_id).ok,"no summary at precommit exit")
		# Exit before commit without consuming recovery. The next process has no
		# object graph, singleton writer lease or in-memory plan from this process.
		owner.queue_free()
	else:
		if not check(args.size()>=3 and V.sha(args[2]),"runner carries expected input digest"):
			quit(1);return
		input_digest=args[2]
		if mode=="recover":
			var recovered:=service.recover()
			if not check(recovered.ok and recovered.committed,"fresh process commits persisted plan"):
				quit(1);return
		var summary:=service.summary(ids.raid_id)
		var loaded:=store.load_profile()
		if not check(summary.ok and summary.committed and loaded.ok,"committed profile and summary reopen"):
			quit(1);return
		check(summary.receipt.input_digest==input_digest and summary.receipt.profile_generation==4 and loaded.generation==4,"exact one settlement commit across processes")
		check(native.validate_loadout(loaded.payload.domains[V.LOADOUT]),"fresh native loadout decode")
		check(summary.receipt.retained==[{"definition":String(ZerkovInventoryCatalog.ITEM_BANDAGE),"quantity":2}],"native retained quantities unchanged")
		check(service.commit(ids.raid_id).replayed and store.load_profile().generation==4,"lost postcommit acknowledgement replay")
		if mode=="verify":check(args.size()==4 and loaded.fingerprint==args[3],"second relaunch restores byte-identical committed envelope")
	var final:=store.load_profile()
	print("RAID_RESTART_RESULT checks=",checks," failures=",failures," mode=",mode," input=",input_digest," profile=",final.get("fingerprint",""))
	store.close()
	quit(0 if failures==0 else 1)
