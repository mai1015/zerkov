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
