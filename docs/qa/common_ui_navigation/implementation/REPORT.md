# Task 8.2 — CommonUI navigation implementation and repair evidence

Status: implementation repair complete; independent re-review pending.

Task: `8.2` from `add-zerkov-playable-raid-2026-09-09`.
Implementation baseline: `39dcf3bba9aad7675b0cdf2f9d6925f06aa0d751`.
Independent-review repair base: `79cd5deffa784264d6c653c6c9e403954fb335e7`.
Engine: Godot `4.7.2.stable.official.ed1daf0bf`, Compatibility renderer.

## Outcome

Production navigation now enters one typed intent boundary and commits menu or
HUD mutations through the existing `CommonUIScreenRoot`. Modal and popup
lifecycles continue through their native CommonUI layers, now with stable
`modal/confirm`, `modal/prompt`, and `developer/catalog` contexts. The
navigator's pending collection serializes commands only; live history is still
derived from the four CommonUI layers, so this change does not add a competing
global stack.

The route catalog declares layer, priority, empty typed-payload, developer-only,
and Back policy. Intents are validated at admission and again before execution,
then detached from caller mutation. Untyped requests, unknown route IDs,
unknown payload types, unexpected payload values, stale production origins and
direct production requests for study routes are rejected with a diagnostic
without dismissing a modal/popup or mutating any layer depth/top.

F1 remains the explicit production entrance to the 28-route developer catalog.
The `--qa`/`--screen` review harness remains available outside production flow.
Screens receive only the narrow `ZUIContext`, which submits typed route/Back
intents and exposes the admitted typed payload without owning stack state or
game authority.

## Independent-review repair

The exact 1920x1080 review paths now preserve CommonUI ownership under rapid
input and overlay races:

- HUD -> Pause -> Session -> Back pops to the retained Pause, and Pause
  Resume/Back pops to the retained HUD. Menu depth is bounded at two; Back no
  longer pushes duplicate Pause/Session screens.
- A modal or popup claims its layer synchronously and blocks other route
  commits. Duplicate same-frame confirms are idempotently rejected, overlay
  references remain tracked until CommonUI finishes the pop, repeated Back is
  consumed, and focus returns to the retained screen.
- A dialog callback is tied to the screen instance that opened it and runs only
  after a successful modal pop while that owner is still current. A stale
  callback expires safely rather than touching a replaced screen.
- Developer selections require a live opaque capability issued by the active
  F1 catalog. The catalog closes and restores lower lifecycle/focus before its
  authorized route commits. Direct facade calls, forged developer/system
  origins, expired capabilities, and mismatched or stale Back origins fail
  without mutating the active composition.

The return target recorded on each screen is lifecycle metadata for the
existing CommonUI menu layer; it is not a second history stack.

## Reported Continue/focus path

The 1600x900 path from the Astra audit is corrected at CommonUI activation:

- title registers CommonUI Confirm while active, so Enter and a south/A
  controller event enter the main menu through the same typed route intent;
- main-menu activation declares `MenuContinue/Hit` as its CommonUI default
  focus instead of grabbing focus before lifecycle settlement;
- the next advertised Enter activates Continue and opens `session`; it does not
  focus or activate `Header/SwitchAccount` and does not produce the disabled
  account-switch toast;
- pause similarly declares Resume as activation-owned default focus.

No project binding table, glyph selection, rebinding behavior or device-
detection policy was authored here; those remain task 8.3/8.10 work.

## Automated results

| Evidence | Result |
| --- | --- |
| `logs/navigation_1080.log` | `72` checks, `0` failures at exact 1920x1080; retained HUD/Pause Back chain, overlay serialization, stale callbacks, focus, duplicate input and origin/capability forgery |
| `logs/navigation_1080_native.log` | the same `72`-check contract passes with the native Compatibility renderer; counted once in the assertion total |
| `logs/navigation_contract.log` | `78` checks, `0` failures; keyboard, synthetic controller, focus, layer, Back, invalid-intent and lifecycle coverage |
| `logs/common_ui_integration.log` | `76` checks, `0` failures |
| `logs/ui_composition.log` | `109` checks, `0` failures |
| `logs/lifecycle_contract.log` | `209` checks, `0` failures; `28` routes and `392` geometry records |
| `logs/ui_reflow.log` | `756` checks, `0` failures |
| `logs/responsive.log` | `97` checks, `0` failures; developer study reached through F1 |
| `logs/route_ui.log` | `945` checks, `0` failures; all `28` route scenes |
| `logs/route_smoke.log` | `28` screens, `0` missing/capture errors |
| `logs/combined_addons.log` | `155` checks, `0` failures |
| `logs/border_render.log` | `135` native-render checks, `0` failures |
| `logs/editor_import.log` | clean import and global-class registration |
| `logs/strict_validation.log` | approved change validates `Valid` in strict mode |
| `git diff --check` | exit `0`, no output |

The unique assertion-bearing accepted suites total `2,632` checks with `0`
failures.
The focused lifecycle digest remains exactly
`550b91a79fa9c5ae30bc3f736629e78429c25f56e0fc4c52bbecf38e60fa1e03`,
matching accepted task 8.1 evidence. Its per-resolution geometry digests also
remain unchanged at 1920x1080, 1600x900, 1280x720 and 960x540.

Accepted logs were searched for `ERROR:`, `SCRIPT ERROR:`, `WARNING:`,
`FATAL:`, failed-condition diagnostics, nonzero failure summaries, orphan
reports and leaks; there were no matches. Every accepted process exited `0`.

## Native capture matrix

The existing single-mount lifecycle harness captured the activation-owned
Continue focus using the real Compatibility renderer after code settled.

| Resolution | Capture | Runtime result |
| --- | --- | --- |
| 1920x1080 | `captures/1920x1080/main_menu.png` | `failures=0`, exact 1920x1080 image |
| 1600x900 | `captures/1600x900/main_menu.png` | `failures=0`, exact 1600x900 image |
| 1280x720 | `captures/1280x720/main_menu.png` | `failures=0`, exact 1280x720 image |
| 960x540 | `captures/960x540/main_menu.png` | `failures=0`, exact 960x540 image |

All four final captures are byte-identical to the accepted implementation
captures. Continue owns the visible focus treatment; the existing
desktop/compact composition remains nonempty and free of obvious new overlap or
clipping. Independent visual acceptance is not claimed here.

## Scope and remaining boundaries

- No inventory/loot layout, new screen, game authority, presentation-view
  contract, vendored add-on, Forge source, truth spec or task ledger changed.
- Task 8.3 still owns project logical action metadata, binding/glyph resolution,
  rebinding and broader controller-detection behavior.
- Task 8.10 still owns the exhaustive CommonUI modal/focus/action-routing,
  rebinding and adaptive-regression port. This packet adds only the focused 8.2
  lifecycle/navigation coverage needed to prove the ownership replacement.
- Synthetic keyboard and controller events cover deterministic input routing;
  no physical controller was attached, so physical-device detection and glyph
  evidence remain task 8.3/8.10 boundaries.

`frozen_sources.sha256` seals the production dependencies, focused tests,
accepted logs and native images reviewed for this implementation.
