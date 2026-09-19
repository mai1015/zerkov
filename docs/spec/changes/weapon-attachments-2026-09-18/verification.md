# Option A knife and gun-local muzzle verification

## Source and approval

This correction is based on PR #43 head `d66122b31c00cb5e6a8fc6176c9a3fe73a5eba91`, tree `c3da7496eb2158001cb058a6c96cba364413565b`. The original tree was reconstructed and verified locally before editing. The user explicitly selected Option A after requesting both attachment fixes.

The supplied archive has layered PNG animation sheets, not a supplied skeletal character rig. Its extension inventory and knife geometry are recorded in archive-audit.json. No separate bone, joint, skin-weight or skeletal-rig file was found. The current character uses Sprite2D layers, not Skeleton2D/Bone2D. No skeletal or IK system is introduced.

The new original source is `Main character/Animations/Knife Attack/knife-attack-knife.png`: 563 bytes, SHA-256 `daf7af354ff1cb912792764e436f6e5e02927912b7abfa34582381a3540bc602`. It is copied byte-exactly from zerkov.zip, not repainted or resized. The source verifier now covers 30 original images; provenance restrictions remain unchanged.

## Corrections

The source muzzle animation is now a child of the visible gun. The emitter inherits its current movement, orientation, scale and reflection, rather than remaining at the shot-time world position. Its source frame still requires a committed shot and expires on the existing tick schedule. Melee, reload, missing gear, death and release hide the muzzle. Impact/blood rendering stays at the unchanged authoritative world endpoint. No procedural tracer, additional raycast, ammo mutation or damage rule is added.

Option A uses the six full 64x64 cells from the original knife strip. The blade and matching arm/body layers share the same canonical frame, native scale, (32,48) pivot and left/right reflection. The old inventory-blade scale, approximate grip offsets and independent aim rotation do not apply to an attack-strip frame. All twelve frame/direction combinations were inspected in native gameplay captures.

This is the user's approved visual substitution: the inventory identity and melee mechanics remain the existing machete, while the attack uses the supplied knife silhouette and trail. Idle still shows the original machete. It is not a new knife gameplay item or a bespoke machete animation.

## Executed validation

Locked Godot `4.7.2.stable.official.ed1daf0bf`, existing verified native libraries, outside runtime copy:

| Contract | Checks / failures |
| --- | ---: |
| Equipment commands/projection | 201 / 0 |
| Weapon presentation, attachment and lifecycle | 243 / 0 |
| Native combat execution | 439 / 0 |
| Equipped-item reconciliation | 123 / 0 |
| Inventory to gameplay abilities | 562 / 0 |
| Authored Character UI binding | 65 / 0 |
| Independent headless create / resume / deployed gameplay | 100 / 0; 76 / 0; 779 / 0 |
| Independent graphical create / resume / deployed gameplay | 113 / 0; 81 / 0; 835 / 0 |
| Full extraction/death/save-retry regression | 4270 / 0 |
| Two independent saved-profile reads | 3 / 0; 3 / 0 |

Both runner invocations and cleanup finished successfully. Tooling: 249 tests passed. Original-byte verification, Python compilation, exact-1080 gate and whitespace checks passed. Counts include repeated per-tick/capture assertions, not independent scenarios.

The actual-input driver moves and turns the player during an existing muzzle effect, then performs one right and one left melee gesture and captures each of their six source frames. Tests compare the real arm/knife transforms and atlas regions; a separate native contract also uses a translated/rotated/scaled parent. Impacts and shot identity stay unchanged during attachment motion.

The same campaign sequence verifies dry-fire/reload rejection, 30 to 29 ammunition, unequip and re-equip without refill, empty hands, and real enemy damage from 440 to 398. This expanded sequence records seven committed player shots with 23 rounds remaining. It uses existing white-box route/head-hitbox guidance, not teleports, injected damage or unguided aiming acceptance.

The full-flow saved fingerprint is `3d4450762bae29d111692a1865f1c3659272cecdfdcaad79aec2f9563bcf756a` in both independent verification processes.

## Visual evidence and boundaries

27 raw 1920x1080 captures passed the existing physical-window/viewport/texture/readback guard. The deployment movie contains 1748 frames at fixed 15 FPS, lasting 116.533 seconds. It deliberately pauses at source frames for inspection and is not a frame-rate or game-speed measurement. The H.264 review copy preserves the frame count, dimensions and timing; dummy audio is omitted. Enlarged contact sheets are labelled inspection crops, not raw output.

Linux evidence uses hash-verified existing libraries staged outside the source checkout, explicit extension startup for the documented engine cold-discovery issue, and the equipment runner's existing temporary dashboard-disabled import policy. Shipping project configuration is restored before gameplay. This is not an ordinary editor cold-import fix or addon/engine promotion. The earlier eager editor-dashboard import blocker is not claimed resolved; final-head CI is reported separately on the PR.

Performance, multiplayer, authoritative hit geometry, balance, save format and audio are unchanged. The broader upright-sprite versus ground-plane hitbox alignment remains separate. Human visual/game-feel acceptance is still open.
