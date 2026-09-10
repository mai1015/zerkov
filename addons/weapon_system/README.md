# Weapon System

Weapon System is a deterministic, server-authoritative firearm runtime for
Godot 4.7. Its native C++ core is engine-independent; Godot Resources, Nodes,
networking, Inventory System, Gameplay Abilities, and presentation are
adapters around that core. The engine-free 2D world coordinator is not yet
bound to GDScript.

Start with [`docs/how-it-works.md`](docs/how-it-works.md). It follows one
weapon from definition and instance creation through fire/reload, world
resolution, replication, and presentation, and calls out the current façade
boundaries before they surprise an integration.

## Installation

1. Copy (or, in this repository, simply enable) `addons/weapon_system/` —
   `Project Settings > Plugins > Weapon System`.
2. This is a **required native GDExtension**; there is no GDScript fallback.
   Confirm a matching platform/build-type artifact exists under
   `addons/weapon_system/bin/` and is declared in
   `weapon_system.gdextension` — Godot refuses to start (loudly) if the
   declared artifact for the current target is missing.
3. Optionally enable `addons/weapon_system_inventory/` and/or
   `addons/weapon_system_gameplay_abilities/` — each is a separately
   enableable plugin depending only on this addon's and its target
   sibling's public façade, never required by this addon or by each other.

See [`docs/distribution.md`](docs/distribution.md) for building the
native artifact and the current platform support matrix.

## V1 scope

V1 intentionally implements the smallest reusable top-down survival-shooter
slice:

- immutable versioned weapon and hitscan definitions;
- stable weapon-instance identity and revisions;
- semi-automatic 2D hitscan fire;
- server-tick cadence and deterministic spread;
- one internal loaded-round count;
- authority-tick simple reload using an external ammunition reservation;
- authoritative pose tolerance plus native-C++ nearest-target resolution,
  obstruction, damage dispatch, and positional noise;
- canonical commands, outcomes, snapshots, deltas, and compatibility data;
- optional Inventory System and Gameplay Abilities adapters.

The following are explicit V1 exclusions: automatic or burst fire,
projectiles, detachable magazine item instances, chambered rounds, tactical
reload policy, nested/attachment-provided slots, durability, heat, jams,
malfunction clearing, armor penetration, body-part ballistics, bleeding,
medical consequences, and client rollback of arbitrary world or damage
state. Flat attachment slots and atomic loadout replacement are implemented.

Unsupported authored mechanisms fail validation. They are never approximated
as a supported mechanism.

## Ownership and dependency direction

| Concern | Canonical owner |
| --- | --- |
| Weapon definition, loaded rounds, cadence, spread, reload state | Weapon System |
| Physical weapon/ammo ownership and equipment location | Inventory System or game authority |
| Ability grants, activation gates, character modifiers, effects, cues | Gameplay Abilities adapter/GAS |
| Actor pose, targets, obstruction, damage sink, noise sink | Game world |
| Session identity, authentication, ownership, transport | Game |
| Animation, audio, VFX, crosshair, HUD, input routing | Game presentation |

The base addon does not depend on Inventory System, Gameplay Abilities,
CommonUI, a transport, a database, or a game-specific actor model.

Inventory integration is one-way and optional. It projects accepted
authoritative equipment and ammunition reservations into Weapon System. It
never grants a weapon from a pending UI ghost or client claim.

Gameplay Abilities integration is also one-way and optional. It translates
accepted Fire/Reload activation into ordinary weapon commands and can supply
authority-derived modifiers or one selected damage sink. GAS cooldowns do not
replace mechanical cadence, GAS costs do not consume physical ammunition, and
GAS tasks do not complete reload independently.

## Authority invariants

- A rejected command changes no mechanical state or revision and emits no
  canonical transition event. Once a command passes envelope admission, its
  tick/sequence bookkeeping may still advance even when gameplay rejects it.
- Accepted fire consumes exactly one round and advances revision once.
- A duplicate command returns its recorded outcome; a conflicting duplicate
  is rejected.
