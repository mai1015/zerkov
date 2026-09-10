---
created_at: 2026-09-09T23:45:13Z
updated_at: 2026-09-10T03:06:43Z
completed_at:
---

# Tasks by Aspect

## Model lanes

- `[LUNA]`: `gpt-5.6-luna`, normally `max`. Use for bounded implementation,
  data authoring, fixtures, mechanical refactors and deterministic tests.
- `[SOL]`: `gpt-5.6-sol`, normally `high`; use `max` for authority, security,
  persistence recovery, protocol and networking work.
- `[ASTRA]`: `gpt-6-astra`, normally `high`; use `max` for architecture gates,
  UI/UX, level composition, combat feel and final cross-system review.
- `[PLAYTEST]`: human play and product judgment. A model may prepare the build,
  capture evidence and analyze feedback but cannot replace this gate.

Model choice never weakens the task's evidence requirements. Read
`model-routing.md` before dispatching work.

## Completion contract

A task is complete only when its scoped implementation, relevant automated
checks, diagnostics review and named evidence are complete. Runtime errors count
as failures even when a process exits successfully. Do not check a parent item
while any required child behavior remains incomplete.

## 0. Proposal and approval

- [x] 0.1 `[ASTRA]` Inventory the current UI, add-on capabilities, release
  status and source-art families.
- [x] 0.2 `[ASTRA]` Author the proposal, architecture, capability deltas,
  aspect task ledger, workstream order and model-routing guidance.
- [x] 0.3 `[PLAYTEST]` Review the first-playable boundary and explicitly
  approve Stage 2 implementation.
- [x] 0.4 `[ASTRA]` Resolve or record the four open product decisions in
  `design.md` without expanding the first playable.

Evidence: strict proposal validation passes and the user explicitly approves
the change.

## 1. Add-on packaging and platform baseline

- [x] 1.1 `[LUNA]` Create a machine-readable add-on lock manifest containing
  package name, version, API/protocol/schema versions, source revision, source
  path and SHA-256 for every copied native artifact.
- [x] 1.2 `[LUNA]` Add a deterministic vendor/update script that copies only
  the six distributable `addons/<name>/` directories and rejects an unlocked
  source or artifact mismatch.
- [x] 1.3 `[SOL]` Install the pinned add-ons together and enable only their
  documented plugins/autoloads; do not add game-owned state to an add-on.
- [x] 1.4 `[SOL]` Add one combined extension-load and version-negotiation smoke
  that fails clearly for a missing class, incompatible version or wrong binary.
- [x] 1.5 `[LUNA]` Pin the Godot editor/runtime and native toolchain versions in
  project documentation and developer commands.
- [x] 1.6 `[SOL]` Prove a debug Windows client artifact can build and load in a
  minimal exported Zerkov project, or record the exact reproducible blocker.
- [x] 1.7 `[SOL]` Prove a headless Linux server artifact can build and load, or
  record the exact reproducible blocker.
- [x] 1.8 `[LUNA]` Add license and third-party-notice aggregation for every
  shipped add-on and selected asset family.

  Public distribution remains blocked, by the aggregation gate itself, until
  Inventory System and Weapon System supply license grants and the project
  records provenance for the handoff/original art families. This does not
  block internal gameplay-slice development.

Evidence: macOS combined load smoke; Windows client and Linux server artifact
reports; lock-manifest checksum test; clean Godot import log.

## 2. Runtime foundation and raid authority

- [x] 2.1 `[LUNA]` Create typed product directories for bootstrap, content,
  domain ports, raid runtime, adapters, presentation and tests without moving
  existing UI files prematurely.
- [x] 2.2 `[SOL]` Define stable entity, inventory, weapon, task, request,
  consequence, raid and settlement identity types plus collision tests.
- [x] 2.3 `[SOL]` Implement `ZWorldUnits` as the sole checked conversion between
  Godot positions, tile/pixel coordinates and each add-on's fixed units.
