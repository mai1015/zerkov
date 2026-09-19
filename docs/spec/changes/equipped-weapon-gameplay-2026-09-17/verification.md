# Equipped weapon gameplay verification

## Source and ownership

Runtime-validated head: `e1a5ddd6c22956605ddfe6b8c974c61b56dc0404`.
Runtime tree: `b5a3a66541203cfc973768e1abfd14a3bd0a4ca3`.
Base: main `1b1c53fd14102991ea8364014a609eb93a501218`, including the merged equipment, contextual-loot and static-geometry work. This PR adds no performance work.

The interruption left a Git tree without a branch commit. It was recovered as the runtime head above. Downloaded source artifact 10562251435 (Offline journey run 35382162715) has SHA-256 `0ad4962553ec2bba63cfd976c50aa50dc62bcc86ecbf5d170a81d51cb7d56d43`; reconstructed bytes and modes produce the exact runtime tree. Subsequent changes are registration/tests and this verification record, not runtime code.

The baseline LocalActorPresenter displayed body layers but did not consume equipped weapon state. Existing combat authority already owned mechanical firing, inventory reloads and target damage. This change connects the world presentation and proves those mechanics through the same saved equipment identity; it does not replace the combat simulation.

WeaponCombatAdapter exposes a read-only sidecar from the already-resolved shot. Its original consequence and digest remain unchanged. RaidCombatExecution publishes that geometry after resolution; LocalWeaponPresenter only draws it. There is no second raycast, sprite-driven damage, animation-driven ammunition change or input authorization in the presenter.

## Actual player-input sequence

The test opens the production campaign, creates/saves modified equipment, resumes in a separate process, equips the saved AKM and deploys. It then exercises:

1. The same mapped AKM appears on the world actor; its initially empty magazine rejects firing without a muzzle effect.
2. R starts the real inventory-backed reload. Firing during reload remains rejected; completion loads 30 rounds from the carried reserve.
3. A normal mouse shot changes 30 to 29 and produces one committed muzzle/trace effect. Early cadence rejection consumes no additional round and adds no successful effect.
4. The actual Character control unequips the AKM. After canonical reconciliation, the firearm disappears, the equipped machete is held, and firing cannot consume the parked AKM's 29 rounds.
5. V starts the authoritative melee timeline. Unequipping the machete as well leaves genuinely empty hands.
6. Re-equipping the same persisted AKM restores the same mapped weapon with 29 rounds, not a reseeded/full magazine.
7. Normal navigation and ordinary mouse fire reach a real enemy. One confirmed player consequence changes the mutant's summed native health from 440000000 to 398000000 micros (440 to 398). The run ends with 15 committed player shots and 15 loaded rounds remaining.

The encounter uses white-box navigation/head-hitbox aim guidance from the existing local-flow driver. It does not teleport, inject damage, refill ammunition, seed target outcomes or fabricate successful feedback. Native authority decides every hit. This proves execution and presentation integration, not unguided player aiming usability.

## Native results

Pinned Godot: `4.7.2.stable.official.ed1daf0bf`.

| Contract | Checks / failures |
| --- | ---: |
| Equipment commands/projection | 201 / 0 |
| Detached weapon presentation and lifecycle | 43 / 0 |
| Native combat execution | 439 / 0 |
| Equipped-item reconciliation | 123 / 0 |
| Inventory to gameplay abilities | 562 / 0 |
| Authored Character UI binding | 65 / 0 |
| Linux headless new campaign / independent resume | 100 / 0; 76 / 0 |
| Linux headless deployment plus gameplay | 631 / 0 |
| Linux full extraction/death/save-retry regression | 4270 / 0 |
| Full-flow profile checks in two independent processes | 3 / 0; 3 / 0 |
| macOS native movie create / resume / deploy | 113 / 0; 81 / 0; 648 / 0 |
| Linux native movie create / resume / deploy with raw stills | 113 / 0; 81 / 0; 659 / 0 |

Counts contain repeated tick/state assertions, not that many independent scenarios. Cleanup completed; both local runners ended with EQUIPMENT_RUNNER_COMPLETE and exit zero. The eleven extra Linux graphical checks are the eleven guarded PNG writes, not additional gameplay scenarios.

macOS Equipment UI run: https://github.com/mai1015/zerkov/actions/runs/35382162675 . Its inspected footage artifact 10563062954 identifies the runtime head above and has SHA-256 `928339bb2f7007fa34a4d0033f52fb788b88b80a7e5309dd9a2ff1ca34d01625`. All three AVI recordings are 1920x1080 at a fixed QA rate of 15 FPS. The deployed movie is 1192 frames. Movie timing includes deliberate test pauses and is not a frame-rate benchmark.

## Tooling registration correction

The recovered runtime head's pre-multiplayer workflow failed three tooling assertions: the new headless/writer counts were not updated, and the manifest used Control instead of the unchanged source's CanvasItem texture-filter anchor. The follow-up restores the actual anchor, registers counts 64 and 18, and explicitly requires the new weapon-presentation contract. No capture guard or runtime test is weakened.

With those corrections, all 245 tooling tests pass, including the 23 exact-output scope tests. Python compilation, the repository exact-1080 gate and whitespace checks pass. Final-head CI must be read separately; these results do not label queued or unrelated jobs successful.

## Linux provenance and qualification

The uploaded Linux engine SHA-256 is `8d106cbe6144c2dc7e881d61d2429c1a8a76e6b22ef48bd5e48dcf934953f71e`. Native libraries come from existing artifact 10513198359, run 35256404225, source a609daff28673451668026e0b992c37f52923440. Its ZIP SHA-256 is `2c1ae287d39f022fe7ec10a0cbc2af42d60344dacdace12a7927b8142804c21e`; all twelve native library sizes and hashes match the supplied manifest.

Libraries are staged in an outside runtime. Import uses explicit extension startup registration for the already-documented pinned-engine cold-discovery defect. Graphical runs use Xvfb/Mesa and the unchanged physical-window/viewport/texture/readback 1080 guard. This is not a cold-import fix, addon promotion, exported-platform test or hardware FPS qualification. Neither binaries nor font files are part of the evidence delivery.

## Visual review and remaining limits

Actual raw frames were inspected for attached AKM and muzzle flash, reload, machete-only state, empty hands, restored weapon and the real damaging shot. HUD primary/melee icons follow canonical gear, unsupported secondary art stays hidden, and the crosshair's rendered center follows the gameplay pointer.

Weapon art reuses shipped item images with explicit attachment anchors and cosmetic rotation. It is not bespoke directional body/weapon animation. The existing upright body sprite, ground-based shot origin and top-down body-zone layout are not fully aligned: the visible muzzle/trace/impact can disagree with the apparent body height and aiming point. The test's canonical head guidance does not resolve that visual/game-feel issue. Do not represent this as final hitbox-to-sprite or fresh-player combat acceptance. No new weapon audio is claimed; QA uses the dummy audio driver.

Human visual/game-feel acceptance remains open. Performance, multiplayer, new weapon balance, save format changes, unsupported equipment slots and new weapon-selection/automatic-fire rules remain outside this change.
