class_name ZUIFeatureGateView
extends ZReadOnlyView

## Read-only capability metadata for post-slice UI actions.
##
## A gate is presentation truth, not a service or a mutation channel. Production
## composition receives LOCKED values from ZUIPresentationProvider until the
## owning authority exists. Explicit developer/test fixture contexts may expose
## the same authored action as PROTOTYPE without implying persistence.

enum Status {
	LOCKED,
	PROTOTYPE,
	AVAILABLE,
}

const ACTION_IDS: PackedStringArray = [
	"bunker",
	"crafting",
	"friends",
	"insurance",
	"marketplace",
]

const ACTION_LABELS: Dictionary = {
	"bunker": "Bunker",
	"crafting": "Crafting",
	"friends": "Friends",
	"insurance": "Insurance",
	"marketplace": "Marketplace",
}

var _action_id: StringName = &"":
	set(value):
		if not _sealed_view:
			_action_id = value
var _display_name: String = "":
	set(value):
		if not _sealed_view:
			_display_name = value
var _status: Status = Status.LOCKED:
	set(value):
		if not _sealed_view:
			_status = value
var _gate_reason: StringName = &"":
	set(value):
		if not _sealed_view:
			_gate_reason = value


static func supports_action(action_id: StringName) -> bool:
	return ACTION_IDS.has(String(action_id))


static func label_for(action_id: StringName) -> String:
	return str(ACTION_LABELS.get(String(action_id), ""))


static func locked(
	action_id: StringName,
	gate_reason: StringName = &"ui_feature_service_not_injected",
	p_generation: int = 0,
	p_revision: int = 0,
	p_source_tick: int = 0
) -> ZUIFeatureGateView:
	return _create(action_id, Status.LOCKED, gate_reason, p_generation,
		p_revision, p_source_tick)


static func prototype(
	action_id: StringName,
	gate_reason: StringName = &"ui_feature_fixture_only",
	p_generation: int = 0,
	p_revision: int = 0,
	p_source_tick: int = 0
) -> ZUIFeatureGateView:
	return _create(action_id, Status.PROTOTYPE, gate_reason, p_generation,
		p_revision, p_source_tick)


static func available(
	action_id: StringName,
	p_generation: int,
	p_revision: int,
	p_source_tick: int
) -> ZUIFeatureGateView:
	return _create(action_id, Status.AVAILABLE, &"", p_generation,
		p_revision, p_source_tick)


static func _create(
	action_id: StringName,
	status: Status,
	gate_reason: StringName,
	p_generation: int,
	p_revision: int,
	p_source_tick: int
) -> ZUIFeatureGateView:
	if not supports_action(action_id):
		return null
	if not ZReadOnlyView.enum_value_is_valid(int(status), Status.size()):
		return null
	if status != Status.AVAILABLE and gate_reason.is_empty():
		return null
	if status == Status.AVAILABLE and not gate_reason.is_empty():
		return null
	var result := ZUIFeatureGateView.new()
	result._action_id = action_id
	result._display_name = label_for(action_id)
	result._status = status
	result._gate_reason = gate_reason
	var sync_state := ZReadOnlyView.SyncState.READY \
			if status == Status.AVAILABLE else ZReadOnlyView.SyncState.UNBOUND
	if not result._initialize_view(p_generation, p_revision, p_source_tick,
			sync_state, gate_reason):
		return null
	return result


func _ready_payload_is_valid() -> bool:
	return supports_action(_action_id) and not _display_name.is_empty() \
			and _status == Status.AVAILABLE and _gate_reason.is_empty()


func action_id() -> StringName:
	return _action_id


func display_name() -> String:
	return _display_name


func status() -> Status:
	return _status


func status_name() -> StringName:
	match _status:
		Status.PROTOTYPE:
			return &"prototype"
		Status.AVAILABLE:
			return &"available"
		_:
			return &"locked"


func gate_reason() -> StringName:
	return _gate_reason


func is_locked() -> bool:
	return _status == Status.LOCKED


func is_prototype() -> bool:
	return _status == Status.PROTOTYPE


func is_available() -> bool:
	return _status == Status.AVAILABLE and is_ready()


func status_label() -> String:
	match _status:
		Status.PROTOTYPE:
			return "PROTOTYPE ONLY"
		Status.AVAILABLE:
			return "AVAILABLE"
		_:
			return "LOCKED"


func snapshot() -> ZUIFeatureGateView:
	match _status:
		Status.PROTOTYPE:
			return prototype(_action_id, _gate_reason, _generation, _revision,
				_source_tick)
		Status.AVAILABLE:
			return available(_action_id, _generation, _revision, _source_tick)
		_:
			return locked(_action_id, _gate_reason, _generation, _revision,
				_source_tick)
