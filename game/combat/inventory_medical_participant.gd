class_name InventoryMedicalParticipant
extends MedicalInventoryParticipantPort
## Production medical-item participant over InventoryAuthority reservations.
##
## The caller chooses only `bandage` or `splint`; this port owns the sealed
## item-trait and container-order mapping. A silent successor is never left
## ordinary-callable after an ambiguous failure.

enum Lifecycle { UNBOUND, READY, RECOVERY_REQUIRED, RELEASED }

const MAX_RECORDS: int = 256
const MAX_PENDING: int = 64
const MAX_IDENTIFIER_BYTES: int = 192
const STAGE_HELD: int = 1
const STAGE_COMMITTED: int = 2
const STAGE_RELEASED: int = 3
const STAGE_PUBLISHED: int = 4

var lifecycle: Lifecycle = Lifecycle.UNBOUND
var last_error: StringName = &""

var _owner: RaidInventoryOwner
var _owner_instance_id: int = 0
var _owner_generation: int = 0
var _authority: InventoryAuthority
var _authority_instance_id: int = 0
var _inventory_id: int = 0
var _catalog_fingerprint: int = 0
var _catalog_algorithm: StringName = &""
var _admission: ZSessionAdmission
var _identity_port: ZInventoryIdentityPort
var _native_actor_id: int = 0
var _identity_token: String = ""
var _records: Dictionary = {}
var _transaction_active: bool = false
var _recovery: Dictionary = {}


func configure(
	owner: RaidInventoryOwner,
	admission: ZSessionAdmission,
	identity_port: ZInventoryIdentityPort,
	expected_owner_generation: int
) -> bool:
	last_error = &""
	if lifecycle != Lifecycle.UNBOUND or _transaction_active:
		return _reject_bool(&"medical_inventory_already_configured")
	if owner == null or not is_instance_valid(owner) \
			or expected_owner_generation <= 0 \
			or not owner.is_current_generation(expected_owner_generation):
		return _reject_bool(&"medical_inventory_owner_invalid")
	if admission == null or not admission.is_usable() or identity_port == null:
		return _reject_bool(&"medical_inventory_admission_invalid")
	var admission_copy := admission.snapshot()
	if admission_copy == null:
		return _reject_bool(&"medical_inventory_admission_invalid")
	var authority := owner.raid_authority()
	var inventory_id_value := owner.raid_player_inventory_id
	var catalog := owner.catalog()
	if authority == null or not is_instance_valid(authority) \
			or inventory_id_value <= 0 \
			or not authority.has_inventory(inventory_id_value) \
			or catalog == null or not catalog.is_sealed() \
			or catalog.manifest_fingerprint() == 0:
		return _reject_bool(&"medical_inventory_authority_invalid")
	var expected_catalog := ZerkovInventoryCatalog.build_sealed_catalog()
	if expected_catalog == null \
			or expected_catalog.manifest_fingerprint() != catalog.manifest_fingerprint() \
			or expected_catalog.manifest_algorithm() != catalog.manifest_algorithm():
		return _reject_bool(&"medical_inventory_catalog_mismatch")
	var native_actor := identity_port.native_actor_id(
		admission_copy.session_id, admission_copy.actor_id,
		admission_copy.authority_epoch, admission_copy.generation)
	if native_actor <= 0 or not identity_port.actor_owns_inventory(
			admission_copy.session_id, admission_copy.actor_id,
			inventory_id_value, admission_copy.authority_epoch,
			admission_copy.generation):
		return _reject_bool(&"medical_inventory_actor_mismatch")

	_owner = owner
	_owner_instance_id = owner.get_instance_id()
	_owner_generation = expected_owner_generation
	_authority = authority
	_authority_instance_id = authority.get_instance_id()
	_inventory_id = inventory_id_value
	_catalog_fingerprint = catalog.manifest_fingerprint()
	_catalog_algorithm = catalog.manifest_algorithm()
	_admission = admission_copy
	_identity_port = identity_port
	_native_actor_id = native_actor
	_identity_token = "medical_inventory:%d:%d:%d:%d" % [
		_owner_instance_id, _owner_generation, _authority_instance_id, _inventory_id]
	lifecycle = Lifecycle.READY
	return true


