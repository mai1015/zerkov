class_name InventoryProjectionBridge
extends Node
## Binds scene-owned InventoryAuthority snapshots to presentation-only models.
##
## Profile and raid authorities use independent native inventory-id allocators,
## so each authority owns a separate InventoryPresentationModel scope.  Every
## ingress method verifies the owner generation, the scope generation, and the
## exact authority instance before accepting an immutable native snapshot or
## result.  Pending intent remains inside InventoryPresentationModel's intent
## layer and is never copied into the confirmed snapshot registry.

signal model_replaced(scope: StringName, model: InventoryPresentationModel, scope_generation: int)
signal projection_status_changed(scope: StringName, status: int)
signal snapshot_projected(scope: StringName, inventory_id: int, revision: int)
signal snapshot_ignored(scope: StringName, inventory_id: int, revision: int, reason: StringName)
signal binding_invalidated(reason: StringName)

enum ProjectionStatus {
	UNBOUND,
	LOADING,
	READY,
	RESYNCHRONIZING,
	STALE,
	DISCONNECTED,
}

const SCOPE_PROFILE: StringName = &"profile"
const SCOPE_RAID: StringName = &"raid"
const _SCOPES: Array[StringName] = [SCOPE_PROFILE, SCOPE_RAID]
const MAX_REMEMBERED_RESULTS_PER_SCOPE: int = 2048

var last_error: StringName = &""

var _owner: RaidInventoryOwner
var _owner_instance_id: int = 0
var _owner_generation: int = 0
var _generation_serial: int = 0
var _scope_authorities: Dictionary = {}
var _scope_inventory_ids: Dictionary = {}
var _scope_models: Dictionary = {}
var _scope_statuses: Dictionary = {}
var _scope_generations: Dictionary = {}
var _scope_snapshots: Dictionary = {}
var _scope_revisions: Dictionary = {}
var _scope_retired_inventory_ids: Dictionary = {}
var _scope_processed_result_ids: Dictionary = {}
var _scope_processed_result_order: Dictionary = {}
var _authority_connections: Array[Dictionary] = []
var _owner_tree_exiting_connection: Callable


func _init() -> void:
	for scope in _SCOPES:
		_scope_models[scope] = InventoryPresentationModel.new()
		_scope_statuses[scope] = ProjectionStatus.UNBOUND
		_scope_generations[scope] = 0
		_scope_snapshots[scope] = {}
		_scope_revisions[scope] = {}
		_scope_retired_inventory_ids[scope] = {}
		_scope_processed_result_ids[scope] = {}
		_scope_processed_result_order[scope] = []


## Establishes one explicit owner-generation binding and installs initial
## immutable snapshots synchronously.  The returned model is noncanonical
## presentation state: consumers may mutate its reversible view/intent layers,
## while only this bridge's confirmed_snapshot() registry is the immutable
## projection boundary. A trusted refresh repairs accidental model-only
## snapshot replacement without ever writing back to authority.
func bind_owner(owner: RaidInventoryOwner, expected_owner_generation: int) -> bool:
	last_error = &""
	if owner == null or not is_instance_valid(owner):
		return _reject(&"owner_missing")
	if not owner.is_current_generation(expected_owner_generation):
		return _reject(&"stale_owner_generation")
	if owner.profile_authority() == null or owner.raid_authority() == null:
		return _reject(&"authority_missing")

	_disconnect_bound_signals()
	# A caller may deliberately replace one live owner with another. Mark every
	# previously handed-out model disconnected before publishing fresh models so
	# retained UI references cannot keep rendering the former authority.
	_invalidate_models(ProjectionStatus.UNBOUND, true)
	_owner = owner
	_owner_instance_id = owner.get_instance_id()
	_owner_generation = expected_owner_generation
	_scope_authorities = {
		SCOPE_PROFILE: owner.profile_authority(),
		SCOPE_RAID: owner.raid_authority(),
	}
	_scope_inventory_ids = {
		SCOPE_PROFILE: [owner.profile_inventory_id],
		SCOPE_RAID: [
			owner.raid_player_inventory_id,
			owner.world_crate_inventory_id,
			owner.corpse_inventory_id,
		],
	}

	for scope in _SCOPES:
		_generation_serial += 1
		_scope_generations[scope] = _generation_serial
		_scope_snapshots[scope] = {}
		_scope_revisions[scope] = {}
		_scope_retired_inventory_ids[scope] = {}
		_scope_processed_result_ids[scope] = {}
		_scope_processed_result_order[scope] = []
		_replace_model(scope, ProjectionStatus.LOADING)
		_connect_authority(scope, _scope_authorities[scope] as InventoryAuthority)

	_owner_tree_exiting_connection = Callable(self, "_on_owner_tree_exiting")
	_owner.tree_exiting.connect(_owner_tree_exiting_connection)

	for scope in _SCOPES:
		if not _refresh_scope_internal(scope):
			_invalidate_binding(&"initial_snapshot_failed")
			return _reject(&"initial_snapshot_failed")
	return true