- [x] 2.4 `[LUNA]` Implement a manually driven 60 Hz `RaidClock` with pause,
  step and bounded catch-up behavior; do not derive authority from frame delta.
- [x] 2.5 `[SOL]` Implement an offline `SessionCoordinator` that creates trusted
  session/actor/authority epochs through the same port future networking uses.
- [x] 2.6 `[SOL]` Implement the `RaidAuthority` lifecycle state machine:
  preparing, active, extracting, settling, completed, failed and torn down.
- [x] 2.7 `[SOL]` Add a bounded intent queue with source, session, actor, target
  tick, sequence and payload validation before domain dispatch.
- [x] 2.8 `[SOL]` Implement the documented per-tick domain order and reject
  reentrant or regressing mutations.
- [x] 2.9 `[LUNA]` Add a bounded ordered raid event journal for spawn, loot,
  fire, hit, injury, heal, kill, task, extraction, death and settlement events.
- [x] 2.10 `[SOL]` Add deterministic replay fixtures proving identical accepted
  inputs create identical domain digests and audit records.
- [x] 2.11 `[SOL]` Add teardown/generation handling so late signals, timers and
  deferred callbacks cannot mutate a replaced or completed raid.

Evidence: headless authority contract; tick-order fixture; identity collision
suite; replay digest; teardown/reentrancy regression tests.

## 3. World, level and player mechanics

- [ ] 3.1 `[ASTRA]` Build an isolated render-scale spike comparing candidate
  low-resolution world surfaces at 1920x1080, 1600x900 and 1280x720 while the
  existing UI remains crisp.
- [ ] 3.2 `[ASTRA]` Select and document the world surface, camera policy,
  pixel-snap rules and failure tolerances from native captures.
- [ ] 3.3 `[LUNA]` Create a 32 px Sawmill source TileSet with explicit terrain,
  navigation, collision and draw-layer metadata.
- [ ] 3.4 `[ASTRA]` Compose the Sawmill Yard greybox/readability layout with
  spawn, objective landmarks, combat lanes, cover, loot and Road Gate extract.
- [ ] 3.5 `[LUNA]` Implement player acceleration, speed, facing and input intent
  generation without direct transform authority in the UI/controller.
- [ ] 3.6 `[SOL]` Implement server-authoritative 2D movement, collision,
  correction and blocked-movement results.
- [ ] 3.7 `[LUNA]` Implement camera follow, cursor-to-world aim and interaction
  targeting as presentation/input adapters.
- [ ] 3.8 `[SOL]` Implement bounded proximity/line policy for doors, crates,
  corpses, healing targets and extraction zones.
- [ ] 3.9 `[SOL]` Author navigation data and a deterministic path-request seam
  that keeps pathfinding results outside canonical add-on state.
- [ ] 3.10 `[SOL]` Bake stable Common Vision occluder segments from explicit
  level data, remove internal duplicate edges and validate segment budgets.
- [ ] 3.11 `[LUNA]` Add spawn, loot, patrol, objective and extraction marker
  resources with stable authored identifiers.
- [ ] 3.12 `[SOL]` Add a headless Sawmill contract checking required anchors,
  collisions, reachable extract, occluder bounds and duplicate identifiers.

Evidence: resolution comparison sheet; approved Sawmill layout capture;
movement/collision contract; level validation report.

## 4. Inventory, equipment and loot

- [x] 4.1 `[LUNA]` Author the first-playable item definitions for AKM, machete,
  7.62x39 ammunition, magazine, bandage, splint, quest crates and a focused set
  of valuable/junk loot.
- [x] 4.2 `[SOL]` Author and seal container/equipment profiles for pockets, rig,
  backpack, secure container, weapon slots, stash, crate and corpse.
- [x] 4.3 `[SOL]` Create profile and raid Inventory authorities from explicit
  lifecycle owners; do not use a process-global canonical inventory.
- [x] 4.4 `[LUNA]` Materialize one searchable world crate and one corpse-loot
  inventory with deterministic contents for the vertical-slice fixture.
