# Fresh independent Astra gate — task 4.7b

**ACCEPT CHECKPOINT. Task 4.7b may be marked complete. Human approval remains false.**

Reviewed the dirty tree against `9f5f90388911dfe36da0978f8d8bdadfb6f9bb44`
on 2026-09-10. No remaining checkpoint-blocking production defect was found.
The previous rejection's two sealed probes now pass, as do the earlier
command-correlation, lifecycle, compact-input, extent, fixture-restoration,
artwork, and status-bound regressions. This validator changed only files in
this evidence directory. Production code, promoted tests, the task ledger,
DESIGN, the index, and HEAD were not edited or committed by this validator.

## Acceptance evidence

The two scripts from [the preceding rejection](../astra_acceptance/REPORT.md)
were rerun with only evidence-directory and inheritance paths substituted.
[Normalized source hashes](sealed_probe_comparison.json) prove their assertion
source is unchanged.

- [Live Health/Stats disclosure](logs/live_sections.log): **18 / 0**. Native
  auto 960×540 section clicks retain the live binding and expose a visible
  `FIXTURE PREVIEW` notice after transient notifications expire. The probe
  intersects labels with the viewport and every clipping ancestor.
- [Unrelated accepted receipt / tooltip](logs/compact_tooltip_refresh.log):
  **17 / 0**. A native Bandage click opens inspection; a genuine ammunition
  transfer through the production controller and adapter leaves that valid
  selected tooltip visible.
- [Additional independent challenge](logs/overlay_and_sections_challenge.log):
  **112 / 0**. Health and Stats notices fit fully at all four outputs. Desktop
  tabs use native route navigation followed by explicit public runtime binding;
  compact tabs remain on the same bound screen. An accepted command arriving
  between native Close mouse-down and mouse-up cannot resurrect the closed
  tooltip. Reopening, transferring the inspected Bandage out of its source,
  and a later unrelated accepted transfer leave the stale overlay closed.

The latest promoted presentation probes also pass (**315 / 0** and **540 / 0**),
including the retained tooltip repair and explicit Health/Stats notices.
[A clean native tooltip frame](promoted_p2/960x540_compact_tooltip_after_receipt.png)
shows the unchanged Bandage identity and confirmed quantity after the receipt.
Only the transient notification was hidden for this supplemental capture;
the sealed reproduction retains the ordinary runtime notification.

## Continuous flow and compact playthrough

[The continuous native 1280×720 flow](native_flow.gd) passes **88 / 0** in one
owner/session/screen lifetime:

1. Open and bind explicit owner, bridge, adapter, and admitted identity.
2. Native item selection and typed `sealed` search produce zero requests or
   canonical revision changes.
3. Real drag places Sealed Documents at rig `(2,0)` with one request.
4. R rotates once; echoed R submits nothing.
5. Ctrl-drag opens the CommonUI quantity modal; modal-suspended R and native
   Cancel submit nothing. A repeated Ctrl-drag, native typed `10`, and Confirm
   split the original 60 stack into 50 and 10 at exact rig `(4,0)`.
6. A native occupied-slot drop merges once, preserves target item 6 at quantity
   60, and removes split source item 9.
7. Ctrl-click completes one authority-selected transfer without a UI first-fit
   destination or partial-transfer behavior.
8. A documented concurrent canonical rotation after pending begins produces a
   real `destination_revision_stale` rejection. The rejected world item keeps
   its latest canonical location and the stable reason is displayed.
9. Resynchronize, disconnect, explicitly rebind, then issue a fresh successful
   native rotation without replay/command-ID collision.

See [runtime log](logs/native_flow_typed_quantity.log),
[receipts and sequence metadata](flow/native_flow.json), and
[native sequence sheet](native_flow_sheet.png). Canonical stack seeding,
explicit lifecycle transitions, and concurrent-authority injection are direct
test seams; the inventory gestures and quantity typing use Godot Controls and
Viewport input. This is automated native playthrough evidence, not a human
playtest or a complete raid loop.

The separately constructed [960×540 compact continuity flow](compact_continuity.gd)
passes **34 / 0**: native section and Loot clicks, wheel travel to both exact
terminals, return to origin, ordinary Bandage click, exact selection/focus,
on-screen tooltip, and typed `bandage` search with no commands or changed corpse
bytes. The promoted compact-selection probe passes **37 / 0**, including
rendered scroller visibility at every settle frame and preserved focus/hover.

| Source | Canonical grid at 74 px | Native page | Native wheel terminal |
| --- | --- | --- | --- |
| Stash | 888×1480, 12×20 | 632×156 | `(256,1324)` |
| Corpse | 740×592, 10×8 | 632×156 | `(108,436)` |

The independent compact flow assigns no scrollbar offsets; both final cell
centers are actually within the retained pane. The older supplemental compact
stage inside `native_flow.gd` includes explicit clamp assignments and is not
used as the proof of native terminal reachability.

## Exact current results

