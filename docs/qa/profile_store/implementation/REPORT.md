# Task 7.9 — ProfileStore implementation evidence

Status: **future-envelope rollback repair complete; final verification passed**

Task: `7.9` from `add-zerkov-playable-raid-2026-09-09`

Rejected candidate reviewed: `d6d8603d1df2ede88a409a089b6c2f674660146b`

Correctness repair commit: `f20d8b9b33b1cb428f45d87dbeec917de7a36e01`

Future-envelope rejection reviewed: `1b4d8b5fc1f8285d3dab9abe8c83f29afece720d`

Future-envelope repair commit: `a63921cad04247a38221d833ad15798684b6fb9a`

Post-repair integration base: accepted `main`
`c265d3a4efd9b49f840b87e201ceb8f4b661d26b`, merged as
`9c9201fa67f4f5b54d71bd897370531f5e9e1790`

Final integration base: current `main`
`4accbd8a92e9ad66900b3398fe97ab5b8fa47bb6`, merged as
`99226f7a4c5df23f5488aa19e157e83100bab9fc`

Engine: Godot `4.7.2.stable.official.ed1daf0bf`

Host observed by the promoted contract: macOS, APFS

## Concurrency correctness repair

Independent review of commit `d52c3f69b2b4df291a40e61d3ed656933aafd2b3`
found that the process-wide writer-lease dictionary and the per-store operation
flag used check-then-set sequences without synchronization. Real Godot Threads
could therefore acquire two leases for one storage identity or enter two saves
on one store.

The repaired implementation uses one static `Mutex` for lease-map ownership and
one instance `Mutex` for lifecycle/operation state. Lease acquisition/release,
configuration admission, close, and the final check/set that admits load/save
are now linearized. Lock order is always lease mutex then instance mutex when
both are needed. Adapter configure/prepare/key/capability callbacks, canonical
encoding and hashing, and every storage operation run outside both locks.

`close()` is now an idempotent boolean operation. It refuses teardown with
`profile_store_configuration_active` or `profile_store_operation_active`
instead of releasing a lease while work is in flight. Failure exits clear their
admission state under the instance mutex; a contender can acquire the lease
after the active operation finishes and close is retried.

## Independent-review correctness repair

Review of `d6d8603` found four remaining contract gaps. The repair reserves
`committed_durable` for the exact conjunction of a successful and committed
primary replacement, candidate-file durability, and supported successful
directory synchronization. If replacement reports `committed=true` together
with an operation error, the verified primary is retained but the receipt is
`committed_durability_uncertain` with that error preserved. All 32 combinations
of the five boolean result dimensions are asserted.

Version 1 now has one explicit lineage: the first write is generation/revision
`1/1`, and both counters increment together. Unequal counters are rejected
before primary/backup selection, payload hashing, or fingerprint comparison;
tests recompute a valid fingerprint around forged newer mismatched copies and
prove that each remains ineligible to beat the other valid copy.

All public receipts and capability snapshots are recursively read-only,
including unconfigured calls, pre-selection validation failures, and the loser
of a concurrent same-store save. Finally, the replay documentation now states
the implemented guarantee precisely: an exact replay independently reads and
validates both copies, but performs no writes, rotation, or other mutation.

## Future-envelope rollback repair

Independent review of `1b4d8b5` demonstrated that an old build classified a
canonical future-version primary as ordinary invalid data, loaded the older v1
backup, and then overwrote the future primary with v1 bytes. The repaired
reader separates structurally recognizable unsupported format headers from
malformed or corrupt supported-version data. Recognition requires a canonical
dictionary with the required typed schema/version/codec/digest/profile header
and this store's exact profile identity; future extra fields remain visible to
the header probe before the v1 exact-field check.

An unsupported envelope schema, version, payload schema, codec, or digest
algorithm in either primary or backup now blocks selection. Load returns
`load_blocked_unsupported_format`; ordinary save and exact replay return
`write_blocked_unsupported_format`. Each frozen receipt reports
`profile_format_unsupported`, `unsupported_format=true`, and
`migration_required=true` with a bounded format diagnostic. The store reads
both copies but performs no temp cleanup, write, rotation, replace, or directory
sync, preserving all four slots byte-for-byte. Migration must be implemented by
a future version-aware service or newer game build outside task 7.9.

The promoted matrix covers schema/version/codec across both slot permutations,
mixed with an older valid v1 copy, and invokes load, next-generation save, and
exact replay for every case. A same-instance fixture then externally replaces
the future bytes with malformed v1 bytes and proves ordinary backup recovery
and a subsequent supported v1 save still work; the guard adds no hidden latch
and does not disable corruption recovery for the supported format.

