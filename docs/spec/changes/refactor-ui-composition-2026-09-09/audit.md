# UI structure audit

Reviewed on 2026-09-09 America/Toronto with the pinned Godot
`4.7.2.stable.official.ed1daf0bf` executable. No runtime or addon source was
changed during this audit. CodeGraph is absent and no CodeGraph MCP tools are
exposed in this session, so discovery used direct reads. The checkout also has
no `.git` directory; no Git diff or rollback baseline could be established.

## What is working

- All 28 route scenes load through a real `CommonUIScreenRoot`.
- Modal confirmations use `ZerkovDialog` on the CommonUI modal layer.
- Parallax is isolated in an authored component; navigation chrome already
  exposes semantic signals. These are useful foundations to preserve.
- Repeated cards and world rows are scene instances, and the desktop scenes
  contain substantial authored visual information.
- The existing native smoke checks pass. The problem is component ownership
  across interaction and layout changes, not a failure to load the addon.

## Findings

### 1. Inventory abandons its authored hierarchy after ordinary actions

Priority: high. `inventory_screen.gd` initially binds the scene, but inherits
`_refresh_body()` from [inventory.gd](../../../../ui/screens/inventory.gd).
At lines 855–875 it removes `InventoryContent`, creates a new Control, and calls
the old `_build_*` methods. `_set_filter()` calls this at lines 887–891; loot
mode and other interactions share the rebuild path.

The runtime probe opened inventory, retained its content instance ID, and
selected the guns filter. The original content was freed and the authored
`InventoryContent/SortStash` path disappeared. Editing the authored shell
therefore does not reliably affect the screen after a filter action. This is
more than a folder naming issue.

Fix: update filter state and the grid component in place. Share the same
authored sections between initial rendering, subsequent updates, and reflow.
Dynamic item counts still belong in a data-driven grid.

### 2. CommonUI hosts the screens, but does not own navigation history

Priority: high for gameplay integration. In
[main.gd](../../../../ui/main.gd), `screen_layer` is always `menu_layer()`
(line 42), `_drain_screen_mounts()` always calls `replace_screen()` (line 140),
and navigation history is a separate string array (lines 23, 148–169).
`current_route` changes before the asynchronous mount succeeds (line 157),
so a failed mount can also leave route bookkeeping ahead of the visible screen.

Runtime evidence: opening `hud` leaves HUD depth 0 and menu depth 1; opening
pause frees that HUD instance; Back creates a different HUD. This prevents
CommonUI from restoring the covered screen's local state and remembered focus.
The F1 picker is a manually created panel outside those layers (lines 292–325).

Fix: a route catalog declares scene, layer, presentation role, and navigation
operation. CommonUI owns the retained stack. The navigator publishes committed
route state after success, and covered screens resume without reconstruction.
Classify reset, workspace-tab replacement, and temporary push/pop explicitly.

### 3. Shared visuals are bypassed in compact layouts and resize handling

Priority: high for maintainability. The bunker family's
[layout_compact()](../../../../ui/screens/bunker.gd) (lines 503–518) selects a
panel by its x coordinate, removes the children, and builds another header.
Runtime evidence confirms `TopChrome` is absent after compact bunker layout.
[tasks_screen.gd](../../../../ui/screens/tasks_screen.gd) (lines 795–805) hides
the shared navigation and invokes another programmatic chrome builder.
Settings and Controls instead have separately authored `CompactHeader` nodes.

Resize completion in `main.gd` (lines 98–118) remounts the whole route. Invoking
that callback with QA mode disabled frees the current screen even when only a
layout refresh is needed. State retained in `app.state` may survive, but this
is not preservation of the screen, transient state, or focused controls.

Fix: let components own their desktop and compact arrangements and keep
content identity stable. Reflow uses named sections and containers, not
coordinate-based discovery. Same-layout window resizes only adjust scaling.

### 4. The project button is a factory alias, not a styling source of truth

Priority: medium. [zerkov_button.tscn](../../../../ui/components/zerkov_button.tscn)
contains six lines: an inherited CommonButton and `show_glyph = false`.
Its project appearance comes from `ZKit.button()` and the parent runtime theme.
Other component scenes instantiate the addon button directly, while navigation
attaches the addon script directly to authored Button nodes.

