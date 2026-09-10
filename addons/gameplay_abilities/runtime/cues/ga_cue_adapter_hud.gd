class_name GameplayCueAdapterHud
extends GameplayCueAdapter

## Minimal HUD cue-adapter example (task 9.6): REVERSIBLE presentation.
##
## A HUD indicator (e.g. "Dash ready to fire") is cheap to show speculatively
## and cheap to take back, so it starts on PREDICT and is corrected
## immediately on CANCEL/CORRECT -- unlike the VFX/audio examples, it does
## NOT wait for CONFIRM.
##
## This is a minimal demonstration, not a framework: it tracks state as a
## bounded Dictionary and emits [signal hud_state_changed] rather than
## assuming any concrete Control exists. A game wires that signal (or
## overrides the `_on_*` methods directly) to its own HUD widgets.

## key(String) -> "pending" | "confirmed". A real HUD widget would instead
## show/hide/tint itself directly from [signal hud_state_changed].
var badges: Dictionary = {}

signal hud_state_changed(key: String, state: String)


func _on_predicted(key: String, _payload: Dictionary) -> void:
	badges[key] = "pending"
	hud_state_changed.emit(key, "pending")


func _on_confirmed(key: String, _payload: Dictionary) -> void:
	badges[key] = "confirmed"
	hud_state_changed.emit(key, "confirmed")


func _on_cancelled(key: String, _payload: Dictionary) -> void:
	badges.erase(key)
	hud_state_changed.emit(key, "cancelled")
