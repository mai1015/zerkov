## Context

The current project is a native Godot UI prototype with 28 verified routes and
session-local sample state. The external add-on workspace provides independent
deterministic domains for UI routing, vision, abilities, inventory, level/tasks
and weapons. Those domains intentionally do not own Zerkov's transport, world,
actors, hit resolution, persistence, economy or raid policy.

The add-ons have uneven readiness. Inventory, Vision and CommonUI have completed
their focused hardening work; Gameplay Abilities and Weapon networking still
have security and convergence work open; Level Task System is pre-release and
still lacks completed task snapshot/restore and several integrations. Most
non-macOS native artifacts are still planned rather than supported.

## Goals / Non-Goals

### Goals

- Deliver one complete, replay-safe offline extraction loop.
- Make the offline runtime use the same authority boundary needed by future
  dedicated-server multiplayer.
- Preserve the approved UI and pixel-art identity.
- Give every authoritative mutation one owner and every cross-domain
  consequence one stable identity.
- Keep tasks small, verifiable and routable to an appropriate Codex model.

### Non-Goals

- PvP, matchmaking, live services or public servers in the first playable.
- Full trader, insurance, hideout, crafting or economy simulation.
- Complete content import from every source-art directory.
- Modifying sibling add-on internals from the Zerkov product project.
- Treating a successful macOS editor run as Windows or Linux release support.

## Product loop

```text
profile + stash
      |
      v
select loadout -> deploy -> raid
                         |-- move / perceive / fight
                         |-- search / loot / heal
                         |-- advance objective
                         `-- extract or die
                                  |
                                  v
                        atomic settlement
                                  |
                                  v
                       summary -> bunker
```

The raid must be fun before the surrounding meta systems are expanded. Meta UI
may remain visible for review, but actions without an authoritative backing
service stay feature-gated or clearly marked as unavailable.

## Decisions

### Product project

The current Zerkov repository is the integrated game. A second product project
would duplicate UI, assets, export configuration and test harnesses.

### Authority boundary

`RaidAuthority` owns:

- the canonical 60 Hz tick;
- authenticated actor/session identity, even in offline mode;
- conversion between Godot world coordinates and add-on fixed units;
- world liveness, pose, distance, line-of-sight and interaction policy;
- the order in which accepted intents reach domain authorities;
- stable command, consequence, request and settlement identities;
- an append-only bounded raid audit stream;
- generation changes, teardown and publication of read-only projections.

UI code, AI controllers and future remote peers submit intent. They do not call
domain mutation methods directly.

### Runtime composition

```text
ZerkovApp
|-- ContentCatalogs
|-- ProfileStore
|-- CommonUIScreenRoot
|-- SessionCoordinator
`-- RaidSession
    |-- RaidAuthority
    |   |-- MovementWorld2D
    |   |-- InventoryAuthority
    |   |-- WeaponAuthority
    |   |-- GameplayAbilityWorldCoordinator
    |   |-- CommonVisionWorld2D
    |   |-- LevelTaskRuntimeOwner
    |   `-- RaidEventJournal
    |-- WorldPresentation
    `-- UIProjectionBridge
```

Offline play creates a trusted local session and drives the same intent APIs.
Network play later replaces only session ingress and replica egress.

### Tick order

Every authority tick uses a documented order:

1. Admit bounded player, AI and system intents for the tick.
2. Advance movement and publish authoritative actor poses.
3. Update vision targets/observers and complete budgeted projections.
4. Convert AI decisions into intents for the next tick.
5. Execute interactions and weapon mechanics against current poses.
6. Resolve committed shots and other world consequences exactly once.
7. Advance ability effects, health/status, reload and other due work.
8. Feed ordered committed events into tasks and the raid audit stream.
9. Publish immutable domain/UI projections and schedule persistence/replication.

Consequences that span domains use a stable identity and an explicit
reserve/commit/rollback or idempotent retry contract. Signal delivery order is
never used as a transaction boundary.

### Game-owned adapters

