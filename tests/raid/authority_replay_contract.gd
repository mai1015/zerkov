extends SceneTree
## Run with: godot --headless --path . --script res://tests/raid/authority_replay_contract.gd

const FIXTURE_PATH := "res://tests/raid/fixtures/authority_replay.json"

var checks: int = 0
var failures: int = 0
var reentrant_rejections: int = 0
var nested_drain_rejections: int = 0


func _initialize() -> void:
	call_deferred("run")


func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("AUTHORITY_REPLAY_CONTRACT: " + message)


func run() -> void:
	var fixture := _load_fixture()
	check(not fixture.is_empty(), "replay fixture loads")
	var first := _run_fixture(fixture, false)
	var second := _run_fixture(fixture, true)
	check(first != null and second != null, "both replay authorities complete")
	if first != null and second != null:
		check(first.journal.records() == second.journal.records(),
			"arrival order produces identical audit records")
		check(first.journal.digest() == second.journal.digest(),
			"arrival order produces identical journal digest")
		check(first.state_digest() == second.state_digest(),
			"accepted input replay produces identical authority digest")
		check(not first.state_digest().is_empty(), "authority digest is available")
		var records := first.journal.records()
		check(records.size() == 3, "three committed events are journaled exactly once")
		if records.size() == 3:
			check(records[0]["event_id"] == "zerkov.consequence.replay.loot_001",
				"same-tick intents are ordered by canonical sequence")
			check(records[1]["event_id"] == "zerkov.consequence.replay.loot_002",
				"second same-tick intent follows sequence order")
			check(records[2]["tick"] == 2 and records[2]["sequence"] == 3,
				"journal tick and global sequence are monotonic")
		check(first.last_phase_trace == RaidAuthority.PHASE_NAMES,
			"every tick uses the documented nine-phase order")
		var generation := first.generation()
		check(not bool(first.call("_process_tick", 2, generation)),
			"regressing authority tick is rejected")
		check(first.last_error == &"tick_regressed_or_skipped",
			"regressing tick has a stable diagnostic")
		var duplicate_id := ZConsequenceId.parse("zerkov.consequence.replay.fire_003")
		check(not first.record_event(
			ZRaidEvent.EventKind.FIRE,
			duplicate_id,
			2,
			first.admission().actor_id,
			{},
			generation
		), "duplicate presentation signal cannot append a consequence twice")
		check(first.journal.size() == 3, "duplicate signal leaves journal unchanged")

	check(reentrant_rejections == 4, "each nested tick attempt is rejected as reentrant")
	_test_intent_validation(fixture)
	_test_queue_bound(fixture)
	_test_journal_bound(fixture)
	_test_admitted_intent_snapshot(fixture)
	_test_nested_drain_guard(fixture)
	_test_advance_one_with_backlog(fixture)
	_test_handler_failure_consistency(fixture)
	_test_event_tick_gate(fixture)
	check(ZCanonicalValue.sha256({"b": 2, "a": 1}) == ZCanonicalValue.sha256({"a": 1, "b": 2}),
		"canonical digest ignores dictionary insertion order")
	check(not ZCanonicalValue.is_bounded({"float": 1.5}),
		"authoritative payload rejects floating-point values")

	print("AUTHORITY_REPLAY_RESULT checks=", checks, " failures=", failures,
		" reentrant_rejections=", reentrant_rejections)
	quit(0 if failures == 0 else 1)


func _load_fixture() -> Dictionary:
	var file := FileAccess.open(FIXTURE_PATH, FileAccess.READ)
	if file == null:
		return {}
	var value: Variant = JSON.parse_string(file.get_as_text())
	return value as Dictionary if value is Dictionary else {}


