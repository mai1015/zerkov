---
created_at: 2026-09-09T23:45:13Z
updated_at: 2026-09-11T02:14:29Z
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

Display-scope decision (2026-09-10): exact 1920x1080 is the only current
first-playable UI and visual acceptance target. Existing responsive/compact
behavior, historical captures and dedicated sources may remain, but current
agents, tasks and tests MUST NOT execute their smaller suites or regenerate
their outputs. Do not add smaller-layout implementation or review work until
task 11.8 or a later approved proposal reopens display support.

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

- [x] 3.1 `[ASTRA]` Build an isolated render-scale spike comparing candidate
  low-resolution world surfaces at 1920x1080, 1600x900 and 1280x720 while the
  existing UI remains crisp.
- [x] 3.2 `[ASTRA]` Select and document the world surface, camera policy,
  pixel-snap rules and failure tolerances from native captures. The independent
  Astra review accepted fixed 640x360 rendering with nearest filtering,
  integer fit/centered matte and a rounded final presentation camera; human
  approval remains false and later animation, combat/readability and cursor
  mapping gates remain open.
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

Completed task evidence (3.1-3.2, 2026-09-10): the native render-scale matrix
passed capture `RENDER_SCALE_COMPLETE checks=1292 failures=0`, existing UI
composition `UI_COMPOSITION_COMPLETE checks=109 failures=0`, responsive
layouts `RESPONSIVE_TEST_COMPLETE checks=96 failures=0`, and border rendering
`BORDER_RENDER_TEST_COMPLETE checks=135 failures=0`. The evidence packet records
26 PNG hashes and the 1600x900 world rectangle as 1280x720 centered with 160 px
horizontal and 90 px vertical matte. The selected constant-FOV policy keeps
world visibility stable across the tested outputs, trading the 900p matte for
fairness rather than exposing extra world area; no human approval or later
animation/combat/readability/cursor-mapping acceptance is claimed.

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
- [x] 4.7a `[SOL]` Implement authority-side routing for placement-aware world
  loot and same-inventory move, rotate, split, merge and quick-transfer
  intents, including typed outcomes at the adapter/controller seam. Quick
  transfer is complete-only (`allow_partial=false`), with strict schemas,
  typed receipts and a submission reentrancy guard.
- [x] 4.7b `[LUNA]` Bind existing drag, rotate, split, merge and quick-transfer
  interactions to the approved authority seam; keep filter, search and tooltip
  behavior presentation-only. The existing UI interactions are bound to real
  snapshots and independently verified at the native desktop resolutions.
- [x] 4.8 `[SOL]` Implement equipped-item reconciliation and stable weapon/entity
  mappings after accepted inventory revisions. The reconciler uses stable
  weapon/equipment IDs, exact native Resource provenance, fail-atomic rebinding,
  recursively read-only publications and reentrant release ordering.
- [x] 4.9 `[SOL]` Implement ammunition/magazine reserve, reload commit,
  cancellation and rollback without duplication or loss.
- [x] 4.10 `[SOL]` Implement inventory-to-ability equipment grants and revoke
  them idempotently from full snapshots and accepted deltas.
- [ ] 4.11 `[LUNA]` After 4.12 and 4.12a are accepted, extend the existing
  designed inventory/loot UI with loot-container open/search/close
  presentation, including inaccessible, stale, overweight, disconnected and
  resynchronizing states. Do not introduce a replacement inventory screen;
  bind canonical inventory snapshots/intents into the accepted grid, drag,
  transfer and focus behavior at 1920x1080. Existing compact code may remain
  but is not part of this task's acceptance gate. Preserve the audited baseline
  in `docs/qa/astra_visual_audit_2026-09-10/INVENTORY_1080P_BASELINE.md`.
- [x] 4.12 `[SOL]` Prove canonical inventory persistence round trips and live
  authority replacement invalidate stale UI/adapters safely.
