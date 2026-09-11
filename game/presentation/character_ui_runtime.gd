class_name CharacterUIRuntime
extends Node
## Screen-family presentation owner for the existing Character workspace.
##
## Inventory snapshots and intents remain on the accepted owner/bridge/adapter/
## controller seam. Health is injected as an immutable HealthView because the
## health authority/projection owner is composed by later gameplay work. This
## object retains presentation-only interaction coordinates across CommonUI
## route replacement; it never becomes canonical gameplay storage.

signal inventory_view_changed(scope: StringName, view: InventoryView)
signal health_view_changed(view: HealthView)
signal binding_invalidated(reason: StringName)
signal binding_rebound(generation: int)

const SCOPE_PROFILE: StringName = &"profile"
const SCOPE_RAID: StringName = &"raid"

var last_error: StringName = &""

var _controller := InventoryPresentationController.new()
var _admission: ZSessionAdmission
var _profile_view: InventoryView
var _raid_view: InventoryView
var _health_view: HealthView
var _configured: bool = false
var _connections_active: bool = false
var _interaction_state: Dictionary = {}
# Presentation may deliberately replace `_health_view` with an unavailable
# snapshot. Keep the last accepted ready truth separately so that a failed
# rebind or teardown cannot reopen an older/divergent stream on recovery.
var _health_lineage_actor_key: String = ""
var _health_lineage_generation: int = 0
var _has_ready_health_watermark: bool = false
var _ready_health_revision: int = 0
var _ready_health_source_tick: int = 0
var _ready_health_content_digest: String = ""


func configure(
	owner: RaidInventoryOwner,
	bridge: InventoryProjectionBridge,
	adapter: InventoryIntentAdapter,
	admission: ZSessionAdmission,
	health_snapshot: HealthView
) -> bool:
	var previous_actor_key := _health_lineage_actor_key
	var previous_generation := _health_lineage_generation
	release(&"character_runtime_replaced", false)
	last_error = &""
	if owner == null or bridge == null or adapter == null \
			or admission == null or not admission.is_usable():
		return _fail_configure(&"character_runtime_dependency_missing")
	var admission_copy := admission.snapshot()
	if admission_copy == null:
		return _fail_configure(&"character_runtime_dependency_missing")
	var lineage_reason := _health_lineage_error(admission_copy)
	if not lineage_reason.is_empty():
		return _fail_configure(lineage_reason)
	var health_reason := _health_transition_error(health_snapshot, admission_copy)
	if not health_reason.is_empty():
		return _fail_configure(health_reason)
	if not previous_actor_key.is_empty() and (
			previous_actor_key != admission_copy.actor_id.canonical_key() \
			or previous_generation != admission_copy.generation):
		_sanitize_interaction_for_replacement()
	if not _controller.bind(owner, bridge, adapter, admission_copy):
		return _fail_configure(_controller.last_error)
	_admission = admission_copy
	_health_view = health_snapshot
	_commit_health_lineage(admission_copy, health_snapshot)
	_configured = true
	_connect_controller()
	_refresh_inventory_views()
	if _profile_view == null or _raid_view == null:
		return _fail_configure(&"inventory_view_projection_failed")
	# A retained Character screen can outlive an authority generation. Publish
	# the fully configured replacement only after every immutable view and the
	# intent controller point at the same admission generation.
	inventory_view_changed.emit(SCOPE_PROFILE, _profile_view)
	inventory_view_changed.emit(SCOPE_RAID, _raid_view)
	health_view_changed.emit(_health_view)
	binding_rebound.emit(_admission.generation)
	return true


func initialize_unavailable(reason: StringName) -> void:
	var diagnostic := reason if not reason.is_empty() \
			else &"character_runtime_unavailable"
	release(diagnostic, true)


func is_configured() -> bool:
	return _configured


func inventory_controller() -> InventoryPresentationController:
	return _controller


func inventory_view(scope: StringName) -> InventoryView:
	return _profile_view if scope == SCOPE_PROFILE else _raid_view


func health_view() -> HealthView:
	return _health_view


func items_for(source: StringName) -> Array[Dictionary]:
	var scope := _controller.scope_for_source(source)
	var view := inventory_view(scope)
	return _controller.items_for_view(source, view) if view != null else []


