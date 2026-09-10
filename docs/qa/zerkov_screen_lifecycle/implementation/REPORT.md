# Task 8.1 — frozen implementation evidence

Status: implementation complete; independent acceptance review pending.

Task: `8.1` from `add-zerkov-playable-raid-2026-09-09`.
Implementation baseline: `ab036d2a6c102b6692a9d36e7db6a1b8821f0402`.
Engine: Godot `4.7.2.stable.official.ed1daf0bf`, Compatibility renderer.
Review target: Visual Reviewer `3149c21f-defc-4a28-b2d7-86c6b12e0fd8`.

## Outcome

The repository's shared `ZScreen` already contains the requested production
behavior: it inherits `CommonActivatableScreen`, acquires its route context and
screen-scoped Back action while active, releases them while covered, disables
covered-screen processing, and reacquires them when restored. That code was
present in the imported foundation checkpoint but had not been accepted as
task 8.1 evidence. In accordance with the Charter's instruction to reuse valid
legacy work after verification, this implementation pass does not rewrite the
already-correct production lifecycle or any UI layout source.

This pass adds a task-specific contract and native capture harness. The
contract verifies every registered route uses `ZScreen` and
`CommonActivatableScreen`; exercises active -> covered -> restored -> teardown;
checks context, action, processing, stack and signal ownership; and compares
every descendant `Control` anchor, offset, position, size, minimum size, scale,
rotation and pivot before covering and after restoration.

## Automated results

| Evidence | Result |
| --- | --- |
| `lifecycle_contract.log` | `209` checks, `0` failures; `28` routes; `392` geometry records across four resolutions |
| `common_ui_integration.log` | `76` checks, `0` failures |
| `route_smoke.log` | `28` screens, `0` missing/capture errors |
| `ui_composition.log` | `109` checks, `0` failures |
| `ui_reflow.log` | `756` checks, `0` failures |
| `responsive.log` | `96` checks, `0` failures |
| `editor_import.log` | clean import; no parser, registration or extension errors |
| strict spec validation | `Valid` |
| `git diff --check` | exit `0`, no output |

The assertion-bearing suites total `1,246` checks with `0` failures. The
focused geometry digest is
`550b91a79fa9c5ae30bc3f736629e78429c25f56e0fc4c52bbecf38e60fa1e03`.
The desktop lifecycle geometry digest is identical at 1920x1080, 1600x900 and
1280x720; the intentionally adaptive 960x540 compact layout has its own stable
digest. Within every resolution, the pre-cover, covered and restored snapshots
are exactly equal.

## Native capture matrix

The capture harness mounts `main_menu` once, verifies that it is the routing-
active top of the CommonUI menu layer, waits for layout, and captures the real
Godot Compatibility viewport. It avoids the general QA crawler's duplicate
initial-route refresh path.

| Resolution | Capture | Runtime result |
| --- | --- | --- |
| 1920x1080 | `captures/1920x1080/main_menu.png` | `failures=0`, exact 1920x1080 image |
| 1600x900 | `captures/1600x900/main_menu.png` | `failures=0`, exact 1600x900 image |
| 1280x720 | `captures/1280x720/main_menu.png` | `failures=0`, exact 1280x720 image |
| 960x540 | `captures/960x540/main_menu.png` | `failures=0`, exact 960x540 image |

All four captures were inspected for non-empty rendering, expected desktop or
compact composition, obvious overlap and clipping. Independent visual
acceptance remains pending and is not claimed by this report.

## Diagnostics review

Accepted logs were searched for `ERROR:`, `SCRIPT ERROR:`, `WARNING:`,
`FATAL:`, failed-condition diagnostics, orphan reports and leaks; there were no
matches. Every accepted Godot process exited `0`.

Two authoring runs are excluded: the first ran before the fresh workspace
import, and an early generic 960x540 QA capture refreshed its already-open
initial route and emitted an anchor warning. The final packet was regenerated
after import with the deterministic single-mount capture harness; none of those
excluded diagnostics appear in the accepted logs or captures.

## Scope and claims

- Production UI, scene and layout files are unchanged by this pass.
- Added files are the focused lifecycle contract, capture harness, their Godot
  UID sidecars, this evidence packet, and one README command entry.
- The packet proves task 8.1's shared-screen lifecycle and geometry boundary.
- It does not claim task 8.2 navigation replacement, task 8.3 input metadata,
  task 8.10 complete focus/rebinding coverage, task 8.12 final real-data visual
  acceptance, human playtesting, a complete raid loop, multiplayer, or release
  readiness.
- The task checkbox and commit checkpoint intentionally remain pending until
  the independent Visual Reviewer decision and the required fresh Astra
  validation complete in the mandated sequence.

`frozen_sources.sha256` seals the production dependencies, added test/capture
sources, accepted logs and native images reviewed by the next stage.