func is_bound() -> bool:
	return _binding_is_current(false)


func validate_binding() -> bool:
	last_error = &""
	if _binding_is_current(false):
		return true
	if _owner != null:
		_invalidate_binding(&"owner_generation_invalidated")
	return _reject(&"owner_generation_invalidated")


func owner_generation() -> int:
	return _owner_generation


func scope_generation(scope: StringName) -> int:
	return int(_scope_generations.get(scope, 0))


func scope_status(scope: StringName) -> ProjectionStatus:
	return int(_scope_statuses.get(scope, ProjectionStatus.UNBOUND)) as ProjectionStatus


func presentation_model(scope: StringName) -> InventoryPresentationModel:
	return _scope_models.get(scope, null) as InventoryPresentationModel


func authority_for_scope(scope: StringName) -> InventoryAuthority:
	if not _binding_is_current(false):
		return null
	return _scope_authorities.get(scope, null) as InventoryAuthority


func inventory_ids(scope: StringName) -> Array[int]:
	var result: Array[int] = []
	for inventory_id in (_scope_inventory_ids.get(scope, []) as Array):
		result.append(int(inventory_id))
	return result


func confirmed_revision(scope: StringName, inventory_id: int) -> int:
	return int((_scope_revisions.get(scope, {}) as Dictionary).get(inventory_id, -1))


func confirmed_snapshot(scope: StringName, inventory_id: int) -> InventorySnapshotResource:
	if not _binding_is_current(false):
		return null
	return (_scope_snapshots.get(scope, {}) as Dictionary).get(
		inventory_id, null) as InventorySnapshotResource


## Captures presentation intent only.  The returned id must be used as the
## native command id by the separately owned intent adapter.  No authority
## method is called here and the confirmed snapshot remains untouched.
func begin_pending_intent(
	scope: StringName,
	kind: StringName,
	args: Dictionary,
	expected_owner_generation: int,
	expected_scope_generation: int
) -> int:
	last_error = &""
	if not _tokens_are_current(scope, expected_owner_generation, expected_scope_generation):
		return _reject_int(&"stale_projection_binding")
	var inventory_id := int(args.get("inventory_id", 0))
	if not inventory_ids(scope).has(inventory_id):
		return _reject_int(&"inventory_outside_scope")
	var model := presentation_model(scope)
	if model == null or not model.has_snapshot(inventory_id):
		return _reject_int(&"projection_not_ready")
	return model.begin_intent(kind, args.duplicate(true))


func cancel_pending_intent(
	scope: StringName,
	pending_id: int,
	expected_owner_generation: int,
	expected_scope_generation: int
) -> bool:
	last_error = &""
	if not _tokens_are_current(scope, expected_owner_generation, expected_scope_generation):
		return _reject(&"stale_projection_binding")
	var model := presentation_model(scope)
	if model == null or model.get_pending(pending_id).is_empty():
		return _reject(&"pending_intent_unknown")
	model.cancel_intent(pending_id)
	return true


