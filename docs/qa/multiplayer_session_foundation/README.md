# Task 10.2 — product multiplayer session foundation

Status: implementation candidate; acceptance requires a green native workflow on
the exact reviewed head.

This bounded slice defines authenticated remote admission, profile/actor claims,
authority-epoch fencing, contiguous command sequence admission and compatibility
negotiation at the game-owned product layer. It intentionally does not install a
transport, expose RPCs, create client replicas, trust local profile files as
online state, or promote the staged Weapon/Gameplay Abilities network binaries.

The implementation keeps `SessionCoordinator.new()` offline by default.
`AuthenticatedSessionIngress` must be supplied explicitly by a future trusted
host composition. A successful authentication returns only credential-free
claims. `ZProductSessionRegistry` binds those claims to one transport peer and
does not execute gameplay; a later task 10.4 adapter must still apply size,
rate, relevance, revision and semantic checks before enqueueing a `ZRaidIntent`.

The pinned Godot 4.7.2 workflow records the exact commit and source hashes, then
runs:

- product compatibility/authentication/ownership/epoch/sequence contracts;
- the existing offline session lifecycle regression;
- the equipped-item identity-boundary regression affected by admission fields;
- exact-1080 repository policy checks;
- a native editor import on macOS.

Live ENet/Steam traffic, server/client scene composition, reconnect/resync,
prediction, scoped replication, hostile packet/flood testing and release
artifacts remain tasks 10.3–10.13.
