# Task 5.4 implementation evidence

Status: implementation complete and ready for independent acceptance. Task
`5.4` remains unchecked in `tasks.md` by design.

Recorded: 2026-09-11

Branch: `codex/weapon-combat-adapter-5-4`

Base: `c265d3a4efd9b49f840b87e201ceb8f4b661d26b`

Engine: Godot `4.7.2.stable.official.ed1daf0bf`, Compatibility renderer,
headless only.

## Implemented boundary

- `WeaponCombatAdapter` binds only during raid preparation and authenticates
  the exact `RaidAuthority`, offline admission, player actor/source,
  `WeaponAuthority`, task-5.2 weapon-context binding generation, task-5.3
  hitbox-world capability, session, authority epoch/generation and world token.
- A non-replayed `shot_committed` signal is admitted only in authoritative
  phase 5. Its exact accepted outcome, native post-commit weapon snapshot,
  current equipped weapon record and stable weapon binding are captured before
  it enters the bounded queue.
- Phase 6 derives one checked canonical ray from the committed fixed origin,
  direction and range, excludes the firing actor, and calls the exact
  `BodyHitboxWorld2D` capability once. Task 5.3 remains the sole owner of body,
  obstruction, rational-distance and tie-break selection.
- One game-owned immutable result maps the world outcome to `hit` or `miss`.
  Obstruction is a miss with `miss_reason=occluded`; the obstruction fact and
  exact hit point/fraction remain available. The same stable consequence ID is
  used for one audit record and one consequence publication.
- Repeated non-replayed delivery, an early replay while queued and a later
  WeaponAuthority replay are idempotent. A resolved replay returns a fresh,
  recursively read-only copy of the original result and performs no query,
  journal append or signal emission.
- Shot-identity divergence, derived event/request-ID collision, malformed or
  stale shot facts, wrong actor/source binding, replaced dependencies and
  synchronous mutation reentry fail closed. Release disconnects the signal and
  unregisters phase 6 before dependencies; a released instance can bind a fresh
  dependency graph with a new generation.
- Journal event capacity/identity is preflighted before the world query.
  Adapter queue/ledger and hitbox-query capacities are also checked before any
  partial consequence publication.

No damage, injury, bleed, death, healing, melee, input routing, presentation,
VFX, audio, add-on source, UI or task-ledger status was changed.

## Permanent focused evidence

`tests/combat/weapon_combat_adapter_contract.gd` passed:

`WEAPON_COMBAT_ADAPTER_RESULT checks=197 failures=0`

The contract uses the real pinned native `WeaponAuthority` and authoritative
`BodyHitboxWorld2D`. It covers hit, clear miss, exact boundary-tie obstruction,
stable digests, detached recursive immutability, queued duplicate delivery,
early and late replay, one-query/one-event/one-emission accounting, release
reentry, teardown/rebind, wrong actor/source, stale generation/tick, malformed
payload, shot-identity divergence, forced event-ID collision and every named
capacity preflight. A separately preclaimed journal event ID also proves the
audit collision is rejected before the spatial query.

## Adjacent contracts

| Contract | Result |
| --- | --- |
| Weapon instance context | `308/0` |
| Weapon context adversarial | `49/0` |
| Weapon persistence/replacement integration | `43/0` |
| Inventory/weapon reload | `176/0` |
| Body hitbox | `111/0` |
| Body hitbox adversarial | `173/0` |
| Body hitbox review regression | `72/0` |
| Authority replay/journal | `81/0` |
| Session lifecycle | `44/0` |
| Units/clock | `32/0` |
| Identity collision | `18442/0` |
| Combat content | `80/0` |
| Health/ability content | `392/0` |

Focused plus adjacent execution total: **20,200 checks, 0 failures**.

The task-5.2 contract now explicitly proves its non-enumerating combat-binding
authentication accepts the exact raid/weapon/actor/source/generation and
rejects wrong actor, source and generation.

## Import, diagnostics and spec

- Fresh headless editor import exited `0`; script registration and editor load
  completed with no `SCRIPT ERROR`, `Parse Error`, `ERROR:` or `WARNING:` line.
- All 14 accepted contract executions exited `0`; their outputs contained no
  runtime/parser/assertion/leak diagnostic.
- `git diff --check` passed.
- `git diff --name-only -- addons` was empty.
- Strict change validation returned `Valid` using the bundled spec toolkit.
- No UI, viewport, compact, responsive, visual, capture or screen-size command
  ran.

## Explicit limits and remaining risks

- One binding retains at most 64 pending shots and 4,096 resolved results.
  Capacity is fail-stop rather than eviction because replay must return the
  original result. The body-world query ledger independently retains 4,096
  results; the raid journal retains its configured bounded maximum.
- The boundary is offline, synchronous, in-memory and single-writer/no-yield.
  Durable/network replay and replica egress remain gated multiplayer work.
- `WeaponAuthority` exposes only its legacy compact GDScript consequence
  string. The adapter deterministically hashes that complete string into typed
  product event/request IDs and collision-checks both mappings; the add-on's
  native structured `ConsequenceIdentity` is not falsely claimed.
- A mechanically committed shot that encounters capacity or dependency failure
  cannot be uncommitted. The adapter publishes no partial hit/miss consequence,
  fails the raid tick and preserves the native committed weapon truth for
  diagnosis.
- Damage, noise dispatch, injuries and death are intentionally absent. Task 5.6
  must consume the stable hit result idempotently; noise ownership remains for
  its later approved implementation boundary.

`frozen_sources.sha256` seals the changed production/contracts plus the exact
approved proposal/design/routing/task/capability inputs. `packet.sha256` seals
this report, the source seal and the machine-readable result summary.
