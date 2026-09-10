class_name InventoryPresentationModel
extends RefCounted

## Snapshot-driven presentation model (tasks.md 8.2; inventory-presentation
## spec, "Snapshot-Driven Presentation Model"; design.md "Presentation
## architecture and interaction grammar").
##
## Scene-free, control-free, and authority-free: this class never holds an
## [InventoryAuthority]/[InventoryReplicaNode] reference and never calls into
## one. It is fed immutable [InventorySnapshotResource]s, recipient-bound
## [InventoryDiscoverySnapshotResource]s, and authoritative result records by
## a host (a screen/controller [Node] that owns the façade), and it exposes
## captured intent records for that same host to submit --
## "presentation consumes snapshots + submits intent" (design.md). Nothing
## here mutates canonical item, container, quantity, placement, or revision
## state; every method that "mutates" only touches this model's own local
## view/intent/feedback layers.
##
## -- The four layers (tasks.md 8.2) -----------------------------------------
## 1. CANONICAL  -- [member _snapshots]: latest accepted projected
##    [InventorySnapshotResource] per inventory id; [member
##    _discovery_snapshots] is a separate recipient-only axis and is never
##    merged into canonical item/container identity.
## 2. VIEW       -- [member _selection], [member _hover], [member
##    _focus_memory], [member _open_container_path]: pure local UI state,
##    never sent to authority and never reconciled against a snapshot.
## 3. INTENT     -- [member _pending]: canonical command intents; [member
##    _discovery_pending]: recipient discovery request id -> exact opaque
##    target plus both captured revision axes. Neither submits itself.
## 4. FEEDBACK   -- [member _last_rejection], [member _stale_corrections],
##    [member _accepted_markers], [member _disconnected], [member
##    _resynchronizing]: transient, TTL-bounded reconciliation state.
##
## -- Determinism --------------------------------------------------------
## Every Dictionary this class iterates for anything order-sensitive (building
## an Array of ids/entries to return) walks SORTED keys, never raw Dictionary
## iteration order, per this addon's canonical-ordering convention
## (contracts.md) extended to the presentation layer.
##
## -- Container/item facts this model cannot derive on its own --------------
## Snapshots do not carry a container's access mask or mass capacity (that
## lives in catalog-side [InventoryContainerConstraints], not the snapshot
## DTO), so "read-only" and "overweight" cannot be derived from snapshot
## content alone. The host computes those (typically from
## [code]InventoryAuthority.container_mass()[/code]/[code]container_mass_capacity()[/code]/
## a cached constraints lookup) and reports them through [method
## set_container_read_only]/[method set_container_overweight]/[method
## set_item_read_only]. "overflow" is deliberately NOT modeled here at all --
## it is pure viewport-vs-content geometry owned by the rendering control
## (a [ScrollContainer]'s own content size), which this scene-free class has
## no way to know.

signal model_changed
## Fires whenever [member _pending] changes shape (begin/cancel/resolve/TTL
## expiry) -- a finer-grained subset of [signal model_changed] for a consumer
## that only cares about in-flight intent (e.g. a "submitting..." indicator).
signal pending_changed
## Discovery-specific counterpart to [signal pending_changed]. Kept separate
## so a host can refresh Search/Scan/Cancel affordances without treating
## recipient discovery as a canonical inventory transaction.
signal discovery_pending_changed
## Fires exactly once per NEW rejection (never for TTL expiry of an old one).
## [param info] is the same Dictionary [method get_last_rejection] returns.
signal rejection_feedback(info: Dictionary)
## Fires exactly once per newly ACCEPTED (non-replayed) command -- the accept
## branch's mirror of [signal rejection_feedback], so views can edge-trigger
## one-shot accepted feedback (e.g. the §9 accepted flash) without inferring
## transitions from rebuild-prone card state. [param info] mirrors the
## rejection Dictionary's shape minus status/reason: `command_id`, `kind`,
## `inventory_id`, `items`, `ttl_remaining`.
signal accepted_feedback(info: Dictionary)
## Fires when an opaque discovery target or captured revision pair became
## stale. [param info] contains only recipient-visible tokens/revisions and a
## deterministic focus-recovery target; it never contains a canonical item id.
signal discovery_stale_token(info: Dictionary)
## Focus-only notification for hosting adapters. It deliberately does not
## trigger [signal model_changed], because controls are rebuilt from that
## signal and a focus-entered -> rebuild -> focus-entered loop would never
## settle.
signal discovery_focus_changed(inventory_id: int, kind: StringName, token: int)

# -- Item view-state tokens (DESIGN.md §12's fixed 24-state vocabulary; this
# model only ever RETURNS the subset item_state() resolves itself). --------
const STATE_NORMAL: StringName = &"normal"
const STATE_SELECTED: StringName = &"selected"
const STATE_PENDING: StringName = &"pending"
const STATE_ACCEPTED: StringName = &"accepted-flash"
const STATE_REJECTED: StringName = &"rejected"
const STATE_STALE_CORRECTED: StringName = &"stale-corrected"
const STATE_REDACTED: StringName = &"redacted"
const STATE_READ_ONLY: StringName = &"read-only"
const STATE_DISCONNECTED: StringName = &"disconnected"
const STATE_RESYNCHRONIZING: StringName = &"resynchronizing"

# -- Container view-state tokens (a distinct, container-scoped subset of the
# same DESIGN.md §12 vocabulary; see container_state()'s doc comment for why
# "overflow" is deliberately absent from this list). ------------------------
const STATE_EMPTY: StringName = &"empty"
const STATE_LOADING: StringName = &"loading"
const STATE_INACCESSIBLE: StringName = &"inaccessible"
const STATE_OVERWEIGHT: StringName = &"overweight"

# -- Recipient discovery states (DESIGN.md §12.11). These are intentionally
# distinct from network `loading`: an unsearched shell is complete,
# authoritative knowledge, not missing transport data. ----------------------
const STATE_DISCOVERY_UNSEARCHED: StringName = &"discovery-unsearched"
const STATE_DISCOVERY_SEARCHING: StringName = &"discovery-searching"
const STATE_DISCOVERY_INDEXED: StringName = &"discovery-indexed"
const STATE_DISCOVERY_UNKNOWN: StringName = &"discovery-unknown-entry"
const STATE_DISCOVERY_SCANNING: StringName = &"discovery-scanning-entry"

const DISCOVERY_INTENT_SEARCH: StringName = &"discovery_search"
const DISCOVERY_INTENT_SCAN: StringName = &"discovery_scan"
const DISCOVERY_INTENT_CANCEL: StringName = &"discovery_cancel"

# Mirrors protocol/inv_visibility.h's REDACTED_ITEM_DEFINITION_IDENTIFIER --
# never registered in any DefinitionCatalog, only ever a wire/snapshot
# placeholder for an item this presentation is not allowed to see the real
# identity of.
const REDACTED_ITEM_DEFINITION_IDENTIFIER: StringName = &"inventory.redacted.item"

