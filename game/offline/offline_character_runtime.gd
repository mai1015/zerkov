class_name OfflineCharacterRuntime
extends CharacterUIRuntime
## Supplies the retained Character workspace without constructing a raid owner.
var _local := OfflineInventoryController.new()
var _session: OfflineBunkerSession

func attach(session: OfflineBunkerSession) -> void:
	_session = session
	_local.attach(session)
	binding_rebound.emit(session.generation())

func is_configured() -> bool:
	return _local.is_bound()

func inventory_controller() -> InventoryPresentationController:
	return _local

func inventory_view(scope: StringName) -> InventoryView:
	return _local.inventory_view(scope)

func items_for(source: StringName) -> Array[Dictionary]:
	return _local.items_for(source)

func health_view() -> HealthView:
	return HealthView.unavailable(ZReadOnlyView.SyncState.UNBOUND, &"health_not_active_in_bunker")

func release(reason: StringName = &"offline_profile_closed", emit_signal: bool = true) -> void:
	_local.unbind()
	_session = null
	if emit_signal:
		binding_invalidated.emit(reason)
