class_name WeaponAmmoHudPresenter
extends Control

## Optional lightweight ammo HUD: loaded rounds / capacity, loaded
## ballistic-profile identity, and reload phase -- all read from
## `WeaponAuthority.snapshot()`'s public fields (weapon-presentation
## spec.md "Presentation Is Not Authority": "the HUD displays those values
## without mutating the weapon instance"). Never mutates weapon state;
## safe to remove.

@export var capacity: int = 0
@export var label_format := "%d / %d  %s"

## Bounded counter a headless check can assert against without a display.
var refresh_count := 0
var last_text := ""

var _weapon_authority: Node
var _instance_id := ""
var _label: Label


func _ready() -> void:
	_label = Label.new()
	add_child(_label)


func attach(p_weapon_authority: Node, p_instance_id: String, p_capacity: int) -> void:
	_weapon_authority = p_weapon_authority
	_instance_id = p_instance_id
	capacity = p_capacity
	refresh()


func refresh() -> void:
	if _weapon_authority == null:
		return
	var state: Dictionary = _weapon_authority.snapshot(_instance_id)
	if state.is_empty():
		return
	var loaded := int(state.get("loaded_rounds", 0))
	var phase := String(state.get("phase", "ready"))
	var profile: Dictionary = state.get("loaded_profile", {})
	var profile_label := String(profile.get("id", "")) if bool(profile.get("has_profile", false)) else "EMPTY"
	last_text = label_format % [loaded, capacity, phase.to_upper()]
	if _label != null:
		_label.text = "%s  (%s)" % [last_text, profile_label]
	refresh_count += 1
