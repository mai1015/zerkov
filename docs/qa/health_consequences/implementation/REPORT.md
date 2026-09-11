# Task 5.6 implementation evidence

Status: diagnostic-repair candidate ready for renewed independent acceptance.
Task 5.6 remains unchecked by design.

- Recorded: 2026-09-11
- Branch: `codex/damage-injury-healing-5-6-diagnostic-final`
- Original base: `b0ead7da37dcf239c40dd3c706d94b0e457ca310`
- Sealed candidate: `fb8b1cf3d1cb11abc0f8d99aea815296ed4b56e5`
- Callback-repair candidate: `726492d2056b757e9f6023fc5d37dfda7e9f9e80`
- Integrated main: `e12dcd043625c22ea8b62cd7fce2587505bb03a8`
- Main-integration checkpoint:
  `ffe56dc2c0852c7734ad9c7890c41343987a6b0f`
- Intrinsic implementation checkpoint: `8a40030`
- Canonical-outcome checkpoint: `7ea5695`
- Reentrancy/recovery repair checkpoint: `21a5150`
- Post-merge pre-evidence checkpoint: `3e829d5`
- Native-cancellation repair checkpoint:
  `9d6035cb0a84b6278b20d69f67203d380ff0b703`
- Diagnostic public-error repair checkpoint:
  `87a78328530c44c00d39c9703895feb0de49f2db`
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
  successors publish. Death erases every actor schedule and records a bounded,
  same-phase cancellation proof so due work snapshotted before a lethal hit or
  lethal bleed is retired without disguising any other missing schedule.
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
  holds can no longer commit and permits terminal recovery teardown. Dequeued
  in-flight requests retain reservation and mutation state and become terminal
  only after teardown is proven; an invalidated authority cannot admit a new
  queue slot.
- Every synchronous callback-producing registration boundary is fenced before
  native initialization, revalidated after initialization and each grant, and
  restored byte-for-byte or quarantined on context loss. Production medical
  publication likewise revalidates its exact owner, authority, inventory,
  generation and identity after the native callback, reports a proven native
  publication as `committed`, and fail-stops instead of continuing stale work.
- Explicit release now raises the same mutation fence before unregistering the
  phase handler and keeps it raised across every medical-participant clear,
  native component teardown, recovery publication and final invalidation
  callback. Every guarded exit returns through one wrapper that clears the
  fence, including retryable failure. A stable actor/record teardown plan is
  captured before the first native callback boundary, so later actors are never
  looked up through callback-mutable live storage. Once a terminal invalidation
  or recovery signal returns, the outer operation restores its own public
  `last_error`; a callback can still observe its nested reentrant rejection,
  but cannot overwrite the already-emitted outer reason.
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
- lethal hit with a due bleed and lethal bleed with another due bleed;
- terminal recovery of dequeued ambiguous and committed-publication receipts;
- post-authority-teardown queue rejection without consuming capacity;
- production publication callback teardown, exact reservation recovery, and
  honest committed mutation reporting;
- public signal reentry rejection plus bootstrap-grant release fencing;
- callback-driven registration context change with exact snapshot cleanup;
- two-actor native activation cancellation rejecting recursive release while
  both captured components reach terminal cleanup exactly once;
- `binding_invalidated` callback reentry preserving the outer terminal reason,
  terminal pending-treatment receipt, journal history and cleanup;
- `recovery_latched` callback reentry preserving the outer failure reason,
  pending receipt/history and retryable teardown to one terminal receipt;
- refusal to treat owner lifecycle alone as proof of native inventory unload;
- repeated ordered inputs producing equal normalized native state/event traces.

Focused run 1: `444/0`.

Focused run 2: `444/0`.

## Independent adversarial probe

The review probe at
`/tmp/zerkov-5-6-review-evidence.COkob3/adversarial.gd` was run unchanged.
Its SHA-256 was
`5aae00d91b64c431388a95018a281aa6135dbd2026dd30b48341b9046062035d`.
It covers the eight independently reported lethal-work, queue, receipt,
publication, registration and unload-proof regressions.

