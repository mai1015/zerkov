# Troubleshooting

Actionable diagnostics grounded in this addon's actual `StatusCode`/
`DiagnosticId`/`Rejection` values (`native/core/wpn_status.h`), not generic
advice. Every command result Dictionary returned by `WeaponAuthority`
(`fire()`, `begin_reload()`, `cancel_reload()`, `configure_attachments()`,
`teardown()`) carries a `status: {code, diagnostic, detail}` Dictionary; a
rejected outcome additionally carries `rejection` (the coarser
`wpn::Rejection` enum used by `CommandOutcome`, distinct from the finer
`DiagnosticId`).

## "WeaponAuthority native class is not registered"

The GDExtension did not load for the current platform/build-type. Check:

- `addons/weapon_system/weapon_system.gdextension` declares an entry for your
  exact `(platform, build-type[, arch])`.
- The declared artifact actually exists under `addons/weapon_system/bin/` —
  see [`distribution.md`](distribution.md#building-the-extension).
- `addons/weapon_system/release_manifest.json`'s matching target entry: only
  `macos/universal` (`debug` and `release`) is `"status": "built"` today;
  `windows/x86_64` and `linux/x86_64` are `"status": "planned"` — there is no
  artifact to load for those targets yet.

Per the weapon-platform-support spec's "Native Deterministic Implementation"
requirement, a missing/incompatible native library MUST fail explicitly —
Godot refuses to start rather than silently falling back to a GDScript
implementation (there is none).

## Catalog `register_*()` fails, or `content_fingerprint()` looks wrong

- Every `register_shot_profile()` / `register_recoil_profile()` /
  `register_attachment()` / `register_ballistic_profile()` /
  `register_weapon()` call on `WeaponDefinitionCatalog` is only valid before
  `seal()`. Registration validates and copies each `Resource`'s current field
  values into the sealed native catalog — see
  [`authoring.md`](authoring.md).
- `StatusCode.INVALID_IDENTIFIER` (`DiagnosticId.IDENTIFIER_INVALID` /
  `IDENTIFIER_TOO_LONG`, code 20 / diagnostic 1 or 2): an empty or
  over-`MAX_IDENTIFIER_BYTES` (128) definition ID.
- `StatusCode.DUPLICATE_DEFINITION` (`DiagnosticId.DEFINITION_DUPLICATE`,
  code 21 / diagnostic 20): the same `(id, version)` pair registered twice.
- `StatusCode.UNKNOWN_DEFINITION` (`DiagnosticId.DEFINITION_UNKNOWN_REFERENCE`,
  code 22 / diagnostic 21): a `WeaponDefinition` names a `shot_profile_id`/
  `recoil_profile_id` that was never registered — register referenced
  profiles first, or check for a version mismatch (the catalog resolves the
  exact `(id, version)` pair, never "latest").
- `StatusCode.CATALOG_SEALED` / `CATALOG_NOT_SEALED` (`DiagnosticId`
  `CATALOG_ALREADY_SEALED=22` / `CATALOG_REQUIRES_SEAL=23`): you called a
  `register_*()` method after `seal()`, or a construction/validation method
  before it. This is deliberate — a sealed catalog is immutable, and mutating
  the *original* authoring `Resource` after seal is a documented no-op
  against the sealed catalog (weapon-authoring spec, "Resource changes after
  configuration").
- A definition that names automatic/burst fire, a projectile, a detachable
  magazine, a chamber, nested/attachment-provided slots, or a penetration
  modifier on a weapon/attachment fails validation with the unsupported
  field/value identified — V1 never silently downgrades it to semi-auto
  hitscan (weapon-authoring spec, "Deferred mechanism is authored" /
  "Weapon attempts to define penetration").
- `accuracy_moa_milli` negative or above the sealed V1 limit
  (`MAX_ACCURACY_MOA_MILLI` = 60,000, i.e. 60 MOA) rejects before runtime
  readiness — see [`authoring.md`](authoring.md#accuracy-integer-milli-moa).

## A `fire()` / `begin_reload()` / `configure_attachments()` call returns `accepted: false`

Read `status.code` first, then `status.diagnostic` for the exact reason.
Every rejection changes no mechanical instance state and emits no canonical
transition event (weapon-runtime spec, "Shared Authoritative Command Gate").

| `status.code` | `status.diagnostic` | Meaning |
|---|---|---|
| `COMMAND_REJECTED` (62) | `REVISION_STALE` (62) | The command's `expected_revision` differs from the instance's current revision. `detail`/the outcome's own `revision` field names the current one. |
| `DUPLICATE_CONFLICT` (61) | `COMMAND_DUPLICATE_CONFLICT` (63) | The same `command_id` was reused with different canonical payload bytes. |
| `COMMAND_REJECTED` (62) | `ACTOR_NOT_LIVE` (64) | The `AuthorityContext` Dictionary's `actor_live` was false (or the context was never supplied — see below). |
| `COMMAND_REJECTED` (62) | `WEAPON_NOT_USABLE` (65) | `weapon_usable` was false in the authority context. |
| `COMMAND_REJECTED` (62) | `WEAPON_NOT_EQUIPPED` (77) | `weapon_equipped` was false — leaving usable equipment scope disables firing without discarding mechanical state (weapon-inventory-integration spec, "Item-Backed Weapon Lifecycle"). |
| `COMMAND_REJECTED` (62) | `WEAPON_RELOADING` (66) | `fire()`/`configure_attachments()` was called while a reload is active. |
| `COMMAND_REJECTED` (62) | `WEAPON_NOT_RELOADING` (67) | `cancel_reload()` was called on a weapon that is not reloading. |
| `COMMAND_REJECTED` (62) | `CADENCE_NOT_ELAPSED` (68) | Fewer than `cadence_ticks` authority ticks have elapsed since the last accepted fire. |
| `COMMAND_REJECTED` (62) | `OUT_OF_AMMO` (69) | `loaded_rounds == 0`. |
| `COMMAND_REJECTED` (62) | `ORIGIN_MISMATCH` (70) / `AIM_MISMATCH` (71) | The claimed origin/aim exceeded the weapon's sealed origin/aim tolerance against the authority-supplied pose — the committed shot always uses the authoritative pose, never the claim. |
| `COMMAND_REJECTED` (62) | `VALUE_OUT_OF_RANGE` (7) | A command failed structural validation. For `begin_reload()`, this includes an empty/invalid reservation ID or profile ID/version. |
| `COMMAND_REJECTED` (62) | `RELOAD_NOT_NEEDED` (73) | `begin_reload()` on an already-full weapon. |
| `COMMAND_REJECTED` (62) | `RELOAD_QUANTITY_INVALID` (74) | Reserved rounds are zero or would exceed capacity. |
| `COMMAND_REJECTED` (62) | `ATTACHMENT_SLOT_UNKNOWN` / `_DUPLICATE` / `ATTACHMENT_UNKNOWN_REFERENCE` / `_SLOT_INCOMPATIBLE` (116–119) | `configure_attachments()`'s desired loadout named an unknown slot, a duplicate slot, an unknown attachment `(id, version)`, or an incompatible slot-kind pairing — the *entire* command is rejected, the previous loadout is unchanged. |
| `COMMAND_REJECTED` (62) | `ATTACHMENT_CONFIG_DURING_RELOAD` (120) | `configure_attachments()` was called while reloading. |
| `COMMAND_REJECTED` (62) | `PROFILE_UNKNOWN_REFERENCE` / `PROFILE_TRAIT_MISMATCH` / `PROFILE_TOPUP_MISMATCH` (121–123) | The reservation named an unregistered profile, its trait disagrees with the weapon, or it tries to top up a non-empty weapon with a different exact profile. |
| `COMMAND_REJECTED` (62) | `AUTHORITY_TICK_REGRESSION` (112) | The trusted authority tick is below the instance's accepted floor. This rejects before sequence admission and changes no history or state. (`TICK_REVERSED` (75) belongs to separate tick/reload-participant APIs.) |
| `COMMAND_REJECTED` (62) | `DUPLICATE_OUTCOME_EVICTED` (113) | A sequence at/below the epoch high-watermark has no cached outcome and can never execute. (`SEQUENCE_STALE` (76) is the outer network gate's stale-sequence diagnostic.) |
| `ARITHMETIC_ERROR` (7) | `TICK_ARITHMETIC_OVERFLOW` (115) | The current operation's checked due-tick calculation overflowed and latched the instance unhealthy. |
| `UNHEALTHY` (90) | `RUNTIME_UNHEALTHY` (114) | A later command reached an instance already latched unhealthy. Recover with a trusted replacement snapshot/new authority epoch. |

**`ACTOR_NOT_LIVE` on every fire call, even with a valid pose** — the most
common integration mistake: `fire(command, authority)`'s `authority`
Dictionary is caller-supplied on every call; there is no persisted/implicit
world state behind it. If you route fire through `WeaponNetworkBridge`, its
`authority_context_provider` Callable property builds this Dictionary
server-side — leaving it unset produces an all-false/neutral context by
design (fail-closed default), which deterministically rejects every fire as
`ACTOR_NOT_LIVE`. See [`integration.md`](integration.md#authority-modifiers-and-the-authoritycontext-dictionary).

**A duplicate command silently "succeeds" twice** — it should not. Re-check
that you are not minting a fresh `command_id` for what is actually a retry;
`fire()`/etc. return the *recorded* outcome (`replayed: true` on the result)
for an exact duplicate `(command_id, payload)`, and reject
`DUPLICATE_CONFLICT` for the same `command_id` with different payload bytes.

## World resolution (hit/miss/damage/noise) never happens

`WeaponAuthority`'s bound `fire()`/`fire_native()` surface stops at the
**mechanical** commit — consuming a round, deriving shot direction, and
emitting `shot_committed` with a Dictionary containing direction, damage,
range, noise radius, consumed ballistic-profile identity, and a legacy
`consequence_id`. The core `CommittedShot` has a structured consequence
identity and exact shot-profile identity, but the current GDScript Dictionary
does not expose either field.
The 2D world coordinator that resolves that committed shot against targets,
obstruction, a damage sink, and a noise sink — `wpn::WorldCoordinator`
(`native/core/wpn_world_coordinator.h`) plus the port interfaces in
`native/core/wpn_world_ports.h` (`ActorPoseProvider`, `EligibleTargetQuery`,
`ObstructionQuery`, `DamageSink`, `PositionalNoiseSink`) — is implemented and
covered by `native/tests/wpn_test_world.cpp`, but **is not yet bound to
GDScript through `ClassDB`** (`register_types.cpp` registers
`WeaponDefinitionCatalog`, `WeaponSystemVersion`, `WeaponAuthority`, and
`WeaponNetworkBridge` only — no `WeaponWorldCoordinator` Node exists). A
pure-GDScript game must resolve obstruction/target/damage/noise itself after
receiving `shot_committed` — or a C++ addon consumer can wire
`wpn::WorldCoordinator` directly against `fire_native()`'s `CommittedShot`
output. See [`integration.md`](integration.md#world-ports-and-consequence-identity)
for the full port contract and this gap's exact citation.

## `WeaponNetworkBridge` rejects every command with `CONTENT_NOT_READY`

The server-side ownership table only marks a peer compatibility-ready after
the bridge's `send_compatibility_handshake()` round-trip; before that,
commands are rejected `SESSION_NOT_READY`/`CONTENT_NOT_READY`. Confirm the
client bridge is processing (it sends once automatically) and that the game
called `begin_session()` for that peer.

Important: the current bridge RPC does **not** decode or compare the manifest;
it marks an existing session ready unconditionally. Comparing protocol,
schema, features, world versions, and `content_fingerprint()` is presently a
game-owned admission step. Do it before `authorize_instance()` and do not
treat absence of `CONTENT_NOT_READY` as proof of content compatibility. See
[`how-it-works.md`](how-it-works.md#current-godot-bridge-boundaries).

## `WeaponNetworkBridge` rejects a command with `ACTOR_BINDING_DENIED` / `ROLE_INSUFFICIENT`

`validate_binding()` is the single admission point for "client commands
another actor's weapon" (weapon-protocol spec). Call
`authorize_instance(peer, instance_id, role)` server-side (role `0` =
observer, `1` = owner) before a client can submit fire/reload/attachment
commands for that instance — an unauthorized or under-role peer is rejected
before any weapon or world mutation, bounded by `MAX_BOUND_INSTANCES_PER_PEER`
(256) authorized instances per peer.

## `WeaponReplica.apply_delta()` requests a resync / `RESYNC_NEEDED`

An already-applied successor revision is a harmless duplicate. A predecessor
ahead of the replica is a gap; a predecessor behind it paired with a newer
successor is an impossible transition. The latter two cases request resync
rather than guessing intermediate state. Fetch a fresh
`WeaponSnapshotEnvelope`/`WeaponSnapshotBatch` and apply it — `WeaponReplica`
never guesses intermediate ammunition/reload/recoil/attachment state across a
gap (weapon-protocol spec, "Delta is lost").

## Where to look next

- Every definition kind, the MOA formula, attachment slots, and modifier
  algebra: [`authoring.md`](authoring.md).
- Roles, command envelope, authority modifiers, world ports, consequence
  identity, protocol/networking: [`integration.md`](integration.md).
- Presentation signals: [`presentation.md`](presentation.md).
- Every test suite and how to run it: [`verification.md`](verification.md).
- Installation and platform support: [`distribution.md`](distribution.md).
