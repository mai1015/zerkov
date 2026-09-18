# Tasks

Status: explicitly approved September 17, 2026; E1-E6 implemented and verified on the current merged UI revision. E7 human visual acceptance remains separate and open. No performance, multiplayer, unsupported gear categories, or stash-transfer work is included.

## Final observed verification

Commit `18b1914b6d45189d4168f6d07ff64fe0995703b3`, Equipment UI run [35296934870](https://github.com/mai1015/zerkov/actions/runs/35296934870), locked Godot `4.7.2.stable.official.ed1daf0bf` on macOS:

- Equipment/strict-command contracts: **201 checks, 0 failures**.
- Equipped-item reconciliation: **123 checks, 0 failures**.
- Real inventory/gameplay-ability reconciliation: **562 checks, 0 failures**.
- Character UI binding: **65 checks, 0 failures**, exact 1920x1080 logical canvas.
- Separate-process headless application flow: create **100/0**, resume **76/0**, deploy **99/0**, cleanup **5/0**; `EQUIPMENT_RUNNER_COMPLETE` present.
- Native fullscreen 1920x1080 recording flow: create **113/0**, resume **82/0**, deploy **106/0**, cleanup **5/0**; all three movies completed and `EQUIPMENT_RUNNER_COMPLETE` is present.
- The native create flow exercised real mouse/keyboard activation, equipment drag/drop, secure-container movement and confirmed canonical AKM/machete state.
- The resume flow verified an intentionally empty primary slot survives a fresh process, then re-equips the same item identity; incompatible equipment is rejected without mutation.
- The deploy flow opened the current Bunker briefing, deployed the persisted item, opened the raid Character UI, unequipped/re-equipped the same primary, and verified firearm equipment ability revoke/regrant without duplication.
- The equipment headless job also ran the unchanged full local extraction/death/save-retry/recovery driver: **4,241 checks, 0 failures**, plus two fresh-process profile reads (**3/0** each) and cleanup (**5/0**).
- Exact recording surface remained physical/logical/viewport **1920x1080**. Movie mode is visual evidence only, not an FPS result.

Artifacts:
- `equipment-headless` — artifact **10528675338**.
- `equipment-footage` — artifact **10528214480**.

The final native capture demonstrates the implementation evidence required by E7. E7 remains unchecked because the task explicitly requires **human visual approval**, which has not been supplied yet.

## Implementation

- [x] E1 `[SOL]` Add canonical equipment-slot projection and secure-container projection to the existing inventory presentation seam. **Evidence:** headless/native projection contract covering occupied/empty primary, melee, rig, backpack slots; immutable detached records; secure-container contents; owner replacement invalidation.

- [x] E2 `[SOL]` Extend `InventoryIntentAdapter` with strict same-inventory equip/unequip intents. Resolve destination slot identifiers against the authoritative equipment container/catalog instead of `ZIdentityRules.is_valid_part()`. **Evidence:** accepted equip/unequip, incompatible/unknown slot, stale generation/revision, duplicate request, occupied destination, teardown and no-mutation rejection contracts.

- [x] E3 `[LUNA]` Extend the existing inventory presentation seam with equipment/secure sources and UI command receipts while keeping profile stash read-only. Implemented in the `InventoryEquipmentController` subclass of `InventoryPresentationController`. **Evidence:** controller contracts proving confirmed-only updates, pending/rejection rollback, source availability, and no cross-authority stash mutation.

- [x] E4 `[LUNA]` Bind the existing Character Gear column to the live equipment projection. Remove fixture AKM/shotgun/M1911/machete identities and fixture ammunition from production live mode; map primary/melee to Sling/Leg Strap and mark unsupported authored slots unavailable. **Evidence:** exact-1920x1080 screen contract and real application label assertions with fixture state not rendered in live mode. Final native capture is available for E7 review.

- [x] E5 `[SOL]` Verify accepted equipment mutations still drive the existing equipped-item and ability reconciliation exactly once. **Evidence:** integration contract covering equip, unequip, repeated identical projection, item destruction/owner replacement, weapon mapping and ability grant/revoke without duplication; additional normal deployed Character-screen input checks.

- [x] E6 `[SOL]` Verify local persistence and deployment consistency. Home equipment changes must serialize through the existing `ProfileStore`; relaunch must reproduce the same equipment; deployment must instantiate the same canonical loadout with no starter reseed/fallback. **Evidence:** isolated-file native flow with three fresh processes, exact profile fingerprints, restart, and raid equipment snapshot comparison.

- [ ] E7 `[ASTRA]` Review the exact 1920x1080 production Character screen after live equipment binding. **Evidence:** native capture demonstrates correct live item names/status, empty/unsupported slot treatment, secure-container legibility, and no fixture gear identities. **Human visual approval remains the final checkbox.**
