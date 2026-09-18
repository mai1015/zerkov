# Tasks

Approved scope: the user's explicit follow-up to PR #28; performance and multiplayer are unchanged.

- [x] G1 [SOL] Trace input, inventory-to-weapon identity, authoritative shooting and world presentation. The baseline body-only LocalActorPresenter ignored frame.weapon; shot feedback lacked resolved geometry. See verification.md.
- [x] G2 [SOL] Connect the held AKM/machete/empty-hands state and confirmed shot presentation. Native detached presentation contract: 43 checks, zero failures, including dead/stale/duplicate/rejected cases.
- [x] G3 [SOL] Exercise the normal saved campaign, deployment, reload/fire, actual enemy damage and inventory unequip/re-equip. Native Linux deployed flow: 631/0; same persisted weapon preserves ammunition. Full local regression: 4270/0.
- [x] G4 [ASTRA] Record and inspect actual 1920x1080 gameplay. macOS CI deploy: 648/0; Linux deploy with eleven guarded PNG writes: 659/0. Original weapon attachment, firing, machete, empty hands and real-hit frames inspected.
- [ ] Human visual/game-feel acceptance. Existing upright body art and canonical top-down hitboxes are not fully aligned; bespoke directional weapon animations and fresh-player aiming acceptance are not claimed. The current integration is functional evidence, not final combat-art approval.

Exact runtime source, native artifact provenance, counts, registration correction and remaining limits are recorded in verification.md. PR #43 stays draft for visual acceptance.
