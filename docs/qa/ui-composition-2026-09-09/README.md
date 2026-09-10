# UI composition migration acceptance

UI-only implementation completed 2026-09-09 (Toronto), using pinned Godot
4.7.2, Compatibility renderer, Apple M4 Pro. Gameplay authority, `game/`,
vendored addons, platform artifacts and original assets were not edited by
this migration. UI fixtures remain previews, not production services.

## Automated results

| Suite | Checks | Failures |
| --- | ---: | ---: |
| CommonUI integration | 76 | 0 |
| UI composition / cancellation / retained HUD / drag | 109 | 0 |
| All-route repeated reflow | 756 | 0 |
| General UI | 920 | 0 |
| Inventory | 21 | 0 |
| Bunker / crafting / session | 21 | 0 |
| Raid UI | 29 | 0 |
| Utilities | 24 | 0 |
| Responsive behavior / pending dialogs | 96 | 0 |
| Compact inventory | 42 | 0 |
| Compact bunker | 40 | 0 |
| Compact frontflow | 107 | 0 |
| Compact utilities | 134 | 0 |
| Compact raid | 342 | 0 |
| Native border rendering | 135 | 0 |
| Native component states | 39 | 0 |
| **Total** | **2,891** | **0** |

The final import and test logs contain no script/runtime errors. All 111 UI
scene/script/theme files passed literal resource-path resolution (zero missing
references). F6-style standalone starts passed for main menu, HUD, settings and
the preview host. General UI counts increased from 814 because character route
wrappers now retain the shared authored sections; interaction checks were not
removed. Responsive assertions now require retained identity instead of the
previous route-remount behavior.

New regression coverage includes an arbitrarily named host, invalid and injected
canceled navigation, same HUD across pause/workspace/Back, nested modal input
suspension, F1 focus containment, one grid signal connection, retained search
focus/caret, active drag data across reflow, and three resize round trips on
every route without accumulating controls or retaining cropped HUD textures.

## Native review

Each contact sheet contains all 28 routes. Before/after captures cover four
automatic-layout sizes and forced compact at 1280×720: 140 baseline and 140
final route images. An additional 21 images cover component states and dialogs
at 1920×1080, 1280×720 and 960×540.

- [1920×1080](contact-1920x1080.png)
- [1600×900 desktop](contact-1600x900.png)
- [1280×720 desktop](contact-1280x720.png)
- [960×540 compact](contact-960x540.png)
- [1280×720 forced compact](contact-forced-1280x720.png)
- [Pressed card](960-pressed.png), [disabled and updated components](960-updated-disabled.png), [prompt](960-prompt.png)

Desktop composition is preserved. The largest per-frame mean luminance
difference is 0.100 on a 0–255 scale; no desktop frame has more than 0.301% of
pixels differing by over 16 levels. These metrics support visual review, not a
claim of pixel identity. See [per-route differences](capture-differences.json).

Intentional compact differences: the shared navigation/header remains present,
and character/bunker panes retain their authored sections instead of using a
second simplified builder. Tabs, scrolling and pinned actions keep these
sections reachable. Short compact labels avoid collisions without changing
desktop copy. Component hover/pressed visuals now render: native `flat` had
suppressed their authored styles. Disabled hit targets remain transparent so
they cannot obscure the component's content.

Native review also caught and fixed a missing Close-button rim, a desktop
power arc leaking into compact build mode, label overlaps and stale compact
HUD texture crops after returning to desktop.

## Full evidence and recovery

Full images, logs and the original project-owned snapshot are retained outside
the project at `/Volumes/Data/codes/games/zerkov-ui-backup.pdqYzi/`:

- `before.tar`: recoverable original UI, UI tests/tools and documentation.
- `baseline/` and `after/`: five layout sets, 28 images each.
- `component-states/`: normal, hover, pressed, selected/focus, updated/disabled,
  confirmation and prompt states at three sizes.
- `logs/`: final suites, import, standalone preview and native route runs.

The forced-compact baseline was rendered from the original UI snapshot in an
isolated temporary project. No original UI was restored over the working tree.
[capture-manifest.json](capture-manifest.json) records image dimensions and
SHA-256 values for the captures and recovery archive.

Implementation/API guide: [UI components](../../../ui/components/README.md).
Approved change: [UI composition](../../spec/changes/refactor-ui-composition-2026-09-09/tasks.md).
This evidence supports the UI portions of playable-raid tasks 8.1/8.2/8.10;
real projections, intents, production gating and gameplay acceptance remain
with that ongoing implementation. No broader gameplay task is marked complete.