| Suite/probe variant | Checks | Failures |
| --- | ---: | ---: |
| authority | 79 | 0 |
| replay | 81 | 0 |
| equipped_reconciliation | 123 | 0 |
| binding | 138 | 0 |
| multi_controller | 23 | 0 |
| reentrant | 28 | 0 |
| compact_extent | 19 | 0 |
| inventory | 21 | 0 |
| compact_inventory | 42 | 0 |
| projection | 99 | 0 |
| intent | 162 | 0 |
| mutation | 146 | 0 |
| composition | 109 | 0 |
| responsive | 96 | 0 |
| reflow | 756 | 0 |
| components | 15 | 0 |
| independent_surface | 68 | 0 |
| fixture_status | 52 | 0 |
| compact_continuity | 34 | 0 |
| compact_native_selection | 37 | 0 |
| sealed presentation_honesty | 528 | 0 |
| sealed p2_presentation | 299 | 0 |
| native_flow_typed_quantity | 88 | 0 |
| native_pointer | 20 | 0 |
| compact_visual | 23 | 0 |
| core_capture | 140 | 0 |
| sealed live_sections | 18 | 0 |
| sealed compact_tooltip_refresh | 17 | 0 |
| overlay_and_sections_challenge | 112 | 0 |
| latest promoted_p2 | 315 | 0 |
| latest promoted_honesty | 540 | 0 |
| **31 distinct suite/probe paths, 31 final executions** | **4228** | **0** |

These are raw executed assertion counters, including setup and capture checks;
they are not 4,228 independent gameplay scenarios. The sealed and latest
presentation-probe variants overlap substantially. The final set has no
assertion ERROR, SCRIPT ERROR, stack overflow, RID/ObjectDB/font leak, timeout,
or lingering validator-owned Godot process. Both editor imports pass. Strict
spec validation and `git diff --check` pass; the ledger and DESIGN are unchanged,
4.7b remains unchecked pending the parent agent's update, and HEAD is unchanged.

All Godot invocations used only
`/Volumes/Data/sdk/godot/editors/4.7.2/Godot.app/Contents/MacOS/Godot`, official
4.7.2 `ed1daf0bf`. The existing sibling add-on debugger was left untouched.

Two unsuccessful authoring runs of the new validator-only challenge are
preserved, not counted as passing coverage: first, missing explicit GDScript
types produced two parser errors before any checks; second, the test tried to
override a scene's forced desktop tab and requested Gold Watch from the wrong
fixture, producing **106 checks / 19 setup failures**. Only that new diagnostic
driver was corrected: it now navigates actual routes and uses a known crate
item. [Authoring record](challenge_authoring_results.json),
[setup record](challenge_setup_v1_results.json), and their retained logs explain
the failures. The whole audit therefore made **33 suite/probe invocations**
(4,334 raw assertions including those 19 invalid-setup failures), plus **two
editor imports**, for **35 Godot invocations**. No production change occurred
between these attempts. These do not conceal a failed current production test.

## Source, design, and limits

The new controller, retained grid/screen/actions/layout, scene changes,
projection bridge, adapter submission boundary, and promoted correlation,
lifecycle, native input, and presentation tests were reviewed against the
repository instructions and approved proposal, tasks, design, capability
requirements, model-routing rules, and DESIGN contract.

UI item records are detached from immutable confirmed native snapshots. Search,
filter, hover, selection, and tooltip rendering do not author canonical state.
Move/rotate/split/merge/loot/quick-transfer gestures emit strict payloads through
the adapter. Profile writes and unsupported world editing fail closed. Scope,
owner/scope generations, binding tokens, exact item facts, and captured
dependencies guard deferred input and synchronous replacement. Product command
IDs advance before pending publication, remain distinct across controllers and
models, and fail in constant time at exhaustion. Feedback resolves once.

Compact reflow retains its active workspace and tooltip; tab/release work is
deferred outside native pointer dispatch. Completed wheel capture release
preserves the scroller's coordinates and restores focus/cursor state without a
rendered hidden frame. The explicit-close serial invalidates queued restores;
source removal closes stale inspection. These claims are supported by native
input tests, not only direct callback tests.

The live-empty gear/economy actions are explicitly unavailable; fixture preview
restoration is visible and bounded at all outputs with no stale LIVE status
tooltip. Encrypted Drive and Gold Watch keep their true identities and use
neutral box artwork with visible and accessible PLACEHOLDER disclosure. Health
and Stats remain authored preview values, now visibly labeled within each
reachable section. No early health/progression implementation is claimed.

Exact auto 1920×1080, 1600×900, 1280×720, and 960×540 native captures cover ready,
pending, accepted split/merge, rejected/restored, search/no-match,
resynchronizing, disconnected, live/fixture, disclosure, and tooltip states.
All four state sheets, the flow and reference-comparison sheets, and raw
compact, tooltip, fixture, and Health/Stats frames were visually inspected.
Not every duplicate raw capture was individually inspected. The preserved
outer geometry and authored hierarchy match the approved reference; larger
canonical content is contained in scroll panes. The top-chrome pixel comparison
is **0/107520, 0/75200, 2/47360, and 0/53760** changed pixels respectively.
This narrow comparison is not a claim of full-screen pixel equality; actual
inventory content, extents, state feedback, and disclosure intentionally differ.

Core pending/rejection captures and P2 rejected captures use public presentation
seams to stage those visual states. The separate continuous flow supplies the
genuine native gesture and concurrent-rejection proof. Desktop Health/Stats
navigation is followed by explicit runtime binding because product bootstrap
and broader screen migration remain later tasks.

[Source hashes](reviewed_sources.sha256), [tracked production diff](reviewed_production.diff),
[reference comparison](reference_comparison.json), [capture manifest](evidence_manifest.json),
and [exact aggregation](audit_summary.json) make the reviewed state auditable.
CodeGraph was unavailable; no index was initialized. The frontend skill supplied
existing-design/native visual QA discipline; web/Lighthouse checks do not apply.
This gate covers macOS native Compatibility rendering and the scoped inventory
binding only. Human gates 5.13, 8.13, and 12.5, whole-game completion,
multiplayer, and other-platform release acceptance remain open.

**Disposition: mark only task 4.7b complete and create its checkpoint after the
documentation handoff. Human approval remains false.**
