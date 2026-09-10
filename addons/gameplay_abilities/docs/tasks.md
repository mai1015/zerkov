# Deterministic Ability Tasks

Ability Tasks are bounded, serializable waits owned by an active ability
execution. They provide the useful part of Unreal GAS-style asynchronous
abilities—charge windows, channels, combo input, gameplay-event waits, tag
edges, authority barriers, and targeting—without storing `Node`, timer,
callable, signal, `InputEvent`, or physics state in the deterministic core.

An immediate ability does not need a task. A long-running ability normally
sets `ends_on_commit = false`, starts a task from its behavior hook, and reacts
to the immutable terminal task event through the same bounded command builder.

## Lifecycle and ownership

Every active task contains a stable component-local handle, parent execution
and spec, task kind, start/due/deadline ticks, normalized kind payload,
visibility, prediction policy, provenance, and prediction key.

- Only non-terminal tasks are stored.
- Complete, fail, timeout, and cancel detach indexes before publishing one
  immutable terminal event.
- A duplicate terminal command never calls the task hook again.
- Ending/cancelling the parent, revoke-cancel, authority correction, and owner
  teardown cancel all owned tasks in handle order.
- Parent cleanup intentionally does not invoke one task callback per child; it
  avoids callback storms during teardown.
- Task callbacks submit commands after the current transaction/notification
  batch. They cannot synchronously recurse into another task transition.

Task handles are meaningful only inside their component/session. Never persist
or compare them as project-wide identifiers.

## Built-in kinds

| Kind | Completes when | Kind-specific request fields |
|---|---|---|
| `KIND_WAIT_TICKS` | The authority gameplay tick reaches `start_tick + wait_ticks` | `wait_ticks >= 1` |
| `KIND_WAIT_GAMEPLAY_EVENT` | The first post-start matching registered event is committed | `gameplay_event_tag`, `gameplay_event_match` |
| `KIND_WAIT_TAG_QUERY` | The registered query crosses the requested edge | `tag_query`, `tag_edge`, `complete_if_already_satisfied` |
| `KIND_WAIT_LOGICAL_INPUT` | The expected registered logical input and phase arrive with a valid sequence | `logical_input`, `logical_phase` |
| `KIND_WAIT_AUTHORITY` | Immediately on authority, or when the owning client receives the matching acknowledgement | `authority_prediction_key` |
| `KIND_WAIT_TARGET_DATA` | Its targeting session confirms/resolves, rejects, cancels, or times out | `target_schema`; see [targeting.md](targeting.md) |

Gameplay-event waits are broadcast, not consume-first: every matching waiter
completes in ascending task-handle order. A newly started task cannot observe
an event or tag edge already being dispatched.

Every kind may set `has_deadline = true` and an absolute `deadline_tick`.
Deadlines win over ordinary same-tick events/input.

## `GameplayAbilityTaskRequest`

This immutable-after-submission `Resource` is the GDScript request wrapper.

Common properties:

- `kind`
- `has_deadline`, `deadline_tick`
- `visibility`: `VISIBILITY_OWNER_ONLY`, `VISIBILITY_OBSERVABLE`, or
  `VISIBILITY_INTERNAL`
- `prediction_policy`: `PREDICTION_AUTHORITY_ONLY`, `PREDICTION_SAFE`, or
  `PREDICTION_REQUIRES_AUTHORITY`

Only fields belonging to the selected kind may be populated. Hidden payload
from another kind is rejected rather than ignored.

## Starting and querying tasks

The preferred path is the active hook’s capability-limited builder:

```gdscript
func on_execute(
        context: Dictionary,
        builder: GameplayAbilityCommandBuilder
    ) -> bool:
    var request := GameplayAbilityTaskRequest.new()
    request.kind = GameplayAbilityTaskRequest.KIND_WAIT_TICKS
    request.wait_ticks = 12
    request.visibility = GameplayAbilityTaskRequest.VISIBILITY_OWNER_ONLY
    var started := builder.request_task(request)
    return started["status"]["ok"]


func on_task_event(
        context: Dictionary,
        event: Dictionary,
        builder: GameplayAbilityCommandBuilder
    ) -> bool:
    if event["outcome"] != GameplayAbilityComponent.TASK_COMPLETED:
        return builder.submit({"kind": 7})["status"]["ok"] # cancel parent
    return builder.submit({"kind": 6})["status"]["ok"] # end parent
```

