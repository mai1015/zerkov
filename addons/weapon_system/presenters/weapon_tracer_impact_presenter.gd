class_name WeaponTracerImpactPresenter
extends Node2D

## Optional lightweight 2D presenter: a self-expiring tracer line plus an
## impact marker. `WeaponAuthority` exposes no world-query/hit-resolution
## façade (the native `wpn::WorldCoordinator` core class has no Godot
## binding at all -- see this change's final report "Façade gaps"), so a
## world-resolved hit POINT is inherently game-owned data, exactly like
## `examples/weapon_system/extraction_combat_demo.gd`'s own
## `_resolve_committed_shot()` already computes it. This presenter therefore
## never performs its own world query: the game calls `show_tracer()`/
## `show_impact()` with an already-resolved endpoint. `wire_to_weapon()` is
## provided as a convenience for games that only want the NOMINAL (un-
## truncated) ballistic ray straight from the public `shot_committed` DTO,
## with no world resolution at all.

signal tracer_shown(from: Vector2, to: Vector2)
signal impact_shown(at: Vector2, is_hit: bool)

@export var tracer_color: Color = Color("#d7a53a") # design.md §3.3 accent.
@export var tracer_duration_seconds: float = 0.10
@export var impact_hit_color: Color = Color("#5fbf72") # design.md §3.3 positive.
@export var impact_miss_color: Color = Color("#c04a34") # design.md §3.3 danger.
@export var impact_duration_seconds: float = 0.20
@export var impact_radius: float = 5.0

## Bounded counters a headless check can assert against without a display.
var tracer_count := 0
var impact_count := 0

var _tracer_from := Vector2.ZERO
var _tracer_to := Vector2.ZERO
var _tracer_elapsed := 0.0
var _tracer_active := false

var _impact_at := Vector2.ZERO
var _impact_is_hit := false
var _impact_elapsed := 0.0
var _impact_active := false

var _wired_weapon_authority: Node


func show_tracer(from: Vector2, to: Vector2) -> void:
	_tracer_from = from
	_tracer_to = to
	_tracer_elapsed = 0.0
	_tracer_active = true
	tracer_count += 1
	tracer_shown.emit(from, to)
	set_process(true)
	queue_redraw()


func show_impact(at: Vector2, is_hit: bool) -> void:
	_impact_at = at
	_impact_is_hit = is_hit
	_impact_elapsed = 0.0
	_impact_active = true
	impact_count += 1
	impact_shown.emit(at, is_hit)
	set_process(true)
	queue_redraw()


## Convenience auto-wire: derives a NOMINAL (not world-resolved) full-range
## tracer directly from `shot_committed`'s public `shot` DTO -- direction
## and `range_milliunits` only, exactly the documented public values
## (weapon-presentation spec.md "Presenters ... consuming ONLY documented
## public signals/snapshot values"). A game wanting a world-truncated tracer
## calls `show_tracer()`/`show_impact()` directly instead (or in addition).
func wire_to_weapon(p_weapon_authority: Node, p_instance_id: String,
		p_pixels_per_milliunit: float, p_origin: Vector2) -> void:
	unwire()
	if p_weapon_authority == null:
		return
	_wired_weapon_authority = p_weapon_authority
	_wired_weapon_authority.shot_committed.connect(_on_shot_committed.bind(p_instance_id, p_pixels_per_milliunit, p_origin))


func unwire() -> void:
	if _wired_weapon_authority != null and _wired_weapon_authority.shot_committed.is_connected(_on_shot_committed):
		_wired_weapon_authority.shot_committed.disconnect(_on_shot_committed)
	_wired_weapon_authority = null


func _on_shot_committed(outcome: Dictionary, p_instance_id: String,
		p_pixels_per_milliunit: float, p_origin: Vector2) -> void:
	var shot: Dictionary = outcome.get("shot", {})
	if shot.is_empty() or String(shot.get("instance_id", "")) != p_instance_id:
		return
	var direction_fixed: Dictionary = shot.get("direction", {})
	var direction := Vector2(float(direction_fixed.get("x", 0)), float(direction_fixed.get("y", 0)))
	if direction != Vector2.ZERO:
		direction = direction.normalized()
	var range_pixels := float(shot.get("range_milliunits", 0)) * p_pixels_per_milliunit
	show_tracer(p_origin, p_origin + direction * range_pixels)


func _process(delta: float) -> void:
	var redraw := false
	if _tracer_active:
		_tracer_elapsed += delta
		if _tracer_elapsed >= tracer_duration_seconds:
			_tracer_active = false
		redraw = true
	if _impact_active:
		_impact_elapsed += delta
		if _impact_elapsed >= impact_duration_seconds:
			_impact_active = false
		redraw = true
	if redraw:
		queue_redraw()
	else:
		set_process(false)


func _draw() -> void:
	if _tracer_active:
		var t := clampf(_tracer_elapsed / tracer_duration_seconds, 0.0, 1.0)
		draw_line(_tracer_from, _tracer_to, Color(tracer_color, 1.0 - t), 2.0)
	if _impact_active:
		var t := clampf(_impact_elapsed / impact_duration_seconds, 0.0, 1.0)
		var color := impact_hit_color if _impact_is_hit else impact_miss_color
		draw_arc(_impact_at, impact_radius * (1.0 + t), 0.0, TAU, 24, Color(color, 1.0 - t), 2.0)