- Claimed aim/origin is intent. The committed shot uses authoritative pose.
- When a configured native `WorldCoordinator` resolves a valid committed shot,
  it performs at most one damage dispatch and one noise dispatch, including
  misses. `WeaponAuthority` does not invoke that coordinator for you.
- Reload accepts only a reservation ID, quantity, and exact ammunition profile;
  the external ammunition authority must validate and settle that reservation.
- Clients may predict presentation only.
- Headless authority never requires rendering, audio, UI, or physical input.

## Documentation

- [`docs/how-it-works.md`](docs/how-it-works.md) — the first-time adopter
  guide: end-to-end mental model, a working direct-authority example, runtime
  lifecycle, commands/receipts, fire/reload/recoil/attachments, world and
  networking boundaries, snapshots/deltas, presenters, limits, and an
  integration checklist.
- [`docs/authoring.md`](docs/authoring.md) — the five sealed
  definition kinds, the integer milli-MOA formula (with a worked example),
  attachment slots, and the canonical parts-per-million modifier algebra.
- [`docs/integration.md`](docs/integration.md) — roles, the command
  envelope, authority modifiers, world ports, consequence identity, protocol
  v2/compatibility fingerprints, and `WeaponNetworkBridge` setup.
- [`docs/presentation.md`](docs/presentation.md) — every signal, the seven
  optional presenter helpers, and the presentation/authority boundary.
- [`docs/verification.md`](docs/verification.md) — every build/test command
  and what each suite proves.
- [`docs/distribution.md`](docs/distribution.md) — installing the addon and
  the pre-1.0 platform support matrix.
- [`docs/troubleshooting.md`](docs/troubleshooting.md) — actionable
  `StatusCode`/`DiagnosticId` diagnostics.
- Adapters: `weapon_system_inventory` and
  `weapon_system_gameplay_abilities` are separately distributed packages and
  are not included in this standalone addon.
- In the full source checkout only, the repository-level
  [Zerkov parity evidence](../../docs/weapon_system/zerkov-parity.md) and
  [adoption boundary](../../docs/weapon_system/zerkov-adoption-boundary.md)
  record comparison and migration considerations. They are not required to
  use this standalone package.

## Status

The usable slice now includes the deterministic native fire/reload/recoil/
attachment core, editor-Resource authoring (`WeaponDefinitionCatalog` +
the six `native/resources/` Resource classes) alongside the original
Dictionary-based `WeaponAuthority` façade, canonical protocol v2 codecs, the
optional `WeaponNetworkBridge` (owner/role/epoch/sequence/rate/size
admission, snapshot/delta convergence, bounded reversible client
prediction), optional Inventory and GAS adapters (exact ammunition-profile
mapping, accepted attachment-slot projection, dormant item-backed
lifecycle), and optional 2D/read-only helpers under `presenters/`.

Two boundaries matter to adopters. First, the Resource-backed
`WeaponDefinitionCatalog` and Dictionary-backed `WeaponAuthority` own
separate native catalogs; there is no public transfer API between them, so
live GDScript runtime setup currently uses `WeaponAuthority.configure()`.
Second, the bundled Godot `WeaponNetworkBridge` is experimental and is not
production-hardened: its compatibility handshake, client command identity/
entropy, resync authorization, initial-snapshot acknowledgement, and
reconnect paths have documented gaps. See
[`docs/how-it-works.md`](docs/how-it-works.md#current-godot-bridge-boundaries)
before adopting it for untrusted peers.

**Known gap**: the engine-free `wpn::WorldCoordinator` (2D hitscan
resolution, damage dispatch, positional noise —
`native/core/wpn_world_coordinator.h`) is fully implemented and tested but has **no
Godot façade yet** — no `ClassDB`-registered Node, no `shot_resolved`
signal. `WeaponAuthority`'s bound surface stops at the mechanical fire
commit (`shot_committed`). See
[`docs/troubleshooting.md`](docs/troubleshooting.md#world-resolution-hitmissdamagenoise-never-happens)
for exactly what that means for a GDScript-only game today.

Public APIs are pre-1.0 until the full verification and reference-slice gates
are complete.
