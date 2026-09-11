# Astra native visual audit — 2026-09-10

## Outcome

Visual acceptance remains open. The audited recovery state is an interactive UI
prototype with real inventory-domain behavior, not a playable offline raid.
No P0 issue was found. Three P1 integration/layout failures prevent promotion.

Audited recovery commit: `ce777d8` (`recovery/main-mixed-2026-09-10`)

Runtime: Godot `4.7.2.stable.official.ed1daf0bf`, Compatibility renderer.
The audit made no source changes. Its temporary native captures and logs were
written under `/tmp/zerkov-visual-audit.KCmmk1`; that directory is diagnostic
working evidence, not a permanent acceptance packet.

## P1 findings

1. `ui/screens/character/components/character_layout.gd` fails type inference
   while loading the character screen. At 960x540, Inventory, Health, and Stats
   retain cropped desktop geometry with important content offscreen.
2. The recovery loot surface applies full-rect layout while embedded, covering
   the existing character, navigation, loadout, and inventory composition. It
   must not replace the designed inventory UI.
3. The standalone compact loot surface overflows vertically at 960x540. Revealed
   items and Transfer become unreachable without scrolling, and Close overlaps
   content.

## P2 findings

- Rebuilding loot rows destroys semantic keyboard/controller focus.
- Main-menu activation focuses Switch Account while the visible CTA advertises
  Enter/Continue; repeated Enter opens a disabled-feature toast.
- Compact Tasks count badges intrude into objective detail.
- Fixture/online/controller disclosures are inconsistent with observed runtime
  state.

## Evidence reliability

The four-resolution catalog produced 112 PNG files and printed a green
`QA_COMPLETE` marker while Godot logged character compilation/runtime errors.
Catalog success is therefore insufficient unless diagnostics are scanned.

The original loot harness is stale: it calls rejected arbitrary-time APIs and
removed test setters, then labels incomplete states as indexed/revealed. Those
captures are historical only. A temporary authority-clock diagnostic reached
the current states with `376/0` checks, but it does not replace task acceptance.

The isolated 640x360 integer-fit renderer remains crisp and passed `1292/0`,
but it is not yet wired into the production raid path.

## Product direction and open gates

- Finish inventory persistence/capability work before loot presentation.
- Extend the existing designed inventory grids and interaction language; do not
  ship a separate replacement inventory or developer-console loot screen.
- Preserve character/loadout/navigation, compact reachability, and semantic
  focus when live projections update.
- Keep tasks 4.11, 5.13, 8.12, 8.13, 12.4, and 12.5 open. Model/native captures
  do not replace the required human playtest and product approval gates.