func is_ready() -> bool:
	return lifecycle == Lifecycle.READY and not _transaction_active \
		and _binding_is_current()


func identity_token() -> String:
	return _identity_token if is_ready() else ""


func actor_id() -> String:
	return _admission.actor_id.canonical_key() \
		if _admission != null and _admission.is_usable() else ""


func owner_generation() -> int:
	return _owner_generation


func inventory_id() -> int:
	return _inventory_id


func current_revision() -> int:
	return _authority.inventory_revision(_inventory_id) \
		if _binding_is_current() else -1


func prepare_treatment(
	reservation_id: String,
	treatment: StringName,
	expected_revision: int,
	deadline_tick: int
) -> Dictionary:
	last_error = &""
	if not is_ready():
		return _rejection(&"medical_inventory_not_ready")
	if reservation_id.is_empty() \
			or reservation_id.to_utf8_buffer().size() > MAX_IDENTIFIER_BYTES \
			or expected_revision < 0 or deadline_tick <= 0:
		return _rejection(&"medical_reservation_request_invalid")
	var declaration := ZerkovHealthConsequencePolicy.treatment_declaration(treatment)
	if declaration.is_empty():
		return _rejection(&"medical_treatment_invalid")
	var fingerprint := ZCanonicalValue.sha256({
		"reservation_id": reservation_id,
		"treatment": String(treatment),
		"expected_revision": expected_revision,
		"deadline_tick": deadline_tick,
		"identity_token": _identity_token,
	})
	if fingerprint.is_empty():
		return _rejection(&"medical_reservation_request_invalid")
	if _records.has(reservation_id):
		var existing := _records[reservation_id] as Dictionary
		if String(existing.get("fingerprint", "")) != fingerprint:
			return _latch_recovery(&"medical_reservation_identity_collision", existing)
		var replay := reservation_health(reservation_id)
		replay["replayed"] = true
		return replay
	if _records.size() >= MAX_RECORDS or _pending_count() >= MAX_PENDING:
		return _rejection(&"medical_reservation_capacity_exceeded")
	var snapshot := _authority.snapshot(_inventory_id)
	if snapshot == null or snapshot.get_revision() != expected_revision:
		return _rejection(&"medical_inventory_revision_stale")
	if not _identity_is_current():
		return _rejection(&"medical_inventory_actor_repointed")

	_transaction_active = true
	var native_result: Dictionary = _authority.prepare_quantity_reservation(
		_inventory_id,
		reservation_id,
		String(declaration["required_trait"]),
		_container_priorities(),
		1,
		expected_revision,
		deadline_tick)
	_transaction_active = false
	if not _result_is(native_result, STAGE_HELD, reservation_id, 1):
		return _rejection(&"medical_inventory_prepare_rejected", native_result)
	if not _prepared_lines_match(
			native_result.get("lines", []) as Array,
			snapshot, StringName(declaration["item_identifier"])):
		_transaction_active = true
		var released: Dictionary = _authority.release_quantity_reservation(
			_inventory_id, reservation_id)
		_transaction_active = false
		if not _result_is(released, STAGE_RELEASED, reservation_id, 1):
			return _latch_recovery(
				&"medical_prepare_cleanup_failed", {"prepare": native_result, "release": released})
		return _rejection(&"medical_inventory_prepare_postcondition_failed")
	var record := {
		"fingerprint": fingerprint,
		"reservation_id": reservation_id,
		"treatment": treatment,
		"item_identifier": StringName(declaration["item_identifier"]),
		"required_trait": StringName(declaration["required_trait"]),
		"predecessor_revision": expected_revision,
		"deadline_tick": deadline_tick,
		"stage": STAGE_HELD,
		"lines": (native_result.get("lines", []) as Array).duplicate(true),
	}
	_records[reservation_id] = record
	return _decorate(native_result, MUTATION_NONE, treatment, record)


