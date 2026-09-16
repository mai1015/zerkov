# Task 10.1 — networking and platform readiness audit

Audit date: 2026-09-15. **Decision: do not enable live multiplayer yet.**
The merged offline domain baseline is green; addon hardening completion and
Windows/Linux release prerequisites are not established. No task checkbox is
promoted. This audit changes no production code, addon, lock, or permissions.

## Revision, method and limits

Base: `bfae2bd69c6ec3f5efd369bd7858fa629f7b9e05` (merged combat, progression,
AI and art plus task-ledger update). Evidence-producing audit commit:
`7da7168e0df48859b628476dc9481a03fb4b2d96`. The only differences from that base
are the inventory tool, its tests and a read-only CI workflow. Subsequent report
and inventory refinements do not change the game or vendored source.

The source packet contains 1,855 tracked source/configuration files, including
native C++ and headers. Every packet SHA-256 was verified after download. The
artifact inventories ran against the **full actual checkout**, not this
source-only packet: missing libraries in a deliberately binary-free source
archive would prove nothing about packaging.

Findings below are **source-reviewed behavior**, not exploit reproductions
against shipped binaries. Offline native tests exercise actual macOS addons,
not the multiplayer RPC path. Dirty source worktrees at pin time and recorded
release/tree revisions are not a source-to-binary build attestation. No fresh
native build, Windows/Linux engine load/export, server-plus-two-client run,
packet impairment test, graphical traversal, or human acceptance is claimed.

The sibling Gameplay Abilities 5.x / Weapon 6.x hardening change and its terminal
results were not identified through the accessible repository connection.
Searches for the addon workspaces returned no match. This is missing evidence,
not a statement that those repositories or a newer fix do not exist. Task 10.1
requires exact sibling change/revision, tests and rebuilt package provenance;
Zerkov's own section 5 checkboxes do not satisfy that requirement.

## Source findings and repair ownership

Line locators refer to the audited base above. `W` below is
`addons/weapon_system/native/godot/weapon_network_bridge.cpp`; `G` is
`addons/gameplay_abilities/native/godot/gameplay_ability_network_bridge.cpp`.

### W1 — compatibility readiness without manifest comparison

`W:484–501`, `_rpc_compatibility_handshake()`, discards `p_bytes` and marks
compatibility ready for an existing ownership-table session. It does not decode
or compare API/protocol/schema/features/catalog/world versions. This is not a
claim that the handler creates an unauthenticated session; it bypasses the
compatibility prerequisite within an existing one.

**Repair:** sibling bridge must use its real compatibility evaluator; product
session admission must remain deny-by-default until authentication and exact
content negotiation both succeed. **Required test:** incompatible, malformed,
pre-session, duplicate and reconnect handshakes cannot open command or egress
permissions; a valid retry after session creation can converge.

### W2 — client command identity and sampling entropy cross the trust boundary

`W:845–879` creates IDs from a per-bridge `c1`, `c2`, ... counter and accepts the
client's `spread_seed`. `W:503–576` forwards both into the native fire command.
The core lookup in `native/core/wpn_runtime.cpp:356–377,419–435` keys idempotency
by command ID **independently of instance/scope**. Two clients or replacement
bridge lifetimes can collide; deterministic sampling is not server-owned merely
because the server computes the resulting shot.

**Repair:** game-owned session/actor/epoch command identity and trusted server
entropy must be applied before the authoritative operation, with a specified
retained/replacement-session counter policy. **Required test:** two peers and a
replacement connection issue their first commands without cross-replay; changing
client entropy cannot select authoritative dispersion. Do not reset counters
while retaining an incompatible authority replay history.

### W3 — resync and acknowledgement bypass ordinary admission

`W:794–815`, `_rpc_resync_request()`, applies a resync rate bound then sends the
requested instance snapshot. `send_snapshot_to_peer()` at `W:386–407` does not
add a session/ownership/relevance/compatibility check. Together these paths can
expose a requested existing instance without the normal recipient grant check.
A rate limit is not authorization.

`W:776–792` records acknowledgement revisions without the same admission checks.
`native/protocol/wpn_replica.cpp:267–281` advances the peer/instance watermark;
it does not verify that this recipient was sent or authorized for that revision.

**Repair:** use one reviewed admission/relevance policy for all auxiliary RPCs,
not just fire/reload. Bound acknowledgement revisions by actual sent baselines.
**Required test:** unknown, revoked, observer-only, incompatible and reconnected
peers cannot request hidden snapshots or forge future acknowledgements. Observe
all wire outputs, not just rendered visibility.

### W4 — initial snapshot/delta and reconnect convergence are incomplete

`W:1033–1068` applies initial snapshots and emits signals without acknowledging
that baseline. The server's ordinary broadcast uses full snapshots while the
acknowledged revision is zero. The client auto-handshake is lifetime/ordering
sensitive; `on_server_disconnected()` at `W:225–239` does not reinitialize the
handshake, replicas and pending predictions. Server cleanup does not by itself
replace the native authority's history.

