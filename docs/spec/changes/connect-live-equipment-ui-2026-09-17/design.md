# Design

Status: proposed; implementation requires explicit approval.

## 1. Preserve current ownership boundaries

`InventoryAuthority` remains the sole canonical owner. The Character screen receives immutable projections and submits intents. The existing raid/loadout inventory remains separate from the profile stash; this change deliberately does not invent a cross-authority transaction.

The accepted inventory pipeline already exposes same-inventory native `equip_item` and `unequip_item` commands. The game-owned `InventoryIntentAdapter` will add strict equip/unequip intent schemas and invoke those methods only after the same session, actor, generation, revision and ownership checks used by existing mutations. Business rejection returns a stable receipt and does not fail the raid tick.

## 2. Equipment projection

Extend the presentation seam with a detached equipment projection derived from the confirmed loadout snapshot:

- locate the root `zerkov.container.equipment` container;
- inspect items whose canonical location kind is `slot`;
- key them by the declared `slot_identifier`;
- include stable item id, item definition id, quantity, inventory revision and presentation-only display metadata;
- never expose native Resources, authority objects or writable dictionaries.

The projection SHALL represent all canonical named slots, including empty slots. It SHALL NOT manufacture entries for authored UI slots absent from the canonical equipment profile.

The secure container becomes a normal read/projection source over its canonical spatial container. Existing pockets, rig and backpack projections remain unchanged.

## 3. Slot validation

The current `InventoryIntentAdapter._normalize_location()` incorrectly applies `ZIdentityRules.is_valid_part()` to the complete dotted slot identifier. Runtime entity identity grammar and Inventory catalog content identifiers are different namespaces.

Equip admission will not accept an arbitrary dotted string based on syntax alone. The adapter resolves the destination equipment container from the current snapshot/catalog and accepts only a slot identifier actually declared by that container. This simultaneously fixes valid authored slots and rejects unknown/injected slot names.

Unequip destinations remain ordinary validated spatial/list locations owned by the same loadout inventory.

## 4. UI mapping

Retain `ui/screens/character/character_screen.tscn` and its established visual hierarchy.

Canonical mapping for the current first playable:

- `zerkov.slot.weapon_primary` → authored `SlingSlot`;
- `zerkov.slot.weapon_melee` → authored `LegStrapSlot`;
- rig/backpack equipment state is reflected in the existing rig/backpack sections and status text; if canonical rig/backpack item definitions are later populated, those same slot projections become their source;
- authored Head/Face/Armor/Headset/Back-secondary/Holster controls have no current canonical slots and therefore render `UNAVAILABLE`/empty, are disabled, and never display fixture weapons or ammunition.

Live item labels come from the projected canonical item definition. Ammunition count shown with a weapon, if present, must come from the confirmed weapon/inventory projection; otherwise omit the count rather than retain a fixture number. Icons may be shown only when mapped to the same canonical item definition; otherwise use a neutral empty/placeholder treatment, not a different sample item.

## 5. Interaction model

Pointer/controller/keyboard equipment actions emit intents. Supported actions:

- drag or action-menu equip from a loadout spatial container into a compatible canonical equipment slot;
- unequip from a canonical slot into a selected/auto-placement loadout spatial container;
- same-inventory slot swap only if the native authority and compatibility rules accept it.

Pending presentation may show reversible intent feedback, but the slot changes only when the confirmed snapshot revision advances. Rejection restores the confirmed placement and presents the stable reason.

Profile stash remains visibly read-only in this change. The UI must not imply that dragging from stash into loadout is supported.

## 6. Persistence and deployment

`LocalCampaign.save_home()` already serializes the canonical loadout and stash separately. After any accepted home equipment mutation, the normal home save boundary persists the changed loadout. Deployment continues to instantiate the raid inventory from that persisted loadout record. No alternate equipment save file or fixture fallback is introduced.

Acceptance includes relaunch before deployment to prove persistence, and post-deployment verification against the raid inventory snapshot and equipment reconciler.

## 7. Failure and lifecycle behavior

- stale UI generation, owner generation, inventory revision or item identity → reject with no mutation;
- incompatible item/slot or occupied slot when swap is not explicitly requested → native rejection, no local repair;
- inventory owner replacement/teardown → equipment projection becomes unavailable and controls disable;
- corrupt/missing local save → existing local-save error path; never seed fixture equipment;
- unsupported authored gear slot → disabled presentation-only state, not an intent target.

## 8. Verification

Add focused contracts for slot projection, equip/unequip admission, invalid-slot rejection, stale revision/generation, equipment/ability reconciliation, secure-container projection and UI fixture removal. Add one native exact-1920x1080 application flow using real input:

1. open local campaign and Character/Gear;
2. assert canonical AKM and machete appear in the expected live slots;
3. unequip/re-equip the primary weapon through UI input;
4. attempt an incompatible slot and prove no mutation;
5. leave the screen so the normal home save runs;
6. restart from the same isolated local profile;
7. prove the same loadout appears;
8. deploy and prove the raid inventory/equipment reconciler receives the same primary/melee equipment.

The test must inspect canonical snapshots/receipts for assertions; it must not seed fixture state after campaign creation or call native mutation methods directly as a substitute for UI input.
