# Combat content boundary

`zerkov_combat_content.gd` is the first-playable combat catalog.

- The native Weapon System catalog contains one V1 firearm: `zerkov.weapon.akm`.
  Its shot, recoil, ammunition-ballistic profile, and three flat attachment
  definitions are validated by `WeaponDefinitionCatalog.validate_catalog()` and
  then copied through `register_*()` before `seal()`.
- The Weapon System currently accepts only semi-automatic 2D hitscan weapons.
  It has no melee mechanism, so `zerkov.weapon.machete` is deliberately a
  game-owned authoritative melee dictionary. It carries integer damage/reach,
  60 Hz wind-up/active/recovery timing, stamina cost, and a single-target rule.
  It is never registered as a `WeaponDefinitionResource` and must be consumed
  by the later game melee authority.
- `WeaponAuthority.configure()` is exposed by `build_runtime_configuration()`
  as a separate Dictionary path because the vendored add-on has no
  Resource-catalog-to-authority bridge. It is startup configuration only.
- Inventory and combat keep distinct but explicit identities: the physical
  AKM item maps to `zerkov.weapon.akm`, while the physical 7.62x39 stack maps
  to the exact `zerkov.item.ammo.762x39.standard` ballistic profile through
  `zerkov.trait.ammo.caliber_762x39`. The physical
  `zerkov.item.magazine.akm_30` remains inventory-owned: Weapon System V1
  models an internal 30-round count and has no detachable-magazine identity.

All IDs are lower-case dotted `zerkov.*` identifiers. Spatial and damage values
are integer Weapon System milliunits, scalar costs use integer Gameplay
Abilities micro-units, and timing uses authoritative integer ticks. No
presentation or animation event can make a melee hit authoritative.

`zerkov_health_ability_content.gd` is the first-playable Gameplay Abilities
health catalog. It authors seven zone-health attributes plus whole-life state,
stamina, hydration, pain and movement scale, together with zone-specific heavy
bleed, fracture, bandage and splint tags/effects. Persistent state is committed
by long-running abilities: dead cancels the alive execution, bandaged cancels
the matching bleed execution, and splinted cancels the matching fracture
execution, so native teardown removes the old effect, tag and modifiers.

Set-by-caller damage/resource effects must enter through
`ZerkovHealthAbilityContent.apply_bounded_instant()`. It accepts integer
micro-units, caps overkill and restoration to actual base/current headroom,
rejects resource overspend, and verifies the exact authored ability grant.
Before native activation it also rejects stale per-grant command sequences,
runs the public side-effect-free effect preflight, and holds a per-component
guard so a synchronous native change notification cannot reenter the seam and
enqueue a second helper-owned mutation. If a notification from another native
operation is delivering notifications, the seam probes the native mutation
queue through its public task-transition API at the already-admitted tick. A
full queue is rejected synchronously without exposing the request's future tick
or reserving headroom. Otherwise the seam reserves projected attribute
headroom, command sequence and tick, then dispatches the real ability activation
from its bounded game-owned queue after native notification delivery. Calls
arriving behind a reservation join that queue instead of overtaking it. Each
receipt reports zero applied work until public activation-lifecycle signals
settle it, and `bounded_application_receipt()` exposes that terminal result.
The bounded receipt ID is process-local admission bookkeeping, not the stable
combat-consequence identity which remains task 5.6-owned.
Rejected calls therefore advance neither canonical snapshot bytes nor the
component's diagnostic tick watermark, while multiple queued calls cannot
oversubscribe a bounded attribute. Initialization likewise verifies the live
sealed-catalog provenance and 60 Hz clock before mutation, and remains
idempotent after valid gameplay changes.

The declarations intentionally stop at task 5.5's data/policy boundary. Task
5.6's `HealthConsequenceAdapter` consumes exact phase-6 weapon-consequence
records in journal sequence during phase 7, translates fixed damage through the
bounded health seam, evaluates the fingerprinted `ZerkovHealthConsequencePolicy`,
and owns stable damage, injury, bleed, heal, death and kill identities. Heavy
bleed schedules fixed one-unit damage every 60 ticks; a 25-unit committed hit
starts heavy bleed and a 35-unit arm/leg hit also fractures. Lethal head or
thorax damage publishes dead/unusable status and interrupts actor reloads before
same-tick treatment work can run.

Bandage and splint item quantities remain Inventory System-owned. The
`InventoryMedicalParticipant` selects their unique sealed traits from the
declared pocket/rig/backpack/secure order, prepares a quantity hold, and exposes
silent commit, publication and exact-predecessor rollback to the health
coordinator. Health and item successors either both commit, both restore, or
leave a bounded fail-stop recovery record when either mutation cannot be
proved. Task 5.7 will route player quick-heal actions into the adapter's exact,
queue-only treatment request schema. Presentation remains consequence-free.

`ZerkovGameplayAbilityContent` is the explicit composition root for health and
equipment definitions. Gameplay Abilities catalogs do not merge implicitly, so
runtime composition must configure a component from that combined catalog
before initializing either content family. Its combined initializer performs
one exact-catalog/family preflight before either family may mutate state.
