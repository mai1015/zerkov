---
created_at: 2026-09-09T23:45:13Z
updated_at: 2026-09-10T16:49:50Z
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
reload coordination (4.9) are complete at the implementation/evidence level.
The fresh independent Astra checkpoint accepted task 4.9 with `20750/0` raw
assertion executions. Its promoted catalog and reload contracts passed
`537/0` and `159/0`; the independent canonical capacity challenge passed
`33/0`; the real-add-on flow passed `208/0` headless and `213/0` in the native
Compatibility window, where the native run repeats the 208 core assertions and
adds five capture checks. The packet contains 17 distinct test programs and 18
execution variants. The canonical flow reserves 27 rounds in exact
magazine-to-rig-to-pockets order, cancels and replays without changing
quantities, then commits to 30 loaded rounds with a conserved total of 41.
Task 4.10 is the next implementation task. Human approval remains false, and
the production weapon-instance/input work (5.2 and 5.7), later combat,
playtest, whole-game and release gates remain open.

The 4.9 boundary is offline, synchronous, in-memory, single-writer/no-yield
coordination. It does not claim crash-safe symmetric two-phase commit because
the installed WeaponAuthority facade exposes no public rollback participant; it
also does not claim physical detachable-magazine identity or swapping. Those
limits, plus the native validation harness being distinct from production UI
and human playtest, are recorded in the final Astra packet at
`docs/qa/inventory_weapon_reload/astra_final/REPORT.md`.

## Approval gate

Approval authorizes Stage 2 implementation of the checked tasks only. It does
not authorize multiplayer deployment, public release, destructive source-asset
changes, or expansion into the excluded meta systems.
