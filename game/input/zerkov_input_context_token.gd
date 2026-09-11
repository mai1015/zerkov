class_name ZerkovInputContextToken
extends RefCounted

## Opaque capability for one caller-owned lease on a game-owned CommonUI
## context.
##
## A stale token cannot release a replacement context.  The token exposes only
## detached state and a release operation; callers never receive the native
## context handle or a mutable service entry.

var context_id: StringName = &""
var generation: int = 0
var priority: int = 0
var source: StringName = &""
var capability_id: int = 0
var _owner: WeakRef
var _released: bool = false


func configure(owner: Node, p_context_id: StringName, p_generation: int, p_priority: int, p_source: StringName, p_capability_id: int) -> void:
	_owner = weakref(owner)
	context_id = p_context_id
	generation = p_generation
	priority = p_priority
	source = p_source
	capability_id = p_capability_id
	_released = false


func is_active() -> bool:
	if _released or _owner == null:
		return false
	var owner := _owner.get_ref() as Node
	return owner != null and owner.has_method("is_context_token_active") \
			and bool(owner.is_context_token_active(self))


func is_released() -> bool:
	return _released


func release() -> bool:
	if _released or _owner == null:
		return false
	var owner := _owner.get_ref() as Node
	if owner == null or not owner.has_method("release_context_token"):
		_released = true
		return false
	var released := bool(owner.release_context_token(self))
	if released:
		_released = true
	return released


func _invalidate() -> void:
	_released = true
	_owner = null


func snapshot() -> Dictionary:
	return {
		"context": String(context_id),
		"generation": generation,
		"priority": priority,
		"source": String(source),
		"capability_id": capability_id,
		"active": is_active(),
		"released": _released,
	}