**Repair:** explicit initial acknowledgement, retained versus replacement
session semantics, coordinated counters, prediction expiration and replica
teardown. **Required test:** first relevance reaches real deltas; loss, reordering,
resync and reconnect heal without stale state resurrection or duplicate effects.
A documented protocol codec is not proof that the live bridge uses it correctly.

### W5 — inventory permission and game phase composition remain necessary

`W:710–775` validates attachment commands through the normal weapon gate but has
no inventory-possession callback before applying catalog-valid loadouts. Also,
`W:503–576` invokes `fire_native()` directly from its RPC handler. Attaching that
bridge as an alternate path would bypass Zerkov's tested `RaidAuthority` phase
ordering and cross-domain inventory/health transactions.

**Repair:** a game-owned ingress must stamp trusted identity/timing and enqueue
internal commands; attachment possession and reload reservations must come from
canonical inventory. This is product integration work as well as sibling bridge
hardening. **Required test:** valid-but-unowned attachments reject, and remote
fire/reload cannot mutate native domains outside their named raid phases.

### G1/G2 — Gameplay Abilities has existing safeguards but permissive defaults

Do **not** transfer W1/W3 accusations to Gameplay Abilities. `G:945–990` decodes
and evaluates compatibility. `G:3563–3605` gates full-state publication on
successful handshakes and splits owner/public audiences. `G:3644–3725` requires
handshake and current relevance before serving resync; peer cleanup also exists.

Two integration obligations remain. `require_target_authorization=false` in
`gameplay_ability_network_bridge.h:940`; the missing callback only rejects when
that flag is true (`G:2247–2264`). `current_relevant_peers()` at `G:1077–1088`
defaults to all connected peers when no override is supplied. An explicit
`set_no_relevant_peers()` exists; an empty override is not equivalent to denying
all recipients. Structural target/ability/session checks still exist; these
findings do not assert arbitrary remote damage has been reproduced.

**Repair:** before exposure, require target authorization and initialize egress
to nobody, then grant only recipient-specific views derived from authorized
Vision knowledge. **Required test:** absent callbacks, hidden targets, absent or
revoked relevance, and failed handshakes fail closed across every feed. Complete
sibling hardening evidence is still required; the existence of these safeguards
alone does not sign off every Gameplay Abilities network task.

## Exact platform inventory

The Linux and Windows runners produced byte-identical inventories at the audit
commit, including all native-byte hashes. The current six-package composition
has the following prerequisite results:

| Target/artifacts | Observed files | Meaning |
| --- | --- | --- |
| Windows x86-64, debug + release | 0 / 12 | All six packages lack both libraries. |
| Linux x86-64, debug + release | 0 / 12 | All six packages lack both libraries. |
| macOS declared debug + release | 11 / 12 | Level Task release is missing; the 11 present files match the project lock. |

A later reviewed headless composition may omit client-only packages. This
inventory does not silently assume such an exclusion or claim every future
server must ship CommonUI. It examines the current declared six-package bundle.
Missing required bytes block the load/export prerequisite; this audit does not
mislabel that result as a failed compiler invocation.

All six release-manifest files match their locked manifest-file digest. Four
CommonUI/CommonVision macOS debug/release artifacts match Zerkov's project pin
but differ from their release-manifest artifact digests, as already recorded by
`local_rebuilt_unmanifested`. This is a known release-provenance gap, **not a new
corruption finding**. The refined tool reads artifact digests from the actual
release manifest and separately reports the lock's recorded copy.

Gameplay Abilities pins source head `6620e50c868680bc947690db26dcb9a4ee77d15e`
and release revision `86090ec42070348f889eaa807e8c64ff33b6a53f`; Weapon pins
`460183752a305aba8ca1c3018ffb440014f50e4c` and
`9f2398239233457ba4f648a68c766b927d3f7460`. Level Task's source revision is null.
Every package records a dirty worktree at pin time. Version strings and historic
release test counts must not be presented as completion of a newer hardening
change. Keep the full package-tree hash policy; this inventory does not recompute
or replace the vendor validator's package-tree digest.

## Verified merged offline baseline

Real macOS addons, engine `4.7.2.stable.official.ed1daf0bf`, exact audit-head
checkout and temporary test projects. CI runs **35023547244** (Combat),
**35023547270** (Raid progression), and **35023547385** (platform inventory)
completed successfully. Downloaded raw logs identify `7da7168e...` and contain
all completion markers without script-error/failure diagnostics.

