# Integration with the merged live equipment UI

Main advanced to `ed9d18f7fe19b8a2a3ae0ac347b19f783fa13a9a` (PR #28) while
this contextual-loot change was being finalized. The follow-up merges that main
into the PR branch, rather than overwriting or reverting equipment integration.
The reviewed combined implementation tree is
`5e71d3d3a7b3f90a75b08db436de4806958ed14c` before this documentation file.
Independent local three-way reconstruction exactly matches GitHub's test-merge
tree; all incoming equipment, health-scope, runner and scene changes are retained.

The Character scene now uses `equipment_screen.gd`, inheriting the existing
Character workspace and its contextual-loot behavior. Its real equipment slots,
secure storage and equipment intents are retained. The inherited-screen check
in the journey suite accepts that actual subclass. The exact-output inventory
retains the newly registered equipment tests. No equipment implementation file
is modified by the contextual-loot diff against this new main.

The previous general statement that all equipment-slot integration is unfinished
is superseded by this merge: the supported native equipment slots are live.
Unsupported slots, quick-use and remaining Stats functionality keep their
existing truthful availability treatment; this PR does not implement them.

## Repeated local verification on the combined implementation

All runs exited zero, using real native libraries and independent file namespaces.
These are fresh runs after integration, not reused pre-equipment results.

| Invocation | Checks / failures |
| --- | --- |
| Contextual loot New / independent Continue | 1313 / 0; 22 / 0 |
| Graphical contextual loot New / independent Continue | 1330 / 0; 23 / 0 |
| Existing offline journey New / independent Continue | 275 / 0; 137 / 0 |
| Existing full local raid cycle | 4268 / 0 |
| Full-cycle saved envelope, two independent processes | 3 / 0; 3 / 0 |

The final nine raw 1920x1080 captures include the actual equipped AKM/melee and
secure-container projection from the merged equipment implementation. The loot
sequence still searches, opens, filters, transfers all original stacks, closes,
reopens and retires the source, without moving the player's own inventory.
The committed fingerprints match verification.md. Seventeen runner tests,
23 repository-scope tests and the exact-output gate pass after integration.

The Linux runtime remains an outside copy with hash-verified GDExtensions,
explicit extension startup for the known engine import issue, and Xvfb/Mesa for
graphical capture. This is not a cold-import fix, package promotion, export,
performance measurement or human/controller signoff. Final pushed-head native
macOS CI is reported separately in the PR after its results are inspected.