# Reason tokens surfaced on [member _last_rejection]["reason_token"], derived
# from the rejected result's structured status. Keyed by DiagnosticId where
# one exists and is specific enough to be useful to presentation (native/core/
# inv_status.h); StatusCode-keyed fallbacks cover the rest. Neither enum is
# ClassDB-bound in this addon (matches the contract suite's own EVK_*
# precedent of locally mirroring the values it needs, with a citation).
const _DIAGNOSTIC_REASON_TOKENS := {
	112: &"inventory.presentation.reason.occupied", # DiagnosticId::PLACEMENT_OVERLAP
	113: &"inventory.presentation.reason.out_of_bounds", # DiagnosticId::PLACEMENT_OUT_OF_BOUNDS
	114: &"inventory.presentation.reason.containment_cycle", # DiagnosticId::CONTAINMENT_CYCLE
	115: &"inventory.presentation.reason.nesting_too_deep", # DiagnosticId::NESTING_DEPTH_EXCEEDED
	118: &"inventory.presentation.reason.filtered", # DiagnosticId::FILTER_TRAIT_MISMATCH
	119: &"inventory.presentation.reason.unknown_slot", # DiagnosticId::SLOT_UNKNOWN
	120: &"inventory.presentation.reason.invalid_ordinal", # DiagnosticId::LIST_ORDINAL_INVALID
	121: &"inventory.presentation.reason.capacity_unavailable", # DiagnosticId::CAPACITY_FEATURE_UNAVAILABLE
	122: &"inventory.presentation.reason.access_denied", # DiagnosticId::ACCESS_DENIED
	123: &"inventory.presentation.reason.overweight", # DiagnosticId::MASS_CAPACITY_EXCEEDED
	124: &"inventory.presentation.reason.stack_mismatch", # DiagnosticId::STACK_DEFINITION_MISMATCH
	132: &"inventory.presentation.reason.no_placement_found", # DiagnosticId::PLACEMENT_CANDIDATE_EXHAUSTED
	133: &"inventory.presentation.reason.quick_transfer_incomplete", # DiagnosticId::QUICK_TRANSFER_INCOMPLETE
	159: &"inventory.presentation.reason.discovery_recipient_unknown",
	160: &"inventory.presentation.reason.discovery_busy",
	161: &"inventory.presentation.reason.discovery_revision_stale",
	162: &"inventory.presentation.reason.discovery_not_indexed",
	163: &"inventory.presentation.reason.discovery_token_invalid",
	164: &"inventory.presentation.reason.discovery_task_not_found",
	165: &"inventory.presentation.reason.discovery_elapsed_invalid",
	166: &"inventory.presentation.reason.discovery_target_stale",
	167: &"inventory.presentation.reason.discovery_redacted",
}
const _STATUS_REASON_TOKENS := {
	1: &"inventory.presentation.reason.invalid_argument", # StatusCode::INVALID_ARGUMENT
	2: &"inventory.presentation.reason.not_found", # StatusCode::NOT_FOUND
	6: &"inventory.presentation.reason.limit_exceeded", # StatusCode::LIMIT_EXCEEDED
	60: &"inventory.presentation.reason.stale_revision", # StatusCode::REVISION_MISMATCH
	61: &"inventory.presentation.reason.duplicate_command", # StatusCode::DUPLICATE_COMMAND
	62: &"inventory.presentation.reason.permission_denied", # StatusCode::PERMISSION_DENIED
	63: &"inventory.presentation.reason.role_violation", # StatusCode::ROLE_VIOLATION
}
const _DEFAULT_REASON_TOKEN: StringName = &"inventory.presentation.reason.rejected"

## Default pending-intent lifetime, in host-defined ticks (frames, fixed
## simulation steps -- whatever unit the host's [method tick] calls use).
## Overridable per call via `args.ttl_ticks` in [method begin_intent].
@export var default_pending_ttl_ticks: int = 180
## How long an accepted-flash / rejection / stale-corrected marker stays
## visible after the triggering event, in the same host-defined tick unit.
@export var accepted_marker_ttl_ticks: int = 36
@export var rejection_feedback_ttl_ticks: int = 90
@export var stale_correction_ttl_ticks: int = 90

## Optional presentation-only resolver:
## `Callable(item_definition_identifier: StringName) -> Dictionary`.
## Names, descriptions, categories, and textures returned here never enter
## canonical inventory state.
var item_presentation_resolver: Callable


func item_presentation(item_definition_identifier: StringName) -> Dictionary:
	if not item_presentation_resolver.is_valid():
		return {
			"display_name": String(item_definition_identifier),
			"icon": null,
			"fallback": true,
		}
	var value: Variant = item_presentation_resolver.call(item_definition_identifier)
	return value as Dictionary if value is Dictionary else {}

# -- Canonical layer ----------------------------------------------------
var _snapshots: Dictionary = {} # int inventory_id -> InventorySnapshotResource
var _discovery_snapshots: Dictionary = {} # int inventory_id -> InventoryDiscoverySnapshotResource

# -- View layer -----------------------------------------------------------
var _selection: Dictionary = {} # {} or {"inventory_id": int, "item_id": int}
var _hover: Dictionary = {} # same shape as _selection
var _focus_memory: Dictionary = {} # int container_id -> String remembered identifier
var _open_container_path: Array[int] = []
var _read_only_containers: Dictionary = {} # int container_id -> true
var _read_only_items: Dictionary = {} # int item_id -> true
var _inaccessible_containers: Dictionary = {} # int container_id -> true (host override)
var _overweight_containers: Dictionary = {} # int container_id -> true
var _discovery_focus: Dictionary = {} # int inventory_id -> {kind: StringName, token: int}
var _discovery_focus_recovery: Dictionary = {} # int inventory_id -> recipient-safe recovery record

# -- Intent layer -----------------------------------------------------------
var _pending: Dictionary = {} # int pending_id (== client command_id) -> Dictionary
# Starts far above any realistic auto-allocated authority command id (every
# InventoryAuthority typed command method starts ITS OWN `next_command_id`
# counter at 1 and increments per instance -- inventory_authority.h). Since
# begin_intent()'s calling convention requires the caller to reuse this
# value as the real command_id (see begin_intent()'s doc comment), a pending
# id drawn from the same small 1.. range as auto-allocated ids risks
# colliding with an authority call this model never tracked (e.g. server-side
# world setup, or any command submitted without going through this model) --
# the SAME authority instance's idempotency ledger would then see two
# unrelated commands sharing one id and reject the second as
# DUPLICATE_COMMAND/IDEMPOTENCY_PAYLOAD_MISMATCH. Reserving a high id range
# for this model's own pending ids makes that collision practically
# unreachable (a game would need billions of untracked auto-allocated
# commands on one authority instance first) without requiring this
# authority-free class to hold or query a live InventoryAuthority reference.
var _next_pending_id: int = 1 << 32
var _discovery_pending: Dictionary = {} # int request_id -> captured recipient intent
var _next_discovery_request_id: int = 1 << 48

# -- Feedback layer -----------------------------------------------------------
var _last_rejection: Dictionary = {} # {} or {command_id, kind, inventory_id, items, status, reason_token, ttl_remaining}
var _stale_corrections: Dictionary = {} # int inventory_id -> {"items": Array[int], "ttl_remaining": int}
var _accepted_markers: Dictionary = {} # int item_id -> int ttl_remaining
var _disconnected: bool = false
var _resynchronizing: bool = false
var _discovery_resynchronizing: Dictionary = {} # int inventory_id -> true
var _last_discovery_rejection: Dictionary = {}


# =============================================================================
# Canonical layer
# =============================================================================

