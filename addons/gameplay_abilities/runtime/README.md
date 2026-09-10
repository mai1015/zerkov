# `runtime/` — typed GDScript hooks

Everything here is typed GDScript that composes the native addon's public
API (`GameplayAbilityComponent`, `GameplayAbilityNetworkBridge`, and the
`native/resources/` authoring Resources). Nothing in this directory touches
godot-cpp or `native/`.

## Logical cue adapters (task 9.6)

`ga_cue_adapter.gd` (`GameplayCueAdapter`) is a base `Node` that consumes a
`GameplayAbilityComponent`'s `effect_cue_triggered` and
`prediction_phase_changed` signals and turns them into one dispatched,
deduplicated call sequence. **This addon does not ship a mandatory
presentation framework** — `GameplayCueAdapter` and the four adapters under
`cues/` are a minimal, optional demonstration of the right pattern. A game
may ignore all of this and read the two signals directly instead.

### The phase state machine

Every cue and every predicted command carries one `CuePhase`
(`GameplayAbilityComponent.CuePhase`, mirroring `ga::CuePhase`):

| Phase | Meaning |
|---|---|
| `CUE_PREDICT` | The owning client applied this locally, ahead of authority confirmation. |
| `CUE_CONFIRM` | Authority matched a predicted occurrence — it is now real. |
| `CUE_CORRECT` / `CUE_CANCEL` | Authority rejected or diverged from the prediction — undo it. |
| `CUE_AUTHORITY_ONLY` | This occurrence was never predicted at all (e.g. a remote-target effect, or any non-owning observer). Treated as an immediate confirmation. |
| `CUE_SNAPSHOT_RESTORED` | A late join or resync snapshot revealed this effect is *already active* — not a new occurrence. |

`GameplayCueAdapter` dispatches every phase to one of four overridable
methods, each receiving the same stable dedup key the base class computed:

```
_on_predicted(key: String, payload: Dictionary)        # CUE_PREDICT
_on_confirmed(key: String, payload: Dictionary)        # CUE_CONFIRM, CUE_AUTHORITY_ONLY
_on_cancelled(key: String, payload: Dictionary)        # CUE_CORRECT, CUE_CANCEL
_on_snapshot_restored(key: String, payload: Dictionary) # CUE_SNAPSHOT_RESTORED
```

### Dedup rules

Every occurrence has a stable identity shaped like `ga::CueDedupId`
(`target`, `definition`, `handle`, `occurrence`). `GameplayCueAdapter`
computes one dedup key per incoming payload and tracks each key's state as
either `"predicted"` (seen a PREDICT, not yet resolved) or `"resolved"`
(seen a terminal CONFIRM/AUTHORITY_ONLY/CORRECT/CANCEL). The dispatch rule
this produces, matching `specs/gameplay-ability-networking/spec.md`'s
"Prediction-Aware Presentation Events" and "Component-Local Reconciliation":

- **A predicted cue is confirmed exactly once.** A duplicate CONFIRM/
  AUTHORITY_ONLY for an already-resolved key is swallowed.
- **A rejected prediction is cancelled exactly once.** CORRECT/CANCEL only
  fires `_on_cancelled` for a key currently in the `"predicted"` state; a
  key that was never predicted, or was already resolved, is left alone.
- **No duplicate irreversible presentation.** Because CONFIRM/
  AUTHORITY_ONLY is itself deduplicated, an adapter that waits for it (see
  below) can never spawn/play twice for the same occurrence.
- **No replay of historical one-shot cues on snapshot restore.**
  `CUE_SNAPSHOT_RESTORED` never calls `_on_predicted`/`_on_confirmed`/
  `_on_cancelled` — only `_on_snapshot_restored`, itself deduplicated
  per key so a persistent-state notification isn't repeated on every
  subsequent snapshot of the same still-active effect.

### Reversible vs. irreversible presentation

This is the single most important design decision a concrete adapter makes,
and the four examples under `cues/` each demonstrate one side of it:

- **Reversible** presentation (a HUD badge, an anticipation animation pose)
  is cheap to start speculatively and cheap to undo, so it may start on
  `_on_predicted` and be corrected in `_on_cancelled`.
  See `cues/ga_cue_adapter_hud.gd` and `cues/ga_cue_adapter_animation.gd`.
- **Irreversible** presentation (a spawned particle burst, a played sound)
  cannot be taken back once it happens, so it must wait for
  `_on_confirmed` and do nothing at all in `_on_predicted`/`_on_cancelled`.
  See `cues/ga_cue_adapter_vfx.gd` and `cues/ga_cue_adapter_audio.gd`.

When in doubt, wait for confirmation — a slightly-delayed effect is far less
noticeable than an effect that visibly plays and then has to be walked back.

### Wiring an adapter

```gdscript
var hud_adapter := GameplayCueAdapterHud.new()
add_child(hud_adapter)
hud_adapter.attach(my_ability_component)   # or set `component_path` in the editor
```

## Authoring bridges (task 9.1 remainder)

- `ga_ability_definition_bridge.gd` (`GameplayAbilityDefinitionBridge`)
  converts an authored `GameplayAbilityDefinition` resource (or an array of
  them) into the `Dictionary` shape `GameplayAbilityComponent.set_ability_definitions`
  already accepts. The native component binding still takes
  `Array[Dictionary]` rather than `TypedArray[GameplayAbilityDefinition]`
  directly (see that resource's header comment for why); this bridge is the
  seam a future native binding change would let a caller drop.
- `ga_network_policy_bridge.gd` (`GameplayNetworkPolicyBridge`) applies an
  authored `GameplayNetworkPolicy` resource to a
  `GameplayAbilityNetworkBridge`'s existing `hidden_*`/`relevant_peers`/
  `owner_view` setters, so a game maintains one policy asset per component
  instead of hand-built `PackedStringArray` literals at every call site.
