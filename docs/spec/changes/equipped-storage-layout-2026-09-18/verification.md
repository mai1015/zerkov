# Corrected equipped-storage validation

## Published implementation

PR #47: `codex/equipped-storage-review`.
Tested implementation commit: `24a4c317af0af4a8628befe8ef7920e9ad58d61a`.
Exact source tree: `a0a09982d735279ea61d874fb89f4238d30ae5f4`.
Parent merge `6be2bf98c909c1bb9db3d780d6d70a59badbffd9` incorporates main
`2154994e97b93e6d12510f660878b4355558117d`.

The final bookkeeping update changes only this document and tasks.md. Runtime,
tests, workflows, assets, locks and capture guards are unchanged from the tested
implementation. This PR is for review, not an instruction to merge.

The earlier local-only patch and its replacement action-strip screenshots are
superseded. Final evidence uses the original authored numbered Quick Use row.

## Verified exact-head native CI

Pinned macOS Godot `4.7.2.stable.official.ed1daf0bf`, actual checkout addons and
normal editor import. Workflow `35414498820` completed successfully. Downloaded
result files explicitly identify the tested implementation SHA.

| Contract | Checks / failures |
| --- | --- |
| Storage: New Game / independent Continue | 217 / 0; 110 / 0 |
| Contextual loot: New / Continue | 1317 / 0; 22 / 0 |
| Offline journey: New / Continue | 277 / 0; 137 / 0 |
| Full local raid cycle, workflow 35414498889 | 4270 / 0 |
| CPU profile control / instrumented, unchanged retry | 311 / 0; 311 / 0 |

The full-cycle log includes extraction, settlement-write retry, abandonment,
death, recovery and redeployment. The Equipment UI, Combat, Raid Progression,
Native offline raid integration, bunker-workspace and unified-bunker workflows
also completed successfully on the implementation commit. All 18 listed PR
workflows were successful after the single profiler retry described below.
These results do not mean multiplayer or platform exports are qualified.

Archive identities verified after download:

- Exact source artifact 10575227714: SHA-256
  `0d68f349d0bda21d70dd123291574926bf2675c8e08f4fb7f3d1c9a3cb4cb4f6`.
  Reconstructing its files and executable bits yields the exact Git tree above.
- Journey/loot/storage artifact 10575003209: SHA-256
  `3086f78be4d2f7b6afe505f7bf90cbf1dd5d5b10858e9e4e60804dec4b3f8251`.
- Full local-cycle artifact 10574798401: SHA-256
  `7fdd856e78913ee2614e2f300949360d8a90a1760a8442f947890814ae7a70a6`.

Storage New and Continue preserve the same committed profile fingerprint:
`b7b37251d4ab1a2aa710aec07f2717eb32864f8f9d8f8643e2d17c62c0f70117`.
Counts include repeated tick/assertion checks, not independent scenarios.

The existing runner controls (19 tests), repository policy tests (23 tests),
and exact-1080 gate were additionally rerun successfully against the exact
source archive during final review. No Godot or screenshot behavior is mocked
by those Python policy tests.

## Fresh graphical verification of the published source

A new Linux graphical run was executed during final review, not inferred from
the previous screenshots. New Game passed 224 checks; independent Continue
passed 112 checks; both had zero failures and the same fingerprint as CI.
All cleanup completed. Every tracked source file remained byte-identical to
the exact-head archive after import and execution.

Nine raw 1920x1080 PNGs passed the unchanged physical-window, viewport, texture
and image guard. They cover no gear, explicit native fixture gear, Secure at
the shared-scroll bottom, legacy recovery without grids, Character in a raid,
and the original Quick Use controls on the HUD. The frames were inspected;
the review packet includes the raw PNGs, full logs and individual SHA-256 hashes.
Any reduced contact sheet is inspection-only, not a native-resolution capture.

The graphical environment is Linux x86_64, Xvfb at 1920x1080 and Mesa llvmpipe.
Engine SHA-256:
`8d106cbe6144c2dc7e881d61d2429c1a8a76e6b22ef48bd5e48dcf934953f71e`.
It uses the previously built native libraries from `a609daff...`, each checked
against the supplied manifest, in a separate runtime copy. Explicit extension
startup is used for the already documented Linux cold-discovery limitation.
No script doubles, fixture presentation provider, gameplay substitution or
source modifications are used. The driver reports unsupported V-Sync changes;
this is not a zero-warning, real-time performance, ordinary cold-import or
export qualification claim.

Test equipment and legacy items are explicitly inserted native fixtures in
isolated save namespaces. They do not alter production starter gear. Real mouse
input unequips the rig and hides its grid; re-equipping the same native item
restores the correct dimensions. Repeated refresh/reflow and attempted show()
cannot resurrect absent-gear grids. Legacy recovery buttons submit ordinary
revision-checked moves without exposing storage cells. Stale recovery and
invalid incoming capacity requests preserve inventory state.

## Profiler import failure and unchanged retry

The first attempt of CPU-profile workflow `35414498843` failed during its
control-mode editor import, before the control/instrumented gameplay comparison.
Its prior health-catalog contract had passed 806 checks. The retained log does
not establish the cause of the import termination; no engine fix is claimed.
The profiler script, workflow and clock driver are unchanged from the parent.

Only failed job `105820330493` was retried, without editing code, skipping an
assertion, adding continue-on-error or relaxing any gate. Replacement job
`105823400493` completed successfully: control and instrumented authority
traces match, and the original checkout is unchanged. The initial failure is
preserved alongside the successful retry in the review evidence.

- Failed-attempt artifact 10574758608: SHA-256
  `8da4083f574e448ce04e498f49f4bc1a78114c0af9db21a968ee855bb358fa2c`.
- Successful-retry artifact 10575134719: SHA-256
  `219ee3ab8e7c6096833443417c5a728a65789ad861a0e594992fbde48f435875`.

## Remaining boundaries

The existing Quick Use design is reused, not a new bar or assignment backend.
Slots 5-8 remain explicitly unavailable; no sample item/count is shown as real.
The V1 save format still keeps storage roots separate from provider items, so
filled providers must be emptied before removal. Restricted automatic transfer
uses whole-stack valid placement, not cross-inventory stack merging or partial
success. No profile migration, addon/engine lock, starter kit, catalog, art/font
binary or map changes are introduced by this correction.

User visual/controller acceptance remains separate from automated test success.
