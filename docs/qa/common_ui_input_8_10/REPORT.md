# Task 8.10 — CommonUI input and modal regression evidence

Status: implementation evidence only; Task 8.10 remains unchecked pending
independent review.

Implementation base: `64e01051e6676c9582ce5409b683d542dddc8686`.
Engine: Godot `4.7.2.stable.official.ed1daf0bf`, headless Compatibility
renderer.

## Outcome

The accepted authored Controls screen now resolves its binding rows from the
game-owned `ZerkovInputService` and commits keyboard, mouse and controller
captures through CommonUI's binding registry. The retained scene, layout,
theme and 1920×1080 geometry are unchanged; the old fixture binding table is
used only when an isolated preview has no product input service.

Capture is owned at the `_input` stage so Escape cancels, Backspace clears an
optional slot, and an accepted physical candidate cannot also trigger a route
action. CommonUI modal ownership suspends the covered screen, contains focus,
and restores the exact prior control after keyboard, controller or pointer
dismissal. Deactivated Controls instances invalidate pending capture state.

## Focused runner

`tests/common_ui_input_regression_1080.gd` statically pins the viewport to
`Vector2i(1920, 1080)` and covers:

- live CommonUI row resolution with no production fixture binding table;
- keyboard rebind, persistence reload, optional clear and controller rebind;
- rebound action dispatch from the active screen through the typed route boundary;
- UI action collision preview and rejection without route/state mutation;
- keyboard Escape, controller B and pointer Cancel modal ownership;
- prompt focus containment and stale callback dismissal;
- stale deferred capture input after a route transition;
- context lease release and host/screen teardown invalidation.

All screen-producing runner output in this packet is exact `1920x1080`.

## Executed checks

| Evidence | Result |
| --- | --- |
| `godot --headless --editor --quit --path .` | exit 0; clean import/class registration |
| `common_ui_input_regression_1080.gd` | `40` checks, `0` failures; viewport `(1920, 1080)` |
| `common_ui_navigation_1080_regression.gd` | `94` checks, `0` failures; exact 1920×1080 modal/focus/action path |
| `zerkov_input_bindings_contract.gd` | `380` checks, `0` failures; exact 1920×1080 action/rebinding path |
| `git diff --check` | exit 0 |

No task ledger, truth spec, add-on or inventory surface was changed. This
report intentionally does not mark Task 8.10 complete.
