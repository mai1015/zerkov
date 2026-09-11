# Task 5.4 repaired implementation evidence

Status: repaired implementation ready for independent acceptance. Task 5.4
remains unchecked by design.

- Recorded: 2026-09-11
- Branch: codex/weapon-combat-adapter-5-4
- Original base: c265d3a4efd9b49f840b87e201ceb8f4b661d26b
- Accepted integrated main: ebb003ce068d4621a49af9614be136a149580dd8
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
- RaidAuthority issues a random, bounded, non-reusable registration identity
  and keeps one canonical registration record. Phase ordering stores IDs only;
  dispatch attests the original callback identity and the relay's exact signal
  connection identity together with phase, tick, and generation. Replacing a
  signal connection cannot inherit the old registration.
- Before BodyHitboxWorld2D issues a bearer it locks that raid authority to named
  method handlers and refuses any already-retained anonymous closure. Once all
  required named publisher/consumer grants are commissioned, the original
  bearer is erased and synchronously revoked; only the bounded exact phase
  grants remain. Dictionary keys/values, Object properties, Object signals,
  Callable owners, and bound arguments are recursively screened.
- The accepted Task 5.3 v2 bearer is used only transiently at bind to authorize
  narrow BodyHitboxWorld2D phase grants. Neither the adapter, authority,
  handler, callback owner, provenance, nor result graph retains the bearer,
  lease, or a bearer-returning callable. Metadata and raycast grants also
  verify exact raid/session/epoch/generation/actor/source/world provenance.
- RaidAuthority commits the complete canonical registration and ordered phase
  roster at tick start, then rechecks it before every phase. Removing canonical
  registration and ordering entries together after fire therefore cannot
  strand a committed shot behind a successful tick; mutation fails terminally.
  No public obligation/shot-DTO intake exists.
- The native `command_id + ":shot"`, typed event/query IDs, journal slot,
  hitbox-query slot, exact handler grant, and full target-coordinate envelope
  are preflighted before WeaponAuthority.fire can consume ammo or revision.
  Checked multiplication/addition avoids INT64_MIN-unsafe absolute value.
- Journal, adapter queue/ledger, hitbox-query, phase-grant, and lifetime
  registration storage are bounded and collision checked before publication.
- One first-seen operation produces at most one authoritative raycast, one
  immutable hit/miss result, one journal input, and one consequence signal.

The Task 5.4 implementation/repair adds no damage, injury, bleed, death,
healing, noise dispatch, melee, input routing, presentation, add-on source, UI,
truth-spec, or task-ledger change. Accepted-main history is reported separately.

## Rejection regressions

The permanent contract retains the earlier candidate regressions and closes
every finding against rejected repair
499fa37efde7e0c37cb8401a990d517811370307:

1. Recursive property inspection follows nested Objects, Callable owners, and
   Dictionary keys and values. Bearer-owning callback registration is rejected;
   post-registration key/property mutation cannot become reachable through
   adapter/authority/world property graphs because the caller is signal-relayed.
2. Phase ordering and callback facts no longer have split-brain representations.
   Replacing a phase-list entry while canonical registration remains intact
   fails roster coherence before the replacement callback can run.
3. Public `shot_committed` notifications cannot open pending work, and the
   public phase-obligation intake has been removed. Only `commit_fire` can
   consume a round and create one pending consequence.
4. Reflectively removing the active phase-6 handler after native commit fails
   canonical-roster validation and cannot strand a successful tick.
5. A boundary-valid 124-byte command is rejected because the derived `:shot`
   identity would exceed the bound; ammo and revision remain unchanged.
6. A scalable but boundary-adjacent origin is rejected by the complete target
   envelope before native ammo/revision mutation.
7. Anonymous closure handlers cannot coexist with a live Task 5.3 bearer:
   closure-first commissioning refuses bearer issuance, bearer-first
   commissioning refuses closure registration, and the commissioning bearer
   is revoked after narrow grants are installed.
8. Removing both the canonical handler record and its ordered phase entry after
   native fire changes the tick-start roster commitment, terminalizes the tick,
   and leaves zero query/event/result publications.
9. Disconnecting the registered relay bridge and connecting a different
   callback fails the exact connection-identity attestation before either the
   replacement or the original handler can resolve the pending shot.

Earlier forged signal DTO, direct native fire, phase-5 resolver, extreme-origin
checked-arithmetic, replay, collision, and capacity regressions remain covered.

The contract also covers hit, clear miss, obstruction/body boundary tie,
immutable replay, duplicate operation, synchronous callback reentry,
release/rebind, wrong actor/source, stale generation/tick, malformed requests,
identity collisions, and all capacity preflights.

Focused result: WEAPON_COMBAT_ADAPTER_RESULT checks=368 failures=0

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
| Units/clock | 41/0 |
| Identity collision | 18442/0 |
| Combat content | 80/0 |
| Health/ability content | 392/0 |

Adjacent: 20,026 checks, 0 failures.

Focused plus adjacent: 20,394 checks, 0 failures.

The accepted Task 6.1 Vision contract was additionally run twice after the
overlapping RaidAuthority merge and passed 305/0 on both runs. Including those
required compatibility reruns, the final execution total is 21,004/0.

## Import, diagnostics and spec

- Fresh pinned headless editor import exited 0 with no diagnostic line.
- All 15 weapon/adjacent contracts plus two post-merge Vision runs exited 0
  with no failure or runtime diagnostic.
- Git diff checks passed and the task-specific diff has no add-on source.
- Task 5.3 and Task 6.1 remain checked; task 5.4 remains unchecked. Accepted
  task 8.11 and prior accepted tasks remain checked after exact-main integration.
- Strict change validation returned Valid.
- No UI, viewport, compact, responsive, visual, capture, or screen-size test ran.

## Limits and remaining risks

- Limits are 64 pending shots, 4,096 resolved operations,
  4,096 task-5.3 query results, 8,192 journal events, 16 delegated phase grants,
  and 256 lifetime handler registrations. Capacity is fail-stop, not eviction,
  because replay and non-reuse proofs must remain stable.
- Trusted composition presents the Task 5.3 bearer only at initial phase-grant
  authorization. Runtime callbacks publish/query through exact-registration
  grants and never receive or retain the bearer.
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