- [x] 4.12a `[SOL]` Normalize `FEATURE_LIST` capability-query metadata for
  stash, world-crate and corpse profiles that can carry item-provided
  ordered-list magazine children, and prove nested magazine contents through
  transfer, persistence and query contracts before exposing those contents
  there.

Evidence: inventory catalog validator; inventory intent-adapter and
presentation-projection contracts; transaction-routing tests; existing
inventory UI suite bound to real snapshots; reload rollback fixtures;
persistence byte round trip.

Completed task evidence (4.7a and 4.8, 2026-09-10):
`INVENTORY_MUTATION_ROUTING_RESULT checks=146 failures=0`,
`INVENTORY_INTENT_ADAPTER_RESULT checks=162 failures=0`,
`INVENTORY_PROJECTION_RESULT checks=99 failures=0`,
`INVENTORY_CATALOG_RESULT checks=504 failures=0`,
`INVENTORY_AUTHORITY_RESULT checks=79 failures=0`,
`AUTHORITY_REPLAY_RESULT checks=81 failures=0`, and
`EQUIPPED_ITEM_RECONCILIATION_RESULT checks=123 failures=0`.
The reconciliation review also reran the shared identity contract
(`IDENTITY_CONTRACT_RESULT checks=18442 failures=0`), catalog, authority,
projection and intent contracts above, plus the combat content contract
(`COMBAT_CONTENT_RESULT checks=79 failures=0`).

Completed task evidence (4.7b, 2026-09-10): the fresh independent Astra gate
accepted 31 distinct final suite/probe variants with `4228` raw checks and
`0` failures at 1920x1080, 1600x900, 1280x720 and 960x540. The continuous
native owner/session flow passed `88/0`; compact native continuity passed
`34/0`, and the promoted compact-selection probe passed `37/0`. The unchanged
sealed live-section and tooltip regressions passed `18/0` and `17/0`; the
independent overlay/section challenge passed `112/0`. Earlier authoring
attempts are retained as diagnostic history and are excluded from the accepted
31-variant total.

The binding keeps canonical mutation in the authority/adapter seam: detached
UI records render immutable confirmed snapshots; filter, search, hover,
selection and tooltip remain presentation-only; drag, rotate, split, merge,
loot and quick-transfer emit strict intents. Owner/scope generations, binding
tokens, exact item facts and captured dependencies protect deferred input and
synchronous replacement; command IDs advance before pending publication,
remain distinct across controllers/models, fail closed at exhaustion, and
resolve feedback once. Quick transfer remains complete-only
(`allow_partial=false`). Live-empty gear/economy actions are unavailable;
fixture restoration is visibly labelled `FIXTURE PREVIEW`, and Encrypted Drive
and Gold Watch retain their true identities with neutral artwork and visible
accessible `PLACEHOLDER` disclosure. Health and Stats remain authored preview
values with explicit notices rather than early progression claims.

The evidence is native macOS Compatibility coverage only, and the automated
flows are not a human playtest or a complete raid loop. Human gates 5.13, 8.13
and 12.5, whole-game completion, multiplayer, and other-platform release
acceptance remain open. See
`docs/qa/inventory_ui_binding/astra_final_accept/REPORT.md` for the full
acceptance packet and rejection history.

Completed task evidence (4.9, 2026-09-10): the fresh independent Astra
checkpoint accepted the final packet at
`docs/qa/inventory_weapon_reload/astra_final/REPORT.md` with human approval
false. All current runs used the pinned Godot 4.7.2 Compatibility executable,
passed diagnostics and exited cleanly. The raw accepted total is `20750`
assertions with `0` failures. The promoted catalog contract passed
`INVENTORY_CATALOG_RESULT checks=537 failures=0`; the promoted reload contract
passed `INVENTORY_WEAPON_RELOAD_RESULT checks=159 failures=0`; the independent
capacity challenge passed `33/0`; the independent real-add-on flow passed
`208/0` headless and `213/0` native. Native repeats the same 208 core flow
assertions and adds five window/renderer/capture checks. The packet contains
17 distinct test programs and 18 execution variants.

