# Live offline map publication

## Actual pushed implementation

Production baseline: `82ecaa960d9b2a09033782a78e9069911ecda32f`.
Implementation commit: `a7d634b2be1e0c4348ce7acdd383d17d8e523831`.
PR #33 branch: `feat/offline-native-raids`.

All 39 candidate source/resource/test/report files were published in that commit.
The guarded transfer verified exact Git preimages and every resulting SHA-256,
including Blackwater's unchanged saved native scene. The source transfer was tested
locally first. Hosted publication job `105379589070` in run `35273870329` then
passed every verification and fast-forwarded only the authorized branch. It did
not change main, merge the PR, force-push, mutate addon/image files or claim a
rendering result from source serialization. All temporary payload files were deleted.

The subsequent commit removes the one-use publisher workflow and replaces the
initial source-only workflow with ordinary read-only verification. Final CI has
contents-read permission, no persisted Git credentials, no source expansion and
no commit/push step. No font binaries or internal runtime archives are delivered.

## Already executed local evidence

The production sources match the completed local native runs:

- All-map actual-file input-driven matrix: 21,423 check executions / 0 failures.
- Graphical native-map launch/briefing/HUD and recovery: 2,373 / 0.
- Four actual raw 1920x1080 captures from the production UI and live map host.
- Six runner-unit tests, 23 output-policy tests, full source policy and original
  eleven-PNG verification pass.
- Sawmill/native progression, movement/navigation, locomotion, hitbox, vision and
  AI compatibility results are recorded in VALIDATION.md, including the historical
  failed bound assertion and its explicit 881/0 replacement regression.

The live-map flow does not use a review walker, developer route forcing or a
fixture presentation provider. The automation does pace canonical ticks and follow
advisory paths, and it reads actual actor state to aim through normal input.
This is functional integration evidence, not an unassisted human real-time playtest.

## Hosted verification status

The new `Native offline raid integration` workflow runs source checks plus the
full six-scenario Sawmill/Northline/Blackwater native matrix on macOS using the
committed extensions and exact locked engine. Its results must be inspected after
execution; publication success and this document do not imply native CI success.
The final status is recorded on the PR with exact workflow and source IDs.

## Release boundary

Both native maps are now selectable offline gameplay candidates in the ordinary
bunker briefing. Each has three searchable caches, one active named exit, one scav
and one mutant. The remaining scenery is not automatically interactive. Map/loot
population and balance, controller/human acceptance and real-time 60/120 FPS targets
remain open. Large-map validation/navigation preflight remains synchronous.
Local-only persistence, original-source fidelity and existing Sawmill behavior
are retained. No Steam/session/server/cloud requirement has been introduced.
PR #33 remains draft and unmerged for acceptance review.
