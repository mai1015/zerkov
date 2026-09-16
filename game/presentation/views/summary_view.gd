class_name SummaryView
extends ZReadOnlyView
## Immutable raid-summary projection derived from a committed settlement receipt.

enum Outcome {
	EXTRACTED,
	DIED,
	FAILED,
}

enum LootDisposition {
	RETAINED,
	LOST,
	REWARDED,
}

class LootLine extends RefCounted:
	var _sealed: bool = false:
		set(value):
			if not _sealed:
				_sealed = value

	func _seal_record() -> void:
		_sealed = true

	var _content_id: StringName = &"":
		set(value):
			if not _sealed:
				_content_id = value
	var _display_name: String = "":
		set(value):
			if not _sealed:
				_display_name = value
	var _quantity: int = 0:
		set(value):
			if not _sealed:
				_quantity = value
	var _unit_value: int = 0:
		set(value):
			if not _sealed:
				_unit_value = value
	var _disposition: LootDisposition = LootDisposition.LOST:
		set(value):
			if not _sealed:
				_disposition = value

	static func create(
		p_content_id: StringName,
		p_display_name: String,
		p_quantity: int,
		p_unit_value: int,
		p_disposition: LootDisposition
	) -> LootLine:
		if not ZReadOnlyView.content_id_is_valid(p_content_id) or p_display_name.is_empty() \
				or p_quantity <= 0 or p_unit_value < 0:
			return null
		if not ZReadOnlyView.enum_value_is_valid(int(p_disposition), LootDisposition.size()):
			return null
		var result := LootLine.new()
		result._content_id = p_content_id
		result._display_name = p_display_name
		result._quantity = p_quantity
		result._unit_value = p_unit_value
		result._disposition = p_disposition
		result._seal_record()
		return result

	func content_id() -> StringName:
		return _content_id

	func display_name() -> String:
		return _display_name

	func quantity() -> int:
		return _quantity

	func unit_value() -> int:
		return _unit_value

	func total_value() -> int:
		return _quantity * _unit_value

	func disposition() -> LootDisposition:
		return _disposition

	func snapshot() -> LootLine:
		return create(_content_id, _display_name, _quantity, _unit_value, _disposition)

class TaskResult extends RefCounted:
	var _sealed: bool = false:
		set(value):
			if not _sealed:
				_sealed = value

	func _seal_record() -> void:
		_sealed = true

	var _task_key: String = "":
		set(value):
			if not _sealed:
				_task_key = value
	var _title: String = "":
		set(value):
			if not _sealed:
				_title = value
	var _completed_objectives: int = 0:
		set(value):
			if not _sealed:
				_completed_objectives = value
	var _total_objectives: int = 0:
		set(value):
			if not _sealed:
				_total_objectives = value
	var _completed: bool = false:
		set(value):
			if not _sealed:
				_completed = value
	var _reward_value: int = 0:
		set(value):
			if not _sealed:
				_reward_value = value

	static func create(
		p_task_id: ZTaskId,
		p_title: String,
		p_completed_objectives: int,
		p_total_objectives: int,
		p_completed: bool,
		p_reward_value: int
	) -> TaskResult:
		if p_task_id == null or not p_task_id.is_initialized() or p_title.is_empty() \
				or p_completed_objectives < 0 or p_total_objectives < p_completed_objectives \
				or p_total_objectives <= 0 or p_reward_value < 0:
			return null
		if p_completed and p_completed_objectives != p_total_objectives:
			return null
		var result := TaskResult.new()
		result._task_key = p_task_id.canonical_key()
		result._title = p_title
		result._completed_objectives = p_completed_objectives
		result._total_objectives = p_total_objectives
		result._completed = p_completed
		result._reward_value = p_reward_value
		result._seal_record()
		return result

	func task_id() -> ZTaskId:
		return ZTaskId.parse(_task_key)

	func title() -> String:
		return _title

	func completed_objectives() -> int:
		return _completed_objectives

	func total_objectives() -> int:
		return _total_objectives

	func is_completed() -> bool:
		return _completed

	func reward_value() -> int:
		return _reward_value

	func snapshot() -> TaskResult:
		return create(task_id(), _title, _completed_objectives,
			_total_objectives, _completed, _reward_value)

class Correction extends RefCounted:
	var _sealed: bool = false:
		set(value):
			if not _sealed:
				_sealed = value

	func _seal_record() -> void:
		_sealed = true

	var _correction_key: String = "":
		set(value):
			if not _sealed:
				_correction_key = value
	var _code: StringName = &"":
		set(value):
			if not _sealed:
				_code = value
	var _description: String = "":
		set(value):
			if not _sealed:
				_description = value

	static func create(
		p_correction_id: ZConsequenceId,
		p_code: StringName,
		p_description: String
	) -> Correction:
		if p_correction_id == null or not p_correction_id.is_initialized() \
				or p_code.is_empty() or p_description.is_empty():
			return null
		var result := Correction.new()
		result._correction_key = p_correction_id.canonical_key()
		result._code = p_code
		result._description = p_description
		result._seal_record()
		return result

	func correction_id() -> ZConsequenceId:
		return ZConsequenceId.parse(_correction_key)

	func code() -> StringName:
		return _code

	func description() -> String:
		return _description

	func snapshot() -> Correction:
		return create(correction_id(), _code, _description)