Independent run 1: `197/0`.

Independent run 2: `197/0`.

## Sealed-review native-cancellation probe

The independent reproducer at
`/private/tmp/zerkov-5-6-sealed-review.ROSLAk/additional_callback_probe.gd`
was run unchanged. Its SHA-256 was
`10d08bd68c828e7ba4d2489d92e22ab0321224e6083fb98273b5532e001ae631`.
Both runs proved that the first actor's native `activation_cancelled` callback
receives `health_binding_change_reentrant`, the outer release succeeds, the
adapter retains no actors, and both registered components are torn down.

Callback run 1: `11/0`.

Callback run 2: `11/0`.

## Reviewer diagnostic reentry reproduction

The unmodified reviewer diagnostic at
`/private/tmp/zerkov-5-6-sol-review.NmA7fZ/release_callback_surface_probe.gd`
was run against its intended pre-repair callback candidate. Its SHA-256 was
`0a1070f4d18798fc492fe881cbc71565a09b5f99275e9a3627767761dbcb5e0a`.
It produced `18/0` while printing the two reproduced masked values:
`health_binding_change_reentrant` after the successful
`binding_invalidated` callback and after the
`medical_inventory_release_failed` recovery callback. The probe's final two
assertions deliberately encode those candidate observations, so the corrected
expectations are promoted into the permanent focused contract above rather than
being treated as a post-repair green oracle.

## Sealed-candidate adjacent headless baseline

The sealed candidate established the following unchanged baseline before this
review repair:

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
| Inventory intent adapter | 162/0 |
| Inventory multi-controller | 23/0 |
| Inventory persistence replacement | 97/0 |
| Inventory nested magazine | 258/0 |
| Inventory mutation routing | 146/0 |
| Equipped-item reconciliation | 123/0 |

Sealed adjacent result: `22,700/0` across 25 contracts.

Sealed focused plus adjacent: `23,518/0`.

Sealed focused, adjacent and independent adversarial: `23,912/0`.

## Merge-sensitive adjacent headless gates

After merging current main, the following nonvisual contracts passed:

| Contract | Result |
| --- | ---: |
| Health ability content | 392/0 |
| Combat content | 80/0 |
| Inventory catalog | 551/0 |
| Authority replay/journal | 81/0 |

Post-repair verification executed `2,408` green assertions: focused `888/0`,
independent adversarial `394/0`, native-cancellation probe `22/0`, and adjacent
headless contracts `1,104/0`. The pre-repair reviewer reproduction is retained
above as diagnostic evidence and is not included in that green total.

## Import, validation, hashes and diff

- Exact main `e12dcd043625c22ea8b62cd7fce2587505bb03a8` was merged at
  `ffe56dc2c0852c7734ad9c7890c41343987a6b0f` before the final verification.
- Fresh pinned headless import after that merge exited 0 with no warning, script
  error or engine error.
- Strict validation of `add-zerkov-playable-raid-2026-09-09` returned `Valid`.
- Vendored-add-on integrity tests passed `4/4`; no add-on source changed.
- `git diff --check` passed. The task diff against integrated main contains no
  `RaidAuthority`, UI, viewport, visual or capture file. No UI, visual,
  viewport or renderer-backed test was run.
- A narrow synchronous-public-signal audit covered `damage_committed`,
  `injury_committed`, `treatment_committed`, `death_committed`,
  `recovery_latched`, and `binding_invalidated`. The four outcome signals emit
  immutable receipts while phase/mutation gates remain active and do not publish
  an outer terminal `last_error` reason; their existing reentry fence remains
  unchanged. Only recovery and invalidation publish a reason already assigned
  to `last_error`, so only those two sites restore it after synchronous delivery.
- `frozen_sources.sha256` seals the implementation, focused contracts,
  governing instructions, approved inputs and accepted Task 5.4/5.5 evidence.
  `packet.sha256` seals this report, the structured results and source manifest.
- Task 5.6 remains unchecked pending renewed independent review.

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
