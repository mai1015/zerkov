# Combat input ingress (task 5.7 candidate)

This component converts the existing CommonUI combat actions, or root-owned AI
requests, into the existing `ZRaidIntent` queue. It does **not** execute attacks,
reloads, treatment or melee, install CommonUI callbacks, or change the production
bootstrap. Task 5.7 stays unchecked until those integration paths are exercised.

## One sequence owner

Use **one `ZCombatInputAdapter` per actor/source** for both movement and combat.
It extends `UIIntentAdapter`; inherited directional movement helpers dispatch to
the same bounded allocator. Do not retain a separate task-3 movement encoder for
that actor/source. Existing movement normalization and payloads are unchanged.

Bindings are one-shot and copy the session/actor identities. Generated request
IDs include session, actor, source, authority epoch, generation and sequence.
Changing sessions requires a new encoder/router/sink. Rejected schema requests
consume no sequence; attempted queue submissions never recycle a sequence.
The existing queue owns duplicate detection, not a second combat-history ledger.

## Schemas

Logical IDs remain `common_ui/zerkov/gameplay/<action>`; canonical kinds are
`combat_<action>`. All six actions have an exact payload schema:

| Action | Payload |
| --- | --- |
| aim | `direction_milli: Vector2i`, `aiming: bool` |
| fire | `weapon_id`, `expected_weapon_revision` |
| reload | `weapon_id`, `expected_weapon_revision`, `expected_inventory_revision` |
| cancel_reload | `weapon_id`, `reservation_id` |
| melee | `weapon_id`, `expected_inventory_revision` |
| quick_heal | `body_zone`, `treatment`, `expected_health_revision`, `expected_inventory_revision` |

Weapon IDs identify runtime equipment instances, not short content definitions.
Revisions are nonnegative integers. Treatment is `bandage` or `splint` and the
body zone is one of the seven existing health zones. Aim direction is nonzero,
with each component in [-1000,1000]; its magnitude does not grant range or speed.
The direction convention matches AI requests. `aiming=false` represents aim
release. Obtain cursor direction through the existing task-3 presentation/input
adapter, not a world-position field supplied to the weapon authority.

All revisions, weapon IDs and reservation IDs are **claims**: domain consumers
must recheck current ownership, equipment, revision, resource, range and timing.
No caller-controlled hit, damage, spread seed, stamina cost or actor identity is
accepted in these payloads. Quick-heal selection must use the player's confirmed
health/inventory view; this ingress never silently chooses or consumes an item.

## Root composition

Bind `RaidCombatIntentSink` to the real `RaidAuthority`, its generation and an
already-authorized actor/source. Then bind an encoder and router for that exact
context. For example, the following is the setup shape (each failure must be
handled by the caller before enabling gameplay input):

```gdscript
var input := ZCombatInputAdapter.new()
var sink := RaidCombatIntentSink.new()
var router := ZCombatActionRouter.new()
var admission := raid.admission()
if not input.configure(admission.session_id, admission.actor_id,
        admission.authority_epoch, raid.generation()):
    return false
if not sink.bind(raid, admission.actor_id, ZRaidIntent.Source.PLAYER,
        raid.generation()):
    return false
if not router.bind(input, sink):
    return false
```

Call `submit_logical()` only from the active gameplay CommonUI context; CommonUI
retains physical binding, modal/context and focus filtering. There is no new
InputMap polling or automatic-fire loop here. Supply the captured generation and
exact next authority tick. Use `submit_movement()` on the same router for task-3
movement. An AI/root port uses `configure_source(..., Source.AI)` and
`submit_action()` with the same schema; `submit_logical()` cannot impersonate AI.
The concrete AI world port must resolve its own equipment/revision claims; the
existing value-only AI decisions are not automatically connected by this PR.

Every receipt says `committed=false`: `admitted=true` means only that a command
entered the queue. A malformed or contradictory sink result returns
`admitted=null, outcome_unknown=true` and closes further admission. Do not retry
such a result under a fresh ID assuming nothing happened. Exact producer request
IDs may be supplied for safe duplicate detection; the queue rejects duplicate
requests, it does not return a downstream execution receipt.

The root owns the sink; neither UI models nor AI brains receive RaidAuthority.
Release retained input bindings during teardown. Reentry into admission or
release is rejected while a sink callback is in flight.

## Verification and remaining work

```sh
python3 tests/tooling/test_combat_input_runner.py
python3 tools/run_combat_input_contracts.py --godot "$ZERKOV_GODOT"
python3 tools/run_combat_input_contracts.py --godot "$ZERKOV_GODOT" --native
```

Both runner modes import temporary copies and read the engine pin from
`config/toolchain.lock.json`. Default mode executes the actual IDs, movement
encoder and raid intent queue with an explicitly named authority-context/sink
test double. Native mode additionally uses the concrete sink, real
RaidAuthority and existing action catalog. Its probe consumes envelopes only;
it does not fabricate successful weapon/health operations. Missing native
classes and script errors fail the run, even when a process otherwise exits 0.
The new entrypoints are registered in the existing exact-1080 gate inventory.

The existing production bootstrap and UI are unchanged. The next combat change
must connect accepted intents to aim/pose, `WeaponCombatAdapter.commit_fire`,
`InventoryWeaponAdapter` and `HealthConsequenceAdapter.queue_treatment`, with
current binding/revision checks and actual execution receipts. Task 5.8 must
implement authoritative melee before a queued melee command can deal damage.
Tasks 5.9 and 5.11-5.13 remain HUD, readability, encounter tuning and human
playtest work. These routing regressions support 5.10 but do not prove its full
cadence/ammo/reload/death acceptance matrix. No task checkbox is changed.