func _run_fixture(fixture: Dictionary, reverse_arrival: bool) -> RaidAuthority:
	var raid := ZRaidId.parse(String(fixture["raid_id"]))
	var coordinator := SessionCoordinator.new()
	var admission := coordinator.open_offline(
		raid,
		StringName(fixture["profile_key"]),
		StringName(fixture["actor_slot"])
	)
	var authority := RaidAuthority.new()
	if not authority.configure(raid, admission, int(fixture["seed"])):
		check(false, "fixture authority configures")
		return null
	var generation := authority.generation()
	check(authority.register_phase_handler(
		RaidAuthority.TickPhase.MOVEMENT,
		&"reentrant_probe",
		_reentrant_probe,
		generation
	), "reentrant probe registers")
	check(authority.register_phase_handler(
		RaidAuthority.TickPhase.INTERACTIONS_AND_WEAPONS,
		&"fixture_apply",
		_apply_fixture_intents,
		generation
	), "fixture intent handler registers")
	check(authority.transition(RaidAuthority.Lifecycle.ACTIVE, generation),
		"fixture authority activates")
	var intent_rows := (fixture["intents"] as Array).duplicate(true)
	if reverse_arrival:
		intent_rows.reverse()
	for row_value in intent_rows:
		var row := row_value as Dictionary
		var intent := ZRaidIntent.create(
			ZRequestId.parse(String(row["request_id"])),
			ZRaidIntent.Source.PLAYER,
			admission.session_id,
			admission.actor_id,
			admission.authority_epoch,
			generation,
			int(row["target_tick"]),
			int(row["sequence"]),
			StringName(row["kind"]),
			{
				"amount": int(row["amount"]),
				"consequence_id": String(row["consequence_id"]),
			}
		)
		check(authority.enqueue_intent(intent, generation), "fixture intent is admitted")
	check(authority.advance_one(generation), "fixture tick one advances")
	check(authority.advance_one(generation), "fixture tick two advances")
	return authority


func _reentrant_probe(
	authority: RaidAuthority,
	_phase: RaidAuthority.TickPhase,
	_tick: int,
	_intents: Array[ZRaidIntent]
) -> bool:
	if not authority.advance_one(authority.generation()):
		reentrant_rejections += 1
		return authority.last_error == &"reentrant_tick"
	return false


func _apply_fixture_intents(
	authority: RaidAuthority,
	_phase: RaidAuthority.TickPhase,
	tick: int,
	intents: Array[ZRaidIntent]
) -> bool:
	for intent in intents:
		var event_kind := ZRaidEvent.EventKind.LOOT
		if intent.kind == &"fire":
			event_kind = ZRaidEvent.EventKind.FIRE
		var event_id := ZConsequenceId.parse(String(intent.payload["consequence_id"]))
		if not authority.record_event(
			event_kind,
			event_id,
			tick,
			intent.actor_id,
			{
				"amount": int(intent.payload["amount"]),
				"request_id": intent.request_id.canonical_key(),
				"roll": authority.rng.next_int(1000),
			},
			authority.generation()
		):
			return false
	return true


func _test_intent_validation(fixture: Dictionary) -> void:
	var raid := ZRaidId.parse(String(fixture["raid_id"]))
	var admission := SessionCoordinator.new().open_offline(raid, &"validation", &"player")
	var authority := RaidAuthority.new()
	check(authority.configure(raid, admission, 1), "validation authority configures")
	var generation := authority.generation()
	check(authority.transition(RaidAuthority.Lifecycle.ACTIVE, generation),
		"validation authority activates")
	var request := ZRequestId.from_parts(PackedStringArray(["validation", "intent_001"]))
	var valid := ZRaidIntent.create(
		request,
		ZRaidIntent.Source.PLAYER,
		admission.session_id,
		admission.actor_id,
		admission.authority_epoch,
		generation,
		1,
		1,
		&"move",
		{"axis": Vector2i(1, 0)}
	)
	check(authority.enqueue_intent(valid, generation), "well-formed intent is accepted")
	check(not authority.enqueue_intent(valid, generation) and authority.last_error == &"duplicate_request",
		"duplicate request ID is rejected")
	var duplicate_sequence := ZRaidIntent.create(
		ZRequestId.from_parts(PackedStringArray(["validation", "duplicate_sequence"] )),
		ZRaidIntent.Source.PLAYER,
		admission.session_id,
		admission.actor_id,
		admission.authority_epoch,
		generation,
		1,
		1,
		&"move",
		{}
	)
	check(not authority.enqueue_intent(duplicate_sequence, generation)
		and authority.last_error == &"duplicate_sequence",
		"same actor/source sequence cannot be reused under a new request ID")
	var wrong_session := ZRaidIntent.create(
		ZRequestId.from_parts(PackedStringArray(["validation", "wrong_session"])),
		ZRaidIntent.Source.PLAYER,
		ZSessionId.from_parts(PackedStringArray(["offline", "wrong", "00000001"])),
		admission.actor_id,
		admission.authority_epoch,
		generation,
		1,
		2,
		&"move",
		{}
	)
	check(not authority.enqueue_intent(wrong_session, generation)
		and authority.last_error == &"session_mismatch", "session mismatch is rejected")
	var float_payload := ZRaidIntent.create(
		ZRequestId.from_parts(PackedStringArray(["validation", "float_payload"])),
		ZRaidIntent.Source.PLAYER,
		admission.session_id,
		admission.actor_id,
		admission.authority_epoch,
		generation,
		1,
		3,
		&"move",
		{"axis": 0.5}
	)
	check(not authority.enqueue_intent(float_payload, generation)
		and authority.last_error == &"payload_invalid_or_unbounded",
		"floating payload is rejected")
	var stale_generation := ZRaidIntent.create(
		ZRequestId.from_parts(PackedStringArray(["validation", "stale_generation"])),
		ZRaidIntent.Source.PLAYER,
		admission.session_id,
		admission.actor_id,
		admission.authority_epoch,
		generation - 1,
		1,
		4,
		&"move",
		{}
	)
	check(not authority.enqueue_intent(stale_generation, generation)
		and authority.last_error == &"generation_mismatch", "intent generation mismatch is rejected")


