@tool
class_name CommonActivatableScreen
extends Control

## A screen that can become routing-active on a [CommonUILayer].
##
## Games extend this to add visual and game-specific behaviour by overriding the
## documented hooks. The hooks run inside the layer's stack transaction and
## cannot bypass the final activation-state update the runtime performs, so
## routing state stays authoritative in the native runtime.

## Emitted after the screen became routing-active.
signal activated
## Emitted after the screen stopped being routing-active.
signal deactivated

enum State {
	INACTIVE,
	ACTIVATING,
	ACTIVE,
	DEACTIVATING,
}

## Context pushed while this screen is active. Empty means the screen adds no
## context of its own.
@export var screen_context: StringName = &""
## Priority of [member screen_context] relative to other active contexts.
@export var context_priority: int = 0
## Suspends every lower context while this screen is active, which is what a
## modal normally wants.
@export var suspends_lower_contexts: bool = false
## Control focused when the screen activates and nothing was remembered.
@export var default_focus: NodePath
## Hides the screen instead of freeing it when it is popped.
@export var keep_alive_when_popped: bool = false
## When true, this screen registers [constant CommonUIDefaults.BACK] on
## activation (scoped to its own context, like any other registration) and pops
## itself off its owning layer on press, consuming the input. Off by default so
## existing screens keep their current behaviour; a screen with its own Back
## handling (a dialog, a screen that intercepts Back for a nested state) should
## leave this false and register its own handler instead.
@export var handles_back: bool = false

var state: State = State.INACTIVE:
	set(value):
		state = value

## Set by the owning layer.
var layer_id: StringName = &"":
	set(value):
		layer_id = value

var _context_handle: CommonUIContextHandle = null
var _suspended_handles: Array[CommonUIContextHandle] = []
var _action_handles: Array[CommonUIActionHandle] = []
var _remembered_focus: NodePath = NodePath()
## Focus trap (modals only): the last focus owner seen inside this screen, and a
## re-entrancy guard used while pulling focus back in.
var _focus_trap_target: Control = null
var _returning_focus := false
## Snapshot of every trapped control's navigation paths, taken by
## [method _contain_focus_navigation] and restored by
## [method _restore_focus_navigation] so a modal's containment never outlives
## the trap and author-configured neighbours always come back exactly as set.
var _nav_snapshot: Dictionary = {}
## True for the duration of [method _on_deactivating] when this deactivation
## covers the screen (kept in its layer's stack, still visible behind the one
## above it) rather than popping it off entirely. [CommonAnimatedScreen] reads
## this to skip its exit animation and stay fully shown while covered.
var _deactivation_covered := false
## Monotonic token for an activation coroutine. Cancellation increments it so
## an awaiting hook cannot finish later and put the screen back into ACTIVE.
var _activation_generation := 0


func _get_runtime() -> CommonUIRuntime:
	# An absolute path is only resolvable while inside the tree; nodes that are
	# tearing down must not try to reach the autoload.
	if Engine.is_editor_hint() or not is_inside_tree():
		return null
	var runtime := get_node_or_null(^"/root/CommonUI")
	return runtime as CommonUIRuntime


func is_routing_active() -> bool:
	return state == State.ACTIVE


## The context this screen pushed while active, or null. A modal uses these to
## suspend the screens beneath it.
func get_context_handle() -> CommonUIContextHandle:
	return _context_handle


# --- Lifecycle hooks -------------------------------------------------------
#
# Override these in a game screen. `_on_activating` and `_on_deactivating` may
# await; the layer will not start another stack mutation until they return.

func _on_activating() -> void:
	pass


func _on_activated() -> void:
	pass


func _on_deactivating() -> void:
	pass


func _on_deactivated() -> void:
	pass


# --- Action registration ---------------------------------------------------

## Registers an action scoped to this screen. The registration is released when
## the screen deactivates, and the runtime drops it safely if this node is freed
## first.
func register_action(action: StringName, callback: Callable, options: Dictionary = {}) -> CommonUIActionHandle:
	var runtime := _get_runtime()
	if runtime == null:
		return null
	var merged := options.duplicate()
	merged["owner"] = self
	merged["screen"] = self
	merged["layer"] = layer_id
	if not merged.has("context") and not String(screen_context).is_empty():
		merged["context"] = screen_context
	var handle := runtime.register_action(action, callback, merged)
	if handle != null:
		_action_handles.append(handle)
	return handle


