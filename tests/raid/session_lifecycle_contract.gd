extends SceneTree
## Run with: godot --headless --path . --script res://tests/raid/session_lifecycle_contract.gd

var checks: int = 0
var failures: int = 0
var mutation_count: int = 0
var late_rejections: int = 0


func _initialize() -> void:
	call_deferred("run")


func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("SESSION_LIFECYCLE_CONTRACT: " + message)


func run() -> void:
	var raid := ZRaidId.from_parts(PackedStringArray(["fixture", "lifecycle_001"]))
	check(raid != null, "raid fixture identity constructs")
	var coordinator := SessionCoordinator.new(OfflineSessionIngress.new())
	var first := coordinator.open_offline(raid, &"profile_a", &"player")
	check(first.is_usable(), "offline session is admitted through the ingress port")
	check(first.trust_level == ZSessionAdmission.TrustLevel.LOCAL_TRUSTED,
		"offline session is explicitly local-trusted")
	check(first.authority_epoch == 1 and first.generation == 1,
		"first authority epoch and generation are stable")
	check(first.session_id.canonical_key() == "zerkov.session.offline.profile_a.00000001",
		"offline session ID is canonical")
	check(first.actor_id.canonical_key() == "zerkov.entity.offline.profile_a.player.00000001",
		"offline actor ID is canonical")

	var second := coordinator.open_offline(raid, &"profile_a", &"player")
	check(second.is_usable() and second.authority_epoch == 2, "authority epochs are monotonic")
	check(not first.session_id.is_equal(second.session_id), "replacement session identity is unique")
	check(not first.actor_id.is_equal(second.actor_id), "replacement actor identity is unique")
	var malformed := coordinator.open_offline(raid, &"Bad Profile", &"player")
	check(not malformed.accepted and malformed.reason == &"malformed_session_request",
		"malformed local identity is rejected")
	check(coordinator.next_authority_epoch() == 4, "rejected admission cannot reuse its epoch")

	var remote_request := ZSessionRequest.create_offline(
		ZRequestId.from_parts(PackedStringArray(["session", "remote", "00000099"])),
		raid,
		&"profile_a",
		&"player",
		99
	)
	remote_request.mode = ZSessionRequest.Mode.REMOTE
	var remote_result := OfflineSessionIngress.new().admit(remote_request)
	check(not remote_result.accepted and remote_result.reason == &"offline_ingress_rejects_remote",
		"offline ingress cannot silently authenticate a remote request")

	var authority := RaidAuthority.new()
	check(authority.configure(raid, first, 7283), "authority configures once")
	var generation := authority.generation()
	first.authority_epoch = 999
	first.generation = 999
	first.session_id = ZSessionId.from_parts(PackedStringArray(["offline", "mutated", "00000999"] ))
	check(authority.generation() == generation
		and authority.admission().authority_epoch == generation
		and authority.admission().session_id.canonical_key()
			== "zerkov.session.offline.profile_a.00000001",
		"authority snapshots admission identity and epochs at configuration")
	check(not authority.configure(raid, first, 7283), "authority rejects reconfiguration")
	check(not authority.transition(RaidAuthority.Lifecycle.COMPLETED, generation),
		"preparing cannot skip directly to completed")
	check(authority.lifecycle == RaidAuthority.Lifecycle.PREPARING,
		"invalid transition is fail-atomic")
	check(authority.transition(RaidAuthority.Lifecycle.ACTIVE, generation),
		"preparing transitions to active")
	check(authority.clock != null and not authority.clock.paused, "active raid clock runs")
	check(authority.transition(RaidAuthority.Lifecycle.EXTRACTING, generation),
		"active transitions to extracting")
	check(authority.transition(RaidAuthority.Lifecycle.ACTIVE, generation),
		"cancelled extraction returns to active")
	check(authority.transition(RaidAuthority.Lifecycle.SETTLING, generation),
		"active transitions to settling")
	check(authority.clock.paused, "settling pauses gameplay ticks")
	check(authority.transition(RaidAuthority.Lifecycle.COMPLETED, generation),
		"settling transitions to completed")
	check(not authority.transition(RaidAuthority.Lifecycle.ACTIVE, generation),
		"completed raid cannot reactivate")
	check(not authority.apply_if_current(generation, _increment_mutation),
		"completed raid rejects late callback mutation")
	check(mutation_count == 0, "rejected completed callback has no effect")
	var terminal_event := ZConsequenceId.from_parts(PackedStringArray(["late", "completed"] ))
	check(not authority.journal.append(
		ZRaidEvent.EventKind.SETTLEMENT,
		terminal_event,
		authority.last_processed_tick,
		authority.admission().actor_id,
		{}
	) and authority.journal.last_error == &"journal_sealed",
		"completed authority seals direct journal mutation")
	var terminal_rng_state := authority.rng.state
	authority.rng.next_int(1000)
	check(authority.rng.state == terminal_rng_state and authority.rng.is_sealed(),
		"completed authority seals deterministic randomness")
	check(authority.clock.step(1).is_empty() and authority.clock.is_sealed(),
		"completed authority seals direct clock advancement")
	check(authority.teardown(generation), "completed raid can tear down")
	check(authority.lifecycle == RaidAuthority.Lifecycle.TORN_DOWN, "teardown is terminal")
	check(authority.generation() == generation + 1, "teardown invalidates captured generation")
	check(not authority.apply_if_current(generation, _increment_mutation),
		"stale deferred callback is rejected after teardown")
	check(not authority.teardown(generation), "stale teardown cannot repeat")
	check(mutation_count == 0, "late teardown callbacks cannot mutate state")
	check(second.generation != generation, "replacement admission has a distinct generation")

	var unusable := ZSessionAdmission.new()
	unusable.accepted = true
	unusable.request_id = ZRequestId.new()
	unusable.raid_id = raid
	unusable.session_id = ZSessionId.new()
	unusable.actor_id = ZEntityId.new()
	unusable.authority_epoch = 1
	unusable.generation = 1
	unusable.trust_level = ZSessionAdmission.TrustLevel.LOCAL_TRUSTED
	check(not unusable.is_usable(), "accepted admission rejects uninitialized typed identities")
	check(not RaidAuthority.new().configure(raid, unusable, 1),
		"authority rejects a malformed custom-ingress admission")

	var replacement := RaidAuthority.new()
	check(replacement.configure(raid, second, 7284), "replacement authority configures")
	var replacement_generation := replacement.generation()
	check(replacement.transition(RaidAuthority.Lifecycle.ACTIVE, replacement_generation),
		"replacement authority activates")
	var late_timer := Timer.new()
	late_timer.one_shot = true
	late_timer.wait_time = 0.01
	late_timer.timeout.connect(_late_callback.bind(replacement, replacement_generation))
	root.add_child(late_timer)
	late_timer.start()
	call_deferred("_late_callback", replacement, replacement_generation)
	check(replacement.teardown(replacement_generation),
		"replacement tears down before scheduled callbacks arrive")
	await create_timer(0.03).timeout
	check(late_rejections == 2, "deferred call and timer signal both reject stale generation")
	check(mutation_count == 0, "late deferred/timer work cannot mutate replaced raid")
	late_timer.queue_free()

	print("SESSION_LIFECYCLE_RESULT checks=", checks, " failures=", failures)
	quit(0 if failures == 0 else 1)


func _increment_mutation() -> void:
	mutation_count += 1


func _late_callback(authority: RaidAuthority, captured_generation: int) -> void:
	if not authority.apply_if_current(captured_generation, _increment_mutation):
		late_rejections += 1
