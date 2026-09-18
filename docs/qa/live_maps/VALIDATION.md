# Native offline map integration — actual execution

## Scope and lineage

This follows merged preparation PR #30, native-world PR #24 and original-PNG PR
#32. Production baseline: `82ecaa960d9b2a09033782a78e9069911ecda32f`.
The previous PRs do not constitute live-map acceptance. This implementation adds
Blackwater's previously delivered native environment and connects both native maps
to the existing local campaign/raid owners, preserving Sawmill and bunker flows.

The container's direct GitHub DNS lookup failed. Exact source was reconstructed
from authenticated workflow artifact 10516962757 (run 35266786887), checking every
selected source SHA-256 and Git blob identity. Local Git history is a reconstruction,
not a claim of a full local clone. Runtime files came from the existing project CI
build artifact 10516707485, run 35265222105, built at a04ecfb825a2be5b19baf08c70e61d2ac644510a.
All six addon source subtree Git IDs were independently compared with baseline and
are identical. No addon source, descriptor, package lock or engine lock is changed.
The internally restored existing UI font dependencies are never included in user
evidence packages. Original PNGs are already committed and no longer a blocker.

## Local native results

Pinned standard engine: `4.7.2.stable.official.ed1daf0bf`.
Executable SHA-256: `8d106cbe6144c2dc7e881d61d2429c1a8a76e6b22ef48bd5e48dcf934953f71e`.
Host: Linux, native compiled project extensions, Compatibility/OpenGL under
1920x1080 Xvfb for graphical runs. The full application is cold-copied with no
`.godot` cache or seeded extension list, imported, then executed. Full-copy imports
in both final runs exit zero without engine/script errors. This does not establish
all-platform editor/export qualification or repair an engine lifecycle defect.

The final headless runner completed **21,423 check executions, zero failures**.
Its actual input-driven scenarios are:

| Map | Extract / retry / redeploy | Enemy-driven death |
| --- | --- | --- |
| Sawmill | 3,561 / 0 | 592 / 0 |
| Northline | 5,581 / 0 | 1,142 / 0 |
| Blackwater | 7,296 / 0 | 904 / 0 |

The total also includes 2,263 core assertions, two independent fresh-process saved
fingerprint reads after each scenario, and cleanup checks. Counts are repeated
assertions and per-tick/geometry checks, not distinct gameplay cases. Native flow
uses actual Godot input through the normal title/menu/bunker briefing/loot/HUD
widgets, not an inspection walker or fixture presentation provider. The test root
paces the real canonical tick explicitly; automatic input follows the real advisory
path and reacts to visible enemies. It is not a human or real-time FPS playtest.

Each extract scenario searches three map-specific caches, transfers the objective
through the existing loot controls, reaches its actual zone, injects one failed
settlement write, clicks the existing retry action, returns to bunker and deploys
again. Shutdown/reload of that second session applies existing abandonment policy.
The two separate processes load the actual files and compare the final fingerprint.
Death scenarios receive damage from the real enemy combat pipeline; they do not
set a fake death flag. Existing secured/unsecured loss and health policies remain.
The map descriptor survives recovery without loading or resuming the map.

The final graphical runner completed **2,373 checks, zero failures**: the same
2,263 core checks and both native maps' actual briefing/deployment/launch/recovery
runs. Its four raw captures show the current production briefing and live HUD.
The physical Window, viewport, texture and image must all be exactly 1920x1080;
no resize, offscreen-only substitute or generated concept image is accepted.
The guarded capture code is unchanged in policy, and no font binary is bundled.
Graphical subprocesses retain the known unsupported-VSync notice; no SCRIPT ERROR,
ERROR or parse diagnostic is present in the accepted runtime logs. Pixel-repeat
comparison across platforms is not claimed for these UI captures.

## Domain and compatibility contracts

The core suite checks all map source dependencies and original PNG hashes, exact
scene-derived blockers and valid/reachable production-body approaches, duplicate
and foreign map anchor rejection, convex polygon geometry, repeated query identity,
1,024 movement colliders with 1,025 rejected, unchanged generic canonical budgets,
and native import without an inspection actor. Northline has 681 blockers;
Blackwater has 189 including the one new saved EastRoadSupply crate. The original
Blackwater environment is not rewritten. Water blocks movement, not gunfire/sight.

Integer convex SAT/sweep tests compare rectangular polygons against the existing
rectangle resolver over 990 steps with both windings. Exact rational boundaries
handle sub-microunit intervals without overflow or rounding a crossing into a
false free path. New navigation checks swept corridors between free tile centers;
a thin sealed wall must reject and an actual doorway must admit a detour.
A 4px conservative navigation allowance handles steering tolerance without shrinking
the physical player (still 8px half-extents). Sawmill defaults are unchanged.

Explicit fake storage/inventory ports are used ONLY by the separate exhaustive
persistence checkpoint suite: deployed/prepared/committed states on all three maps,
identical retries, conflicting-map request rejection, malformed map fields and
legacy fieldless Sawmill compatibility. The input-driven scenarios use actual
ProfileStore files in isolated test namespaces and the existing one-shot failure
injection for retry; no user's save is opened or deleted.

Existing native progression contracts passed (311 and 446 checks), navigation
(611), locomotion (166), base/adversarial/review/capability hitboxes (111/173/72/14),
vision world (305), native AI vision (438), and native AI owner (38).
The existing movement regression initially expected the old fixed 512 maximum;
it now retains that case and also tests the explicitly increased bound, including
an unchanged overflow rejection. Its final result is 881 checks, zero failures.
Six runner-unit tests and all 23 repository output-policy tests pass; the full
source-policy command passes without weakening the exact-capture guard.

## Defects found rather than bypassed

Earlier attempts exposed missing native runtime files, reserved-keyword/type
errors in new test code, review markers that a real body could not reach, thin-wall
center-only navigation, a Blackwater steering corner, and incorrect/clipped authored
briefing text. Those attempts were not counted as passing. The fixes install the
existing matched native runtime, type/validate the actual code, author viable
approaches, add one real crate, test swept corridors, reserve a small advisory
margin, and populate the retained UI from map identity. No collider is dropped,
river replaced by an oversized box, body shrunk, test teleported or capture resized.

## Remaining acceptance and known limits

This is a first live offline integration: three mission caches, one active exit,
one scav and one mutant per map. Other review exits/props are not automatically
interactive. Population, loot economy and routes still need human balancing.
No Steam/network/server or new save backend is added. Map selection is available
only in the current home briefing; stale/active/settling requests cannot switch
raid content. Original fieldless saves remain valid and interrupted live maps do
not resume mid-raid after restart.

Large-map integrity/navigation preflight is synchronous, and real-time performance
remains an open gate. Functional tick-driven tests do NOT certify 60/120 displayed
FPS; the current debug runtime can exceed a 16.7ms tick budget. Existing automatic
pacing and game rules are not slowed or altered by this change to manufacture a
performance pass. A target-hardware graphical playtest and profiling/optimization
remain necessary before calling this release-ready.

Local checks are complete. Remote publication/CI status is recorded separately
in the PR after the exact tested source is pushed. Do not infer CI success from
this local record or mark human/controller/export acceptance complete.