## Delivered boundary

`game/profile/` adds a game-owned persistence boundary that is independent of
the Inventory System's authority internals. `ProfileStore` accepts one exact
payload shape containing project-owned data and bounded opaque domain records:

```text
{
  project: Dictionary,
  domains: Dictionary[String, PackedByteArray]
}
```

The on-disk envelope has exact fields for schema, format version, payload
schema/codec, profile identity, generation, revision, checksum/fingerprint
algorithms, payload checksum, envelope fingerprint, and payload. Payload bytes
use a deterministic custom codec rather than JSON or Godot Variant encoding.
The codec accepts only nil, booleans, bounded integers, valid UTF-8 strings,
bounded byte arrays, arrays, and string-keyed dictionaries. Dictionary keys are
sorted, and decoding rejects noncanonical order, duplicates, trailing bytes,
unsupported types, numeric coercion, invalid UTF-8, and every configured
depth/node/count/string/blob/file bound.

The payload checksum is SHA-256 over
`zerkov.profile.payload-checksum.v1 + NUL + canonical_payload`. The envelope
fingerprint is SHA-256 over
`zerkov.profile.envelope-fingerprint.v1 + NUL + canonical_envelope_core`.
Those values detect corruption or tampering that is not recomputed; they are
not authentication, signing, or encryption.

## Write and recovery contract

A save is a generation compare-and-swap. Version 1 starts at generation and
revision `1/1`; each save targets `expected_generation + 1`, and revision must
equal that candidate generation. An exact candidate already present at that
generation returns `replayed_exact_write` with `committed=true` and
`write_performed=false`; it still reads and independently validates primary and
backup. A divergent replay, stale generation, or impossible lineage fails
before file mutation. If either copy has a recognizable unsupported format,
load/save/replay instead return the explicit migration-required status and
preserve primary, backup, and both temp slots exactly.

The save order is:

1. read and independently validate primary and backup;
2. write, flush, read back, decode, and byte-check the candidate in the same
   directory as primary;
3. if primary is the selected valid generation, write, flush, validate, and
   atomically replace backup with those exact primary bytes;
4. atomically replace primary from the validated candidate temp;
5. read back and validate the committed primary;
6. attempt directory durability through the adapter and report its result.

When the selected state came from backup because primary was corrupt, missing,
or older, the existing good backup is preserved. Corrupt primary bytes are
never rotated over it. Safe stale temp files are removed before and after a
save; a symlink/reparse temp or a cleanup error blocks before commit.

Write status is explicit:

| Status | Meaning |
| --- | --- |
| `pre_commit_failed` | Candidate did not replace primary. Backup rotation may have completed, but a validated old primary/backup remains. |
| `committed_durable` | Primary replacement reported both success and commitment, and the injected adapter proved file and directory durability. Production Godot I/O does not claim this. |
| `committed_durability_uncertain` | Candidate replaced primary and read-back verified, but power-loss durability is not proven or the operation reported failure after replacement. |
| `committed_recovery_required` | Replacement occurred, but candidate read-back could not be verified. The receipt never misreports this as an atomic rejection. |
| `replayed_exact_write` | Exact bytes were already committed; no write or rotation ran. |
| `write_blocked_unsupported_format` | A recognized unsupported copy requires an explicit future migration; no storage mutation ran. |

Reads never create defaults and never repair files as a side effect. Primary
and backup are validated independently. The valid higher generation wins;
byte-identical equal generations prefer primary; divergent equal generations
fail closed. A valid backup is returned with `recovered_backup=true` when
primary is corrupt/missing or when backup is newer. Unsafe filesystem objects
or uncertain I/O fail the entire read rather than trusting the other copy. A
recognized unsupported copy is never treated as corruption: it blocks the
entire operation even when the other copy is a valid older v1 envelope.

## Filesystem guarantee on this host

The production adapter maps a validated `zerkov.profile.*` identity through a
domain-separated SHA-256 digest below the fixed
`user://zerkov/profile_store/profiles/` root. Production callers cannot provide
a root, directory, filename, or path. Every temporary and destination file is
in that one directory. Existing directory components and all four exact slots
are checked for symbolic links, junctions/reparse points, and directory/file
type confusion before use.

On the tested APFS host, the implementation uses `FileAccess.flush()` followed
by same-directory `DirAccess.rename_absolute()` as the namespace replacement
point, and verifies the resulting bytes. Godot documents that rename overwrites
an existing destination and that flush writes the file buffer. Godot 4.7 does
not expose a directory-handle fsync operation or a separately auditable fsync
result from `FileAccess.flush()`. Therefore production receipts deliberately
report `committed_durability_uncertain`, not durable. The tests do not simulate
a real power cut and do not prove APFS crash durability.

