# Current UI QA scope — exact 1920×1080

Status: scope-enforcement note for the 2026-09-10 first-playable matrix.

The current UI, navigation, lifecycle, composition, reflow, component-state,
border, inventory-binding and route-crawler entry points are exact 1920×1080-only paths. The
dedicated responsive and compact-family sources, along with their existing
captures and logs, remain historical/deferred artifacts. Current agents,
runners and tests MUST NOT execute or regenerate them until task 11.8 or a
later approved display-support proposal reopens that work.

The exact test commands and final check totals from the 2026-09-10 verification
pass are:

| Entry point | Checks | Failures | Mode |
| --- | ---: | ---: | --- |
| `tests/common_ui_integration_smoke.gd` | 76 | 0 | headless |
| `tests/common_ui_navigation_contract.gd` | 79 | 0 | headless |
| `tests/common_ui_navigation_1080_regression.gd` | 94 | 0 | headless |
| `tests/zerkov_screen_lifecycle_contract.gd` | 116 | 0 | headless |
| `tests/ui_smoke.gd` | 945 | 0 | headless crawler |
| `tests/ui_composition_smoke.gd` | 103 | 0 | headless |
| `tests/ui_reflow_smoke.gd` | 308 | 0 | headless |
| `tests/inventory_smoke.gd` | 21 | 0 | headless |
| `tests/bunker_smoke.gd` | 21 | 0 | headless |
| `tests/raid_smoke.gd` | 29 | 0 | headless |
| `tests/utility_smoke.gd` | 24 | 0 | headless |
| `tests/raid/inventory_ui_binding_contract.gd` | 138 | 0 | headless |
| `tests/addons/combined_addons_smoke.gd` | 155 | 0 | headless |
| `tests/ui_component_states.gd` | 13 | 0 | native |
| `tests/border_render_smoke.gd` | 27 | 0 | native |
| **Current acceptance subtotal** | **2149** | **0** | **16 runs** |

The component suite was also run headless at exact 1920×1080 (`5/0`) as a
supplemental parse/state check; counting both execution variants gives `2154`
raw assertions with zero failures. Editor import completed cleanly, and strict
validation of both approved changes returned valid with zero errors/warnings.
The current static audit finds 23 active first-playable GDScript runners with
zero forbidden smaller-size/compact-path hits. Fourteen retained GDScript
runners fail closed during initialization before setup or capture, including
the responsive/compact family, inherited visual-inventory probes, and the old
render-scale comparison runner. Two historical Python image generators
(`inventory_ui_binding/summarize.py` and `render_scale/verify.py`) exit before
imports, directories, subprocesses, or writes. That is 16 deferred executable
entry points in total. Immutable
`docs/qa/**/astra_final` and `astra_gate` native runners are excluded from the
current audit and remain unlisted/deferred historical packet tooling.

This note is separate from prior evidence:
the accepted task 8.1/8.2 frozen-source seals remain valid only for their
immutable recorded commits. They are not revalidated against this scope
enforcement checkout, and no current aggregate seal treats those historical
source manifests as current.

## Enforcement follow-up — 2026-09-11

A read-only Astra audit found that the retained render-scale wrapper was still
advertised as current, generated non-1920×1080 summary images, and exercised an
unselected 320×180 internal world candidate. Both the GDScript runner and its
Python generator now fail before viewport setup, imports, subprocesses,
directories, or writes. The selected 640×360 world surface remains permitted
only when nearest-mapped exactly 3× into a genuine 1920×1080 output target.

The audit also found active image writers that checked only the requested root
size or recorded a failed framebuffer check and then saved anyway. The current
writers now validate the renderer readback immediately before every PNG write
and return/quit without saving on mismatch. Their output directories are not
created until an initial genuine 1920×1080 framebuffer preflight passes. QA and
review sessions reject a later window-size change before scale synchronization
or layout reflow; ordinary retained production compatibility is unchanged.

The static gate now covers the two Python generators, the retired render-scale
runner, known active PNG writers, pre-write readback guards, and the QA resize
guard, including negative controls for the previously unsafe patterns. It
passes four tests. Exact-argument headless checks also pass for the
Task 8.11 state contract (`57/0`), unavailable composition (`106/0`), and
component-state source (`5/0`). All six edited GDScript entry points parse after
a clean Godot 4.7.2 import, strict change validation is `Valid`, and invoking
the historical Python wrapper exits with `DEFERRED_DISPLAY_SUITE` without
creating `docs/qa/render_scale/current_1080/`.
