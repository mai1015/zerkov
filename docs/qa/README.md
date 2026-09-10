# Native UI verification

Verified using Godot 4.7.2, Compatibility renderer, Apple M4 Pro.

## UI composition migration — 2026-09-09

The [current UI-only acceptance report](ui-composition-2026-09-09/README.md)
records 2,891 passing checks, retained screen/component regressions, all 28
routes across five native layout sets, and component-state captures. The
historical reports below predate the feature-folder and CommonUI lifetime
reorganization.

## Border rendering fix — 2026-09-08

The missing weapon-slot top edges and Close button's left edge were reproduced at 1600×900 but not at native 1920×1080. Fractional canvas downscaling made 1px square border polygons thinner than an output pixel. A shared `pixel_style.gd` adapter now draws output-aligned border strips at a minimum of one physical pixel, retaining native StyleBoxFlat drawing at 1080p and above. All screen-family border factories use it; layout margins, colors, hover/focus states and the 1600×900 launch size stay unchanged. Grid strokes are pixel-aligned and the last row/column is inside the grid rectangle, including when its parent clips content.

The graphical `border_render_smoke.gd` suite passes 135/135 checks across 1920×1080, 1600×900, 1366×768, 1280×720 and 1440×900. It compares rendered pixels with/without the normal borders on Close and all four gear weapon slots, requiring continuous edges, then checks all four outer edges and both dividers of an empty grid in an exact-size clipping parent. Letterbox offsets are excluded from render-target pixel coordinates. This test deliberately rejects headless execution.

Existing regression suites also pass: UI 817, responsive 72, and compact-family checks 645. Updated evidence: [1080p inventory](borders-1080/inventory.png), [1600×900 inventory](borders-900/inventory.png), [1280×720 inventory](borders-720/inventory.png). The default-window route captures in `desktop-default/` are refreshed for this fix.

Engine reference: [StyleBoxFlat drawing](https://github.com/godotengine/godot/blob/master/scene/resources/style_box_flat.cpp) skips its antialiasing path for square, unskewed corners. The installed Compatibility renderer also reports that 2D MSAA is unsupported, so the fix does not enable it or change renderer.

## PC-first update — 2026-09-08

Play now opens at 1600×900 with the approved desktop composition. Windows at least 1280×720 keep the 1920×1080 logical canvas and its original columns; only smaller windows automatically reflow. `--layout=compact` explicitly reviews the fallback without changing normal Play behavior.

The default launch was captured through all 28 routes with no missing screens or capture errors. See the current [desktop inventory](desktop-default/inventory.png), [settings](desktop-default/settings.png), [main menu](desktop-default/main_menu.png), and [bunker](desktop-default/bunker.png). All 28 default-window captures are in `desktop-default/`. The earlier `720/` images below show the now-optional compact version, not the current default PC layout.

Regression checks: UI 817/817; PC breakpoint/live resize 72/72; explicitly selected compact suites 645/645 (inventory 42, bunker 40, frontflow 107, utility 134, raid 322). The resize test checks both sides of the exact 1280×720 breakpoint, 1600×900 default, 1440×900 and 1280×800 letterboxing, 1920×1080 restoration, preserved state, and resize-safe dialogs. Historical results below document the preceding full implementation and compact pass.

## Results

| Suite | Checks | Failures |
| --- | ---: | ---: |
| UI routes, resources, wired controls, navigation, dialogs and world management | 817 | 0 |
| Inventory transfer, bounds, compatibility, containers and healing | 21 | 0 |
| Bunker, build, crafting queue and session state | 21 | 0 |
| Raid feedback, settings integration, reload, extraction and readiness | 29 | 0 |
| Utility settings, maps, tasks and binding conflicts | 24 | 0 |
| **Total** | **912** | **0** |

The editor import/parse check completed without script errors. Native capture runs instantiated all 28 routes at 1920×1080, 1280×720 and 960×540, with zero missing-screen or capture errors. The small-window captures now show adaptive layouts, not the earlier uniformly scaled interface. Screenshots were captured from the Godot viewport, not an HTML renderer. Visual review checked the approved composition, art crops, typography, active states and obvious overlaps; it is not a pixel-difference certification.

## Small-window regression

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

Family suites exercise 1280×720 and 960×540. Live-resize checks additionally cover 1280×800, 1440×900 and restoration to 1920×1080. Dialogs keep their callback owner alive during resizing; the pending screen reflow occurs after dismissal. Native wheel and mouse tests verify that scrolling does not make primary actions inaccessible.

Run commands are in the [project README](../../README.md). Test sources are under [tests](../../tests/). Some assertions use native mouse/key events; others inspect local state and call control callbacks directly. They do not test actual gameplay or network services.

## Captures

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
- The 1920×1080 reference layout is retained for normal PC windows (at least 1280×720). Below that threshold, native-sized controls, section tabs and bounded scrolling are available down to 960×540. This is not a phone UI; inventory grids and the region map may scroll or pan within their own panes.
- Controls rebindings are editable mock UI state, not a gameplay input-map implementation.
- Layout nodes are assembled in GDScript; use `ui/main.tscn` for routing/state and F1 for the catalog.