The real canonical fixture starts with an equipped AKM at 3 loaded rounds and
source quantities of 11 magazine-contained, 8 rig and 19 pocket rounds. A
reservation records exactly 27 rounds in magazine -> rig -> pockets order;
canonical physical quantities remain unchanged while those 27 held rounds are
unavailable and excluded from spendable-quantity accounting. Cancel-at-due
releases the native hold and replays its terminal receipt. A second reservation
survives an unrelated accepted inventory revision and commits exactly once,
leaving magazine/rig/pockets at 0/0/11, the weapon at 30 loaded rounds, and
the conserved total at 41. Replay and late sweeps do not emit another
completion. Same-due-tick death and native equipped-item movement/swap
release the uncommitted hold without
loss or duplication. Explicit adapter teardown is a separate independent-flow
case and releases the uncommitted hold. Promoted owner-lifecycle
teardown/invalidation is separate coverage. Out-of-band weapon completion
enters explicit fail-stop quarantine rather than refunding held ammunition.

The accepted scope is offline, synchronous, in-memory, single-writer/no-yield
coordination. Inventory rollback is proven for the unpublished immediate
successor and the game-owned fake rollback seam; the installed WeaponAuthority
facade exposes no public symmetric rollback, so crash/restart atomicity and a
completed recovery workflow are not claimed. Physical detachable-magazine
identity/swapping, production weapon instances/input (5.2 and 5.7), human
playtest, the complete raid loop, multiplayer and release gates remain open.
The future `4.12a` metadata task above is nonblocking for 4.9 and covers
FEATURE_LIST capability-query/transfer/persistence proof for stash, crate and
corpse profiles.

Completed task evidence (4.10, 2026-09-10): the fresh independent Astra
checkpoint accepted
`docs/qa/inventory_ability_equipment/astra_final/REPORT.md` with human approval
false. All current runs used the pinned Godot 4.7.2 Compatibility executable,
passed strict diagnostics and exited cleanly. The accepted total is `21756`
raw assertion executions with `0` failures across 17 distinct test programs and
18 execution variants. The promoted equipment reconciliation contract passed
`INVENTORY_ABILITY_RECONCILIATION_RESULT checks=546 failures=0`; 16 promoted
and adjacent suites contributed `20842/0`; the independently authored real
add-on flow passed `451/0` headless and `463/0` in the visible native window.
Native repeats the same 451 core assertions and adds 12 renderer, window and
capture checks. Four inspected 1280x720 captures and an 80-file hash manifest
seal the accepted packet.

Only `RaidAuthority.advance_one()` drives the independent flows. Real inventory
insert, move, equip, replay and destruction mutations commit in phase 5; native
ability grants/revokes and adapter publication occur in phase 7. Binding is
mutation-free, then revision-zero full reconciliation establishes state.
Accepted revisions queue bounded sequencing hints while reconciliation always
pulls the complete current owner snapshot. Stable source keys make duplicate
full state, recorded and normalized replay, multi-revision batching and
gap/full-snapshot healing idempotent. AKM and machete sources create and remove
real passive executions, infinite effects, gameplay tags and an equipment
attribute modifier; rig and backpack are declared no-grant equipment. Complete
preflight and deterministic add-before-remove ordering cover replacement, and
foreign same-ability sources remain isolated during ordinary cleanup.

Unequip, equipped-item destruction, explicit release, owner-first teardown and
component-first teardown remove owned live contributions. Injected partial
grant/revoke failures enter `RECOVERY_REQUIRED`, fail the raid tick and account
for or terminally quarantine unresolved native state without publishing a
successful revision. The production capacity boundary accounts for 64 native
grant-history tombstones; a 65th grant fails preflight without creating a new
live effect. This remains offline, synchronous and in-memory, and component-wide
quarantine does not promise foreign-state survival.

