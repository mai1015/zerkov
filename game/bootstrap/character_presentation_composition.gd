class_name CharacterPresentationComposition
extends Node
## Production composition for the Character inventory/health workspace.
##
## The inventory owner, bridge, adapter and controller are real game-owned
## runtime objects. No loot or item fixture is materialized here. Until the
## health authority publishes a HealthView, the health surface receives an
## explicit typed unavailable snapshot instead of authored values.

const MAX_TRANSFER_DISTANCE_RAW: int = 2_000_000
const NATIVE_LOCAL_PLAYER_ID: int = 1

var last_error: StringName = &""
var runtime: CharacterUIRuntime

var _owner: RaidInventoryOwner
var _bridge: InventoryProjectionBridge
var _adapter: InventoryIntentAdapter
var _identity: OfflineInventoryIdentity
var _world_policy: ZInventoryWorldPolicyPort
var _admission: ZSessionAdmission
var _started: bool = false


func start() -> bool:
	last_error = &""
	if _started:
		return _reject(&"character_composition_already_started")
	runtime = CharacterUIRuntime.new()
	runtime.name = "CharacterUIRuntime"
	add_child(runtime)

	_owner = RaidInventoryOwner.new()
	_owner.name = "RaidInventoryOwner"
	add_child(_owner)
	if not _owner.configure():
		return _fail_start(_owner.last_error)

	var raid_id := ZRaidId.from_parts(PackedStringArray([
		"offline", "character", "workspace",
	]))
	_admission = SessionCoordinator.new().open_offline(
		raid_id, &"local_profile", &"player")
	if _admission == null or not _admission.is_usable():
		return _fail_start(&"character_session_admission_failed")

	_identity = OfflineInventoryIdentity.new()
	if not _identity.configure(_admission, _owner, NATIVE_LOCAL_PLAYER_ID):
		return _fail_start(&"character_inventory_identity_failed")
	# World interaction facts are deliberately deny-by-default until the actual
	# raid world policy is injected. Empty real world inventories remain visible
	# as unavailable rather than being populated with prototype loot.
	_world_policy = ZInventoryWorldPolicyPort.new()
	_adapter = InventoryIntentAdapter.new()
	if not _adapter.configure(
		_owner, _admission, _identity, _world_policy,
		MAX_TRANSFER_DISTANCE_RAW):
		return _fail_start(_adapter.last_error)

	_bridge = InventoryProjectionBridge.new()
	_bridge.name = "InventoryProjectionBridge"
	add_child(_bridge)
	if not _bridge.bind_owner(_owner, _owner.generation()):
		return _fail_start(_bridge.last_error)

	var health_unavailable := HealthView.unavailable(
		ZReadOnlyView.SyncState.UNBOUND,
		&"health_authority_not_connected",
		_admission.generation, 0, 0, _admission.actor_id)
	if health_unavailable == null or not runtime.configure(
		_owner, _bridge, _adapter, _admission, health_unavailable):
		return _fail_start(runtime.last_error)
	_started = true
	return true


func is_started() -> bool:
	return _started


func owner() -> RaidInventoryOwner:
	return _owner


func bridge() -> InventoryProjectionBridge:
	return _bridge


func adapter() -> InventoryIntentAdapter:
	return _adapter


func admission() -> ZSessionAdmission:
	return _admission.snapshot() if _admission != null else null


func teardown() -> void:
	if runtime != null:
		runtime.release(&"character_composition_teardown", false)
	if _adapter != null and _adapter.is_bound():
		_adapter.release_binding(&"character_composition_teardown")
	if _bridge != null and _bridge.is_bound():
		_bridge.release_binding()
	if _identity != null:
		_identity.release()
	if _owner != null and is_instance_valid(_owner) \
			and _owner.lifecycle == RaidInventoryOwner.Lifecycle.ACTIVE:
		_owner.teardown(_owner.generation())
	_started = false


func _exit_tree() -> void:
	teardown()


func _fail_start(reason: StringName) -> bool:
	last_error = reason if not reason.is_empty() else &"character_composition_start_failed"
	if runtime != null:
		runtime.initialize_unavailable(last_error)
	if _adapter != null and _adapter.is_bound():
		_adapter.release_binding(last_error)
	if _bridge != null and _bridge.is_bound():
		_bridge.release_binding()
	if _identity != null:
		_identity.release()
	if _owner != null and is_instance_valid(_owner) \
			and _owner.lifecycle == RaidInventoryOwner.Lifecycle.ACTIVE:
		_owner.teardown(_owner.generation())
	return false


func _reject(reason: StringName) -> bool:
	last_error = reason
	return false