| Adapter | Responsibility |
| --- | --- |
| `UIIntentAdapter` | Convert logical CommonUI actions and pointer operations into bounded game intents. |
| `InventoryWeaponAdapter` | Validate equipment, reserve ammunition, authorize attachments, and commit or roll back reload consumption. |
| `WeaponCombatAdapter` | Supply authoritative pose, resolve rays/hits, deduplicate shot consequences, and emit presentation-safe results. |
| `InventoryAbilityAdapter` | Reconcile equipment traits with ability grants, effects and gameplay tags after accepted inventory revisions. |
| `VisionAIAdapter` | Convert TileMap-authored occluders and actor transforms into Vision state, then expose only visible/remembered AI knowledge. |
| `TaskEventAdapter` | Convert committed raid events/facts into Level Task input and explicitly acknowledge reward/transition requests. |
| `UIProjectionBridge` | Convert immutable domain snapshots into stable screen-specific view models. |

Adapters live under the product's `game/` namespace, never inside sibling
add-on packages.

The reload adapter (task 4.9, accepted 2026-09-10) binds an equipped weapon
through stable weapon/equipment identity and coordinates the native inventory
quantity participant with the WeaponAuthority reload port. Its first-playable
source policy is magazine-contained ammunition, then rig, then pockets. A
reload reserves exact native item identities and quantities, commits inventory
silently before the weapon's due commit, and publishes inventory followed by
the weapon completion only after both canonical states agree. Cancellation,
death, equipment invalidation and owner teardown release an uncommitted hold;
replayed requests return the terminal receipt, and an out-of-band weapon
completion enters fail-stop quarantine instead of refunding held ammunition.
The accepted real-add-on flow proves this at 3 -> 30 loaded rounds with
11/8/19 source rounds and a conserved total of 41. This is deliberately an
offline, synchronous, in-memory, single-writer/no-yield boundary: the installed
WeaponAuthority facade has no public symmetric rollback, so crash-safe 2PC and
physical detachable-magazine identity/swapping are not claimed. Production
weapon-instance lifecycle and input routing remain tasks 5.2 and 5.7.

The equipment ability adapter (task 4.10, accepted 2026-09-10) binds one exact
inventory owner/admission generation, inventory actor, Gameplay Ability
component and canonical inventory/ability catalog pair. Binding itself is
mutation-free. The adapter registers in `RaidAuthority` phase 7, after inventory
mutations commit in phase 5, and derives grants only from a complete current
owner snapshot. Accepted deltas are bounded sequencing hints rather than a
second source of truth. Stable admission, generation, item, ability-entity and
content identities make the revision-zero full snapshot, duplicate state,
recorded/normalized replay, batched revisions and gap/full-snapshot healing
idempotent.

AKM and machete equipment declare native passive abilities, infinite effects,
gameplay tags and an equipment-readiness attribute modifier; rig and backpack
are explicit no-grant equipment. A complete preflight precedes deterministic
add-before-remove replacement. Unequip, item destruction, explicit release and
owner/component teardown revoke owned sources. Ambiguous partial failure enters
fail-stop recovery and may terminally quarantine the captured component; it is
never represented as a successful adapter revision. The native component keeps
at most 64 historical grant records, so the 65th grant fails preflight. An
accepted P2 composition constraint remains for tasks 4.12/7.1: release the
adapter or tear down its owner/component before `RaidAuthority` terminalizes,
because terminalizing the raid clears phase handlers and does not itself revoke
equipment contributions. Automatic raid-terminal-first cleanup is not claimed.

The reviewed inventory mutation seam (task 4.7a) routes placement-aware world
loot and same-inventory move, rotate, split, merge and complete-only quick
transfer operations through strict payload schemas and typed receipts. Quick
transfer uses `allow_partial=false`, and the submission path rejects reentrant
mutation before a second authoritative submission can start.

The reviewed equipped-item reconciler (task 4.8) accepts only the current
projection's exact native `Resource` provenance, preserves stable
weapon/equipment and entity mappings, performs fail-atomic rebinding, publishes
recursively read-only outcomes, and releases bindings in a reentrant-safe
order.

