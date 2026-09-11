## Context

Preserve `DESIGN.md` and all 28 current routes while replacing the partial
scene migration with explicit ownership. CommonUI remains the installed addon;
all integration and visual decisions stay in game-owned `ui/` code.

The UI is still primarily a prototype. This change isolates its fixture
behavior without inventing production inventory, persistence, combat, or
network services. The playable-raid change owns those contracts.

## Proposed directory structure

Keep related `.tscn`, `.gd`, and `.uid` files together. Use folders to express
ownership; do not create a new folder for every tiny script.

```text
ui/
  main.tscn                     stable application entry point
  main.gd                       bootstrap and temporary compatibility facade
  core/
    screen.gd                   CommonUI lifecycle and UI dependency contract
    ui_context.gd               navigation, feedback, layout, fixture access
    route_catalog.gd            stable IDs, scene references, layer policies
    navigator.gd                stack operations and committed route state
    feedback.gd                 dialogs, popup coordination, notifications
  theme/
    zerkov_theme.tres           authored shared fonts, styles, type variations
    tokens.gd                   runtime access to documented design tokens
    pixel_style.gd              existing pixel-aligned border resource
    theme_adapter.gd            common runtime pixel-style integration
  components/
    controls/                   project button and documented variants
    layout/                     cross-feature navigation chrome
    feedback/                   dialog and toast visuals
    backgrounds/                parallax and shared backdrop
  screens/
    frontflow/                  title, main_menu, saves, join_friend, deploying
      components/               menu action card, world row, new-world row
    bunker/                     bunker, build_mode, crafting, session
      components/               bunker chrome and retained compact workspace
    character/                  inventory, health, stats
      components/               grid, loadout, stash, gear and character panels
    utilities/                  maps, tasks, settings, controls
    raid/                       hud, hud_coop, pause, summary_solo, summary_squad
      components/               crosshair, reload ring and common HUD sections
  dev/
    preview_host.tscn           fixture-backed isolated runtime preview
    screen_catalog.tscn         F1 catalog, presented through CommonUI
    fixture_store.gd            explicit prototype state owner
    fixtures/                  family-specific sample data and mock behavior
    screens/                   the seven existing visual studies/showcase routes
  shaders/                     existing backdrop shader
```

Developer study routes: `hud_detail`, `crosshairs`, `status_icons`, `squad_list`,
`reload`, `mag_empty`, and `showcase`. Their IDs and current access remain intact;
production gating is a separate playable-raid task.

The route catalog replaces filename construction before scenes move. Screen
scripts are consistently named after their scene; the current family bases
such as `inventory.gd` must be split or clearly renamed before that name is
assigned to the concrete inventory controller.

## Component boundaries

Shared components depend on theme resources and CommonUI primitives. They
cannot locate `Main`, navigate globally, or mutate fixture/gameplay state.
Feature screens connect semantic signals to their supplied UI context.

| Component | Public configuration | Outputs / behavior |
| --- | --- | --- |
| Project button | text, variant, disabled, optional CommonUI action | one semantic activation; project focus/hover/disabled states |
| Menu action card | title, subtitle, active/disabled | activation signal and focus target; updates after mount and in editor |
| World row | world presentation data, selected/disabled | selected/activated world ID; internal styling and responsive geometry |
| Navigation chrome | active route, level, currency, task count | navigate, back, insurance intents; one desktop/compact implementation |
| Bunker chrome | title/meta, resource values, optional badge | menu/back intents; explicit optional fields instead of duplicate aliases |
| Inventory grid | immutable item list, selection, compatibility state | existing drag/drop/transfer intents; no authority mutation |
| Adaptive pane | named content slot and overflow policy | retained scroll/focus state across supported reflow |
| Dialog | title/message, prompt configuration, actions | exactly one confirmed/dismissed result and focus restoration |

These are ownership contracts, not a requirement to turn every label or static
rectangle into a separate scene. Extract repeated sections where one shared
implementation actually reduces duplication. Feature-specific components stay
inside their feature until another family needs them.

Use exported resources or typed public configuration methods for complex data,
signals for intent, and a public focus-target accessor where needed. Internal
node names remain private. `@tool` scripts used for Inspector preview must not
access runtime services or connect gameplay actions in the editor.

## Theme and editor ownership

Update `DESIGN.md` section 5 with the concrete component/state contracts before
implementation. Extract the current appearance into an authored Theme with
named variations such as primary, secondary, flat navigation, hit target, and
destructive. Preserve exact handoff-specific geometry where it differs.

The project button scene references that theme and exposes the variants.
Runtime factories, where data-driven construction is appropriate, instantiate
the same component and consume the same resources. Ordinary native inputs such
as OptionButton and LineEdit remain appropriate and use the project theme.

Keep pixel-safe border rendering and its physical-pixel guarantees. Centralize
conversion of authored StyleBoxFlat resources instead of having every screen
walk and restyle the full tree. Preserve the transparent hit-target appearance
of cards and the sharp, unrounded visual language.

## Navigation and layer policy

CommonUI owns screen instances, activation, and temporary stacks. A game-owned
navigator chooses operations and wires feature intents. It does not maintain a
second independent history list or mutate active route metadata before success.
The catalog validates route/payload policy before enqueuing a request.

