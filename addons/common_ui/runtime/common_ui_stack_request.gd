class_name CommonUIStackRequest
extends RefCounted

## One queued screen-stack mutation.
##
## Requests exist so push, pop, replace, and teardown can be serialized across
## asynchronous transitions: a caller awaits [signal finished] while the layer
## drains its queue one request at a time.

enum Kind {
	PUSH,
	POP,
	REPLACE,
	TEARDOWN,
}

enum Status {
	## The request finished and the stack changed.
	SUCCESS,
	## The request was coalesced or no longer applied; the stack is unchanged.
	CANCELED,
	## The request failed; the stack is unchanged.
	ERROR,
}

signal finished(result: Dictionary)

var kind: Kind = Kind.PUSH
## A PackedScene, an already-instantiated CommonActivatableScreen, or null.
var source: Variant = null
var options: Dictionary = {}
var completed := false
var result: Dictionary = {}


func complete(status: Status, screen: CommonActivatableScreen = null, error: String = "") -> void:
	if completed:
		return
	completed = true
	result = {
		"status": status,
		"screen": screen,
		"error": error,
	}
	finished.emit(result)


## Awaits completion. Returns immediately when the request already finished, so
## a caller can never miss the signal.
func wait() -> Dictionary:
	if completed:
		return result
	return await finished
