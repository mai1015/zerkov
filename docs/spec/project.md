# Project Overview

## Product

Zerkov is a PC-first top-down 2D extraction shooter. The initial playable slice
is an offline PvE Sawmill Yard raid built with the same authority boundaries
needed for later co-op and PvP.

The product loop is:

```text
bunker/stash -> choose loadout -> deploy -> move/loot/fight/task
             -> extract or die -> settle profile -> return to bunker
```

## Tech stack

- Engine: Godot 4.7.x, Compatibility renderer
- Game and presentation code: typed GDScript
- Reusable authoritative domains: C++ GDExtensions
- Initial development target: macOS
- Intended shipping client: Windows x86_64
- Intended dedicated-server target: Linux x86_64
- UI design canvas and current acceptance target: exact 1920x1080. Existing
  compact fallback code is retained for compatibility, but smaller-output
  execution and capture review are deferred until task 11.8 or a later approved
  display-support proposal.
- Proposed world render surface: low-resolution `SubViewport`, validated by a
  dedicated pixel-scale spike before it becomes a contract

## Add-on baseline

| Add-on | Baseline | Initial use |
| --- | --- | --- |
| CommonUI | 0.1.2 | input contexts, screen stacks, focus, rebinding |
| Common Vision | 0.1.0 | AI sight/memory and later recipient relevance |
| Gameplay Abilities | 0.2.0 | health, stamina, injuries, healing and status |
| Inventory System | 0.4.0 | stash, equipment, carried loot and world containers |
| Level Task System | 0.1.0 pre-release | one raid-scoped objective pilot |
| Weapon System | 0.1.0 | firearm mechanics, recoil, reload and attachments |

Exact copied source revisions and native artifact hashes must be recorded in a
project-owned lock manifest before implementation depends on them.

## Conventions

- Authoritative raid time advances at one game-owned 60 Hz integer tick.
- Stable content identifiers use lower-case dotted namespaces, for example
  `zerkov.weapon.akm` and `zerkov.task.sawmill.supply_run`.
- Fixed-unit conversion is centralized; add-ons do not independently convert
  Godot pixels or floating-point world values.
- The UI keeps the visual contract in `DESIGN.md` and receives data through
  read-only view models.
- Current `app.state` data is prototype-only and is replaced screen by screen;
  it is never promoted into canonical gameplay storage.
- Tests use Godot headless contract scenes where possible. Visual and combat
  feel gates use captured frames plus human playtesting.
- Network-facing work fails closed and is not accepted without hostile-input,
  disconnect, resynchronization, and reconnect evidence.
- Shipping support is claimed only after the exact artifact builds, loads,
  exports, and passes role-appropriate tests.

## Current change

The initial system build is proposed under
`docs/spec/changes/add-zerkov-playable-raid-2026-09-09/`.
