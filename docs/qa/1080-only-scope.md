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
The static audit found 17 active first-playable scripts with zero forbidden
smaller-size/compact-path hits, eight current documentation files with zero
forbidden runner commands in their command blocks, and an exact-only render-
scale resolution tuple.
The static guard audit covered 14 deferred probe/generator entry points: the
retained responsive/compact smoke entry points and inherited visual inventory
probes fail closed during initialization before setup or capture, and the
historical `summarize.py` generator exits before writing. Immutable
`docs/qa/**/astra_final` and `astra_gate` native runners are excluded from the
current audit and remain unlisted/deferred historical packet tooling.

This note is separate from prior evidence:
the accepted task 8.1/8.2 frozen-source seals remain valid only for their
immutable recorded commits. They are not revalidated against this scope
enforcement checkout, and no current aggregate seal treats those historical
source manifests as current.