func release_actions() -> void:
	for handle in _action_handles:
		if handle != null:
			handle.release()
	_action_handles.clear()


## Wired in [method activate] when [member handles_back] is true. Pops this
## screen off its owning layer and consumes the press either way, so a screen
## further down never sees the same event.
func _on_handles_back_press(event: Dictionary) -> int:
	if event["phase"] != CommonUIRuntime.PHASE_PRESSED:
		return CommonUIRuntime.ROUTE_UNHANDLED
	var layer := get_parent() as CommonUILayer
	if layer != null:
		layer.pop_screen()
	return CommonUIRuntime.ROUTE_HANDLED


# --- Activation, driven by the owning layer --------------------------------

## Runs the activation transaction. Returns false when the screen left the tree
## before activation completed, in which case it is never left registered as
## routing-active.
func activate() -> bool:
	if state == State.ACTIVE or state == State.ACTIVATING:
		return state == State.ACTIVE
	_activation_generation += 1
	var activation_generation := _activation_generation
	state = State.ACTIVATING
	visible = true
	# Re-enable focus on this screen's controls; it may have been covered before.
	_restore_child_focus()

	# A modal must lock input the moment it starts opening, not after its intro
	# animation: otherwise an input pressed while it is still animating in would
	# reach the screen beneath. Suspend the lower contexts and take focus now, so
	# neither framework routing nor a focused control below can act during the
	# transition. The modal's own context and action handlers still come online
	# only once activation completes, so it cannot route early either.
	_suspend_lower_contexts()
	if suspends_lower_contexts:
		# Wire the modal's controls to navigate among themselves so left/right/Tab
		# move between them, then trap focus before taking it so directional
		# navigation can never spatially escape to a screen beneath and the very
		# first grab is recorded.
		_contain_focus_navigation()
		_connect_focus_trap()
		restore_focus()
		# Layout-dependent, so it has to wait a beat; see the method doc comment.
		_pin_spatial_neighbors.call_deferred()

	await _on_activating()
	if activation_generation != _activation_generation:
		return false
	if not is_inside_tree() or state != State.ACTIVATING:
		# Activation was abandoned mid-animation; undo the early lock.
		_disconnect_focus_trap()
		_restore_focus_navigation()
		_resume_lower_contexts()
		state = State.INACTIVE
		return false

	_push_own_context()
	state = State.ACTIVE
	restore_focus()
	if handles_back:
		register_action(CommonUIDefaults.BACK, _on_handles_back_press)
	_on_activated()
	activated.emit()
	return true


## Runs the deactivation transaction. Safe to call on an already-inactive
## screen. [param covered] is true when this screen stays in its layer's stack,
## covered by another screen pushed above it, rather than being popped off
## entirely: [CommonAnimatedScreen] reads [member _deactivation_covered] during
## [method _on_deactivating] to skip its exit animation and stay fully shown in
## that case, since a covered screen must remain visible behind the one above it.
func deactivate(covered: bool = false) -> void:
	if state == State.INACTIVE or state == State.DEACTIVATING:
		return
	state = State.DEACTIVATING
	_disconnect_focus_trap()
	_restore_focus_navigation()
	_remember_focus()
	# A deactivated screen usually stays in its layer's stack, visible behind the
	# screen above it. Disable focus on its controls so the screen on top cannot
	# leak focus onto them via directional navigation.
	_disable_child_focus()

	# Release this screen's actions and pop its context now, before the exit
	# animation runs -- symmetric with activate()'s early lock. Otherwise the
	# screen would stay routable for the whole fade-out, and a destructive
	# confirmation could fire a second time from a second press during the
	# animation. A re-activation that lands mid-fade-out (the screen is raised
	# to the top again before this deactivation's await returns) re-registers
	# through _on_activated's own register_action calls, so nothing here needs
	# to survive past this point.
	release_actions()
	_pop_context()

	_deactivation_covered = covered
	await _on_deactivating()
	_deactivation_covered = false

	state = State.INACTIVE
	if is_inside_tree():
		_on_deactivated()
		deactivated.emit()


