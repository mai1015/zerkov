# Multiplayer session foundation

This directory begins the approved task 10.2 product boundary. It deliberately
does **not** enable ENet, Steam, RPC handlers, replicas, prediction or online
profile settlement.

The current slice provides:

- a product compatibility manifest with exact protocol, command-schema and
  content-fingerprint checks plus required-feature negotiation;
- a server-side authentication port that returns credential-free principal,
  profile and actor claims;
- remote session admission with stable actor identity, monotonic authority
  epochs and immutable admission snapshots;
- a bounded registry that binds one authenticated actor to one transport peer
  and accepts only the next contiguous command sequence.

`ZProductSessionRegistry.admit_command()` is an admission fence, not a gameplay
executor. Later transport work must pass it and all task 10.4 semantic/rate/
relevance checks before creating a `ZRaidIntent`. `RaidAuthority` remains the
only canonical gameplay mutation owner.

Offline startup remains the default. `SessionCoordinator.new()` still installs
`OfflineSessionIngress`, and local profile bytes are not authentication or
online inventory authority.


## Phase B composition and remote-command boundary

The next bounded slice adds three explicit scene roots under
`game/multiplayer/compositions/`:

- `dedicated_server.tscn` owns the canonical `RaidAuthority`, authenticated
  remote-session registry and remote-command gate;
- `owning_client.tscn` owns only a bounded confirmed-state replica store;
- `observer_client.tscn` owns only an independent bounded confirmed-state
  replica store.

These scenes are not referenced by startup and create no ENet or Steam peer.
They are composition boundaries only.

Remote commands are translated rather than forwarded. The game-owned transport
adapter must supply the actual received byte count and decoded command record to
`ZRemoteCommandGate`. The gate checks, in order, size, rate, exact shape,
active session, negotiated compatibility, actor ownership, relevance, remote
sequence, current revision and command semantics. Sequence preflight is
non-consuming; revision or semantic rejection does not burn the caller's next
sequence. After all checks pass, the registry atomically consumes that remote
sequence.

The accepted remote session ID and authority epoch are never inserted into
`RaidAuthority`. Instead the gate stamps a new internal `ZRaidIntent` with the
server-owned authority session/epoch, the authenticated remote actor, trusted
server timing and a separate monotonic per-actor internal sequence. A reconnect
may therefore restart its remote replay namespace at one without colliding with
the raid's canonical intent history.

`ZRemoteCommandPolicyPort` defaults relevance, revision and semantics to
fail-closed behavior. Later visibility/relevance work may derive those answers
from authoritative Common Vision state; clients do not get authority from that
policy seam.
