# Inventory UI binding evidence

This is a retained historical evidence packet. Its smaller-resolution and
compact probes are not part of the current first-playable matrix; current
agents/tests MUST NOT invoke or regenerate them until task 11.8 or a later
approved display-support proposal. The immutable packet and source seals are
not current aggregate checks.

The accepted checkpoint packet is
[`astra_final_accept/REPORT.md`](astra_final_accept/REPORT.md), with machine
totals in [`astra_final_accept/audit_summary.json`](astra_final_accept/audit_summary.json).
It records the fresh Astra ACCEPT CHECKPOINT for task 4.7b: 31 distinct final
suite/probe variants, 4,228 checks, and 0 failures across 1920x1080, 1600x900,
1280x720 and 960x540. The packet also records the native continuous flow
(`88/0`), compact continuity (`34/0`), promoted compact selection (`37/0`),
sealed regressions (`18/0` and `17/0`), and the independent challenge (`112/0`).

`astra_gate/`, `astra_recheck/`, `astra_final/` and `astra_acceptance/` are
retained rejection/repair history. They are useful for audit context but are
not substitutes for the final accepted packet. The final report calls out the
two unsuccessful challenge-authoring attempts separately; they are excluded
from the accepted 31-variant total.

## Recommended checkpoint evidence subset

To keep the checkpoint self-contained without committing every iterative raw
capture, stage:

- this README and `astra_final_accept/REPORT.md`;
- `audit_summary.json`, `evidence_manifest.json`, `sealed_probe_comparison.json`,
  `headless_results.json`, `native_results.json`, `reviewed_sources.sha256`,
  `reference_comparison.json` and `reference_comparison.png`;
- `native_flow.gd`, `native_flow_sheet.png`, and
  `flow/native_flow.json` for the continuous native sequence;
- `compact_continuity.gd`, `compact_native_selection.gd`,
  `flow/compact_continuity.json`, and the five compact continuity frames under
  `flow/`;
- the four resolution state sheets (`1920x1080_states.png`,
  `1600x900_states.png`, `1280x720_states.png`, `960x540_states.png`) plus
  `section_and_overlay_sheet.png` and `native_flow_sheet.png`.

This subset is roughly 5.2 MB and preserves the report, exact machine totals,
source-hash/manifest links, native flow proof, compact proof and resolution
visual proof. Keep the remaining `core/`, `flow/`, `honesty/`, `p2/`, promoted
captures and per-suite logs available locally for investigation; they are
optional duplicates for this checkpoint rather than required proof. Do not
stage the earlier rejection directories unless a later audit specifically needs
their history.

This evidence covers the scoped macOS native inventory binding only. Human
playtests, the complete raid loop, multiplayer, and other-platform release
acceptance remain open.
