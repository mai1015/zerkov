# Runner authoring history — excluded from accepted totals

Command: `python3 docs/qa/inventory_weapon_reload/astra_final/run_validation.py baseline`

Exit: 1. The first validator runner invoked `shasum -c` from the sealed packet
directory, but that manifest uses repository-relative paths. Every entry reported
`FAILED open or read`; this was an incorrect runner working directory, not a hash
mismatch. No Godot flow or suite had run. The runner stopped with
`AssertionError: The prior REJECT packet seal must verify` at the baseline guard.

Repair: invoke the same read-only seal verification from the repository root.
The raw initial verification output is retained as `initial_seal_wrong_cwd.log`.