## Installs [param snapshot] as the latest accepted state for its own
## [code]get_inventory_id()[/code]. Ignored (no-op, no signal) if a
## newer-or-equal-revision snapshot is already stored for that inventory --
## "latest accepted" never regresses, matching the replica's own
## monotonic-revision discipline one layer up.
##
## Also resolves stale-correction (8.2/8.7): every pending intent for this
## inventory whose [code]expected_revision + 1 < snapshot.get_revision()[/code]
## assumed a baseline that something ELSE has since moved past -- such a
## pending's own eventual accept/reject can never arrive meaningfully (the
## authority already answered a different, newer submission's worth of state
## by the time this snapshot was produced, or this ghost's placement no
## longer reflects the real destination). That pending is cleared here and
## its items are marked stale-corrected for [member stale_correction_ttl_ticks].
## A pending whose own command exactly produced this revision
## ([code]expected_revision + 1 == revision[/code]) is left alone; it still
## resolves normally through [method apply_result].
func apply_snapshot(snapshot: InventorySnapshotResource) -> void:
	if snapshot == null:
		return
	var inventory_id := snapshot.get_inventory_id()
	var existing: InventorySnapshotResource = _snapshots.get(inventory_id, null)
	if existing != null and existing.get_revision() > snapshot.get_revision():
		return
	_snapshots[inventory_id] = snapshot

	var corrected_items: Array[int] = []
	for pending_id in _sorted_keys(_pending):
		var pending: Dictionary = _pending[pending_id]
		if int(pending.get("inventory_id", -1)) != inventory_id:
			continue
		var expected_revision := int(pending.get("expected_revision", 0))
		if expected_revision + 1 < snapshot.get_revision():
			for item_id in (pending.get("items", []) as Array):
				corrected_items.append(int(item_id))
			_pending.erase(pending_id)
	if not corrected_items.is_empty():
		_stale_corrections[inventory_id] = {
			"items": corrected_items,
			"ttl_remaining": stale_correction_ttl_ticks,
		}
		pending_changed.emit()

	model_changed.emit()


func has_snapshot(inventory_id: int) -> bool:
	return _snapshots.has(inventory_id)


func get_snapshot(inventory_id: int) -> InventorySnapshotResource:
	return _snapshots.get(inventory_id, null)


# =============================================================================
# Recipient discovery layer
# =============================================================================

## Installs one complete recipient projection. The two revision axes are
## monotonic independently: a projection that regresses either axis is
## rejected, even if the other axis is newer. On success its projected
## inventory snapshot is also installed through [method apply_snapshot], so
## revealed items enter the ordinary presentation path and opaque entries
## remain exclusive to this layer.
func apply_discovery_snapshot(snapshot: InventoryDiscoverySnapshotResource) -> bool:
	if snapshot == null:
		return false
	var inventory_id := snapshot.get_inventory_id()
	var existing: InventoryDiscoverySnapshotResource = _discovery_snapshots.get(inventory_id, null)
	if existing != null:
		if snapshot.get_inventory_revision() < existing.get_inventory_revision():
			return false
		if snapshot.get_discovery_revision() < existing.get_discovery_revision():
			return false

	_discovery_snapshots[inventory_id] = snapshot
	_discovery_resynchronizing.erase(inventory_id)
	_reconcile_discovery_focus(inventory_id, existing, snapshot)
	_reconcile_discovery_pending_for_inventory(inventory_id, snapshot)

	var projected := snapshot.get_projected_snapshot()
	if projected != null:
		apply_snapshot(projected)
	else:
		model_changed.emit()
	return true


## Applies a replacement-style recipient delta only when BOTH predecessor
## revisions exactly match the installed projection. Any gap marks this
## inventory's discovery axis as resynchronizing without changing the
## canonical/network-wide [member _resynchronizing] flag.
func apply_discovery_delta(delta: InventoryDiscoveryDeltaResource) -> bool:
	if delta == null:
		return false
	var inventory_id := delta.get_inventory_id()
	var current: InventoryDiscoverySnapshotResource = _discovery_snapshots.get(inventory_id, null)
	if current == null:
		set_discovery_resynchronizing(inventory_id, true)
		return false
	if delta.get_predecessor_inventory_revision() != current.get_inventory_revision() \
			or delta.get_predecessor_discovery_revision() != current.get_discovery_revision():
		set_discovery_resynchronizing(inventory_id, true)
		return false
	var replacement := delta.get_replacement_snapshot()
	if replacement == null \
			or replacement.get_inventory_id() != inventory_id \
			or replacement.get_inventory_revision() != delta.get_successor_inventory_revision() \
			or replacement.get_discovery_revision() != delta.get_successor_discovery_revision():
		set_discovery_resynchronizing(inventory_id, true)
		return false
	return apply_discovery_snapshot(replacement)


func has_discovery_snapshot(inventory_id: int) -> bool:
	return _discovery_snapshots.has(inventory_id)


func get_discovery_snapshot(inventory_id: int) -> InventoryDiscoverySnapshotResource:
	return _discovery_snapshots.get(inventory_id, null)


func discovery_inventory_revision(inventory_id: int) -> int:
	var snapshot: InventoryDiscoverySnapshotResource = _discovery_snapshots.get(inventory_id, null)
	return snapshot.get_inventory_revision() if snapshot != null else -1


func discovery_revision(inventory_id: int) -> int:
	var snapshot: InventoryDiscoverySnapshotResource = _discovery_snapshots.get(inventory_id, null)
	return snapshot.get_discovery_revision() if snapshot != null else -1


## Recipient containers in ascending opaque-token order. Native projections
## are already canonical, but sorting again at this boundary prevents a
## custom Resource implementation or future binding change from leaking
## insertion order into focus/render order.
func discovery_containers(inventory_id: int) -> Array:
	var snapshot: InventoryDiscoverySnapshotResource = _discovery_snapshots.get(inventory_id, null)
	if snapshot == null:
		return []
	var result: Array = []
	for container_variant in snapshot.get_containers():
		var container: InventoryDiscoveryContainerViewResource = container_variant
		if container != null:
			result.append(container)
	# Indexed containers deliberately have no opaque shell token, so token
	# cannot be used as a Dictionary key here (several indexed containers
	# would all collide at zero). The tuple keeps hidden shells ordered only by
	# recipient-visible token and indexed shells only by disclosed id.
	result.sort_custom(func(a, b):
		var left: InventoryDiscoveryContainerViewResource = a
		var right: InventoryDiscoveryContainerViewResource = b
		var left_hidden := left.get_token() != 0
		var right_hidden := right.get_token() != 0
		if left_hidden != right_hidden:
			return left_hidden
		return left.get_token() < right.get_token() if left_hidden \
				else left.get_container_id() < right.get_container_id())
	return result


func discovery_container_by_token(inventory_id: int, token: int) -> InventoryDiscoveryContainerViewResource:
	if token == 0:
		return null
	for container_variant in discovery_containers(inventory_id):
		var container: InventoryDiscoveryContainerViewResource = container_variant
		if container.get_token() == token:
			return container
	return null


func discovery_container_by_id(inventory_id: int, container_id: int) -> InventoryDiscoveryContainerViewResource:
	if container_id <= 0:
		return null
	for container_variant in discovery_containers(inventory_id):
		var container: InventoryDiscoveryContainerViewResource = container_variant
		if container.get_container_id() == container_id:
			return container
	return null


func discovery_entries(inventory_id: int, container_token: int = 0) -> Array:
	var by_token: Dictionary = {}
	for container_variant in discovery_containers(inventory_id):
		var container: InventoryDiscoveryContainerViewResource = container_variant
		if container_token != 0 and container.get_token() != container_token:
			continue
		for entry_variant in container.get_entries():
			var entry: InventoryDiscoveryEntryResource = entry_variant
			if entry != null:
				by_token[entry.get_token()] = entry
	var result: Array = []
	for token in _sorted_keys(by_token):
		result.append(by_token[token])
	return result


