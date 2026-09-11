---
created_at: 2026-09-10T01:35:01Z
updated_at: 2026-09-10T03:08:58Z
completed_at: 2026-09-10T03:08:58Z
---

Current display scope (2026-09-10): the active first-playable verification
matrix is exact 1920×1080 only. Compact/responsive wording and evidence below
describe the completed historical migration packet; current agents and tests
MUST NOT execute those suites or regenerate their smaller captures until task
11.8 or a later approved display-support proposal reopens them.

## 0. Audit and approval

- [x] 0.1 Inspect component ownership and CommonUI integration; record source
  locations and reproduce structural failures. Evidence: `audit.md`.
- [x] 0.2 Rerun the focused existing baseline. Evidence: CommonUI 76/0 and UI
  814/0 with all 28 routes visited, recorded in `audit.md`.
- [x] 0.3 Validate this change strictly. Evidence: `spec_toolkit.py validate
  refactor-ui-composition-2026-09-09 --type change --strict` returned `Valid`.
- [x] 0.4 Obtain approval of the component and navigation migration described
  in `design.md`. Evidence: user approved implementation in this conversation:
  "yes, lets get that up. we do not really need a spec but fine".

## 1. Baseline and foundations

- [x] 1.1 Snapshot the affected project-owned files and capture representative
  baseline screens/states at the declared sizes. Evidence: recoverable snapshot,
  capture manifest, inventory-filter and resize baseline.
- [x] 1.2 Add the explicit route catalog before moving scene paths. Evidence:
  28 stable IDs resolve, direct-start works, invalid IDs leave the screen intact.
- [x] 1.3 Add the supplied UI context and fixture-backed preview host; remove
  the screen base's absolute Main lookup. Evidence: isolated menu/component
  preview without null errors and normal application bootstrap passing.
- [x] 1.4 Document and author the shared theme/button variants and border
  adapter. Evidence: component state captures, one activation per event, and
  the existing border-render suite passing.

## 2. Shared components and frontflow

- [x] 2.1 Give menu action cards their own updating configuration, focus states,
  and activation signal. Evidence: Inspector/runtime text updates and disabled,
  hover, focus, pressed captures; consumers no longer bind internal labels.
- [x] 2.2 Give world rows a data/selection API and focus/activation contract.
  Evidence: empty/full/selected states, rename/update behavior and save actions.
- [x] 2.3 Consolidate navigation chrome desktop and compact composition.
  Evidence: shared instance remains present at each size; all navigation actions
  work and resources/count/active state update without consumer node traversal.
- [x] 2.4 Consolidate bunker chrome around explicit fields and badge variants.
  Evidence: four family variants at both layouts, no duplicate alias labels or
  separately generated compact header.
- [x] 2.5 Move frontflow scenes/controllers/components and extract their
  fixture behavior from the family base. Evidence: frontflow and compact
  frontflow checks, menu/save/join/deploy captures, no stale resource paths.

## 3. Retained feature composition

- [x] 3.1 Migrate inventory filtering/search/loot updates to its retained shell
  and grid API. Evidence: unchanged shell/search/control IDs, correct items,
  focus/caret preservation, inventory smoke and authored-path regression.
- [x] 3.2 Share character sections across inventory/health/stats and compact
  panes; move the family and fixture data. Evidence: compact inventory suite,
  drag/transfer/heal actions, retained section state and native captures.
- [x] 3.3 Migrate bunker/build composition away from full child replacement and
  coordinate-based discovery. Evidence: station selection, build placement,
  modal flow, retained chrome and compact bunker checks.
- [x] 3.4 Migrate crafting/session updates into retained detail/queue components
  and move the family/fixtures. Evidence: queue progress/collect and session
  actions, node/signal stability, desktop/compact captures.
- [x] 3.5 Move maps/tasks and extract their feature/fixture ownership while
  preserving existing in-place bind behavior. Evidence: utility actions, map
  interaction, tasks selection/scroll and shared compact chrome.
- [x] 3.6 Move settings/controls and consolidate layout/theme use without
  changing existing preview binding behavior. Evidence: settings persistence,
  binding capture/conflict/cancel actions and compact utility suite.
- [x] 3.7 Move raid scenes and shared HUD visuals; separate the seven review
  scenes from feature controllers. Evidence: raid/compact raid suites, preview
  timers and all 28 catalog entries still available.

## 4. Navigation and lifetime

- [x] 4.1 Implement committed route state and declared reset/push/replace/pop
  policies. Evidence: failed/canceled navigation leaves committed state valid,
  temporary Back restores the caller, workspace tabs avoid history loops.
- [x] 4.2 Mount HUD on its layer and retain it under pause/workspace screens.
  Evidence: same HUD ID after pause/resume and inventory open/close, correct
  input suspension and focus restoration, no duplicate action registration.
- [x] 4.3 Move interactive catalog/feedback ownership into the root services
  and CommonUI layers. Evidence: modal and picker trap focus, prevent underlying
  actions from physical input, dismiss once, and restore the prior focus.
- [x] 4.4 Replace route-remount resizing with repeatable component reflow.
  Evidence: repeated desktop/compact/desktop passes preserve shell identity,
  text/caret, scroll, focus, selected pane, drag intent, and pending prompt text.

## 5. Cleanup and acceptance

- [x] 5.1 Remove superseded builders/family bases and temporary facade methods
  after their consumers migrate; update scene references and resource UIDs.
  Evidence: clean import, no dangling paths, all route/component loads pass.
- [x] 5.2 Update README, DESIGN and component API guidance with the final tree
  and add-a-screen/component examples. Evidence: examples load in preview host
  and the documented route registration resolves.
- [x] 5.3 Run the applicable UI and border suites plus new lifecycle
  regressions. Historical evidence: test log with zero runtime errors and no
  weakened interaction coverage; share results with playable-raid tasks
  8.1/8.2/8.10. Current reruns are exact 1920×1080 only.
- [x] 5.4 Review the historical native captures for all routes at the sizes and
  forced-compact cases accepted by the original migration. Evidence: labeled
  before/after captures and documented intentional layout differences only.
  Those captures are retained history and MUST NOT be regenerated by current
  acceptance runs.

Each unchecked item is implementation or acceptance work, not a claim of
completion. Shared evidence may satisfy overlapping playable-raid tasks, but
those tasks are checked only when their complete original scope is met.

## Final evidence

See [the UI acceptance report](../../../qa/ui-composition-2026-09-09/README.md)
for the historical final 2,891/0 matrix, 140 before/after route pairs,
component states, resource checks, preview checks, recovery archive and
documented compact composition differences. The historical packet is not a
current smaller-resolution runner. All work remains UI-only; broader
playable-raid integration tasks are not completed by this change.