func publish_health_view(next_view: HealthView) -> bool:
	last_error = &""
	if not _configured or _admission == null:
		return _fail(&"character_runtime_unavailable")
	var transition_error := _health_transition_error(next_view, _admission)
	if not transition_error.is_empty():
		return _fail(transition_error)
	if next_view.is_ready() and _health_view != null and _health_view.is_ready() \
			and next_view.revision() == _health_view.revision() \
			and next_view.source_tick() == _health_view.source_tick() \
			and next_view.content_digest() == _health_view.content_digest():
		# Same-version, same-content delivery is an idempotent replay. Keep the
		# exact immutable instance already observed by screens and emit nothing.
		return true
	_health_view = next_view
	_commit_health_lineage(_admission, next_view)
	health_view_changed.emit(_health_view)
	return true


func save_interaction_state(value: Dictionary) -> void:
	_interaction_state = value.duplicate(true)


func interaction_state() -> Dictionary:
	return _interaction_state.duplicate(true)


func release(reason: StringName = &"character_runtime_released", emit_signal: bool = true) -> void:
	_disconnect_controller()
	if _controller != null:
		_controller.unbind()
	_configured = false
	var actor := _admission.actor_id if _admission != null \
		else (_health_view.actor_id() if _health_view != null else null)
	var generation := _admission.generation if _admission != null \
		else (_health_view.generation() if _health_view != null else 0)
	var profile_revision := _profile_view.revision() if _profile_view != null else 0
	var raid_revision := _raid_view.revision() if _raid_view != null else 0
	var health_revision := _health_view.revision() if _health_view != null else 0
	var health_tick := _health_view.source_tick() if _health_view != null else 0
	var diagnostic := reason if not reason.is_empty() else &"character_runtime_released"
	last_error = diagnostic
	var state := ZReadOnlyView.SyncState.DISCONNECTED if actor != null \
		else ZReadOnlyView.SyncState.UNBOUND
	_profile_view = InventoryView.unavailable(
		InventoryView.Scope.PROFILE, state, diagnostic,
		generation, profile_revision, 0, actor)
	_raid_view = InventoryView.unavailable(
		InventoryView.Scope.RAID, state, diagnostic,
		generation, raid_revision, 0, actor)
	_health_view = HealthView.unavailable(
		state, diagnostic, generation, health_revision, health_tick, actor)
	_admission = null
	if emit_signal:
		inventory_view_changed.emit(SCOPE_PROFILE, _profile_view)
		inventory_view_changed.emit(SCOPE_RAID, _raid_view)
		health_view_changed.emit(_health_view)
		binding_invalidated.emit(diagnostic)


func _exit_tree() -> void:
	release(&"character_runtime_tree_exiting", false)


func _refresh_inventory_views() -> void:
	_profile_view = _controller.inventory_view(SCOPE_PROFILE)
	_raid_view = _controller.inventory_view(SCOPE_RAID)


func _connect_controller() -> void:
	if _connections_active:
		return
	_controller.projection_changed.connect(_on_controller_projection_changed)
	_controller.status_changed.connect(_on_controller_status_changed)
	_controller.binding_invalidated.connect(_on_controller_binding_invalidated)
	_connections_active = true


func _disconnect_controller() -> void:
	if not _connections_active or _controller == null:
		return
	if _controller.projection_changed.is_connected(_on_controller_projection_changed):
		_controller.projection_changed.disconnect(_on_controller_projection_changed)
	if _controller.status_changed.is_connected(_on_controller_status_changed):
		_controller.status_changed.disconnect(_on_controller_status_changed)
	if _controller.binding_invalidated.is_connected(_on_controller_binding_invalidated):
		_controller.binding_invalidated.disconnect(_on_controller_binding_invalidated)
	_connections_active = false


func _on_controller_projection_changed(scope: StringName) -> void:
	if not _configured:
		return
	_refresh_inventory_views()
	inventory_view_changed.emit(scope, inventory_view(scope))


func _on_controller_status_changed(scope: StringName, _status: int) -> void:
	_on_controller_projection_changed(scope)