- [x] 4.5 `[SOL]` Implement `InventoryIntentAdapter` with actor ownership,
  distance, visibility, revision and world-policy checks.
- [x] 4.6 `[SOL]` Implement the snapshot-to-`InventoryPresentationModel` bridge
  and keep pending intent separate from confirmed state.
- [ ] 4.7a `[SOL]` Implement authority-side routing for placement-aware world
  loot and same-inventory move, rotate, split, merge and quick-transfer
  intents, including typed outcomes at the adapter/controller seam.
- [ ] 4.7b `[LUNA]` Bind existing drag, rotate, split, merge and quick-transfer
  interactions to the approved authority seam; keep filter, search and tooltip
  behavior presentation-only. This UI-dependent work is paused while the user
  updates `ui/**`.
- [ ] 4.8 `[SOL]` Implement equipped-item reconciliation and stable weapon/entity
  mappings after accepted inventory revisions.
- [ ] 4.9 `[SOL]` Implement ammunition/magazine reserve, reload commit,
  cancellation and rollback without duplication or loss.
- [ ] 4.10 `[SOL]` Implement inventory-to-ability equipment grants and revoke
  them idempotently from full snapshots and accepted deltas.
- [ ] 4.11 `[LUNA]` Add loot-container open/search/close presentation, including
  inaccessible, stale, overweight, disconnected and resynchronizing states.
- [ ] 4.12 `[SOL]` Prove canonical inventory persistence round trips and live
  authority replacement invalidate stale UI/adapters safely.

Evidence: inventory catalog validator; inventory intent-adapter and
presentation-projection contracts; transaction-routing tests; existing
inventory UI suite bound to real snapshots; reload rollback fixtures;
persistence byte round trip.

## 5. Weapons, health and combat mechanics

- [x] 5.1 `[LUNA]` Author sealed AKM, machete, ammunition and attachment content
  using stable identifiers and bounded values.
- [ ] 5.2 `[SOL]` Create weapon instances from equipped inventory state and
  provide authoritative liveness, equipment, pose and usability context.
- [ ] 5.3 `[SOL]` Implement body hitboxes for head, torso, arms and legs with a
  deterministic overlap/tie-break policy.
- [ ] 5.4 `[SOL]` Implement `WeaponCombatAdapter` to resolve each non-replayed
  committed shot once and emit one stable hit/miss consequence.
- [ ] 5.5 `[SOL]` Author Gameplay Abilities attributes/tags/effects for body-part
  health, overall life state, stamina, hydration, heavy bleed, fracture,
  bandage and splint.
- [ ] 5.6 `[SOL]` Implement damage, injury, healing and death consequences with
  atomic or idempotent cross-entity application.
- [ ] 5.7 `[LUNA]` Route aim, fire, reload, cancel reload, melee and quick-heal
  logical actions into bounded game intents.
- [ ] 5.8 `[SOL]` Implement melee reach, wind-up, contact, recovery and stamina
  rules without trusting presentation animation events as authority.
- [ ] 5.9 `[LUNA]` Drive HUD ammo, reload, health, status and correction states
  only from confirmed/reversible presentation events.
- [ ] 5.10 `[SOL]` Add deterministic cadence, out-of-ammo, stale-revision,
  reload-race, duplicate-shot and death-during-action regressions.
- [ ] 5.11 `[ASTRA]` Establish measurable combat-readability targets for aim,
  muzzle flash, tracer/impact, hit reaction, hit pause, camera impulse, damage
  direction, reload progress and correction feedback.
- [ ] 5.12 `[ASTRA]` Tune AKM and machete feel against recorded encounters while
  keeping every visual/audio effect consequence-neutral.
- [ ] 5.13 `[PLAYTEST]` Complete blind play sessions for weapon readability,
  injury comprehension, responsiveness and perceived fairness.

Evidence: combat authority suite; captured shot/reload/injury sequences; no
duplicate consequences; documented tuning values; playtest notes.

## 6. AI, perception and encounter behavior

- [ ] 6.1 `[SOL]` Configure the authoritative Vision world with fixed units,
  masks, ranges, cones, samples, memory duration and per-tick work budgets.