func discovery_entry_by_token(inventory_id: int, token: int) -> InventoryDiscoveryEntryResource:
	for entry_variant in discovery_entries(inventory_id):
		var entry: InventoryDiscoveryEntryResource = entry_variant
		if entry.get_token() == token:
			return entry
	return null


func discovery_task(inventory_id: int) -> InventoryDiscoveryTaskResource:
	var snapshot: InventoryDiscoverySnapshotResource = _discovery_snapshots.get(inventory_id, null)
	return snapshot.get_task() if snapshot != null else null


## Returns a complete eligibility decision and the exact revision/token tuple
## a host must submit. This never falls back to canonical selection and never
## describes an absent recipient projection as ordinary network "loading".
func discovery_action_eligibility(inventory_id: int, kind: StringName, target_token: int = 0) -> Dictionary:
	var denied := {
		"allowed": false,
		"reason": &"inventory.presentation.discovery.recipient_view_unavailable",
		"inventory_id": inventory_id,
		"kind": kind,
		"target_token": target_token,
		"inventory_revision": -1,
		"discovery_revision": -1,
	}
	if _disconnected:
		denied["reason"] = &"inventory.presentation.discovery.disconnected"
		return denied
	if _resynchronizing or discovery_needs_resync(inventory_id):
		denied["reason"] = &"inventory.presentation.discovery.resynchronizing"
		return denied
	var snapshot: InventoryDiscoverySnapshotResource = _discovery_snapshots.get(inventory_id, null)
	if snapshot == null:
		return denied

	denied["inventory_revision"] = snapshot.get_inventory_revision()
	denied["discovery_revision"] = snapshot.get_discovery_revision()
	if not discovery_pending_ids_for_inventory(inventory_id).is_empty():
		denied["reason"] = &"inventory.presentation.discovery.local_pending"
		return denied

	var task := snapshot.get_task()
	var actor_busy := task != null and task.is_actor_busy()
	match kind:
		DISCOVERY_INTENT_SEARCH:
			if actor_busy:
				denied["reason"] = &"inventory.presentation.discovery.actor_busy"
				return denied
			var container := discovery_container_by_token(inventory_id, target_token)
			if container == null:
				denied["reason"] = &"inventory.presentation.discovery.stale_token"
				return denied
			if container.get_stage() != InventoryDiscoveryContainerViewResource.STAGE_UNSEARCHED:
				denied["reason"] = &"inventory.presentation.discovery.already_searched"
				return denied
		DISCOVERY_INTENT_SCAN:
			if actor_busy:
				denied["reason"] = &"inventory.presentation.discovery.actor_busy"
				return denied
			var entry := discovery_entry_by_token(inventory_id, target_token)
			if entry == null:
				denied["reason"] = &"inventory.presentation.discovery.stale_token"
				return denied
			if entry.get_stage() != InventoryDiscoveryEntryResource.STAGE_UNKNOWN:
				denied["reason"] = &"inventory.presentation.discovery.already_scanning"
				return denied
		DISCOVERY_INTENT_CANCEL:
			if not actor_busy:
				denied["reason"] = &"inventory.presentation.discovery.no_active_task"
				return denied
			var active_token: int = task.get_target_token()
			if target_token != 0 and target_token != active_token:
				denied["reason"] = &"inventory.presentation.discovery.target_changed"
				return denied
			denied["target_token"] = active_token
		_:
			denied["reason"] = &"inventory.presentation.discovery.unknown_action"
			return denied

	denied["allowed"] = true
	denied["reason"] = &""
	return denied


## Captures a local Search/Scan/Cancel request without submitting it. The
## returned id MUST be passed as `request_id` to the matching authority call.
## A zero return means eligibility failed and no pending record was created.
func begin_discovery_intent(inventory_id: int, kind: StringName, target_token: int = 0) -> int:
	var eligibility := discovery_action_eligibility(inventory_id, kind, target_token)
	if not bool(eligibility.get("allowed", false)):
		return 0
	var request_id := _next_discovery_request_id
	_next_discovery_request_id += 1
	_discovery_pending[request_id] = {
		"request_id": request_id,
		"kind": kind,
		"inventory_id": inventory_id,
		"target_token": int(eligibility.get("target_token", 0)),
		"expected_inventory_revision": int(eligibility.get("inventory_revision", -1)),
		"expected_discovery_revision": int(eligibility.get("discovery_revision", -1)),
		"ttl_remaining": default_pending_ttl_ticks,
	}
	discovery_pending_changed.emit()
	model_changed.emit()
	return request_id


func cancel_discovery_intent(request_id: int) -> void:
	if not _discovery_pending.has(request_id):
		return
	_discovery_pending.erase(request_id)
	discovery_pending_changed.emit()
	model_changed.emit()


func get_discovery_pending(request_id: int) -> Dictionary:
	return (_discovery_pending[request_id] as Dictionary).duplicate(true) \
			if _discovery_pending.has(request_id) else {}


func discovery_pending_ids_for_inventory(inventory_id: int) -> Array[int]:
	var result: Array[int] = []
	for request_id in _sorted_keys(_discovery_pending):
		var pending: Dictionary = _discovery_pending[request_id]
		if int(pending.get("inventory_id", -1)) == inventory_id:
			result.append(request_id)
	return result


## Reconciles the exact resource returned by a discovery authority method.
## Accepted/replayed results clear local pending state; rejected stale tokens
## additionally disable discovery actions until a replacement view is applied.
func apply_discovery_result(result: InventoryDiscoveryResultResource) -> bool:
	if result == null:
		return false
	var request_id := result.get_request_id()
	if not _discovery_pending.has(request_id):
		return false
	var pending: Dictionary = _discovery_pending[request_id]
	_discovery_pending.erase(request_id)
	discovery_pending_changed.emit()

	if result.is_accepted() or result.is_replayed():
		_last_discovery_rejection = {}
		model_changed.emit()
		return true

	var status: Dictionary = result.get_status().duplicate(true)
	_last_discovery_rejection = {
		"request_id": request_id,
		"kind": pending.get("kind", &""),
		"inventory_id": pending.get("inventory_id", 0),
		"target_token": pending.get("target_token", 0),
		"status": status,
		"reason_token": _reason_token_for(status),
		"ttl_remaining": rejection_feedback_ttl_ticks,
	}
	var diagnostic := int(status.get("diagnostic", 0))
	if int(status.get("code", -1)) == 60 or diagnostic in [161, 163, 166]:
		_mark_discovery_target_stale(
				int(pending.get("inventory_id", 0)),
				StringName(pending.get("kind", &"")),
				int(pending.get("target_token", 0)))
	model_changed.emit()
	return true


func get_last_discovery_rejection() -> Dictionary:
	return _last_discovery_rejection.duplicate(true)


func set_discovery_resynchronizing(inventory_id: int, value: bool) -> void:
	var had_value := _discovery_resynchronizing.has(inventory_id)
	if value == had_value:
		return
	if value:
		_discovery_resynchronizing[inventory_id] = true
	else:
		_discovery_resynchronizing.erase(inventory_id)
	model_changed.emit()


func discovery_needs_resync(inventory_id: int) -> bool:
	return _discovery_resynchronizing.has(inventory_id)


func remember_discovery_focus(inventory_id: int, kind: StringName, token: int) -> void:
	if token == 0:
		if _discovery_focus.has(inventory_id):
			_discovery_focus.erase(inventory_id)
			discovery_focus_changed.emit(inventory_id, &"", 0)
		return
	var existing: Dictionary = _discovery_focus.get(inventory_id, {})
	if StringName(existing.get("kind", &"")) == kind \
			and int(existing.get("token", 0)) == token:
		return
	_discovery_focus[inventory_id] = {"kind": kind, "token": token}
	discovery_focus_changed.emit(inventory_id, kind, token)


