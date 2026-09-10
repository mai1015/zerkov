# Integration: Input, AI, Replay, and the Network Session

How a game wires *anything* — a player's keypress, a bot's decision, a
recorded test script — to an ability activation, given the addon's own
normative rule (`specs/gameplay-abilities/spec.md`, "Input-Agnostic
Activation API"):

> The gameplay ability addon SHALL expose logical activation and
> input-phase requests without registering, consuming, or rebinding
> physical `InputEvent` values. CommonUI, `InputMap`, AI, replay, or tests
> MAY feed requests through game-owned adapters without becoming runtime
> dependencies.

Concretely: nothing under `addons/gameplay_abilities/native/` includes
`<godot_cpp/classes/input_event.hpp>`, subscribes to `_input`/
`_unhandled_input`, or reads `InputMap`/`Input` in any form. Verified by
inspection of `native/godot/gameplay_ability_component.h`/`.cpp` and
`native/godot/gameplay_ability_network_bridge.h`/`.cpp` — neither file
mentions `InputEvent`, `InputMap`, or `Input` anywhere. The only
input-shaped field anywhere in the ability data model is
`AbilityTriggerDesc::input_id` (`native/core/ga_abilities.h`), and it is
documented there as "an opaque, game-defined logical action name (e.g.
`"action.dash"`) — never a Godot `InputEvent` and never registered,
consumed, or rebound by this addon." The core does not even read this
field to auto-activate anything: `AbilityComponent::handle_gameplay_event`
(`native/core/ga_ability_component.cpp`) only ever matches
`AbilityTrigger::Kind::GAMEPLAY_EVENT` triggers against a delivered
`GameplayEventContext`; an `INPUT`-kind trigger's `input_id` is inert
metadata a game-owned adapter may read to build its *own* action → ability
mapping. There is no automatic "this action fires this ability" wiring
anywhere in `native/core/` or `native/godot/`.

## Dependency direction

From `design.md`, "Independent addon and dependency direction":

```text
CommonUI or InputMap
        |
        v
game-owned player/controller adapter
        |
        v
GameplayAbilityComponent <----> GameplayAbilityNetworkBridge
        |
        +---- tags / attributes / effects / ability executions
        |
        v
signals and presentation events -> HUD / animation / VFX / audio
```

Reading the arrows:

- **Top box, `CommonUI or InputMap`**: whatever the *game* uses to decide
  "the player pressed dash" — CommonUI's namespaced logical actions, a bare
  `InputMap` action, a gamepad glyph, whatever. The ability addon has no
  opinion here and no code path that touches it.
- **`game-owned player/controller adapter`**: a script the *game* owns
  (not part of `addons/gameplay_abilities/`) that translates whatever the
  top box produced into a `GameplayAbilityComponent`/
  `GameplayAbilityNetworkBridge` call. This is the one and only place input
  vocabulary crosses into ability vocabulary, and it is entirely outside
  the addon.
- **`GameplayAbilityComponent <----> GameplayAbilityNetworkBridge`**: the
  addon's own two Godot nodes (see `api.md`). The double arrow is
  deliberate — the bridge reads the component's state to build outgoing
  packets and calls back into the component's `request_activation`
  for offline/authority roles; neither depends on anything above it.
- **`tags / attributes / effects / ability executions`**: the engine-free
  `native/core/` simulation the component owns. It never sees input,
  never sees CommonUI, never sees the network transport.
- **`signals and presentation events -> HUD / animation / VFX / audio`**:
  the addon emits value DTOs (`api.md`'s 18 component signals + 11 bridge
  signals); a game-owned presentation adapter decides what those events
  mean visually. Symmetric with the top of the diagram: the addon never
  reaches upward into a specific HUD/VFX/audio framework either.

Every arrow points *down* through the addon and back *out* through
signals. Nothing in `addons/gameplay_abilities/native/` references
`addons/common_ui/` (verified: `grep -rl "gameplay_abilities\|GameplayAbility" addons/common_ui` returns nothing), and nothing in
`addons/common_ui/native/` references `addons/gameplay_abilities/` either.
The two addons are siblings; a game may use either, both, or neither.

## The one contract every adapter goes through

Regardless of *why* an activation is being requested, every adapter below
ends at the identical call:

```gdscript
ability_component.request_activation(request: Dictionary, tick: int) -> Dictionary
```

