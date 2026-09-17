# Tasks

- [x] L1: Copy Blackwater resources; authored live anchors and exact scene preflight.
- [x] L2: Bind production movement/navigation/vision/combat and map-scoped task facts.
- [x] L3: Pin map identity in local deployment/settlement, preserve old saves/retries.
- [x] L4: Select maps in current briefing; normal input/HUD/local flow, no walker.
- [x] L5: Native tests for both maps/default Sawmill, save recovery, and captures.
- [x] L6: Publish the actual implementation and exact local native evidence.

L1–L5 evidence: `docs/qa/live_maps/VALIDATION.md` and `RESULTS.json`.
The exact 39-file candidate was published as ordinary source in commit
`a7d634b2be1e0c4348ce7acdd383d17d8e523831`. No addon, image, font, engine lock,
product main scene or save backend changed. The following commit only installs
read-only verification, removes the temporary transfer workflow and records status.

## Separate acceptance gates

- [ ] Current-head hosted native CI completed and reviewed.
- [ ] Human/controller playtest and population/loot balance acceptance.
- [ ] Target-hardware real-time frame budgets and exported-platform qualification.

Functional automation explicitly paces the canonical tick. Passing extraction,
death and restart tests does not establish 60/120 displayed FPS or release readiness.
The original full-map review exit markers are not all active; each live mission
currently has three caches, one exit, one scav and one mutant.
