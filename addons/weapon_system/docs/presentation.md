# Presentation

Every `WeaponAuthority` and `WeaponNetworkBridge` signal, and the boundary
between canonical state and presentation. Presentation never owns loaded rounds, cadence, reload
completion, MOA, recoil/recovery, attachment loadout, ballistic-profile
identity, hit selection, penetration, damage, inventory, or GAS state.
Removing every presenter must leave authoritative behavior unchanged.

## `WeaponAuthority` signals

(`native/godot/weapon_authority.cpp`'s `_bind_methods()`)

| Signal | Payload | Emitted when |
|---|---|---|
| `shot_committed` | `Dictionary outcome` | An accepted `fire()` — the full public outcome Dictionary. Its nested `shot` contains origin, direction, damage/range/noise milliunits, consumed profile, and legacy `consequence_id`. The core's structured consequence identity and exact shot-profile identity are not exposed by this Dictionary. This is a **mechanical** commit, not a world-resolved hit. |
| `reload_started` | `Dictionary outcome` | An accepted `begin_reload()`. |
| `reload_completed` | `Dictionary completion` | A published reload (via `publish_reload_completion()`), whether reached through `advance_tick()` or the prepared-participant path (`commit_due_reload()`). |
| `reload_cancelled` | `Dictionary outcome` | An accepted `cancel_reload()`. |
| `command_rejected` | `Dictionary outcome` | A rejection returned by the core command path. Read the synchronous return too: readiness and façade-conversion failures can return before submission and emit no signal. |
| `state_corrected` | `Array snapshots` | `replace_snapshots()` — a trusted wholesale state replacement (new epoch, restore, resync). |
| `attachment_loadout_changed` | `Dictionary {instance_id, revision, attachment_loadout}` | An accepted `configure_attachments()`. |
| `recoil_anchor_changed` | `Dictionary anchor` | An accepted fire that produced a new recoil anchor. |
| `instance_torn_down` | `Dictionary outcome` | An accepted `teardown()`. |

An exact idempotent retry returns `accepted: true, replayed: true`. Because
the façade branches on `accepted`, it can emit the accepted signal again even
though canonical state was not mutated twice. Gate non-idempotent VFX/audio/
world effects on `replayed == false` or deduplicate with command/consequence
identity.

**There is no `shot_resolved` signal.** `WeaponAuthority` has no knowledge of
world resolution (hit/miss/obstruction) at all — that lives entirely in the
engine-free `wpn::WorldCoordinator`, which currently has no Godot façade (see
[`integration.md`](integration.md)'s "World ports" section). A game that
wants a "shot resolved" presentation event must currently derive it in its
own authoritative world-resolution code, reacting to `shot_committed` and
then emitting a game-owned result signal.

## `WeaponNetworkBridge` signals

(`native/godot/weapon_network_bridge.cpp`'s `_bind_methods()`)

| Signal | Payload | Meaning |
|---|---|---|
| `command_rejected` | `peer, command_id, instance_id, ...` | Server rejected an inbound command (distinct signal from `WeaponAuthority`'s own — this one is peer-scoped). |
| `network_diagnostic` | `peer, Dictionary status` | Bounded diagnostic for malformed/oversized/rate-limited traffic. |
| `presentation_predicted` | `command_id, instance_id, ...` | CLIENT role: a predicted command was sent. |
| `presentation_confirmed` | `command_id, instance_id, ...` | A confirmed sequence now covers this predicted intent. |
| `presentation_reverted` | `command_id, instance_id, ...` | Authority rejected the predicted intent — restore the newest confirmed snapshot. |
| `presentation_diverged` | `command_id, instance_id, ...` | A replica resync/gap discarded this pending intent — its true fate is unknowable, discarded conservatively. |
| `presentation_expired` | `command_id, instance_id, ...` | The intent aged out (`MAX_PRESENTATION_INTENT_AGE_TICKS`) or was evicted by capacity before resolving. |
| `snapshot_applied` | `instance_id, revision` | CLIENT role: a fresh snapshot was applied. |
| `delta_applied` | `instance_id, revision` | CLIENT role: a delta was applied. |
| `resync_needed` | `instance_id` | Replica detected a gap and needs a fresh snapshot. |
| `instance_tombstoned` | `instance_id, revision` | A tombstone was replicated to this client. |

The current bridge does not transport its protocol library's committed-shot
result envelope, and `confirmed_snapshot()` exposes only a small public state
projection. Network clients should replicate game-owned hit/VFX results and
drive views from bridge confirmation/correction signals. See
[`how-it-works.md`](how-it-works.md#current-godot-bridge-boundaries).

## Recoil recovery: derive it, don't wait for it

Neither `WeaponAuthority` nor `WeaponNetworkBridge` emits a per-tick "recoil
recovered" event — `recoil_anchor_changed` fires only on a **new** kick
(an accepted fire). Presenters derive continuous recovery themselves from
the confirmed anchor (`recoil_vertical_offset_nrad`,
`recoil_horizontal_offset_nrad`, `recoil_anchor_tick` on a snapshot) plus the
current authority tick, using `WeaponAuthority.effective_recoil(...)` with the
instance ID and authority tick (a pure read-only query), or the equivalent client-side pure
function — never a canonical per-tick mutation signal.

## Bounded reversible prediction

Every predicted presentation (`WeaponNetworkBridge`'s CLIENT-role
`request_*_networked()` calls) has a stable intent identity
(`command_id`/`sequence`), a bounded lifetime
(`MAX_PENDING_PRESENTATION_INTENTS` = 64,
`MAX_PRESENTATION_INTENT_AGE_TICKS` = 300), and an explicit correction path
(`presentation_confirmed`/`presentation_reverted`/`presentation_diverged`/
`presentation_expired`). It is structurally incapable of mutating canonical
state — the tracker that records it
(`wpn::protocol::PresentationPredictionTracker`) has no
`WeaponRuntime`/`WeaponReplica`
member and no method that returns anything but its own bounded
`PresentationIntent` value.

## Optional presenter classes

The addon ships seven removable GDScript helpers under
`res://addons/weapon_system/presenters/`. They read public state/signals and
never issue weapon commands or become authority:

| Class | Connect it with | What it does / important boundary |
|---|---|---|
| `WeaponMuzzleFlashPresenter` | `attach(authority, instance_id)` | Filters `shot_committed` by instance and draws a short 2D flash. It does not suppress replayed outcomes. |
| `WeaponTracerImpactPresenter` | `wire_to_weapon(authority, instance_id, pixels_per_milliunit, origin)` or `show_tracer()` / `show_impact()` | Auto-wiring draws the nominal full-range ray only. It performs no physics query; pass your resolved endpoint for accurate impact presentation. |
| `WeaponAmmoHudPresenter` | `attach(authority, instance_id, capacity)`, then `refresh()` | Reads loaded rounds, exact loaded-profile label, and phase. Refresh is manual and capacity is game-supplied. |
| `WeaponReloadProgressPresenter` | `attach(authority, instance_id)`, then `update_tick(authority_tick)` | Derives progress from snapshot `start_tick`/`due_tick`. Its authority-wide signal handlers do not filter instance ID, so wrap it in a multi-instance authority. |
| `WeaponCorrectionFlashPresenter` | `attach(authority)` | Flashes on `state_corrected` or core `command_rejected`. Rejection outcomes cannot always identify the target instance; safest for a single-instance authority. |
| `WeaponInspectorPanel` | `configure(authority, instance_id, base_accuracy, recoil_profile, attachments, slot_labels)`, then `refresh(tick)` | Combines confirmed runtime queries with content Dictionaries retained by the game, because sealed definition content has no public read-back API. |
| `WeaponDiagnosticsPanel` | `watch_weapon_authority(authority)`, `watch_adapter(adapter, adapter_name)`, `watch_network_bridge(bridge)` | Stores a bounded, oldest-evicted diagnostic list. It reports only signals it observes and never changes recovery behavior. |

Minimal direct-authority setup:

```gdscript
func add_weapon_presenters() -> void:
    var muzzle := WeaponMuzzleFlashPresenter.new()
    add_child(muzzle)
    muzzle.attach(weapon_authority, "player-1:primary")

    var ammo := WeaponAmmoHudPresenter.new()
    add_child(ammo)
    ammo.attach(weapon_authority, "player-1:primary", 12)
    weapon_authority.shot_committed.connect(func(outcome: Dictionary) -> void:
        if not bool(outcome.get("replayed", false)):
            ammo.refresh()
    )
```

These helpers listen to `WeaponAuthority`, not a client-role
`WeaponNetworkBridge`. In networked play, either adapt bridge signals and its
limited confirmed snapshot to your own UI, or add an explicit view-model
layer. Removing every presenter leaves deterministic/headless authority
behavior unchanged.
