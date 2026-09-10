# Execution Order and Workstreams

The task ledger is organized by aspect. This document supplies dependency order
and safe parallel boundaries. Stage 2 begins only after task 0.3 is approved.

## Dependency map

```text
Proposal approval
      |
      v
Add-on baseline (1) -----> Runtime foundation (2)
      |                         |
      |                         +-----> World/player (3)
      |                         +-----> Inventory (4)
      |                         +-----> Combat/health (5)
      |                                      |
      +-------------------------------> AI/vision (6)
                                             |
World + Inventory + Combat + AI --------------+
      |
      v
Tasks/extraction/persistence (7)
      |
      +-----> UI real-data integration (8)
      +-----> Art/feel completion (9)
      |
      v
Offline vertical-slice gate (12)
      |
      +-----> Meta proposals (11)
      `-----> Multiplayer/release (10), only after its extra gates
```

## Phase A — approve and de-risk native dependencies

Tasks: `0.3-0.4`, then `1.1-1.8`.

Purpose:

- freeze scope and product decisions;
- prevent accidental use of mutable development add-on trees;
- expose Windows/Linux blockers before content depends on unavailable builds;
- give every later task one reproducible Godot/add-on baseline.

Exit gate: combined macOS load smoke is green, exact packages are locked, and
Windows/Linux artifact status is explicit.

Recommended routing:

- Luna: manifest, copy tooling, toolchain docs and notices;
- Sol: combined load/version checks and platform artifact proof;
- Astra: only unresolved first-playable decisions.

## Phase B — establish canonical game seams

Tasks: `2.1-2.11`.

Do not begin independent gameplay systems before identity, units, clock, intent
and lifecycle contracts exist. Otherwise each workstream will invent its own
IDs, time and error handling.

Exit gate: a headless empty raid can start, advance deterministic ticks, record
events, replay to the same digest and tear down cleanly.

## Phase C — playable room

Primary tasks: `3.1-3.12`, selected `9.1-9.5`.

Order:

1. Astra render-scale decision (`3.1-3.2`).
2. Luna asset registry, import metadata and TileSet (`9.1-9.3`, `3.3`).
3. Astra Sawmill greybox and base character composition (`3.4`, `9.4`).
4. Luna player/camera/animation mechanics (`3.5`, `3.7`, `9.5`).
5. Sol movement, interaction, navigation, occluder bake and level contract
   (`3.6`, `3.8-3.10`, `3.12`).

Exit gate: the player can traverse the Sawmill greybox, collide, aim, interact
with a crate and enter the Road Gate zone with stable rendering.

## Phase D — domain slices

After Phase B contracts are stable, these aspect branches can progress with
limited overlap:

| Track | Tasks | Primary paths it should own | Depends on |
| --- | --- | --- | --- |
| Inventory | `4.1-4.12` | future `game/inventory/`, content inventory Resources, inventory adapters/tests | identity, intent, add-on load |
| Combat/health | `5.1-5.10` | future `game/combat/`, ability/weapon content, combat tests | units, tick, movement pose |
| AI/vision | `6.1-6.9` | future `game/ai/`, vision adapters/tests | units, world transforms, occluders |
| UI contracts | `8.1-8.4`, `8.9-8.10` | `ui/` lifecycle/action plumbing and future presentation contracts | CommonUI load, lifecycle contract |
| Art/presentation | `9.6-9.10` | presentation-only animation/VFX/audio assets and presenters | event contracts from relevant domain |

Avoid parallel edits to `project.godot`, shared bootstrap, central IDs, tick
ordering or `ui/main.gd`. Schedule those changes as explicit integration tasks.

Exit gate: each domain passes its standalone headless contract before its UI or
visual polish is treated as integrated.

## Phase E — close the extraction loop

Tasks: `7.1-7.13`, then `8.5-8.11`.

Recommended order:

1. Raid phases, deployment identity and timer.
2. Level Task spike and `Supply Run` event flow.
3. Extraction and death settlement rules.
4. Profile atomic write/recovery and crash fixtures.
5. Summary projection from the authoritative audit/settlement record.
6. HUD, inventory, health, map, task, deploying and summary bindings.
7. Remove production mock-state access.

Exit gate: close/relaunch can complete both extract and death cycles without
duplicating or losing items outside the approved policy.

## Phase F — visual, combat and product acceptance

Tasks: `5.11-5.13`, `6.10`, `8.12-8.13`, `9.11`, `12.1-12.6`.

This phase is not a decorative cleanup. It validates that canonical systems are
legible to a player and that visual/audio prediction remains reversible.

Exit gate: automated evidence is green, ten settlement cycles pass, a fresh
player completes the loop without developer guidance, and the user signs off.

## Phase G — choose the next product branch

After task 12.6, choose one:

- create separate proposals for the smallest valuable meta systems from
  section 11; or
- begin section 10 only if add-on network hardening plus Windows/Linux gates
  have passed.

Do not combine full meta expansion and multiplayer into one change.

## Safe task packet

Every dispatched task should include:

```text
Task ID:
Model lane and effort:
Goal:
Allowed files/areas:
Dependencies confirmed:
Explicit non-goals:
Capability spec:
Required automated checks:
Required visual/process evidence:
Stop/escalate conditions:
```

Keep task IDs stable. If a task proves too large, add numbered children to this
ledger in a proposal revision instead of letting an implementation agent invent
an untracked subproject.

## Handoff format

An implementation handoff must report:

- outcome first;
- task ID completed or still blocked;
- changed files;
- commands and exact pass/fail counts;
- native screenshots, recordings or process logs when required;
- assumptions and remaining risks;
- next unblocked task IDs.

Only update a checkbox after the evidence exists. Partial implementation is
useful progress but remains unchecked and should be described in a progress
note rather than represented as complete.
