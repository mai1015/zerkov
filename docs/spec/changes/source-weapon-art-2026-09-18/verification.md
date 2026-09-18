# Original weapon/arms/VFX integration — verification

## Exact input and boundary

This is the user's requested correction to PR #43, based on `df7321a75179a7346624038af3c1facfcafeca48` (tree `0fd6ff84b330fd7f77b63f5d2a0472fe6308c1ce`). The old handoff inventory-image weapon layer was provisional and did not use the archive's holding poses or VFX.

Uploaded `zerkov.zip` SHA-256: `ae2296dd78ba7310a512a2d3a9a575884dadefaf54eac8f9b3d535b31551b006`. The selected manifest seals **29 original PNGs / 13495 bytes**: 17 weapon/FX sources and twelve already-present body/arm sheets. Sixteen PNGs are newly added; the actual machete and main character layers were already present. Original PNG bytes are copied without resizing, painting, recompression or repacking. Godot AtlasTexture/SpriteFrames resources describe cells and pivots. Forbidden DO NOT USE folders are excluded. Existing distribution/provenance restrictions are not changed into release clearance.

## Implemented source-art use

- AKM: `ally/arms+ak.png` (22×8) contains the actual firearm plus both holding arms. The old body-arm layer is suppressed only while that composite pose is active. Left/right mirroring respects the source's left-facing art; shoulder/grip/muzzle offsets live in an editable resource.
- Machete: `Weapons Inventory/Melee/Weapons_inventory_MACHETTE.png`, using its native region rather than the handoff icon. Six source knife-attack body/arm frames are sampled from the committed melee windup/active/recovery windows. The blade is the actual machete, not a knife substituted for it. No dedicated machete animation or authored reload strip is claimed.
- Muzzle: the seven 28×20 frames of `fx/ak-47 mozzle flash.png`, attached to the shot-time barrel.
- Impact: eight-cell concrete, wood, metal, red-brick and dirt strips, plus nine original blood particle textures. Blood requires confirmed damage; material impacts require a committed obstruction and an explicit visual surface mapping. Unknown surfaces and clear misses do not invent impacts.

Other NPC holding sprites and weapon inventory variants were identified but are not new supported weapon mechanics. This correction enables no pistol/shotgun/extra slot, automatic fire, save migration, audio or multiplayer.

The generic layered presenter accepts a presentation-only source mask. LocalActorPresenter owns weapon/arms composition. The combat adapter adds only the already-resolved obstruction identifier to its existing presentation sidecar; its authoritative result/digest is unchanged. There is no second ray query, visual-driven damage, animation callback or ammo mutation. Sawmill visual surfaces are associated with existing obstruction identities; native Northline/Blackwater currently leave unmapped surface types unknown rather than guessing. Muzzle and confirmed blood feedback remain available on those maps.

## Executed tests

Locked Linux Godot `4.7.2.stable.official.ed1daf0bf`, existing hash-verified native libraries, outside runtime copy. All changed gameplay, art and equipment-driver bytes match the tested copy. The read-only verifier passes all 29 original sources before native import.

| Contract | Checks / failures |
| --- | ---: |
| Equipment commands/projection | 201 / 0 |
| Source weapon/arm/FX presentation and lifecycle | 129 / 0 |
| Native combat execution | 439 / 0 |
| Equipped-item reconciliation | 123 / 0 |
| Native inventory ↔ gameplay abilities | 562 / 0 |
| Authored Character UI | 65 / 0 |
| Independent headless create / resume / gameplay deploy | 100 / 0; 76 / 0; 664 / 0 |
| Full local extraction/death/save-retry regression | 4270 / 0 |
| Independent saved-profile checks | 3 / 0; 3 / 0 |
| Graphical create / resume / gameplay deploy | 113 / 0; 81 / 0; 698 / 0 |

Both full runner invocations exit zero with `EQUIPMENT_RUNNER_COMPLETE`; cleanup passes. Counts include repeated per-tick checks. The graphical deployment includes fourteen successful raw PNG writes plus physical-stage guards; those are not fourteen independent combat scenarios.

The real input sequence still proves empty-magazine rejection, actual carried-ammo reload to 30, fire to 29, cadence rejection, unequip-to-machete, melee, empty hands and re-equipping the same item with 29 rounds. During ordinary traversal/fire the mutant's native summed health changes **440 → 398**. With the additional pose/FX probes, this run records **10 committed player shots and 20 loaded rounds remaining**; old 15/15 counts do not apply. Navigation and canonical head-hitbox guidance are white-box assistance, not teleports, injected damage or unguided aim acceptance.

The full-cycle saved fingerprint is `3d4450762bae29d111692a1865f1c3659272cecdfdcaad79aec2f9563bcf756a` and matches both independent verification processes. Tooling: **249 tests passed**, Python compilation, exact-1080 repository gate and whitespace checks passed. The source verifier has negative controls for altered bytes, dimensions, paths, duplicates and provenance.

## Graphical review and qualification

Fourteen native 1920×1080 screenshots and new/resume/deploy AVI recordings were produced with Xvfb/Mesa software rendering. Reviewed frames include original holding arms facing left/right, source muzzle flash, source melee body/arms with the actual blade, empty hands and confirmed enemy damage/blood. Screenshots are raw renderer output, not generated artwork or resized substitutes. The deployment movie has 1291 frames at fixed **15 FPS** (86.067 seconds); deliberate pauses are QA evidence, not a performance result.

The outside Linux import uses explicit extension startup registration for the already-documented pinned-engine cold-discovery defect. The physical-window/viewport/texture/readback 1080 guard is unchanged. No native binaries, engine/addon lock, performance scheduler, map geometry or gameplay tuning are changed. No fonts or native libraries are included in the conversation evidence packet.

Remaining limits: the existing upright body imagery still does not fully coincide with the ground-plane/top-down body-zone collision layout. This correction fixes holding art, source frame synchronization and source VFX, not that geometric/aiming design issue. The reload uses the source holding pose with a cosmetic tilt/progress bar, not a nonexistent dedicated reload animation. Full exported-platform, controller/unguided-player and target-hardware FPS qualification remain separate. Human approval is open; final-head GitHub CI status must be checked rather than inferred from these local runs.
