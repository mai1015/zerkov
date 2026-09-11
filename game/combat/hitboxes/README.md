# Authoritative body hitboxes

`BodyHitboxWorld2D` is Zerkov-owned canonical spatial state. Callers replace
its complete fixed-unit snapshot once per authoritative tick; the service does
not read `Node2D`, presentation, animation, Weapon System, or Gameplay
Abilities transforms.

The sealed humanoid profile contains seven AABBs: head, thorax and abdomen
(the torso group), left/right arms, and left/right legs. Ray candidates are
ordered by exact rational entry distance. An obstruction wins an exact tie
with a body. Remaining ties use obstruction ID, or entity ID then authored
zone priority then hitbox ID. Input Array or scene-tree order is irrelevant.

Binding captures the exact `RaidAuthority`, raid, session, epoch, authorized
owner actor/source, and concrete world instance. Every publication, complete-
snapshot removal, query, replay, release, and metadata read requires the exact
opaque capability object minted and returned once by that bind. There is no
active-capability lookup for stale callers. The world retains only a SHA-256
commitment over a cryptographically random 32-byte lease, the candidate object
identity, and the exact world/authority/generation/token context. It retains no
live capability, weak reference, bound callable, raw lease, or capability
instance ID. A copied lease in another object therefore cannot authenticate.
Generation/token values remain deterministic audit provenance but are never
treated as credentials; foreign or revoked capabilities fail even when every
public ID and counter is identical. Release clears the commitment and erases
the returned object's lease before clearing state; authority teardown
invalidates it before query parsing or replay lookup.
The only public binding/snapshot metadata readers are
`binding_provenance(capability)` and `snapshot_metadata(capability)`; redundant
scalar getters are intentionally absent, so retaining a reused world reference
cannot expose or reacquire replacement-binding metadata.

Consumers receive the bearer only from `bind_raid_authority` and pass it as a
transient argument to guarded operations. Runtime `Object` adapters must not
cache the bearer, its raw lease, or an equivalent callable in reflectively
discoverable members. No authorization material is included in snapshot
metadata, query-result/replay records, or their canonical digests.

The binding owner and snapshot publisher, every body entity/source, and every
query actor/source are checked through `RaidAuthority`'s explicit read-only
authorization port. No scene node or live transform participates. Complete
snapshots are validated before replacement, body and obstruction revisions
cannot regress or resurrect after removal, query IDs cannot be reused for
different inputs, and all storage/work limits fail closed. Authoritative
metadata, profile declarations, hit/miss/obstruction results, replays, and
rejections are detached and recursively read-only.

Snapshot bodies use the exact fields `entity_id`, `actor_source`,
`profile_id`, `body_revision`, `origin_raw`, `facing_quarter_turns`,
`collision_layer`, and `targetable`. Obstructions use `obstruction_id`, `geometry_revision`,
`min_raw`, `max_raw`, `collision_layer`, and `enabled`. Ray queries use
`request_id`, raid/session/epoch/generation/token provenance, binding-owner
actor/source, query actor/source, `tick`, `world_revision`, `origin_raw`,
`target_raw`, `body_mask`, `obstruction_mask`, and `excluded_entity_ids`.
Positions are `Vector2i` canonical micro-world-units; no float or presentation
transform is admitted. Runtime object identities participate only inside the
unpublished one-way commitment and are deliberately excluded from binding
provenance, canonical snapshots, query results, and resolution hashes.
