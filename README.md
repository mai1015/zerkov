# Zerkov

Native Godot 4 project combining the approved Zerkov UI with the Stage 2
playable-raid implementation. Open `project.godot` and press **F6** on
`ui/main.tscn`, or **F5** to run the current product shell. Start at the title
screen and press any key.

The checked-in screens are still driven primarily by prototype data while the
approved offline Sawmill gameplay slice is integrated. Multiplayer, economy
and expanded bunker systems remain outside the active slice.

## Review controls

| Key | Action |
| --- | --- |
| F1 | Open the complete screen catalog |
| Esc | Back, dismiss overlay, or pause |
| Tab | Open/close inventory in the raid and bunker |
| M | Open maps |
| J | Open tasks |
| R | Preview reload in the raid |
| H | Preview low health in the raid |
| X | Preview extraction / raid summary |
| Y | Preview healing in the raid / health UI |
| LMB | Preview ammo use and crosshair feedback in the raid |

Full screens live under `ui/screens/<feature>/`; the seven review studies live under `ui/dev/screens/`. The F1 catalog includes all 28 stable route IDs, health/stats variants and the component-state showcase. Insurance claims, trading/marketplace, and character customization were explicitly not designed in the supplied handoff and are outside this implementation.

## Structure

- `addons/`: locked CommonUI, Vision, Gameplay Abilities, Inventory, Level Task
  and Weapon snapshots; see `config/addons.lock.json`.
- `ui/main.tscn` / `main.gd`: stable UI bootstrap, viewport fitting and native QA facade.
- `ui/core/`: supplied screen context, explicit route catalog, committed CommonUI navigation, feedback and reversible layout support.
- `ui/theme/`: authored `zerkov_theme.tres`, palette/fonts, button variants and the pixel-aligned border adapter.
- `ui/screens/{frontflow,bunker,character,utilities,raid}/`: feature-owned scenes, bindings and local components. Inventory/health/stats inherit one character workspace.
- `ui/components/{controls,layout,feedback,backgrounds}/`: cross-feature components with configuration and semantic signals; see [component APIs and extension examples](ui/components/README.md).
- `ui/dev/`: fixture state/data, isolated preview host, F1 catalog and seven visual studies. These remain UI previews, not gameplay authority.
- `ui/shaders/`: world-backdrop blur, leaving interface text sharp.
- `assets/handoff/`: all approved handoff images.
- `assets/original/`: scoped originals, including inventory, weapons, ammo, bunker and UI sprites.
- `assets/fonts/`: Chakra Petch and IBM Plex Mono, with their OFL licenses.
- `DESIGN.md`: design contract, tokens, states and verification approach.
- `docs/ASSETS.md`: complete asset provenance and mapping.
- `docs/DEVELOPMENT.md`: pinned engine/toolchain, add-on update workflow and
  foundation verification commands.

PC is the primary target. Play defaults to a 1600×900 window showing the approved 1920×1080 composition, proportionally fitted without changing its columns or panels. Normal PC windows (1280×720 and larger) use this desktop layout; non-16:9 windows preserve the design aspect ratio. Only windows narrower than 1280 or shorter than 720 switch to the compact scrolling fallback, supported down to 960×540. Small sprites use nearest filtering; the compatibility renderer keeps this UI-only project lightweight.

In the compact fallback, use the mouse wheel or trackpad over a pane to scroll, and section tabs to access additional panels. Mock state survives resizing; dialogs preserve typed input. For explicit developer review, pass `--layout=compact` or `--layout=desktop` after `--`; normal Play uses `auto`. Restart a running preview to pick up the new default window settings.

Square borders use a shared pixel-aligned style adapter when downscaled, keeping at least one physical pixel visible without changing the 1080p layout. Grid outer edges sit inside the clipping bounds. This works with Compatibility and does not require MSAA.

## Verification and captures

Replace `godot` below with your Godot executable. The local editor used for this project is `/Volumes/Data/sdk/godot/editors/4.7.2/Godot.app/Contents/MacOS/Godot`.

```sh
godot --headless --path . --editor --import --quit
godot --headless --path . -- --smoke
godot --headless --path . --script res://tests/common_ui_integration_smoke.gd
godot --headless --path . --script res://tests/addons/combined_addons_smoke.gd
godot --headless --path . --script res://tests/ui_smoke.gd
godot --headless --path . --script res://tests/ui_composition_smoke.gd
godot --headless --path . --script res://tests/ui_reflow_smoke.gd
godot --headless --path . --script res://tests/inventory_smoke.gd
godot --headless --path . --script res://tests/bunker_smoke.gd
godot --headless --path . --script res://tests/raid_smoke.gd
godot --headless --path . --script res://tests/utility_smoke.gd
godot --headless --path . --script res://tests/responsive_smoke.gd
godot --path . --script res://tests/border_render_smoke.gd
godot --path . --script res://tests/ui_component_states.gd -- --capture-dir=/tmp/zerkov-ui-components
godot --path . --resolution 1920x1080 -- --qa --capture-dir=/tmp/zerkov-ui-qa
godot --path . --resolution 1280x720 -- --screen=inventory --qa --capture-dir=/tmp/zerkov-ui-qa-720
godot --path . --resolution 960x540 -- --qa --capture-dir=/tmp/zerkov-ui-qa-960
```

`--screen=<route>` starts any route registered in `ui/core/route_catalog.gd`; paths are not constructed from IDs. `--smoke` instantiates all screens and exits. `--qa` also supports PNG captures using the actual Godot renderer; captures require a graphical session. Runtime errors in console output must be treated as failures even when the process exits successfully.

Additional focused small-window suites are `tests/compact_inventory_smoke.gd`, `compact_bunker_smoke.gd`, `compact_frontflow_smoke.gd`, `compact_utility_smoke.gd`, and `compact_raid_smoke.gd`. Run them with the same `--script res://tests/<name>.gd` pattern; they exercise native scrolling and compact actions at both window sizes.

Screens and repeated visual components are authored as `.tscn` files. Controllers bind data and intent; they do not replace the fixed screen shell during filtering or resizing. HUDs stay on the HUD layer beneath pause/workspaces, and Back restores the retained caller. Individual registered screen scenes support F6 through an isolated fixture host without requiring a node named `Main`. Open `ui/dev/preview_host.tscn` for the component showcase, or `ui/main.tscn` for normal UI routing.

The six vendored packages currently prove a combined macOS debug development
path. Windows and Linux release claims remain blocked until every exact native
artifact and export smoke passes. See [the development baseline](docs/DEVELOPMENT.md).

See [verification results and native screenshots](docs/qa/README.md). Imported originals remain separate from the approved handoff assets; the source asset folders were not modified.
