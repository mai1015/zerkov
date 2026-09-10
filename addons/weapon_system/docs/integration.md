# Integration

Roles, the command envelope, authority modifiers, world ports, consequence
identity, the wire protocol, and `WeaponNetworkBridge` setup. This is the
"how a game wires Weapon System to its own actors, world, and transport"
document; for authoring definitions see [`authoring.md`](authoring.md), for
signals see [`presentation.md`](presentation.md).

## Roles

`WeaponAuthority.Role` (native/godot/weapon_authority.h):

| Role | Value | Meaning |
|---|---:|---|
| `ROLE_OFFLINE_AUTHORITY` | 0 | Default. Single-process authority — a local game or a test driving the runtime directly. |
| `ROLE_SERVER_AUTHORITY` | 1 | Authority behind a network bridge. |

`role` is presently a **labeling-only** property on `WeaponAuthority` itself:
both roles are full canonical authority over their owned runtime with no
behavioral difference at that class. The functional client/server split
lives one level up, in `WeaponNetworkBridge.Role`:

| Role | Value | Meaning |
|---|---:|---|
| `ROLE_SERVER` | 0 | Gates every inbound command through the admission gate, then routes it into a game-configured `WeaponAuthority`. Creates the trusted core authority envelope (tick/scope/epoch) server-side. |
| `ROLE_CLIENT` | 1 | Owns a `WeaponReplica` (confirmed state only) and a `PresentationPredictionTracker` (bounded, reversible, presentation-only prediction). Structurally cannot mutate canonical state — this role never touches a `WeaponAuthority`/`WeaponRuntime` at all. |

There is deliberately no `ROLE_OFFLINE_AUTHORITY` on the bridge: an offline
game simply never attaches `WeaponNetworkBridge` and drives `WeaponAuthority`
directly — the bridge is optional plumbing on top of the same command/state
contracts every caller (offline, AI, replay, tests, network) shares.

## Command envelope semantics

Every mutating `WeaponRuntime` command (`fire`, `begin_reload`,
`cancel_reload`, `configure_attachments`, `teardown`) carries the same
authority-created envelope identity fields
(`native/core/wpn_runtime.h`):

| Field | Type | Meaning |
|---|---|---|
| `command_id` | string | Idempotency identity, ≤`MAX_IDENTIFIER_BYTES`; keep it globally unique within one authority/runtime, not merely per instance. |
| `sequence` | uint64 | Monotonic per-`(scope, instance, epoch)` sequence claim. |
| `instance_id` | string | Target weapon instance. |
| `expected_revision` | uint64 | Optimistic-concurrency check against the instance's current revision. |
| `tick` | uint64 | **Trusted** authority tick — supplied by the caller's authority context, never an untrusted wire payload (see "Protocol" below: the wire `*Intent` DTOs deliberately have no tick field at all). |
| `authority_scope` | string | Stable world/session namespace the instance is bound to. |
| `authority_epoch` | uint64 | Current trusted authority epoch; only a trusted replacement snapshot may change it. |

### Admission order

`WeaponRuntime::admit()` (the "Shared Authoritative Command Gate") runs, in
order: idempotency replay/conflict check, instance existence, authority-scope
match, structural validity, authority-epoch match, latched unhealthiness,
authority-tick non-regression, then sequence admission against the epoch
high-watermark. **Sequence admission advances the high-watermark for both
accepted transitions and deterministic gameplay rejections** — a malformed
envelope rejected *before* admission never advances it, so it can be
re-submitted; anything admitted, accepted or rejected, cannot execute again
under the same sequence.

### Idempotency and duplicate outcomes