- [ ] 6.2 `[LUNA]` Register/update/remove player and NPC observers/targets from
  authoritative transforms with exact revision progression.
- [ ] 6.3 `[SOL]` Implement `VisionAIAdapter` so AI consumes only visible or
  remembered records and never reads hidden live transforms through another
  service.
- [ ] 6.4 `[LUNA]` Implement a deterministic AI state model for idle, patrol,
  investigate, engage, search, retreat and dead.
- [ ] 6.5 `[SOL]` Implement Scav aiming, cadence, cover/path requests and target
  loss behavior through the same intent boundary as the player.
- [ ] 6.6 `[LUNA]` Implement the mutant chase/melee behavior after the shared AI
  and melee contracts are green.
- [ ] 6.7 `[SOL]` Add a bounded game-owned noise event service for gunshots,
  impacts, sprinting and interactions; do not misrepresent hearing as Vision.
- [ ] 6.8 `[LUNA]` Add developer overlays for vision state, last-known position,
  navigation path, AI state and work-budget diagnostics.
- [ ] 6.9 `[SOL]` Add occlusion, memory expiry, target removal, noise, path
  failure, budget exhaustion and many-NPC deterministic tests.
- [ ] 6.10 `[ASTRA]` Tune encounter readability, reaction delays, search
  persistence and threat escalation without giving AI hidden information.

Evidence: Vision/AI headless suite; debug capture; bounded-work metrics;
recorded Scav and mutant encounters.

## 7. Tasks, extraction, profile persistence and settlement

- [ ] 7.1 `[SOL]` Implement raid phase transitions and reject intents that are
  invalid for the current phase or authority generation.
- [ ] 7.2 `[SOL]` Create the raid loadout from an immutable profile generation
  and record the unique raid/settlement identity before deployment.
- [ ] 7.3 `[LUNA]` Implement the authoritative raid timer and derived HUD clock.
- [ ] 7.4 `[SOL]` Run a Level Task integration spike for one raid-scoped graph;
  document missing APIs and disable persistent resume if snapshot/restore is
  not yet ready.
- [ ] 7.5 `[LUNA]` Author `Supply Run`: search three valid Sawmill crates, retain
  the objective item and extract through Road Gate.
- [ ] 7.6 `[SOL]` Feed ordered inventory/combat/world events and typed facts to
  the task instance; explicitly acknowledge task requests.
- [ ] 7.7 `[SOL]` Implement extraction eligibility, countdown, interruption and
  exactly-once completion.
- [ ] 7.8 `[SOL]` Define and implement death loss plus the approved secure-
  container retention rule as one settlement plan.
- [ ] 7.9 `[SOL]` Implement versioned `ProfileStore` envelopes with atomic
  replacement, backup recovery and checksum/fingerprint validation.
- [ ] 7.10 `[SOL]` Implement idempotent `RaidSettlementService` prepare/commit/
  recover behavior for extract and death.
- [ ] 7.11 `[SOL]` Add crash-point fixtures before profile write, during atomic
  replacement and after profile commit but before acknowledgement.
- [ ] 7.12 `[LUNA]` Build the summary view from audit events and committed
  settlement data, including loot, kills, damage, injuries and task progress.
- [ ] 7.13 `[SOL]` Prove close/relaunch restores the exact committed profile and
  never restores an uncommitted raid result.

Evidence: task graph fixture; extract/death settlement golden files; crash
recovery matrix; restart smoke; summary-to-audit consistency test.

## 8. UI, input and presentation integration

- [ ] 8.1 `[SOL]` Make the shared Zerkov screen base participate in
  `CommonActivatableScreen` lifecycle without changing layout geometry.
- [ ] 8.2 `[SOL]` Replace manual production navigation with CommonUI menu, HUD,
  modal and popup layers while retaining the F1 developer catalog.
- [ ] 8.3 `[LUNA]` Author logical action definitions, default bindings, glyph
  metadata and rebinding persistence for gameplay and UI contexts.
