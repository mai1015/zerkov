# Tasks

Status: explicitly approved September 17, 2026; E1-E6 implemented and native functional verification passed. E7 visual acceptance remains separate and open. No performance, multiplayer, unsupported gear categories, or stash-transfer work is included.

## Observed verification

Commit `251bb8c6a03d5e3eb7125e2cd6706fde3ae1f610`, Equipment UI run [35254649172](https://github.com/mai1015/zerkov/actions/runs/35254649172), artifact `equipment-headless` (`10512103830`), locked Godot `4.7.2.stable.official.ed1daf0bf` on macOS:

- Equipment/strict-command contracts: 128 checks, 0 failures.
- Equipped-item reconciliation: 123 checks, 0 failures.
- Real inventory/gameplay-ability reconciliation: 562 checks, 0 failures.
- Character UI binding: 65 checks, 0 failures, 1920x1080 logical canvas.
- Separate-process application flow: create 102/0, resume 80/0, deploy 99/0, cleanup 5/0; `EQUIPMENT_RUNNER_COMPLETE` present.
- The create flow exercised real mouse and keyboard input, equipment drag/drop, and secure-container movement. Resume/deploy verified persisted item identity and profile fingerprints; deployed input verified firearm ability revoke/regrant without duplicates.
- Eight Python runner regression tests passed locally, including real subprocess timeout output and original-failure precedence over cleanup errors.

The same run's **footage job failed** because the macOS usable desktop clamped the native window to 1920x971. Its AVI is not accepted visual evidence. The capture-host correction selects a mode by usable desktop area; the exact native-window/viewport/image guard remains mandatory. The full equipment flow and local-flow checks are being rerun after bringing main's newly merged validation tooling into this branch. Final run/capture evidence belongs in PR #28; no human visual approval or rendered FPS result is claimed here.

## Implementation

- [x] E1 `[SOL]` Add canonical equipment-slot projection and secure-container projection to the existing inventory presentation seam. **Evidence:** headless/native projection contract covering occupied/empty primary, melee, rig, backpack slots; immutable detached records; secure-container contents; owner replacement invalidation.

- [x] E2 `[SOL]` Extend `InventoryIntentAdapter` with strict same-inventory equip/unequip intents. Resolve destination slot identifiers against the authoritative equipment container/catalog instead of `ZIdentityRules.is_valid_part()`. **Evidence:** accepted equip/unequip, incompatible/unknown slot, stale generation/revision, duplicate request, occupied destination, teardown and no-mutation rejection contracts.

- [x] E3 `[LUNA]` Extend the existing inventory presentation seam with equipment/secure sources and UI command receipts while keeping profile stash read-only. Implemented in the `InventoryEquipmentController` subclass of `InventoryPresentationController`. **Evidence:** controller contracts proving confirmed-only updates, pending/rejection rollback, source availability, and no cross-authority stash mutation.

- [x] E4 `[LUNA]` Bind the existing Character Gear column to the live equipment projection. Remove fixture AKM/shotgun/M1911/machete identities and fixture ammunition from production live mode; map primary/melee to Sling/Leg Strap and mark unsupported authored slots unavailable. **Evidence:** exact-1920x1080 screen contract and real application label assertions with fixture state not rendered in live mode. Native visual acceptance remains E7.

- [x] E5 `[SOL]` Verify accepted equipment mutations still drive the existing equipped-item and ability reconciliation exactly once. **Evidence:** integration contract covering equip, unequip, repeated identical projection, item destruction/owner replacement, weapon mapping and ability grant/revoke without duplication; additional normal deployed Character-screen input checks.

- [x] E6 `[SOL]` Verify local persistence and deployment consistency. Home equipment changes must serialize through the existing `ProfileStore`; relaunch must reproduce the same equipment; deployment must instantiate the same canonical loadout with no starter reseed/fallback. **Evidence:** isolated-file native flow with three fresh processes, exact profile fingerprints, restart, and raid equipment snapshot comparison.

- [ ] E7 `[ASTRA]` Review the exact 1920x1080 production Character screen after live equipment binding. **Evidence:** native capture demonstrating correct live item names/status, empty/unsupported slot treatment, secure-container legibility, and no fixture gear identities. Human visual approval remains a separate acceptance checkbox.