The inventory UI binding (task 4.7b, accepted 2026-09-10) keeps canonical
mutation in the authority/adapter seam. UI item records are detached from
immutable confirmed snapshots; filter, search, hover, selection and tooltip
behavior remain presentation-only, while drag, rotate, split, merge, loot and
quick-transfer gestures emit strict intents. Owner/scope generations, binding
tokens, exact item facts and captured dependencies protect deferred input and
synchronous replacement. Command IDs advance before pending publication,
remain distinct across controllers and models, fail closed at exhaustion, and
resolve feedback once; quick transfer remains complete-only
(`allow_partial=false`). Live-empty gear/economy actions are unavailable and
fixture restoration is visibly labelled `FIXTURE PREVIEW`. Encrypted Drive and
Gold Watch retain their true identities with neutral artwork and accessible
`PLACEHOLDER` disclosure; Health and Stats are explicitly authored preview
values. The accepted native evidence covers 1920x1080, 1600x900, 1280x720 and
960x540 as historical regression evidence. The current first-playable visual
acceptance target is 1920x1080 only; smaller and compact layouts are
nonblocking and deferred. This does not claim human playtest, complete
raid-loop, multiplayer, or other-platform release acceptance; later UI,
combat and progression gates remain open.

### Identifiers and units

Content and runtime identifiers use stable lower-case namespaces:

```text
zerkov.level.sawmill_yard
zerkov.extract.sawmill.road_gate
zerkov.weapon.akm
zerkov.item.ammo.762x39.standard
zerkov.effect.injury.heavy_bleed
zerkov.task.sawmill.supply_run
```

A `ZWorldUnits` utility owns all checked conversion. The implementation must
choose and lock one relation among source pixels, tiles and canonical world
distance before weapon ranges, vision ranges or navigation data are authored.

### World and asset pipeline

- Treat 32 px environment atlases as source tiles and 64 px character cells as
  authored animation frames unless asset-specific metadata says otherwise.
- Build Sawmill Yard as a real scene with separate ground, detail, collision,
  canopy, interaction, navigation, spawn, loot, extraction and occluder data.
- Bake Common Vision segments from explicit level-authoring data; runtime Vision
  does not infer them from physics or TileMaps.
- Use the selected fixed 640x360 internal world `SubViewport` separately from
  the crisp UI. At each output, fit it with `k = floor(min(W/640, H/360))`
  using integer enlargement and a centered matte; preserve nearest filtering
  and round the final presentation camera once to whole source pixels.
- Import only selected runtime assets, retain source provenance, use nearest
  filtering for sprites, and exclude every `DO NOT USE` directory.
- Build the base layered character first. Cosmetic permutations are content
  expansion, not a first-playable dependency.

### Render-scale decision (tasks 3.1-3.2)

The native comparison from clean checkpoint `93f337e` selected a fixed 640x360
world surface, orthographic Camera2D zoom `(1,1)`, nearest filtering, integer
fit and centered letterboxing. The final desired presentation camera, including
any presentation impulse, is rounded once to whole world-raster pixels with
Camera2D smoothing off; simulation positions, ranges, collision shapes and
`ZWorldUnits` remain unrounded. The HUD remains an independent full-output
composition and can use the matte without being textured by the world surface.

For the current first playable, 1920x1080 is the sole supported output: the
640x360 world surface displays at exact 3x scale and fills the viewport. The
earlier 1600x900, 1280x720 and compact captures remain useful historical
regressions but are not release gates. Support policy, adaptation and visual
approval for smaller outputs are deferred. The capture evidence records
`human_approval: false`; later animation, combat/readability and cursor-mapping
gates remain open.

### Combat and health ownership

Weapon System owns firearm mechanics: cadence, ammunition state, reload phase,
attachments and recoil. It does not select world hits.

Zerkov owns hitboxes, ray/shape queries, obstruction, hit-zone selection,
damage policy and committed combat events. Gameplay Abilities owns health,
stamina, injuries, healing effects and death-producing attribute/tag state.

Combat presentation is derived from committed or explicitly reversible
predicted events. Camera impulse, hit pause, muzzle flash, tracers, audio and
animation cannot change canonical outcomes.

### UI migration

- Keep the existing layout, theme, adaptive behavior and developer catalog.
- Change the shared Zerkov screen base to participate in CommonUI activation
  and route logical actions through CommonUI contexts.
- Keep custom Zerkov inventory visuals; bind them to the Inventory presentation
  model and immutable snapshots rather than adopting another visual theme.
- Replace `app.state` one screen family at a time with `InventoryView`,
  `HealthView`, `RaidView`, `TaskView`, `MapView`, `BunkerView` and
  `SummaryView` projections.
