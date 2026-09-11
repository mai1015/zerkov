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

Queries and snapshot publication carry the captured authority generation and
binding token. Complete snapshots are validated before replacement, body and
obstruction revisions cannot regress or resurrect after removal, query IDs
cannot be reused for different inputs, and all storage/work limits fail closed.

Snapshot bodies use the exact fields `entity_id`, `profile_id`,
`body_revision`, `origin_raw`, `facing_quarter_turns`, `collision_layer`, and
`targetable`. Obstructions use `obstruction_id`, `geometry_revision`,
`min_raw`, `max_raw`, `collision_layer`, and `enabled`. Ray queries use
`request_id`, `authority_generation`, `binding_token`, `tick`,
`world_revision`, `origin_raw`, `target_raw`, `body_mask`,
`obstruction_mask`, and `excluded_entity_ids`. Positions are `Vector2i`
canonical micro-world-units; no float or presentation transform is admitted.
