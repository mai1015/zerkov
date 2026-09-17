# Pre-multiplayer validation report

**Review date:** 2026-09-17
**Reviewed baseline:** `main` at `36e363625861e3fe3758c345181a66891facdabd`
**Locked engine:** `4.7.2.stable.official.ed1daf0bf`
**Decision:** the implemented offline/local first-playable is a coherent functional pre-multiplayer milestone. The task ledger and CI coverage were stale, but this review did not find a new gameplay-policy defect that justified changing production behavior.

This is not release approval. Real-time raid performance, non-vital destroyed-limb consequences, remaining visual/tuning/human acceptance, cross-platform packages and all live multiplayer work remain open.

## Scope

The review covered the repository and product layers that are expected to exist before multiplayer:

- repository registration, source-scope and exact-1920x1080 policy;
- deterministic combat input/HUD values;
- deterministic AI, hearing and review regressions;
- raid progression, ProfileStore and settlement recovery;
- the merged F5 local product flow and its four native scenarios;
- the task ledger through section 9, without promoting human or release gates;
- CI workflows that were supposed to protect the merged game cycle.

The repository currently carries macOS native add-ons, not Linux native add-ons. Linux therefore provides portable source-isolated validation only. Native combat, AI, progression and complete-application acceptance remain macOS jobs and must fail rather than silently skip when the checked-in libraries cannot load.

## Fresh portable execution

A read-only materialization commit added only a temporary packaging workflow to the reviewed `main` tree. That workflow produced the locked Linux engine and source archive; the temporary workflow itself was excluded from the test checkout. The engine archive SHA-256 was `cadd3204e728a35d3f13adb7fd0d7902636b79f6b95c40c265eb73b6c35329e4` and `--version` matched the complete lock string above.

The following completed against the reviewed source:

| Layer | Fresh result |
| --- | --- |
| Tooling/source-policy discovery | **187 tests passed** |
| Exact output/source registry | `FIRST_PLAYABLE_1080_GATE passed=true`, 1920x1080, 640x360 world, integer scale 3 |
| Combat replay | **3,595 checks / 0 failures**, twice, identical digest |
| Combat HUD values | **34 / 0** |
| AI replay | **2,164 / 0**, twice, identical digest |
| Noise service | **341 / 0** |
| AI review regressions | **235 / 0** |
| Raid progression | **311 / 0**, twice |
| ProfileStore | **527 / 0** |

The repeated combat digest was `b8c5c5215ef63dc1ec600004354a15dbc7116c074bd9c242b9f869ceb73dd6ff`. The repeated AI digest was `faffd3cee28c2a32f54b5e710aa841e6bf9ebc43e1c368fd38ac4f745bb7f0f8`.

`tools/run_pre_multiplayer_validation.py` now owns this portable sequence and the supported native/local-flow sequences. It verifies the complete engine version before execution, preserves each existing runner's diagnostic rules, stops on the first nonzero result and treats timeout as failure.

## Native product evidence and task reconciliation

The merged local-flow work already exercised the real macOS add-ons and complete application through player input. Its final accepted scenarios are:

| Scenario | Accepted result | What it establishes |
| --- | ---: | --- |
| Complete flow | **4,063 / 0** | new/continue, loadout, deployment, movement, search, loot UI, combat, Tasks/Maps, extraction, failed-save retry, summary, return, redeploy, abandonment and recovery |
| Enemy death | **585 / 0** | real AI perception/movement/melee, terminal settlement and post-death recovery |
| Clock | **293 / 0** | canonical post-tick HUD clock and approved solo pause behavior |
| Launch | **54 / 0** | missing/valid/corrupt local-save entry behavior and independent-process continue |
| Native combat execution | **439 / 0** | weapon/reload/melee/health execution through shipped add-ons |
| Native death races | **1,283 / 0** | four death-during-action races with no late duplicate consequence |

These results support closing five implementation clauses that remained incorrectly unchecked:

- **5.10:** deterministic cadence, empty-ammo, stale-revision, reload-race, duplicate-action and death-during-action regressions;
- **7.3:** authoritative raid timer and derived HUD clock;
- **8.5:** live HUD binding;
- **8.7:** live Tasks/Maps binding and unavailable-feature gating;
- **8.8:** deployment and committed-summary lifecycle binding.

Closing these clauses does not close their neighboring qualitative acceptance work. In particular, combat readability/tuning, controller and visual review, ten-cycle soak, integrated art/audio/VFX and blind play remain open.

## Gaps repaired

### Stale CI ownership

`merged-game-cycle-audit.yml` and `normal-launch-flow.yml` checked out a fixed pre-integration commit (`cb8bc50e72b631664c9f1fb2a59ee5e84249fbae`). A green run therefore could not protect the current branch. They are retired in favor of:

- the current-head portable `pre-multiplayer-validation.yml` gate; and
- the existing current-head `local-first-playable.yml` native scenario matrix.

The local-flow path filter now includes workflow changes, so changes to validation ownership cannot bypass the native product matrix.

### Launch documentation

The current product entrypoint is F5 / `project.godot`, which launches `game/bootstrap/local/local_game.tscn`. Directly running `ui/main.tscn` is an intentionally unbound UI review host, not the game. The README and development guide now state that distinction explicitly.

### Reproducibility

Previously, a reviewer had to infer which independent commands constituted the pre-multiplayer baseline. The new orchestrator exposes three explicit layers:

```bash
python3 tools/run_pre_multiplayer_validation.py --godot "$ZERKOV_GODOT" --mode isolated
python3 tools/run_pre_multiplayer_validation.py --godot "$ZERKOV_GODOT" --mode native
ZERKOV_TEST_SCENARIO=full python3 tools/run_pre_multiplayer_validation.py \
  --godot "$ZERKOV_GODOT" --mode local-flow --scenario full
```

`native` and `local-flow` require a supported host with the shipped add-ons. Missing native support is a failed prerequisite, not a passing skip.

## Explicitly unresolved

The following must not be inferred as complete from this validation:

1. **Real-time performance:** the composed raid simulation remains substantially above a 60 Hz tick budget. Separate performance work is active; functional CI is not FPS acceptance.
2. **Destroyed non-vital limbs:** zeroed non-vital zones do not yet have an accepted spillover/incapacitation policy. The enemy-death scenario proves a lethal path, not that this design issue is solved.
3. **Qualitative gameplay acceptance:** tasks 5.11-5.13, 6.10, 8.12-8.13, 9.4 and 9.6-9.11 remain open where they require readability, tuning, integrated presentation or human evidence.
4. **Full acceptance/release:** section 12 remains open, including ten consecutive extract/death cycles, physical controller/navigation coverage, target-hardware frame pacing and release-package validation.
5. **Multiplayer:** section 10 remains outside this milestone. No Steam host/join, remote authority, prediction, reconnect, cloud save or hosted service is claimed.
6. **Platform packaging:** the repository still lacks complete truthful Windows/Linux shipped add-on packages and exports.

## Review conclusion

The right correction is evidence and validation ownership, not another rewrite of the offline flow. The pre-multiplayer implementation is functional and internally consistent enough to serve as the baseline for the remaining performance/gameplay-acceptance work. It is not yet a release candidate and should not be used to justify beginning live multiplayer before the existing section-10 prerequisites are deliberately approved.
