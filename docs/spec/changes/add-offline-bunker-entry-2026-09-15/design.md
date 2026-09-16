# Design

OfflineApplication owns startup, OfflineBunkerSession, the presentation bridge
and the original ui/main.tscn instance. Direct F6 of the UI shell remains the
existing isolated preview; production F5 enters through the application root.
Screens receive a narrow session-generation capability, immutable values and
commands, never native inventory or save-file objects.

OfflineBunkerSession stages each inventory command on a restored native record,
uses native move/rotate/split/merge/equip semantics, saves the complete candidate
through ProfileStore CAS, then replaces its private live snapshot. No candidate
or native notification reaches the UI before verified commit. Precommit failure
retains the prior state; ambiguous postcommit state blocks edits until reload.
Generation and revision checks reject stale gestures. A busy guard covers command
callbacks and publication. There is no background autosave or unsaved quit path.

OfflineInventoryController is a presentation specialization of the existing
controller API. It shares catalog presentation metadata and authored widgets,
not the raid admission/tick mechanism. Legacy scope names describe UI columns,
not running raids. Health/progression remain explicitly unavailable.

The profile schema and starter-kit version are explicit. Local profile ID is
fixed; no screen supplies a filesystem path. A trusted debug test seam permits
isolated ProfileFileOperations. Normal runtime always uses production operations.
The inherited ProfileStore is in-process single-writer and does not claim
cross-process locking or directory-fsync/power-loss durability.