## Public snapshot ingress for the local bound authority. The exact authority,
## its current bytes, and both generations are part of the binding; stale,
## duplicate, foreign, or out-of-order snapshots are ignored monotonically.
func apply_authoritative_snapshot(
	scope: StringName,
	authority: InventoryAuthority,
	snapshot: InventorySnapshotResource,
	expected_owner_generation: int,
	expected_scope_generation: int
) -> bool:
	last_error = &""
	if not _tokens_are_current(scope, expected_owner_generation, expected_scope_generation):
		return _ignore_snapshot(scope, snapshot, &"stale_projection_binding")
	if authority == null or authority != authority_for_scope(scope):
		return _ignore_snapshot(scope, snapshot, &"authority_mismatch")
	if snapshot != null:
		var inventory_id := snapshot.get_inventory_id()
		var current_revision := confirmed_revision(scope, inventory_id)
		# The authority argument and Resource have no provenance link in Godot's
		# type system.  For a forward-moving public ingress, require the bytes to
		# equal a fresh snapshot pulled from the exact bound authority.  Older and
		# equal inputs still go through the monotonic checks below so callers receive
		# the more useful stale/divergence diagnostic.
		if snapshot.get_revision() > current_revision \
				and not _snapshot_matches_bound_authority(scope, snapshot):
			_mark_scope_resynchronizing(scope)
			return _ignore_snapshot(scope, snapshot, &"snapshot_authority_mismatch")
	return _accept_snapshot(scope, snapshot, false)


func refresh_inventory(
	scope: StringName,
	inventory_id: int,
	expected_owner_generation: int,
	expected_scope_generation: int
) -> bool:
	last_error = &""
	if not _tokens_are_current(scope, expected_owner_generation, expected_scope_generation):
		return _reject(&"stale_projection_binding")
	if not inventory_ids(scope).has(inventory_id):
		return _reject(&"inventory_outside_scope")
	return _refresh_inventory_internal(scope, inventory_id)


func begin_resynchronization(
	scope: StringName,
	expected_owner_generation: int,
	expected_scope_generation: int
) -> bool:
	last_error = &""
	if not _tokens_are_current(scope, expected_owner_generation, expected_scope_generation):
		return _reject(&"stale_projection_binding")
	var model := presentation_model(scope)
	if model != null:
		model.set_resynchronizing(true)
	_set_scope_status(scope, ProjectionStatus.RESYNCHRONIZING)
	return true


func complete_resynchronization(
	scope: StringName,
	expected_owner_generation: int,
	expected_scope_generation: int
) -> bool:
	last_error = &""
	if not _tokens_are_current(scope, expected_owner_generation, expected_scope_generation):
		return _reject(&"stale_projection_binding")
	return _refresh_scope_internal(scope)


func tick(ticks: int = 1) -> void:
	for scope in _SCOPES:
		var model := presentation_model(scope)
		if model != null:
			model.tick(ticks)


func release_binding() -> void:
	if _owner == null:
		return
	_invalidate_binding(&"bridge_released")


func _exit_tree() -> void:
	release_binding()


func _connect_authority(scope: StringName, authority: InventoryAuthority) -> void:
	var authority_id := authority.get_instance_id()
	var transaction_callback := Callable(self, "_on_transaction_committed").bind(scope, authority_id)
	var unloaded_callback := Callable(self, "_on_inventory_unloaded").bind(scope, authority_id)
	var generation_callback := Callable(self, "_on_inventory_generation_changing").bind(
		scope, authority_id)
	authority.transaction_committed.connect(transaction_callback)
	authority.inventory_unloaded.connect(unloaded_callback)
	authority.inventory_generation_changing.connect(generation_callback)
	_authority_connections.append({
		"authority": authority,
		"transaction": transaction_callback,
		"unloaded": unloaded_callback,
		"generation": generation_callback,
	})


