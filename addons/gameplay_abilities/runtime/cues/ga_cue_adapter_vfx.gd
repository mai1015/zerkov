class_name GameplayCueAdapterVfx
extends GameplayCueAdapter

## Minimal VFX cue-adapter example (task 9.6): IRREVERSIBLE presentation.
##
## A spawned particle burst cannot be un-spawned, so this adapter does
## nothing on PREDICT and waits for CONFIRM/AUTHORITY_ONLY before ever
## instantiating anything. CANCEL/CORRECT is a no-op by construction: since
## nothing was created on PREDICT, there is nothing to undo.
##
## Minimal demonstration, not a framework: [member vfx_scene] is optional.
## If unset (e.g. a headless test with no scene assets), this adapter still
## runs its full confirm-gated bookkeeping and emits [signal vfx_spawned]
## instead of instantiating anything.

## Optional scene to instantiate on confirmation. May be left null.
@export var vfx_scene: PackedScene
## Parent new instances are added under. Defaults to this adapter's own
## parent when null.
@export var spawn_parent: Node

## Bounded count of spawns this adapter has performed, useful for tests.
var spawn_count: int = 0

signal vfx_spawned(key: String)


func _on_confirmed(key: String, _payload: Dictionary) -> void:
	spawn_count += 1
	if vfx_scene != null:
		var instance: Node = vfx_scene.instantiate()
		var parent := spawn_parent if spawn_parent != null else get_parent()
		if parent != null:
			parent.add_child(instance)
		else:
			instance.queue_free() # nowhere to attach it -- avoid leaking the instance.
	vfx_spawned.emit(key)

# _on_predicted/_on_cancelled are intentionally left at the base class's
# no-op default: PREDICT and CANCEL/CORRECT never touch presentation here.