func recall_discovery_focus(inventory_id: int) -> Dictionary:
	return (_discovery_focus[inventory_id] as Dictionary).duplicate(true) \
			if _discovery_focus.has(inventory_id) else {}


func get_discovery_focus_recovery(inventory_id: int) -> Dictionary:
	return (_discovery_focus_recovery[inventory_id] as Dictionary).duplicate(true) \
			if _discovery_focus_recovery.has(inventory_id) else {}


func clear_discovery_focus_recovery(inventory_id: int) -> void:
	_discovery_focus_recovery.erase(inventory_id)


## Clears every recipient-bound projection, opaque token, pending request,
## focus record, and projected canonical snapshot previously installed by
## discovery. Call this before applying the first view for a replacement
## authenticated session/actor so a legitimate revision-zero reconnect is
## not mistaken for a regression of the previous recipient.
func reset_discovery_recipient_state() -> void:
	var affected_inventories := _discovery_snapshots.keys()
	for inventory_id in affected_inventories:
		_snapshots.erase(int(inventory_id))
	_discovery_snapshots.clear()
	_discovery_pending.clear()
	_discovery_focus.clear()
	_discovery_focus_recovery.clear()
	_discovery_resynchronizing.clear()
	_last_discovery_rejection = {}
	discovery_pending_changed.emit()
	discovery_focus_changed.emit(0, &"", 0)
	model_changed.emit()


func discovery_container_state(inventory_id: int, container_token: int) -> StringName:
	if _disconnected:
		return STATE_DISCONNECTED
	if _resynchronizing or discovery_needs_resync(inventory_id):
		return STATE_RESYNCHRONIZING
	for request_id in discovery_pending_ids_for_inventory(inventory_id):
		var pending: Dictionary = _discovery_pending[request_id]
		if int(pending.get("target_token", 0)) == container_token:
			return STATE_PENDING
	var container := discovery_container_by_token(inventory_id, container_token)
	if container == null:
		return STATE_INACCESSIBLE
	match container.get_stage():
		InventoryDiscoveryContainerViewResource.STAGE_UNSEARCHED:
			return STATE_DISCOVERY_UNSEARCHED
		InventoryDiscoveryContainerViewResource.STAGE_SEARCHING:
			return STATE_DISCOVERY_SEARCHING
		InventoryDiscoveryContainerViewResource.STAGE_INDEXED:
			return STATE_DISCOVERY_INDEXED
	return STATE_INACCESSIBLE


func discovery_entry_state(inventory_id: int, entry_token: int) -> StringName:
	if _disconnected:
		return STATE_DISCONNECTED
	if _resynchronizing or discovery_needs_resync(inventory_id):
		return STATE_RESYNCHRONIZING
	for request_id in discovery_pending_ids_for_inventory(inventory_id):
		var pending: Dictionary = _discovery_pending[request_id]
		if int(pending.get("target_token", 0)) == entry_token:
			return STATE_PENDING
	var entry := discovery_entry_by_token(inventory_id, entry_token)
	if entry == null:
		return STATE_STALE_CORRECTED
	return STATE_DISCOVERY_SCANNING \
			if entry.get_stage() == InventoryDiscoveryEntryResource.STAGE_SCANNING \
			else STATE_DISCOVERY_UNKNOWN


static func discovery_progress(elapsed_ms: int, duration_ms: int) -> float:
	if duration_ms <= 0:
		return 0.0
	return clampf(float(elapsed_ms) / float(duration_ms), 0.0, 1.0)


func _reconcile_discovery_pending_for_inventory(
		inventory_id: int,
		snapshot: InventoryDiscoverySnapshotResource) -> void:
	var changed := false
	for request_id in discovery_pending_ids_for_inventory(inventory_id):
		var pending: Dictionary = _discovery_pending[request_id]
		if snapshot.get_inventory_revision() <= int(pending.get("expected_inventory_revision", -1)):
			continue
		var kind := StringName(pending.get("kind", &""))
		var token := int(pending.get("target_token", 0))
		var target_survives := true
		if kind == DISCOVERY_INTENT_SEARCH:
			target_survives = discovery_container_by_token(inventory_id, token) != null
		elif kind == DISCOVERY_INTENT_SCAN:
			target_survives = discovery_entry_by_token(inventory_id, token) != null
		if target_survives:
			continue
		_discovery_pending.erase(request_id)
		changed = true
		_mark_discovery_target_stale(inventory_id, kind, token)
	if changed:
		discovery_pending_changed.emit()


func _reconcile_discovery_focus(
		inventory_id: int,
		old_snapshot: InventoryDiscoverySnapshotResource,
		new_snapshot: InventoryDiscoverySnapshotResource) -> void:
	if old_snapshot == null or not _discovery_focus.has(inventory_id):
		return
	var remembered: Dictionary = _discovery_focus[inventory_id]
	var kind := StringName(remembered.get("kind", &""))
	var token := int(remembered.get("token", 0))
	var new_tokens := _discovery_tokens_for_snapshot(new_snapshot, kind)
	if token in new_tokens:
		_discovery_focus_recovery.erase(inventory_id)
		return

	var old_tokens := _discovery_tokens_for_snapshot(old_snapshot, kind)
	var old_index := old_tokens.find(token)
	var replacement_token := 0
	if not new_tokens.is_empty():
		var replacement_index := old_index if old_index >= 0 else 0
		replacement_token = int(new_tokens[mini(replacement_index, new_tokens.size() - 1)])
		_discovery_focus[inventory_id] = {"kind": kind, "token": replacement_token}
	else:
		_discovery_focus.erase(inventory_id)
	var recovery := {
		"inventory_id": inventory_id,
		"kind": kind,
		"stale_token": token,
		"replacement_token": replacement_token,
		"fallback": &"opaque_token" if replacement_token != 0 else &"container_action",
	}
	_discovery_focus_recovery[inventory_id] = recovery
	discovery_stale_token.emit(recovery.duplicate(true))


func _mark_discovery_target_stale(inventory_id: int, kind: StringName, token: int) -> void:
	_discovery_resynchronizing[inventory_id] = true
	var recovery := {
		"inventory_id": inventory_id,
		"kind": kind,
		"stale_token": token,
		"replacement_token": 0,
		"fallback": &"replacement_view",
	}
	_discovery_focus_recovery[inventory_id] = recovery
	discovery_stale_token.emit(recovery.duplicate(true))


func _discovery_tokens_for_snapshot(
		snapshot: InventoryDiscoverySnapshotResource,
		kind: StringName) -> Array[int]:
	var result: Array[int] = []
	if snapshot == null:
		return result
	if kind == DISCOVERY_INTENT_SEARCH or kind == &"container":
		for container_variant in snapshot.get_containers():
			var container: InventoryDiscoveryContainerViewResource = container_variant
			if container.get_token() != 0:
				result.append(container.get_token())
	else:
		for container_variant in snapshot.get_containers():
			var container: InventoryDiscoveryContainerViewResource = container_variant
			for entry_variant in container.get_entries():
				var entry: InventoryDiscoveryEntryResource = entry_variant
				result.append(entry.get_token())
	result.sort()
	return result


# =============================================================================
# Intent layer
# =============================================================================