(or its batch form `process_activation_batch(requests: Array, tick: int) -> Array`,
or `handle_gameplay_event(event: Dictionary, tick: int) -> Dictionary` for
event-triggered abilities — see `api.md` for the exact `request`/`event`
Dictionary shapes and the returned `ActivationResult` shape). There is no
separate "player request" API versus "AI request" API versus "replay
request" API — a CommonUI-driven controller, an `InputMap`-driven
controller, server-side AI, and a test/replay driver are four different
*callers* of the exact same method, which is what makes the diagram above
true rather than aspirational.

### Example 1 — a game-owned controller driven by CommonUI

CommonUI's real, verified API (`addons/common_ui/native/godot/common_ui_runtime.h`):
`CommonUIRuntime.register_action(action: StringName, callback: Callable, options: Dictionary) -> Ref<CommonUIActionHandle>`.
The callback receives one `Dictionary` shaped
`{action, phase, device, ui_user, viewport_id, time_usec, repeat_index, handle_id}`
(built in `CommonUIRuntime::Invoker::invoke`, `common_ui_runtime.cpp`) and
returns a `CommonUIRuntime.RouteResult`; the return value is only read when
`phase == CommonUIRuntime.PHASE_PRESSED` (matching
`addons/common_ui/controls/common_button.gd`'s own real usage pattern —
this example follows that file's exact idiom rather than inventing a new
one):

```gdscript
# game-owned, NOT part of addons/gameplay_abilities/ or addons/common_ui/
extends Node

@export var ability_component: GameplayAbilityComponent
var _dash_spec: int = -1  # AbilitySpecId, resolved once dash is granted
var _next_sequence: int = 1

func _ready() -> void:
	_dash_spec = _grant_dash()
	CommonUIRuntime.get_singleton().register_action(
		&"gameplay.dash", _on_dash_action, {"owner": self})

func _grant_dash() -> int:
	var result := ability_component.grant_ability("ability.dash", 1, "action.dash", ability_component.get_current_tick())
	return int(result["spec"])

func _on_dash_action(event: Dictionary) -> int:
	if event["phase"] != CommonUIRuntime.PHASE_PRESSED:
		return CommonUIRuntime.ROUTE_UNHANDLED
	var result := ability_component.request_activation({
		"spec": _dash_spec,
		"command_sequence": _next_sequence,
	}, ability_component.get_current_tick())
	_next_sequence += 1
	var status: Dictionary = result["status"]
	return CommonUIRuntime.ROUTE_HANDLED if status["ok"] else CommonUIRuntime.ROUTE_UNHANDLED
```

`GameplayAbilityComponent` never appears inside `addons/common_ui/`, and
`CommonUIRuntime` never appears inside `addons/gameplay_abilities/` — this
script is the *only* place the two vocabularies meet, and it belongs to
the game.

### Example 2 — the same controller driven by plain `InputMap`

A game that does not use CommonUI at all wires the identical
`request_activation` call from `_unhandled_input`:

```gdscript
# game-owned; no CommonUI dependency at all
extends Node

@export var ability_component: GameplayAbilityComponent
var _dash_spec: int = -1
var _next_sequence: int = 1

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("dash"):
		var result := ability_component.request_activation({
			"spec": _dash_spec,
			"command_sequence": _next_sequence,
		}, ability_component.get_current_tick())
		_next_sequence += 1
		if result["status"]["ok"]:
			get_viewport().set_input_as_handled()
```

Both controllers call the *exact same* `request_activation(Dictionary, int)`
method on the *exact same* class. Swapping Example 1 for Example 2 (or
running both side by side for different input methods) never touches
`addons/gameplay_abilities/`.

### Example 3 — server-side AI, no physical input at all

Per the spec's own scenario ("Dedicated server executes AI ability"): a
headless server has no `InputEvent`s, no viewport, and no CommonUI
autoload running at all (a dedicated-server export need not even bundle
CommonUI). An AI controller reaches the identical call directly:

```gdscript
# game-owned AI controller, runs only on the server/authority
extends Node

@export var ability_component: GameplayAbilityComponent  # role == ROLE_SERVER_AUTHORITY

func _on_ai_decided_to_dash(command_sequence: int) -> void:
	var result := ability_component.request_activation({
		"spec": _resolve_dash_spec(),
		"command_sequence": command_sequence,
		"provenance": GameplayAbilityComponent.PROVENANCE_AUTHORITATIVE,
	}, ability_component.get_current_tick())
	# result["status"] follows the identical ActivationResult contract
	# every other caller in this document receives.
```

Nothing about the ability's validation, cost/cooldown/tag checks,
transaction commit, or emitted signals differs based on who called
`request_activation` — the component has no notion of "this call came from
a human" versus "this call came from AI." That symmetry is the whole point
of the "Input-Agnostic Activation API" requirement.

