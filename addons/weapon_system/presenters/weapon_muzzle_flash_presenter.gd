class_name WeaponMuzzleFlashPresenter
extends Node2D

## Optional lightweight 2D presenter (weapon-presentation spec.md "Optional
## Lightweight 2D Presenters"). Consumes ONLY `WeaponAuthority`'s public
## `shot_committed` signal and never issues a command or touches canonical
## weapon/inventory/GAS state -- deleting this node from a scene leaves
## authoritative behavior completely unchanged (spec.md "Presentation Is Not
## Authority": "Removing all presenters MUST leave authoritative behavior
## unchanged").
##
## Position this node at the weapon's muzzle in world/local space; it only
## ever draws a short, self-expiring flash centered on itself.

signal flash_started(instance_id: String)
signal flash_ended(instance_id: String)

@export var flash_duration_seconds: float = 0.06
@export var flash_color: Color = Color("#e8e9ec") # design.md §3.2 text_primary.
@export var flash_radius: float = 10.0

## Bounded counters a headless check can assert against without a display.
var flash_count := 0

var _weapon_authority: Node
var _watched_instance_id := ""
var _elapsed := 0.0
var _active := false


## Wires this presenter to one `WeaponAuthority` instance's `shot_committed`
## signal, filtered to `p_instance_id` (the signal is authority-wide -- see
## this file's own "Known façade gaps" note in
## docs for why a multi-instance authority needs per-presenter filtering).
func attach(p_weapon_authority: Node, p_instance_id: String) -> void:
	detach()
	_weapon_authority = p_weapon_authority
	_watched_instance_id = p_instance_id
	if _weapon_authority != null:
		_weapon_authority.shot_committed.connect(_on_shot_committed)
	set_process(true)


func detach() -> void:
	if _weapon_authority != null and _weapon_authority.shot_committed.is_connected(_on_shot_committed):
		_weapon_authority.shot_committed.disconnect(_on_shot_committed)
	_weapon_authority = null
	_active = false
	set_process(false)


func _on_shot_committed(outcome: Dictionary) -> void:
	var shot: Dictionary = outcome.get("shot", {})
	if shot.is_empty():
		return
	if String(shot.get("instance_id", "")) != _watched_instance_id:
		return
	_active = true
	_elapsed = 0.0
	flash_count += 1
	flash_started.emit(_watched_instance_id)
	queue_redraw()


func _process(delta: float) -> void:
	if not _active:
		return
	_elapsed += delta
	if _elapsed >= flash_duration_seconds:
		_active = false
		flash_ended.emit(_watched_instance_id)
	queue_redraw()


func _draw() -> void:
	if not _active:
		return
	var t := clampf(_elapsed / flash_duration_seconds, 0.0, 1.0)
	draw_circle(Vector2.ZERO, flash_radius * (0.6 + 0.4 * (1.0 - t)), Color(flash_color, 1.0 - t))