## Registers optimistic ghost data for a not-yet-confirmed command. Does NOT
## touch [member _snapshots] or submit anything itself.
##
## CALLING CONVENTION: the returned pending id is a CLIENT-assigned command
## id, not an opaque handle -- the caller MUST pass this exact value as the
## `command_id` argument of the real [code]InventoryAuthority[/code] call it
## makes immediately after (e.g.
## [code]authority.move_item(inv, item, dest, actor, pending_id)[/code]), or
## [method apply_result] will never be able to correlate the authoritative
## result back to this ghost. A host that drives presentation intent must
## therefore never rely on `command_id <= 0` auto-allocation for a
## presentation-tracked command.
##
## [param args]: [code]{inventory_id: int, items: Array[int] (existing item
## ids this intent concerns; empty for a pure-insert intent with no item yet),
## ghost_placement: Dictionary (opaque, location_dict()-shaped placement data
## for rendering an optimistic ghost), ttl_ticks: int (optional, overrides
## [member default_pending_ttl_ticks])}[/code].
func begin_intent(kind: StringName, args: Dictionary) -> int:
	var inventory_id := int(args.get("inventory_id", 0))
	var items: Array[int] = []
	for raw_item in (args.get("items", []) as Array):
		items.append(int(raw_item))

	var pending_id := _next_pending_id
	_next_pending_id += 1

	var expected_revision := 0
	var snapshot: InventorySnapshotResource = _snapshots.get(inventory_id, null)
	if snapshot != null:
		expected_revision = snapshot.get_revision()

	var ghost_placement: Dictionary = {}
	if args.get("ghost_placement") is Dictionary:
		ghost_placement = (args["ghost_placement"] as Dictionary).duplicate(true)

	_pending[pending_id] = {
		"kind": kind,
		"inventory_id": inventory_id,
		"items": items,
		"expected_revision": expected_revision,
		"ghost_placement": ghost_placement,
		"ttl_remaining": int(args.get("ttl_ticks", default_pending_ttl_ticks)),
	}
	pending_changed.emit()
	model_changed.emit()
	return pending_id


## Withdraws a pending intent before authority ever responds (e.g. a drag
## cancelled mid-gesture). This is purely local bookkeeping: if the
## corresponding command was already submitted, its eventual result -- if any
## arrives -- simply finds no matching pending entry and [method apply_result]
## silently ignores it.
func cancel_intent(pending_id: int) -> void:
	if not _pending.has(pending_id):
		return
	_pending.erase(pending_id)
	pending_changed.emit()
	model_changed.emit()


## Reconciles an authoritative command-result Dictionary (the exact shape
## every [code]InventoryAuthority[/code] typed command method / [code]
## submit_command_bytes()[/code] returns) against [member _pending]. A result
## whose `command_id` names no known pending entry is ignored -- either this
## model never tracked that command (submitted outside the intent layer) or
## it already resolved once.
##
## - `replayed == true`: cleared silently, no feedback (an idempotent replay
##   of an already-known outcome; the original resolution already fired).
## - `accepted == true` (and not replayed): pending cleared, every named item
##   gets a transient accepted-flash marker, AND is removed from [member
##   _last_rejection]'s own item list if present there.
## - otherwise (rejected): pending cleared, every named item's stale
##   accepted-flash marker (if any) is removed, [member _last_rejection] is
##   set, and [signal rejection_feedback] fires once. Canonical state is
##   untouched -- this only ever writes to the feedback layer.
##
## The cross-clearing above (accept clears rejection, reject clears
## accepted-flash) matters because these two markers are keyed independently
## by item id, not by command id: without it, an item's LEFTOVER
## accepted-flash from an earlier, already-resolved command could keep
## outranking (per [method item_state]'s precedence) a brand-new rejection
## for a DIFFERENT command touching the very same item, or vice versa --
## [method item_state] would then show stale feedback for an outcome that no
## longer reflects this item's most recent authoritative result.
func apply_result(result: Dictionary) -> void:
	var command_id := int(result.get("command_id", 0))
	if not _pending.has(command_id):
		return
	var pending: Dictionary = _pending[command_id]
	_pending.erase(command_id)

	if bool(result.get("replayed", false)):
		pending_changed.emit()
		model_changed.emit()
		return

	if bool(result.get("accepted", false)):
		for item_id in (pending.get("items", []) as Array):
			var iid := int(item_id)
			_accepted_markers[iid] = accepted_marker_ttl_ticks
			_clear_item_from_last_rejection(iid)
		pending_changed.emit()
		model_changed.emit()
		accepted_feedback.emit({
			"command_id": command_id,
			"kind": pending.get("kind", &""),
			"inventory_id": pending.get("inventory_id", 0),
			"items": (pending.get("items", []) as Array).duplicate(),
			"ttl_remaining": accepted_marker_ttl_ticks,
		})
		return

	for item_id in (pending.get("items", []) as Array):
		_accepted_markers.erase(int(item_id))

	var status: Dictionary = (result.get("status", {}) as Dictionary).duplicate(true)
	_last_rejection = {
		"command_id": command_id,
		"kind": pending.get("kind", &""),
		"inventory_id": pending.get("inventory_id", 0),
		"items": (pending.get("items", []) as Array).duplicate(),
		"status": status,
		"reason_token": _reason_token_for(status),
		"ttl_remaining": rejection_feedback_ttl_ticks,
	}
	pending_changed.emit()
	model_changed.emit()
	rejection_feedback.emit(_last_rejection.duplicate(true))


## Removes [param item_id] from [member _last_rejection]'s own item list, if
## present -- clearing [member _last_rejection] entirely once no item remains
## in it. See [method apply_result]'s doc comment for why a fresh accept
## actively clears this rather than relying on precedence ordering alone.
func _clear_item_from_last_rejection(item_id: int) -> void:
	if _last_rejection.is_empty():
		return
	var items: Array = (_last_rejection.get("items", []) as Array)
	if not items.has(item_id):
		return
	items.erase(item_id)
	if items.is_empty():
		_last_rejection = {}
	else:
		_last_rejection["items"] = items


func get_pending(pending_id: int) -> Dictionary:
	return (_pending[pending_id] as Dictionary).duplicate(true) if _pending.has(pending_id) else {}


## Every currently-tracked pending id for [param inventory_id], sorted
## ascending (client command ids are monotonic, so this is also submission
## order).
func pending_ids_for_inventory(inventory_id: int) -> Array[int]:
	var result: Array[int] = []
	for pending_id in _sorted_keys(_pending):
		if int((_pending[pending_id] as Dictionary).get("inventory_id", -1)) == inventory_id:
			result.append(pending_id)
	return result


## The ghost placement data for the first pending intent (lowest id) naming
## [param item_id], or an empty Dictionary if none is pending.
func get_pending_ghost(inventory_id: int, item_id: int) -> Dictionary:
	for pending_id in _sorted_keys(_pending):
		var pending: Dictionary = _pending[pending_id]
		if int(pending.get("inventory_id", -1)) != inventory_id:
			continue
		if item_id in (pending.get("items", []) as Array):
			return (pending.get("ghost_placement", {}) as Dictionary).duplicate(true)
	return {}


# =============================================================================
# View layer
# =============================================================================

func select(inventory_id: int, item_id: int) -> void:
	_selection = {"inventory_id": inventory_id, "item_id": item_id}
	if _discovery_focus.has(inventory_id):
		_discovery_focus.erase(inventory_id)
		discovery_focus_changed.emit(inventory_id, &"", 0)
	model_changed.emit()


func clear_selection() -> void:
	if _selection.is_empty():
		return
	_selection = {}
	model_changed.emit()


func get_selection() -> Dictionary:
	return _selection.duplicate()


