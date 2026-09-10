@tool
class_name CommonUILayer
extends Control

## One named UI layer with an ordered screen stack.
##
## Only the routing-active top screen of an eligible layer contributes
## screen-scoped actions. Push, pop, replace, and teardown are serialized
## through a request queue, so overlapping asynchronous transitions can never
## leave a screen partially attached, visible, focused, or routing-active.
##
## Requests are coalesced before they run, in exactly two ways, so this stays
## predictable: (1) a PUSH request queued directly behind another still-pending
## (not yet running) PUSH of the exact same [code]source[/code] replaces it --
## the earlier one is dropped and completes [constant CommonUIStackRequest.Status.CANCELED],
## so mashing the same Confirm press during a transition produces exactly one
## new screen instead of one per press; (2) queuing a TEARDOWN cancels every
## other request currently pending (not yet running) with CANCELED, since none
## of them would still apply once the stack is cleared. Nothing else is
## coalesced -- a push followed by an unrelated push, or by a pop, always runs
## in full FIFO order, and a request already being drained (in flight) always
## runs to completion.

signal stack_changed(depth: int)
signal screen_pushed(screen: CommonActivatableScreen)
signal screen_popped(screen: CommonActivatableScreen)

## Identifier used by action registrations and by the native runtime.
@export var layer_id: StringName = &"":
	set(value):
		layer_id = value
		update_configuration_warnings()

## Higher priority layers are evaluated before lower ones.
@export var layer_priority: int = 0

## When false the layer keeps its stack but contributes no actions.
@export var layer_active: bool = true:
	set(value):
		layer_active = value
		if not Engine.is_editor_hint():
			var runtime := _get_runtime()
			if runtime != null and not String(layer_id).is_empty():
				runtime.set_layer_active(layer_id, layer_active, 0)

## When true (the default) this layer and every screen pushed onto it keep
## processing input, GUI events, and animations while [member SceneTree.paused]
## is true. A pause menu is the flagship use case: it must still open, animate,
## and respond to input while it pauses the rest of the game. Turn off for a
## layer whose screens should freeze along with everything else.
@export var pause_immune: bool = true

var _stack: Array[CommonActivatableScreen] = []
var _queue: Array[CommonUIStackRequest] = []
var _draining := false
## Focus owner recorded before the current top screen was pushed, per depth.
## Each entry is {path, screen}: the screen is the fallback when the exact
## control is no longer eligible.
var _focus_memory: Array[Dictionary] = []
## External tree exits are pruned synchronously, then lifecycle recovery is
## serialized behind any in-flight stack transaction. A generation coalesces
## several exits from the same scene-tree teardown into one final recovery.
var _external_recovery_pending := false
var _external_recovery_generation := 0
var _external_recovery_focus: Dictionary = {}


func _get_runtime() -> CommonUIRuntime:
	# An absolute path is only resolvable while inside the tree; nodes that are
	# tearing down must not try to reach the autoload.
	if Engine.is_editor_hint() or not is_inside_tree():
		return null
	var runtime := get_node_or_null(^"/root/CommonUI")
	return runtime as CommonUIRuntime


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	if pause_immune:
		# Screens added as children default to PROCESS_MODE_INHERIT, so this
		# alone is enough for the whole subtree -- controls, tweens, and this
		# layer's own coroutines -- to keep responding while paused.
		process_mode = Node.PROCESS_MODE_ALWAYS
	if String(layer_id).is_empty():
		push_error("CommonUILayer at %s has no layer_id." % get_path())
		return
	var runtime := _get_runtime()
	if runtime != null:
		runtime.configure_layer(layer_id, layer_priority, layer_active, 0)


func _get_configuration_warnings() -> PackedStringArray:
	if String(layer_id).is_empty():
		return PackedStringArray(["layer_id must be set so actions can be scoped to this layer."])
	return PackedStringArray()


# --- Queries ---------------------------------------------------------------

func get_depth() -> int:
	return _stack.size()


func get_top_screen() -> CommonActivatableScreen:
	return _stack.back() if not _stack.is_empty() else null


func has_screen(screen: CommonActivatableScreen) -> bool:
	return _stack.has(screen)


# --- Public transactions ---------------------------------------------------

## Pushes a scene or an existing screen. `source` may be a PackedScene or a
## CommonActivatableScreen.
func push_screen(source: Variant, options: Dictionary = {}) -> Dictionary:
	return await request_push(source, options).wait()


## Pops the top screen. Repeated requests while a pop is already running are
## serialized, so a screen is never removed twice.
func pop_screen(options: Dictionary = {}) -> Dictionary:
	return await request_pop(options).wait()