- [ ] 8.4 `[SOL]` Define typed/read-only `RaidView`, `InventoryView`,
  `HealthView`, `TaskView`, `MapView`, `BunkerView` and `SummaryView` contracts.
- [ ] 8.5 `[LUNA]` Bind the HUD to real raid, weapon, health, task and extraction
  projections with reversible prediction/correction states.
- [ ] 8.6 `[SOL]` Bind inventory and health screens to real snapshots while
  preserving drag state, selection, focus and compact scroll positions.
- [ ] 8.7 `[LUNA]` Bind Tasks and Maps to the Sawmill task/level projections;
  feature-gate unavailable zones and persistent task functions.
- [ ] 8.8 `[LUNA]` Bind deployment and summary screens to real raid lifecycle and
  settlement receipts.
- [ ] 8.9 `[LUNA]` Mark bunker, crafting, friends, insurance and marketplace
  actions as explicit prototype/locked features until their services exist.
- [ ] 8.10 `[LUNA]` Port modal, focus, action routing, rebinding and adaptive
  regression coverage to CommonUI-backed screens.
- [ ] 8.11 `[SOL]` Remove production reads/writes of `app.state`; keep mock
  fixtures only behind test/developer providers.
- [ ] 8.12 `[ASTRA]` Review every real-data screen at 1920x1080, 1600x900,
  1280x720 and the supported compact fallback for hierarchy and readability.
- [ ] 8.13 `[PLAYTEST]` Complete mouse/keyboard and controller navigation passes
  without relying on the F1 review catalog.

Evidence: existing 28-route smoke remains green; CommonUI lifecycle/input
tests; real-data screenshot matrix; zero production mock-state references.

## 9. Art, animation, VFX and audio

- [ ] 9.1 `[LUNA]` Create a curated asset registry with source provenance,
  runtime aliases, frame/atlas metadata, filtering and license fields.
- [ ] 9.2 `[LUNA]` Add import presets/tests that keep pixel sprites nearest,
  backgrounds appropriately filtered and every `DO NOT USE` path excluded.
- [ ] 9.3 `[LUNA]` Slice selected exterior, road, fence, prop, Sawmill, weapon,
  item and character sheets from explicit metadata rather than filename guesses.
- [ ] 9.4 `[ASTRA]` Build and approve the base layered player sprite composition
  for idle, walk, attack, grenade, hit and death states.
- [ ] 9.5 `[LUNA]` Implement the animation state machine and deterministic
  presentation-event inputs; animations do not author gameplay outcomes.
- [ ] 9.6 `[ASTRA]` Align held AKM, muzzle, melee contact and equipment visuals
  across animation frames and facing states.
- [ ] 9.7 `[ASTRA]` Create the first-pass muzzle flash, impacts, blood, status,
  extraction and loot-interaction VFX using the existing visual language.
- [ ] 9.8 `[ASTRA]` Define the combat audio event palette and select licensed or
  temporary sources for fire, tails, impacts, reload, footsteps, injuries,
  UI confirmation and ambience.
- [ ] 9.9 `[LUNA]` Implement audio/VFX presenters driven only by committed or
  explicitly reversible events, with pooling and simultaneous-event bounds.
- [ ] 9.10 `[ASTRA]` Establish the Sawmill lighting, canopy, contrast and weather
  treatment while keeping enemies, loot and exits readable.
- [ ] 9.11 `[ASTRA]` Produce labeled native capture/contact-sheet evidence for
  player animation, combat states, AI states and all first-playable screens.

Evidence: asset-registry validation; no forbidden imports; approved animation
sheet; pooled-effects stress run; labeled visual/audio review evidence.

## 10. Multiplayer, security and release readiness

These tasks are gated and are not part of the offline first-playable approval.

- [ ] 10.1 `[SOL]` Audit the sibling hardening change and record evidence that
  Gameplay Abilities 5.x and Weapon 6.x network tasks are complete.
- [ ] 10.2 `[SOL]` Define authenticated session, actor ownership, authority
  epoch, command sequence and compatibility negotiation at the product layer.
