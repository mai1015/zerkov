@tool
class_name CommonAnimatedScreen
extends CommonActivatableScreen

## A [CommonActivatableScreen] that fades, slides, or scales itself in and out.
##
## The base screen exposes async [method CommonActivatableScreen._on_activating]
## and [method CommonActivatableScreen._on_deactivating] hooks that the owning
## [CommonUILayer] awaits before it starts the next stack mutation. This subclass
## fills those hooks with a tween so opening, closing, replacing, and swapping a
## screen animate, while the layer still observes a fully settled state when the
## transaction completes.
##
## A game screen can extend this instead of [CommonActivatableScreen] and pick a
## transition in the inspector, or override [method _on_activating] /
## [method _on_deactivating] itself for something bespoke. [CommonDialog] extends
## it so the shipped modal animates out of the box.
##
## [b]Layout note:[/b] the tween animates [member Control.modulate],
## [member Control.scale], and [member Control.position]. A screen added directly
## to a layer (as the stack does) is free of container-driven layout, so these
## are safe to drive. A screen parented under a [Container] would have its
## position reset every frame; animate a child of the screen in that case.

enum Transition {
	## No animation; the screen appears and disappears instantly.
	NONE,
	## Cross-fades [member Control.modulate] alpha.
	FADE,
	## Fades and scales from [member scale_from] to full size (a modal "pop").
	SCALE,
	## Slides in from / out to the left edge of the viewport.
	SLIDE_LEFT,
	## Slides in from / out to the right edge of the viewport.
	SLIDE_RIGHT,
	## Slides in from / out to the top edge of the viewport.
	SLIDE_UP,
	## Slides in from / out to the bottom edge of the viewport.
	SLIDE_DOWN,
}

## Animation played while the screen activates.
@export var enter_transition: Transition = Transition.FADE
## Animation played while the screen deactivates. A screen with the same enter
## and exit transition reverses the motion on close.
@export var exit_transition: Transition = Transition.FADE
## Duration of a single transition, in seconds. Zero or less means instant.
@export var duration: float = 0.16
## Starting scale for [constant Transition.SCALE]. 1.0 disables the scale part.
@export_range(0.0, 1.0, 0.01) var scale_from: float = 0.92
## Tween interpolation curve.
@export var transition_curve: Tween.TransitionType = Tween.TRANS_CUBIC
## Tween easing direction.
@export var easing: Tween.EaseType = Tween.EASE_OUT
## Master switch for this screen. When false the screen shows and hides instantly
## regardless of the transitions above.
@export var animations_enabled: bool = true

## Resting layout position, captured when a transition starts so slides return to
## exactly where the layout placed the screen.
var _base_position: Vector2 = Vector2.ZERO


# --- Activation hooks ------------------------------------------------------

func _on_activating() -> void:
	if not _should_animate(enter_transition):
		_apply_shown_state()
		return
	# The layout pass has already placed the screen, so its current position is
	# the resting target the enter animation moves toward.
	_base_position = position
	pivot_offset = size * 0.5

	# Start off in the transition's "outside" state, then tween to fully shown.
	modulate.a = _alpha_for(enter_transition)
	scale = _scale_for(enter_transition)
	position = _base_position + _slide_offset(enter_transition)

	await _play(_tween_to(1.0, Vector2.ONE, _base_position))
	_apply_shown_state()


func _on_deactivating() -> void:
	if _deactivation_covered:
		# A covered screen stays in its layer's stack, visible behind the screen
		# above it -- skip the exit animation entirely and make sure it is left
		# in its fully shown state rather than wherever an in-flight transition
		# left it (the default exit transition is FADE, which would otherwise
		# leave it at modulate.a == 0.0, i.e. invisible, while still "covered").
		_base_position = position
		_apply_shown_state()
		return
	if not _should_animate(exit_transition):
		return
	# Capture the resting position now: enter may have used NONE, so
	# `_base_position` from a prior activate cannot be trusted here.
	_base_position = position
	pivot_offset = size * 0.5

	var target_alpha := _alpha_for(exit_transition)
	var target_scale := _scale_for(exit_transition)
	var target_position := _base_position + _slide_offset(exit_transition)
	await _play(_tween_to(target_alpha, target_scale, target_position))