func _disconnect_bound_signals() -> void:
	for entry_value in _authority_connections:
		var entry := entry_value as Dictionary
		var authority := entry.get("authority", null) as InventoryAuthority
		if authority == null or not is_instance_valid(authority):
			continue
		var transaction_callback := entry.get("transaction", Callable()) as Callable
		var unloaded_callback := entry.get("unloaded", Callable()) as Callable
		var generation_callback := entry.get("generation", Callable()) as Callable
		if transaction_callback.is_valid() and authority.transaction_committed.is_connected(
			transaction_callback):
			authority.transaction_committed.disconnect(transaction_callback)
		if unloaded_callback.is_valid() and authority.inventory_unloaded.is_connected(unloaded_callback):
			authority.inventory_unloaded.disconnect(unloaded_callback)
		if generation_callback.is_valid() and authority.inventory_generation_changing.is_connected(
			generation_callback):
			authority.inventory_generation_changing.disconnect(generation_callback)
	_authority_connections.clear()
	if _owner != null and is_instance_valid(_owner) and _owner_tree_exiting_connection.is_valid() \
			and _owner.tree_exiting.is_connected(_owner_tree_exiting_connection):
		_owner.tree_exiting.disconnect(_owner_tree_exiting_connection)
	_owner_tree_exiting_connection = Callable()


func _on_transaction_committed(result: Dictionary, scope: StringName, authority_id: int) -> void:
	if not _callback_is_current(scope, authority_id):
		return
	# A queued receipt is admission bookkeeping, not an authoritative outcome.
	# Current native authorities emit only the later final result on this signal,
	# but keep this guard so a future façade cannot resolve pending intent early.
	if bool(result.get("queued", false)):
		return
	var command_id := int(result.get("command_id", 0))
	if command_id > 0 and _result_was_processed(scope, command_id):
		return
	var model := presentation_model(scope)
	if model == null:
		return
	var pending := model.get_pending(command_id)

	var touched: Array[int] = []
	for revision_value in (result.get("revisions", []) as Array):
		var revision := revision_value as Dictionary
		var inventory_id := int(revision.get("inventory", 0))
		if _inventory_is_live_in_scope(scope, inventory_id) and not touched.has(inventory_id):
			touched.append(inventory_id)
	var pending_inventory_id := int(pending.get("inventory_id", 0))
	if _inventory_is_live_in_scope(scope, pending_inventory_id) \
			and not touched.has(pending_inventory_id):
		touched.append(pending_inventory_id)
	var conflicting_inventory := int(result.get("conflicting_inventory", 0))
	if _inventory_is_live_in_scope(scope, conflicting_inventory) \
			and not touched.has(conflicting_inventory):
		touched.append(conflicting_inventory)
	touched.sort()
	if not touched.is_empty() and not _refresh_inventories_internal(scope, touched):
		_mark_scope_resynchronizing(scope)
		return

	# Result feedback is applied only after every affected canonical snapshot is
	# installed.  A model_changed/accepted_feedback listener can therefore never
	# observe a half-refreshed cross-inventory transaction.
	model.apply_result(result.duplicate(true))
	if command_id > 0:
		_remember_processed_result(scope, command_id)


func _on_inventory_generation_changing(
	inventory_id: int,
	scope: StringName,
	authority_id: int
) -> void:
	if not _callback_is_current(scope, authority_id) or not inventory_ids(scope).has(inventory_id):
		return
	(_scope_retired_inventory_ids.get(scope, {}) as Dictionary).erase(inventory_id)
	_invalidate_scope_inventory(scope, inventory_id, ProjectionStatus.RESYNCHRONIZING)
	var captured_owner_generation := _owner_generation
	var captured_scope_generation := scope_generation(scope)
	call_deferred("_complete_replacement_resync", scope, inventory_id,
		captured_owner_generation, captured_scope_generation)


