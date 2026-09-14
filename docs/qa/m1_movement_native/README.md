# M1 movement: recorded isolated native validation

Base reviewed: `55362911aa089c3b87100697181a982eebd3c209`.
Scope: the pure movement component and its original contract, not the complete
Zerkov game. No task checkbox, engine pin, native add-on, UI, or launch scene is
changed by this commit.

## Evidence in this PR

- `REPORT.md`: the original validation report, with trailing whitespace removed;
  retained as historical evidence. Statements about no remote changes describe
  the original validation run, before this PR was submitted.
- `SOURCE_MANIFEST.json`: SHA-256 hashes for the unchanged candidate files and
  Git blob identities of the two exact repository dependencies.
- `logs/`: directly reviewable original logs, including the rejected .NET run.
- `SHA256SUMS`: hashes of the files added by this commit, excluding this manifest.
  Paths are relative to the repository root.

The previously delivered `zerkov_native_validation.zip` replay capsule remains a
separate conversation attachment. It is NOT checked into this text-only PR.
Its SHA-256 is
`6718e133ab99bc1ed4394f286a75bd278e3523f888f8d9b2b07466dbff207408`.
That capsule contains the isolated project, extended tests, generated vectors,
runner, and synthetic capture. No engine binaries, fonts, or native add-on
artifacts are included in this commit.

The recorded isolated runs tested a sealed source snapshot. They do NOT
validate arbitrary future checkout changes. Compare the candidate hashes in
`SOURCE_MANIFEST.json` with the current product files before using this evidence.
A new run was not performed during PR submission; source identity was checked.

## Run the original contract against the current checkout

After the pinned engine and all required native dependencies pass their gates:

```sh
export ZERKOV_GODOT=/absolute/path/to/the/pinned/Godot
python3 tools/check_toolchain.py
python3 tools/vendor_addons.py check --scope destination
"$ZERKOV_GODOT" --headless --path . --editor --import --quit
"$ZERKOV_GODOT" --headless --path . \
  --script res://tests/world/movement_step_contract.gd
```

Both `MOVEMENT_STEP_RESULT` with zero failures AND clean diagnostics are
required. A zero process exit on its own is insufficient. The .NET run with
missing-runtime errors is explicitly not an accepted result.

The synthetic exact-1920x1080 render result in the historical logs is engine
capability evidence only, not product visual acceptance or a gameplay capture.
No smaller-output support is reopened. Full-project import, source-policy
checks, movement/authority integration, Sawmill traversal, and human acceptance
were not validated by the archived isolation run. Tasks 3.5 and 3.6 stay open.