The 28-route desktop probe counted 65 CommonButton descendants and 492 other
Button descendants. That count includes repeated instances across routes; it
is not a count of unique component definitions. Native Godot buttons are valid
under CommonUI, so their mere presence is not a bug. The issue is that shared
styling and action conventions are split across scene overrides, `ZKit`, dialog
code, family helper functions, and screen-specific styling passes.

Fix: an authored project theme and named variants, consumed by both scene
instances and dynamic factories. Use the project CommonButton for semantic
actions while retaining appropriate native inputs and specialized controls.
Keep the existing pixel-border adapter in one shared theme integration layer.

### 5. Component callers still own internal nodes and interaction styling

Priority: medium. `menu_action_card.gd` sets its exports into labels only in
`_ready()` (lines 13–29). Updating `card_title` after mounting did not update
the visible label in the probe. It also lacks `@tool`, so the exported instance
copy is not reflected by this script in the editor.

[main_menu.gd](../../../../ui/screens/main_menu.gd) directly edits
`MenuContinue/Title` and `Subtitle` and wires each card's `Hit` and title focus
colors (lines 28–33, 58–78, 99–114). `world_row.tscn` has no controller/API;
[saves.gd](../../../../ui/screens/saves.gd) owns its internal labels, hit target,
selection styles, and geometry. `top_chrome.gd` preserves duplicate label aliases
for four consumers, rather than exposing one header model.

Fix: stable public configuration, semantic signals, and a focus-target accessor.
Components render their own states; feature screens bind data and intent.
Use editor-safe setters for values that should preview in the Inspector.

### 6. Large family bases mix unrelated responsibilities and require Main

Priority: medium. `inventory.gd` is 1,179 lines, `utility.gd` 1,081,
`bunker.gd` 695, `frontflow.gd` 658, and `raid.gd` 427. They mix fixture data,
state changes, layout factories, input, routing, and feature-specific callbacks.
Concrete scene controllers inherit these bases, so apparently small screens
still depend on a large cross-feature implementation.

[ui_screen.gd](../../../../ui/ui_screen.gd) line 10 hard-codes `/root/Main`.
Running `main_menu.tscn` directly produced `Node not found: "Main"` followed by
an invalid `current_route` access on null in `main_menu.gd:11`. This limits
isolated runtime preview and testing; it does not mean the scene cannot be
opened in the Godot layout editor.

Fix: a small screen lifecycle base, explicitly supplied UI services, feature
controllers, and fixture providers with a dedicated preview host. Keep fixture
state separate from future authoritative gameplay state.

## Verification performed

Executable: `/Volumes/Data/sdk/godot/editors/4.7.2/Godot.app/Contents/MacOS/Godot`.

| Check | Observed result |
| --- | --- |
| `--headless --path . --script res://tests/common_ui_integration_smoke.gd` | 76 checks, 0 failures |
| `--headless --path . --script res://tests/ui_smoke.gd` | 814 checks, 0 failures; all 28 routes visited |
| `--headless --path . res://ui/screens/main_menu.tscn --quit-after 6` | Runtime errors described above; process returned 0 |
| Temporary structural probe, using the project main scene | Results below |

```text
PROBE hud: hud_depth=0 menu_depth=1
PROBE pause: original_hud_alive=false
PROBE resume: original_hud_restored=false
PROBE inventory: authored_sort_present=true common_button=false
PROBE inventory_filter: original_surface_alive=false authored_sort_path_present=false
PROBE resize_reflow: original_screen_alive=false
PROBE menu_card: exported_title_updates_label=false
PROBE compact_bunker: shared_top_chrome_present=false
PROBE desktop_route_button_totals: common=65 other=492
PROBE other_button_classes: { "Button": 492 }
```

The temporary diagnostic source is
`/tmp/zerkov-ui-structure.8f3JbC/probe.gd`; it can be rerun with
`--headless --path . --script /tmp/zerkov-ui-structure.8f3JbC/probe.gd`
while that temporary file remains available. It only exercises local prototype
UI state. It is audit evidence, not a production test or part of the migration.

The integration tests currently check initial component presence and successful
replacement, including the one-screen menu depth expectation at lines 84–98.
They do not establish component retention after filtering, pause/resume, or
reflow. Future tests must distinguish intentional replacement from temporary
covering instead of requiring depth 1 for every operation.

This audit did not rerun all compact suites, border rendering, or native visual
captures. No claim of new visual validation is made. Those are implementation
acceptance gates in the accompanying proposal.
