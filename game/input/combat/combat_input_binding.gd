class_name ZCombatInputBinding
extends Node
## Real CommonUI callbacks. Holds only an intent router and presentation model;
## no WeaponAuthority, HealthConsequenceAdapter, actor transform, or world query.
var _router: ZCombatActionRouter
var _model: ZCombatHudModel
var _input: ZerkovInputService
var _token: ZerkovInputContextToken
var _handles: Array = []
var _generation: int = 0
var _held: Dictionary = {}
var _aim: Vector2 = Vector2.RIGHT
var _aiming: bool = false
var _last_move: Vector2 = Vector2.ZERO
var _released: bool = false
var last_receipt: Dictionary = {}

func bind(runtime: CommonUIRuntime, service: ZerkovInputService,
	router: ZCombatActionRouter, model: ZCombatHudModel, generation: int) -> bool:
	if _generation != 0 or _released or runtime == null or service == null or router == null or model == null \
		or not service.is_configured() or generation < 1: return false
	_router = router
	_model = model
	_input = service
	_generation = generation
	_token = service.activate_context(ZerkovInputActions.GAMEPLAY_CONTEXT, -1, &"combat_input")
	if _token == null: return false
	for action: StringName in [ZerkovInputActions.GAME_AIM, ZerkovInputActions.GAME_FIRE,
		ZerkovInputActions.GAME_RELOAD, ZerkovInputActions.GAME_CANCEL_RELOAD,
		ZerkovInputActions.GAME_MELEE, ZerkovInputActions.GAME_QUICK_HEAL,
		ZerkovInputActions.GAME_MOVE_UP, ZerkovInputActions.GAME_MOVE_LEFT,
		ZerkovInputActions.GAME_MOVE_DOWN, ZerkovInputActions.GAME_MOVE_RIGHT,
		ZerkovInputActions.GAME_SPRINT, ZerkovInputActions.GAME_CROUCH]:
		var handle := runtime.register_action(action, Callable(self, "_handle").bind(action),
			{"owner": self, "context": ZerkovInputActions.GAMEPLAY_CONTEXT, "priority": 0, "ui_user": 0})
		if handle == null:
			release()
			return false
		_handles.append(handle)
	return true

## A cursor/controller adapter supplies a finite direction, not an actor pose.
func set_aim_direction(direction: Vector2) -> bool:
	if not is_finite(direction.x) or not is_finite(direction.y) or direction.is_zero_approx(): return false
	_aim = direction.normalized()
	return true

func _handle(event: Dictionary, action: StringName) -> int:
	var pressed: bool = event.get("phase") == CommonUIRuntime.PHASE_PRESSED
	var released: bool = event.get("phase") in [CommonUIRuntime.PHASE_RELEASED, CommonUIRuntime.PHASE_CANCELED]
	if released: _held.erase(action)
	if not _active():
		_held.clear()
		return CommonUIRuntime.ROUTE_UNHANDLED
	var kind := ZCombatActionCodec.action_for_logical(action)
	if kind.is_empty():
		if pressed: _held[action] = true
		return CommonUIRuntime.ROUTE_HANDLED
	if kind == &"aim": _aiming = pressed if pressed or released else _aiming
	if not pressed and kind != &"aim": return CommonUIRuntime.ROUTE_HANDLED
	if not pressed and not released: return CommonUIRuntime.ROUTE_HANDLED
	var frame := _model.confirmed_frame()
	if frame.is_empty() or not frame.health.alive: return CommonUIRuntime.ROUTE_HANDLED
	var payload := payload_for(kind, frame, _aim, _aiming)
	if payload.is_empty(): return CommonUIRuntime.ROUTE_HANDLED
	last_receipt = _router.submit_logical(action, payload, int(frame.tick) + 1, _generation)
	_model.predict(last_receipt)
	return CommonUIRuntime.ROUTE_HANDLED

## Called by the root once before admitting the next authority tick. Input
## state only; movement and facing still commit inside RaidAuthority.MOVEMENT.
func flush_movement(target_tick: int) -> Dictionary:
	var direction := Vector2.ZERO
	if _active():
		direction = Vector2(int(_held.has(ZerkovInputActions.GAME_MOVE_RIGHT)) - int(_held.has(ZerkovInputActions.GAME_MOVE_LEFT)),
			int(_held.has(ZerkovInputActions.GAME_MOVE_DOWN)) - int(_held.has(ZerkovInputActions.GAME_MOVE_UP)))
	if not _active() or _model.confirmed_frame().is_empty():
		_held.clear()
		return {}
	# Aim is part of this admitted movement payload, even when stationary.
	var receipt := _router.submit_movement(target_tick, _generation, direction, _aim,
		_held.has(ZerkovInputActions.GAME_SPRINT), _held.has(ZerkovInputActions.GAME_CROUCH))
	_last_move = direction
	return receipt

static func payload_for(kind: StringName, frame: Dictionary, aim: Vector2 = Vector2.RIGHT, aiming: bool = false) -> Dictionary:
	var weapon: Dictionary = frame.get("weapon", {})
	if kind == &"aim":
		return {"direction_milli": Vector2i(roundi(aim.x * 1000), roundi(aim.y * 1000)), "aiming": aiming}
	if kind in [&"fire", &"reload", &"cancel_reload"]:
		if weapon.is_empty(): return {}
		var result := {"weapon_id": String(weapon.instance_id), "expected_weapon_revision": int(weapon.revision)}
		if kind == &"reload": result["expected_inventory_revision"] = int(frame.inventory_revision)
		if kind == &"cancel_reload":
			var reservation := String(weapon.get("reload", {}).get("reservation_id", ""))
			if reservation.is_empty(): return {}
			result["reservation_id"] = reservation
		return result
	if kind == &"melee":
		var equipment: Dictionary = frame.get("melee_equipment", {})
		return {"weapon_id": equipment.weapon_id, "expected_equipment_revision": equipment.revision} if not equipment.is_empty() else {}
	if kind == &"quick_heal":
		# Stable body declaration order; heavy bleed first, then fractures.
		for treatment: StringName in [&"bandage", &"splint"]:
			for zone: Dictionary in frame.get("health", {}).get("body_parts", []):
				if bool(zone.get("heavy_bleed" if treatment == &"bandage" else "fractured", false)):
					return {"body_zone": String(zone.zone_identifier), "treatment": String(treatment),
						"expected_health_revision": int(frame.health.health_revision), "expected_inventory_revision": int(frame.inventory_revision)}
	return {}

func _active() -> bool:
	return not _released and _input != null and _input.is_context_token_active(_token)

func release() -> void:
	if _released: return
	_released = true
	for handle in _handles:
		if handle != null: handle.release()
	_handles.clear()
	if _input != null and _token != null: _input.release_context_token(_token)
	_held.clear()

func _exit_tree() -> void:
	release()