func is_selected(inventory_id: int, item_id: int) -> bool:
	return int(_selection.get("inventory_id", -1)) == inventory_id and int(_selection.get("item_id", -1)) == item_id


func set_hover(inventory_id: int, item_id: int) -> void:
	_hover = {"inventory_id": inventory_id, "item_id": item_id}
	model_changed.emit()


func clear_hover() -> void:
	if _hover.is_empty():
		return
	_hover = {}
	model_changed.emit()


func get_hover() -> Dictionary:
	return _hover.duplicate()


func is_hovered(inventory_id: int, item_id: int) -> bool:
	return int(_hover.get("inventory_id", -1)) == inventory_id and int(_hover.get("item_id", -1)) == item_id


## Remembers the last-focused item/slot identifier within one container, so a
## host can restore focus deterministically after a modal closes or a
## container is re-entered (inventory-presentation spec, "Input and Focus
## Parity": "focus restoration MUST verify that the target remains visible,
## enabled, allowed, and valid" -- that verification is the HOST's/control's
## job against the current snapshot; this just remembers the last intent).
func remember_focus(container_id: int, identifier: String) -> void:
	_focus_memory[container_id] = identifier


func recall_focus(container_id: int) -> String:
	return String(_focus_memory.get(container_id, ""))


## Pushes [param container_id] onto the nested-container navigation ancestry
## (inventory-presentation spec, "Nested container is opened": "preserving
## focus and navigation ancestry").
func open_container(container_id: int) -> void:
	_open_container_path.append(container_id)
	model_changed.emit()


## Pops the innermost open container, if any.
func close_container() -> void:
	if _open_container_path.is_empty():
		return
	_open_container_path.pop_back()
	model_changed.emit()


## Removes EVERY occurrence of [param container_id] from the open-container
## navigation ancestry, regardless of its depth/position -- the windowed
## presentation's own per-window close affordance ([InventoryTwoPaneView]'s
## floating open-container window chrome, see that file's header comment)
## needs to close the SPECIFIC window a player dismissed, not merely the
## innermost one [method close_container] always pops. A no-op (no signal)
## if [param container_id] never appeared in the path at all.
func close_container_id(container_id: int) -> void:
	var filtered: Array[int] = []
	var removed := false
	for cid in _open_container_path:
		if cid == container_id:
			removed = true
		else:
			filtered.append(cid)
	if not removed:
		return
	_open_container_path = filtered
	model_changed.emit()


func get_open_container_path() -> Array[int]:
	return _open_container_path.duplicate()


## 0 (invalid) at the top level (no nested container currently open).
func current_container() -> int:
	return _open_container_path.back() if not _open_container_path.is_empty() else 0


# -- Host-reported facts a snapshot alone cannot carry (see file header). --

func set_container_read_only(container_id: int, value: bool) -> void:
	_set_flag(_read_only_containers, container_id, value)


func is_container_read_only(container_id: int) -> bool:
	return _read_only_containers.has(container_id)


func set_item_read_only(item_id: int, value: bool) -> void:
	_set_flag(_read_only_items, item_id, value)


func is_item_read_only(item_id: int) -> bool:
	return _read_only_items.has(item_id)


func set_container_inaccessible(container_id: int, value: bool) -> void:
	_set_flag(_inaccessible_containers, container_id, value)


func set_container_overweight(container_id: int, value: bool) -> void:
	_set_flag(_overweight_containers, container_id, value)


func is_container_overweight(container_id: int) -> bool:
	return _overweight_containers.has(container_id)


func _set_flag(bag: Dictionary, key: int, value: bool) -> void:
	if value:
		bag[key] = true
	else:
		bag.erase(key)


# =============================================================================
# Feedback layer
# =============================================================================

func set_disconnected(value: bool) -> void:
	if _disconnected == value:
		return
	_disconnected = value
	model_changed.emit()


func is_disconnected() -> bool:
	return _disconnected


func set_resynchronizing(value: bool) -> void:
	if _resynchronizing == value:
		return
	_resynchronizing = value
	model_changed.emit()


func is_resynchronizing() -> bool:
	return _resynchronizing


func get_last_rejection() -> Dictionary:
	return _last_rejection.duplicate(true)


## Advances every TTL-bounded feedback/intent entry by [param ticks] (default
## 1), in the host's own frame/tick unit -- see [member default_pending_ttl_ticks].
## Expired pending intents are dropped silently (no rejection feedback: a TTL
## expiry is not an authoritative outcome, just this model giving up on
## waiting for one); expired accepted/rejection/stale-correction markers are
## cleared. The host is expected to call this once per relevant tick from its
## own [code]_process[/code]/[code]_physics_process[/code] -- this class has
## no [Node] of its own to drive it automatically (file header: "scene-free").
func tick(ticks: int = 1) -> void:
	if ticks <= 0:
		return
	var pending_changed_flag := false
	var discovery_pending_changed_flag := false

	for pending_id in _sorted_keys(_pending):
		var pending: Dictionary = _pending[pending_id]
		var remaining := int(pending.get("ttl_remaining", 0)) - ticks
		if remaining <= 0:
			_pending.erase(pending_id)
			pending_changed_flag = true
		else:
			pending["ttl_remaining"] = remaining
			_pending[pending_id] = pending

	for request_id in _sorted_keys(_discovery_pending):
		var discovery_pending: Dictionary = _discovery_pending[request_id]
		var remaining := int(discovery_pending.get("ttl_remaining", 0)) - ticks
		if remaining <= 0:
			_discovery_pending.erase(request_id)
			discovery_pending_changed_flag = true
		else:
			discovery_pending["ttl_remaining"] = remaining
			_discovery_pending[request_id] = discovery_pending

	for item_id in _sorted_keys(_accepted_markers):
		var remaining: int = int(_accepted_markers[item_id]) - ticks
		if remaining <= 0:
			_accepted_markers.erase(item_id)
		else:
			_accepted_markers[item_id] = remaining

	if not _last_rejection.is_empty():
		var remaining: int = int(_last_rejection.get("ttl_remaining", 0)) - ticks
		if remaining <= 0:
			_last_rejection = {}
		else:
			_last_rejection["ttl_remaining"] = remaining

	if not _last_discovery_rejection.is_empty():
		var remaining: int = int(_last_discovery_rejection.get("ttl_remaining", 0)) - ticks
		if remaining <= 0:
			_last_discovery_rejection = {}
		else:
			_last_discovery_rejection["ttl_remaining"] = remaining

	for inventory_id in _sorted_keys(_stale_corrections):
		var entry: Dictionary = _stale_corrections[inventory_id]
		var remaining: int = int(entry.get("ttl_remaining", 0)) - ticks
		if remaining <= 0:
			_stale_corrections.erase(inventory_id)
		else:
			entry["ttl_remaining"] = remaining
			_stale_corrections[inventory_id] = entry

	if pending_changed_flag:
		pending_changed.emit()
	if discovery_pending_changed_flag:
		discovery_pending_changed.emit()
	model_changed.emit()


func _reason_token_for(status: Dictionary) -> StringName:
	var diagnostic := int(status.get("diagnostic", 0))
	if _DIAGNOSTIC_REASON_TOKENS.has(diagnostic):
		return _DIAGNOSTIC_REASON_TOKENS[diagnostic]
	var code := int(status.get("code", -1))
	if _STATUS_REASON_TOKENS.has(code):
		return _STATUS_REASON_TOKENS[code]
	return _DEFAULT_REASON_TOKEN


# =============================================================================
# Derived view-state queries
# =============================================================================

