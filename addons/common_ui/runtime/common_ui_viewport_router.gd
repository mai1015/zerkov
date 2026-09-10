@tool
class_name CommonUIViewportRouter
extends Node

## Routes CommonUI input for the [Viewport] it lives in.
##
## The [CommonUIRuntime] autoload only sees events dispatched to the root
## Viewport, so an action registered with a non-default [code]viewport[/code]
## scope (typically a control inside a [SubViewport], such as a split-screen or
## render-to-texture surface) would never receive input. Add one of these nodes
## anywhere inside that Viewport and its input is observed and routed against the
## runtime's [code](ui_user, Viewport)[/code] state, consuming events on that
## Viewport alone.
##
## The runtime remains the authority: this node only forwards; the route result
## and event consumption are decided natively, exactly as for the root Viewport.

var _runtime: CommonUIRuntime = null
## Cached so teardown can unregister even when [method Node.get_viewport] has
## already returned null.
var _viewport: Viewport = null
var _ready_done := false


func _get_runtime() -> CommonUIRuntime:
	if Engine.is_editor_hint() or not is_inside_tree():
		return null
	return get_node_or_null(^"/root/CommonUI") as CommonUIRuntime


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	_ready_done = true
	_register()


## Re-registers when this node re-enters the tree without a full [method _ready]
## running again, e.g. a pooled Viewport/subscene that is removed and re-added
## rather than freed -- [method _exit_tree] unregisters on the way out, and
## nothing previously re-registered on the way back in. Mirrors
## [method CommonButton._enter_tree]; see its comment for why the guard is
## needed (this fires before the very first [method _ready] too).
func _enter_tree() -> void:
	if Engine.is_editor_hint() or not _ready_done:
		return
	_register()


func _register() -> void:
	_viewport = get_viewport()
	_runtime = _get_runtime()
	if _runtime == null:
		push_error("CommonUIViewportRouter requires the CommonUI autoload.")
		return
	if _viewport == null:
		push_error("CommonUIViewportRouter is not inside a Viewport.")
		return
	# Announce the Viewport so registrations scoped to it stop warning that
	# nothing can route them.
	_runtime.register_viewport_router(_viewport)

	# UI must keep responding while the game itself is paused.
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process_input(true)
	set_process_shortcut_input(true)
	set_process_unhandled_input(true)


func _exit_tree() -> void:
	if _runtime != null and _viewport != null:
		_runtime.unregister_viewport_router(_viewport)
	_runtime = null
	_viewport = null


func _input(event: InputEvent) -> void:
	# Device and modality observation only; never consumes.
	if _runtime != null:
		_runtime.observe_viewport_input(event)


func _shortcut_input(event: InputEvent) -> void:
	# Keys and joypad buttons reach the tree here, post-GUI.
	if _runtime != null and _viewport != null:
		_runtime.route_viewport_input(event, _viewport, false)


func _unhandled_input(event: InputEvent) -> void:
	# Mouse buttons, joypad axes, and touch reach the tree only here.
	if _runtime != null and _viewport != null:
		_runtime.route_viewport_input(event, _viewport, true)
