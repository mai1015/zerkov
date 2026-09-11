class_name CharacterPresentationComposition
extends Node
## Injection-only production composition for the Character workspace.
##
## The app/profile/raid root retains ownership of inventory authority objects
## and supplies the already-matched owner, projection bridge, intent adapter,
## admission, and immutable health projection. This composition owns only the
## presentation runtime. Starting without dependencies is a valid fail-closed
## state and never manufactures a parallel gameplay authority or session.

const REASON_AUTHORITY_NOT_INJECTED: StringName = \
		&"character_authority_not_injected"

var last_error: StringName = &""

var _runtime: CharacterUIRuntime
var _started: bool = false


func start(
	owner: RaidInventoryOwner = null,
	bridge: InventoryProjectionBridge = null,
	adapter: InventoryIntentAdapter = null,
	admission: ZSessionAdmission = null,
	health_snapshot: HealthView = null
) -> bool:
	last_error = &""
	if _started:
		return _reject(&"character_composition_already_started")
	_ensure_runtime()
	_started = true
	if owner == null and bridge == null and adapter == null \
			and admission == null and health_snapshot == null:
		_runtime.initialize_unavailable(REASON_AUTHORITY_NOT_INJECTED)
		last_error = REASON_AUTHORITY_NOT_INJECTED
		return true
	return _bind_injected(owner, bridge, adapter, admission, health_snapshot)


## Rebinds the same presentation runtime so a retained CommonUI screen observes
## one atomic unavailable-or-rebound transition. Dependency ownership stays at
## the game root; this method never releases or tears down injected authorities.
func rebind(
	owner: RaidInventoryOwner,
	bridge: InventoryProjectionBridge,
	adapter: InventoryIntentAdapter,
	admission: ZSessionAdmission,
	health_snapshot: HealthView
) -> bool:
	last_error = &""
	if not _started or _runtime == null:
		return _reject(&"character_composition_not_started")
	return _bind_injected(owner, bridge, adapter, admission, health_snapshot)


func is_started() -> bool:
	return _started


## Narrow presentation-only handoff used by the app's typed route context.
## Canonical owner/bridge/adapter/admission references are never exposed.
func character_runtime() -> CharacterUIRuntime:
	return _runtime


func teardown() -> void:
	if not _started:
		return
	last_error = &"character_composition_teardown"
	if _runtime != null:
		_runtime.release(last_error, true)
	_started = false


func _exit_tree() -> void:
	teardown()


func _ensure_runtime() -> void:
	if _runtime != null and is_instance_valid(_runtime):
		return
	_runtime = CharacterUIRuntime.new()
	_runtime.name = "CharacterUIRuntime"
	add_child(_runtime)


func _bind_injected(
	owner: RaidInventoryOwner,
	bridge: InventoryProjectionBridge,
	adapter: InventoryIntentAdapter,
	admission: ZSessionAdmission,
	health_snapshot: HealthView
) -> bool:
	if _runtime.configure(owner, bridge, adapter, admission, health_snapshot):
		return true
	last_error = _runtime.last_error \
			if not _runtime.last_error.is_empty() \
			else &"character_composition_bind_failed"
	return false


func _reject(reason: StringName) -> bool:
	last_error = reason
	return false