func reservation_health(reservation_id: String) -> Dictionary:
	if not _binding_is_current() or not _records.has(reservation_id):
		return _rejection(&"medical_reservation_unknown")
	var record := _records[reservation_id] as Dictionary
	var result: Dictionary = _authority.health_quantity_reservation(reservation_id)
	var stage := int(record.get("stage", 0))
	if not _result_is(result, stage, reservation_id, 1):
		return _latch_recovery(&"medical_reservation_health_invalid", {
			"record": record, "health": result})
	return _decorate(
		result, MUTATION_COMMITTED if stage >= STAGE_COMMITTED else MUTATION_NONE,
		StringName(record["treatment"]), record)


func commit_treatment_silent(reservation_id: String) -> Dictionary:
	last_error = &""
	if not is_ready() or not _records.has(reservation_id):
		return _rejection(&"medical_reservation_unknown")
	var record := _records[reservation_id] as Dictionary
	if int(record.get("stage", 0)) != STAGE_HELD:
		return _rejection(&"medical_reservation_stage_invalid")
	var health := reservation_health(reservation_id)
	if not bool(health.get("accepted", false)):
		return health
	_transaction_active = true
	var result: Dictionary = _authority.commit_quantity_reservation_silent(
		_inventory_id, reservation_id)
	_transaction_active = false
	if not _result_is(result, STAGE_COMMITTED, reservation_id, 1) \
			or int(result.get("revision", -1)) \
				!= int(record["predecessor_revision"]) + 1:
		# The native call can fail after crossing its mutation boundary. Its
		# reservation health is the only admissible oracle: a still-held record is
		# cleanly retryable/rollbackable, while an exact committed record proves the
		# successor and lets this idempotent participant continue. Anything else is
		# genuinely ambiguous and permanently fail-stops.
		var observed: Dictionary = _authority.health_quantity_reservation(reservation_id)
		if _result_is(observed, STAGE_HELD, reservation_id, 1) \
				and _authority.inventory_revision(_inventory_id) \
					== int(record["predecessor_revision"]):
			return _rejection(&"medical_inventory_silent_commit_rejected", {
				"mutation_state": MUTATION_NONE,
				"commit": result,
				"health": observed,
			})
		if _result_is(observed, STAGE_COMMITTED, reservation_id, 1) \
				and int(observed.get("revision", -1)) \
					== int(record["predecessor_revision"]) + 1:
			result = observed
		else:
			return _latch_recovery(&"medical_inventory_silent_commit_failed", {
				"record": record, "commit": result, "health": observed})
	record["stage"] = STAGE_COMMITTED
	_records[reservation_id] = record
	return _decorate(result, MUTATION_COMMITTED, StringName(record["treatment"]), record)


func publish_treatment(reservation_id: String) -> Dictionary:
	last_error = &""
	if not is_ready() or not _records.has(reservation_id):
		return _rejection(&"medical_reservation_unknown")
	var record := _records[reservation_id] as Dictionary
	if int(record.get("stage", 0)) != STAGE_COMMITTED:
		return _rejection(&"medical_reservation_stage_invalid")
	_transaction_active = true
	var result: Dictionary = _authority.publish_quantity_reservation(reservation_id)
	_transaction_active = false
	if not _result_is(result, STAGE_PUBLISHED, reservation_id, 1) \
			or int(result.get("revision", -1)) \
				!= int(record["predecessor_revision"]) + 1:
		var observed: Dictionary = _authority.health_quantity_reservation(reservation_id)
		if _result_is(observed, STAGE_COMMITTED, reservation_id, 1) \
				and int(observed.get("revision", -1)) \
					== int(record["predecessor_revision"]) + 1:
			return _rejection(&"medical_inventory_publish_rejected", {
				"mutation_state": MUTATION_COMMITTED,
				"publication": result,
				"health": observed,
			})
		if _result_is(observed, STAGE_PUBLISHED, reservation_id, 1) \
				and int(observed.get("revision", -1)) \
					== int(record["predecessor_revision"]) + 1:
			result = observed
		else:
			return _latch_recovery(&"medical_inventory_publish_failed", {
				"record": record, "publication": result, "health": observed})
	record["stage"] = STAGE_PUBLISHED
	_records[reservation_id] = record
	return _decorate(result, MUTATION_COMMITTED, StringName(record["treatment"]), record)


