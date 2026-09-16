# Candidate design and trust boundaries

The server issues a fresh random connection token only after the trusted host
opens a session. The token correlates a connection; it does not authenticate an
account. Compatibility is decoded and compared against each side's own catalog.
Each authorized peer/instance obtains explicit permissions. All command,
resync, acknowledgement and state paths check session, token, compatibility,
relevance, input bounds and rate limits.

The bridge namespaces replay identity with connection token and instance; client
counter names cannot collide at the native authority. The game receives no
client-selected sampling entropy. RPC admission queues value inputs
and never calls weapon mutation. Before executing, the host checks that the
pending command's session/grant remains current; afterwards it completes the
actual result. Revocation records negative replay state before discarding queued
work. Prediction is resolved by correlated results, not another actor's snapshot.

Initial snapshots acknowledge revision zero. Delta acknowledgements must name
revisions actually sent to that recipient; arbitrary future numbers are rejected.
Disconnect and grant revocation invalidate confirmed client state. A revoked
view is not a canonical gameplay tombstone. Stale connection traffic cannot
repopulate a replacement session.

Candidate provenance hashes all staged source files and changed outputs. Builds
use the existing exact godot-cpp pin and full addon source, with only unused SDK
bindings trimmed. Native fixtures load actual candidate debug/release libraries
with explicit startup registration. Three ENet peers are separate multiplayer
roots in one process; this is not a three-process game soak or loss/jitter test.
GAS native property/default checks do not establish target-RPC authorization.

Installed-game regression jobs continue using the old locked binaries. Their
passes cannot establish compatibility of the newly built candidate with the
complete game. That requires a later reviewed staged game replacement, complete
required regressions, package manifest/lock regeneration and loader resolution.
