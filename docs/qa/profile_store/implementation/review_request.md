# Task 7.9 integration review request

Review future-envelope repair commit
`a63921cad04247a38221d833ad15798684b6fb9a` after current `main`
`4accbd8a92e9ad66900b3398fe97ab5b8fa47bb6` was integrated by merge
`99226f7a4c5df23f5488aa19e157e83100bab9fc`. The repair preserves the
previous durability, lineage, recursive-immutability, mutex-backed lease, and
operation-admission corrections.

Review the exact files sealed by `frozen_sources.sha256` against task 7.9 and
the raid-progression/runtime-foundation deltas. Confirm that:

1. canonical payload and envelope bytes have no coercion, duplicate-key, or
   unknown-field ambiguity and enforce the documented bounds;
2. checksum and fingerprint cover distinct domain-separated inputs;
3. profile identity maps only to a fixed digest-owned production path;
4. reads validate both copies independently, never invent defaults, and apply
   the documented deterministic precedence;
5. backup rotation never replaces the sole good backup with corrupt primary;
6. candidate and backup staging are flushed and verified before primary commit;
7. receipts distinguish pre-commit failure, verified-but-durability-uncertain
   commit, unverified committed state, exact replay, and backup recovery;
8. `committed_durable` requires replacement `ok=true` and `committed=true`,
   file durability, and supported successful directory synchronization; every
   other committed result tuple stays durability-uncertain;
9. all 32 file-durable/replace-ok/replace-committed/sync-supported/sync-ok
   tuples assert status, commitment, verification, durability, mutation, sync,
   error reporting, and recursive immutability;
10. version-1 generation/revision starts at `1/1`, remains equal, and rejects
    recomputed-fingerprint mismatches before copy selection;
11. every public receipt/capability snapshot is recursively read-only,
    including early failures and the concurrent-save loser;
12. exact replay reads and validates both copies but performs no write,
    rotation, or other mutation;
13. generation/revision CAS and equal-generation divergence fail closed;
14. injected failures cover both sides of write/backup/primary replacement
   without replacing production globals;
15. host claims stop at same-directory APFS rename plus Godot flush/read-back,
    and do not imply directory fsync, real power-cut proof, authentication,
    encryption, or interprocess locking;
16. no settlement, loss-policy, loadout, summary, UI, add-on, task-ledger, or
    truth-spec scope entered the change.
17. the static lease mutex makes same-identity configure acquisition/release a
    single linearization point across Godot Threads;
18. the instance mutex admits at most one load/save and prevents close from
    releasing the lease while configuration or an operation is active;
19. no mutex remains held while calling the file-operation seam, hashing,
    serializing, reading, flushing, replacing, verifying, or syncing;
20. bounded synchronized thread probes prove one eight-way configure winner,
    one same-store save winner, explicit loser receipts, no deadlock, and lease
    reacquisition only after successful teardown.
21. a canonical matching-profile envelope with an unsupported schema, version,
    payload schema, codec, or digest algorithm is classified separately from
    malformed/corrupt supported-version data before copy selection;
22. an unsupported copy in either primary or backup blocks load, ordinary save,
    and exact replay even when the other copy is a valid older v1 generation;
23. blocked receipts use the explicit immutable load/write unsupported statuses,
    report migration required, and expose only a bounded format diagnostic;
24. blocked load/save/replay read both copies but perform no temp cleanup, write,
    rotation, replace, or sync, preserving primary, backup, and both temp slots
    byte-for-byte;
25. after an external future migration supplies supported-format bytes, normal
    malformed-v1 backup recovery and subsequent saving resume without a hidden
    latch; ProfileStore itself performs no migration in task 7.9;
26. the required current-main merge's reopened 5.3 ledger note remains unchanged
    and task 7.9 remains unchecked.
