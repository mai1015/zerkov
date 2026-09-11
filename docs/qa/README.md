# Native UI verification

Verified using Godot 4.7.2, Compatibility renderer, Apple M4 Pro.

## Current acceptance scope — exact 1920×1080 only

Current first-playable UI/navigation/lifecycle/composition/reflow/component,
border, inventory-binding and crawler verification runs at exact 1920×1080 only. Existing smaller
PNG files, logs, reports and dedicated responsive/compact sources remain
historical audit artifacts; current agents, runners and tests MUST NOT invoke
or regenerate them until task 11.8 or a later approved display-support
proposal. The new scope-enforcement results are in
[`1080-only-scope.md`](1080-only-scope.md). Prior accepted task 8.1/8.2 source
seals remain immutable evidence for their recorded commits and are not current
aggregate checks.

## UI composition migration — 2026-09-09

The [retained UI-only acceptance report](ui-composition-2026-09-09/README.md)
records 2,891 passing checks, retained screen/component regressions, all 28
routes across five historical native layout sets, and component-state captures.
It is not the current smaller-resolution matrix. The historical reports below
predate the feature-folder and CommonUI lifetime reorganization.

## Border rendering fix — 2026-09-08 (historical packet)

The missing weapon-slot top edges and Close button's left edge were reproduced at
a smaller historical output but not at native 1920×1080. Fractional canvas
downscaling made 1px square border polygons thinner than an output pixel. A
shared `pixel_style.gd` adapter now draws output-aligned border strips at a
minimum of one physical pixel, retaining native StyleBoxFlat drawing at 1080p
and above. All screen-family border factories use it; layout margins, colors,
hover/focus states and the historical launch-size behavior stay unchanged.
Grid strokes are pixel-aligned and the last row/column is inside the grid
rectangle, including when its parent clips content. The recorded
multi-resolution run is historical; the current border entry point is exact
1920×1080-only.

The graphical `border_render_smoke.gd` suite's recorded 135/135 checks cover
the historical matrix. It compares rendered pixels with/without the normal
borders on Close and all four gear weapon slots, requiring continuous edges,
then checks all four outer edges and both dividers of an empty grid in an
exact-size clipping parent. Letterbox offsets are excluded from render-target
pixel coordinates. This test deliberately rejects headless execution; current
runs use exact 1920×1080 only.

Existing historical regression suites also pass: UI 817, responsive 72, and
compact-family checks 645. Updated historical evidence: [1080p inventory](borders-1080/inventory.png), [smaller inventory](borders-900/inventory.png), [another historical inventory](borders-720/inventory.png). The default-window route captures in `desktop-default/` are retained; current agents/tests MUST NOT regenerate the smaller artifacts.