### Example 4 — a deterministic test/replay driver

A recorded fixture (matching the shape `native/tests/ga_test_conformance.cpp`'s
`ScenarioOp`/`ScenarioBuilder` uses at the native-test level, translated to
the Godot-facing Dictionary contract) replays a fixed list of
`(tick, request)` pairs through the identical method, with no wall clock,
no `InputEvent`, and no CommonUI involved:

```gdscript
# test/tooling script — same contract as every controller above
func replay(ability_component: GameplayAbilityComponent, recorded: Array) -> void:
	for entry in recorded:
		var tick: int = entry["tick"]
		var request: Dictionary = entry["request"]
		var result := ability_component.request_activation(request, tick)
		assert(result["status"]["code"] == entry["expected_status_code"])
```

Because `request_activation` takes an explicit `tick` and an explicit
`command_sequence` rather than reading any ambient clock or ambient input
state, this replay is exactly as deterministic as a live player's input —
there is no separate "test mode" the component needs to be put into.

## Feeding Ability Tasks and typed targeting

Long-running abilities keep the same dependency direction. A game-owned
adapter translates an ordinary `InputEvent`, CommonUI action, AI decision,
or replay record into one logical phase:

```gdscript
component.submit_logical_input(
    execution,
    task,
    &"action.rpg.confirm",
    GameplayAbilityComponent.LOGICAL_INPUT_CONFIRM,
    next_command_sequence(),
    prediction_key,
    authority_tick
)
```

An owning network client uses
`bridge.request_task_input_networked(...)`; the server still validates
owner, execution, task, expected phase, sequence, deadline, and rate.

Target selection follows the same pattern. Presentation creates a local
`GameplayTargetValue`, optionally asks a preview provider, then submits or
confirms it through the world coordinator (offline/server/AI/test) or
`request_target_command_networked` (owning client). The value is intent,
not proof: only the authority coordinator can return a valid
`GameplayValidatedTargetData` and use it in `apply_effect_batch()`.

This standalone mirror intentionally does not ship a CommonUI-specific
targeting adapter. A game-owned adapter can register logical confirm/cancel
actions, call the preview/submit/confirm/cancel methods above, and release its
action handles; ordinary `_input` code can call the same methods. The shipped
channel/charge/combo task example is
[`ga_channel_charge_combo_ability.gd`](../../../examples/gameplay_abilities/tasks/ga_channel_charge_combo_ability.gd).
See [`tasks.md`](tasks.md) and [`targeting.md`](targeting.md).

## Attaching `GameplayAbilityNetworkBridge` to the session harness

