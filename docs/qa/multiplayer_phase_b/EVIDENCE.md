# Phase B — task 10.3 / 10.4 acceptance evidence

Date: 2026-09-19

Status: exact-head implementation candidate accepted for merge. This record does
not claim live ENet/Steam support, native addon promotion, replication egress,
prediction, reconnect/resynchronization, hostile multi-process qualification, or
release-platform support.

## Exact revisions

- Task 10.2 merged commit: `09af7fc55480d4b39e3bbefff06a1da31254e4c5`.
- Phase A evidence merge: `304faeb2ad5ecbfea9a2d57cd7881b76f768a247`.
- Phase B reviewed head: `3414ba1587432a8abd7efa6d58e4ff2555232505`.
- Pull request: `#51` — `feat(multiplayer): add Phase B role separation and remote command gate`.

## Implemented boundary

Task 10.3 adds separate transport-neutral scene roots:

- `dedicated_server.tscn`: owns the canonical `RaidAuthority`, authenticated
  remote-session registry, and remote-command gate;
- `owning_client.tscn`: owns only a bounded confirmed-state replica store;
- `observer_client.tscn`: owns only an independent bounded confirmed-state
  replica store.

The client compositions expose no canonical authority handle. The scenes are not
wired into normal startup and create no ENet or Steam peer.

Task 10.4 adds the product ingress chain:

```text
size -> rate -> shape -> session -> compatibility -> ownership -> relevance
     -> sequence preflight -> revision -> semantic -> internal enqueue
     -> replay-sequence commit
```

Remote session identifiers and authority epochs are not forwarded into
`RaidAuthority`. Accepted requests are translated into new internal
`ZRaidIntent` values using the server-owned authority session/epoch, the
server tick, the authenticated actor, and a distinct per-actor internal
sequence. Remote replay-sequence preflight is non-consuming; relevance,
revision, semantic, or canonical-enqueue rejection does not consume the remote
sequence.

## Native contract results

Workflow: `Multiplayer session foundation`, run `35425525578`, pinned Godot
`4.7.2.stable.official.ed1daf0bf`.

| Contract | Result |
| --- | ---: |
| Product session foundation | 57 checks / 0 failures |
| Phase B composition and remote-command gate | 55 / 0 |
| Existing offline session lifecycle | 44 / 0 |
| Equipped-item identity regression | 123 / 0, 14 publications |

The native editor import completed without `SCRIPT ERROR`, `ERROR:`, or
`WARNING:` markers in the retained import log.

The exact Phase B head also completed all ten triggered workflows successfully:

| Workflow | Run | Conclusion |
| --- | ---: | --- |
| Multiplayer session foundation | `35425525578` | success |
| Pre-multiplayer validation | `35425525575` | success |
| Combat contracts | `35425525549` | success |
| Raid progression | `35425525566` | success |
| Local first playable | `35425525585` | success |
| Equipment UI | `35425525543` | success |
| Bunker workspaces integration | `35425525548` | success |
| Unified bunker campaign flow | `35425525590` | success |
| Offline journey UX | `35425525555` | success |
| Raid handler CPU profile | `35425525574` | success |

## Evidence artifact

- Name: `multiplayer-session-foundation`
- Artifact ID: `10578149995`
- Archive SHA-256: `55c8ebee590264f4c31efcdee6250d122e01c4c0325a5191f688a3e989466ebc`
- Recorded commit: `3414ba1587432a8abd7efa6d58e4ff2555232505`

The archive contains the exact commit, selected source hashes, native import log,
product/Phase-B contract log, offline-session regression log, and equipment
identity regression log.

## Remaining section-10 work

Task 10.1 remains open: candidate hardening evidence exists, but the actual
owning sibling changes, cold-discovery promotion prerequisite, truthful package
identity, normal re-vendoring, and full promoted-byte regressions are not closed.

Tasks 10.5–10.13 remain open. In particular, this Phase B acceptance is not the
server-plus-two-client hostile transport test in 10.10 and is not a release
qualification claim.