## Cancels an in-flight activation, for example because the tree is being torn
## down. The screen must not remain routing-active afterwards.
func cancel_activation() -> void:
	if state == State.INACTIVE:
		return
	_activation_generation += 1
	_disconnect_focus_trap()
	_restore_focus_navigation()
	release_actions()
	_pop_context()
	state = State.INACTIVE


## Suspends the contexts a modal covers. Called at the start of activation so the
## lock is in place before the intro animation, not after it.
func _suspend_lower_contexts() -> void:
	if not suspends_lower_contexts:
		return
	var runtime := _get_runtime()
	if runtime == null or String(screen_context).is_empty():
		return
	# Suspending keeps each lower context's stack position, so resuming restores
	# the original ordering without re-registering handlers.
	_suspended_handles = _collect_lower_contexts()
	for handle in _suspended_handles:
		handle.set_suspended(true)


## Pushes this screen's own context once activation has completed, so a control
## registered during the transition cannot route before the screen is active.
func _push_own_context() -> void:
	var runtime := _get_runtime()
	if runtime == null or String(screen_context).is_empty():
		return
	_context_handle = runtime.push_context(screen_context, context_priority, 0)


func _resume_lower_contexts() -> void:
	for handle in _suspended_handles:
		if handle != null and handle.is_active():
			handle.set_suspended(false)
	_suspended_handles.clear()


func _pop_context() -> void:
	if _context_handle != null:
		_context_handle.release()
		_context_handle = null
	_resume_lower_contexts()


## Contexts a modal should suspend. Games may override to keep a persistent
## context, such as a debug overlay, alive beneath a modal.
func _collect_lower_contexts() -> Array[CommonUIContextHandle]:
	return []


# --- Focus -----------------------------------------------------------------

func _remember_focus() -> void:
	var focused := get_viewport().gui_get_focus_owner() if is_inside_tree() else null
	if focused != null and is_ancestor_of(focused):
		_remembered_focus = get_path_to(focused)
	# A focus owner outside this screen is not ours to remember.


## Focuses the remembered control, then the default target, then the first
## eligible descendant. Every candidate is verified to be inside this screen,
## visible, enabled, focusable, and still valid before it is used.
##
## Public so an owning layer can ask the screen to re-place focus after a screen
## on a higher layer closed.
func restore_focus() -> void:
	if not is_inside_tree():
		return
	for path in [_remembered_focus, default_focus]:
		var candidate := _eligible_control(path)
		if candidate != null:
			candidate.grab_focus()
			return
	var fallback := _first_focusable(self)
	if fallback != null:
		fallback.grab_focus()


# --- Focus trap ------------------------------------------------------------
#
# A modal suspends action routing beneath it, but Godot's built-in focus
# navigation (ui_left / ui_right / ui_up / ui_down / Tab) still searches every
# focusable control in the viewport and would happily move focus onto a button
# on a screen behind the modal. While a modal is the active, unsuspended screen,
# this trap keeps focus inside its own subtree.

func _connect_focus_trap() -> void:
	if not is_inside_tree():
		return
	var viewport := get_viewport()
	if viewport != null and not viewport.gui_focus_changed.is_connected(_on_gui_focus_changed):
		viewport.gui_focus_changed.connect(_on_gui_focus_changed)


func _disconnect_focus_trap() -> void:
	if not is_inside_tree():
		return
	var viewport := get_viewport()
	if viewport != null and viewport.gui_focus_changed.is_connected(_on_gui_focus_changed):
		viewport.gui_focus_changed.disconnect(_on_gui_focus_changed)
	_focus_trap_target = null


## True while this modal owns focus, i.e. it is opening or open and not itself
## suspended by a modal above it (whose own trap then takes over).
func _focus_trap_active() -> bool:
	if not suspends_lower_contexts:
		return false
	if state != State.ACTIVATING and state != State.ACTIVE:
		return false
	return _context_handle == null or not _context_handle.is_suspended()


func _on_gui_focus_changed(control: Control) -> void:
	if _returning_focus or not _focus_trap_active():
		return
	if control != null and (control == self or is_ancestor_of(control)):
		# Focus is inside the modal; remember where so an escape snaps back here.
		_focus_trap_target = control
		return
	# Focus escaped the modal (or was cleared): pull it back in.
	_returning_focus = true
	if _focus_trap_target != null and is_instance_valid(_focus_trap_target) \
			and is_ancestor_of(_focus_trap_target) and _is_focusable(_focus_trap_target):
		_focus_trap_target.grab_focus()
	else:
		restore_focus()
	_returning_focus = false