The addon's own bridge (`native/godot/gameplay_ability_network_bridge.h`)
never creates a `MultiplayerPeer`; it only ever reads
`Node::get_multiplayer()`, which resolves whatever branch-scoped
`MultiplayerAPI` the game already configured. The game-layer reference
harness for this is `examples/gameplay_abilities/net/ga_session_harness.gd`
(`GASessionHarness`; see `examples/gameplay_abilities/net/README.md` for
its full loopback/direct-IP/discovery contract, which this document does
not repeat). `GASessionHarness.branch_root` is the `Node` its
`session_ready` signal reports a configured `MultiplayerAPI` for
(`get_tree().set_multiplayer(api, branch_root.get_path())`, per that
file's own comment). A `GameplayAbilityNetworkBridge` — and the
`GameplayAbilityComponent` it targets via `component_path` — belong
**under** `branch_root`, exactly like any other networked node the game
attaches to that branch:

```gdscript
var harness := GASessionHarness.new()
add_child(harness)
harness.session_ready.connect(_on_session_ready)

func _on_session_ready(role: int, peer_id: int) -> void:
	var component := GameplayAbilityComponent.new()
	component.role = _role_for(role)  # map GASessionHarness.Role -> GameplayAbilityComponent.Role
	# ... set tag/attribute/effect/ability definitions, call component.configure() ...
	harness.branch_root.add_child(component)

	var world_coordinator := GameplayAbilityWorldCoordinator.new()
	# ... assign the same catalog/schemas, configure, register component ...
	harness.branch_root.add_child(world_coordinator)

	var bridge := GameplayAbilityNetworkBridge.new()
	harness.branch_root.add_child(bridge)
	bridge.component_path = bridge.get_path_to(component)
	bridge.world_coordinator_path = bridge.get_path_to(world_coordinator)
	# The bridge reads its role/authority from `component` and its transport
	# from `harness.branch_root`'s own configured MultiplayerAPI — it never
	# receives ENet-specific state from the harness at all.
```

`GASessionHarness.Role` (`OFFLINE`, `LISTEN_SERVER`, `DEDICATED_SERVER`,
`CLIENT`) and `GameplayAbilityComponent.Role`
(`ROLE_OFFLINE_AUTHORITY`, `ROLE_SERVER_AUTHORITY`, `ROLE_NETWORK_CLIENT`)
are two independently-named enums the game maps between explicitly — the
harness has no reference to `GameplayAbilityComponent` at all (by design;
see `examples/gameplay_abilities/net/README.md`'s "why the game owns the
peer"), so there is no automatic role inference to rely on. Once attached,
`GameplayAbilityNetworkBridge.request_activation_networked` is the
client-side counterpart of every example above: on `ROLE_NETWORK_CLIENT`
it encodes and sends an `ACTIVATION_COMMAND` RPC instead of calling the
local component directly, but the *caller-facing* request `Dictionary` is
identical to every `request_activation` call shown in Examples 1–4 (see
`api.md`).

## Why CommonUI is not a dependency, and why the reverse would be a cycle

CommonUI's own scope (from its documentation and verified by inspecting
`addons/common_ui/native/godot/common_ui_runtime.h`) is namespaced UI
*action routing*: registering a logical action name against a `Callable`,
input-context/priority/device-modality bookkeeping, and a screen/layer
stack. It has no concept of a gameplay tag, attribute, effect, ability, or
network role anywhere in its native core or its `runtime/*.gd` scripts —
confirmed by grepping `addons/common_ui/` for `gameplay_abilities` or
`GameplayAbility` (no matches).

The ability addon could not depend on CommonUI even if it wanted to,
without breaking its own non-goals:

- **Dedicated servers must run with no UI at all.** `native/godot/gameplay_ability_component.h`
  and `gameplay_ability_network_bridge.h` are usable on a headless
  `SERVER_AUTHORITY` process that never loads `CommonUIRuntime`'s
  autoload. If `GameplayAbilityComponent` depended on CommonUI classes,
  every dedicated-server export would need to bundle and initialize a UI
  input-routing runtime it never uses.
- **AI and replay must reach the identical contract with no input concept
  in play at all** (Examples 3 and 4 above) — a dependency on CommonUI
  would make "logical action routing" a mandatory hop even when nothing
  resembling an action is involved.
- **The reverse direction is the one that would actually cycle.** CommonUI
  is the more general, lower-level capability (it also drives, e.g.,
  `CommonButton`/`CommonDialog`, which have nothing to do with gameplay
  abilities). If CommonUI depended on `GameplayAbilityComponent` to, say,
  suspend routing while an ability channel is active, then a game using
  only CommonUI (no gameplay abilities at all) would be forced to compile
  and load the ability addon's native library anyway — and a future
  change to ability internals could break unrelated UI-only games. Making
  the ability addon the one-way dependent, never the dependency, is what
  keeps both addons independently usable.

CommonUI *may* still gate or suspend a gameplay action for UI reasons (a
paused menu should not let dash fire) — but that decision, too, lives in
the game-owned controller (Examples 1/2 above): the controller checks
whatever CommonUI/context state it needs *before* calling
`request_activation`. The ability addon never asks CommonUI anything.

## What this document does not cover

- The typed hook contract a bound ability's own behavior (as opposed to
  the *activation request* this document covers) is built through — see
  [`hooks.md`](hooks.md).
- The full signal/method/Dictionary reference for both Godot classes shown
  above — see [`api.md`](api.md).
- The reference ENet/LAN-discovery transport `GASessionHarness` wraps — see
  [`examples/gameplay_abilities/net/README.md`](../../../examples/gameplay_abilities/net/README.md).
- Ability Task semantics — see [`tasks.md`](tasks.md).
- Typed target providers, sessions, and batches — see
  [`targeting.md`](targeting.md).

`runtime/ga_network_policy_bridge.gd` (`GameplayNetworkPolicyBridge.apply()`)
reads a `GameplayNetworkPolicy` resource and calls the bridge's
hidden-identifier/relevant-peer/owner-view setters for the game in one
call: `GameplayNetworkPolicyBridge.apply(policy, bridge)`. It is a
one-way, one-time push — call it again after mutating the policy resource
for the change to take effect. A game may instead call
`GameplayAbilityNetworkBridge.set_hidden_attribute_identifiers`/
`set_hidden_tag_identifiers`/`set_hidden_ability_identifiers`/
`set_relevant_peers`/`set_owner_view` directly (see `api.md`), reading
whatever policy resource fields it wants by hand.
