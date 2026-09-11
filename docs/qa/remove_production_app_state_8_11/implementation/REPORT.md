# Task 8.11 — production `app.state` removal evidence

Status: implementation candidate only. Task 8.11 remains unchecked pending
independent review.

Implementation base: `64e01051e6676c9582ce5409b683d542dddc8686`.
Merged accepted main before sealing:
`abc9c107d91b7b01819a67da88add254de2e0bcf` (Task 8.10).
Engine: Godot `4.7.2.stable.official.ed1daf0bf`; native Compatibility renderer
for the exact screenshot and headless Compatibility for structural UI checks.

## Outcome

Production `Main` and `ZUIContext` no longer expose `state` or `fixtures`.
Every retained prototype mutation now goes through a generation-scoped
`ZUIFixtureProvider`, and that provider is issued only to explicit review,
developer-catalog, QA, or `prototype_fixture_mode` contexts. The fixture store
and the four authored sample imports remain under `ui/dev/`; a production route
origin cannot acquire them.

Non-Character production composition receives typed `BunkerView`, `RaidView`,
`TaskView`, `MapView`, and `SummaryView` publications. In the current partial
product composition the missing services publish initialized `UNBOUND` views
with route-specific diagnostics. Their screens render an inert, honest locked
state instead of constructing a sample profile, raid, task graph, map, or
settlement. The provider accepts only same-generation immutable publications,
rejects regressing or equal-version-divergent values, replaces fail-atomically,
and returns typed stale/released truth after replacement or teardown.

The accepted Task 8.6 Character composition remains its existing injection-only
seam. Its authored Inventory workspace and 74px grid are retained; an uninjected
production runtime publishes the accepted typed unavailable view and displays no
sample inventory. The accepted Task 8.10 Controls route likewise stays on its
game-owned `ZerkovInputService`. Its authored row names are static presentation
metadata beside the controller, not an import of developer fixture state.
Explicit review/prototype Controls contexts remain isolated on the fixture
provider.

## Permanent regression contracts

- `ui_state_8_11_contract.gd` recursively enumerates every production `.gd`
  source below `ui/` and `game/`. It proves zero legacy `app.state` or reflective
  state access, one permitted fixture-import owner, no fixture-store escape from
  `ui/dev/`, absent legacy public properties, provider generation/teardown
  behavior, typed unavailable publication, and retained Task 8.6/8.10 seams.
- `ui_production_unavailable_8_11_contract.gd` boots only exact 1920x1080. It
  proves all production origins receive no fixture provider; representative
  Bunker, Raid, Task, Map and Summary routes show typed unavailable truth with
  no sample identity; Character remains authored and sample-free; Controls
  remains live and fixture-free; and an explicit prototype session still
  renders the retained authored preview.
- `test_ui_first_playable_scope.py` discovers UI runners from source. The
  current inventory is 24 active exact-1920 runners plus 13 historical deferred
  runners. Active sources require a 1920x1080 gate and reject known smaller
  outputs/compact overrides. Deferred compact, responsive, and
  `tests/visual/inventory_ui_binding` sources must terminate with
  `DEFERRED_DISPLAY_SUITE` before retained runner logic; the historical contact
  sheet generator must terminate before imports or writes.
- Built-in smoke/review command-line entry points reject explicit non-1920
  resolution and compact/unknown layout arguments from both Godot argument
  sources, then verify the actual root at `Vector2i(1920, 1080)` and the native
  window before constructing any route. Native capture runners fail closed
  before path creation or writing if their exact-size check fails.

## Exact executed checks

| Evidence | Result |
| --- | --- |
| Editor import/class registration | exit `0`; no parser or runtime diagnostic |
| Strict spec validation | `Valid` |
| Static first-playable scope contract | `2` tests, `0` failures; 24 active / 13 deferred runners |
| Task 8.11 source/provider contract | `57` checks, `0` failures |
| Task 8.11 native production/unavailable contract | `109` checks, `0` failures; exact `1920x1080` |
| Read-only view contracts | `115` checks, `0` failures |
| Character presentation composition | `22` checks, `0` failures |
| Task 8.6 Character UI | `65` checks, `0` failures; exact `1920x1080` |
| Inventory UI binding | `138` checks, `0` failures; exact `1920x1080` |
| Task 8.10 CommonUI input | `51` checks, `0` failures; exact `1920x1080` |
| CommonUI navigation | `79` checks, `0` failures; 28 routes |
| CommonUI navigation regression | `94` checks, `0` failures; exact `1920x1080` |
| CommonUI integration | `76` checks, `0` failures; exact `1920x1080` |
| UI route smoke | `948` checks, `0` failures; exact `1920x1080` |
| UI composition | `103` checks, `0` failures; exact `1920x1080` |
| Inventory / bunker / raid / utility families | `21/0`, `21/0`, `29/0`, `24/0`; exact `1920x1080` |
| Screen lifecycle | `116` checks, `0` failures; exact `1920x1080` |
| UI reflow | `308` checks, `0` failures; exact `1920x1080` only |
| Built-in route smoke | 28 screens, `0` missing/capture errors; exact `1920x1080` |
| Exact CLI guard probes | headless and native `--layout=desktop`; 28 screens, `0` errors each |
| Native lifecycle capture guard | `0` failures; immediate framebuffer check and output both exact `1920x1080` |
| `git diff --check` | exit `0` |

