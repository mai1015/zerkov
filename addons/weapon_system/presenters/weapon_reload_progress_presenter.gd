class_name WeaponReloadProgressPresenter
extends Node2D

## Optional lightweight 2D presenter for reload progress. There is no
## canonical per-tick "reload progress" signal by design (weapon-
## presentation spec.md "Stable Presentation Signals": "Presenters SHALL
## derive continuous recoil recovery from the confirmed anchor and
## authority tick rather than requiring canonical per-tick recovery
## signals" -- the same discipline applies here). This presenter instead
## derives a CONTINUOUS fraction from the reload window's public
## `start_tick`/`due_tick` snapshot fields and a caller-supplied current
## authority tick, refreshed only on `reload_started`/`reload_completed`/
## `reload_cancelled` plus an explicit `update_tick()` call -- never
## mutating weapon state.

signal reload_progress_changed(instance_id: String, fraction: float)

@export var bar_size: Vector2 = Vector2(64, 6)
@export var bar_color: Color = Color("#7cb3d9") # design.md §3.3 info.
@export var bar_background: Color = Color("#24272c") # design.md §3.2 surface_raised.

var reloading := false
var last_fraction := 0.0
## Bounded counter a headless check can assert against without a display.
var progress_sample_count := 0

var _weapon_authority: Node
var _instance_id := ""


func attach(p_weapon_authority: Node, p_instance_id: String) -> void:
	detach()
	_weapon_authority = p_weapon_authority
	_instance_id = p_instance_id
	if _weapon_authority != null:
		_weapon_authority.reload_started.connect(_on_reload_started)
		_weapon_authority.reload_completed.connect(_on_reload_completed)
		_weapon_authority.reload_cancelled.connect(_on_reload_cancelled)


func detach() -> void:
	if _weapon_authority != null:
		if _weapon_authority.reload_started.is_connected(_on_reload_started):
			_weapon_authority.reload_started.disconnect(_on_reload_started)
		if _weapon_authority.reload_completed.is_connected(_on_reload_completed):
			_weapon_authority.reload_completed.disconnect(_on_reload_completed)
		if _weapon_authority.reload_cancelled.is_connected(_on_reload_cancelled):
			_weapon_authority.reload_cancelled.disconnect(_on_reload_cancelled)
	_weapon_authority = null
	reloading = false


func _on_reload_started(outcome: Dictionary) -> void:
	if not bool(outcome.get("accepted", false)):
		return
	reloading = true
	last_fraction = 0.0
	queue_redraw()


func _on_reload_completed(_completion: Dictionary) -> void:
	reloading = false
	last_fraction = 1.0
	queue_redraw()


func _on_reload_cancelled(_outcome: Dictionary) -> void:
	reloading = false
	last_fraction = 0.0
	queue_redraw()


## Called by the game once per displayed frame (or tick) with the CURRENT
## authority tick; reads only the public `reload` snapshot sub-dictionary
## (`start_tick`/`due_tick`) -- never a predicted/private value.
func update_tick(current_tick: int) -> void:
	if _weapon_authority == null or not reloading:
		return
	var state: Dictionary = _weapon_authority.snapshot(_instance_id)
	var reload: Dictionary = state.get("reload", {})
	if reload.is_empty():
		return
	var start_tick := int(reload.get("start_tick", 0))
	var due_tick := int(reload.get("due_tick", start_tick))
	var span := due_tick - start_tick
	var fraction := 1.0 if span <= 0 else clampf(float(current_tick - start_tick) / float(span), 0.0, 1.0)
	last_fraction = fraction
	progress_sample_count += 1
	reload_progress_changed.emit(_instance_id, fraction)
	queue_redraw()


func _draw() -> void:
	if not reloading:
		return
	draw_rect(Rect2(Vector2.ZERO, bar_size), bar_background)
	draw_rect(Rect2(Vector2.ZERO, Vector2(bar_size.x * last_fraction, bar_size.y)), bar_color)
