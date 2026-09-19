# Design — Tarkov-like Gunsmith Foundation

## 1. Design principles

1. **Inventory owns things; build authority owns assembly meaning; WeaponAuthority owns firearm mechanics.**
2. **One real item identity per part.** Installed parts are not copied into a second build inventory.
3. **Atomic apply.** A gunsmith action either produces one valid complete build or leaves inventory, build, and weapon runtime unchanged.
4. **Flat mechanics, hierarchical presentation.** V1 can show a readable slot tree while the native runtime remains bounded and flat.
5. **No fake raid art.** Cataloging a weapon does not imply it has an approved held pose.
6. **Source art is data, not compatibility.** Archive folder names seed authoring; sealed definitions decide runtime behavior.

## 2. Asset inventory and initial taxonomy

The uploaded archive contains 32 firearm families and 62 attachment images.

| Family | Count | Family-layer coverage |
| --- | ---: | --- |
| AR | 8 | gun plus family-specific barrel/stock/grip/scope where supplied |
| SMG | 8 | gun plus family-specific stock/grip/scope where supplied |
| Pistol | 7 | base gun layers |
| Shotgun | 5 | base gun layers |
| Sniper | 4 | gun plus scope where supplied |

All 84 family-layer PNGs are 96x32. Attachments are exactly 31 small and 31 large images:

| Attachment category | Count |
| --- | ---: |
| Optic | 10 |
| Stock | 10 |
| Grip | 10 |
| Barrel | 10 |
| Muzzle | 20 |
| Laser | 2 |

The authoring importer SHALL preserve original bytes and emit an explicit manifest with dimensions, hashes, family/category, size class, and source path. It SHALL reject `DO NOT USE` sources.

## 3. Canonical data model

### 3.1 Weapon platform definition

A `ZWeaponPlatformDefinition` describes a customizable firearm platform:

- stable `platform_id`
- inventory item definition ID
- Weapon System definition ID/version
- family and authored display name
- size class (`small` or `large`)
- preview art recipe
- ordered semantic slots
- approved raid pose profile ID or empty
- compatibility tags

V1 semantic slot categories:

- `optic`
- `muzzle`
- `stock`
- `grip`
- `barrel`
- `laser`

A platform may expose zero or one slot of each category in the first slice. The data shape allows stable unique slot IDs per platform.

### 3.2 Part definition

A `ZWeaponPartDefinition` contains:

- stable `part_definition_id`
- inventory item definition ID
- native Weapon System attachment definition ID/version
- category and size class
- required/blocked compatibility tags
- original preview texture
- authored mount transform for preview
- modifier metadata
- optional raid-presentation metadata

Compatibility is explicit data. Filename parsing is allowed only in the import/audit tool that generates a reviewable candidate manifest.

### 3.3 Weapon item subtree

Every customizable weapon item SHALL provide one nested list container, `zerkov.container.weapon_parts`. Installed part item instances live inside this container.

The weapon item's mutable component `zerkov.component.weapon_build.v1` stores a bounded canonical payload:

```
{
  schema: "zerkov.weapon_build.v1",
  build_revision: int,
  slots: [
    {slot_id: String, part_item_id: int, part_definition_id: String}
  ]
}
```

Entries are sorted by `slot_id`. The component references only children actually present in the weapon's provided part container. Orphan children and references to external items fail validation.

This gives InventoryAuthority ownership of the complete transferable subtree while preserving semantic slot identity.

## 4. WeaponBuildAuthority

`WeaponBuildAuthority` is game-owned and session/profile scoped. It consumes immutable Inventory snapshots plus sealed platform/part catalogs and exposes:

- `build_snapshot(weapon_item_id)`
- `compatibility(weapon_item_id, slot_id, candidate_part_item_id)`
- `preview_build(command)` — pure validation/stat projection
- `install_part(command)`
- `remove_part(command)`
- `swap_part(command)`
- `apply_preset(command)`

Mutating commands carry:

- stable command/request ID
- actor/source identity
- inventory ID
- weapon item ID
- expected inventory revision
- expected build revision
- semantic slot ID
- candidate part item IDs where relevant

Commands are bounded and idempotent. Exact replay returns the terminal receipt. Reusing a command identity with different payload rejects without mutation.

## 5. Atomic cross-domain mutation

A gunsmith mutation is coordinated by a game-owned adapter.

### Install/swap

1. Read one immutable inventory snapshot and current weapon-build component.
2. Authenticate weapon and candidate part ownership.
3. Validate platform, slot, candidate definition, size/tags, build bounds, and destination nesting.
4. Compute the complete desired semantic build and corresponding native flat loadout.
5. Preflight Inventory and WeaponAuthority revisions.
6. Move the candidate part into the weapon-provided parts container and move the replaced part back to the requested stash/backpack destination.
7. Write the new canonical `weapon_build` mutable component.
8. Apply the complete native attachment loadout.
9. Publish one confirmed build projection.