func _complete_replacement_resync(
	scope: StringName,
	inventory_id: int,
	expected_owner_generation: int,
	expected_scope_generation: int
) -> void:
	if not _tokens_are_current(scope, expected_owner_generation, expected_scope_generation):
		return
	if not _refresh_inventory_internal(scope, inventory_id):
		_mark_scope_resynchronizing(scope)


func _on_inventory_unloaded(inventory_id: int, scope: StringName, authority_id: int) -> void:
	if not _callback_is_current(scope, authority_id) or not inventory_ids(scope).has(inventory_id):
		return
	(_scope_retired_inventory_ids.get(scope, {}) as Dictionary)[inventory_id] = true
	_invalidate_scope_inventory(scope, inventory_id, ProjectionStatus.STALE)
	call_deferred("_validate_owner_after_lifecycle_event")


func _validate_owner_after_lifecycle_event() -> void:
	if not _binding_is_current(false):
		_invalidate_binding(&"owner_generation_invalidated")


func _on_owner_tree_exiting() -> void:
	_invalidate_binding(&"owner_tree_exiting")


func _refresh_scope_internal(scope: StringName) -> bool:
	if not _binding_is_current(false):
		return false
	var ok := _refresh_inventories_internal(scope, inventory_ids(scope))
	if ok:
		var model := presentation_model(scope)
		if model != null:
			model.set_resynchronizing(false)
		_set_scope_status(scope, ProjectionStatus.READY)
	else:
		_mark_scope_resynchronizing(scope)
	return ok


func _refresh_inventory_internal(scope: StringName, inventory_id: int) -> bool:
	return _refresh_inventories_internal(scope, [inventory_id])


## Pulls every requested snapshot before publishing any of them, then installs
## the complete set while the model's signals are blocked.  This keeps a
## cross-inventory transaction coherent to every presentation listener and
## prevents a failed later pull from leaving an earlier inventory half-updated.
func _refresh_inventories_internal(scope: StringName, requested_ids: Array) -> bool:
	var authority := _scope_authorities.get(scope, null) as InventoryAuthority
	if authority == null or not is_instance_valid(authority):
		return false
	var snapshots: Array = []
	var seen: Dictionary = {}
	for inventory_value in requested_ids:
		var inventory_id := int(inventory_value)
		if seen.has(inventory_id):
			continue
		seen[inventory_id] = true
		if (_scope_retired_inventory_ids.get(scope, {}) as Dictionary).has(inventory_id) \
				or not authority.has_inventory(inventory_id):
			return false
		var snapshot := authority.snapshot(inventory_id)
		if snapshot == null:
			return false
		snapshots.append(snapshot)
	return _accept_snapshot_batch(scope, snapshots, true)


func _accept_snapshot(
	scope: StringName,
	snapshot: InventorySnapshotResource,
	allow_equal_revision: bool
) -> bool:
	return _accept_snapshot_batch(scope, [snapshot], allow_equal_revision)