- [ ] 10.3 `[SOL]` Implement separate dedicated-server, owning-client and
  observer scene compositions; clients contain replicas, not authorities.
- [ ] 10.4 `[SOL]` Route every remote command through size, rate, session,
  compatibility, ownership, relevance, sequence, revision and semantic gates.
- [ ] 10.5 `[SOL]` Implement grant-scoped inventory, weapon, ability and vision
  snapshot/delta egress with exact recipient mapping.
- [ ] 10.6 `[SOL]` Derive replication relevance from authorized Vision
  projections without leaking hidden entity identities through another feed.
- [ ] 10.7 `[SOL]` Implement bounded reversible client presentation prediction
  and explicit confirm/revert/diverge/expire behavior.
- [ ] 10.8 `[SOL]` Implement disconnect, retained reconnect, replacement session,
  resync, authority generation replacement and replica teardown.
- [ ] 10.9 `[SOL]` Replicate committed game-owned hit/VFX/audit results without
  letting client presentation choose canonical consequences.
- [ ] 10.10 `[SOL]` Pass server plus two clients, unauthorized attachment,
  chosen-entropy, ID collision, malformed packet, flood and wrong-recipient
  tests.
- [ ] 10.11 `[SOL]` Pass packet loss, jitter, reordering, late join, reconnect,
  resync, persistence failure, load and soak gates.
- [ ] 10.12 `[ASTRA]` Review multiplayer correction readability and perceived
  responsiveness without relaxing authority or prediction bounds.
- [ ] 10.13 `[SOL]` Build, load, export and checksum the exact Windows client and
  Linux dedicated-server release artifacts before support is claimed.

Evidence: hostile-client matrix; two-client process logs; reconnect/resync
fixtures; load/soak report; exact release manifest and artifact hashes.

## 11. Post-slice meta systems

These items require separate approved changes after the vertical slice.

- [ ] 11.1 `[ASTRA]` Review the raid playtest results and choose the smallest
  meta loop that improves meaningful loadout decisions.
- [ ] 11.2 `[SOL]` Specify and implement bunker station state, prerequisites and
  versioned profile ownership.
- [ ] 11.3 `[SOL]` Specify and implement crafting reservations, timers, queue,
  collect and crash recovery.
- [ ] 11.4 `[SOL]` Specify and implement trader stock, pricing, reputation and
  atomic inventory/currency transactions.
- [ ] 11.5 `[SOL]` Expand persistent task chains only after Level Task snapshot,
  restore, reward and conversation integration gates pass.
- [ ] 11.6 `[SOL]` Specify insurance only after persistent ownership, raid loss
  provenance and server time are authoritative.
- [ ] 11.7 `[ASTRA]` Review corresponding UI flows before enabling each meta
  system in production navigation.

Evidence: separate validated change proposal for each accepted meta capability.

## 12. Offline vertical-slice acceptance

- [ ] 12.1 `[SOL]` Run the complete deterministic headless suite from profile
  load through raid settlement and profile reload.
- [ ] 12.2 `[LUNA]` Run all existing UI, responsive, inventory, bunker, raid and
  utility regressions against the integrated project.
- [ ] 12.3 `[SOL]` Complete ten consecutive extract/death cycles without item
  duplication, loss outside policy, stale authority mutation or save corruption.
- [ ] 12.4 `[ASTRA]` Perform final UI, Sawmill composition and combat-feedback
  review from native captures and recorded gameplay.
- [ ] 12.5 `[PLAYTEST]` Complete a fresh-player test proving the player can
  load out, deploy, understand injury, loot, complete `Supply Run`, find Road
  Gate and understand the settlement result without developer explanation.
- [ ] 12.6 `[ASTRA]` Record accepted limitations and recommend the next proposal:
  raid-depth/meta expansion or co-op networking.

Evidence: green automated report, ten-cycle ledger, performance/diagnostic log,
native video/captures, playtest findings and explicit vertical-slice sign-off.
