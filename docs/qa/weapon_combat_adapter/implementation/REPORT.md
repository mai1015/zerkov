# Task 5.4 repaired implementation evidence

Status: repaired implementation ready for independent acceptance. Task 5.4
remains unchecked by design.

- Recorded: 2026-09-11
- Branch: codex/weapon-combat-adapter-5-4
- Original base: c265d3a4efd9b49f840b87e201ceb8f4b661d26b
- Accepted integrated main: 6fc090ebe63b0bb86979e004f3295897d0302950
- Accepted Task 5.3 merge: 49c0ae0f3d512df441858e61c0881cdbe22c40a4
- Engine: Godot 4.7.2.stable.official.ed1daf0bf, headless only

## Repaired authority boundary

- WeaponCombatAdapter.commit_fire is the sole committed-shot intake. It derives
  the current task-5.2 weapon binding and authoritative pose, constructs the
  command, invokes WeaponAuthority.fire directly, and consumes only that
  operation's immediate return.
- The adapter never connects to or consumes the publicly emittable
  shot_committed signal. Direct native fire outside the adapter, replay-shaped
  forged notifications, and malformed notification dictionaries cannot enter
  its queue or consequence ledger.
- Exact command requests share the bounded shot ledger. Exact replay returns a
  detached recursively read-only original before another native call, query,
  event, or publication. Divergent facts under one command ID fail closed.
- RaidAuthority records the exact phase handler currently being dispatched.
  Resolution checks the handler ID, phase, tick, authority generation, adapter
  generation, and reentry state before spatial or journal work. A phase-5
  direct resolver call is rejected even with otherwise correct arguments.
- The accepted Task 5.3 v2 bearer is only a transient bind or resolution
  argument. No raw bearer, lease secret, or wrapping callable is assigned to an
  adapter property. Every phase-6 use reauthenticates exact raid, session,
  epoch, generation, actor, source, and world provenance. Only the non-secret
  binding token is retained.
- Origin scaling, direction/range multiplication, and target addition validate
  operands before arithmetic and avoid INT64_MIN-unsafe absolute value. Extreme
  authoritative origins fail before native fire or multiplication.
- Journal, adapter queue/ledger, and hitbox-query capacities are checked before
  irreversible work. Stable event/query IDs use two-pass collision checking
  before either reservation is published.
- One first-seen operation produces at most one authoritative raycast, one
  immutable hit/miss result, one journal input, and one consequence signal.

The Task 5.4 implementation/repair adds no damage, injury, bleed, death,
healing, noise dispatch, melee, input routing, presentation, add-on source, UI,
truth-spec, or task-ledger change. Accepted-main history is reported separately.

## Rejection regressions

The permanent contract closes every finding against earlier candidate
6296e6668813f70d5c358cbd6ed84bd27a816bc4:

1. A forged phase-5 shot_committed DTO adds no extra pending shot, query, event,
   result, or publication.
2. Direct native fire outside commit_fire remains native truth but is not
   consumed as a game-owned consequence.
3. A phase-5 direct resolver call fails before the one registered phase-6
   dispatch resolves exactly once.
4. Recursive property inspection, callable arguments, and nested collections
   expose no retained hitbox bearer in the adapter.
5. Origin 9,000,000,000,000,000,000 fails before multiply, native mutation,
   query, journal append, or publication.

The contract also covers hit, clear miss, obstruction/body boundary tie,
immutable replay, duplicate operation, synchronous callback reentry,
release/rebind, wrong actor/source, stale generation/tick, malformed requests,
identity collisions, and all capacity preflights.

Focused result: WEAPON_COMBAT_ADAPTER_RESULT checks=244 failures=0

## Adjacent headless contracts

| Contract | Result |
| --- | --- |
| Weapon instance context | 308/0 |
| Weapon context adversarial | 49/0 |
| Weapon persistence integration | 43/0 |
| Inventory/weapon reload | 176/0 |
| Body hitbox | 111/0 |
| Body hitbox adversarial | 173/0 |
| Body hitbox review regression | 72/0 |
| Body hitbox capability encapsulation | 14/0 |
| Authority replay/journal | 81/0 |
| Session lifecycle | 44/0 |
| Units/clock | 32/0 |
| Identity collision | 18442/0 |
| Combat content | 80/0 |
| Health/ability content | 392/0 |

Adjacent: 20,017 checks, 0 failures.

Focused plus adjacent: 20,261 checks, 0 failures.

## Import, diagnostics and spec

- Fresh pinned headless editor import exited 0 with no diagnostic line.
- All 15 permitted contracts exited 0 with no failure or runtime diagnostic.
- Git diff checks passed and the task-specific diff has no add-on source.
- Task 5.3 remains checked; task 5.4 remains unchecked. Accepted tasks 7.9 and
  8.3 remain checked after the exact-main integration.
- Strict change validation returned Valid.
- No UI, viewport, compact, responsive, visual, capture, or screen-size test ran.

## Limits and remaining risks

- Limits are 64 pending shots, 4,096 resolved operations, 4,096 task-5.3 query
  results, and at most 8,192 configured journal events. Capacity is fail-stop,
  not eviction, because replay must retain the original result.
- Trusted production composition must keep the Task 5.3 bearer outside
  discoverable Object state and pass it transiently from the registered phase-6
  callback. This implementation supplies and verifies that consumer contract.
- The boundary is offline, synchronous, in-memory and single-writer/no-yield.
  Durable/network replay and replica egress remain later work.
- Typed event/query IDs are deterministic hashes of the complete legacy native
  consequence string and both mappings are collision checked.
- A mechanically committed shot cannot be rolled back after an unexpected
  later dependency failure. No partial hit/miss consequence is published; the
  tick fails and native committed truth remains available for diagnosis.
- Damage, injuries, death, healing, and noise consumption remain absent.

frozen_sources.sha256 seals changed production/contracts and exact approved
inputs. packet.sha256 seals this report, results, and the source manifest.
