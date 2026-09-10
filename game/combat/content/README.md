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