func _test_queue_bound(fixture: Dictionary) -> void:
	var raid := ZRaidId.parse(String(fixture["raid_id"]))
	var admission := SessionCoordinator.new().open_offline(raid, &"queue", &"player")
	var queue := ZRaidIntentQueue.new()
	for index in ZRaidIntentQueue.MAX_QUEUED_INTENTS:
		var intent := ZRaidIntent.create(
			ZRequestId.from_parts(PackedStringArray(["queue", "intent_%04d" % index])),
			ZRaidIntent.Source.PLAYER,
			admission.session_id,
			admission.actor_id,
			admission.authority_epoch,
			admission.generation,
			1,
			index + 1,
			&"move",
			{}
		)
		if not queue.admit(intent, 0, admission.session_id, admission.actor_id,
			admission.authority_epoch, admission.generation):
			check(false, "queue accepts entry within declared bound")
			break
	check(queue.size() == ZRaidIntentQueue.MAX_QUEUED_INTENTS, "intent queue reaches exact bound")
	var overflow := ZRaidIntent.create(
		ZRequestId.from_parts(PackedStringArray(["queue", "overflow"])),
		ZRaidIntent.Source.PLAYER,
		admission.session_id,
		admission.actor_id,
		admission.authority_epoch,
		admission.generation,
		1,
		ZRaidIntentQueue.MAX_QUEUED_INTENTS + 1,
		&"move",
		{}
	)
	check(not queue.admit(overflow, 0, admission.session_id, admission.actor_id,
		admission.authority_epoch, admission.generation) and queue.last_error == &"intent_queue_full",
		"intent queue rejects overflow")