Every UI/visual invocation used the single approved viewport explicitly:

```text
/opt/homebrew/bin/godot --path . --resolution 1920x1080 --script res://tests/presentation/ui_production_unavailable_8_11_contract.gd -- --capture-path=res://docs/qa/remove_production_app_state_8_11/implementation/production_unavailable_1920x1080.png
/opt/homebrew/bin/godot --headless --path . --resolution 1920x1080 --audio-driver Dummy --script res://tests/common_ui_input_regression_1080.gd
/opt/homebrew/bin/godot --headless --path . --resolution 1920x1080 --script res://tests/presentation/character_ui_binding_8_6_contract.gd
/opt/homebrew/bin/godot --headless --path . --resolution 1920x1080 --script res://tests/raid/inventory_ui_binding_contract.gd
/opt/homebrew/bin/godot --headless --path . --resolution 1920x1080 --script res://tests/common_ui_navigation_contract.gd
/opt/homebrew/bin/godot --headless --path . --resolution 1920x1080 --script res://tests/common_ui_navigation_1080_regression.gd
/opt/homebrew/bin/godot --headless --path . --resolution 1920x1080 --script res://tests/ui_smoke.gd
/opt/homebrew/bin/godot --headless --path . --resolution 1920x1080 --script res://tests/ui_composition_smoke.gd
/opt/homebrew/bin/godot --headless --path . --resolution 1920x1080 --script res://tests/inventory_smoke.gd
/opt/homebrew/bin/godot --headless --path . --resolution 1920x1080 --script res://tests/bunker_smoke.gd
/opt/homebrew/bin/godot --headless --path . --resolution 1920x1080 --script res://tests/raid_smoke.gd
/opt/homebrew/bin/godot --headless --path . --resolution 1920x1080 --script res://tests/utility_smoke.gd
/opt/homebrew/bin/godot --headless --path . --resolution 1920x1080 --script res://tests/common_ui_integration_smoke.gd
/opt/homebrew/bin/godot --headless --path . --resolution 1920x1080 --script res://tests/zerkov_screen_lifecycle_contract.gd
/opt/homebrew/bin/godot --headless --path . --resolution 1920x1080 --script res://tests/ui_reflow_smoke.gd
/opt/homebrew/bin/godot --headless --path . --resolution 1920x1080 -- --smoke
/opt/homebrew/bin/godot --headless --path . --resolution 1920x1080 -- --smoke --layout=desktop
/opt/homebrew/bin/godot --path . --resolution 1920x1080 -- --smoke --layout=desktop
/opt/homebrew/bin/godot --path . --resolution 1920x1080 --script res://tests/visual/zerkov_screen_lifecycle/capture.gd -- --capture-path=/tmp/zerkov-8-11-lifecycle-c6816ff-1920x1080.png
```

The editor import, strict spec validation, source/provider and read-only domain
contracts, static Python gate, hash checks, literal audit and Git checks do not
render UI and therefore have no acceptance viewport.

The lifecycle guard probe's temporary PNG reported 1920x1080 both in-run and
through an independent metadata read, then was removed after verification.

The accepted Task 8.10 input runner was serialized. Before and after execution,
the only matching shared persistence file was `common_ui_bindings.json`, with
identical SHA-256
`ff6f972f99cc7e9a66db4852735ead27d344b3d090d246a420aa0136aff6bde5`;
`.tmp` and `.bak` were absent both times.

The lifecycle geometry stayed at aggregate SHA-256
`4eb724f07fb51fdfccaa5b0659bd07fe33dcb8ba23afea03bb8f1666582c8a4a`;
its exact-1920 source geometry digest stayed
`794e84f101b28dea717a58416b4593af290b79a8cafccf414a8fc93f8b9ddccb`.

## Native evidence

[`production_unavailable_1920x1080.png`](production_unavailable_1920x1080.png)
is a native Compatibility-renderer frame of the production Main Menu missing-
service truth. It is exactly 1920x1080 and has SHA-256
`946d010d541ac202f6dd840925a3f90fd4d25af3c6b9d8800cfb905077e0a6b7`.
It was visually inspected for opaque coverage, readable hierarchy, body copy
wrapped wholly inside the existing centered panel, explicit unavailable status
and absence of sample profile/raid content.

No compact, responsive, old `tests/visual/inventory_ui_binding`, 1600x900,
1280x720, 960x540, or other smaller-output runner or capture was executed or
regenerated. Historical artifacts were left untouched.

## Scope held

This candidate does not create gameplay, profile, raid, settlement, task, map,
bunker, crafting, friend, insurance, or marketplace services. It does not bind
HUD, Tasks/Maps, deployment/summary, or meta actions to new authorities, and it
does not claim Tasks 8.5, 8.7, 8.8, or 8.9. Task 8.11 remains open until an
independent reviewer accepts this packet.
