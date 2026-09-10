The first independent harness invocation failed to parse two script aliases
declared as `const C := ZerkovEquipmentAbilityContent` and
`const I := ZerkovInventoryCatalog`. The engine exited zero, but the runner
correctly rejected the run because the raw log contained script errors and no
result marker. Its log and runner result remain in `history/flow_*`.

Only those QA aliases were changed to explicit production-script `preload`
expressions. The independent headless fixture then passed 451 checks and the
visible native fixture passed 463. No production or promoted-test repair was
made. Earlier authoring attempts are excluded from accepted totals. The script
copy placed in history when the failed run was archived reflects the corrected
QA source at archive time; the raw log identifies the earlier parse failure.