Bind both callbacks:

```gdscript
component.bind_authority_hook(
    "ability.example.channel", on_execute, on_task_event)
```

The ability must declare `hook_binding = 1` (`AUTHORITY_ONLY`). A
prediction-safe ability uses `bind_prediction_safe_hook(..., task_callable)`
and must pass all prediction conformance checks.

Game/test orchestration may call the explicit component API:

| Method | Purpose |
|---|---|
| `start_ability_task(execution, request, tick, provenance)` | Start under a live parent |
| `cancel_ability_task(task, tick, reason, provenance)` | Explicitly cancel one task |
| `has_ability_task(task)` / `get_ability_task(task)` | Read immutable state |
| `active_ability_tasks()` | Handles in canonical order |
| `ability_tasks_for_execution(execution)` | One parent’s handles |
| `notify_restored_ability_tasks(tick)` | Emit presentation-only restored notifications |

`get_ability_task()` returns the task identity/parent, request dictionary,
start/due ticks, last input sequence, provenance, and prediction key. It never
returns a mutable core object.

## Logical input adapters

`WAIT_LOGICAL_INPUT` receives a logical identity and one phase:
press, release, confirm, or cancel. The game owns mapping from devices or
automation to that logical command.

Authority/offline/AI:

```gdscript
component.submit_logical_input(
    execution,
    task,
    "input.ability.primary",
    GameplayAbilityComponent.LOGICAL_INPUT_RELEASE,
    next_command_sequence(),
    0, # prediction key
    authority_tick,
    GameplayAbilityComponent.PROVENANCE_AUTHORITATIVE)
```

Owning network client:

```gdscript
bridge.request_task_input_networked(
    task,
    GameplayAbilityComponent.LOGICAL_INPUT_RELEASE,
    next_command_sequence(),
    client_tick,
    prediction_key)
```

The server validates session ownership, component/execution/task identity,
expected kind/input/phase, monotonic sequence, deadline, payload, and rate.
A duplicate replays its cached result and cannot complete the task twice.

Physical `InputEvent`, CommonUI widget identity, key codes, animation notifies,
and frame timestamps never enter the task snapshot or protocol.

Reference adapters:

- Ordinary input/AI and a complete charge-channel-combo flow:
  [`ga_channel_charge_combo_ability.gd`](../../../examples/gameplay_abilities/tasks/ga_channel_charge_combo_ability.gd)
