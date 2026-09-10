The first baseline runner stopped before engine execution because the locked
`level_task_system` sibling has no `.git` directory. The runner originally
assumed all six siblings were Git repositories. No production or test file was
edited, no add-on was mutated, and no Godot process was launched by this attempt.

The QA runner now records Git heads/status and source hashes where Git exists,
and a full file-hash snapshot (excluding generated cache directories) for the
non-Git sibling. This authoring attempt is excluded from accepted test totals.
