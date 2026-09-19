class_name ZClientReplicaStore
extends RefCounted
## Bounded client-only confirmed-state holder. No authority or command execution.

const MAX_CHANNELS: int = 32
const MAX_REVISION: int = 2_147_483_647

var last_error: StringName = &""
var _state_by_channel: Dictionary = {}
var _revision_by_channel: Dictionary = {}

func apply_snapshot(channel: StringName, revision: int, payload: Dictionary) -> bool:
	last_error = &""
	if not ZIdentityRules.is_valid_part(String(channel)):
		return _reject(&"replica_channel_invalid")
	if revision < 0 or revision > MAX_REVISION:
		return _reject(&"replica_revision_out_of_bounds")
	if not ZCanonicalValue.is_bounded(payload):
		return _reject(&"replica_payload_invalid_or_unbounded")
	if not _state_by_channel.has(channel) and _state_by_channel.size() >= MAX_CHANNELS:
		return _reject(&"replica_channel_capacity_full")
	var current := int(_revision_by_channel.get(channel, -1))
	if revision <= current:
		return _reject(&"replica_revision_not_newer")
	_state_by_channel[channel] = payload.duplicate(true)
	_revision_by_channel[channel] = revision
	return true

func state(channel: StringName) -> Dictionary:
	var current := _state_by_channel.get(channel, {})
	return (current as Dictionary).duplicate(true)

func revision(channel: StringName) -> int:
	return int(_revision_by_channel.get(channel, -1))

func channel_count() -> int:
	return _state_by_channel.size()

func clear() -> void:
	_state_by_channel.clear()
	_revision_by_channel.clear()
	last_error = &""

func _reject(code: StringName) -> bool:
	last_error = code
	return false
