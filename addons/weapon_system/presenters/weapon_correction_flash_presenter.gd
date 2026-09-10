class_name WeaponCorrectionFlashPresenter
extends Node2D

## Optional lightweight 2D presenter: flashes when authority replaces
## predicted/stale local presentation (`state_corrected`) or rejects a
## submitted command (`command_rejected`) -- weapon-presentation spec.md
## "Stable Presentation Signals": "Weapon state is corrected -- presenters
## receive one correction signal describing the confirmed baseline".
## Consumes only those two public `WeaponAuthority` signals; issues no
## commands and mutates no canonical state.
##
## KNOWN FAÇADE GAP: `command_rejected`'s outcome Dictionary carries no
## `instance_id` (unlike `shot_committed`'s nested `shot.instance_id`), so a
## presenter watching a `WeaponAuthority` that manages MORE than one
## instance cannot attribute a rejection to a specific weapon from the
## signal alone -- see this change's final report. This presenter is safe
## to use unfiltered only when its `WeaponAuthority` manages a single
## instance (true of every reference scene in this change); a multi-
## instance game should instead correlate the SYNCHRONOUS return value of
## its own `fire()`/`begin_reload()` call (which it already knows the
## instance_id for) rather than relying on this signal for attribution.

signal correction_flashed(reason: String)

@export var correction_color: Color = Color("#7cb3d9") # design.md §3.3 info -- state corrected.
@export var rejection_color: Color = Color("#c04a34") # design.md §3.3 danger -- command rejected.
@export var flash_duration_seconds: float = 0.18
@export var flash_radius: float = 14.0

## Bounded counters a headless check can assert against without a display.
var correction_count := 0
var rejection_count := 0
var last_rejection_code := -1

var _weapon_authority: Node
var _color := Color.WHITE
var _elapsed := 0.0
var _active := false


func attach(p_weapon_authority: Node) -> void:
	detach()
	_weapon_authority = p_weapon_authority
	if _weapon_authority != null:
		_weapon_authority.state_corrected.connect(_on_state_corrected)
		_weapon_authority.command_rejected.connect(_on_command_rejected)
	set_process(true)


func detach() -> void:
	if _weapon_authority != null:
		if _weapon_authority.state_corrected.is_connected(_on_state_corrected):
			_weapon_authority.state_corrected.disconnect(_on_state_corrected)
		if _weapon_authority.command_rejected.is_connected(_on_command_rejected):
			_weapon_authority.command_rejected.disconnect(_on_command_rejected)
	_weapon_authority = null
	_active = false
	set_process(false)


func _on_state_corrected(_snapshots: Array) -> void:
	correction_count += 1
	_start_flash(correction_color)
	correction_flashed.emit("state_corrected")


func _on_command_rejected(outcome: Dictionary) -> void:
	rejection_count += 1
	last_rejection_code = int(outcome.get("rejection", -1))
	_start_flash(rejection_color)
	correction_flashed.emit("command_rejected")


func _start_flash(color: Color) -> void:
	_color = color
	_elapsed = 0.0
	_active = true
	queue_redraw()


func _process(delta: float) -> void:
	if not _active:
		return
	_elapsed += delta
	if _elapsed >= flash_duration_seconds:
		_active = false
	queue_redraw()


func _draw() -> void:
	if not _active:
		return
	var t := clampf(_elapsed / flash_duration_seconds, 0.0, 1.0)
	draw_arc(Vector2.ZERO, flash_radius, 0.0, TAU, 32, Color(_color, 1.0 - t), 3.0)
