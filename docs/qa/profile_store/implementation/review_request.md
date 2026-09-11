# Task 7.9 integration review request

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
8. generation/revision CAS and equal-generation divergence fail closed;
9. injected failures cover both sides of write/backup/primary replacement
   without replacing production globals;
10. host claims stop at same-directory APFS rename plus Godot flush/read-back,
    and do not imply directory fsync, real power-cut proof, authentication,
    encryption, or interprocess locking;
11. no settlement, loss-policy, loadout, summary, UI, add-on, task-ledger, or
    truth-spec scope entered the change.
12. the static lease mutex makes same-identity configure acquisition/release a
    single linearization point across Godot Threads;
13. the instance mutex admits at most one load/save and prevents close from
    releasing the lease while configuration or an operation is active;
14. no mutex remains held while calling the file-operation seam, hashing,
    serializing, reading, flushing, replacing, verifying, or syncing;
15. bounded synchronized thread probes prove one eight-way configure winner,
    one same-store save winner, explicit loser receipts, no deadlock, and lease
    reacquisition only after successful teardown.
