# Profile persistence boundary

`ProfileStore` is the game-owned, local persistence boundary for an offline
profile. It stores project data plus named opaque domain records without making
an inventory add-on (or any later settlement service) the owner of the profile.

The payload shape is exact:

```gdscript
{
    "project": Dictionary,
    "domains": Dictionary[String, PackedByteArray],
}
```

Call `configure("zerkov.profile.local")`, then `load_profile()` or
`save_profile(payload, expected_generation, revision)`. A save always targets
`expected_generation + 1`; version 1 starts at generation/revision `1/1` and
keeps those counters equal as they advance exactly once. Repeating the exact
request is write-free and mutation-free, but still reads and validates primary
and backup before selecting the committed copy. A divergent request for the
same or a stale generation is rejected. Call `close()` after the final
operation; it is idempotent, returns `true` after releasing the lease, and
returns `false` with
`profile_store_operation_active` or `profile_store_configuration_active` when
teardown races work that still owns the store.

A canonical dictionary with the required typed format header and matching
profile identity is structurally recognizable even when its declared envelope
schema, version, payload schema, codec, or digest algorithm is unsupported. If
either primary or backup contains such a format, `ProfileStore` returns
`load_blocked_unsupported_format` or `write_blocked_unsupported_format` with
`profile_format_unsupported`, `unsupported_format=true`, and
`migration_required=true`. It still reads both copies for bounded diagnostics,
but load, ordinary save, and exact replay perform no write, rotation, cleanup,
or sync and preserve every slot byte-for-byte. A future version-aware migration
tool or newer game build must transform or explicitly retire those bytes;
automatic migration is outside task 7.9.

Production callers cannot provide a path. The default adapter maps a validated
profile identity to a domain-separated SHA-256 filename below the fixed
`user://zerkov/profile_store/profiles/` root. The separately named
`configure_with_trusted_operations()` API exists for deterministic tests and
trusted debug composition only (release builds reject it); the store still
sends it fixed slot identifiers, not paths.

## Commit and recovery model

The primary profile, one backup generation, and both temporary files live in
one directory. A candidate is written, flushed, read back, fully decoded and
validated before any replacement. When the current primary is valid, its exact
bytes are likewise staged and validated before atomically replacing the backup.
Only then does one same-directory rename replace the primary. If recovery chose
the backup because the primary was corrupt or missing, that good backup is
preserved rather than overwritten from the bad primary.

Reads validate primary and backup independently. The valid higher generation
wins; byte-identical ties prefer primary, while divergent equal generations
fail closed. A valid backup is returned with `recovered_backup` when primary is
missing/corrupt; reads never invent defaults or automatically rewrite storage.
Version-1 copies with unequal generation/revision counters are invalid before
selection, even if their checksum and fingerprint were recomputed. Unsafe
filesystem objects and I/O uncertainty fail closed.

Malformed or corrupt copies that declare the supported version-1 format remain
eligible for ordinary backup recovery. The unsupported-format barrier is
reserved for a structurally recognizable header belonging to this profile; it
does not turn checksum/fingerprint failure, truncation, malformed current-format
fields, or foreign-profile bytes into a migration request.

Write results distinguish:

- `pre_commit_failed`: the candidate did not replace primary;
- `committed_durable`: the injected adapter reported a successful committed
  primary replacement and proved both file and directory durability;
- `committed_durability_uncertain`: primary was replaced and verified, but the
  adapter cannot prove power-loss durability;
- `committed_recovery_required`: replacement occurred but read-back could not
  prove the committed candidate;
- `replayed_exact_write`: the exact candidate was already committed.
- `write_blocked_unsupported_format`: a recognized unsupported copy requires
  explicit migration; no storage mutation ran.

All public load/save receipts and capability dictionaries are recursively
read-only snapshots, including admission failures returned by racing calls.

On the production Godot adapter, `FileAccess.flush()` is called and the commit
uses `DirAccess.rename_absolute()` in one directory. Godot 4.7 exposes no
directory-fsync operation and `flush()` does not expose a separately auditable
fsync result, so production success is intentionally reported as committed but
durability-uncertain. On the validated macOS/APFS host this establishes a
single namespace-replacement point, but it is not proof against sudden power
loss.

There is no interprocess lock: the supported mode remains one offline process.
Within that process, a static `Mutex` linearizes lease acquisition/release for
each storage identity and an instance `Mutex` admits at most one load/save at a
time. Configure, close, and operation admission update their in-memory state in
short critical sections. No adapter callback, hashing pass, or storage I/O runs
with either mutex held. A close racing an active operation is rejected without
releasing the lease, so another store cannot enter until the operation finishes
and close is retried successfully. Symlink/reparse checks close ordinary
traversal paths, but concurrent hostile local filesystem mutation between check
and open is outside this boundary's threat model.

Checksums and fingerprints detect accidental or non-recomputed tampering; they
are not signatures or encryption and do not defend against an attacker who can
rewrite the file and recompute SHA-256.
