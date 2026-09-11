class_name TaskView
extends ZReadOnlyView
## Read-only task list and objective projection.

enum Status {
	AVAILABLE,
	ACTIVE,
	COMPLETED,
	FAILED,
	LOCKED,
	FEATURE_GATED,
}

enum RewardKind {
	ITEM,
	CURRENCY,
	EXPERIENCE,
	REPUTATION,
}

class Objective extends RefCounted:
	var _sealed: bool = false:
		set(value):
			if not _sealed:
				_sealed = value

	func _seal_record() -> void:
		_sealed = true

	var _objective_id: StringName = &"":
		set(value):
			if not _sealed:
				_objective_id = value
	var _description: String = "":
		set(value):
			if not _sealed:
				_description = value
	var _current: int = 0:
		set(value):
			if not _sealed:
				_current = value
	var _target: int = 0:
		set(value):
			if not _sealed:
				_target = value
	var _optional: bool = false:
		set(value):
			if not _sealed:
				_optional = value

	static func create(
		p_objective_id: StringName,
		p_description: String,
		p_current: int,
		p_target: int,
		p_optional: bool = false
	) -> Objective:
		if p_objective_id.is_empty() or p_description.is_empty() \
				or p_current < 0 or p_target <= 0 or p_current > p_target:
			return null
		var result := Objective.new()
		result._objective_id = p_objective_id
		result._description = p_description
		result._current = p_current
		result._target = p_target
		result._optional = p_optional
		result._seal_record()
		return result

	func objective_id() -> StringName:
		return _objective_id

	func description() -> String:
		return _description

	func current() -> int:
		return _current

	func target() -> int:
		return _target

	func is_complete() -> bool:
		return _current == _target

	func is_optional() -> bool:
		return _optional

	func snapshot() -> Objective:
		return create(_objective_id, _description, _current, _target, _optional)

class Reward extends RefCounted:
	var _sealed: bool = false:
		set(value):
			if not _sealed:
				_sealed = value

	func _seal_record() -> void:
		_sealed = true

	var _reward_id: StringName = &"":
		set(value):
			if not _sealed:
				_reward_id = value
	var _kind: RewardKind = RewardKind.ITEM:
		set(value):
			if not _sealed:
				_kind = value
	var _content_id: StringName = &"":
		set(value):
			if not _sealed:
				_content_id = value
	var _display_name: String = "":
		set(value):
			if not _sealed:
				_display_name = value
	var _amount: int = 0:
		set(value):
			if not _sealed:
				_amount = value

	static func create(
		p_reward_id: StringName,
		p_kind: RewardKind,
		p_content_id: StringName,
		p_display_name: String,
		p_amount: int
	) -> Reward:
		if p_reward_id.is_empty() or not ZReadOnlyView.content_id_is_valid(p_content_id) \
				or p_display_name.is_empty() or p_amount <= 0:
			return null
		if not ZReadOnlyView.enum_value_is_valid(int(p_kind), RewardKind.size()):
			return null
		var result := Reward.new()
		result._reward_id = p_reward_id
		result._kind = p_kind
		result._content_id = p_content_id
		result._display_name = p_display_name
		result._amount = p_amount
		result._seal_record()
		return result

	func reward_id() -> StringName:
		return _reward_id

	func kind() -> RewardKind:
		return _kind

	func content_id() -> StringName:
		return _content_id

	func display_name() -> String:
		return _display_name

	func amount() -> int:
		return _amount

	func snapshot() -> Reward:
		return create(_reward_id, _kind, _content_id, _display_name, _amount)