| Situation | Outcome |
|---|---|
| Same `command_id` + identical payload replayed within bounded history | Returns the recorded outcome without re-applying effects (`replayed: true`). |
| Same `command_id` reused with a **different** payload | Rejected as a conflict; state unchanged. |
| Sequence at/below the epoch high-watermark whose cached outcome has been **evicted** | Rejected as `duplicate_outcome_evicted` (`DiagnosticId::DUPLICATE_OUTCOME_EVICTED` = 113) — this command can never execute again, evicted or not. |
| Trusted tick below the instance's accepted floor | Rejected **before** sequence admission as `authority_tick_regression` (`DiagnosticId::AUTHORITY_TICK_REGRESSION` = 112); no mechanical, sequence, or history state changes. |

A rejected command changes no mechanical instance state (loaded rounds,
cadence, phase, revision, recoil, attachments) and emits no canonical
transition event — only the admission bookkeeping (sequence watermark, tick
floor, replay cache) advances. `WeaponSnapshot::mechanical_fingerprint()`
(distinct from `WeaponSnapshot::fingerprint()`, which includes the
bookkeeping fields) is the exact value to assert against for "a rejected
command mutated nothing mechanically."

Checked tick-arithmetic overflow (e.g. an overflowing reload due-tick
calculation) latches the instance `tick_unhealthy = true`
(`DiagnosticId::RUNTIME_UNHEALTHY` = 114 /
`DiagnosticId::TICK_ARITHMETIC_OVERFLOW` = 115); every later command against
it is rejected until a trusted `replace_from_snapshots()` call starts a new
epoch with `tick_unhealthy = false`.

## Authority modifiers and the AuthorityContext Dictionary

`WeaponAuthority.fire(command, authority)`'s `authority` Dictionary
(`wpn::AuthorityContext`) carries:

| Key | Default | Meaning |
|---|---:|---|
| `actor_live` | `false` | Fails closed: an all-default context deterministically rejects fire as `ACTOR_NOT_LIVE`. |
| `weapon_equipped` | `false` | |
| `weapon_usable` | `false` | |
| `authoritative_origin` | `{x:0, y:0}` | Server-owned firing origin — the committed shot always originates here, never from `claimed_origin`. |
| `authoritative_aim` | `{x:0, y:0}` | |
| `spread_modifier_ppm` | 1,000,000 | |
| `damage_modifier_ppm` | 1,000,000 | |
| `range_modifier_ppm` | 1,000,000 | |
| `noise_modifier_ppm` | 1,000,000 | |
| `recoil_modifier_ppm` | 1,000,000 | Folded into the new-kick calculation alongside attachment recoil deltas — see below. |