func _accept_snapshot_batch(
	scope: StringName,
	snapshots: Array,
	allow_equal_revision: bool
) -> bool:
	var model := presentation_model(scope)
	if model == null:
		return _ignore_snapshot(scope, null, &"model_missing")
	var current_snapshots := _scope_snapshots.get(scope, {}) as Dictionary
	var revisions := _scope_revisions.get(scope, {}) as Dictionary
	var staged: Dictionary = {}
	var repair_ids: Array[int] = []
	for snapshot_value in snapshots:
		var snapshot := snapshot_value as InventorySnapshotResource
		if snapshot == null:
			return _ignore_snapshot(scope, snapshot, &"snapshot_missing")
		var inventory_id := snapshot.get_inventory_id()
		if staged.has(inventory_id):
			return _ignore_snapshot(scope, snapshot, &"duplicate_inventory_in_batch")
		if not inventory_ids(scope).has(inventory_id):
			return _ignore_snapshot(scope, snapshot, &"inventory_outside_scope")
		if (_scope_retired_inventory_ids.get(scope, {}) as Dictionary).has(inventory_id):
			return _ignore_snapshot(scope, snapshot, &"inventory_unloaded")
		var revision := snapshot.get_revision()
		var current_revision := int(revisions.get(inventory_id, -1))
		if revision < current_revision:
			return _ignore_snapshot(scope, snapshot, &"stale_or_duplicate_revision")
		if revision == current_revision:
			var current_snapshot := current_snapshots.get(
				inventory_id, null) as InventorySnapshotResource
			if current_snapshot == null \
					or not _snapshots_presentation_equal(current_snapshot, snapshot):
				_mark_scope_resynchronizing(scope)
				return _ignore_snapshot(scope, snapshot, &"equal_revision_divergence")
			if not allow_equal_revision:
				return _ignore_snapshot(scope, snapshot, &"stale_or_duplicate_revision")
			var model_snapshot := model.get_snapshot(inventory_id)
			if model_snapshot == null \
					or not _snapshots_presentation_equal(current_snapshot, model_snapshot):
				repair_ids.append(inventory_id)
			continue
		staged[inventory_id] = snapshot

	# InventorySnapshotResource is an immutable, native-owned value copy.  Block
	# native model signals until all requested inventories and bridge registries
	# agree, then publish one coherent change edge.
	var pending_before := _pending_ids_for_inventories(model, inventory_ids(scope))
	var was_resynchronizing := model.is_resynchronizing()
	var was_blocking := model.is_blocking_signals()
	if not was_blocking:
		model.set_block_signals(true)
	for inventory_id in _sorted_int_keys(staged):
		var staged_snapshot := staged[inventory_id] as InventorySnapshotResource
		model.apply_snapshot(staged_snapshot)
		current_snapshots[inventory_id] = staged_snapshot
		revisions[inventory_id] = staged_snapshot.get_revision()
	for inventory_id in repair_ids:
		model.apply_snapshot(current_snapshots[inventory_id] as InventorySnapshotResource)
	_scope_snapshots[scope] = current_snapshots
	_scope_revisions[scope] = revisions
	var is_complete := _scope_has_all_snapshots(scope)
	if is_complete:
		model.set_resynchronizing(false)
	if not was_blocking:
		model.set_block_signals(false)
	var model_changed := not staged.is_empty() or not repair_ids.is_empty() \
		or was_resynchronizing != model.is_resynchronizing()
	var pending_after := _pending_ids_for_inventories(model, inventory_ids(scope))
	if not was_blocking and pending_before != pending_after:
		model.pending_changed.emit()
	if not was_blocking and model_changed:
		model.model_changed.emit()
	for inventory_id in _sorted_int_keys(staged):
		snapshot_projected.emit(scope, inventory_id,
			(staged[inventory_id] as InventorySnapshotResource).get_revision())
	if is_complete:
		_set_scope_status(scope, ProjectionStatus.READY)
	return true


func _invalidate_scope_inventory(
	scope: StringName,
	inventory_id: int,
	status: ProjectionStatus
) -> void:
	var old_model := presentation_model(scope)
	if old_model != null:
		_cancel_all_pending(old_model, inventory_ids(scope))
		old_model.set_resynchronizing(true)
	(_scope_snapshots.get(scope, {}) as Dictionary).erase(inventory_id)
	(_scope_revisions.get(scope, {}) as Dictionary).erase(inventory_id)
	_generation_serial += 1
	_scope_generations[scope] = _generation_serial
	# Build the retained multi-inventory projection before handing the new model
	# to listeners. A model_replaced callback must never observe only a prefix of
	# the inventories that survived this lifecycle edge.
	_scope_models[scope] = InventoryPresentationModel.new()
	_set_scope_status(scope, status)
	var replacement := presentation_model(scope)
	replacement.set_block_signals(true)
	for retained_inventory_id in _sorted_int_keys(_scope_snapshots.get(scope, {}) as Dictionary):
		replacement.apply_snapshot(
			(_scope_snapshots[scope] as Dictionary)[retained_inventory_id] as InventorySnapshotResource)
	if status == ProjectionStatus.RESYNCHRONIZING or status == ProjectionStatus.STALE:
		replacement.set_resynchronizing(true)
	replacement.set_block_signals(false)
	model_replaced.emit(scope, replacement, scope_generation(scope))
	replacement.model_changed.emit()


