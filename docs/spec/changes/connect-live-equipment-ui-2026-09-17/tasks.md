# Tasks

Status: proposed; no implementation task may start before explicit approval.

- [ ] E1 `[SOL]` Add canonical equipment-slot projection and secure-container projection to the existing inventory presentation seam. **Evidence:** headless/native projection contract covering occupied/empty primary, melee, rig, backpack slots; immutable detached records; secure-container contents; owner replacement invalidation.

- [ ] E2 `[SOL]` Extend `InventoryIntentAdapter` with strict same-inventory equip/unequip intents. Resolve destination slot identifiers against the authoritative equipment container/catalog instead of `ZIdentityRules.is_valid_part()`. **Evidence:** accepted equip/unequip, incompatible/unknown slot, stale generation/revision, duplicate request, occupied destination, teardown and no-mutation rejection contracts.

- [ ] E3 `[LUNA]` Extend `InventoryPresentationController` with equipment/secure sources and UI command receipts while keeping profile stash read-only. **Evidence:** controller contracts proving confirmed-only updates, pending/rejection rollback, source availability, and no cross-authority stash mutation.

- [ ] E4 `[LUNA]` Bind the existing Character Gear column to the live equipment projection. Remove fixture AKM/shotgun/M1911/machete identities and fixture ammunition from production live mode; map primary/melee to Sling/Leg Strap and mark unsupported authored slots unavailable. **Evidence:** exact-1920x1080 screen contract and capture with fixture state byte-unchanged but not rendered in live mode.

- [ ] E5 `[SOL]` Verify accepted equipment mutations still drive the existing equipped-item and ability reconciliation exactly once. **Evidence:** integration contract covering equip, unequip, repeated identical projection, item destruction/owner replacement, weapon mapping and ability grant/revoke without duplication.

- [ ] E6 `[SOL]` Verify local persistence and deployment consistency. Home equipment changes must serialize through the existing `ProfileStore`; relaunch must reproduce the same equipment; deployment must instantiate the same canonical loadout with no starter reseed/fallback. **Evidence:** isolated-file native flow with restart and raid equipment snapshot comparison.

- [ ] E7 `[ASTRA]` Review the exact 1920x1080 production Character screen after live equipment binding. **Evidence:** native capture demonstrating correct live item names/status, empty/unsupported slot treatment, secure-container legibility, and no fixture gear identities. Human visual approval remains a separate acceptance checkbox.