| Navigation case | CommonUI operation and retention |
| --- | --- |
| Enter a new top-level flow, such as title → main menu or deploy → raid | Explicit reset of obsolete stacks; mount the destination on its declared layer |
| Open saves, join, settings, or another temporary page | Push onto menu; Back pops to the retained caller |
| Switch tabs within character/utility workspace | Replace the workspace top; preserve the caller below it and avoid tab-history loops |
| Show raid HUD | Mount on HUD layer; its lifetime follows the raid presentation session |
| Pause over raid HUD | Push pause onto menu; suspend relevant lower input; pop restores the same HUD |
| Open inventory/map/tasks over raid HUD | Menu workspace above retained HUD; explicit close restores the HUD |
| Pause over bunker/session/main menu | Push over the retained menu screen; resume pops |
| Open confirmation/prompt | Modal layer; suspend all applicable active lower contexts; resolve once |
| Open F1 catalog | Popup layer with explicit input/focus containment and restoration |

Direct `--screen=<route>` and catalog selections must construct a valid review
context for every route without starting real gameplay. Preserve Back policies
for special routes such as build, crafting, and summaries through declared flow
rules. Capture those policies in tests before replacing the implementation.

Notifications remain noninteractive and do not steal focus. Their authored
host is owned by feedback within the root composition; they do not create a
competing navigation stack. All interactive overlays use CommonUI lifecycles.

CommonUI only suspends its own routed contexts. Raw `_input` and
`_unhandled_input` handlers must also respect activation and modal/capture state,
or be routed through screen-scoped CommonUI actions. Test physical events as
well as direct method calls. Do not assume context suspension stops raw input.

## Lifetime and retained compatibility layout

Data updates bind existing nodes. Inventory filter changes update the grid;
selection updates detail panels; crafting changes update queue entries. Variable
rows may be added/removed inside the appropriate data component, but fixed
shells, headers, search fields, and persistent controls keep their identities.

The existing desktop/compact threshold, explicit layout overrides and
idempotent layout APIs remain retained compatibility behavior. The current
first-playable verification target is exact 1920×1080 only; current agents and
tests MUST NOT invoke smaller windows, compact overrides or regenerate smaller
captures. Task 11.8 or a later approved display-support proposal must reopen
that scope.

A resize within the exact desktop path changes viewport fitting without
remounting the active screen. Existing mode-change APIs may continue to preserve
selected panel, text/caret, focus, scroll offsets, active drag intent and pending
dialog text when the deferred compatibility path is explicitly reopened.
Repeated transitions must not accumulate controls or signal connections.

## Migration and compatibility

1. Record native baseline captures and focused structural expectations.
2. Introduce the route catalog and dependency seam while keeping the entry
   scene and route IDs stable. Do not move all files at once.
3. Establish shared theme/button/card/chrome contracts and verify their states
   in a native preview host before migrating feature screens.
4. Migrate frontflow, character, bunker, utilities, and raid families in bounded
   steps, removing each superseded builder only after its consumers migrate.
5. Change navigation semantics with focused push/pop, suspension, and failure
   tests. Keep visibility policies for overlays explicit in both layouts.
6. Update resource references, matching `.uid` files, docs and test fixtures;
   remove temporary facade methods once callers no longer depend on them.
7. Run the complete exact-1920×1080 automated and native visual acceptance
   matrix. Historical smaller evidence remains unchanged and is not regenerated.

Because this checkout has no Git metadata, create a recoverable snapshot of the
specific project-owned files to be edited before migration. Do not initialize a
repository or alter vendored addon packages as part of this change.

## Risks and scope limits

- Tests currently encode a single replacement-only menu. Preserve their useful
  route/action coverage while updating only the assertions intentionally
  superseded by stack behavior; add failure/cancellation tests.
- Moving scenes can break preload paths, dynamic loads, and stored UIDs. The
  catalog plus an import/reference sweep is required at each move.
- Retaining screens also retains timers and input handlers. Cover/deactivate
  must stop inappropriate UI actions and preserve correct preview timing.
- Shared theme extraction can alter borders, tracking, hit areas, and focus
  appearance. Compare native captures and keep border-render checks mandatory.
- Fixture extraction is organizational. Real view models, gameplay intents,
  persistence, controller binding persistence, and production feature gates
  remain owned by the playable-raid proposal.
- Approval of this structure does not approve a visual redesign or removal of
  existing interactions.

## Acceptance evidence

All routes must resolve after file moves. Component tests must prove updates
before/after `_ready`, standalone preview, and one activation per input. Runtime
tests must prove inventory shell retention, HUD/pause identity, focus/input
isolation, failed navigation rollback, and repeated exact-desktop reflow-state
preservation.

Run the current CommonUI, UI, inventory, bunker, raid, utility and border suites
at exact 1920×1080 only. Current acceptance MUST NOT invoke responsive/compact
or other smaller-resolution suites, even for information. Existing smaller
captures and dedicated sources remain historical and are reopened only by task
11.8 or a later approved display-support proposal. Runtime errors count as
failures even when Godot returns exit code 0.
