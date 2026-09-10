---
created_at: 2026-09-09T23:45:13Z
updated_at: 2026-09-10T14:02:26Z
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
reconciliation (4.8), and inventory UI binding (4.7b) are complete. The fresh
independent Astra checkpoint accepted 31 final suite/probe variants with
`4228/0` checks/failures across 1920x1080, 1600x900, 1280x720 and 960x540;
continuous native flow passed `88/0`, compact continuity `34/0` plus promoted
selection `37/0`, sealed regressions `18/0` and `17/0`, and the independent
challenge `112/0`. Task 4.9 is the next unblocked inventory task. Human approval
remains false, and later animation, combat/readability, cursor-mapping,
human-playtest, whole-game and release gates remain open.

## Approval gate

Approval authorizes Stage 2 implementation of the checked tasks only. It does
not authorize multiplayer deployment, public release, destructive source-asset
changes, or expansion into the excluded meta systems.
