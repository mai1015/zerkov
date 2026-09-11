# Task 7.9 integration review request

Review correctness repair commit
`f20d8b9b33b1cb428f45d87dbeec917de7a36e01` after accepted `main`
`c265d3a4efd9b49f840b87e201ceb8f4b661d26b` was integrated by merge
`9c9201fa67f4f5b54d71bd897370531f5e9e1790`. The repair preserves the
previous mutex-backed lease and operation-admission correction.

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
