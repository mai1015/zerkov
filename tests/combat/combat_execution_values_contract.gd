extends SceneTree
## Pure timeline and presentation state, not a replacement for native combat.
var checks: int = 0
var failures: int = 0
const ACTOR := "zerkov.entity.combat.player"
func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error("COMBAT_VALUES: " + message)
func _initialize() -> void:
	var t := ZMeleeTimeline.new()
	var policy := ZMeleePolicy.definition(&"machete")
	check(policy.windup_ticks == 10 and policy.active_ticks == 3 and policy.recovery_ticks == 18, "authored timings")
	check(t.start("swing", 2, policy, Vector2i(1000000, 0)), "start")
	check(not t.start("duplicate", 2, policy, Vector2i.RIGHT), "busy does not restart")
	for tick in range(2, 12):
		check(t.advance(tick, true).phase == &"windup", "windup is contact-free")
	check(t.advance(12, true).query_contact, "first active tick inclusive")
	check(t.mark_contact(12), "contact accepted once")
	check(not t.mark_contact(12) and not t.advance(13, true).query_contact, "no second target/delivery")
	check(t.advance(15, true).phase == &"recovery", "active end exclusive")
	check(not t.can_start(32) and t.can_start(33), "full recovery")
	check(not t.advance(14, true).ok, "regression rejected")
	check(t.start("second", 33, policy, Vector2i(1000000, 0)), "second swing")
	check(t.advance(35, false).interrupted, "canonical interruption")
	check(not t.advance(43, true).query_contact, "late animation cannot revive interrupted swing")
	check(t.snapshot(43).is_read_only() and t.snapshot(43).swing.is_read_only(), "detached frozen timeline")
	var hud := ZCombatHudModel.new()
	check(hud.configure(ACTOR, 1), "HUD bound")
	check(not hud.snapshot().available, "no fixture values before publication")
	var frame := _frame(1)
	check(hud.publish(frame), "confirmed publication")
	check(hud.predict({"admitted":true,"generation":1,"request_id":"request","kind":"fire"}), "provisional input")
	check(hud.snapshot().ammo == 30 and hud.snapshot().health_micros == 7000000, "prediction does not consume or heal")
	frame = _frame(2)
	frame.receipts = [{"actor_id":ACTOR,"generation":1,"request_id":"request","terminal":true,"committed":false,"reason":"cadence"}]
	check(hud.publish(frame) and hud.snapshot().correction == "cadence", "explicit correction")
	check(hud.snapshot().ammo == 30 and hud.snapshot().feedback.is_empty(), "rejection no ammo refund/hit fabrication")
	check(not hud.publish(_frame(1)), "stale publication")
	var bad := _frame(3)
	bad.health.body_parts[0].health_micros = -1
	check(not hud.publish(bad) and hud.snapshot().tick == 2, "invalid frame retains last good publication")
	bad = _frame(3); bad.actor_id = "zerkov.entity.combat.other"
	check(not hud.publish(bad), "recipient isolation")
	hud.release()
	check(not hud.snapshot().available and not hud.publish(_frame(3)), "released projection unavailable")
	print("COMBAT_VALUES_RESULT checks=",checks," failures=",failures)
	quit(0 if failures == 0 else 1)
func _frame(tick: int) -> Dictionary:
	var parts: Array = []
	for i in range(7): parts.append({"health_micros":1000000,"max_health_micros":1000000,"heavy_bleed":false,"fractured":false})
	return {"schema":"zerkov.combat.frame.v1","actor_id":ACTOR,"generation":1,"tick":tick,"available":true,
		"health":{"alive":true,"body_parts":parts,"stamina_micros":100000000,"max_stamina_micros":100000000,"hydration_micros":100000000},
		"weapon":{"phase":"ready","loaded_rounds":30},"reserve_rounds":30,"melee":{"phase":&"ready"},"receipts":[],"feedback":[]}
