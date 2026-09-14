# Zerkov native execution report

**Date:** September 14, 2026
**Result:** Standard Godot now executes successfully in the working Linux x86_64 environment. The original movement GDScript passes its native contract unchanged. The .NET edition reports its version but does not initialize a clean .NET environment.

## 1. Executables and provenance

Both user-supplied archives were extracted after checking member paths and excluding unsafe archive entries. Their executable version queries returned:

```text
Standard: 4.7.2.stable.official.ed1daf0bf
.NET:     4.7.2.stable.mono.official.ed1daf0bf
```

These are observed version strings. Archive and executable SHA-256 hashes are recorded in `SOURCE_MANIFEST.json`; this report does not claim independent authentication against a vendor-signed release manifest.

The isolated project contains the exact original `z_movement_step_2d.gd` and `movement_step_contract.gd` from the previously supplied starter package. No edits were needed for native execution. It also contains the real repository `ZWorldUnits` and `ZUnitConversion` sources at commit `55362911aa089c3b87100697181a982eebd3c209`, not substitute classes. Their Git blob SHA-1 values were reproduced exactly after writing the retrieved source files.

## 2. Actual native results

| Execution | Outcome | Scope |
| --- | --- | --- |
| Standard executable version query | Pass | Reported pinned version |
| Standard headless editor import | Pass | Isolated project; clean diagnostics |
| Original movement contract | 24 scenarios, 36 checks, 0 failures | Unmodified GDScript, executed by Godot |
| Extended native movement checks | 5,000 collision cases; two 10,000-tick traces; 210,003 checks, 0 failures | Generated-case comparison, blocker-order invariance, full movement records, read-only results, repeated trace digests |
| Synthetic native renderer probe | 8 checks, 0 failures; 1920x1080 output | OpenGL Compatibility, virtual X11 display, Mesa llvmpipe software renderer |
| .NET executable version query | Pass | Does not establish .NET runtime initialization |
| .NET runtime/GDScript attempt | Not a clean pass | GDScript reports 36/0, but .NET startup emits errors |

Core result lines:

```text
MOVEMENT_STEP_RESULT scenarios=24 checks=36 failures=0
MOVEMENT_NATIVE_EXTENDED_RESULT cases=5000 trace_ticks=10000 trace_runs=2 checks=210003 failures=0 digest=7a419567085ad052735fd1471e9f6132b797ceb0a8301ec374493cdfd19c19e8
ENGINE_RENDER_PROBE_RESULT checks=8 failures=0 output=1920x1080 display=X11 renderer=gl_compatibility
```

The original and extended contracts were also repeated through the packaged command-line runner, with the same results and trace digest. These are repeated executions, not additional distinct tests. The large extended assertion count must not be interpreted as that many separate gameplay scenarios.

For the 5,000 collision cases, the fixture generator cross-checks expected positions against an independent cell-by-cell oracle for the declared X-then-Y collision path. Godot then runs the actual GDScript and compares its results. The 10,000-tick traces compare against the prior Python model and repeat natively to test determinism. That cross-language agreement is not a proof of correctness for every possible input.

## 3. Graphics capability and limitations

A real, non-headless Godot process ran under Xvfb with the Compatibility renderer and software OpenGL. It verified the physical window and viewport before constructing the test scene, read back a 1920x1080 framebuffer, checked pixels for a known colored primitive and background, and saved a PNG. The image was inspected.

This is a synthetic engine-capability probe, not the Zerkov HUD, Sawmill world, or a gameplay screenshot. No smaller output was used. The graphics driver emitted one warning that V-Sync mode changes are unsupported; the warning remains in the logs. Software-renderer performance is not representative of a player's GPU, and this does not prove interactive gameplay feel or visual acceptance.

## 4. Why the .NET build is not accepted yet

The .NET build's runtime attempt emitted:

```text
ERROR: sh: 1: dotnet: not found
ERROR: .NET: One of the dependent libraries is missing.
ERROR: .NET: Failed to load hostfxr
```

It also emitted `Can't open display: :0`. The process nevertheless returned exit code zero and printed the passing GDScript result. This demonstrates why diagnostics must be inspected in addition to return codes. No C# compilation, .NET runtime execution, or clean .NET editor session is claimed. The standard build does not encounter these .NET errors and is sufficient for the current movement tests.

## 5. What remains unverified

The full Zerkov project has not been imported or launched here. Direct retrieval into the shell again failed with a DNS error for `raw.githubusercontent.com`; selected text sources were retrieved through the GitHub connector instead. There is no complete local checkout in this validation package.

The repository's Linux artifact report at the pinned commit records all six locked Linux extension shared objects as missing. That is repository-recorded blocker evidence, not a freshly executed full-checkout artifact scan. Installing the engine does not supply those game-specific native libraries. The report is at:

`docs/platform/linux-x86_64-headless.md`

Source: https://github.com/mai1015/zerkov/blob/55362911aa089c3b87100697181a982eebd3c209/docs/platform/linux-x86_64-headless.md

Authority-phase integration, input admission, Sawmill collision-data baking, camera mapping, inventory/world interaction, full-raid settlement, and human playtests remain outside this test. Tasks 3.5 and 3.6 remain incomplete. No repository files, branch, or pull request were changed.

## 6. Next implementation boundary

The previous limitation “GDScript not natively tested” is resolved for this movement component. The next work is to connect this tested calculation to the game-owned movement state and `RaidAuthority` MOVEMENT phase using authored Sawmill collision geometry. Full-project Linux validation still needs a local checkout and the matching native add-on libraries. No engine upgrade, .NET migration, or replacement of the existing authority architecture is implied.
