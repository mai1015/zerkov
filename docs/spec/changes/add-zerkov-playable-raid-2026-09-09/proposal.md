---
created_at: 2026-09-09T23:45:13Z
updated_at: 2026-09-10T19:52:55Z
---

## Why

Zerkov has a complete and verified UI prototype plus six extraction-shooter
add-ons, but it has no canonical game runtime. Implementing screens directly
against the current mock dictionary would create competing sources of truth
and make later multiplayer authority, persistence and recovery unsafe.

## What Changes

- Turn the existing Zerkov Godot project into the integrated product shell.
- Pin and load CommonUI, Common Vision, Gameplay Abilities, Inventory System,
  Level Task System and Weapon System without merging their codebases.
- Add a game-owned `RaidAuthority` with one 60 Hz tick, stable identities,
  fixed-unit conversion, world policy and ordered cross-addon adapters.
- Build one offline PvE Sawmill Yard raid with movement, interaction, loot,
  combat, injuries, AI perception, one task, extraction and death.
- Add an idempotent `RaidSettlementService` and atomic local `ProfileStore`.
- Replace UI mock state incrementally with immutable projections while
  preserving the approved Zerkov visual contract and compact layouts.
- Retain authority/replica seams from the beginning, but defer live co-op and
  PvP until add-on network hardening and Windows/Linux artifact gates pass.
- Add aspect-oriented tasks, model-routing guidance and evidence requirements
  so bounded work can be delegated safely to different Codex models.

## First-playable boundary

The slice includes Sawmill Yard, Road Gate, Oak Johnson, AKM, machete, a Scav,
a mutant, body-part health, heavy bleed, fracture, basic healing, loadout,
stash, crate/corpse loot, `Supply Run`, raid summary and persistent settlement.

It excludes PvP, matchmaking, insurance, marketplace, a full trader economy,
complete bunker progression, procedural maps, every weapon and cosmetic
variants.

## Impact

- Affected specs: runtime-foundation, world-player, inventory-equipment,
  combat-health, ai-perception, raid-progression, ui-presentation,
  multiplayer-release
- Affected code: `project.godot`, future `addons/`, future `game/`, existing
  `ui/`, selected runtime assets, tests and export configuration
- Affected data: new versioned content catalogs and profile/raid save envelopes
- Migration: current `app.state` remains available only as a temporary
  prototype fallback and is removed screen by screen after equivalent real
  projections pass their tests

Current implementation boundary: the reviewed inventory authority,
snapshot-projection seam, authority-side mutation routing (4.7a), equipped-item
reconciliation (4.8), inventory UI binding (4.7b), and ammunition/magazine
reload coordination (4.9), and inventory-to-ability equipment reconciliation
(4.10) are complete at the implementation/evidence level. The fresh independent
Astra checkpoint accepted task 4.10 with `21756/0` raw assertion executions.
The promoted reconciliation contract passed `546/0`; the independent real
add-on flow passed `451/0` headless and `463/0` in a visible native
Compatibility window, with four reviewed captures. The packet contains 17
distinct test programs, 18 execution variants and an 80-file evidence seal.

The game-owned adapter applies the revision-zero full snapshot and later
authoritative inventory changes in `RaidAuthority` phase 7, after phase-5
inventory commits. Accepted deltas provide bounded sequencing hints; grants and
revokes are derived from the current complete owner snapshot. Stable source-item
keys make duplicate snapshots, recorded/normalized replay and gap-healed full
reconciliation idempotent. AKM and machete equipment drive real native ability,
effect, tag and modifier state, while rig and backpack remain explicit no-grant
equipment. Task 4.11 is the next inventory task. Human approval remains false,
and the production weapon-instance/input work (5.2 and 5.7), later combat,
playtest, whole-game and release gates remain open.

The 4.10 boundary is offline, synchronous and in-memory. Unexpected ambiguous
native failure enters fail-stop recovery and may quarantine the captured
Gameplay Ability component. Native grant history is bounded at 64 records; the
65th grant fails preflight rather than recycling history. Until tasks 4.12/7.1
close the accepted P2 lifecycle follow-up, composition must release the adapter
or tear down its inventory owner/component before `RaidAuthority` terminalizes.
The final packet at
`docs/qa/inventory_ability_equipment/astra_final/REPORT.md` does not claim
automatic raid-terminal-first cleanup, production UI/input, human playtest or a
complete raid loop.

## Approval gate

Approval authorizes Stage 2 implementation of the checked tasks only. It does
not authorize multiplayer deployment, public release, destructive source-asset
changes, or expansion into the excluded meta systems.