| Contract family | Result |
| --- | --- |
| Combat ingress replay | 3,595 / 0 twice, matching digests |
| Native combat ingress / execution | 60 / 0; 439 / 0 |
| Body-hitbox suites / weapon adapter / health adapter | 370 / 0 combined; 368 / 0; 467 / 0 |
| Health content / weapon content / context / reload / locomotion | 392 / 0; 80 / 0; 308 / 0; 176 / 0; 166 / 0 |
| AI replay / noise / review | 2,164 / 0 twice; 341 / 0; 235 / 0 |
| Native Vision / AI owner / owner failures | 438 / 0; 38 / 0; 89 / 0 |
| Progression values / native integration | 311 / 0 twice; 446 / 0 |
| Real-filesystem prepare / recover / verify | 9 / 0 in each of three separate Godot processes |
| ProfileStore | 527 / 0 |

These are the selected existing domain matrices, not all registered tests.
The art-specific workflow did not match these changes and is not counted.
Normal launch, physical input-driven extract/death traversal, between-raid health
rehydration and blind playtests remain separate. Merged gameplay code passing
its contracts is not the offline product-acceptance signoff required by task 12.
Final audit-head results belong in PR #16; this report preserves the exact
baseline evidence rather than silently reattributing it to a later commit.

## Required next work before networking

1. Identify the sibling hardening change/revision and reconcile it with W1–W5
   and G1/G2. Run its hostile-client, unauthorized resync/attachment, identity,
   chosen-entropy, first-snapshot/delta and reconnect tests against the exact
   rebuilt native artifacts. Repair native code in its owning workspace; re-vendor
   through the existing lock pipeline, not by editing pinned addon files here.
2. Build/load/export/checksum the Windows client and Linux server packages from
   reproducible SDK/toolchain inputs. Record debug/release and role-specific
   outcomes separately; regenerate honest release provenance for local rebuilds.
3. Close the offline first-playable acceptance and explicitly approve 10.2/10.3
   product networking contracts: authenticated actor/session/epoch, transport
   ingress mapping to internal ticks, replica-only client roles, and per-player
   outcomes distinct from the shared raid. Local file escrow is not a trusted
   client inventory upload or multiplayer multiwriter persistence service.
4. Only then open the server-plus-two-clients milestone: bounded remote admission,
   recipient grants, Vision-safe egress across **all** feeds, reversible prediction,
   retained/replacement reconnect, resync and committed consequence replication.
   Finish the loss/jitter/reorder, persistence-failure, soak and correction review
   gates before advertising support. No gate is waived by this audit.

## Reproduction and exit semantics

```sh
python3 tests/tooling/test_multiplayer_readiness.py
python3 tools/audit_multiplayer_readiness.py --output /tmp/zerkov-readiness.json
python3 tools/audit_multiplayer_readiness.py --require-platform-artifacts windows-client
python3 tools/audit_multiplayer_readiness.py --require-platform-artifacts linux-server
python3 tools/check_platform_artifacts.py windows-debug-client
python3 tools/check_platform_artifacts.py linux-debug-server
python3 tools/run_combat_input_contracts.py --godot "$ZERKOV_GODOT" --native --execution
python3 tools/run_ai_contracts.py --godot "$ZERKOV_GODOT" --native
python3 tools/run_raid_progression_contracts.py --godot "$ZERKOV_GODOT" --native
```

Use Python 3.10+ and an output outside the checkout. Inventory exit 0 means
collection succeeded; 1 means malformed/unreadable input; 2 means an explicitly
required platform-artifact prerequisite is blocked. **Every inventory report
keeps `network_ready=false` and platform support false**, even with matching
files. Existing debug-platform-checker results are preserved separately in CI.
The read-only workflow never enables peers, changes locks, applies patches,
pushes commits, or treats an expected prerequisite block as a successful build.

## Source fingerprints for review

| Audited file | SHA-256 |
| --- | --- |
| Weapon `native/godot/weapon_network_bridge.cpp` | `faae067d570cd3b0105bce32c3b079d990d3b9739acb6ac84ea7489f803abbda` |
| Weapon `native/core/wpn_runtime.cpp` | `509c9e04d450d7818ca9801880507fce1ce34a54bf6938d62d264abab1f4666a` |
| Weapon `native/protocol/wpn_replica.cpp` | `366704bfe5f935c9c669c33c535ce78a871d7030b935851931347fd740eee041` |
| Gameplay Abilities `native/godot/gameplay_ability_network_bridge.cpp` | `7f1c2d74e66a8fb770acd49424fa9cbda99baabeb3740268ca95bc53102ecd32` |
| Gameplay Abilities `native/godot/gameplay_ability_network_bridge.h` | `792040cf2d5d7384ffcf1a591ce5fff8bd30470df7e12c1ed6d2479487727e73` |

Full input, descriptor, manifest and binary SHA-256s are in the CI inventories;
full raw native results and source packets remain short-lived CI artifacts, not
committed generated log bundles. This PR deliberately adds only audit tooling,
its negative controls, read-only CI and this report.
