class_name GameplayCueAdapter
extends Node

## Base class for a logical presentation-cue adapter (task 9.6).
##
## Consumes a [GameplayAbilityComponent]'s [signal GameplayAbilityComponent.effect_cue_triggered]
## and [signal GameplayAbilityComponent.prediction_phase_changed] signals,
## normalizes both into ONE [code]CuePhase[/code]-dispatched call sequence,
## and deduplicates by a stable identity shaped like [code]ga::CueDedupId[/code]
## (native/core/ga_effect_runtime.h) -- so a concrete adapter (see
## [code]runtime/cues/[/code]) never has to reimplement the predict/confirm/
## correct/cancel state machine itself. See [code]runtime/README.md[/code]
## for the full contract; this comment is the short version.
##
## THIS ADDON DOES NOT SHIP A PRESENTATION FRAMEWORK. This base class and the
## four example adapters are a minimal, optional demonstration of the right
## pattern -- a game is free to ignore all of this and read
## [code]effect_cue_triggered[/code]/[code]prediction_phase_changed[/code]
## directly instead.
##
## Contract:
##  - PREDICT opens a new dedup entry and calls [method _on_predicted] --
##    unless that entry already exists (a duplicate PREDICT is ignored, not
##    restarted).
##  - CONFIRM or AUTHORITY_ONLY calls [method _on_confirmed] EXACTLY ONCE per
##    dedup entry, whether or not PREDICT ever fired for it, and even if a
##    duplicate CONFIRM/AUTHORITY_ONLY message arrives later (idempotent;
##    see "Prediction Acknowledgement and Handle Mapping" in
##    specs/gameplay-ability-networking/spec.md).
##  - CORRECT or CANCEL calls [method _on_cancelled] EXACTLY ONCE for a
##    dedup entry that was PREDICTED but not yet CONFIRMED, then forgets it.
##    A CORRECT/CANCEL for an entry that was already confirmed, already
##    cancelled, or never seen at all is a no-op -- there is nothing local
##    left to compensate.
##  - SNAPSHOT_RESTORED NEVER calls [method _on_predicted], [method _on_confirmed],
##    or [method _on_cancelled] -- it is a "this effect is ALREADY ACTIVE,
##    restored from a snapshot" notification, not a new occurrence (see
##    "Late Join, Relevance, and Resynchronization": "does not receive
##    historical one-shot cues"). It calls [method _on_snapshot_restored]
##    at most once per dedup entry.
##
## Subclasses override the four `_on_*` methods below and never touch signal
## wiring, phase numbers, or dedup bookkeeping.

## Path to the [GameplayAbilityComponent] this adapter listens to. Resolved
## in [method _ready]; a concrete adapter may instead call [method attach]
## directly (e.g. from a test, or when the component is created at runtime).
@export var component_path: NodePath

var _component: GameplayAbilityComponent = null

# "predicted" -> PREDICT seen, not yet resolved.
# "resolved"  -> CONFIRM/AUTHORITY_ONLY or CORRECT/CANCEL already delivered
#                exactly once; any further phase for this key is ignored.
var _state: Dictionary = {}
# Separate one-shot tracker for SNAPSHOT_RESTORED so a persistent-state
# notification is not replayed on every subsequent snapshot for the same
# still-active effect.
var _snapshot_seen: Dictionary = {}


func _ready() -> void:
	if component_path.is_empty():
		return
	var node := get_node_or_null(component_path)
	if node is GameplayAbilityComponent:
		attach(node)


## Connects this adapter to [param component]. Safe to call directly instead
## of authoring [member component_path] (e.g. from a test).
func attach(component: GameplayAbilityComponent) -> void:
	if _component == component:
		return
	if _component != null:
		_component.effect_cue_triggered.disconnect(_on_effect_cue_triggered)
		_component.prediction_phase_changed.disconnect(_on_prediction_phase_changed)
	_component = component
	if _component == null:
		return
	_component.effect_cue_triggered.connect(_on_effect_cue_triggered)
	_component.prediction_phase_changed.connect(_on_prediction_phase_changed)


## Forgets every dedup entry. Only meaningful for tests or a deliberate full
## teardown -- normal operation never needs this since every entry already
## resolves itself exactly once.
func reset() -> void:
	_state.clear()
	_snapshot_seen.clear()