func _replace_model(scope: StringName, status: ProjectionStatus) -> void:
	_scope_models[scope] = InventoryPresentationModel.new()
	_set_scope_status(scope, status)
	model_replaced.emit(scope, presentation_model(scope), scope_generation(scope))


func _mark_scope_resynchronizing(scope: StringName) -> void:
	var model := presentation_model(scope)
	if model != null:
		model.set_resynchronizing(true)
	_set_scope_status(scope, ProjectionStatus.RESYNCHRONIZING)


func _invalidate_binding(reason: StringName) -> void:
	_disconnect_bound_signals()
	_invalidate_models(ProjectionStatus.DISCONNECTED, true)
	_owner = null
	_owner_instance_id = 0
	_owner_generation = 0
	_scope_authorities.clear()
	_scope_inventory_ids.clear()
	for scope in _SCOPES:
		_scope_retired_inventory_ids[scope] = {}
	binding_invalidated.emit(reason)


func _invalidate_models(status: ProjectionStatus, disconnected: bool) -> void:
	for scope in _SCOPES:
		var model := presentation_model(scope)
		if model != null:
			_cancel_all_pending(model, inventory_ids(scope))
			model.set_disconnected(disconnected)
		_scope_snapshots[scope] = {}
		_scope_revisions[scope] = {}
		_generation_serial += 1
		_scope_generations[scope] = _generation_serial
		_set_scope_status(scope, status)


func _cancel_all_pending(model: InventoryPresentationModel, ids: Array[int]) -> void:
	for inventory_id in ids:
		for pending_id in model.pending_ids_for_inventory(inventory_id):
			model.cancel_intent(pending_id)


func _tokens_are_current(
	scope: StringName,
	expected_owner_generation: int,
	expected_scope_generation: int
) -> bool:
	return _SCOPES.has(scope) \
		and _binding_is_current(true) \
		and expected_owner_generation == _owner_generation \
		and expected_scope_generation == scope_generation(scope)


func _binding_is_current(invalidate_if_stale: bool) -> bool:
	var current := _owner != null and is_instance_valid(_owner) \
		and _owner.get_instance_id() == _owner_instance_id \
		and _owner.is_current_generation(_owner_generation)
	if not current and invalidate_if_stale and _owner != null:
		_invalidate_binding(&"owner_generation_invalidated")
	return current


func _callback_is_current(scope: StringName, authority_id: int) -> bool:
	if not _SCOPES.has(scope) or not _binding_is_current(false):
		return false
	var authority := _scope_authorities.get(scope, null) as InventoryAuthority
	return authority != null and is_instance_valid(authority) \
		and authority.get_instance_id() == authority_id


func _scope_has_all_snapshots(scope: StringName) -> bool:
	var snapshots := _scope_snapshots.get(scope, {}) as Dictionary
	for inventory_id in inventory_ids(scope):
		if not snapshots.has(inventory_id):
			return false
	return not inventory_ids(scope).is_empty()


func _set_scope_status(scope: StringName, status: ProjectionStatus) -> void:
	if int(_scope_statuses.get(scope, ProjectionStatus.UNBOUND)) == int(status):
		return
	_scope_statuses[scope] = status
	projection_status_changed.emit(scope, status)


