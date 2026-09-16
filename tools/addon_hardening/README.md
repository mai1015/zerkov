# Task 10.1 — native hardening candidate

This is a **reviewable local-fork candidate**, not an upstream hardening signoff
or a silently re-vendored package. The canonical sibling repositories were not
available to this connection. Exact audited sources are reproduced outside the
checkout; the six approved source transformations are byte-checked before and
after. No production addon directory, addon lock or release manifest is edited.

## Reconciliation

- W1: actual core compatibility comparison, a server-originated offer and a
  connection-bound handshake. The client must load its own sealed catalog.
- W2: fresh random connection token scopes command identity. The host receives a
  server-created canonical ID, not a bare client `c1`. Client-selected entropy is
  excluded from the execution envelope. Client and native command sequences are
  deliberately distinct; only the game executor assigns native sequences.
- W3: snapshots, deltas, resync, acknowledgement and result feeds all check live
  session/compatibility/grant. Only actually sent revisions can be acknowledged.
  Bounds precede packet copying; unauthorised errors expose no instance revision.
- W4: initial snapshot ack includes revision zero; later state uses deltas. Fresh
  connection tokens invalidate old packets. Replacement/disconnect clears
  confirmed and predicted state and requires fresh explicit grants. Revocation
  removes the local replica without inventing a gameplay tombstone.
- W5: RPC handlers never call native mutation. A required game callback admits
  values into its own tick queue and defaults to denial, including attachment
  and reload inventory claims. Before execution, the game must call
  `command_still_current`; after its real outcome, `complete_command`. Queue
  admission never confirms predicted success and snapshots from other actors
  cannot confirm a client's intent by an unrelated sequence watermark.
- G1/G2: target authorization defaults required; unset/empty relevance defaults
  nobody. Explicit nonempty host allowlists remain supported.

## Deliberately changed optional-bridge contract

`WNB1` is a new bridge envelope over the unchanged core Weapon protocol DTOs.
It is not wire-compatible with the previously shipped bridge. An old client
must fail negotiation, not be treated as compatible. This is a candidate for
review, not a version-bump/release-authority substitute. The old context/profile
provider setter names remain for migration but no longer enable direct RPC
mutations. Install a command-admission handler instead. Returning a malformed
admission result invalidates that connection rather than promising safe retry.

The token is connection correlation, not account authentication. The host still
owns peer authentication, actor ownership, canonical tick, inventory and world
validation, server entropy, multi-domain transactions and save policy. This does
not implement Steam transport, matchmaking, public PvP or a hosted backend.

## Build and evidence

CI stages the candidate, checks the godot-cpp SDK against the project's exact
lock, builds both addons, loads the resulting libraries in isolated projects,
and runs a real-ENet three-peer contract. Native gameplay libraries are not
replaced by GDScript doubles. Artifacts include changed-source digests, build
metadata, native result logs, and candidate libraries. Read-only CI has no
patch-application/auto-push workflow or credential persistence.

`tools/addon_hardening/tests/bridge_contract.gd.in` is a candidate-only test
source template. It is deliberately not an importable production GDScript:
unchanged installed binaries do not yet expose the candidate API. The verifier
materializes it only in the isolated exact-1080 candidate test project.

Run `python3 tools/addon_hardening/test_staging.py` for the source guard tests.
The SCons/verify invocations in `.github/workflows/addon-hardening.yml` are the
reproduction recipe. A successful candidate build/load is not a full-platform
export or task-10 public release signoff. Promotion requires owner review,
release version/provenance, a normal locked-package import and full game-side
regressions with promoted artifacts. Until then, shipped networking stays off.


## Validation scope and known loader prerequisite

The revised candidate additionally rejects mismatched DTO protocol versions and
unsigned counters that cannot be represented by the game-facing int64 port.
Revoking or replacing a grant changes any cancelled pending command's cached
status to terminal denial; regranting must not turn queue admission into a
fabricated execution-success replay.

Verification loads each newly built configuration through an explicit
`.godot/extension_list.cfg` containing only the two known descriptor paths. No
script/import cache is copied, no failing process is retried, and nonzero exits
or script errors still fail the job. Both native test runs use actual ENet
connections and actual WeaponAuthority state. Gameplay Abilities coverage here
is native default/accessor verification; this does **not** reproduce the full
GAS target-authorization/relevance RPC suite.

**Unresolved discovery issue:** on the tested Linux engine, a pristine editor
that automatically discovers these libraries aborts at the end of its first
import. The same abort was reproduced with the *unchanged* Weapon addon rebuilt
against the same SDK/profile. Explicit startup registration avoids this path.
That isolates the symptom from the candidate bridge changes but is not a root
cause diagnosis or a fix for cold editor discovery. This prerequisite remains
open for package promotion. A green candidate job must not be described as
cold-discovery, export, deployment, or full platform qualification.

Windows candidate builds use GNU MinGW: existing core arithmetic uses
`__int128`, which stock MSVC rejected. This is not an MSVC compatibility claim.
Compiler versions, source and binary hashes, engine pin and loading mode are
included in the artifacts. Test-source changes trigger new native runs.

Run `test_verification.py` for fail-closed verifier negative controls. New spec
notes under `docs/spec/changes/harden-network-addon-candidates/` distinguish this
local fork experiment from approved package replacement. No upstream release
or version-number change is fabricated, and installed addon directories stay
byte-for-byte pinned until a separately reviewed promotion passes its gates.