## Snapshots every trapped control's navigation paths, then rewrites only what
## would let focus escape the modal -- never the whole set. Godot's directional
## neighbours ([member Control.focus_neighbor_left] etc.) resolve spatially when
## left empty, which is exactly what a hand-laid-out grid or row of controls
## needs to navigate correctly; overwriting every path with flat tree-order
## cycling (the previous approach) broke that and discarded any neighbour an
## author configured, permanently, since it was never restored.
##
## What actually changes:
## - An explicit path (author-set, or left over from a previous trap) that
##   still resolves to a control inside this modal is left completely alone.
## - An explicit path that resolves outside the modal is redirected back to the
##   control itself, so it cannot be used to walk out.
## - An empty path is left empty here, but is a candidate for
##   [method _pin_spatial_neighbors] once layout has actually settled (see
##   there for why leaving it to Godot's own live spatial search is not enough
##   on its own).
##
## [method _restore_focus_navigation] undoes exactly this rewrite when the trap
## is disengaged, so a screen's authored navigation is intact the next time it
## activates, whether or not it was ever trapped in between.
func _contain_focus_navigation() -> void:
	var controls := _focusable_controls(self)
	if controls.size() < 2:
		return
	var control_set := {}
	for control in controls:
		control_set[control] = true

	_nav_snapshot.clear()
	for control in controls:
		_nav_snapshot[control] = {
			"next": control.focus_next,
			"previous": control.focus_previous,
			"right": control.focus_neighbor_right,
			"bottom": control.focus_neighbor_bottom,
			"left": control.focus_neighbor_left,
			"top": control.focus_neighbor_top,
		}

	for control in controls:
		control.focus_next = _contained_path(control, control.focus_next, control_set)
		control.focus_previous = _contained_path(control, control.focus_previous, control_set)
		control.focus_neighbor_right = _contained_path(control, control.focus_neighbor_right, control_set)
		control.focus_neighbor_bottom = _contained_path(control, control.focus_neighbor_bottom, control_set)
		control.focus_neighbor_left = _contained_path(control, control.focus_neighbor_left, control_set)
		control.focus_neighbor_top = _contained_path(control, control.focus_neighbor_top, control_set)


## `path` unchanged when empty, or when it already names a control in
## `control_set`. An explicit path naming a control outside the set is
## redirected back to `control` itself so it cannot be used to leave the modal.
func _contained_path(control: Control, path: NodePath, control_set: Dictionary) -> NodePath:
	if path.is_empty():
		return path
	var target := control.get_node_or_null(path) as Control
	if target != null and control_set.has(target):
		return path
	return control.get_path_to(control)


## Restores exactly what [method _contain_focus_navigation] snapshotted, so a
## modal's containment never leaks past the trap it belonged to.
func _restore_focus_navigation() -> void:
	if _nav_snapshot.is_empty():
		return
	for control in _nav_snapshot:
		if is_instance_valid(control):
			var snapshot: Dictionary = _nav_snapshot[control]
			control.focus_next = snapshot["next"]
			control.focus_previous = snapshot["previous"]
			control.focus_neighbor_right = snapshot["right"]
			control.focus_neighbor_bottom = snapshot["bottom"]
			control.focus_neighbor_left = snapshot["left"]
			control.focus_neighbor_top = snapshot["top"]
	_nav_snapshot.clear()


