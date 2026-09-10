# Zerkov System Plan

Status: **Stage 1 proposal — implementation is not yet approved.**

## Outcome

Turn the existing native Godot UI prototype into the product shell for a
server-authority-shaped 2D extraction shooter. The first playable is a focused
offline PvE Sawmill Yard raid; co-op and PvP follow only after network and
platform release gates are satisfied.

## First playable

- One Sawmill Yard map and one Road Gate extraction
- Oak Johnson with movement, mouse aim, collision and interaction
- AKM plus machete
- One Scav behavior and one mutant behavior
- Head, torso, arms and legs health
- Heavy bleed, fracture, bandage and splint
- Pockets, rig, backpack, stash, one searchable crate and corpse loot
- One raid-scoped `Supply Run` objective
- Extract and death/loss settlement
- Atomic local profile persistence
- Real raid events powering the existing HUD and solo summary

The first playable intentionally excludes PvP, insurance, marketplace, full
trader economy, complete bunker progression, matchmaking, procedural levels,
all weapons, and cosmetic variants.

## Architecture

```text
CommonUI / player input
          |
          v
     validated intents
          |
          v
RaidAuthority -- one canonical 60 Hz tick
|-- MovementWorld2D
|-- InventoryAuthority <-> InventoryWeaponAdapter
|-- WeaponAuthority -> WeaponCombatAdapter -> world hit resolution
|-- GameplayAbility components <- damage/healing/status consequences
|-- CommonVisionWorld2D -> AI perception and relevance
|-- LevelTask runtime <- ordered raid events
`-- Raid audit stream
          |
          |-- immutable UI projections
          `-- RaidSettlementService -> ProfileStore
```

No sibling add-on directly mutates another sibling. Zerkov owns every adapter,
authorization decision, cross-domain identity and consequence order.

## Delivery order

1. Pin and load the add-ons; freeze IDs, units and tick rules.
2. Build a playable Sawmill test yard with movement and interaction.
3. Add authoritative shooting, damage, health and one perceiving enemy.
4. Add canonical inventory, equipment, loot and reload reservations.
5. Complete the raid timer, task, extraction/death and profile settlement.
6. Bind each existing UI screen to real immutable projections.
7. Expand bunker, crafting and trader systems after the raid is fun.
8. Add co-op after security hardening and Windows/Linux artifacts pass.

## Detailed documents

- [Proposal](spec/changes/add-zerkov-playable-raid-2026-09-09/proposal.md)
- [Architecture and design decisions](spec/changes/add-zerkov-playable-raid-2026-09-09/design.md)
- [Tasks by aspect](spec/changes/add-zerkov-playable-raid-2026-09-09/tasks.md)
- [Execution order and parallel work](spec/changes/add-zerkov-playable-raid-2026-09-09/workstreams.md)
- [Codex model routing](spec/changes/add-zerkov-playable-raid-2026-09-09/model-routing.md)

The capability acceptance requirements are under the change's `specs/`
directory. Implementation starts only after this package is reviewed and
approved.