# --- Overridable presentation hooks (subclasses implement these) -----------
#
# Every hook receives the SAME stable dedup key the base class already
# computed and matched phases by, so a subclass never has to re-derive it
# (or risk deriving it differently for the same occurrence).

## A predicted (not-yet-confirmed) occurrence started. Reversible
## presentation may start speculatively here.
func _on_predicted(_key: String, _payload: Dictionary) -> void:
	pass


## The occurrence is authoritative -- confirmed (matched a predicted one) or
## authority-only (never predicted at all). Irreversible presentation must
## wait for this call.
func _on_confirmed(_key: String, _payload: Dictionary) -> void:
	pass


## A previously predicted occurrence was rejected or corrected. Reversible
## presentation started in [method _on_predicted] must be undone here.
func _on_cancelled(_key: String, _payload: Dictionary) -> void:
	pass


## Persistent, already-active state observed via a late-join/resync
## snapshot -- NOT a new occurrence. Override to reflect ongoing state (e.g.
## show a persistent buff icon) without replaying a one-shot effect.
func _on_snapshot_restored(_key: String, _payload: Dictionary) -> void:
	pass


# --- Signal plumbing + dedup state machine ----------------------------------

func _on_effect_cue_triggered(cue: Dictionary) -> void:
	_dispatch(_dedup_key_for_cue(cue), int(cue.get("phase", GameplayAbilityComponent.CUE_AUTHORITY_ONLY)), cue)


func _on_prediction_phase_changed(payload: Dictionary) -> void:
	_dispatch(_dedup_key_for_prediction(payload), int(payload.get("phase", GameplayAbilityComponent.CUE_PREDICT)), payload)


func _dispatch(key: String, phase: int, payload: Dictionary) -> void:
	match phase:
		GameplayAbilityComponent.CUE_PREDICT:
			if _state.has(key):
				return # already predicted, or already resolved -- never restart.
			_state[key] = "predicted"
			_on_predicted(key, payload)

		GameplayAbilityComponent.CUE_CONFIRM, GameplayAbilityComponent.CUE_AUTHORITY_ONLY:
			if _state.get(key, "") == "resolved":
				return # idempotent: a duplicate confirmation never confirms twice.
			_state[key] = "resolved"
			_on_confirmed(key, payload)

		GameplayAbilityComponent.CUE_CORRECT, GameplayAbilityComponent.CUE_CANCEL:
			if _state.get(key, "") != "predicted":
				return # nothing pending to cancel (never predicted, or already resolved).
			_state[key] = "resolved"
			_on_cancelled(key, payload)

		GameplayAbilityComponent.CUE_SNAPSHOT_RESTORED:
			if _snapshot_seen.has(key):
				return
			_snapshot_seen[key] = true
			_on_snapshot_restored(key, payload)

		_:
			pass


## Stable dedup key for an `effect_cue_triggered` payload, matching
## `ga::CueDedupId` (target, definition, handle, occurrence) exactly.
func _dedup_key_for_cue(cue: Dictionary) -> String:
	return "%d:%d:%d:%d" % [
		int(cue.get("target", 0)), int(cue.get("definition", 0)),
		int(cue.get("handle", 0)), int(cue.get("occurrence", 0)),
	]


## Stable dedup key for a `prediction_phase_changed` payload. The documented
## seam shape is `{prediction_key, execution, phase}`
## (see `GameplayAbilityComponent.notify_prediction_phase`'s doc comment);
## `ga_prediction.h`'s `PredictionPresentationEvent` establishes that a
## PREDICT/CONFIRM/CORRECT/CANCEL quadruple for the SAME predicted command
## always shares one `prediction_key` (`dedup.occurrence` holds it,
## `dedup.handle` is always INVALID for these), so `prediction_key` alone is
## already a sufficient, stable dedup identity for this shape. If a future
## wiring layer instead supplies the full `target`/`definition`/`handle`/
## `occurrence` tuple directly, that takes precedence.
func _dedup_key_for_prediction(payload: Dictionary) -> String:
	if payload.has("target") and payload.has("definition"):
		return "%d:%d:%d:%d" % [
			int(payload.get("target", 0)), int(payload.get("definition", 0)),
			int(payload.get("handle", 0)), int(payload.get("occurrence", 0)),
		]
	return "prediction:%d" % int(payload.get("prediction_key", 0))