func rollback_treatment(reservation_id: String) -> Dictionary:
	last_error = &""
	if not _binding_is_current() or not _records.has(reservation_id):
		return _rejection(&"medical_reservation_unknown")
	var record := _records[reservation_id] as Dictionary
	var stage := int(record.get("stage", 0))
	if stage == STAGE_RELEASED:
		return _decorate(
			_authority.health_quantity_reservation(reservation_id),
			MUTATION_NONE, StringName(record["treatment"]), record)
	if stage == STAGE_PUBLISHED:
		return _rejection(&"medical_published_reservation_not_rollbackable", {
			"mutation_state": MUTATION_COMMITTED})
	_transaction_active = true
	var result: Dictionary
	if stage == STAGE_HELD:
		result = _authority.release_quantity_reservation(_inventory_id, reservation_id)
	else:
		result = _authority.rollback_quantity_reservation(_inventory_id, reservation_id)
	_transaction_active = false
	if not _result_is(result, STAGE_RELEASED, reservation_id, 1) \
			or _authority.inventory_revision(_inventory_id) \
				!= int(record["predecessor_revision"]):
		return _latch_recovery(&"medical_inventory_rollback_failed", {
			"record": record, "rollback": result})
	record["stage"] = STAGE_RELEASED
	_records[reservation_id] = record
	return _decorate(result, MUTATION_NONE, StringName(record["treatment"]), record)


func release_treatment(reservation_id: String) -> Dictionary:
	if not _binding_is_current() or not _records.has(reservation_id):
		return _rejection(&"medical_reservation_unknown")
	var record := _records[reservation_id] as Dictionary
	if int(record.get("stage", 0)) != STAGE_HELD:
		return _rejection(&"medical_reservation_stage_invalid")
	return rollback_treatment(reservation_id)


func recovery_details() -> Dictionary:
	return _recovery.duplicate(true)


func clear() -> bool:
	if _transaction_active:
		return _reject_bool(&"medical_inventory_transaction_active")
	var has_unfinished := false
	for record_value in _records.values():
		var stage := int((record_value as Dictionary).get("stage", 0))
		if stage == STAGE_HELD or stage == STAGE_COMMITTED:
			has_unfinished = true
	if has_unfinished and not _owner_proves_scoped_unload():
		return _reject_bool(&"medical_inventory_reservation_active")
	if has_unfinished:
		# Owner teardown synchronously unloads this exact inventory generation.
		# That lifecycle boundary proves a held or unpublished reservation can no
		# longer commit, so recovery may finish without pretending it rolled back.
		for reservation_id in _records.keys():
			var record := _records[reservation_id] as Dictionary
			if int(record.get("stage", 0)) == STAGE_HELD \
					or int(record.get("stage", 0)) == STAGE_COMMITTED:
				record["stage"] = STAGE_RELEASED
				_records[reservation_id] = record
		_recovery["resolved_by_owner_teardown"] = true
	_owner = null
	_owner_instance_id = 0
	_owner_generation = 0
	_authority = null
	_authority_instance_id = 0
	_inventory_id = 0
	_catalog_fingerprint = 0
	_catalog_algorithm = &""
	_admission = null
	_identity_port = null
	_native_actor_id = 0
	_identity_token = ""
	_records.clear()
	lifecycle = Lifecycle.RELEASED
	return true


func _prepared_lines_match(
	lines: Array,
	snapshot: InventorySnapshotResource,
	expected_item_identifier: StringName
) -> bool:
	if lines.is_empty() or snapshot == null:
		return false
	var items: Dictionary = {}
	for item_value in snapshot.get_items():
		var item := item_value as Dictionary
		items[int(item.get("id", 0))] = item
	var containers: Dictionary = {}
	for container_value in snapshot.get_containers():
		var container := container_value as Dictionary
		containers[int(container.get("id", 0))] = StringName(
			container.get("container_definition_identifier", &""))
	var total := 0
	for line_value in lines:
		var line := line_value as Dictionary
		var item_id := int(line.get("item", 0))
		var quantity := int(line.get("quantity", 0))
		var item := items.get(item_id, {}) as Dictionary
		var location := item.get("location", {}) as Dictionary
		if item.is_empty() or quantity <= 0 \
				or int(item.get("quantity", 0)) < quantity \
				or StringName(item.get("item_definition_identifier", &"")) \
					!= expected_item_identifier \
				or not ZerkovHealthConsequencePolicy.MEDICAL_CONTAINER_PRIORITY.has(
					containers.get(int(location.get("container", 0)), &"")):
			return false
		total += quantity
	return total == 1