The supported mode is one offline process. Mutex-backed in-process admission
rejects a second writer for the same storage identity and a second operation on
the same store; there is no interprocess lock. No ProfileStore mutex is held
across a file-operation callback or storage I/O. Symlink checks reject stable
path attacks, but a hostile local process racing filesystem entries between
check and open is outside this boundary's threat model.

Godot API references used for the guarantee boundary:
[FileAccess](https://docs.godotengine.org/en/4.7/classes/class_fileaccess.html),
[DirAccess](https://docs.godotengine.org/en/4.7/classes/class_diraccess.html).

## Automated results

The final post-merge headless domain matrix executed **21,347 checks with zero
failures**:

| Contract | Checks | Failures |
| --- | ---: | ---: |
| ProfileStore promoted contract | 527 | 0 |
| Inventory persistence/replacement adjacency | 97 | 0 |
| Inventory authority adjacency | 79 | 0 |
| Offline session lifecycle adjacency | 44 | 0 |
| Authority replay adjacency | 81 | 0 |
| Inventory catalog adjacency | 543 | 0 |
| Inventory nested-magazine persistence adjacency | 258 | 0 |
| Inventory projection adjacency | 99 | 0 |
| Combined add-on load | 155 | 0 |
| Stable identity collision suite | 18,442 | 0 |
| 4.11 inventory intent/lifecycle compatibility | 162 | 0 |
| Body hitbox contract | 111 | 0 |
| Body hitbox adversarial contract | 173 | 0 |
| Body hitbox review regression | 72 | 0 |
| Combat content contract | 80 | 0 |
| Health/ability content contract | 392 | 0 |
| Units/clock contract | 32 | 0 |

The promoted contract includes deterministic serialization; checksum and
fingerprint tamper; invalid UTF-8; duplicate, unknown, malformed, truncated,
and oversized encodings; type, integer, string, blob, node, collection, domain
count, total byte, and depth bounds; NaN/infinity rejection; missing profiles;
stale and divergent generation; exact replay; primary/backup precedence;
equal-generation conflict; corrupt primary/good backup; good primary/corrupt
backup; both corrupt; both missing; preservation of the sole good backup;
safe temp cleanup and blocked cleanup; a real symlink fixture; injected failure
before/after candidate write, backup replacement, and primary replacement;
post-commit verification corruption; the complete 32-case durability result
cross-product; a seam-proven durable result; re-fingerprinted unequal-counter
lineage attacks; recursively immutable public success, failure, capability, and
admission results; recognized future schema/version/codec barriers in both
slots; blocked load/save/replay; byte-identical four-slot preservation; normal
supported-version recovery after external migration; fresh-instance host reload
and host backup recovery;
eight-way synchronized lease acquisition; synchronized same-store save
admission; bounded thread joins; close during blocked storage I/O;
validation-error admission cleanup; and lease reacquisition after both ordinary
and raced teardown.

The ProfileStore contract was also repeated 25 times in one bounded headless
run (`13,175` assertions, zero failures, zero join timeouts, and zero deadlocks)
to check scheduling behavior. These repetitions are supplementary and are not
double-counted in the matrix.

All tests in the final matrix are headless domain contracts. No UI scene or
viewport/visual-capture contract was run.

The clean final post-merge editor import exited `0`. Every accepted log was
scanned for `SCRIPT ERROR`, `ERROR:`, warnings, extension-load failures,
assertion failure markers, ObjectDB/RID/resource leaks, and nonzero exits; there
were no matches.
Strict change validation returned `Valid`. Toolchain and vendored-destination
checks passed. `git diff --check` passed.

Exact outputs are in `editor_import.log`, the per-program `logs/*.log` files,
`spec_strict.log`, `diff_check.log`, and `diagnostics_scan.log`.
`frozen_sources.sha256` seals the implementation, contract, and developer
documentation. `packet.sha256` seals the evidence packet excluding itself.

## Scope exclusions and remaining consumers

This task does not create a raid loadout (7.2), define death/secure-container
loss policy (7.8), apply settlement semantics (7.10), claim the full crash-point
suite (7.11), build a summary (7.12), bind UI, or modify an add-on. Neither the
7.9 checkbox nor a truth spec was edited. Later settlement code must provide the
exact project/domain payload, expected generation, and next revision; it must
treat `committed_durability_uncertain` and `committed_recovery_required` as
committed states rather than retrying blindly. The required current-main merge
contributes only the reopened 5.3 ledger note and its report; this 7.9 repair
preserves that note unchanged and leaves 7.9 unchecked.