## Replaces the top screen. If the destination cannot be instantiated the
## current screen stays active and the result is an error.
func replace_screen(source: Variant, options: Dictionary = {}) -> Dictionary:
	return await request_replace(source, options).wait()


## Deactivates and removes every screen.
func teardown() -> Dictionary:
	return await request_teardown().wait()


# The `request_*` variants queue without awaiting and hand back the request, so
# a caller can fire several mutations and inspect each outcome later. This is
# also how a caller observes coalescing: only the mutation that still applies
# reports SUCCESS.

func request_push(source: Variant, options: Dictionary = {}) -> CommonUIStackRequest:
	return _enqueue(CommonUIStackRequest.Kind.PUSH, source, options)


func request_pop(options: Dictionary = {}) -> CommonUIStackRequest:
	return _enqueue(CommonUIStackRequest.Kind.POP, null, options)


func request_replace(source: Variant, options: Dictionary = {}) -> CommonUIStackRequest:
	return _enqueue(CommonUIStackRequest.Kind.REPLACE, source, options)


func request_teardown() -> CommonUIStackRequest:
	return _enqueue(CommonUIStackRequest.Kind.TEARDOWN, null, {})


func _enqueue(kind: CommonUIStackRequest.Kind, source: Variant, options: Dictionary) -> CommonUIStackRequest:
	var request := CommonUIStackRequest.new()
	request.kind = kind
	request.source = source
	request.options = options

	if kind == CommonUIStackRequest.Kind.TEARDOWN:
		_cancel_pending_queue("A teardown was queued; this request no longer applies.")
	elif kind == CommonUIStackRequest.Kind.PUSH:
		_coalesce_pending_push(request)

	_queue.append(request)
	if not _draining:
		# Deferred so this stays a plain function: the drain loop is a coroutine.
		_drain.call_deferred()
	return request


## Collapses `request` (a PUSH about to be queued) against the queue's current
## tail when that tail is itself a still-pending PUSH of the exact same source:
## the tail is dropped and reports CANCELED immediately, so only the newest of a
## run of identical presses ever actually executes. Not recursive and not a
## scan of the whole queue -- only directly-consecutive duplicates collapse, by
## design (see the class doc comment).
func _coalesce_pending_push(request: CommonUIStackRequest) -> void:
	if _queue.is_empty():
		return
	var tail: CommonUIStackRequest = _queue.back()
	if tail.kind != CommonUIStackRequest.Kind.PUSH or tail.source != request.source:
		return
	_queue.pop_back()
	tail.complete(CommonUIStackRequest.Status.CANCELED, null,
		"Collapsed: a later push of the same source was queued before this one ran.")


## Cancels every request currently sitting in the queue (not the one already in
## flight, which is not part of `_queue`). Used when a TEARDOWN is queued, since
## none of those pending mutations would still apply once the stack is cleared.
func _cancel_pending_queue(reason: String) -> void:
	if _queue.is_empty():
		return
	var pending := _queue.duplicate()
	_queue.clear()
	for pending_request in pending:
		pending_request.complete(CommonUIStackRequest.Status.CANCELED, null, reason)


func _drain() -> void:
	if _draining:
		return
	_draining = true
	while not _queue.is_empty():
		var request: CommonUIStackRequest = _queue.pop_front()
		match request.kind:
			CommonUIStackRequest.Kind.PUSH:
				await _do_push(request)
			CommonUIStackRequest.Kind.POP:
				await _do_pop(request)
			CommonUIStackRequest.Kind.REPLACE:
				await _do_replace(request)
			CommonUIStackRequest.Kind.TEARDOWN:
				await _do_teardown(request)
	_draining = false


# --- Transaction bodies ----------------------------------------------------

func _instantiate(source: Variant) -> CommonActivatableScreen:
	if source is CommonActivatableScreen:
		return source
	if source is PackedScene:
		var instance := (source as PackedScene).instantiate()
		var screen := instance as CommonActivatableScreen
		if screen == null:
			# Not a screen: free the instance rather than leaking it.
			instance.queue_free()
			return null
		return screen
	return null