func _on_controller_binding_invalidated(reason: StringName) -> void:
	if not _configured:
		return
	# The controller has already detached its dependencies. Preserve only typed
	# unavailable snapshots associated with the exact former actor/generation.
	last_error = reason
	_configured = false
	_disconnect_controller()
	var actor := _admission.actor_id if _admission != null else null
	var generation := _admission.generation if _admission != null else 0
	_profile_view = InventoryView.unavailable(
		InventoryView.Scope.PROFILE, ZReadOnlyView.SyncState.DISCONNECTED,
		reason, generation, _profile_view.revision() if _profile_view != null else 0,
		0, actor)
	_raid_view = InventoryView.unavailable(
		InventoryView.Scope.RAID, ZReadOnlyView.SyncState.DISCONNECTED,
		reason, generation, _raid_view.revision() if _raid_view != null else 0,
		0, actor)
	_health_view = HealthView.unavailable(
		ZReadOnlyView.SyncState.DISCONNECTED, reason, generation,
		_health_view.revision() if _health_view != null else 0,
		_health_view.source_tick() if _health_view != null else 0, actor)
	inventory_view_changed.emit(SCOPE_PROFILE, _profile_view)
	inventory_view_changed.emit(SCOPE_RAID, _raid_view)
	health_view_changed.emit(_health_view)
	binding_invalidated.emit(reason)


func _health_transition_error(
	view: HealthView,
	admission: ZSessionAdmission
) -> StringName:
	if view == null or not view.is_initialized() or admission == null:
		return &"health_view_binding_invalid"
	var actor := view.actor_id()
	if actor != null and not actor.is_equal(admission.actor_id):
		return &"health_view_binding_invalid"
	if view.generation() != admission.generation:
		return &"health_view_binding_invalid"
	if view.is_ready() and actor == null:
		return &"health_view_binding_invalid"
	if not view.is_ready() or not _has_ready_health_watermark \
			or _health_lineage_actor_key != admission.actor_id.canonical_key() \
			or _health_lineage_generation != admission.generation:
		return &""
	if view.revision() < _ready_health_revision \
			or view.source_tick() < _ready_health_source_tick:
		return &"health_view_version_regressed"
	if view.revision() == _ready_health_revision \
			and view.source_tick() == _ready_health_source_tick \
			and view.content_digest() != _ready_health_content_digest:
		return &"health_view_version_divergent"
	return &""


func _health_lineage_error(admission: ZSessionAdmission) -> StringName:
	if admission == null or admission.actor_id == null:
		return &"health_view_binding_invalid"
	var actor_key := admission.actor_id.canonical_key()
	if _health_lineage_actor_key.is_empty() \
			or actor_key != _health_lineage_actor_key:
		return &""
	if admission.generation < _health_lineage_generation:
		return &"health_view_lineage_regressed"
	return &""


func _commit_health_lineage(
	admission: ZSessionAdmission,
	view: HealthView
) -> void:
	var actor_key := admission.actor_id.canonical_key()
	var replaces_lineage := _health_lineage_actor_key.is_empty() \
			or actor_key != _health_lineage_actor_key \
			or admission.generation > _health_lineage_generation
	if replaces_lineage:
		_has_ready_health_watermark = false
		_ready_health_revision = 0
		_ready_health_source_tick = 0
		_ready_health_content_digest = ""
	_health_lineage_actor_key = actor_key
	_health_lineage_generation = admission.generation
	if view == null or not view.is_ready():
		return
	_has_ready_health_watermark = true
	_ready_health_revision = view.revision()
	_ready_health_source_tick = view.source_tick()
	_ready_health_content_digest = view.content_digest()


func _sanitize_interaction_for_replacement() -> void:
	_interaction_state.erase("selected_item")
	_interaction_state.erase("selected_source")
	_interaction_state.erase("focus_identity")
	_interaction_state.erase("focus_item_id")
	_interaction_state.erase("focus_source")
	_interaction_state.erase("tooltip_item")
	_interaction_state.erase("tooltip_source")
	_interaction_state["tooltip"] = false
	_interaction_state["loot_mode"] = false
	_interaction_state["loot_open"] = false


func _fail(reason: StringName) -> bool:
	last_error = reason
	return false


func _fail_configure(reason: StringName) -> bool:
	var diagnostic := reason if not reason.is_empty() \
			else &"character_runtime_configure_failed"
	initialize_unavailable(diagnostic)
	return false
