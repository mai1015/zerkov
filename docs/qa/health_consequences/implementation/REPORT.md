# Task 5.6 implementation evidence

Status: implementation candidate ready for independent acceptance. Task 5.6
remains unchecked by design.

- Recorded: 2026-09-11
- Branch: `codex/damage-injury-healing-death-5-6`
- Original base: `b0ead7da37dcf239c40dd3c706d94b0e457ca310`
- Integrated main: `1b201cb031ec174dad616334b302e22cc7a744c5`
- Intrinsic implementation checkpoint: `8a40030`
- Post-merge pre-evidence checkpoint: `fbee0bf`
- Engine: Godot `4.7.2.stable.official.ed1daf0bf`, headless only

## Implemented authority boundary

- `HealthConsequenceAdapter` is a game-owned phase-7 consumer. It accepts no
  presentation callback or mutable hit DTO: it reads exact immutable
  `zerkov.combat.weapon_consequence.v1` phase-6 journal records, verifies the
  complete key set, raid/session/epoch/generation/tick/actor envelope and
  canonical payload digest, and applies first-seen hits in journal sequence.
- Stable `ZEntityId` actor registrations bind an exact native
  `GameplayAbilityComponent` instance, entity ID, content fingerprint,
  registration generation, owned grant provenance and monotonically increasing
  command sequence. All 36 dormant health transitions are granted before the
  raid becomes active; initial alive/usable status is published once.
- Damage converts Weapon System milliunits to Gameplay Abilities micro-units
  through `ZWorldUnits`, enters only through
  `ZerkovHealthAbilityContent.apply_bounded_instant()`, and caps at the exact
  zone predecessor. A 25-unit committed hit starts heavy bleed; a 35-unit
  arm/leg hit also fractures. Secondary effects are evaluated once in the
  declared `heavy_bleed`, then `fracture` order.
- Heavy bleed has one actor/zone schedule, fixed one-unit damage every 60
  authority ticks, stable per-occurrence IDs and deterministic due ordering.
  Bandaging erases the exact schedule only after both health and inventory
  successors publish. Death erases every actor schedule.
- Lethal head or thorax damage activates the native dead transition, publishes
  dead/unusable weapon status and interrupts actor reloads during the damage
  operation. `DEATH` precedes `KILL`; same-tick treatments execute later and
  reject before inventory preparation. Further hit consequences are recorded
  as stable ignored-dead outcomes without damage, injury, reload or death
  replay.
- Bandage and splint definitions carry unique sealed inventory traits.
  `InventoryMedicalParticipant` selects one item in the fixed
  pockets/rig/backpack/secure order and exposes prepare, health check, silent
  commit, publication, exact-predecessor rollback and release through the
  narrow `MedicalInventoryParticipantPort`.
- Treatment ordering is target tick, request sequence, then stable request ID.
  Health transitions are snapshotted before mutation. A provably unchanged or
  rollbackable inventory rejection restores both domains; an ambiguous result
  fails the raid and preserves a bounded recovery record instead of retrying
  under a new identity. Exact owner-generation unload proves unfinished native
  holds can no longer commit and permits terminal recovery teardown.
- Damage, treatment and event ledgers never evict replay history. Journal space,
  event identities, damage capacity, treatment queue capacity, bleed schedule
  capacity and native grants are preflighted before the applicable cross-domain
  mutation. Unexpected failure after a committed boundary is reported as
  committed/ambiguous and requires authoritative teardown.
- `RaidEventJournal.remaining_capacity()` is a read-only preflight seam. No
  `RaidAuthority`, add-on, UI, viewport, screen, visual or capture source was
  changed.

## Focused permanent contract

`tests/combat/health_consequence_adapter_contract.gd` uses the real native
Gameplay Abilities component and real Inventory System authority. It covers:

- exact weapon-journal intake and fixed-unit zone damage;
- ordered bleed/fracture state, pain and leg movement effects;
- tick-61 bleed damage and stable schedule removal;
- lethal state, death-before-kill, reload interruption and post-death replay;
- real bandage/splint trait reservation, release, commit and quantity change;
- health/inventory rollback on a proven participant rejection;
- same-tick death-before-treatment and no item preparation;
- ambiguous participant fail-stop, failed premature recovery, and proven
  teardown recovery;
- same-tick treatment ordering independent of arrival order;
- 64-entry pending capacity, 65th rejection and queued replay;
- release terminalization and late-command rejection;
- malformed source digest and one-slot journal preflight before health mutation;
- repeated ordered inputs producing equal normalized native state/event traces.

Focused run 1: `204/0`.

Focused run 2: `204/0`.

## Adjacent headless contracts

| Contract | Result |
| --- | ---: |
| Body hitbox | 111/0 |
| Body hitbox adversarial | 173/0 |
| Body hitbox review regression | 72/0 |
| Body hitbox capability encapsulation | 14/0 |
| Weapon combat adapter | 368/0 |
| Health ability content | 392/0 |
| Combat content | 80/0 |
| Weapon instance context | 308/0 |
| Weapon context adversarial | 49/0 |
| Weapon persistence integration | 43/0 |
| Inventory catalog | 551/0 |
| Inventory authority | 79/0 |
| Inventory/ability reconciliation | 562/0 |
| Inventory/weapon reload | 176/0 |
| Authority replay/journal | 81/0 |
| Session lifecycle | 44/0 |
| Units/clock | 41/0 |
| Identity collision | 18,442/0 |
| Vision world | 305/0 |
| Combined add-ons smoke | 155/0 |

Adjacent result: `22,046/0`.

Focused plus adjacent: `22,454/0`.

## Import, validation, hashes and diff

- Fresh post-merge pinned headless editor import exited 0 with no diagnostic.
- Strict validation of `add-zerkov-playable-raid-2026-09-09` returned `Valid`.
- Vendored-add-on integrity tests passed `4/4`; no add-on source changed.
- `git diff --check` passed. The task diff contains no `RaidAuthority`, UI,
  viewport, visual or capture file.
- `frozen_sources.sha256` seals the implementation, focused contracts,
  governing instructions, approved inputs and accepted Task 5.4/5.5 evidence.
  `packet.sha256` seals this report, the structured results and source manifest.
- Task 5.6 remains unchecked pending independent review.

## Limits and remaining risks

- This boundary is synchronous, in-memory, single-writer and no-yield. A live
  adapter recognizes exact redelivery; the raid journal also rejects reused
  consequence IDs. Cold-process/durable/network replay requires later
  persistence and multiplayer work.
- A health adapter cannot cold-bind after hit history already exists because it
  cannot prove whether a replacement native component contains those effects;
  composition must retain the binding or perform authoritative teardown.
- Limits are 64 actors, 4,096 damage results, 512 treatment identities with 64
  pending, 256 bleed schedules, 16,384 reserved event identities and the
  journal's configured maximum. Saturation is fail-stop, never eviction.
- The full real death-during-native-reload race is deferred to Task 5.10. This
  contract verifies the exact actor-scoped interruption call and its once-only
  ordering; the adjacent real inventory/reload contract independently verifies
  that `interrupt_reload(..., death, tick)` releases uncommitted holds.
- Task 5.7 still owns logical quick-heal routing. Melee consequences, HUD and
  presentation, tuning/human approval, settlement/death loss, durable recovery,
  networking and release readiness remain outside Task 5.6.