## Resolves ONE DESIGN.md §12 state token for [param item_id] in
## [param inventory_id], by DOCUMENTED PRECEDENCE (highest first):
##
##   disconnected > resynchronizing > redacted > stale-corrected > pending
##   > accepted-flash > rejected > read-only > selected > normal
##
## Rationale:
## - `disconnected`/`resynchronizing` are session-wide facts that make every
##   more specific state below them meaningless (nothing else is trustworthy
##   while either holds), so they always win.
## - `redacted` outranks every remaining state because it means this
##   presentation layer does not actually have the item's real content to
##   render a more specific state for -- there is nothing more specific to
##   show than "hidden".
## - `stale-corrected` > `pending` > `accepted-flash` > `rejected`: the
##   authoritative-command lifecycle, in the order a single command instance
##   naturally passes through it. A just-corrected item must not also flash
##   "pending" for the now-void intent that caused the correction; a fresh
##   accepted-flash must not be masked by a stale rejection notice left over
##   from a different, earlier command that happened to touch the same item.
## - `read-only`/`selected` are pure local view/host state with no
##   authoritative lifecycle of their own, so they always yield to any of the
##   states above, and read-only (a standing restriction) outranks selected
##   (a momentary focus/pick choice) since a read-only item's selection still
##   needs its read-only affordances shown, per DESIGN.md §12.1's read-only
##   row ("small lock glyph on disabled actions only").
## - `normal` is the default when nothing above applies.
func item_state(inventory_id: int, item_id: int) -> StringName:
	if _disconnected:
		return STATE_DISCONNECTED
	if _resynchronizing:
		return STATE_RESYNCHRONIZING
	if _is_item_redacted(inventory_id, item_id):
		return STATE_REDACTED
	if _has_stale_correction(inventory_id, item_id):
		return STATE_STALE_CORRECTED
	if _has_pending_item(inventory_id, item_id):
		return STATE_PENDING
	if _accepted_markers.has(item_id):
		return STATE_ACCEPTED
	if _is_item_rejected(item_id):
		return STATE_REJECTED
	if is_item_read_only(item_id) or is_container_read_only(_item_container_id(inventory_id, item_id)):
		return STATE_READ_ONLY
	if is_selected(inventory_id, item_id):
		return STATE_SELECTED
	return STATE_NORMAL


## Resolves ONE container-scoped state token for [param container_id] in
## [param inventory_id], by documented precedence (highest first):
##
##   disconnected > resynchronizing > loading > inaccessible > redacted
##   > overweight > read-only > empty > normal
##
## "overflow" is deliberately NOT one of the tokens this method can return:
## it is pure viewport-vs-content geometry (does the rendered content exceed
## the control's own visible/scrollable area), which only the rendering
## control itself can compute (this class has no size, layout, or node of its
## own -- file header, "scene-free"). A control renders its own overflow
## affordance directly from its own content/viewport measurement, independent
## of this query.
func container_state(inventory_id: int, container_id: int) -> StringName:
	if _disconnected:
		return STATE_DISCONNECTED
	if _resynchronizing:
		return STATE_RESYNCHRONIZING
	if not has_snapshot(inventory_id):
		return STATE_LOADING
	if _inaccessible_containers.has(container_id) or not is_container_visible(inventory_id, container_id):
		return STATE_INACCESSIBLE
	if _is_container_redacted(inventory_id, container_id):
		return STATE_REDACTED
	if is_container_overweight(container_id):
		return STATE_OVERWEIGHT
	if is_container_read_only(container_id):
		return STATE_READ_ONLY
	if _container_item_count(inventory_id, container_id) == 0:
		return STATE_EMPTY
	return STATE_NORMAL


## True when [param container_id] appears in [param inventory_id]'s current
## snapshot. A container absent from an otherwise-present snapshot means the
## façade's visibility projection removed it entirely (protocol/
## inv_visibility.h's HIDDEN) or it simply does not exist.
func is_container_visible(inventory_id: int, container_id: int) -> bool:
	var snapshot: InventorySnapshotResource = _snapshots.get(inventory_id, null)
	if snapshot == null:
		return false
	for container_variant in snapshot.get_containers():
		if int((container_variant as Dictionary).get("id", -1)) == container_id:
			return true
	return false


func _container_item_count(inventory_id: int, container_id: int) -> int:
	var snapshot: InventorySnapshotResource = _snapshots.get(inventory_id, null)
	if snapshot == null:
		return 0
	var count := 0
	for item_variant in snapshot.get_items():
		var item: Dictionary = item_variant
		var location: Dictionary = item.get("location", {})
		if int(location.get("container", -1)) == container_id:
			count += 1
	return count


## Best-effort heuristic (documented, not exact): a container reads as
## REDACTED when at least one of its direct items carries the placeholder
## [constant REDACTED_ITEM_DEFINITION_IDENTIFIER]. An EMPTY redacted
## container is indistinguishable from an empty ordinary one from snapshot
## content alone (protocol/inv_visibility.h strips identity, it does not tag
## the container record itself) and simply reads as `empty` here instead --
## harmless, since there is nothing to hide in an empty container either way.
func _is_container_redacted(inventory_id: int, container_id: int) -> bool:
	var snapshot: InventorySnapshotResource = _snapshots.get(inventory_id, null)
	if snapshot == null:
		return false
	for item_variant in snapshot.get_items():
		var item: Dictionary = item_variant
		var location: Dictionary = item.get("location", {})
		if int(location.get("container", -1)) != container_id:
			continue
		if String(item.get("item_definition_identifier", "")) == String(REDACTED_ITEM_DEFINITION_IDENTIFIER):
			return true
	return false


func _is_item_redacted(inventory_id: int, item_id: int) -> bool:
	var item := _find_item(inventory_id, item_id)
	if item.is_empty():
		return false
	return String(item.get("item_definition_identifier", "")) == String(REDACTED_ITEM_DEFINITION_IDENTIFIER)


func _has_stale_correction(inventory_id: int, item_id: int) -> bool:
	if not _stale_corrections.has(inventory_id):
		return false
	var entry: Dictionary = _stale_corrections[inventory_id]
	return item_id in (entry.get("items", []) as Array)


func _has_pending_item(inventory_id: int, item_id: int) -> bool:
	for pending_id in _sorted_keys(_pending):
		var pending: Dictionary = _pending[pending_id]
		if int(pending.get("inventory_id", -1)) != inventory_id:
			continue
		if item_id in (pending.get("items", []) as Array):
			return true
	return false


func _is_item_rejected(item_id: int) -> bool:
	if _last_rejection.is_empty():
		return false
	return item_id in (_last_rejection.get("items", []) as Array)


func _item_container_id(inventory_id: int, item_id: int) -> int:
	var item := _find_item(inventory_id, item_id)
	if item.is_empty():
		return -1
	var location: Dictionary = item.get("location", {})
	return int(location.get("container", -1))


func _find_item(inventory_id: int, item_id: int) -> Dictionary:
	var snapshot: InventorySnapshotResource = _snapshots.get(inventory_id, null)
	if snapshot == null:
		return {}
	for item_variant in snapshot.get_items():
		var item: Dictionary = item_variant
		if int(item.get("id", -1)) == item_id:
			return item
	return {}


## Ascending-sorted copy of [param dict]'s keys. Shared helper enforcing this
## file's "iterate dictionaries via sorted keys" determinism rule everywhere
## order could otherwise depend on Godot's Dictionary insertion order.
static func _sorted_keys(dict: Dictionary) -> Array:
	var keys := dict.keys()
	keys.sort()
	return keys
