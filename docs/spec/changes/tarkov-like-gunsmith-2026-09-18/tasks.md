# Tasks — Tarkov-like Gunsmith

Stage 1 only. Implementation tasks remain unchecked until this proposal is explicitly approved.

- [x] G0 [SOL] Audit `zerkov.zip`: establish source hash, firearm-family count, layer dimensions, attachment counts/categories, small/large split, and forbidden-source exclusions. Evidence: `asset-audit.md`.
- [ ] G1 [SOL] Add sealed weapon-platform and weapon-part authoring resources/catalog with deterministic fingerprints and negative validation tests. Evidence: catalog contract covering all 32 firearm families and 62 attachments.
- [ ] G2 [SOL] Extend Inventory catalog so customizable firearm items provide a bounded weapon-parts child container and accept a canonical `weapon_build.v1` mutable component. Evidence: subtree transfer, mass, persistence, malformed-component and orphan-child contracts.
- [ ] G3 [SOL] Implement game-owned `WeaponBuildAuthority` read model plus compatibility/preflight APIs. No mutation yet. Evidence: deterministic build snapshots, compatibility reasons, bounds and replay-safe command identity tests.
- [ ] G4 [SOL] Implement atomic install/remove/swap coordination across InventoryAuthority, the weapon-build component, and WeaponAuthority. Evidence: success, stale revision, missing item, incompatible part, exact replay, payload-conflict and failure-atomic tests.
- [ ] G5 [SOL] Extend native Weapon System slot vocabulary additively for Barrel and Laser while preserving the flat <=8 slot model and fail-closed protocol/catalog compatibility. Evidence: native core, Godot façade, protocol, snapshot/delta and network conformance suites.
- [ ] G6 [SOL] Author first complete functional build set for the current AKM platform using optic/muzzle/stock/grip/barrel/laser categories and verify native modifier agreement. Evidence: differential stat and firing/reload contracts.
- [ ] G7 [SOL] Import and seal the remaining 31 firearm family definitions and 62 part-art records without inventing real-world names. Author explicit compatibility metadata. Evidence: full source manifest and deterministic catalog fingerprint.
- [ ] G8 [ASTRA] Build the Zerkov Gunsmith workspace: preview, slot tree, owned/compatible part list, concrete incompatibility reasons, stat delta, Apply/Revert. Evidence: 1920x1080 native interaction contract using actual Inventory/Build snapshots.
- [ ] G9 [SOL] Add local definition-level presets with Save/Load/Delete and atomic Apply using owned item resolution. Evidence: missing-part no-mutation, deterministic resolution, relaunch persistence and preset schema tests.
- [ ] G10 [SOL] Add build reconciliation on weapon transfer, save restore, equip/unequip, and deployment. Evidence: weapon plus installed subtree keeps exact item IDs and accepted build across fresh processes.
- [ ] G11 [ASTRA] Add editor-authored preview mount transforms for the source-pack families and attachments. Evidence: family contact sheets and native preview captures; no runtime filename guessing.
- [ ] G12 [SOL] Add raid pose-profile gating and migrate the corrected AKM presentation to build-driven muzzle/part anchors. Unsupported platforms must reject deployment explicitly. Evidence: no fake AKM arms on unapproved platforms.
- [ ] G13 [SOL] Run full equipment/combat/local-save/extraction regression plus new gunsmith suites. Record exact head, source hashes, native counts, and known visual limitations.
- [ ] Human approval of Gunsmith UX, compatibility behavior, and the first expanded weapon set before broad raid-pose authoring.
