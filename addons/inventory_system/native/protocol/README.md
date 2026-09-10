# Protocol boundary

This directory is reserved for bounded, versioned, transport-neutral commands,
results, snapshots, deltas, codecs, compatibility handshakes, visibility
projections, and persistence records.

Protocol code may depend on `native/core` and the C++17 standard library. It may
not depend on Godot, a socket API, a database, CommonUI, or Gameplay Abilities.
