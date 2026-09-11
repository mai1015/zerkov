# Task 7.9 — ProfileStore implementation evidence

Status: **P1 concurrency repair complete; post-merge verification passed**

Task: `7.9` from `add-zerkov-playable-raid-2026-09-09`

Repair base: current `main` `f94222068ec398e4480e049563c496cedb13ff41`
merged as `2f5c9a3`

Repair commit: `78ce8ecd3a8479fffc8daef2c3e441b457d2abee`

Post-repair integration base: accepted `main`
`c08a39b9026c9f45fd666d61a5c5d96b211e178b`, merged as
`19af13a9b1ad10862d9ac5b21f732396d766972d`

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

A save is a generation compare-and-swap. It targets
`expected_generation + 1`, while revision must advance exactly once. An exact
candidate already present at that generation returns `replayed_exact_write`
with `committed=true` and `write_performed=false`; a divergent replay or stale
generation fails before file mutation.

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
| `committed_durable` | The injected adapter proved both file and directory durability. Production Godot I/O does not claim this. |
| `committed_durability_uncertain` | Candidate replaced primary and read-back verified, but power-loss durability is not proven or the operation reported failure after replacement. |
| `committed_recovery_required` | Replacement occurred, but candidate read-back could not be verified. The receipt never misreports this as an atomic rejection. |
| `replayed_exact_write` | Exact bytes were already committed; no write or rotation ran. |

Reads never create defaults and never repair files as a side effect. Primary
and backup are validated independently. The valid higher generation wins;
byte-identical equal generations prefer primary; divergent equal generations
fail closed. A valid backup is returned with `recovered_backup=true` when
primary is corrupt/missing or when backup is newer. Unsafe filesystem objects
or uncertain I/O fail the entire read rather than trusting the other copy.

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

The repair-validation ten-program Godot matrix on the `f942220` base executed
**20,056 checks with zero failures**:

| Contract | Checks | Failures |
| --- | ---: | ---: |
| ProfileStore promoted contract | 258 | 0 |
| Inventory persistence/replacement adjacency | 97 | 0 |
| Inventory authority adjacency | 79 | 0 |
| Offline session lifecycle adjacency | 44 | 0 |
| Authority replay adjacency | 81 | 0 |
| Inventory catalog adjacency | 543 | 0 |
| Inventory nested-magazine persistence adjacency | 258 | 0 |
| Inventory projection adjacency | 99 | 0 |
| Combined add-on load | 155 | 0 |
| Stable identity collision suite | 18,442 | 0 |

The promoted contract includes deterministic serialization; checksum and
fingerprint tamper; invalid UTF-8; duplicate, unknown, malformed, truncated,
and oversized encodings; type, integer, string, blob, node, collection, domain
count, total byte, and depth bounds; NaN/infinity rejection; missing profiles;
stale and divergent generation; exact replay; primary/backup precedence;
equal-generation conflict; corrupt primary/good backup; good primary/corrupt
backup; both corrupt; both missing; preservation of the sole good backup;
safe temp cleanup and blocked cleanup; a real symlink fixture; injected failure
before/after candidate write, backup replacement, and primary replacement;
post-commit verification corruption; directory-sync failure; a seam-proven
durable result; fresh-instance host reload and host backup recovery; eight-way
synchronized lease acquisition; synchronized same-store save admission; bounded
thread joins; close during blocked storage I/O; validation-error admission
cleanup; and lease reacquisition after both ordinary and raced teardown.

After the repair was preserved and accepted `main` `c08a39b` was merged, the
focused post-merge headless domain matrix executed **660 checks with zero
failures**:

| Post-merge contract | Checks | Failures |
| --- | ---: | ---: |
| ProfileStore promoted contract and concurrency probes | 258 | 0 |
| 4.11 inventory intent/lifecycle compatibility | 162 | 0 |
| Inventory projection lifecycle compatibility | 99 | 0 |
| Offline session lifecycle compatibility | 44 | 0 |
| Inventory persistence/replacement compatibility | 97 | 0 |

The 4.11 compatibility rerun deliberately targets the headless adapter,
projection, session, and persistence boundaries. It does not run
`inventory_loot_ui_4_11_contract.gd`, instantiate its UI scene, exercise a
viewport, or regenerate visual captures.

The post-merge concurrency contract was also repeated 25 times in one bounded
headless run (`6,450` assertions, zero failures and zero join timeouts) to check
for scheduling flakiness. These repetitions are supplementary and are not
double-counted in either matrix.

The clean post-merge editor import exited `0`. Every accepted log was scanned for
`SCRIPT ERROR`, `ERROR:`, warnings, extension-load failures, assertion failure
markers, ObjectDB/RID/resource leaks, and nonzero exits; there were no matches.
Strict change validation returned `Valid`. Toolchain and vendored-destination
checks passed. `git diff --check` passed.

Exact outputs are in `editor_import.log`, the per-program `logs/*.log` files,
`spec_strict.log`, `diff_check.log`, and `diagnostics_scan.log`.
`frozen_sources.sha256` seals the implementation, contract, and developer
documentation. `packet.sha256` seals the evidence packet excluding itself.

## Scope exclusions and remaining consumers

This task does not create a raid loadout (7.2), define death/secure-container
loss policy (7.8), apply settlement semantics (7.10), claim the full crash-point
suite (7.11), build a summary (7.12), bind UI, or modify an add-on. No task
checkbox or truth spec was edited. Later settlement code must provide the exact
project/domain payload, expected generation, and next revision; it must treat
`committed_durability_uncertain` and `committed_recovery_required` as committed
states rather than retrying blindly.