Accepted P2 lifecycle follow-up for tasks 4.12/7.1: composition must release the
adapter or tear down the inventory owner/component before `RaidAuthority`
terminalizes. Raid terminalization clears its phase handlers and, by itself,
does not revoke equipment contributions; automatic raid-terminal-first cleanup
is not claimed. Production UI/input, human playtest, the complete raid loop,
multiplayer and release gates remain open. Task 4.11 remains unchecked and must
extend the existing audited inventory workspace; 4.12 and 4.12a are accepted.

Completed task evidence (4.12, 2026-09-10): persistence and authority
replacement passed independent review after repairing allocator-floor
convergence, generation-scoped projection result ledgers and invalidated reload
receipt replay. The accepted 4.12a-integrated matrix passed `21157/0`, including
persistence `97/0` with four exact round trips, nested magazines `258/0`,
catalog `543/0`, reload `176/0`, projection `99/0` and authority `79/0`.
Retained UI/lifecycle checks added `306/0`; strict diagnostics, spec validation,
vendor checks and SHA-256 seals passed. A forced post-commit verification
mismatch reports committed recovery truthfully instead of returning a false
failure after mutation. No UI layout was changed. See
`docs/qa/inventory_persistence/implementation/REPORT.md`.

## 5. Weapons, health and combat mechanics

- [x] 5.1 `[LUNA]` Author sealed AKM, machete, ammunition and attachment content
  using stable identifiers and bounded values.
- [ ] 5.2 `[SOL]` Create weapon instances from equipped inventory state and
  provide authoritative liveness, equipment, pose and usability context.
- [ ] 5.3 `[SOL]` Implement body hitboxes for head, torso, arms and legs with a
  deterministic overlap/tie-break policy.
- [ ] 5.4 `[SOL]` Implement `WeaponCombatAdapter` to resolve each non-replayed
  committed shot once and emit one stable hit/miss consequence.
- [x] 5.5 `[SOL]` Author Gameplay Abilities attributes/tags/effects for body-part
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

Completed task evidence (5.5, 2026-09-10): the accepted content declares seven
body zones, 12 attributes, 34 tags, 41 effects and 41 abilities. The final
health contract passed `392/0`; combat content `79/0`, equipment reconciliation
`546/0` and combined add-ons `155/0` produced a sealed `1172/0` packet. An
independent `86/86` adversarial pass covered stale future ticks, reentrancy,
bounded concurrent reservations and a saturated 64-request native queue. A
rejected request cannot mutate later, advance admission watermarks or strand a
reservation; capacity can be reused. Strict spec/import/diagnostics and ten
source hashes passed. Cross-entity consequences, bleed scheduling, death order
and medical inventory transactions remain task 5.6. See
`docs/qa/health_ability_content/README.md`.

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

- [x] 8.1 `[SOL]` Make the shared Zerkov screen base participate in
  `CommonActivatableScreen` lifecycle without changing layout geometry.
- [x] 8.2 `[SOL]` Replace manual production navigation with CommonUI menu, HUD,
  modal and popup layers while retaining the F1 developer catalog.
- [ ] 8.3 `[LUNA]` Author logical action definitions, default bindings, glyph
  metadata and rebinding persistence for gameplay and UI contexts.
- [x] 8.4 `[SOL]` Define typed/read-only `RaidView`, `InventoryView`,
  `HealthView`, `TaskView`, `MapView`, `BunkerView` and `SummaryView` contracts.
- [ ] 8.5 `[LUNA]` Bind the HUD to real raid, weapon, health, task and extraction
  projections with reversible prediction/correction states.
- [ ] 8.6 `[SOL]` After inventory tasks 4.11, 4.12 and 4.12a are accepted, bind
  the existing designed inventory and health screens to real snapshots while
  preserving drag state, selection, focus and scroll positions at 1920x1080.
  Do not create a replacement inventory interface; smaller layouts are deferred.
- [ ] 8.7 `[LUNA]` Bind Tasks and Maps to the Sawmill task/level projections;
  feature-gate unavailable zones and persistent task functions.