func _do_push(request: CommonUIStackRequest) -> void:
	var screen := _instantiate(request.source)
	if screen == null:
		request.complete(CommonUIStackRequest.Status.ERROR, null,
			"Could not instantiate the destination screen.")
		return

	var existing_parent := screen.get_parent()
	if existing_parent != null and existing_parent != self:
		request.complete(CommonUIStackRequest.Status.ERROR, null,
			"The screen already belongs to another node; push it there or remove it first.")
		return

	var previous := get_top_screen()
	if screen == previous:
		# Already the top of this layer's stack. The native runtime dedupes the
		# same way (cu_scope.cpp push_screen erases the existing occurrence
		# before re-appending), so raising the current top is a no-op.
		request.complete(CommonUIStackRequest.Status.SUCCESS, screen)
		return

	# A screen already elsewhere in this layer's stack is raised to the top
	# instead of duplicated, mirroring the native runtime's push_screen (it
	# erases the screen's existing stack position before re-appending it).
	# Dropping its old position -- and the focus-memory frame recorded there --
	# first lets the rest of this run exactly like an ordinary push, so
	# _focus_memory stays aligned 1:1 with _stack by depth (see
	# _capture_focus / _restore_captured_focus).
	var already_stacked := has_screen(screen)
	if already_stacked:
		var old_index := _stack.find(screen)
		_stack.remove_at(old_index)
		if old_index < _focus_memory.size():
			_focus_memory.remove_at(old_index)

	_focus_memory.append(_capture_focus())

	if previous != null:
		# The screen below stays in the stack for restoration but stops routing.
		# It is covered, not popped, so it must stay visible behind the new top.
		await previous.deactivate(true)

	screen.layer_id = layer_id
	if screen.get_parent() != self:
		add_child(screen)
	_stack.append(screen)
	_track_screen(screen)

	if not await screen.activate():
		# Activation was cancelled, typically because the tree was torn down.
		# CANCELED promises an unchanged stack, so the screen that was
		# deactivated to make room has to come back.
		#
		# A screen that left the tree on its own during activation (or was
		# freed externally) is already pruned by _on_tracked_screen_tree_exited
		# by the time this resumes -- has_screen(screen) is false, and its
		# stack/focus-memory bookkeeping is already gone. Only its Node
		# lifecycle can still need cleanup, and only if it merely detached
		# itself (still valid) rather than having been freed outright.
		if has_screen(screen):
			# A screen that was already stacked before this push keeps its
			# keep_alive_when_popped contract instead of being unconditionally
			# freed, since it was an established member of the stack, not a
			# fresh instance.
			_remove_from_stack(screen, not already_stacked or not screen.keep_alive_when_popped)
			_focus_memory.pop_back()
		elif is_instance_valid(screen) and not already_stacked:
			screen.queue_free()
		if previous != null and is_instance_valid(previous):
			await previous.activate()
		request.complete(CommonUIStackRequest.Status.CANCELED, null,
			"Activation was cancelled before it completed.")
		return

	# Only a screen that finished activating becomes routing-active, so a
	# control registered during the transition cannot route early.
	var runtime := _get_runtime()
	if runtime != null:
		runtime.push_screen(layer_id, screen, 0)

	screen_pushed.emit(screen)
	stack_changed.emit(_stack.size())
	request.complete(CommonUIStackRequest.Status.SUCCESS, screen)


func _do_pop(request: CommonUIStackRequest) -> void:
	var screen := get_top_screen()
	if screen == null:
		# Extra back requests after the stack drained are not errors; they are
		# simply no longer applicable.
		request.complete(CommonUIStackRequest.Status.CANCELED, null, "The stack is empty.")
		return

	if is_instance_valid(screen):
		await screen.deactivate()
	var free_screen := not is_instance_valid(screen) or not screen.keep_alive_when_popped
	_remove_from_stack(screen, free_screen)

	var restored := get_top_screen()
	if restored != null and is_instance_valid(restored):
		await restored.activate()
	# Every push records one focus frame, so every successful pop must consume
	# exactly one even when another screen remains below. Otherwise closing a
	# Settings screen leaves its frame behind and a later Menu pop consumes that
	# stale entry instead of restoring focus outside the layer.
	_restore_captured_focus()

	screen_popped.emit(screen)
	stack_changed.emit(_stack.size())
	request.complete(CommonUIStackRequest.Status.SUCCESS, restored)


