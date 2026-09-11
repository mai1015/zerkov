# Inventory 1080p Preservation Baseline

Status: accepted as the visual baseline for task 4.11; this is not acceptance
of task 4.11 or of the playable raid.

Audit basis: native Godot 4.7.2 captures of the UI tree at commit `963d801`.
The later `c84c13f` commit changes specification documents only and does not
change the audited interface.

## Product surface to extend

The `inventory`, `health`, and `stats` routes share
`ui/screens/character/character_workspace.tscn`. Task 4.11 MUST extend that
workspace and its existing `Loot` tab; it MUST NOT add a replacement inventory
route or a parallel full-screen loot interface.

At 1920x1080, preserve:

- the shared navigation, raid backdrop, typography, borders, orange selection
  treatment, status strip, and bottom interaction hints;
- the left character column with Gear, Health, and Stats tabs;
- the middle loadout with pockets, rig, backpack, and quick-use slots;
- the right Stash/Loot pane with tabs, search, filters, sorting, organizing,
  and the existing inventory grid;
- 74-pixel inventory cells and canonical container dimensions rather than a
  visually invented capacity;
- selection, hover/focus inspection, drag/drop, rotation, quick transfer,
  split/merge, focus, search caret, and scroll continuity across confirmed
  snapshots;
- honest fixture, placeholder, unavailable-action, disconnected, stale,
  rejected, overweight, and resynchronizing disclosures.

The intended extension points are:

- `ui/screens/character/character_workspace.tscn`
- `ui/screens/character/character_screen.gd`
- `ui/screens/character/inventory_actions.gd`
- `ui/screens/character/components/inventory_grid.gd`

Open/search/close behavior and loot-container state belong inside the existing
right-hand Stash/Loot pane. Search, selection, and inspection remain
presentation-only; canonical changes continue through the accepted inventory
intent and snapshot seams.

## Current findings

- No P0 or P1 defect was found in the requested inventory preservation audit.
- P2: Stats micro-metric captions and values touch or overlap at 1920x1080.
- P2: catalog `QA_COMPLETE` does not itself aggregate unrelated engine/script
  errors, so logs remain a required gate even when the catalog reports zero.
- P3: a transient notification overlaps the unavailable quick-use row for
  approximately 3.5 seconds.

These are existing presentation debts, not reasons to replace the workspace.
Smaller layouts are deferred by the approved 1920x1080 display-scope decision.

## Fresh evidence

- Native catalog: 28 screens, zero missing/capture errors.
- Inventory smoke: 21 checks, zero failures.
- Inventory UI binding: 138 checks, zero failures.
- Live capture harness: 140 checks, zero failures; its 1080p states included
  native drag and quick-transfer, each emitting exactly one request.
- No current GDScript parse/runtime errors were observed.
- No tracked `LootDiscovery`, `loot_discovery`, `RECIPIENT PROJECTION`, or
  `DISCLOSURE MAP` replacement UI was found under `ui/`.

The audit produced temporary captures and logs under
`/tmp/zerkov-inventory-main963d801.k48hsV`. They are diagnostic artifacts, not
shipped evidence or human playtest approval.
