class_name RaidDeployment
extends RefCounted
## A one-shot composition bootstrap. Record identity/escrow BEFORE constructing
## live inventory or a session. The root owns scene lifetime and later settlement.
var raid: RaidAuthority
var inventory: RaidInventoryOwner
var settlement: RaidSettlementService
var deployment: Dictionary = {}
var last_error: StringName = &""
var _attempted: bool = false

func begin(parent: Node, store: ProfileStore, request_id: String, profile_generation: int, seed: int) -> bool:
	if _attempted or parent == null or store == null or not store.is_configured(): return _fail(&"deployment_configuration_invalid")
	_attempted = true
	var native := NativeSettlementInventory.new()
	if not native.configure(): return _fail(&"deployment_catalog_unavailable")
	settlement = RaidSettlementService.new()
	if not settlement.configure(store,native): return _fail(&"deployment_store_unavailable")
	var committed := settlement.deploy(request_id,profile_generation)
	if committed.get("ok") != true: return _fail(StringName(committed.get("reason",&"deployment_commit_failed")))
	if committed.get("can_instantiate") != true: return _fail(&"deployment_replayed_resume_disabled")
	deployment = RaidProgressionValues.freeze(committed.deployment)
	inventory = native.instantiate_owner(parent,committed.domains)
	if inventory == null: return _fail(&"deployment_inventory_load_failed_recovery_required")
	var id := ZRaidId.parse(String(deployment.raid_id))
	var sessions := SessionCoordinator.new()
	var admission := sessions.open_offline(id,StringName(store.profile_id()),&"player")
	raid = RaidAuthority.new()
	if not raid.configure(id,admission,seed): return _fail(&"deployment_authority_failed_recovery_required")
	return true

func _fail(reason: StringName) -> bool:
	last_error = reason
	return false