var _raid_key: String = "":
	set(value):
		if not _sealed_view:
			_raid_key = value
var _settlement_key: String = "":
	set(value):
		if not _sealed_view:
			_settlement_key = value
var _outcome: Outcome = Outcome.FAILED:
	set(value):
		if not _sealed_view:
			_outcome = value
var _duration_ticks: int = 0:
	set(value):
		if not _sealed_view:
			_duration_ticks = value
var _kill_count: int = 0:
	set(value):
		if not _sealed_view:
			_kill_count = value
var _damage_dealt: int = 0:
	set(value):
		if not _sealed_view:
			_damage_dealt = value
var _damage_taken: int = 0:
	set(value):
		if not _sealed_view:
			_damage_taken = value
var _injuries: Array[StringName] = []:
	set(value):
		if not _sealed_view:
			_injuries = value
var _loot: Array[LootLine] = []:
	set(value):
		if not _sealed_view:
			_loot = value
var _task_results: Array[TaskResult] = []:
	set(value):
		if not _sealed_view:
			_task_results = value
var _reward_value: int = 0:
	set(value):
		if not _sealed_view:
			_reward_value = value
var _loss_value: int = 0:
	set(value):
		if not _sealed_view:
			_loss_value = value
var _audit_digest: String = "":
	set(value):
		if not _sealed_view:
			_audit_digest = value
var _audit_available: bool = true:
	set(value):
		if not _sealed_view:
			_audit_available = value
var _valuation_available: bool = true:
	set(value):
		if not _sealed_view:
			_valuation_available = value
var _corrections: Array[Correction] = []:
	set(value):
		if not _sealed_view:
			_corrections = value


static func create(
	p_generation: int,
	p_revision: int,
	p_source_tick: int,
	p_raid_id: ZRaidId,
	p_settlement_id: ZSettlementId,
	p_outcome: Outcome,
	p_duration_ticks: int,
	p_kill_count: int,
	p_damage_dealt: int,
	p_damage_taken: int,
	p_injuries: Array[StringName],
	p_loot: Array[LootLine],
	p_task_results: Array[TaskResult],
	p_reward_value: int,
	p_loss_value: int,
	p_audit_digest: String,
	p_corrections: Array[Correction],
	p_audit_available: bool = true,
	p_valuation_available: bool = true
) -> SummaryView:
	if p_raid_id == null or not p_raid_id.is_initialized() \
			or p_settlement_id == null or not p_settlement_id.is_initialized():
		return null
	if p_duration_ticks < 0 or p_kill_count < 0 or p_damage_dealt < 0 \
			or p_damage_taken < 0 or p_reward_value < 0 or p_loss_value < 0 \
			or (p_audit_available and not _digest_is_valid(p_audit_digest)) \
			or (not p_audit_available and not p_audit_digest.is_empty() and not _digest_is_valid(p_audit_digest)):
		return null
	if not enum_value_is_valid(int(p_outcome), Outcome.size()):
		return null
	for injury in p_injuries:
		if not content_id_is_valid(injury):
			return null
	var staged_loot: Array[LootLine] = []
	for line in p_loot:
		if line == null or not line._sealed:
			return null
		var staged_line := line.snapshot()
		if staged_line == null:
			return null
		staged_loot.append(staged_line)
	var staged_task_results: Array[TaskResult] = []
	var task_ids: Dictionary = {}
	for task_result in p_task_results:
		if task_result == null or not task_result._sealed:
			return null
		var staged_task_result := task_result.snapshot()
		if staged_task_result == null:
			return null
		var task_key := staged_task_result.task_id().canonical_key()
		if task_ids.has(task_key):
			return null
		task_ids[task_key] = true
		staged_task_results.append(staged_task_result)
	var staged_corrections: Array[Correction] = []
	var correction_ids: Dictionary = {}
	for correction in p_corrections:
		if correction == null or not correction._sealed:
			return null
		var staged_correction := correction.snapshot()
		if staged_correction == null:
			return null
		var correction_key := staged_correction.correction_id().canonical_key()
		if correction_ids.has(correction_key):
			return null
		correction_ids[correction_key] = true
		staged_corrections.append(staged_correction)
	var result := SummaryView.new()
	result._raid_key = p_raid_id.canonical_key()
	result._settlement_key = p_settlement_id.canonical_key()
	result._outcome = p_outcome
	result._duration_ticks = p_duration_ticks
	result._kill_count = p_kill_count
	result._damage_dealt = p_damage_dealt
	result._damage_taken = p_damage_taken
	result._injuries = read_only_string_names(p_injuries)
	result._loot.assign(staged_loot)
	result._task_results.assign(staged_task_results)
	result._corrections.assign(staged_corrections)
	result._loot.make_read_only()
	result._task_results.make_read_only()
	result._corrections.make_read_only()
	result._reward_value = p_reward_value
	result._loss_value = p_loss_value
	result._audit_digest = p_audit_digest.to_lower()
	result._audit_available = p_audit_available
	result._valuation_available = p_valuation_available
	if not result._initialize_view(p_generation, p_revision, p_source_tick, SyncState.READY):
		return null
	return result


