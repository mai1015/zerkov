extends RefCounted
## Closed-roster authorization tests. The unrestricted graph scanner remains a
## diagnostic tool; production guards authorize exact invocations, not arbitrary
## executable scripts. Native/world mutation guards remain authoritative.
const HANDLER: StringName = &"closed_dispatch_probe"
class Target:
	extends Node
	var calls: int = 0
	var payload: Variant
	var world: BodyHitboxWorld2D
	var registration: String = ""
	var raw_denied: bool = false
	var wrong_method_denied: bool = false
	func phase(raid, phase_id: int, tick: int, _intents: Array[ZRaidIntent], cookie: int) -> bool:
		if cookie != 7 or not raid.is_dispatching_phase_registration(&"closed_dispatch_probe", registration,
			Callable(self, "phase").bind(cookie), phase_id, tick, raid.generation()): return false
		calls += 1
		wrong_method_denied = not raid.can_dispatch_phase_callback(Callable(self, "phase").bind(8))
		if world != null:
			var result := world.raycast({}, payload)
			raw_denied = not result.get("accepted", false) and world.last_error == &"binding_capability_revoked"
		return true
class Replacement:
	extends Node
	var calls: int = 0
	func phase(_raid, _phase_id, _tick, _intents, _cookie) -> bool:
		calls += 1
		return true

var checks: int = 0
var failures: int = 0
var _check: Callable

func run(check_callback: Callable) -> bool:
	_check = check_callback
	for scenario: String in ["normal", "roster", "owner", "script", "revoked_bearer"]:
		if not _scenario(scenario): return false
	print("CLOSED_DISPATCH_RESULT checks=", checks, " failures=", failures)
	return failures == 0

func _scenario(scenario: String) -> bool:
	var raid = RaidAuthority.new() # Dynamic lets older comparison checkouts import this helper.
	var raid_ref: WeakRef = weakref(raid)
	var target := Target.new()
	(Engine.get_main_loop() as SceneTree).root.add_child(target)
	var id := ZRaidId.from_parts(PackedStringArray(["closed_dispatch", scenario]))
	var admission := SessionCoordinator.new().open_offline(id, StringName("closed_" + scenario))
	var ok := _assert(raid.configure(id, admission, 1), "configure " + scenario)
	var generation: int = raid.generation()
	ok = _assert(not raid.seal_production_dispatch(generation), "cannot seal arbitrary/unconfigured roster") and ok
	ok = _assert(raid.require_named_phase_handlers(generation), "require named methods") and ok
	var callback := Callable(target, "phase").bind(7)
	ok = _assert(raid.register_phase_handler(RaidAuthority.TickPhase.WORLD_CONSEQUENCES,
		HANDLER, callback, generation), "register exact named method") and ok
	target.registration = raid.phase_handler_registration_id(HANDLER, generation)
	var world: BodyHitboxWorld2D
	var bearer: BodyHitboxWorld2D.BindingCapability
	if scenario == "revoked_bearer":
		world = BodyHitboxWorld2D.new()
		bearer = world.bind_raid_authority(raid, admission.actor_id, ZRaidIntent.Source.PLAYER, generation)
		ok = _assert(bearer != null, "real raw capability issued during preparation") and ok
		ok = _assert(world.authorize_phase_consumer(bearer, HANDLER, target.registration, callback), "install exact native/world phase grant") and ok
		ok = _assert(world.seal_phase_grants(bearer), "raw bearer revoked before production") and ok
		target.world = world
	ok = _assert(not raid.seal_production_dispatch(generation + 1), "wrong generation cannot seal") and ok
	ok = _assert(raid.seal_production_dispatch(generation), "seal complete production roster") and ok
	ok = _assert(raid.has_closed_production_dispatch(), "closed mode is explicit") and ok
	ok = _assert(not raid.seal_production_dispatch(generation), "cannot replace a sealed roster") and ok
	ok = _assert(not raid.register_phase_handler(RaidAuthority.TickPhase.WORLD_CONSEQUENCES,
		&"late_handler", callback, generation), "cannot add handlers after seal") and ok
	ok = _assert(not raid.can_dispatch_phase_callback(callback), "out-of-phase invocation denied") and ok
	ok = _assert(raid.transition(RaidAuthority.Lifecycle.ACTIVE, generation), "activate") and ok
	if scenario == "normal":
		var unrelated: Array = []
		for i in range(512): unrelated.append({"i": i, "text": "passive state"})
		target.payload = unrelated
		var before: Dictionary = raid.dispatch_work_counts()
		for _i in range(8): ok = _assert(raid.advance_one(generation), "closed tick advances") and ok
		var after: Dictionary = raid.dispatch_work_counts()
		ok = _assert(after.graph_scans == before.graph_scans, "idle/retained data causes zero new graph scans") and ok
		ok = _assert(target.calls == 8 and target.wrong_method_denied, "exact body executes; substituted bound argument denied") and ok
	elif scenario == "roster":
		raid._handler_ids[HANDLER].priority += 1
		ok = _assert(not raid.advance_one(generation) and target.calls == 0, "changed roster rejected before body") and ok
	elif scenario == "owner":
		target.queue_free()
		ok = _assert(not raid.advance_one(generation) and target.calls == 0, "queued owner cannot execute") and ok
	elif scenario == "script":
		var replacement := Replacement.new()
		target.set_script(replacement.get_script())
		replacement.free()
		ok = _assert(not raid.advance_one(generation) and target.get("calls") == 0, "same object with replaced script rejected") and ok
	else:
		target.payload = bearer
		ok = _assert(not raid.phase_handler_callback_is_safe(callback), "diagnostic scanner still detects retained bearer type") and ok
		ok = _assert(raid.advance_one(generation) and target.raw_denied,
			"closed invocation does not revive revoked raw authority") and ok
	ok = _assert(raid.teardown(generation), "teardown " + scenario) and ok
	ok = _assert(not raid.can_dispatch_phase_callback(callback), "terminal invocation denied") and ok
	if world != null:
		ok = _assert(world.release_delegated_binding(), "release sealed world") and ok
	target.free()
	world = null
	callback = Callable()
	raid = null
	ok = _assert(raid_ref.get_ref() == null, "sealed policy does not retain authority") and ok
	return ok

func _assert(ok: bool, label: String) -> bool:
	checks += 1
	if not ok: failures += 1
	return bool(_check.call(ok, "closed dispatch: " + label))