- A screen may temporarily use mock data only behind an explicit prototype
  flag. Production routes must not silently mix mock and canonical values.
- Visual approval compares native captures at supported layouts and includes
  keyboard, mouse and controller focus states.

### Task-system staging

The first task is raid-scoped `Supply Run`. Level Task System may drive it once
its current runtime APIs pass an integration spike. Mid-raid task resume and
persistent task chains remain disabled until versioned task snapshot/restore is
complete and verified. Zerkov must not build an incompatible second quest DSL
as a temporary substitute.

### Persistence and settlement

`ProfileStore` owns a versioned envelope containing project data plus opaque
domain persistence bytes. File replacement is atomic and recoverable.

Deployment creates a unique raid and settlement identity and records the
starting profile generation. Extraction or death produces one settlement plan.
Applying the same plan again must be a no-op with the original receipt. A
successful profile commit occurs before the raid is reported settled.

The first implementation may be a local file port. Database choice, cloud
sync, account ownership and encryption remain replaceable infrastructure.

### Multiplayer gates

The first playable uses direct offline authority and no live network bridge.
Networking starts only when all of the following are true:

- Gameplay Abilities deny-by-default authorization/relevance and abuse-control
  hardening is complete.
- Weapon session identity, entropy ownership, compatibility, RPC admission,
  reconnect and resolved-shot replication hardening is complete.
- Windows client and Linux server artifacts build, load and export.
- The offline authority loop passes deterministic replay and settlement tests.

Co-op precedes PvP. Multiplayer acceptance requires server plus two clients,
malformed/hostile commands, packet loss/reordering, disconnect/reconnect,
resynchronization and crash-recovery evidence.

### Model-assisted execution

Tasks carry model lanes based on ambiguity and risk rather than file type.
Luna handles bounded mechanical implementation; Sol handles cross-system and
network correctness; Astra handles architecture, visual judgment, combat feel
and final gates. `model-routing.md` defines escalation and prompt templates.

## Risks / Trade-offs

- Six native add-ons create platform and version coupling. Pinning and a load
  matrix are required before gameplay work grows.
- A polished UI can encourage premature meta-system scope. First-playable
  exclusions remain explicit.
- Cross-domain reload, equipment and settlement behavior can duplicate or lose
  items if signals are treated as transactions. Explicit identities and
  reserve/commit contracts add complexity but are required.
- Pixel-art scaling outside 1080p remains unapproved. The current slice gates
  native captures at 1920x1080 and defers smaller-output adaptation.
- Current source art provides atlases and props, not finished levels. Sawmill
  Yard requires authored layout, collisions, navigation and occluders.
- Level Task persistence is incomplete, so persistent quest expansion is gated.
- macOS success does not reduce the need for early Windows/Linux proof.

## Migration Plan

1. Approve this proposal and freeze the first-playable boundary.
2. Pin add-ons, introduce product directories and pass a combined load smoke.
3. Add the authority/tick/identity skeleton without replacing UI routes.
4. Build a playable Sawmill test yard and combat/loot domain slices.
5. Bind real projections into HUD, inventory, health, tasks and summary.
6. Add atomic profile/settlement recovery and complete the offline loop.
7. Remove production dependence on mock state.
8. Expand meta systems only after the vertical-slice gate passes.
9. Begin multiplayer only after the documented hardening/platform gates pass.

## Approved slice decisions

- The first public milestone is strictly solo and offline. Co-op remains gated
  behind the accepted offline vertical slice, add-on hardening and platform
  evidence.
- On death, canonical items committed to the secure container are retained;
  unsecured carried items are lost. Settlement tests will freeze the exact
  boundary before UI binding.
- The first-playable roster keeps both one Scav and one mutant. The Scav lands
  first; mutant implementation starts only after shared perception and melee
  contracts are green.
- Tasks 3.1-3.2 selected the fixed 640x360 internal world surface with nearest
  filtering, integer fit and centered matte after an independent Astra review.
  The final presentation camera rounds once to whole source pixels, while the
  HUD remains an independent full-output composition. The first-playable
  output is now 1920x1080 only, where the world is exact 3x. Smaller and compact
  outputs are explicitly deferred rather than current acceptance gates. Human
  approval remains false; later animation, combat/readability and cursor-mapping
  gates remain open.
