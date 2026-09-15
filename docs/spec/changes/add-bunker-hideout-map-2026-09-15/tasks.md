# Tasks

- [x] Inspect kit guides, hashes, anchors and placement metadata.
- [x] Author the six-area cutaway and native-pixel sprite placement.
- [x] Add room inspection and consequence-neutral lighting controls.
- [x] Add source/layout contracts and the existing screen integration wrapper.
- [x] Verify native renderer, actual mouse input, exact output and repeatability.
- [x] Review captured native screenshots and retain evidence in the PR.
- [ ] User visual acceptance and full six-add-on host regression.

Native evidence: `docs/qa/bunker_hideout/VALIDATION.md` and `capture.json`.
Two graphical Godot processes passed 34 assertions each. Both 1920x1080
lighting captures matched byte-for-byte; nine Python layout tests passed.
Two known Xvfb V-Sync notices are disclosed, with no unexpected diagnostics.
The raw captures were downloaded, hash-verified and visually inspected.
The final item is not inferred from isolated presentation testing.