static func unavailable(
	p_sync_state: SyncState,
	p_diagnostic: StringName,
	p_generation: int = 0,
	p_revision: int = 0,
	p_source_tick: int = 0,
	p_raid_id: ZRaidId = null,
	p_settlement_id: ZSettlementId = null
) -> SummaryView:
	if p_sync_state == SyncState.READY:
		return null
	if sync_state_requires_subject(p_sync_state) and (p_raid_id == null \
			or not p_raid_id.is_initialized() or p_settlement_id == null \
			or not p_settlement_id.is_initialized()):
		return null
	var result := SummaryView.new()
	result._raid_key = p_raid_id.canonical_key() if p_raid_id != null else ""
	result._settlement_key = p_settlement_id.canonical_key() \
		if p_settlement_id != null else ""
	return result if result._initialize_view(
		p_generation, p_revision, p_source_tick, p_sync_state, p_diagnostic) else null


static func _digest_is_valid(value: String) -> bool:
	if value.length() != 64:
		return false
	for index in value.length():
		var code := value.to_lower().unicode_at(index)
		if not (code >= 48 and code <= 57) and not (code >= 97 and code <= 102):
			return false
	return true


func raid_id() -> ZRaidId:
	return ZRaidId.parse(_raid_key) if not _raid_key.is_empty() else null


func settlement_id() -> ZSettlementId:
	return ZSettlementId.parse(_settlement_key) if not _settlement_key.is_empty() else null


func _ready_payload_is_valid() -> bool:
	if raid_id() == null or settlement_id() == null or (_audit_available and not _digest_is_valid(_audit_digest)) \
			or (not _audit_available and not _audit_digest.is_empty() and not _digest_is_valid(_audit_digest)) \
			or not enum_value_is_valid(int(_outcome), Outcome.size()) \
			or _duration_ticks < 0 or _kill_count < 0 or _damage_dealt < 0 \
			or _damage_taken < 0 or _reward_value < 0 or _loss_value < 0:
		return false
	for injury in _injuries:
		if not content_id_is_valid(injury):
			return false
	for line in _loot:
		if line == null or not line._sealed or line.snapshot() == null:
			return false
	var task_ids: Dictionary = {}
	for task_result in _task_results:
		if task_result == null or not task_result._sealed or task_result.snapshot() == null:
			return false
		var task_key := task_result.task_id().canonical_key()
		if task_ids.has(task_key):
			return false
		task_ids[task_key] = true
	var correction_ids: Dictionary = {}
	for correction in _corrections:
		if correction == null or not correction._sealed or correction.snapshot() == null:
			return false
		var correction_key := correction.correction_id().canonical_key()
		if correction_ids.has(correction_key):
			return false
		correction_ids[correction_key] = true
	return true


func outcome() -> Outcome:
	return _outcome


func duration_ticks() -> int:
	return _duration_ticks


func kill_count() -> int:
	return _kill_count


func damage_dealt() -> int:
	return _damage_dealt


func damage_taken() -> int:
	return _damage_taken


func injuries() -> Array[StringName]:
	return read_only_string_names(_injuries)


func loot() -> Array[LootLine]:
	var result: Array[LootLine] = []
	for line in _loot:
		result.append(line.snapshot())
	result.make_read_only()
	return result


func task_results() -> Array[TaskResult]:
	var result: Array[TaskResult] = []
	for task_result in _task_results:
		result.append(task_result.snapshot())
	result.make_read_only()
	return result


func reward_value() -> int:
	return _reward_value


func loss_value() -> int:
	return _loss_value


func loot_value() -> int:
	var total := 0
	for line in _loot:
		total += line.total_value()
	return total


func audit_digest() -> String:
	return _audit_digest


func corrections() -> Array[Correction]:
	var result: Array[Correction] = []
	for correction in _corrections:
		result.append(correction.snapshot())
	result.make_read_only()
	return result


func audit_available() -> bool:
	return _audit_available


func valuation_available() -> bool:
	return _valuation_available