class Entry extends RefCounted:
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
	var _description: String = "":
		set(value):
			if not _sealed:
				_description = value
	var _trader_name: String = "":
		set(value):
			if not _sealed:
				_trader_name = value
	var _zone_id: StringName = &"":
		set(value):
			if not _sealed:
				_zone_id = value
	var _status: Status = Status.AVAILABLE:
		set(value):
			if not _sealed:
				_status = value
	var _tracked: bool = false:
		set(value):
			if not _sealed:
				_tracked = value
	var _objectives: Array[Objective] = []:
		set(value):
			if not _sealed:
				_objectives = value
	var _rewards: Array[Reward] = []:
		set(value):
			if not _sealed:
				_rewards = value
	var _gate_reason: StringName = &"":
		set(value):
			if not _sealed:
				_gate_reason = value

	static func create(
		p_task_id: ZTaskId,
		p_title: String,
		p_description: String,
		p_trader_name: String,
		p_zone_id: StringName,
		p_status: Status,
		p_tracked: bool,
		p_objectives: Array[Objective],
		p_rewards: Array[Reward],
		p_gate_reason: StringName = &""
	) -> Entry:
		if p_task_id == null or not p_task_id.is_initialized() or p_title.is_empty() \
				or p_description.is_empty() or p_trader_name.is_empty() \
				or not ZReadOnlyView.content_id_is_valid(p_zone_id):
			return null
		if not ZReadOnlyView.enum_value_is_valid(int(p_status), Status.size()):
			return null
		if (p_status == Status.LOCKED or p_status == Status.FEATURE_GATED) \
				and p_gate_reason.is_empty():
			return null
		var objective_ids: Dictionary = {}
		for objective in p_objectives:
			if objective == null or objective_ids.has(objective.objective_id()):
				return null
			objective_ids[objective.objective_id()] = true
		var reward_ids: Dictionary = {}
		for reward in p_rewards:
			if reward == null or reward_ids.has(reward.reward_id()):
				return null
			reward_ids[reward.reward_id()] = true
		var result := Entry.new()
		result._task_key = p_task_id.canonical_key()
		result._title = p_title
		result._description = p_description
		result._trader_name = p_trader_name
		result._zone_id = p_zone_id
		result._status = p_status
		result._tracked = p_tracked
		result._gate_reason = p_gate_reason
		for objective in p_objectives:
			result._objectives.append(objective.snapshot())
		for reward in p_rewards:
			result._rewards.append(reward.snapshot())
		result._objectives.make_read_only()
		result._rewards.make_read_only()
		result._seal_record()
		return result

	func task_id() -> ZTaskId:
		return ZTaskId.parse(_task_key)

	func title() -> String:
		return _title

	func description() -> String:
		return _description

	func trader_name() -> String:
		return _trader_name

	func zone_id() -> StringName:
		return _zone_id

	func status() -> Status:
		return _status

	func is_tracked() -> bool:
		return _tracked

	func gate_reason() -> StringName:
		return _gate_reason

	func objectives() -> Array[Objective]:
		var result: Array[Objective] = []
		for objective in _objectives:
			result.append(objective.snapshot())
		result.make_read_only()
		return result

	func rewards() -> Array[Reward]:
		var result: Array[Reward] = []
		for reward in _rewards:
			result.append(reward.snapshot())
		result.make_read_only()
		return result

	func snapshot() -> Entry:
		return create(task_id(), _title, _description, _trader_name, _zone_id,
			_status, _tracked, objectives(), rewards(), _gate_reason)

var _scope_id: StringName = &"":
	set(value):
		if not _sealed_view:
			_scope_id = value
var _tasks: Array[Entry] = []:
	set(value):
		if not _sealed_view:
			_tasks = value
var _selected_task_key: String = "":
	set(value):
		if not _sealed_view:
			_selected_task_key = value


static func create(
	p_generation: int,
	p_revision: int,
	p_source_tick: int,
	p_tasks: Array[Entry],
	p_selected_task_id: ZTaskId = null,
	p_scope_id: StringName = &"zerkov.task_scope.profile"
) -> TaskView:
	if not content_id_is_valid(p_scope_id):
		return null
	var task_ids: Dictionary = {}
	for task in p_tasks:
		if task == null:
			return null
		var key := task.task_id().canonical_key()
		if task_ids.has(key):
			return null
		task_ids[key] = true
	if p_selected_task_id != null and not task_ids.has(p_selected_task_id.canonical_key()):
		return null
	var result := TaskView.new()
	result._scope_id = p_scope_id
	for task in p_tasks:
		result._tasks.append(task.snapshot())
	result._tasks.make_read_only()
	result._selected_task_key = p_selected_task_id.canonical_key() \
		if p_selected_task_id != null else ""
	if not result._initialize_view(p_generation, p_revision, p_source_tick, SyncState.READY):
		return null
	return result


static func unavailable(
	p_sync_state: SyncState,
	p_diagnostic: StringName,
	p_generation: int = 0,
	p_revision: int = 0,
	p_source_tick: int = 0,
	p_selected_task_id: ZTaskId = null,
	p_scope_id: StringName = &""
) -> TaskView:
	if p_sync_state == SyncState.READY:
		return null
	if sync_state_requires_subject(p_sync_state) and not content_id_is_valid(p_scope_id):
		return null
	var result := TaskView.new()
	result._scope_id = p_scope_id
	result._selected_task_key = p_selected_task_id.canonical_key() \
		if p_selected_task_id != null and p_selected_task_id.is_initialized() else ""
	return result if result._initialize_view(
		p_generation, p_revision, p_source_tick, p_sync_state, p_diagnostic) else null


func tasks() -> Array[Entry]:
	var result: Array[Entry] = []
	for task in _tasks:
		result.append(task.snapshot())
	result.make_read_only()
	return result


func scope_id() -> StringName:
	return _scope_id


func selected_task_id() -> ZTaskId:
	return ZTaskId.parse(_selected_task_key) if not _selected_task_key.is_empty() else null


func _ready_payload_is_valid() -> bool:
	if not content_id_is_valid(_scope_id):
		return false
	var ids: Dictionary = {}
	for task in _tasks:
		if task == null or task.snapshot() == null:
			return false
		var key := task.task_id().canonical_key()
		if ids.has(key):
			return false
		ids[key] = true
	return _selected_task_key.is_empty() or ids.has(_selected_task_key)