func _test_journal_bound(fixture: Dictionary) -> void:
	var raid := ZRaidId.parse(String(fixture["raid_id"]))
	var actor := ZEntityId.from_parts(PackedStringArray(["fixture", "journal", "actor"]))
	var journal := RaidEventJournal.new()
	check(journal.configure(raid, 2), "bounded journal configures")
	var first_id := ZConsequenceId.from_parts(PackedStringArray(["journal", "first"] ))
	var second_id := ZConsequenceId.from_parts(PackedStringArray(["journal", "second"] ))
	var third_id := ZConsequenceId.from_parts(PackedStringArray(["journal", "third"] ))
	check(journal.append(ZRaidEvent.EventKind.SPAWN, first_id, 1, actor, {}),
		"journal appends first event")
	check(not journal.append(ZRaidEvent.EventKind.SPAWN, first_id, 1, actor, {})
		and journal.last_error == &"duplicate_event", "journal deduplicates consequence identity")
	check(journal.append(ZRaidEvent.EventKind.LOOT, second_id, 2, actor, {}),
		"journal appends through capacity")
	check(not journal.append(ZRaidEvent.EventKind.FIRE, third_id, 3, actor, {})
		and journal.last_error == &"journal_full", "journal fails closed at capacity")
	check(journal.size() == 2, "journal capacity rejection preserves records")
	var oversized := RaidEventJournal.new()
	check(not oversized.configure(raid, RaidEventJournal.DEFAULT_MAX_EVENTS + 1),
		"journal configuration cannot exceed its declared hard bound")
	var large := RaidEventJournal.new()
	check(large.configure(raid, ZCanonicalValue.DEFAULT_MAX_COLLECTION + 1),
		"journal can use capacity beyond one canonical payload collection")
	var all_appended := true
	for index in ZCanonicalValue.DEFAULT_MAX_COLLECTION + 1:
		var event_id := ZConsequenceId.from_parts(PackedStringArray([
			"journal",
			"large_%04d" % index,
		]))
		if not large.append(ZRaidEvent.EventKind.TASK, event_id, index, actor, {"value": index}):
			all_appended = false
			break
	check(all_appended and large.size() == ZCanonicalValue.DEFAULT_MAX_COLLECTION + 1,
		"journal reaches configured capacity above canonical collection limits")
	check(not large.digest().is_empty(), "large bounded journal retains a deterministic digest")
	var admission := SessionCoordinator.new().open_offline(raid, &"large_digest", &"player")
	var authority := RaidAuthority.new()
	check(authority.configure(raid, admission, 13), "large-digest authority configures")
	var authority_appended := true
	for index in ZCanonicalValue.DEFAULT_MAX_COLLECTION + 1:
		var event_id := ZConsequenceId.from_parts(PackedStringArray([
			"authority_journal",
			"large_%04d" % index,
		]))
		if not authority.record_event(
			ZRaidEvent.EventKind.TASK,
			event_id,
			0,
			admission.actor_id,
			{"value": index},
			authority.generation()
		):
			authority_appended = false
			break
	check(authority_appended and not authority.state_digest().is_empty(),
		"authority digest remains available for a journal beyond generic payload limits")


func _test_admitted_intent_snapshot(fixture: Dictionary) -> void:
	var raid := ZRaidId.parse(String(fixture["raid_id"]))
	var admission := SessionCoordinator.new().open_offline(raid, &"snapshot", &"player")
	var queue := ZRaidIntentQueue.new()
	var intent := ZRaidIntent.create(
		ZRequestId.from_parts(PackedStringArray(["snapshot", "intent_001"] )),
		ZRaidIntent.Source.PLAYER,
		admission.session_id,
		admission.actor_id,
		admission.authority_epoch,
		admission.generation,
		1,
		1,
		&"move",
		{"axis": Vector2i(1, 0)}
	)
	check(queue.admit(intent, 0, admission.session_id, admission.actor_id,
		admission.authority_epoch, admission.generation), "snapshot fixture intent is admitted")
	intent.target_tick = 2
	intent.sequence = 99
	intent.session_id = ZSessionId.from_parts(PackedStringArray(["offline", "mutated", "00000001"] ))
	intent.payload = {"axis": 0.5}
	var due := queue.drain_tick(1)
	check(due.size() == 1 and due[0].target_tick == 1 and due[0].sequence == 1,
		"post-admission envelope mutation cannot change queue timing or order")
	if due.size() == 1:
		check(due[0].session_id.is_equal(admission.session_id)
			and due[0].payload == {"axis": Vector2i(1, 0)},
			"post-admission mutation cannot bypass identity or payload validation")


func _test_nested_drain_guard(fixture: Dictionary) -> void:
	var raid := ZRaidId.parse(String(fixture["raid_id"]))
	var admission := SessionCoordinator.new().open_offline(raid, &"nested_drain", &"player")
	var authority := RaidAuthority.new()
	check(authority.configure(raid, admission, 5), "nested-drain authority configures")
	var generation := authority.generation()
	check(authority.register_phase_handler(
		RaidAuthority.TickPhase.MOVEMENT,
		&"nested_drain_probe",
		_nested_drain_probe,
		generation
	), "nested-drain probe registers")
	check(authority.transition(RaidAuthority.Lifecycle.ACTIVE, generation),
		"nested-drain authority activates")
	check(authority.request_clock_ticks(2, generation) == 2,
		"nested-drain fixture schedules two ticks")
	check(authority.drain_requested_ticks(generation) == 2,
		"outer drain processes every scheduled tick")
	check(nested_drain_rejections == 2 and authority.clock.current_tick == 2
		and authority.last_processed_tick == 2 and authority.clock.pending_ticks == 0,
		"nested drains reject before consuming backlog or advancing the clock")


