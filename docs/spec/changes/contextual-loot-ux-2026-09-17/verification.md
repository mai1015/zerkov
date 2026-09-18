# Contextual loot verification

Base: main `f1d4e76af0a124f1df2efdf872b7b66c129bdc08`, tree
`8c0c560293ab8629728a1480ac4e143eb6aca412`. This includes the merged section
navigation, native map selection and event-driven runtime. Those systems and
all native addon/engine locks are preserved.

## Real local results

Pinned Godot `4.7.2.stable.official.ed1daf0bf`, genuine hash-verified Linux
GDExtensions, isolated file namespaces, no fixture campaign or inventory.

| Invocation | Checks | Failures |
| --- | ---: | ---: |
| Contextual loot New | 1313 | 0 |
| Contextual loot independent Continue | 22 | 0 |
| Graphical contextual loot New | 1330 | 0 |
| Graphical independent Continue | 23 | 0 |
| Existing journey New / Continue | 275 / 137 | 0 / 0 |
| Full native local raid cycle | 4268 | 0 |
| Full-cycle saved envelope, two independent processes | 3 / 3 | 0 / 0 |

All processes exited 0. Check counts include repeated canonical-tick assertions;
they are not counts of independent test scenarios. New performs real search,
opened-crate transfers and an actual abandoned-raid settlement. Its independent
Continue reads the same committed fingerprint:
`f666ab617e5d253d579170dc84ee2b2ce4dd70df892472648e7094e43735c87f`.
Read-only preparation and pane closing are separately checked not to mutate the
profile/owning inventory. No successful raid outcome is manufactured.

The full cycle still covers search, opening and transferring real loot,
extraction, settlement-write failure/retry, abandonment, death, home recovery,
redeployment and restart. Its final fingerprint is
`3d4450762bae29d111692a1865f1c3659272cecdfdcaad79aec2f9563bcf756a`.

The native UX suite tests no phantom Loot tab at home or in raid, no closed
pane/focus targets, value-only Nearby metadata, wrong-phase/stale-epoch and
changed-target rejection, modal blocking, search/resume without duplication,
named opened source, Gear/Health continuity, real transfer, filter-no-match vs
empty, clear-filter recovery, close/reopen and context retirement on leaving
Character. Equipment/loadout coordinates remain stable through the transitions.

Seventeen runner guard tests, 23 repository-scope tests, the exact-1080 inventory
gate and whitespace checks pass. The added CI step runs the same loot suite
strictly on macOS; final pushed-head result is recorded in the PR after upload.
No existing failed-check policy or physical capture guard is weakened.

## Visual review

Nine raw 1920x1080 PNGs were captured and inspected: eight New states (menu,
gear-only, Nearby/unsearched, searching, open source, filter-no-match, empty,
closed) and independent Continue's menu. The existing physical Window, viewport,
texture and image guard passes. No screenshots were generated, composited or
resized. Native input includes mouse/keyboard events rather than direct route
assignment or button-signal success injection.

Two visual defects found during review were corrected: disabled swap labels
spilling into the source pane, and empty/filter-message overlap with category
filters. The final global-Back check moves the actual pointer to neutral space
first so it tests page navigation, not Godot's separate first-Escape tooltip
cancellation. No production Escape priority, tooltip handling or navigation
permission was bypassed to obtain a pass.

Linux graphical runs use Xvfb 1920x1080 with software Mesa. Their outside runtime
uses explicit extension startup registration for the known pinned-engine cold
editor-discovery defect. These tests are not a cold-import fix, addon promotion,
exported client, performance measurement or human/controller signoff. Existing
equipment-slot/quick-use/Stats integration limitations remain labelled and are
not represented as implemented by this UI work.

## Reproduction

```sh
python3 tests/tooling/test_bunker_flow_runner.py
python3 tests/tooling/test_ui_first_playable_scope.py
python3 tools/check_first_playable_1080.py
python3 tools/run_bunker_flow_contracts.py --suite loot --godot "$ZERKOV_GODOT" --output /tmp/zerkov-loot-new
python3 tools/run_bunker_flow_contracts.py --suite loot --graphical --godot "$ZERKOV_GODOT" --output /tmp/zerkov-loot-visual-new
```

Use new output directories. Standard CI uses the existing exact-pin macOS
importer. Graphical qualification requires a real 1920x1080 output host.
