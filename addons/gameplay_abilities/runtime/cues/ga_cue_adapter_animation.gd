class_name GameplayCueAdapterAnimation
extends GameplayCueAdapter

## Minimal animation cue-adapter example (task 9.6): REVERSIBLE presentation.
##
## Plays a low-committal "anticipation" animation on PREDICT (e.g. a wind-up
## pose), then either the "resolved" animation on CONFIRM/AUTHORITY_ONLY or
## the "revert" animation on CANCEL/CORRECT to visually undo the wind-up.
## This is the reversible counterpart to the VFX/audio examples below, which
## demonstrate the opposite (irreversible, confirm-gated) pattern.
##
## Minimal demonstration, not a framework: [member player] is optional. If
## unset (e.g. in a headless test with no scene assets), this adapter still
## runs its full predict/confirm/cancel bookkeeping and emits
## [signal animation_cue] so a test or a game can observe it without needing
## an actual [AnimationPlayer].

## Optional player to drive. May be left null.
@export var player: AnimationPlayer
@export var anticipation_animation: StringName = &"anticipation"
@export var resolved_animation: StringName = &"resolved"
@export var revert_animation: StringName = &"revert"

signal animation_cue(key: String, animation_name: StringName)


func _on_predicted(key: String, _payload: Dictionary) -> void:
	_play(key, anticipation_animation)


func _on_confirmed(key: String, _payload: Dictionary) -> void:
	_play(key, resolved_animation)


func _on_cancelled(key: String, _payload: Dictionary) -> void:
	_play(key, revert_animation)


func _play(key: String, animation_name: StringName) -> void:
	if player != null and player.has_animation(animation_name):
		player.play(animation_name)
	animation_cue.emit(key, animation_name)