func _nested_drain_probe(
	authority: RaidAuthority,
	_phase: RaidAuthority.TickPhase,
	_tick: int,
	_intents: Array[ZRaidIntent]
) -> bool:
	var pending_before := authority.clock.pending_ticks
	var result := authority.drain_requested_ticks(authority.generation())
	var rejected := result == 0 and authority.last_error == &"reentrant_tick"
	if rejected and authority.clock.pending_ticks == pending_before:
		nested_drain_rejections += 1
	return rejected


func _test_advance_one_with_backlog(fixture: Dictionary) -> void:
	var raid := ZRaidId.parse(String(fixture["raid_id"]))
	var admission := SessionCoordinator.new().open_offline(raid, &"single_step", &"player")
	var authority := RaidAuthority.new()
	check(authority.configure(raid, admission, 6), "single-step authority configures")
	var generation := authority.generation()
	check(authority.transition(RaidAuthority.Lifecycle.ACTIVE, generation),
		"single-step authority activates")
	check(authority.request_clock_ticks(3, generation) == 3,
		"single-step fixture schedules a backlog")
	check(authority.advance_one(generation), "advance_one succeeds with an existing backlog")
	check(authority.clock.current_tick == 1 and authority.last_processed_tick == 1
		and authority.clock.pending_ticks == 2,
		"advance_one consumes exactly one pending tick")
	check(authority.drain_requested_ticks(generation) == 2
		and authority.last_processed_tick == 3,
		"remaining backlog drains without a skip or false failure")


func _test_handler_failure_consistency(fixture: Dictionary) -> void:
	var raid := ZRaidId.parse(String(fixture["raid_id"]))
	var admission := SessionCoordinator.new().open_offline(raid, &"handler_failure", &"player")
	var authority := RaidAuthority.new()
	check(authority.configure(raid, admission, 7), "failure authority configures")
	var generation := authority.generation()
	check(authority.register_phase_handler(
		RaidAuthority.TickPhase.WORLD_CONSEQUENCES,
		&"fail_after_commit",
		_fail_after_commit,
		generation
	), "failure handler registers")
	check(authority.transition(RaidAuthority.Lifecycle.ACTIVE, generation),
		"failure authority activates")
	check(authority.request_clock_ticks(3, generation) == 3,
		"failure fixture schedules a backlog")
	check(authority.drain_requested_ticks(generation) == 0
		and authority.last_error == &"phase_handler_failed",
		"failed handler terminates the drain with a stable diagnostic")
	check(authority.lifecycle == RaidAuthority.Lifecycle.FAILED
		and authority.clock.current_tick == authority.last_processed_tick
		and authority.last_processed_tick == 1 and authority.clock.pending_ticks == 0,
		"failed tick is consumed consistently and remaining backlog is cleared")
	check(authority.journal.size() == 1 and authority.journal.is_sealed(),
		"committed audit prefix is retained and sealed on handler failure")


func _fail_after_commit(
	authority: RaidAuthority,
	_phase: RaidAuthority.TickPhase,
	tick: int,
	_intents: Array[ZRaidIntent]
) -> bool:
	var event_id := ZConsequenceId.from_parts(PackedStringArray([
		"failure",
		"tick_%04d" % tick,
	]))
	authority.record_event(
		ZRaidEvent.EventKind.TASK,
		event_id,
		tick,
		authority.admission().actor_id,
		{"committed": true},
		authority.generation()
	)
	return false


func _test_event_tick_gate(fixture: Dictionary) -> void:
	var raid := ZRaidId.parse(String(fixture["raid_id"]))
	var admission := SessionCoordinator.new().open_offline(raid, &"event_tick", &"player")
	var authority := RaidAuthority.new()
	check(authority.configure(raid, admission, 11), "event-tick authority configures")
	var generation := authority.generation()
	check(authority.transition(RaidAuthority.Lifecycle.ACTIVE, generation),
		"event-tick authority activates")
	var future_id := ZConsequenceId.from_parts(PackedStringArray(["event_tick", "future"] ))
	check(not authority.record_event(
		ZRaidEvent.EventKind.SPAWN,
		future_id,
		1,
		admission.actor_id,
		{},
		generation
	) and authority.last_error == &"event_tick_invalid" and authority.journal.size() == 0,
		"out-of-band callback cannot poison the journal with a future tick")