## Deferred follow-up to [method _contain_focus_navigation], for every
## direction it left empty. Godot's own spatial search for an empty
## [member Control.focus_neighbor_right] (etc.) runs against the *whole
## viewport*, not just this modal -- so an unrelated control elsewhere on
## screen (a HUD button pinned to a corner, say) can beat a control's true
## in-modal neighbour on Godot's own distance heuristic even though
## [method _on_gui_focus_changed] always undoes the resulting escape. Undoing
## it lands back on the source control, not the correct neighbour, which is
## not "the grid navigates correctly" even though it never actually leaves the
## modal. This instead computes each trapped control's nearest neighbour using
## ONLY this modal's own controls, by real geometry, and pins it explicitly
## wherever a direction is still empty and a modal-local answer exists; a
## direction with no candidate in it (a true edge/corner) is left empty, which
## is the geometrically correct "nothing to move to" rather than a synthetic
## wrap.
##
## Deferred because layout -- the positions this depends on -- is itself
## computed on a deferred pass (Container sizing/sorting is not synchronous
## with add_child), so calling this from [method activate] directly would see
## stale or zero-sized rects for freshly added content such as a fresh
## GridContainer's children.
func _pin_spatial_neighbors() -> void:
	if not is_instance_valid(self) or not is_inside_tree() or not _focus_trap_active():
		return
	var controls: Array[Control] = []
	for control in _nav_snapshot:
		if is_instance_valid(control):
			controls.append(control)
	if controls.size() < 2:
		return
	var directions := {
		"focus_neighbor_right": Vector2.RIGHT,
		"focus_neighbor_bottom": Vector2.DOWN,
		"focus_neighbor_left": Vector2.LEFT,
		"focus_neighbor_top": Vector2.UP,
	}
	for control in controls:
		if not control.is_inside_tree():
			continue
		for property in directions:
			if not (control.get(property) as NodePath).is_empty():
				continue
			var target := _nearest_in_direction(control, controls, directions[property])
			if target != null and target.is_inside_tree():
				control.set(property, control.get_path_to(target))


## The control in `candidates` that lies most directly in `direction` from
## `from`, weighting how far off-axis a candidate is more heavily than raw
## distance so a row/column reads as "the next one over" instead of jumping to
## a closer diagonal neighbour. Null when nothing lies in that direction at all.
func _nearest_in_direction(from: Control, candidates: Array[Control], direction: Vector2) -> Control:
	var origin := from.get_global_rect().get_center()
	var best: Control = null
	var best_score := INF
	for candidate in candidates:
		if candidate == from or not is_instance_valid(candidate):
			continue
		var delta := candidate.get_global_rect().get_center() - origin
		var forward := delta.dot(direction)
		if forward <= 0.5:
			continue
		var lateral := (delta - direction * forward).length()
		var score := lateral * 4.0 + forward
		if score < best_score:
			best_score = score
			best = candidate
	return best


# --- Covered-screen focus -------------------------------------------------
#
# A screen that is deactivated but kept in its layer's stack stays in the tree,
# visible behind the screen above it. Its controls must stop being focus targets
# while covered, or the screen on top leaks focus onto them.

## Original focus mode of each control disabled while this screen is covered.
var _disabled_focus_modes: Dictionary = {}


func _disable_child_focus() -> void:
	if not _disabled_focus_modes.is_empty():
		return
	for control in _focusable_controls(self):
		_disabled_focus_modes[control] = control.focus_mode
		control.focus_mode = Control.FOCUS_NONE


func _restore_child_focus() -> void:
	for control in _disabled_focus_modes:
		if is_instance_valid(control):
			control.focus_mode = _disabled_focus_modes[control]
	_disabled_focus_modes.clear()


## Focusable descendant controls, in scene-tree (tab) order.
func _focusable_controls(root: Node) -> Array[Control]:
	var result: Array[Control] = []
	for child in root.get_children():
		var control := child as Control
		if control != null and _is_focusable(control):
			result.append(control)
		result.append_array(_focusable_controls(child))
	return result


func _eligible_control(path: NodePath) -> Control:
	if path.is_empty():
		return null
	var node := get_node_or_null(path)
	var control := node as Control
	if control == null or not is_instance_valid(control):
		return null
	if not is_ancestor_of(control) and control != self:
		return null
	return control if _is_focusable(control) else null


func _is_focusable(control: Control) -> bool:
	if not control.is_visible_in_tree():
		return false
	if control.focus_mode == Control.FOCUS_NONE:
		return false
	# Disabled BaseButtons cannot take focus even with a focus mode set.
	if control is BaseButton and control.disabled:
		return false
	return true


## Deterministic fallback: the first focusable control in scene-tree order.
func _first_focusable(root: Node) -> Control:
	for child in root.get_children():
		var control := child as Control
		if control != null and _is_focusable(control):
			return control
		var nested := _first_focusable(child)
		if nested != null:
			return nested
	return null


func _exit_tree() -> void:
	if state != State.INACTIVE:
		cancel_activation()
