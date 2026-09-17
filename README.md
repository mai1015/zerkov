# Zerkov

Native Godot 4 project combining the approved Zerkov UI with the Stage 2
offline playable raid. Open `project.godot` and press **F5** to run the actual
local-save product path. It starts at the title screen and continues through
New/Continue, Bunker, loadout, deployment, Sawmill combat and looting,
extraction or death, committed summary, and return home. Pressing **F6** on
`ui/main.tscn` runs the separate unbound UI/QA host; it is not the game root and
does not own a profile or raid authority.

The F5 path binds the existing authored HUD, inventory, Tasks, Maps, deployment
and summary screens to real local projections. Screens and actions outside the
offline slice remain explicit prototypes or locked features. Multiplayer,
economy and expanded bunker systems are outside the active slice.

## UI review-host controls

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

PC at 1920×1080 is the sole current first-playable display and visual-acceptance
target, and Play opens at that resolution. Existing responsive/compact production
code and smaller captures remain only as retained historical compatibility
artifacts. Current agents and tests MUST NOT invoke smaller windows, compact
layout overrides, or regenerate smaller captures; task 11.8 or a later approved
display-support proposal is the only reopening point. Small sprites use nearest
filtering; the compatibility renderer keeps the project lightweight.

The retained compact fallback, resize APIs, and explicit `--layout` overrides are
deferred implementation surfaces only. Do not use them for current acceptance or
capture generation. Restart a running preview to pick up the current exact
1920×1080 window settings.

Square borders and grid outer edges stay pixel-aligned inside clipping bounds at 1080p. This works with Compatibility and does not require MSAA.

## Verification and captures

Use the exact engine version in `config/toolchain.lock.json`. The consolidated
runner fails on a version mismatch, a child timeout, any non-zero contract, or
the diagnostic rules enforced by the domain runners:

```sh
# Portable: repository policy, all Python tooling, and isolated combat/AI/progression.
python3 tools/run_pre_multiplayer_validation.py --godot "$ZERKOV_GODOT" --mode isolated

# Requires a host that can load the checked-in native add-ons (currently macOS).
python3 tools/run_pre_multiplayer_validation.py --godot "$ZERKOV_GODOT" --mode native
python3 tools/run_pre_multiplayer_validation.py --godot "$ZERKOV_GODOT" --mode local-flow --scenario full
```

The remaining commands are individual UI and capture gates. Replace `godot`
with the pinned executable:

```sh
godot --headless --path . --editor --import --quit
python3 tests/tooling/test_ui_first_playable_scope.py
godot --headless --path . --script res://tests/presentation/ui_state_8_11_contract.gd
godot --headless --path . --script res://tests/presentation/ui_production_unavailable_8_11_contract.gd
godot --headless --path . -- --smoke
godot --headless --path . --script res://tests/common_ui_integration_smoke.gd
godot --headless --path . --script res://tests/common_ui_navigation_contract.gd
godot --headless --path . --script res://tests/common_ui_navigation_1080_regression.gd
godot --headless --path . --script res://tests/zerkov_screen_lifecycle_contract.gd
godot --headless --path . --script res://tests/addons/combined_addons_smoke.gd
godot --headless --path . --script res://tests/ui_smoke.gd
godot --headless --path . --script res://tests/ui_composition_smoke.gd
godot --headless --path . --script res://tests/ui_reflow_smoke.gd
godot --headless --path . --script res://tests/inventory_smoke.gd
godot --headless --path . --script res://tests/bunker_smoke.gd
godot --headless --path . --script res://tests/raid_smoke.gd
godot --headless --path . --script res://tests/raid/inventory_ui_binding_contract.gd
godot --headless --path . --script res://tests/utility_smoke.gd
godot --path . --script res://tests/border_render_smoke.gd
godot --path . --script res://tests/ui_component_states.gd -- --capture-dir=/tmp/zerkov-ui-components
godot --path . --resolution 1920x1080 -- --qa --capture-dir=/tmp/zerkov-ui-qa
```

`--screen=<route>` starts any route registered in `ui/core/route_catalog.gd`; paths are not constructed from IDs. `--smoke` instantiates all screens and exits. Both CLI review paths pin the window to the exact 1920×1080 first-playable target before constructing a route. `--qa` also supports PNG captures using the actual Godot renderer; captures require a graphical session. Runtime errors in console output must be treated as failures even when the process exits successfully.

Historical small-window sources (`tests/responsive_smoke.gd` and the dedicated
`tests/compact_*_smoke.gd` files) and their existing captures remain for audit
history. They are deferred and MUST NOT be invoked or regenerated by the current
matrix; task 11.8 or a later approved display-support proposal must reopen them.

Screens and repeated visual components are authored as `.tscn` files. Controllers bind data and intent; they do not replace the fixed screen shell during filtering or resizing. HUDs stay on the HUD layer beneath pause/workspaces, and Back restores the retained caller. Individual registered screen scenes support F6 through an isolated fixture host without requiring a node named `Main`. Open `ui/dev/preview_host.tscn` for the component showcase, or `ui/main.tscn` for normal UI routing.

The six vendored packages currently prove a combined macOS debug development
path. Windows and Linux release claims remain blocked until every exact native
artifact and export smoke passes. See [the development baseline](docs/DEVELOPMENT.md).

See [verification results and native screenshots](docs/qa/README.md). Imported originals remain separate from the approved handoff assets; the source asset folders were not modified.
