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
`expected_generation + 1`, and revision must advance exactly once. Repeating
the exact request is an I/O-free replay; a divergent request for the same or a
stale generation is rejected.

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
Unsafe filesystem objects and I/O uncertainty fail closed.

Write results distinguish:

- `pre_commit_failed`: the candidate did not replace primary;
- `committed_durable`: the injected adapter proved both file and directory
  durability;
- `committed_durability_uncertain`: primary was replaced and verified, but the
  adapter cannot prove power-loss durability;
- `committed_recovery_required`: replacement occurred but read-back could not
  prove the committed candidate;
- `replayed_exact_write`: the exact candidate was already committed.

On the production Godot adapter, `FileAccess.flush()` is called and the commit
uses `DirAccess.rename_absolute()` in one directory. Godot 4.7 exposes no
directory-fsync operation and `flush()` does not expose a separately auditable
fsync result, so production success is intentionally reported as committed but
durability-uncertain. On the validated macOS/APFS host this establishes a
single namespace-replacement point, but it is not proof against sudden power
loss. There is also no interprocess lock: the supported mode is one offline
process, with an in-process single-writer lease. Symlink/reparse checks close
ordinary traversal paths, but concurrent hostile local filesystem mutation
between check and open is outside this boundary's threat model.

Checksums and fingerprints detect accidental or non-recomputed tampering; they
are not signatures or encryption and do not defend against an attacker who can
rewrite the file and recompute SHA-256.