func _do_replace(request: CommonUIStackRequest) -> void:
	# Instantiate before touching the stack so a failure leaves the current
	# screen as the active top screen.
	var screen := _instantiate(request.source)
	if screen == null:
		request.complete(CommonUIStackRequest.Status.ERROR, null,
			"Could not instantiate the replacement screen.")
		return

	var existing_parent := screen.get_parent()
	if existing_parent != null and existing_parent != self:
		request.complete(CommonUIStackRequest.Status.ERROR, null,
			"The screen already belongs to another node; it cannot replace the current screen.")
		return

	# The outgoing screen stays in the stack until the replacement has actually
	# activated: destroying it first would make a cancelled replace unrecoverable.
	var previous := get_top_screen()
	if previous != null and is_instance_valid(previous):
		await previous.deactivate()

	screen.layer_id = layer_id
	if screen.get_parent() != self:
		add_child(screen)
	_stack.append(screen)
	_track_screen(screen)

	if not await screen.activate():
		_remove_from_stack(screen, true)
		if previous != null and is_instance_valid(previous):
			await previous.activate()
		request.complete(CommonUIStackRequest.Status.CANCELED, null,
			"Activation was cancelled before it completed.")
		return

	var runtime := _get_runtime()
	if runtime != null:
		runtime.push_screen(layer_id, screen, 0)

	if previous != null and is_instance_valid(previous):
		_remove_from_stack(previous, not previous.keep_alive_when_popped)
		screen_popped.emit(previous)

	screen_pushed.emit(screen)
	stack_changed.emit(_stack.size())
	request.complete(CommonUIStackRequest.Status.SUCCESS, screen)


func _do_teardown(request: CommonUIStackRequest) -> void:
	while not _stack.is_empty():
		var screen: CommonActivatableScreen = _stack.back()
		if is_instance_valid(screen):
			await screen.deactivate()
		_remove_from_stack(screen, not is_instance_valid(screen) or not screen.keep_alive_when_popped)
		screen_popped.emit(screen)
	_focus_memory.clear()
	stack_changed.emit(0)
	request.complete(CommonUIStackRequest.Status.SUCCESS)


func _remove_from_stack(screen: CommonActivatableScreen, free_screen: bool) -> void:
	_untrack_screen(screen)
	_stack.erase(screen)
	var runtime := _get_runtime()
	if runtime != null and is_instance_valid(screen):
		runtime.remove_screen(layer_id, screen, 0)
	if not is_instance_valid(screen):
		return
	if free_screen:
		screen.queue_free()
	else:
		screen.visible = false


# --- External-free pruning --------------------------------------------------
#
# A screen freed directly by the game (queue_free, scene change) or reparented
# away must not leave a dangling entry in _stack: a later pop would await
# deactivate() on a freed instance. Every screen this layer stacks is tracked
# from the moment it enters _stack until this layer removes it through one of
# its own transactions (_remove_from_stack always untracks first), so only an
# external removal ever reaches the handler below.

func _track_screen(screen: CommonActivatableScreen) -> void:
	if screen != null and is_instance_valid(screen) \
			and not screen.tree_exited.is_connected(_on_tracked_screen_tree_exited):
		screen.tree_exited.connect(_on_tracked_screen_tree_exited)


func _untrack_screen(screen: CommonActivatableScreen) -> void:
	if screen != null and is_instance_valid(screen) \
			and screen.tree_exited.is_connected(_on_tracked_screen_tree_exited):
		screen.tree_exited.disconnect(_on_tracked_screen_tree_exited)


## A tracked screen just left the tree without going through this layer's own
## removal path. Prunes every stack entry that is now freed or parented
## elsewhere, dropping the focus-memory frame recorded at the same depth so the
## invariant _capture_focus / _restore_captured_focus rely on keeps holding.
func _on_tracked_screen_tree_exited() -> void:
	# If a whole suffix left before this callback ran, restoring the focus frame
	# of the lowest removed screen matches popping that suffix in order. For
	# A/B/C -> A, that is B's captured frame (focus on A), not C's frame (focus
	# on the now-dead B).
	var first_removed_top := _stack.size()
	while first_removed_top > 0:
		var candidate: CommonActivatableScreen = _stack[first_removed_top - 1]
		if is_instance_valid(candidate) and candidate.get_parent() == self:
			break
		first_removed_top -= 1
	var top_was_pruned := first_removed_top < _stack.size()
	var recovery_focus: Dictionary = {}
	if top_was_pruned and first_removed_top < _focus_memory.size():
		recovery_focus = _focus_memory[first_removed_top]

	var pruned := false
	var index := 0
	while index < _stack.size():
		var screen: CommonActivatableScreen = _stack[index]
		if is_instance_valid(screen) and screen.get_parent() == self:
			index += 1
			continue
		_stack.remove_at(index)
		_untrack_screen(screen)
		if index < _focus_memory.size():
			_focus_memory.remove_at(index)
		var runtime := _get_runtime()
		if runtime != null and is_instance_valid(screen):
			runtime.remove_screen(layer_id, screen, 0)
		pruned = true
	if pruned:
		stack_changed.emit(_stack.size())
	if top_was_pruned:
		_schedule_external_recovery(recovery_focus)