func _result_is(
	result: Dictionary,
	stage: int,
	reservation_id: String,
	quantity: int
) -> bool:
	return bool(result.get("accepted", false)) \
		and int(result.get("stage", -1)) == stage \
		and String(result.get("reservation_id", "")) == reservation_id \
		and int(result.get("inventory_id", 0)) == _inventory_id \
		and int(result.get("quantity", -1)) == quantity


func _decorate(
	result: Dictionary,
	mutation_state: StringName,
	treatment: StringName,
	record: Dictionary
) -> Dictionary:
	var decorated := result.duplicate(true)
	decorated["reason"] = &""
	decorated["mutation_state"] = mutation_state
	decorated["treatment"] = treatment
	decorated["item_identifier"] = record.get("item_identifier", &"")
	decorated["predecessor_revision"] = int(record.get("predecessor_revision", -1))
	return decorated


func _container_priorities() -> Array[String]:
	var result: Array[String] = []
	for identifier in ZerkovHealthConsequencePolicy.MEDICAL_CONTAINER_PRIORITY:
		result.append(String(identifier))
	return result


func _pending_count() -> int:
	var result := 0
	for value in _records.values():
		var stage := int((value as Dictionary).get("stage", 0))
		if stage == STAGE_HELD or stage == STAGE_COMMITTED:
			result += 1
	return result


func _identity_is_current() -> bool:
	return _admission != null and _admission.is_usable() \
		and _identity_port != null \
		and _identity_port.native_actor_id(
			_admission.session_id, _admission.actor_id,
			_admission.authority_epoch, _admission.generation) == _native_actor_id \
		and _identity_port.actor_owns_inventory(
			_admission.session_id, _admission.actor_id, _inventory_id,
			_admission.authority_epoch, _admission.generation)


func _binding_is_current() -> bool:
	return _owner != null and is_instance_valid(_owner) \
		and _owner.get_instance_id() == _owner_instance_id \
		and _owner.is_current_generation(_owner_generation) \
		and _owner.raid_authority() == _authority \
		and _owner.raid_player_inventory_id == _inventory_id \
		and _owner.catalog() != null and _owner.catalog().is_sealed() \
		and _owner.catalog().manifest_fingerprint() == _catalog_fingerprint \
		and _owner.catalog().manifest_algorithm() == _catalog_algorithm \
		and _authority != null and is_instance_valid(_authority) \
		and _authority.get_instance_id() == _authority_instance_id \
		and _authority.has_inventory(_inventory_id) \
		and _identity_is_current()


func _owner_proves_scoped_unload() -> bool:
	return _owner != null and is_instance_valid(_owner) \
		and _owner.get_instance_id() == _owner_instance_id \
		and _owner.lifecycle == RaidInventoryOwner.Lifecycle.TORN_DOWN \
		and _owner.generation() != _owner_generation \
		and _owner.raid_player_inventory_id == 0


func _latch_recovery(reason: StringName, details: Dictionary) -> Dictionary:
	lifecycle = Lifecycle.RECOVERY_REQUIRED
	last_error = reason
	_recovery = {
		"reason": reason,
		"details": details.duplicate(true),
		"requires_authoritative_recovery": true,
		"inventory_id": _inventory_id,
		"owner_generation": _owner_generation,
	}
	return _rejection(reason, {
		"mutation_state": MUTATION_AMBIGUOUS,
		"recovery": _recovery,
	})


func _rejection(reason: StringName, details: Dictionary = {}) -> Dictionary:
	var result := {
		"accepted": false,
		"reason": reason,
		"mutation_state": MUTATION_NONE,
	}
	result.merge(details, true)
	return result


func _reject_bool(reason: StringName) -> bool:
	last_error = reason
	return false
