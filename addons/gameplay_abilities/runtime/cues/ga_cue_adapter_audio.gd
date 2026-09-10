class_name GameplayCueAdapterAudio
extends GameplayCueAdapter

## Minimal audio cue-adapter example (task 9.6): IRREVERSIBLE presentation.
##
## A one-shot sound cannot be un-played, so -- exactly like the VFX example
## -- this adapter does nothing on PREDICT and only plays on
## CONFIRM/AUTHORITY_ONLY. CANCEL/CORRECT is a no-op by construction.
##
## Minimal demonstration, not a framework: [member stream] is optional. If
## unset (e.g. a headless test with no audio assets), this adapter still
## runs its full confirm-gated bookkeeping and emits [signal audio_played]
## instead of producing sound.

## Optional stream to play on confirmation. May be left null.
@export var stream: AudioStream
@export var bus: StringName = &"Master"

var _player: AudioStreamPlayer
## Bounded count of plays this adapter has performed, useful for tests.
var play_count: int = 0

signal audio_played(key: String)


func _ready() -> void:
	super._ready()
	if stream != null:
		_player = AudioStreamPlayer.new()
		_player.bus = bus
		add_child(_player)


func _on_confirmed(key: String, _payload: Dictionary) -> void:
	play_count += 1
	if _player != null and stream != null:
		_player.stream = stream
		_player.play()
	audio_played.emit(key)

# _on_predicted/_on_cancelled are intentionally left at the base class's
# no-op default: PREDICT and CANCEL/CORRECT never touch presentation here.