If any required step cannot be admitted, the command SHALL fail before mutation. If a downstream native failure occurs after an inventory mutation is committed, the adapter SHALL enter an explicit recovery-required state rather than pretending the build succeeded. The implementation task must prefer a transaction/preflight seam that prevents this split-brain case.

### Transfer

Because installed parts are nested children, existing inventory subtree transfer moves the weapon and parts together. The build component travels with the weapon item. On destination admission, the build reconciler validates the component against the transferred children and reconstructs the native weapon loadout.

## 6. Native Weapon System extension

The existing runtime is intentionally flat and bounded to at most eight attachment slots. V1 preserves that property.

Existing slot kinds remain:

- Optic
- Muzzle
- Stock
- Grip

This change proposes additive native kinds:

- Barrel
- Laser

The protocol/catalog fingerprint and compatibility version SHALL change exactly as required by the addon rules. Old peers/builds must reject incompatible catalogs/protocols rather than reinterpret slot ordinals.

Attachment-provided slots remain forbidden in v1.

Barrels may use the existing bounded accuracy/recoil/noise/reload/cadence modifier algebra. Lasers may initially have neutral mechanical modifiers while still existing as a real installed part and presentation capability; laser aiming behavior is a separate approved feature.

## 7. Presets

A local `WeaponPresetStore` persists definition-level recipes:

```
{
  preset_id,
  name,
  platform_id,
  slots: [{slot_id, part_definition_id}]
}
```

No item IDs are persisted in presets.

Applying a preset:

1. finds compatible owned part instances from the current inventory snapshot;
2. resolves deterministically by lowest stable item ID unless the user selected a specific instance;
3. reports missing definitions before mutation;
4. applies the complete build atomically or not at all.

Presets do not purchase, spawn, or duplicate parts.

## 8. Gunsmith UX

Entry points:

- Character > selected firearm > **MODDING**
- context action on an owned firearm > **MODDING**

Desktop layout:

- center-left: scalable weapon preview assembled from source layers;
- left rail: semantic slot tree with installed part names/status;
- right pane: owned compatible parts, with filters for compatible/all/owned;
- bottom stats: current versus preview deltas;
- footer: Apply, Revert, Save Preset, Load Preset.

Selection is preview-only until Apply. Preview never mutates inventory or WeaponAuthority.

Incompatible parts remain inspectable when the user chooses All, with a concrete reason such as wrong size class, wrong slot category, missing required tag, blocked tag, or slot unavailable on platform.

The visual language SHALL reuse Zerkov's bunker/character UI rather than reproduce Tarkov's layout or trade dress.

## 9. Preview composition

The preview renderer uses the shared 96x32 family canvases. Each family-specific layer and generic attachment receives an authored mount transform. The preview system is deterministic and editor-adjustable.

V1 preview order:

1. base gun/receiver
2. barrel
3. stock
4. grip
5. muzzle
6. optic
7. laser

Specific platform resources may override z-order where the source art demands it.

## 10. Raid presentation gating

Customization breadth and raid usability are separate.

Each platform must declare a `pose_profile_id`. A pose profile specifies the approved held-art strategy, muzzle anchor, mirroring rules, and any hand/arm substitution.

- If a profile exists and passes visual/native contracts, the weapon may be equipped for raid.
- If no profile exists, Gunsmith may customize it in bunker, but deployment SHALL state `RAID PRESENTATION UNAVAILABLE` and reject it as a primary weapon.
- No unreviewed platform may silently reuse AKM holding arms.

This keeps the current corrected gun-local muzzle and source-frame melee guarantees intact.

## 11. Stat projection

The UI reads confirmed native effective modifiers for committed builds. Preview stats are calculated with the same canonical authoring math in a pure game-owned projection and verified against native results in differential tests.

V1 exposes only stats backed by authoritative mechanics:

- accuracy
- recoil
- noise
- reload duration
- cadence

Weight comes from InventoryAuthority mass. Ergonomics, muzzle velocity, durability and jamming are deferred until they have an authoritative owner.

## 12. Bounds

Initial hard bounds:

- 32 authored firearm platforms from this source pack
- 62 authored attachment art records from this source pack
- at most 8 native mechanical slots per firearm
- at most 8 installed semantic parts in v1
- build component payload must remain within Inventory mutable-component limits
- preset name <= 48 UTF-8 bytes
- at most 64 local presets
- no attachment-provided recursive slots in v1

## 13. Migration

Existing AKM instances with no `weapon_build` component reconcile to an empty/default build without reseeding or replacing item identity. The current canonical AKM equipped state, loaded-round state, and persisted item identity must survive migration.

The new source-pack firearm definitions SHALL NOT be seeded into existing profiles automatically. Test fixtures may create them only in isolated test inventories.
