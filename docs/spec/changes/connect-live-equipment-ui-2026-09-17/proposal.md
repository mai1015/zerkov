# Connect live equipment UI

Status: proposed; implementation requires explicit approval.

## Why

The local first-playable now launches the real campaign and binds the inventory grids to canonical snapshots, but the Character Gear column still renders authored fixture weapons and disables those controls in live mode. The live presentation controller also ignores `slot` item locations, so equipped items are not available as a production projection. The current intent adapter has no equip/unequip verbs, and its generic slot-location normalization treats a dotted catalog slot identifier as one runtime identity segment, which rejects valid authored slots such as `zerkov.slot.weapon_primary`.

The result is misleading: a starter AKM and machete really exist in canonical equipment slots and deploy correctly, while the UI shows fixture-only gear rather than those items. A player cannot reliably inspect or change canonical equipment from the production Character workspace.

## Goal

Connect the existing Character inventory/gear screen to canonical equipment state without replacing the screen or bypassing Inventory authority. Production live mode shall:

- render actual equipped items from canonical named-slot locations;
- render the secure container from the canonical loadout;
- submit equip and unequip intents through the game-owned inventory authority seam;
- validate destination slots against the current canonical equipment container/catalog rather than the runtime-identity grammar;
- update only from confirmed inventory projections;
- persist home loadout changes through the existing local `ProfileStore` flow and deploy exactly that saved loadout;
- remove fixture item names/ammunition counts/icons from live gear presentation; unsupported visual slots must be visibly unavailable instead of showing sample equipment.

## Scope

This change covers equipment inside the current loadout inventory: primary weapon, melee weapon, rig and backpack named slots declared by `ZerkovInventoryCatalog`, plus the secure container and the existing pockets/rig/backpack inventory grids. It may add presentation metadata for those existing item definitions, but it does not add new equipment categories.

Home and raid equipment mutations remain intent-only and authority-owned. Equip/unequip are same-inventory operations and therefore stay within the existing `InventoryAuthority` that owns the loadout. Home changes are persisted before deployment using the existing local campaign save boundary.

## Explicit non-goals

- No performance work or simulation scheduling changes.
- No Steam, multiplayer, PvPvE, cloud saves or backend work.
- No marketplace, trader, insurance, crafting or economy implementation.
- No armor/headset/face/holster/secondary-weapon gameplay categories unless they already exist canonically; authored UI slots without a canonical slot remain disabled and clearly unavailable.
- No profile-stash ↔ loadout transfer in this change. The current stash and loadout are owned by separate `InventoryAuthority` instances; adding a truthful atomic cross-authority transfer requires a separate persistence/identity design instead of a UI shortcut.
- No replacement inventory screen and no direct UI mutation of native inventory state.

## Compatibility

The local save format is unchanged. Existing loadout/stash persistence records remain valid. Starter equipment remains only new-campaign content; the UI does not seed, repair or fabricate equipment. Existing raid settlement rules and equipment/ability reconciliation remain unchanged.

## Acceptance summary

A production test must open an existing local campaign, show the exact canonical primary/melee equipment, unequip and re-equip through real UI input, reject an incompatible slot without mutation, persist the result, relaunch, deploy, and prove the raid receives the same confirmed equipment. Removing an item or changing ammunition must never leave the UI showing the old fixture value. Exact 1920x1080 native captures must contain no fixture gear identities in live mode.