# --- Tween construction ----------------------------------------------------

func _tween_to(target_alpha: float, target_scale: Vector2, target_position: Vector2) -> Tween:
	var tween := create_tween().set_parallel(true)
	# The default TWEEN_PAUSE_BOUND freezes the tween whenever the bound node
	# does not process while SceneTree.paused is true. A pause menu is the
	# flagship use case for this screen type, so the tween must keep stepping
	# regardless of pause state or the bound node's process_mode -- otherwise
	# _play's poll loop below never observes is_running() go false and the
	# owning layer's stack drain hangs forever. This holds even for a screen
	# embedded outside CommonUIScreenRoot / CommonUILayer, which otherwise make
	# a screen pause-immune via process_mode.
	tween.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	tween.set_ease(easing).set_trans(transition_curve)
	# Tweening all three every time keeps the code branch-free; a property already
	# at its target simply holds still.
	tween.tween_property(self, "modulate:a", target_alpha, duration)
	tween.tween_property(self, "scale", target_scale, duration)
	tween.tween_property(self, "position", target_position, duration)
	return tween


## Awaits the tween without ever hanging the owning layer's stack drain.
##
## A tween bound to this node is killed silently when the node leaves the tree,
## and a killed tween never emits [signal Tween.finished] -- awaiting that signal
## directly would stall [method CommonActivatableScreen.deactivate] forever.
## Polling the frame instead lets teardown end the wait the moment the node is
## gone. [method Control.is_inside_tree] is re-checked before every
## [member SceneTree.process_frame] await so [method Node.get_tree] is never
## called on a freed node.
##
## [member SceneTree.process_frame] itself is emitted every frame regardless of
## [member SceneTree.paused], so this loop always wakes up; the only way it
## could spin forever is the tween itself never advancing while paused, which
## [method _tween_to] rules out via [constant Tween.TWEEN_PAUSE_PROCESS].
func _play(tween: Tween) -> void:
	if tween == null or not is_inside_tree():
		return
	# One frame lets the tween begin stepping so is_running() reflects reality
	# rather than its not-yet-started value.
	await get_tree().process_frame
	while is_inside_tree() and tween.is_valid() and tween.is_running():
		await get_tree().process_frame


# --- Per-transition target math --------------------------------------------

func _alpha_for(transition: Transition) -> float:
	# FADE and SCALE start (or end) transparent; slides keep full opacity.
	return 0.0 if transition == Transition.FADE or transition == Transition.SCALE else 1.0


func _scale_for(transition: Transition) -> Vector2:
	return Vector2.ONE * scale_from if transition == Transition.SCALE else Vector2.ONE


## Offset from the resting position to the transition's off-screen anchor. The
## viewport dimension is used so the screen leaves the frame completely.
func _slide_offset(transition: Transition) -> Vector2:
	var viewport := get_viewport_rect().size
	match transition:
		Transition.SLIDE_LEFT:
			return Vector2(-viewport.x, 0.0)
		Transition.SLIDE_RIGHT:
			return Vector2(viewport.x, 0.0)
		Transition.SLIDE_UP:
			return Vector2(0.0, -viewport.y)
		Transition.SLIDE_DOWN:
			return Vector2(0.0, viewport.y)
		_:
			return Vector2.ZERO


func _apply_shown_state() -> void:
	modulate.a = 1.0
	scale = Vector2.ONE
	position = _base_position


func _should_animate(transition: Transition) -> bool:
	if Engine.is_editor_hint():
		return false
	if not animations_enabled or transition == Transition.NONE or duration <= 0.0:
		return false
	if not is_inside_tree():
		return false
	# Project-wide kill switch, e.g. for a reduced-motion accessibility option.
	# Consumers set it via ProjectSettings; absent, animations stay on.
	if ProjectSettings.get_setting("common_ui/disable_screen_animations", false):
		return false
	return true