- CommonUI confirm/cancel composition follows the game-owned adapter boundary
  in the
  [integration guide](integration.md#feeding-ability-tasks-and-typed-targeting).

This standalone mirror does not ship a CommonUI-specific adapter, and the
GameplayAbilities addon has no CommonUI dependency.

## Task events and signals

`GameplayAbilityComponent.ability_task_event(event)` publishes starts,
terminals, and explicit restored-state notifications. Important fields:

```text
task, owner, execution, spec, ability, ability_identifier,
kind, outcome, cancel_reason, status, tick, provenance, prediction_key,
restored, matched_definition, matched_identifier, instigator, target,
magnitude, payload_tag, logical_phase, command_sequence, target_session,
target_context
```

Outcomes are `TASK_ACTIVE`, `TASK_COMPLETED`, `TASK_FAILED`,
`TASK_TIMED_OUT`, and `TASK_CANCELLED`.

Cancel reasons distinguish explicit cancellation, parent end/cancel,
spec revoke, owner teardown, authority correction, and target-session
cancellation. Presentation should branch on the enum/status, not parse text.

Signals are deferred until the transaction commits and carry copied
Dictionaries. Retaining a `GameplayAbilityCommandBuilder` after its callback
returns is invalid; later calls fail closed.

## Ordering

For one component tick:

1. owner teardown or authority correction;
2. authoritative ability/task cancellation commands;
3. deadlines and due ticks;
4. committed tag-query edges;
5. committed gameplay events;
6. validated logical input;
7. task callback command batches.

Tie-breakers are parent execution, task handle, then event sequence. Work
created by a callback or signal runs in a later queue turn.

## Snapshots, reconnect, and restore

Component snapshots include active tasks, kind payload, parent/prediction
links, indexes, allocator state, deadlines, and input/event baselines.
Restore validates into temporary state and then swaps atomically.

Restore never replays:

- the original task start;
- historical input or gameplay events;
- task terminal callbacks;
- one-shot signals or effects.

Call `notify_restored_ability_tasks()` after the owning presentation layer is
ready. It emits `restored = true` for each visible active wait so UI can rebuild
a progress bar or targeting screen without re-running gameplay continuation.
Network bridge owner snapshots use the same rule for late join, reconnect,
gap resync, and authority correction.

`visibility` governs replication, not just the local record: `INTERNAL`
tasks are never sent to any remote peer, including the task's own owner —
the network bridge's owner-facing snapshot/event-batch paths always filter
the task section to `OWNER_ONLY` before it crosses the wire, so an `INTERNAL`
task exists only in the authoritative baseline. `OWNER_ONLY` (the default)
replicates to the owning client only. `OBSERVABLE` is additionally eligible
for observer-visible state, and (protocol 3, `FeatureSet::OBSERVER_TASK_STATE`)
the observer wire payload (`encode_public_state`) now carries a bounded,
whitelisted observable-task section: `public_state_updated`'s
`observable_tasks` array lists every currently active `OBSERVABLE` task's
handle, execution, owning ability identifier, kind, and start/deadline ticks
— never prediction, provenance, sequence, or wait-condition detail, and never
an `OWNER_ONLY`/`INTERNAL` task — as current-state data with no historical
replay. See "Task state visibility" in [protocol.md](protocol.md) for the
full table, the whitelist record layout, and the exact wire paths this
applies to.

## Prediction

Prediction is allowlisted:

- tick waits may use the negotiated tick timeline;
- tag queries require owner-visible rollback-covered state;
- logical input may predict but remains an authority command;
- gameplay events must already be represented in the journal;
- `WAIT_AUTHORITY` is the continuation barrier for everything else;
- target waits follow the schema/provider policy in
  [targeting.md](targeting.md).

Rejection restores the latest confirmed component/coordinator baselines,
including task/session allocators and indexes, then replays still-eligible
commands once. Do not use hidden scene state, random numbers, client-only
physics, wall time, or unrestricted callbacks in a prediction-safe hook.

A request combining `prediction_policy = PREDICTION_SAFE` with
`visibility = VISIBILITY_INTERNAL` is rejected at start (and at restore):
an `INTERNAL` task is never replicated back to its own owner, so a locally
predicted one could never receive the authoritative confirmation/correction
it needs to reconcile. This is additive — `visibility` defaults to
`VISIBILITY_OWNER_ONLY`, so an ordinary prediction-safe task request is
unaffected.

## Safe hook rules

- Use the supplied immutable context and builder only.
- Keep external side effects out of validation/preparation and
  prediction-safe callbacks.
- Submit `END_EXECUTION`/`CANCEL_EXECUTION` through the builder instead of
  directly mutating the component from inside a callback.
- Use authoritative gameplay events for montage/simulation notifies that
  affect gameplay. A local animation signal is presentation only.
- Keep the controller object that owns bound `Callable`s alive.
- Drive ticks from the negotiated game simulation, not `SceneTreeTimer`.

## Budgets

Hard limits in `ga_limits.h` include:

- 32 active tasks per component;
- 8 tasks per execution;
- 128 task terminal events and 128 logical inputs per tick;
- 256 bytes per task payload;
- a deadline horizon of 864,000 ticks.

Exhaustion returns structured `CAPACITY_EXCEEDED`, `OUT_OF_BOUNDS`, or
`RATE_LIMITED`; no live task is silently evicted.

## Migrating scene-owned waits

1. Keep the current ability definition, but set `ends_on_commit = false`.
2. Replace the timer/signal continuation with one task request.
3. Move continuation decisions into the task callback and builder.
4. Feed device/UI/AI input through a logical adapter.
5. Rebuild presentation from restored events.
6. Verify cancel, revoke, owner teardown, snapshot, reconnect, and prediction
   correction before deleting the old Node/timer state.
