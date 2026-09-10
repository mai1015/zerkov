# Authoring

How to author the five sealed V1 definition kinds, the integer milli-MOA
accuracy contract, flat attachment slots, and the canonical parts-per-million
modifier algebra. Every Resource here is a mutable editor-authored input;
`WeaponAuthority.configure()` (Dictionary façade) or
`WeaponDefinitionCatalog.register_*()`/`seal()` (Resource façade,
`native/godot/weapon_definition_catalog.h`) validates and copies current field
values into a sealed, immutable `wpn::WeaponCatalog`. Later mutation of the
authoring Resource — or the Dictionary/Array a caller passed to `configure()`
— never reaches an already-sealed catalog.

> **Runtime integration boundary:** these two entry points own separate native
> catalogs. A sealed `WeaponDefinitionCatalog` cannot currently be passed to
> `WeaponAuthority`; live GDScript setup still supplies Dictionary arrays to
> `WeaponAuthority.configure()`. A successful `configure()` also replaces the
> authority's runtime and removes its live instances. See
> [`how-it-works.md`](how-it-works.md#two-authoring-surfaces-that-do-not-connect-automatically)
> before building a Resource-loading pipeline.

## The five definition kinds

Every kind mirrors one `wpn::` struct in `native/core/wpn_definitions.h` field
for field, and each has a matching Resource in `native/resources/`:

| Kind | Core type | Resource | Identity |
|---|---|---|---|
| Hitscan shot profile | `wpn::HitscanShotProfile` | `HitscanShotProfileResource` | `id` + `version` |
| Recoil profile | `wpn::RecoilProfile` | `RecoilProfileResource` | `id` + `version` |
| Attachment definition | `wpn::AttachmentDefinition` | `AttachmentDefinitionResource` | `id` + `version` |
| Ammunition ballistic profile | `wpn::AmmunitionBallisticProfile` | `AmmunitionBallisticProfileResource` | `id` + `version` |
| Weapon definition | `wpn::WeaponDefinition` | `WeaponDefinitionResource` | `id` + `version` |

(`WeaponAttachmentSlotResource` is a sixth, tiny Resource — one entry inside a
`WeaponDefinitionResource.attachment_slots` array, not an independent sealed
definition kind of its own.)

### Identifier format

Use the canonical identifier format for definitions, instances, slots,
reservations, and commands: a UTF-8 string of 1–128 bytes that starts with
lowercase `a-z`, contains at least two segments separated by `.`, `-`, or `:`, has no adjacent
or trailing separators, and otherwise uses lowercase letters, digits, and `_`.
For example, `weapon.rifle`, `ammo.9mm`, and `slot:optic` are valid; `rifle`,
`Weapon.Rifle`, and `weapon..rifle` are not. Use globally unique command IDs
within one `WeaponAuthority`, because its idempotency history is not scoped by
instance. Authoring, instance creation, and protocol gates validate this
format; direct core command methods do not uniformly revalidate every string.

V1 accepts only `mechanism = HITSCAN_2D` (`wpn::WeaponMechanism::HITSCAN_2D`)
and `fire_mode = SEMI_AUTO` (`wpn::FireMode::SEMI_AUTO`). The authoring
Resource enums (`WeaponDefinitionResource.Mechanism`/`FireMode`) intentionally
list the deferred values too (`MECHANISM_PROJECTILE_2D`,
`FIRE_MODE_AUTOMATIC`, `FIRE_MODE_BURST`) so an author can see the deferred
vocabulary in the inspector — `WeaponDefinitionCatalog::register_weapon()`
rejects anything else with the offending field/value named; it never
approximates a deferred mechanism as semi-auto hitscan.

### Hitscan shot profile

`HitscanShotProfileResource` fields: `identifier`, `version`,
`damage_milliunits` (signed 64-bit fixed-point damage), `range_milliunits`
(max hit range, world milliunits), `spread_microradians` (legacy field —
see "MOA vs. `spread_microradians`" below), `aim_tolerance_microradians`,
`origin_tolerance_milliunits`.

### Recoil profile

`RecoilProfileResource` fields: `identifier`, `version`,
`vertical_kick_nrad` (non-negative per-shot vertical kick),
`horizontal_kick_min_nrad`/`horizontal_kick_max_nrad` (signed range;
`min` MUST NOT exceed `max`), `recovery_per_tick_nrad` (positive linear
recovery slope — V1 has no authored recovery *curve*, only a fixed
per-tick slope toward zero), `max_vertical_offset_nrad`/
`max_horizontal_offset_nrad` (accumulated-offset caps; each must be at least
large enough to fit a single kick). All values are signed 64-bit integer
nanoradians.

### Attachment definition

`AttachmentDefinitionResource` fields: `identifier`, `version`,
`compatible_slot_kinds_mask` (bitmask — see "Attachment slots" below),
`compatible_tags` (bounded free-form tags, ≤8), and five signed
parts-per-million modifiers: `accuracy_modifier_ppm`, `recoil_modifier_ppm`,
`noise_modifier_ppm`, `reload_duration_modifier_ppm`, `cadence_modifier_ppm`
(each bounded to ±`MAX_MODIFIER_DELTA_PPM` = ±500,000, i.e. ±50%). An
attachment has **no** ammunition-identity, capacity, damage, or penetration
field — those are unrepresentable by omission, not merely rejected.
`provided_slot_count` MUST be `0` in V1 (nested/attachment-provided slots are
explicitly rejected, never silently ignored, if authored non-zero).

### Ammunition ballistic profile

`AmmunitionBallisticProfileResource` fields: `identifier`, `version`,
`ammunition_trait` (the exact trait this profile satisfies). This schema has
**no** penetration, armor-response, or projectile-ballistics field — see
"Bullet profile and penetration ownership" below.

### Weapon definition

`WeaponDefinitionResource` fields: `identifier`, `version`, `mechanism`,
`fire_mode`, `shot_profile_id`/`shot_profile_version` (required reference),
`ammunition_trait`, `capacity` (internal loaded-round count — V1 has no
detachable-magazine item identity or chamber), `cadence_ticks` (positive
minimum authority ticks between accepted shots), `reload_ticks` (positive
authority ticks a reload takes), `noise_radius_milliunits`,
`accuracy_moa_milli` (see below), `recoil_profile_id`/`recoil_profile_version`
(**required** reference — exactly like `shot_profile_id`; an empty
`recoil_profile_id` is rejected), and `attachment_slots` (bounded ordered
array of `WeaponAttachmentSlotResource`, ≤`MAX_ATTACHMENT_SLOTS_PER_WEAPON` =
8, unique slot IDs; order is authoring-significant and participates in the
content fingerprint).

## Accuracy: integer milli-MOA

Authoritative accuracy is authored as `accuracy_moa_milli` — a non-negative
integer where `1000` means exactly one minute of angle (MOA), and the value
is the **full group diameter**, not a radius. It is bounded by
`MAX_ACCURACY_MOA_MILLI` = 60,000 (60 MOA).

The core converts half that diameter (a radius) to a non-negative integer
nanoradian angular radius as:

```
angular_radius_nrad = round_half_up(
    accuracy_moa_milli * 3_141_592_654 / 21_600_000
)
```

using checked 128-bit-safe quotient/remainder integer arithmetic
(`wpn::convert_accuracy_moa_milli_to_angular_radius_nrad`,
`native/core/wpn_numerics.cpp`). `3_141_592_654` is the sealed V1 integer
representation of π in nanoradians (`PI_NANORADIANS`); `21_600_000`
(`MOA_MILLI_TO_NANORADIAN_DENOMINATOR`) is the fixed denominator that folds
in the milli-MOA scale, the /2 (diameter→radius), and the MOA→radian
conversion in one integer ratio. No platform floating-point value and no
presentation-only crosshair value ever participates in this conversion; the
formula, its rounding rule, and `MOA_CONVERSION_VERSION` are sealed inputs to
the content fingerprint.

**Worked example** (this exact case is asserted by
`wpn_test_numerics.cpp` and `wpn_test_authoring.cpp`):

`accuracy_moa_milli = 2500` (2.5 MOA full group diameter) →

```
2500 * 3_141_592_654 = 7_853_981_635_000
7_853_981_635_000 / 21_600_000 = 363_610  remainder 5_635_000
```

The remainder (5,635,000) is less than half the divisor (10,800,000), so
`round_half_up` rounds down: **`angular_radius_nrad = 363610`** on every
supported platform, bit-identical.

Negative or above-limit `accuracy_moa_milli` fails catalog validation before
runtime readiness.

### MOA vs. `spread_microradians`

`HitscanShotProfileResource.spread_microradians` predates the sealed
milli-MOA/nanoradian numeric contract and is **no longer consulted** by the
fire-path dispersion calculation, which derives its angular radius from
`WeaponDefinition.accuracy_moa_milli` as described above. The field is
retained only because `native/godot/weapon_authority.cpp`'s Dictionary façade
already reads/writes it; author `accuracy_moa_milli` on the weapon
definition for authoritative accuracy, not `spread_microradians` on the shot
profile.

## Attachment slots

`WeaponAttachmentSlotResource` pairs a stable `slot_id` with exactly one
`SlotKind` ordinal (`SLOT_KIND_OPTIC = 0`, `SLOT_KIND_MUZZLE = 1`,
`SLOT_KIND_STOCK = 2`, `SLOT_KIND_GRIP = 3` — translated explicitly into the
core's `wpn::AttachmentSlotKind` bit value by
`WeaponDefinitionCatalog`/`weapon_authority.cpp`, never cast directly).
`AttachmentDefinitionResource.compatible_slot_kinds_mask` is instead a
**bitmask** over the same closed set (`SLOT_KIND_BIT_OPTIC = 1`,
`SLOT_KIND_BIT_MUZZLE = 2`, `SLOT_KIND_BIT_STOCK = 4`,
`SLOT_KIND_BIT_GRIP = 8`), since one attachment may fit several slot kinds
while one slot accepts only one kind.

Via the Dictionary façade (`WeaponAuthority.configure()`'s `p_weapons[i]`),
`attachment_slots` is `Array[{slot_id: String, slot_kind: int}]` where
`slot_kind` is the raw bit value (1/2/4/8) — the same vocabulary an
attachment's `compatible_slot_kinds_mask` uses.

V1's attachment loadout is flat: a weapon declares at most 8 slots, each
slot accepts at most one attachment, and an attachment definition can never
itself provide additional slots (`provided_slot_count` must be `0`; a
non-zero value is a validation error naming that exact field, not a silently
ignored one). `configure_attachments()` replaces a weapon instance's entire
loadout atomically — see [`integration.md`](integration.md)'s "Command
envelope semantics" for the runtime contract.

## Canonical parts-per-million modifier algebra

Attachment accuracy/recoil/noise/reload/cadence fields are signed
**parts-per-million deltas** around the neutral multiplier
`MODIFIER_NEUTRAL_PPM` = 1,000,000 (100%). Each attachment delta is bounded to
±`MAX_MODIFIER_DELTA_PPM` = ±500,000 (±50%). Fire-time `AuthorityContext`
values use a different input shape: they are neutral-1,000,000 multipliers,
not deltas. Damage and range use those multipliers directly; spread, noise,
and recoil first convert them to one delta (`multiplier - 1_000_000`) and fold
that with attachment deltas. Consequently, use 500,000–1,500,000 for those
three folded authority multipliers; a value outside that interval is rejected
by the current per-delta bound.

For each property (accuracy, recoil, noise, reload duration, cadence), the
core (`wpn::fold_modifier_deltas_ppm`, `native/core/wpn_numerics.cpp`):

1. sums every contributing delta in canonical
   **`(source, slot_id, definition_id, definition_version)` order** using checked arithmetic —
   never insertion/registration order, so two catalogs describing the same
   modifiers in different container order fold to the same aggregate;
2. clamps the resulting aggregate multiplier **once** to
   `[MIN_MODIFIER_MULTIPLIER_PPM, MAX_MODIFIER_MULTIPLIER_PPM]` =
   `[0, 4,000,000]` (0%–400%);
3. multiplies the property's base value by that aggregate multiplier exactly
   once (checked, 128-bit-safe), **rounds ties away from zero**
   (`wpn::apply_modifier_multiplier`);
4. applies the property's own final legal clamp.

A fold exceeding `MAX_MODIFIER_FOLD_DELTAS` = 64 entries, an out-of-bound
single delta, or a checked-arithmetic overflow rejects the **complete**
modifier set before mutation — never a partial application. Recoil modifiers
affect only the *new kick magnitude* of the next shot; the recovery slope is
always the sealed `RecoilProfile.recovery_per_tick_nrad` and is never
modifier-affected in V1.

`WeaponAuthority.effective_modifiers(instance_id)` is a pure read-only query
returning the instance's *current accepted attachment loadout's* aggregate
multipliers (`accuracy_multiplier_ppm`, `recoil_multiplier_ppm`,
`noise_multiplier_ppm`, `reload_duration_multiplier_ppm`,
`cadence_multiplier_ppm`) — it does **not** fold in any authority-supplied
delta from a live `fire()` call, unlike the fire-time computation itself.

## Bullet profile and penetration ownership

Every sealed `AmmunitionBallisticProfile` declares one exact
`ammunition_trait`. A weapon definition's own `ammunition_trait` must match
for reload/fire compatibility, validated even when Inventory System is
absent. Weapon and attachment definitions have **no** penetration field at
all — authoring one is rejected with the offending field named. Penetration,
armor response, and projectile ballistics belong on the game's own
ammunition/bullet content, referenced by the same ballistic-profile identity
a committed shot and its `DamageRequest` carry
(`wpn::DamageRequest::profile`, `native/core/wpn_world_ports.h`) — see
[`integration.md`](integration.md)'s "World ports" section.

## Validation and diagnostics

Catalog validation rejects: empty IDs, duplicate `(id, version)` pairs,
unknown references (unknown shot/recoil profile, unknown attachment,
unknown ballistic profile), non-finite values, negative values where
prohibited, values above documented limits, zero capacity, zero/negative
damage, zero/negative cadence or reload duration, and invalid tolerance/MOA/
recoil/attachment/ballistic-profile references — all before a runtime
becomes ready. `WeaponDefinitionCatalog.validate_catalog()` runs the same
checks over a scratch catalog (nothing registered into the real one) and
returns a bounded, deterministic, stable-order findings array (capped at
`DEFAULT_MAX_FINDINGS` = 64, `truncated`/`truncated_count` reported past
that) — use it for editor-time or CI diagnostics before committing to
`register_*()`/`seal()`. See
[`troubleshooting.md`](troubleshooting.md) for the exact `StatusCode`/
`DiagnosticId` values each failure reports.