func _ignore_snapshot(
	scope: StringName,
	snapshot: InventorySnapshotResource,
	reason: StringName
) -> bool:
	last_error = reason
	var inventory_id := snapshot.get_inventory_id() if snapshot != null else 0
	var revision := snapshot.get_revision() if snapshot != null else -1
	snapshot_ignored.emit(scope, inventory_id, revision, reason)
	return false


func _sorted_int_keys(values: Dictionary) -> Array[int]:
	var result: Array[int] = []
	for key in values.keys():
		result.append(int(key))
	result.sort()
	return result


func _pending_ids_for_inventories(
	model: InventoryPresentationModel,
	ids: Array[int]
) -> Array[int]:
	var result: Array[int] = []
	for inventory_id in ids:
		for pending_id in model.pending_ids_for_inventory(inventory_id):
			if not result.has(pending_id):
				result.append(pending_id)
	result.sort()
	return result


func _inventory_is_live_in_scope(scope: StringName, inventory_id: int) -> bool:
	return inventory_ids(scope).has(inventory_id) \
		and not (_scope_retired_inventory_ids.get(scope, {}) as Dictionary).has(inventory_id)


## Snapshot canonical bytes include authority-shared allocator counters.  Those
## counters can advance when a sibling inventory changes without advancing this
## inventory's revision.  Equal-revision consistency at the presentation seam
## therefore compares every script-visible projection field while deliberately
## excluding hidden allocator state.
func _snapshots_presentation_equal(
	left: InventorySnapshotResource,
	right: InventorySnapshotResource
) -> bool:
	if left == null or right == null:
		return left == right
	return left.get_inventory_id() == right.get_inventory_id() \
		and left.get_profile_identifier() == right.get_profile_identifier() \
		and left.get_revision() == right.get_revision() \
		and left.get_manifest_fingerprint() == right.get_manifest_fingerprint() \
		and left.get_manifest_algorithm() == right.get_manifest_algorithm() \
		and left.get_visibility() == right.get_visibility() \
		and left.get_containers() == right.get_containers() \
		and left.get_items() == right.get_items() \
		and left.get_references() == right.get_references()


func _snapshots_exactly_equal(
	left: InventorySnapshotResource,
	right: InventorySnapshotResource
) -> bool:
	return _snapshots_presentation_equal(left, right) \
		and left.hash() == right.hash() \
		and left.canonical_bytes() == right.canonical_bytes()


func _snapshot_matches_bound_authority(
	scope: StringName,
	snapshot: InventorySnapshotResource
) -> bool:
	if snapshot == null or not _inventory_is_live_in_scope(scope, snapshot.get_inventory_id()):
		return false
	var authority := _scope_authorities.get(scope, null) as InventoryAuthority
	if authority == null or not is_instance_valid(authority) \
			or not authority.has_inventory(snapshot.get_inventory_id()):
		return false
	var live_snapshot := authority.snapshot(snapshot.get_inventory_id())
	return _snapshots_exactly_equal(snapshot, live_snapshot)


func _result_was_processed(scope: StringName, command_id: int) -> bool:
	return (_scope_processed_result_ids.get(scope, {}) as Dictionary).has(command_id)


func _remember_processed_result(scope: StringName, command_id: int) -> void:
	var ids := _scope_processed_result_ids.get(scope, {}) as Dictionary
	if ids.has(command_id):
		return
	var order := _scope_processed_result_order.get(scope, []) as Array
	ids[command_id] = true
	order.append(command_id)
	while order.size() > MAX_REMEMBERED_RESULTS_PER_SCOPE:
		ids.erase(int(order.pop_front()))
	_scope_processed_result_ids[scope] = ids
	_scope_processed_result_order[scope] = order


func _reject(reason: StringName) -> bool:
	last_error = reason
	return false


func _reject_int(reason: StringName) -> int:
	last_error = reason
	return 0
