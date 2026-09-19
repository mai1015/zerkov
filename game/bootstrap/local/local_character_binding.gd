class_name LocalCharacterBinding
extends Node
## Composes the accepted Character workspace against the current native owner.
var last_error: StringName = &""
var _bridge: InventoryProjectionBridge
var _adapter: InventoryIntentAdapter
var _identity: OfflineInventoryIdentity
var _policy: ZInventoryWorldPolicyPort
var _runtime: CharacterUIRuntime

func bind(runtime: CharacterUIRuntime, owner: RaidInventoryOwner, admission: ZSessionAdmission,
		health: HealthView, policy: ZInventoryWorldPolicyPort) -> bool:
	if _bridge != null or runtime == null or health == null or policy == null: return false
	_runtime = runtime
	_policy = policy
	_identity = OfflineInventoryIdentity.new()
	if not _identity.configure(admission, owner, 7_200_009): return _fail(&"local_character_identity_invalid")
	_bridge = InventoryProjectionBridge.new()
	add_child(_bridge)
	if not _bridge.bind_owner(owner, owner.generation()): return _fail(&"local_character_projection_failed")
	_adapter = WearableStorageIntentAdapter.new()
	if not _adapter.configure(owner, admission, _identity, policy, 3 * ZAIValues.UNIT): return _fail(_adapter.last_error)
	if not runtime.configure(owner, _bridge, _adapter, admission, health): return _fail(runtime.last_error)
	return true

func release() -> void:
	if _runtime != null: _runtime.release(&"local_character_owner_released")
	if _adapter != null and _adapter.is_bound(): _adapter.release_binding(&"local_character_owner_released")
	if _bridge != null: _bridge.release_binding()
	if _identity != null: _identity.release()
	if _policy is LocalInventoryWorldPolicy: (_policy as LocalInventoryWorldPolicy).release()
	_runtime = null
	_adapter = null
	_identity = null
	_policy = null

func _fail(reason: StringName) -> bool:
	last_error = reason
	return false