All five `*_modifier_ppm` values are neutral-1,000,000 multipliers computed
from trusted authority state — never accepted directly from a client. Damage
and range are scaled directly and accept the structural 0–4,000,000 range.
Spread, noise, and recoil are converted to signed deltas and folded with
attachment deltas; the current ±500,000 per-delta rule therefore limits those
three authority inputs to 500,000–1,500,000. Outside that narrower range the
fire is rejected with `VALUE_OUT_OF_RANGE` after envelope admission. See
[`authoring.md`](authoring.md#canonical-parts-per-million-modifier-algebra).

**`recoil_modifier_ppm` is live and does affect committed kick.** Verified
directly against the runtime, not merely the header comment: the Dictionary
façade reads it (`WeaponAuthority::authority_from_dict()`,
`native/godot/weapon_authority.cpp`) into
`wpn::AuthorityContext::recoil_modifier_ppm`, and `WeaponRuntime::fire()`
(`native/core/wpn_runtime.cpp`) appends it as an `"authority"`-sourced delta
to the instance's attachment recoil deltas before folding and applying the
aggregate multiplier to both `RecoilProfile::vertical_kick_nrad` and the
horizontal kick range — the same `fold_modifier_deltas_ppm()` +
`apply_modifier_multiplier()` pipeline every other modifier uses (see
[`authoring.md`](authoring.md)'s modifier algebra). It affects only the
**new** kick a fire produces, never the fixed recovery slope, exactly like
an attachment's own `recoil_modifier_ppm`.

This end-to-end statement applies to direct `WeaponAuthority.fire()` calls.
The current `WeaponNetworkBridge` server projection forwards spread, damage,
range, and noise modifiers from its callback but omits
`recoil_modifier_ppm`; add it in a hardened wrapper if network fire must use
that channel.

This was previously documented here (and in both adapter READMEs) as a
"known façade gap" with no live effect — that claim was true of an earlier
revision of `native/core/wpn_runtime.h`/`.cpp` and
`native/godot/weapon_authority.cpp`, but is **stale** as of the current
worktree: those three files now read and apply the field end-to-end. The
GAS adapter's own code comments
(`addons/weapon_system_gameplay_abilities/weapon_gas_adapter.gd`'s
`authority_modifiers()`, `weapon_gas_mapping_entry.gd`'s
`recoil_control_attribute_identifier` doc comment) still assert "NO live
effect today" — those comments were not updated when the core gap closed and
should be corrected in a future code change; this documentation reflects the
verified current runtime behavior instead of the stale comment.

## World ports and consequence identity

**Current implementation status: `wpn::WorldCoordinator` and the five world
ports (`ActorPoseProvider`, `EligibleTargetQuery`, `ObstructionQuery`,
`DamageSink`, `PositionalNoiseSink`) are engine-free C++ types
(`native/core/wpn_world_ports.h`, `native/core/wpn_world_coordinator.h`) with
no Godot façade.** There is no `GDREGISTER_CLASS` for a `WorldCoordinator`
Node in `register_types.cpp`, and no `shot_resolved` signal exists anywhere
in the addon (`WeaponAuthority` only emits `shot_committed` — the mechanical
fire outcome, before world resolution). A game wiring world resolution today
either consumes that signal and performs its own authoritative Godot query,
or drives `wpn::WorldCoordinator` from C++ — see
`native/tests/wpn_test_world.cpp` for a reference usage. Treat any expectation
of a GDScript-bound world-coordinator Node as aspirational until a
`native/godot/` façade for it exists.

The ports themselves (usable from C++ today):

| Port | Contract |
|---|---|
| `ActorPoseProvider::query_actor_pose` | Returns `false` when the actor's authoritative pose cannot be resolved this tick — caller MUST NOT fall back to a claimed pose. |
| `EligibleTargetQuery::query_eligible_targets` | Fills ≤`MAX_TARGET_CANDIDATES` (512) eligible, positive-radius, stable-ID targets. `false` = adapter fault, not "no targets." |
| `ObstructionQuery::query_nearest_obstruction` | Nearest obstruction along the whole bounded ray, `[0, range]`. |
| `DamageSink::dispatch_damage` | Exactly one canonical sink per configured runtime — `WorldPortConfig.canonical_damage_sinks` with zero or >1 entries fails `configure()` before readiness. Returns `ACCEPTED`/`REJECTED`/`AMBIGUOUS` (`wpn::SinkDispatchResult`); an `AMBIGUOUS` response is never auto-retried within the same `resolve()` call. |
| `PositionalNoiseSink::publish_noise` | Called once for every structurally valid committed shot passed to a configured coordinator, including misses, obstructions, and world-query faults. Unconfigured/malformed inputs return before noise. |

Resolution order (`WorldCoordinator::resolve`): range-limit the ray → query
eligible targets (canonical stable-ID order) → independently query the
nearest whole-ray obstruction → pick the smallest canonical distance
(**obstruction wins an equal-distance tie**; **the lower stable target ID
wins an equal target-entry-distance tie**) → dispatch at most one damage
request on a hit → always publish noise. All coordinates/radii/distances are
checked-integer world-milliunit values under `WORLD_QUANTIZATION_VERSION` = 1
/ `WORLD_TIE_RULE_VERSION` = 1 (both fold into the compatibility manifest).

A world-query failure or quantization fault latches
`WorldCoordinator::healthy() == false`; a fresh `configure()` is the explicit
recovery point. An unresolved consequence (fault before resolution, or a HIT
whose sink response came back `AMBIGUOUS`) is retained, bounded
(`MAX_UNRESOLVED_CONSEQUENCES` = 1024), keyed by full `ConsequenceIdentity`
equality — `resume_unresolved_consequence()` is the only way to retry it,
and it never invents a replacement identity or refunds the consumed round.

### Consequence identity

`wpn::ConsequenceIdentity` (`native/core/wpn_runtime.h`) is the versioned
canonical value naming one committed shot's world consequence:

```
version: uint16 = 1              (CONSEQUENCE_IDENTITY_VERSION)
domain: uint32 = 1               (CONSEQUENCE_DOMAIN_WEAPON_SHOT)
authority_scope: string
authority_epoch: uint64
instance_id: string
successor_revision: uint64       (the fire's own accepted successor revision)
command_id: string
```

**Full-value equality (`operator==`) is the only canonical identity
comparison.** `compact_hash()` may index this value (e.g. as a map key) but
MUST NOT replace `operator==` for identity decisions — this rule is enforced
structurally: `CommittedShot::consequence_identity`,
`DamageRequest::consequence_identity`, `NoiseRequest::consequence_identity`,
and `ShotResolution::consequence_identity` all carry the full value, not just
the hash. (`CommittedShot::consequence_id` is a separate, legacy, non-
canonical compact string — `command_id + ":shot"` — kept only for source
compatibility with existing Dictionary/DTO code; it is not the canonical
identity.)

## Protocol v2 and compatibility fingerprints

`PROTOCOL_VERSION = 2` (`native/core/wpn_limits.h`) — bumped from 1 for the
authority-envelope/recoil-anchor/attachment-loadout/ballistic-profile/
tombstone wire additions. The packaged `release_manifest.json` also declares
protocol 2. Runtime compatibility decisions use the compiled constant and the
decoded compatibility value, never documentation prose.

`wpn::CompatibilityManifest` (`native/core/wpn_version.h`) is the sealed
compatibility unit two peers compare:

```
api_major / api_minor / api_patch : uint16  (0 / 1 / 0)
protocol                          : uint16  (2)
resource_schema                   : uint16  (1)
features                          : uint64  (ProtocolFeature bitmask)
catalog_fingerprint                : uint64  (WeaponCatalog::fingerprint())
world_quantization_version         : uint16  (1)
world_tie_rule_version             : uint16  (1)
```

`ProtocolFeature` bits (`native/core/wpn_version.h`): `CATALOG_MANIFEST` (0),
`SEMI_AUTO` (1), `HITSCAN_2D` (2), `SIMPLE_RELOAD` (3), `SNAPSHOTS` (4).
`wpn::check_compatibility()`/`protocol::check_handshake_compatibility()` fail
closed on major/minor API, protocol, schema, catalog fingerprint, and world-
version mismatches. API patch differences are tolerated, and a local feature
superset accepts a remote subset. These are core helpers, not proof that the
current Godot bridge invokes them: its
compatibility RPC currently marks an existing session ready without decoding
or comparing the payload. Perform the strict comparison in game-owned
session admission until that wrapper is hardened.

Everything that folds into `WeaponCatalog::fingerprint()` — every authored
definition, the numeric constants (`PI_NANORADIANS`,
`MOA_MILLI_TO_NANORADIAN_DENOMINATOR`), sampler versions
(`MOA_CONVERSION_VERSION`, `AIM_ROTATION_ALGORITHM_VERSION`,
`DISPERSION_SEED_SAMPLER_VERSION`, `MODIFIER_ALGEBRA_VERSION`), limits, and
supported-feature flags — is exactly what two peers must agree on before
compatibility is ready; presentation-only fields never participate.

## `WeaponNetworkBridge` setup

`WeaponNetworkBridge` (`native/godot/weapon_network_bridge.h`) is an
**optional** Node that attaches beneath a game-selected `MultiplayerAPI`
branch. It never creates, replaces, or owns the game's `MultiplayerPeer` —
it only reads `Node::get_multiplayer()`, matching the sibling
`gameplay_abilities` addon's `GameplayAbilityNetworkBridge` structural
precedent.

### Game-owned peer

Wire it up (SERVER role) with:

- `set_role(WeaponNetworkBridge.ROLE_SERVER)`
- `set_weapon_authority_path(path)` — an already-configured
  `WeaponAuthority` (role `SERVER_AUTHORITY`, already `configure()`d) this
  bridge routes admitted commands into. This bridge never constructs or owns
  a `WeaponAuthority`/`WeaponRuntime` itself.
- `set_authority_scope(scope)` / `set_authority_epoch(epoch)` — MUST match
  whatever the game passed to `WeaponAuthority.create_weapon()` for the
  instances this bridge serves. Defaults (`""`, `0`) match
  `create_weapon()`'s own defaults, so a single-scope game needs no extra
  configuration.
- `set_authority_context_provider(callable)` — **required** for live fire:
  builds the `AuthorityContext` Dictionary for an admitted fire command.
  Called as `callable.call(context)` with a Dictionary carrying
  `peer`, `session`, `instance_id`, `command_id`, and `sequence`. Unset means every
  fire evaluates against an all-false/neutral context, which
  `WeaponRuntime::fire()` deterministically rejects (`ACTOR_NOT_LIVE`) — a
  fail-closed default, never a silent "always allow".
- `set_reload_profile_provider(callable)` — **required** for live reload:
  resolves the exact `BallisticProfileIdentity` a `begin_reload` reservation
  carries server-side, since `BeginReloadIntent` carries no profile field at
  all (a client cannot choose canonical ammunition identity). Unset submits
  an empty profile identity, which `begin_reload()` rejects structurally with
  `VALUE_OUT_OF_RANGE` — same fail-closed posture.
- `begin_session(peer, session)` / `end_session(peer)` / `authorize_instance(peer, instance_id, role)` /
  `revoke_instance(peer, instance_id)` / `drop_peer(peer)` — explicit,
  game-driven ownership. A client-declared instance id, role, or epoch in a
  packet MUST NOT by itself grant admission.

CLIENT role: `set_role(WeaponNetworkBridge.ROLE_CLIENT)`,
`set_server_peer_id(peer)` (almost always `1`), then
`request_fire_networked()` / `request_begin_reload_networked()` /
`request_cancel_reload_networked()` / `request_configure_attachments_networked()`
to send intent, `confirmed_snapshot(instance_id)` /
`is_instance_tombstoned(instance_id)` to read confirmed state, and
`request_resync(instance_id)` for gap recovery. `send_compatibility_handshake()`
is called automatically once per bridge lifetime from `_process()`, but is
also callable directly. The automatic RPC is only a readiness exchange in the
current wrapper; it does not validate the advertised manifest. See the
current bridge boundaries in
[`how-it-works.md`](how-it-works.md#current-godot-bridge-boundaries).

Call the client handshake only after the server has run `begin_session()`.
`begin_session()` resets compatibility readiness, while an early handshake for
an unknown peer is ignored; call `send_compatibility_handshake()` again if
those events race or after any reconnect.

### Prediction limits

Client-side prediction is bounded, reversible, and structurally
presentation-only: `WeaponNetworkBridge`'s CLIENT role never touches its own
`WeaponReplica` from a predicted-command call — `request_*_networked()`
records a bounded `PresentationIntent`
(`MAX_PENDING_PRESENTATION_INTENTS` = 64, oldest evicted first;
`MAX_PRESENTATION_INTENT_AGE_TICKS` = 300 ticks / 5s at the default 60 tick/s)
and emits
`presentation_predicted` — there is no code path from these methods to
canonical replica mutation. On rejection or divergence (a replica resync,
gap, or impossible transition), the replica is already sitting at the
newest confirmed snapshot (it was never advanced by prediction), so recovery
only discards or resolves the bounded pending presentation intents for that
instance — never world or damage state.

See [`presentation.md`](presentation.md) for the full signal list this
bridge and `WeaponAuthority` emit.