Engine reference: [StyleBoxFlat drawing](https://github.com/godotengine/godot/blob/master/scene/resources/style_box_flat.cpp) skips its antialiasing path for square, unskewed corners. The installed Compatibility renderer also reports that 2D MSAA is unsupported, so the fix does not enable it or change renderer.

## PC-first update — 2026-09-08 (historical packet)

The historical packet recorded Play opening at a smaller desktop size with the
approved composition, with the 1920×1080 logical canvas and compact reflow
available. That behavior remains compatibility code, but current Play and
verification use exact 1920×1080. The explicit compact override is deferred and
MUST NOT be used for current acceptance.

The historical default launch was captured through all 28 routes with no
missing screens or capture errors. See the retained [desktop inventory](desktop-default/inventory.png), [settings](desktop-default/settings.png), [main menu](desktop-default/main_menu.png), and [bunker](desktop-default/bunker.png). All 28 default-window captures are in `desktop-default/`; the earlier small-window images below are retained history, not current output.

Historical regression checks: UI 817/817; PC breakpoint/live resize 72/72;
explicitly selected compact suites 645/645 (inventory 42, bunker 40, frontflow
107, utility 134, raid 322). Historical results below document the preceding
full implementation and compact pass; current acceptance MUST NOT rerun these
smaller suites.

## Results

| Suite | Checks | Failures |
| --- | ---: | ---: |
| UI routes, resources, wired controls, navigation, dialogs and world management | 817 | 0 |
| Inventory transfer, bounds, compatibility, containers and healing | 21 | 0 |
| Bunker, build, crafting queue and session state | 21 | 0 |
| Raid feedback, settings integration, reload, extraction and readiness | 29 | 0 |
| Utility settings, maps, tasks and binding conflicts | 24 | 0 |
| **Total** | **912** | **0** |

The historical editor import/parse check completed without script errors.
Historical native capture runs instantiated all 28 routes across multiple
outputs, with zero missing-screen or capture errors. Those screenshots were
captured from the Godot viewport, not an HTML renderer. Visual review checked
the approved composition, art crops, typography, active states and obvious
overlaps; it is not a pixel-difference certification. Current reruns are exact
1920×1080 only.

## Small-window regression (historical/deferred)

The user's small-window feedback prompted native-pixel layouts, scrolling panes, fixed actions and compact section tabs. Shared adaptive-pane primitives follow the project design system. Additional tests pass:

| Suite | Checks | Failures |
| --- | ---: | ---: |
| Inventory panes, 74px cells, wheel, search, transfers and tooltip bounds | 42 | 0 |
| Bunker, crafting, session and build compact actions / scrolling | 40 | 0 |
| Frontflow scrolling, keyboard focus, world CRUD and joining | 107 | 0 |
| Utility panes, values, binding capture, tab navigation and scroll restoration | 134 | 0 |
| HUD anchors, detail panes, summaries and raid feedback | 322 | 0 |
| Live resize, dialog lifetime/input, catalog and notification bounds (original compact policy) | 47 | 0 |
| **Additional total (2026-09-07)** | **692** | **0** |

Family suites historically exercised smaller outputs. Live-resize checks also
covered alternate letterboxing and restoration to 1920×1080. Dialogs keep their
callback owner alive during resizing; the pending screen reflow occurs after
dismissal. Native wheel and mouse tests verify that scrolling does not make
primary actions inaccessible. Current agents/tests MUST NOT invoke this
section's suites until task 11.8 or a later approved display-support proposal.

Run commands are in the [project README](../../README.md). Test sources are under [tests](../../tests/). Some assertions use native mouse/key events; others inspect local state and call control callbacks directly. They do not test actual gameplay or network services.

## Captures (historical; retained without regeneration)

| Screen | 1920×1080 | 1280×720 | 960×540 |
| --- | --- | --- | --- |
| Title | [View](1080/title.png) | [View](720/title.png) | [View](960/title.png) |
| Main menu | [View](1080/main_menu.png) | [View](720/main_menu.png) | [View](960/main_menu.png) |
| Worlds / saves | [View](1080/saves.png) | [View](720/saves.png) | [View](960/saves.png) |
| Join a friend | [View](1080/join_friend.png) | [View](720/join_friend.png) | [View](960/join_friend.png) |
| Bunker session | [View](1080/session.png) | [View](720/session.png) | [View](960/session.png) |
| Bunker stations | [View](1080/bunker.png) | [View](720/bunker.png) | [View](960/bunker.png) |
| Build mode | [View](1080/build_mode.png) | [View](720/build_mode.png) | [View](960/build_mode.png) |
| Crafting | [View](1080/crafting.png) | [View](720/crafting.png) | [View](960/crafting.png) |
| Deploying | [View](1080/deploying.png) | [View](720/deploying.png) | [View](960/deploying.png) |
| Full solo HUD | [View](1080/hud.png) | [View](720/hud.png) | [View](960/hud.png) |
| Full co-op HUD | [View](1080/hud_coop.png) | [View](720/hud_coop.png) | [View](960/hud_coop.png) |
| HUD detail study | [View](1080/hud_detail.png) | [View](720/hud_detail.png) | [View](960/hud_detail.png) |
| Inventory / gear | [View](1080/inventory.png) | [View](720/inventory.png) | [View](960/inventory.png) |
| Health | [View](1080/health.png) | [View](720/health.png) | [View](960/health.png) |
| Stats / skill rulers | [View](1080/stats.png) | [View](720/stats.png) | [View](960/stats.png) |
| Maps | [View](1080/maps.png) | [View](720/maps.png) | [View](960/maps.png) |
| Tasks | [View](1080/tasks.png) | [View](720/tasks.png) | [View](960/tasks.png) |
| Settings | [View](1080/settings.png) | [View](720/settings.png) | [View](960/settings.png) |
| Controls | [View](1080/controls.png) | [View](720/controls.png) | [View](960/controls.png) |
| Pause | [View](1080/pause.png) | [View](720/pause.png) | [View](960/pause.png) |
| Solo summary | [View](1080/summary_solo.png) | [View](720/summary_solo.png) | [View](960/summary_solo.png) |
| Squad summary | [View](1080/summary_squad.png) | [View](720/summary_squad.png) | [View](960/summary_squad.png) |
| Crosshair studies | [View](1080/crosshairs.png) | [View](720/crosshairs.png) | [View](960/crosshairs.png) |
| Status effects | [View](1080/status_icons.png) | [View](720/status_icons.png) | [View](960/status_icons.png) |
| Squad list | [View](1080/squad_list.png) | [View](720/squad_list.png) | [View](960/squad_list.png) |
| Reload ring | [View](1080/reload.png) | [View](720/reload.png) | [View](960/reload.png) |
| Empty magazine | [View](1080/mag_empty.png) | [View](720/mag_empty.png) | [View](960/mag_empty.png) |
| Component states | [View](1080/showcase.png) | [View](720/showcase.png) | [View](960/showcase.png) |

## Scope and intentional placeholders

- The approved handoff guided the shared colors, fonts, sizing and native components.
- All actions are local UI demonstrations. State resets when the app closes. World/save names are not real disk saves; invites, account status, insurance and loot values do not contact a service.
- No combat, character movement, world simulation, real crafting economy or multiplayer is included. HUD damage, ammo, reload and readiness are preview transitions.
- The map, station-art slots and magazine/backpack placeholders follow the supplied mockup. Imported production originals remain available for subsequent art replacement.
- Insurance claims, marketplace/trading and character customization were not designed in the handoff; they remain outside the screen set.
- The 1920×1080 reference layout is the current first-playable target. Existing
  native-sized controls, section tabs and bounded scrolling below it remain
  retained compatibility behavior and are deferred from current acceptance.
- Controls rebindings are editable mock UI state, not a gameplay input-map implementation.
- Layout nodes are assembled in GDScript; use `ui/main.tscn` for routing/state and F1 for the catalog.
