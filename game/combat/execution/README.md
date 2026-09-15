# Combat execution (tasks 5.7–5.11)

`RaidCombatSession` composes the existing native weapon, inventory and health
owners with authoritative hitboxes, locomotion, and the shared intent encoder.
It consumes a prepared roster; it never seeds a player loadout or reads UI sample
state. Deployment and settlement remain task 7 responsibilities.

## Composition

While `RaidAuthority` is PREPARING, authorize each actor/source, create its raid
inventory, and register its `ZPlayerLocomotion` handler. Then add one
`RaidCombatSession` to the tree and call `start(raid, roster, obstructions)`.
Each roster row is `{actor_id: ZEntityId, source: int, movement:
ZPlayerLocomotion, movement_handler: StringName, inventory: RaidInventoryOwner,
natural_melee: bool}`. Natural-mutant rows may omit inventory. The local player
must have inventory; no fallback gun, ammunition, or medical items are generated.
Check the result and release partial composition on failure.

Use one `ZCombatInputAdapter` per actor/source for both movement and combat.
`ZCombatInputBinding.bind()` registers callbacks with the real CommonUI runtime
and context service. Feed cursor direction through `set_aim_direction()`, and
flush movement before the next tick. Bind `ZCombatHudModel` to the actor's
`frame_published` records and inject it into the existing HUD with
`bind_combat_model()`. Neither binding is a replacement for task 7's normal
launch/deployment root.

## Order and ownership

- MOVEMENT resolves both admitted movement and combat aim, publishes poses, and
  replaces the complete body snapshot through an exact named publisher grant.
- INTERACTIONS_AND_WEAPONS runs existing equipment reconciliation before the
  command consumer. Fire calls the existing shot adapter. Reload/cancel use the
  inventory quantity-reservation adapter. Quick-heal queues the existing medical
  transaction. No UI callback spends ammunition, stamina, or health.
- WORLD_CONSEQUENCES resolves actual firearm and active melee queries. Obstruction
  ties win; melee uses a square-expanded AABB swept along the locked swing aim,
  not a claim of a circular capsule. One target maximum per swing.
- ABILITIES_AND_DUE_WORK resolves damage/bleed/death before treatment and new
  melee costs; resource cost goes through the sealed GAS ability. Cancellation
  does not refund a committed cost or allow a late animation callback to hit.
- PUBLISH_PROJECTIONS publishes detached confirmed values and explicitly
  provisional correction/feedback. Queue admission is not execution success.

Release input/HUD subscriptions and combat consumers before terminalizing the
raid. `release()` does not erase the externally owned raid inventories: task 7
must settle them under the selected extract/death policy.

## Content and provisional readability targets (5.11)

The existing AKM remains semi-automatic: 9-tick minimum cadence, 72-tick reload,
42 damage units. No automatic fire loop is added. Machete timing is 10 wind-up,
3 active, 18 recovery ticks, one target, 1.75-world-unit reach, 0.35-unit sweep
radius, and the existing 175,000-micro-unit stamina cost. These costs and timings
must not be silently changed by animation. Mutant claws are a separate natural
attack (12/3/30 ticks, 1.25-unit reach, 25 damage units).

Proposed acceptance targets, **not measured or human-approved tuning**:

| Cue | Target / verification |
| --- | --- |
| Aim | Cursor-to-world aim from task 3; no target snapping or hidden state. |
| Ammo / health | Publish in the same authority tick after commit; pending input never changes canonical numbers. |
| Reload | Tick-derived progress; cancelled/rejected reload never looks completed. |
| Muzzle / tracer / impact | One cue per consequence ID; obstruction and hit distinctly labelled; no second damage path. |
| Hit confirmation | Confirm damage only from the corresponding committed health result, not a visual collision. |
| Melee | Visible wind-up before contact; active/recovery state exposed from the authoritative timeline. |
| Correction | Rejected predictions revert without ammo refund or compensating damage; reason visible for 30 ticks. |
| Hit pause / camera impulse | Presentation only; authoritative replay must remain unchanged with effects enabled or disabled. |
| Injury / direction | Body zone and bleed/fracture from health; directional feedback must use disclosed consequence geometry only. |

Task 5.12 needs recorded encounters and visual/audio tuning; task 5.13 requires
blind human sessions. No headless contract substitutes for these acceptance
steps. World VFX/audio/animation presenters remain coordinated with task 9.

## Verification

```
python3 tests/tooling/test_combat_input_runner.py
python3 tools/run_combat_input_contracts.py --godot "$ZERKOV_GODOT" --execution
python3 tools/run_combat_input_contracts.py --godot "$ZERKOV_GODOT" --native --execution
```

The pure path checks the real input queue, timeline and HUD values. The native
path uses real addons and a test-only explicitly seeded roster. Missing native
libraries are failures, not passing skips. Both runners use temporary copies.
The PR's macOS Actions job records the exact source SHA and raw diagnostics as
short-lived CI artifacts, not repository files.

Current limits remain explicit: 16 combat actors, existing weapon/hitbox/health
ledger capacities, fixed 60 Hz, solo offline lifecycle. Long-raid capacities,
normal-launch composition, action handoff from AI, and supported-host regressions
must be checked before declaring the full first playable accepted.