func _schedule_external_recovery(focus_memory: Dictionary) -> void:
	_external_recovery_generation += 1
	_external_recovery_focus = focus_memory
	if _external_recovery_pending:
		return
	_external_recovery_pending = true
	_recover_after_external_prune.call_deferred()


## Replays the expose-lower half of an ordinary pop after an external removal.
## Waiting for the request drain prevents a screen that exits during an
## activation/deactivation coroutine from racing that transaction. If the
## transaction already reactivated the lower screen, activate() is a no-op.
func _recover_after_external_prune() -> void:
	while is_inside_tree():
		while _draining and is_inside_tree():
			await get_tree().process_frame
		if not is_inside_tree():
			break

		var generation := _external_recovery_generation
		var focus_memory := _external_recovery_focus
		var exposed := get_top_screen()
		if exposed != null and is_instance_valid(exposed) \
				and not exposed.is_routing_active():
			await exposed.activate()

		# Another tracked top left while activation was awaiting. Restart using
		# the newest exposed screen and its corresponding focus frame.
		if generation != _external_recovery_generation:
			continue
		_restore_focus_memory(focus_memory)
		break
	_external_recovery_pending = false


# --- Focus memory ----------------------------------------------------------

func _capture_focus() -> Dictionary:
	if not is_inside_tree():
		return {}
	var focused := get_viewport().gui_get_focus_owner()
	if focused == null:
		return {}
	# The Control itself, not a NodePath: a path is structural, not an identity,
	# so a screen freed later and replaced by an unrelated node that happens to
	# occupy the exact same relative path would otherwise be handed focus it
	# never earned. is_instance_valid() on restore is what a direct reference
	# needs instead of path resolution.
	return {"control": focused, "screen": _screen_of(focused)}


## The activatable screen that contains `node`, or null.
func _screen_of(node: Node) -> CommonActivatableScreen:
	var current := node
	while current != null:
		if current is CommonActivatableScreen:
			return current
		current = current.get_parent()
	return null


func _restore_captured_focus() -> void:
	if _focus_memory.is_empty() or not is_inside_tree():
		return
	var memory: Dictionary = _focus_memory.pop_back()
	_restore_focus_memory(memory)


func _restore_focus_memory(memory: Dictionary) -> void:
	if not is_inside_tree():
		return
	if memory.is_empty():
		return

	# A pop on this layer must not steal focus from a still-open screen on a
	# higher-priority layer, e.g. a popup opened while this layer's screen was
	# topmost. If the live focus owner right now belongs to a routing-active
	# screen on a layer above this one, leave it alone entirely.
	var current_focus := get_viewport().gui_get_focus_owner()
	if _higher_layer_owns_focus(current_focus):
		return

	var control: Variant = memory.get("control", null)
	if control != null and is_instance_valid(control) and control is Control and _is_eligible(control):
		control.grab_focus()
		return

	# The remembered control was freed, hidden, or disabled while the screen
	# above it was open. Hand the decision back to its screen, which applies the
	# documented default-then-first-eligible-descendant fallback.
	#
	# The screen itself may have been freed too -- the captured focus owner can
	# belong to a different layer that was torn down while this layer's top screen
	# was open. Read it untyped and validate before the typed assignment, because
	# assigning a freed instance to a typed variable raises an error.
	var stored: Variant = memory.get("screen", null)
	if stored == null or not is_instance_valid(stored) or not (stored is CommonActivatableScreen):
		return
	var screen: CommonActivatableScreen = stored
	if screen.is_routing_active():
		screen.restore_focus()


## True when `focused` belongs to a routing-active screen on a CommonUILayer
## with higher priority than this one. Layers discover each other as siblings
## under the same parent -- the natural home for every layer, whether that
## parent is a [CommonUIScreenRoot] or a game's own flow node -- rather than
## through a hard dependency on the screen root.
func _higher_layer_owns_focus(focused: Control) -> bool:
	if focused == null:
		return false
	var parent := get_parent()
	if parent == null:
		return false
	for sibling in parent.get_children():
		var other := sibling as CommonUILayer
		if other == null or other == self or other.layer_priority <= layer_priority:
			continue
		var top := other.get_top_screen()
		if top == null or not is_instance_valid(top):
			continue
		if top.is_routing_active() and top.is_ancestor_of(focused):
			return true
	return false


func _is_eligible(control: Control) -> bool:
	if control == null or not is_instance_valid(control):
		return false
	if not control.is_visible_in_tree() or control.focus_mode == Control.FOCUS_NONE:
		return false
	if control is BaseButton and control.disabled:
		return false
	return true