- [ ] 8.8 `[LUNA]` Bind deployment and summary screens to real raid lifecycle and
  settlement receipts.
- [ ] 8.9 `[LUNA]` Mark bunker, crafting, friends, insurance and marketplace
  actions as explicit prototype/locked features until their services exist.
- [ ] 8.10 `[LUNA]` Port modal, focus and action routing plus rebinding
  regression coverage to CommonUI-backed screens. Keep any retained adaptive
  implementation out of the current first-playable test matrix; smaller suites
  are deferred until task 11.8 or a later approved display-support proposal.
- [ ] 8.11 `[SOL]` Remove production reads/writes of `app.state`; keep mock
  fixtures only behind test/developer providers.
- [ ] 8.12 `[ASTRA]` Review every real-data screen at 1920x1080 for hierarchy,
  readability and preserved interaction affordances. Smaller outputs are
  deferred and MUST NOT block first-playable acceptance.
- [ ] 8.13 `[PLAYTEST]` Complete mouse/keyboard and controller navigation passes
  without relying on the F1 review catalog.

Evidence: existing 28-route smoke remains green; CommonUI lifecycle/input
tests; real-data screenshot matrix; zero production mock-state references.

Completed task evidence (8.2, 2026-09-10): independent re-review accepted the
final active-context repair at `e48f18baeede8687a96babc64fc9069016836a3d`.
The exact retained Saves-under-Session deletion/rename reproduction, forged,
replayed, replaced and torn-down context capabilities, and current-owner
single-commit path passed `31/0`. The exact 1920x1080 navigation contract passed
`94/0` headless and native; navigation, CommonUI, lifecycle, UI, component,
composition, crawler, add-on and native-border suites remained green. The
screen geometry digest stayed `550b91a79fa9c5ae30bc3f736629e78429c25f56e0fc4c52bbecf38e60fa1e03`
and the 1920x1080 capture remained byte-identical. Strict validation, editor
import, diagnostics, frozen hashes and diff checks passed. Tasks 8.3 and 8.10
retain binding/glyph/device and exhaustive adaptive coverage respectively; the
smaller-layout runs are historical information, not first-playable gates. See
`docs/qa/common_ui_navigation/implementation/REPORT.md`.

## 9. Art, animation, VFX and audio

- [x] 9.1 `[LUNA]` Create a curated asset registry with source provenance,
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

Completed task evidence (9.1, 2026-09-10): the accepted registry contains 74
stable entries and aliases, 62 verified runtime hashes, 22 verified local-source
hashes, 12 explicitly pending entries and seven dimension-checked atlas
declarations. The focused contract passed `1425/0`; the original independent
adversarial probe passed `26/0`, loader probe `13/0` and integer matrix `20/0`.
A deliberate restoration of the approximate-integer bug made ten permanent
tests fail. Six 1920x1080 UI background sources resolve with matching bytes;
the Sawmill source is honestly registered as a nearest-filtered prop sheet.
Three distribution-license blockers and pre-existing Level Task source drift
remain disclosed. This completes registry metadata only; import policy and
slicing remain tasks 9.2 and 9.3. See `docs/qa/asset_registry/README.md`.

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
- [ ] 11.8 `[ASTRA]` Propose the post-slice display support matrix and reopen
  1600x900, 1280x720 and compact adaptation only after 1920x1080 first-playable
  acceptance is complete.

Evidence: separate validated change proposal for each accepted meta capability.

## 12. Offline vertical-slice acceptance

- [ ] 12.1 `[SOL]` Run the complete deterministic headless suite from profile
  load through raid settlement and profile reload.
- [ ] 12.2 `[LUNA]` Run all exact 1920x1080 UI, navigation, lifecycle,
  composition, reflow, component, border, crawler, inventory, bunker, raid and
  utility regressions against the integrated project. Current acceptance MUST
  NOT invoke smaller-resolution or responsive/compact suites, even for
  information; historical artifacts remain audit-only until task 11.8 or a
  later approved display-support proposal.
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
