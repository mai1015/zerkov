# Behavior Hooks: Authority-Only vs. Prediction-Safe

The typed hook contract behind design.md's "Constrained Behavior Hooks"
and "Owning-client prediction and reconciliation" sections: what a hook
may and may not do, the exact rejection diagnostics, the v1
prediction-safe operation set verbatim, and the subtle overflow-effect
case that a naive authoring-time check misses.

Everything in this document is implemented and tested at the
`native/core/` level. The examples below are still written as C++ (they
mirror the actual native tests, the only tested surface for the exact
capability rules), but the *typed GDScript* half of the requirement's
name — a game author writing a hook in a `.gd` file — is now wired up
too; see "GDScript exposure (task 6.10)" below for the Callable-based
adapter that exposes the identical contract to script.

## Two structurally distinct hook families, two variants each

| Family | Authority-only | Prediction-safe | Bound via |
|---|---|---|---|
| Ability execution (task 6.6) | `AuthorityAbilityHook` | `PredictionSafeAbilityHook` | `AbilityComponent::bind_authority_hook` / `bind_prediction_safe_hook` (`native/core/ga_ability_component.h`) |
| Effect calculation (task 5.7) | `AuthorityCalculationHook` | `PredictionSafeCalculationHook` | passed per-call to `EffectRuntime::apply` (`native/core/ga_effect_hooks.h`, `ga_effect_runtime.h`) |

Within each family, the authority-only and prediction-safe classes share
**no common base**:

```cpp
// native/core/ga_ability_component.h
class AuthorityAbilityHook {
public:
    virtual ~AuthorityAbilityHook() = default;
    virtual Status execute(const AbilityExecutionContext &, AbilityCommandBuilder &) = 0;
};

class PredictionSafeAbilityHook {
public:
    virtual ~PredictionSafeAbilityHook() = default;
    virtual Status execute(const AbilityExecutionContext &, AbilityCommandBuilder &) = 0;
    virtual bool depends_on_time() const { return false; }
    virtual bool depends_on_randomness() const { return false; }
    virtual bool depends_on_scene_or_physics() const { return false; }
    virtual bool uses_unrestricted_callback() const { return false; }
};
```

Neither declares the other as a base, and neither is registered through a
shared pointer type anywhere in the codebase — `AbilityComponent::authority_hooks`
is `std::map<DefinitionId, AuthorityAbilityHook *>` and
`prediction_hooks` is a *separate* `std::map<DefinitionId, PredictionSafeAbilityHook *>`.
Passing a `PredictionSafeAbilityHook*` where an `AuthorityAbilityHook*` is
expected (or vice versa) is a **compiler error**, not a runtime policy
check that a reviewer could miss. The calculation-hook pair pins this
exact property with a `static_assert` test:

```cpp
// native/tests/ga_test_effects.cpp — effect_hook_interfaces_are_structurally_distinct
static_assert(!std::is_convertible<StructuralProbeHook *, PredictionSafeCalculationHook *>::value, ...);
static_assert(!std::is_convertible<PredictionSafeCalculationHook *, AuthorityCalculationHook *>::value, ...);
```

The ability-hook pair has the identical structural property (no shared
base declared anywhere in `ga_ability_component.h`), but — unlike the
calculation-hook pair — this is not additionally pinned by its own
`static_assert` test in `ga_test_abilities.cpp`. The guarantee is the same
in kind; only the calculation-hook family has a dedicated regression test
proving it.

**Why they share no ancestor, in one sentence**: an author who writes a
`PredictionSafeAbilityHook` subclass has committed, at the type level, to
never doing anything an authority-only hook could get away with — there is
no cast, no virtual dispatch trick, and no runtime flag that lets a
prediction-safe hook instance later behave like an authority-only one.

## GDScript exposure (task 6.10)

`GameplayAbilityComponent.bind_authority_hook(ability_identifier: String,
callable: Callable) -> Dictionary` and
`GameplayAbilityComponent.bind_prediction_safe_hook(ability_identifier: String,
callable: Callable, depends_on_time := false, depends_on_randomness := false,
depends_on_scene_or_physics := false, uses_unrestricted_callback := false) ->
Dictionary` (`native/godot/gameplay_ability_component.h`/`.cpp`) bind a
GDScript `Callable` as a real `ga::AuthorityAbilityHook`/
`ga::PredictionSafeAbilityHook` instance
(`native/godot/gameplay_ability_hook_bridge.h`/`.cpp`:
`ScriptAuthorityAbilityHook`/`ScriptPredictionSafeAbilityHook` — two
separate classes with no shared base, matching the C++ pair's own
structural-separation property). Both delegate to the EXISTING
`AbilityComponent::bind_authority_hook`/`bind_prediction_safe_hook` calls
documented above unchanged, so every guarantee on this page — sticky
rejection, bind-time `validate_prediction_safe_hook` conformance, atomic
application through the normal `EffectRuntime`/`handle_gameplay_event`
path — holds identically for a script-authored hook.

The bound Callable is invoked as
`callable.call(context: Dictionary, builder: GameplayAbilityCommandBuilder) -> Variant`:
- `context` is an immutable Dictionary snapshot of `AbilityExecutionContext`
  (`GameplayAbilityComponent::ability_execution_context_dict`) — owner
  attributes/tags already resolved to identifier strings, targets,
  set-by-caller, and the triggering event if any. Never a live reference.
- `builder` wraps the SAME `ga::AbilityCommandBuilder&` the C++ interface
  receives (`native/godot/gameplay_ability_command_builder.h`/`.cpp`,
  `GameplayAbilityCommandBuilder`); `builder.submit(command: Dictionary) ->
  Dictionary{status}` accepts an `AbilityHookCommand`-shaped Dictionary and
  forwards it to the real `AbilityCommandBuilder::submit` unchanged. The
  wrapper is invalidated the instant the Callable returns, so a script that
  stashes the `Ref` and calls `submit` later gets a harmless
  `STATUS_HOOK_FAILED`, never a dangling access.
- The return value is interpreted narrowly: `Nil` -> success (a plain
  `func(...) -> void` hook "just works"); `bool` -> that value; anything
  else (including whatever a script that hit a runtime error leaves behind)
  -> `STATUS_HOOK_FAILED`, a bounded diagnostic code, never an unbounded
  string built from the value itself.

Calculation hooks (`AuthorityCalculationHook`/`PredictionSafeCalculationHook`)
were **not** given the same Callable adapter — every call site that ever
invokes `EffectRuntime::apply` with a hook argument lives inside
`AbilityComponent::commit_execution_body` (`native/core/ga_ability_component.cpp`,
off limits to this task) and hardcodes `nullptr` for it; there is no
per-ability "bind a calculation hook" registration API on `AbilityComponent`
for a Godot adapter to hook into, unlike the ability-hook pair. See this
addon's `docs/api.md` for the full rationale.

## Safe Ability Task continuation

Both GDScript bind methods accept an optional `task_callable` after the
ordinary execute callable. It runs only for an immutable terminal task event,
after the transition transaction and current notification batch:

```gdscript
component.bind_authority_hook(
    &"ability.rpg.channel",
    _on_execute,
    _on_task_terminal
)

func _on_execute(
        context: Dictionary,
        builder: GameplayAbilityCommandBuilder
    ) -> bool:
    var request := GameplayAbilityTaskRequest.new()
    request.kind = GameplayAbilityTaskRequest.KIND_WAIT_TICKS
    request.wait_ticks = 30
    return builder.request_task(request).status.ok

func _on_task_terminal(
        context: Dictionary,
        event: Dictionary,
        builder: GameplayAbilityCommandBuilder
    ) -> bool:
    # AbilityHookCommandKind::END_EXECUTION / CANCEL_EXECUTION.
    var command_kind := 6 if (
        event.outcome == GameplayAbilityComponent.TASK_COMPLETED
    ) else 7
    return builder.submit({"kind": command_kind}).status.ok
```

The callback receives a new capability-limited builder and cannot retain it.
It may queue another bounded task/command, but cannot synchronously recurse
into the transition being dispatched. Parent cleanup intentionally does not
invoke one callback per cancelled child. Snapshot restore likewise emits no
historical terminal callback; use `notify_restored_ability_tasks()` and
`ability_task_event` for presentation reconstruction. See
[`tasks.md`](tasks.md) for event shapes, prediction rules, logical input,
and the channel/charge/combo example.

## What an authority-only hook may and may not do

An `AuthorityAbilityHook::execute` receives an immutable
`AbilityExecutionContext` (owner attributes/tags as sorted snapshots,
this execution's `targets`, `set_by_caller`, and the triggering
`GameplayEventContext` if any) and an `AbilityCommandBuilder&`.

**May:**
- Consult validated game state through the context (`find_owner_attribute`,
  `owner_tags`, `targets`, `set_by_caller`, `event`) — a read-only,
  point-in-time snapshot, never a live reference.
- Submit any of the three documented commands via
  `AbilityCommandBuilder::submit`: `APPLY_SELF_EFFECT`, `APPLY_TARGET_EFFECT`
  (target must already be one of the context's own `targets`),
  `EMIT_GAMEPLAY_EVENT`.

**May not:**
- **Mutate native containers directly** — the hook is never given a
  reference to `AttributeSet`/`TagContainer`/`EffectRuntime`, only the
  read-only context and the command builder.
- **Inject an authority handle** — `AbilityHookCommand` has no handle
  field of any kind (`effect_definition`, `explicit_target`,
  `set_by_caller`, `event` only). A hook cannot fabricate an
  `EffectHandle`/`ExecutionId` even if it wanted to; there is no field to
  put one in.
- **Bypass effect requirements** — every accepted command re-enters
  through the *same* `EffectRuntime::apply`/`AbilityComponent::handle_gameplay_event`
  path any other caller uses (`ga_ability_component.cpp`,
  `commit_execution_body`'s command-application loop), inside the same
  atomic commit transaction, so requirement/immunity/stacking checks run
  identically regardless of who submitted the effect spec.

**Accepted example (self-target)** — `ability_authority_hook_applies_validated_effect_atomically`
(`native/tests/ga_test_abilities.cpp`): a `BurstHook : AuthorityAbilityHook`
submits `APPLY_TARGET_EFFECT` naming `world.effect_self_burst` against
`p_context.owner` (the only target a single-component test can validate
end-to-end without a second component). The activation succeeds and health
drops by exactly the effect's declared amount — the hook never touched
`attributes()` itself; the core applied it.

**Rejected example** — `ability_hook_capability_violation_state_unchanged`
(`native/tests/ga_test_abilities.cpp`): a `ViolatingHook : PredictionSafeAbilityHook`
submits `APPLY_TARGET_EFFECT` — never permitted from a prediction-safe
hook regardless of target validity. The activation fails with
`StatusCode::CAPABILITY_VIOLATION`, exactly one
`AbilityDiagnosticKind::CAPABILITY_VIOLATION_DETECTED` diagnostic fires,
and the owner's health is provably unchanged.

### A genuinely remote target (task 6.13)

`AbilityComponent` only ever owns ONE entity's containers. When a hook
submits `APPLY_TARGET_EFFECT` naming an `explicit_target` that is NOT
`p_context.owner`, the command is still validated and accepted (the
activation itself succeeds) but this component cannot apply it — that
boundary is correct, not a bug. Instead of the pre-6.13 behavior (silently
discarded, no error, no diagnostic), the core now surfaces it as an
ordered `ga::PendingRemoteEffectCommand` on
`ActivationResult::pending_remote_effects` (or `commit_activation`'s
optional out-param for the explicit-commit path). The caller — the
network/game layer, which knows how to resolve an `EntityId` to a real
component — applies it via `ga::AbilityComponent::apply_remote_effect`,
called ON the TARGET's own component, through that component's own normal
validated `EffectRuntime::apply` (Godot layer:
`GameplayAbilityComponent.apply_pending_remote_effect`). This is a
SEPARATE, independently atomic transaction scoped to the target component
only — this addon's `Transaction` type is single-component by design, so
cross-component atomicity with the originating commit is not attempted or
claimed; see `apply_remote_effect`'s own doc comment
(`native/core/ga_ability_component.h`) for exactly what IS guaranteed.
`apply_remote_effect` is authority-only regardless of the command's own
recorded `provenance` field (a remote-target effect is never predicted --
task 8.4 keeps remote-target effects server-only), so a `ROLE_NETWORK_CLIENT`
target component structurally cannot be driven through this path.

Every existing guarantee above still holds for the remote case: no handle
field exists on the command to inject an authority handle, and
`apply_remote_effect` re-enters the identical `EffectRuntime::apply` path,
so requirement/immunity/stacking checks run exactly as they would for any
other caller — now evaluated against the REAL target's state, not
skipped.

**Accepted example (remote target)** —
`ability_authority_hook_remote_target_surfaced_not_applied_locally` and
`ability_apply_remote_effect_applies_on_target_component_only`
(`native/tests/ga_test_abilities.cpp`): the same `RemoteBurstHook` submits
`APPLY_TARGET_EFFECT` naming a SECOND, separately-constructed
`AbilityComponent`'s entity id. The originating component's own state is
proven untouched, `pending_remote_effects` carries exactly the accepted
command, and applying it via `apply_remote_effect` on the target component
mutates only that component. `ability_apply_remote_effect_rejects_network_client_target`
and `ability_apply_remote_effect_rejects_mismatched_target_component` prove
the authority-only and target-identity guarantees.

### The rejection is sticky — a hook cannot swallow its own failure

```cpp
// native/core/ga_ability_component.cpp
Status AbilityCommandBuilder::submit(const AbilityHookCommand &p_command) {
    if (!violation.ok()) {
        return violation; // sticky -- a hook cannot "retry past" a rejection
    }
    ...
}
```

and the caller checks it unconditionally after `execute()` returns,
regardless of what `execute()` itself returned:

```cpp
// A rejected submission is checked UNCONDITIONALLY, regardless of
// what the hook itself returned.
if (!builder.violation_status().ok()) {
    emit_diagnostic(AbilityDiagnosticKind::CAPABILITY_VIOLATION_DETECTED, ...);
    p_txn.fail(builder.violation_status());
    return builder.violation_status();
}
```

`ViolatingHook.execute` deliberately ignores `submit`'s own return value
and returns `ok_status()` anyway (see the test's comment: "Even if the
hook ignores the rejection and returns OK, the core checks the builder's
sticky violation status itself.") — the commit still fails, because
`AbilityCommandBuilder::violation`, once set, never clears and blocks
every subsequent `submit` call from recording anything further.

## What a prediction-safe hook additionally requires

Beyond everything above, a `PredictionSafeAbilityHook`:

- **Must be a pure function of `AbilityExecutionContext` alone** — no wall
  clock, no RNG, no scene/physics query, no unrestricted callback. The
  four virtual `depends_on_*`/`uses_unrestricted_callback` methods default
  to `false`; an author who overrides one to `true` is *honestly
  declaring* a disqualifying dependency, not something the framework
  detects by inspection.
- **May submit only `APPLY_SELF_EFFECT`**, naming an effect that is
  *itself* `prediction_safe == true` **and** `has_period == false` —
  checked structurally inside `AbilityCommandBuilder::submit`'s
  `prediction_safe_mode` branch, not left to the hook author's judgment.

Two separate enforcement points exist, and each catches a different
mistake:

1. **Bind-time conformance** (`validate_prediction_safe_hook`, run by
   `AbilityComponent::bind_prediction_safe_hook`) — catches an *honestly
   declared* unsafe dependency before the hook is ever installed.
2. **Execute-time command validation** (`AbilityCommandBuilder::submit`) —
   catches an *attempted operation* outside the permitted kind, even from
   a hook that declared itself pure.

**Accepted example (bind-time + execute-time)** —
`ability_prediction_safe_hook_nondeterministic_rejected_at_bind`
(`native/tests/ga_test_abilities.cpp:1207`)'s `SafeHook`: submits
`APPLY_SELF_EFFECT` naming `world.effect_self_burst`. Binds successfully
and, once granted and activated, applies the effect.

**Rejected example (bind-time)** — the same test's `RandomHook`:
overrides `depends_on_randomness() -> true` and does nothing else unsafe.
`bind_prediction_safe_hook` returns `StatusCode::PREDICTION_NOT_SAFE`
before the hook is ever installed — it is rejected purely on its declared
capability, before `execute` is ever called.

**Rejected example (execute-time)** — `ViolatingHook` above doubles as
this case: it declares no unsafe capability (so it *passes* bind-time
conformance) but attempts `APPLY_TARGET_EFFECT` when actually invoked,
which `AbilityCommandBuilder::submit`'s `prediction_safe_mode` branch
refuses with the identical `CAPABILITY_VIOLATION` shown above.

## Effect calculation hooks

Same two-tier shape, one level down (a resolved `Fixed` magnitude rather
than a set of ability-level commands).

```cpp
// native/core/ga_effect_hooks.h
class AuthorityCalculationHook {
public:
    virtual ~AuthorityCalculationHook() = default;
    virtual Status calculate(const CalculationContext &, Fixed &r_out) = 0;
};
class PredictionSafeCalculationHook {
public:
    virtual ~PredictionSafeCalculationHook() = default;
    virtual Status calculate(const CalculationContext &, Fixed &r_out) = 0;
    virtual bool depends_on_time() const { return false; }
    virtual bool depends_on_randomness() const { return false; }
    virtual bool depends_on_scene_or_physics() const { return false; }
    virtual bool uses_unrestricted_callback() const { return false; }
};
```

An `AuthorityCalculationHook` is passed *per-call* to `EffectRuntime::apply`
(not bound persistently like an ability hook) and receives a
`CalculationContext` (source/target attribute snapshots, set-by-caller
values, level, tick) — again, value data, never a live container
reference.

**Accepted example** — `effect_authority_hook_success_records_result_on_lifecycle_event`
(`native/tests/ga_test_effects.cpp:1458`): the hook returns `Fixed::from_int(42)`;
the resolved value is recorded on the authoritative `EffectLifecycleEvent`
(`has_hook_result = true`, `hook_result = 42`) — precisely so a client
never recomputes this locally, only replicates the recorded number.

**Rejected example** — `effect_authority_hook_failure_leaves_nothing`
(`native/tests/ga_test_effects.cpp:1417`): the hook returns
`StatusCode::INVALID_ARGUMENT`. The whole effect application fails with
`StatusCode::HOOK_FAILED`; the handle is invalid, `active_count() == 0`,
no modifier and no tag were applied, and the target's health is
unchanged — nothing the hook would have produced survives a failure.

**Prediction-safe conformance** — `validate_prediction_safe` (`native/core/ga_effect_hooks.cpp`)
ORs every offending capability into `Status::detail` rather than stopping
at the first one, so a single diagnostic names every violation at once:

- `effect_prediction_safe_conformance_accepts_pure_hook` — a hook
  declaring nothing unsafe passes.
- `effect_prediction_safe_conformance_rejects_time_dependence` —
  `detail == PREDICTION_UNSAFE_TIME` alone.
- `effect_prediction_safe_conformance_names_every_offending_capability` —
  a hook declaring both randomness and scene/physics dependence yields
  `detail == PREDICTION_UNSAFE_RANDOMNESS | PREDICTION_UNSAFE_SCENE_OR_PHYSICS`.

This "name every offense at once" behavior is specific to
`validate_prediction_safe`/`validate_prediction_safe_hook`; the
ability-level `validate_prediction_eligibility` below instead fails
closed on the **first** violation it finds, in a fixed check order — the
two functions answer different questions (this hook's own conformance,
versus this whole ability definition's eligibility) and are not expected
to behave identically.

## The v1 prediction-safe operation set, verbatim

From design.md, "Owning-client prediction and reconciliation":

- Transitioning the local execution through declared activation phases.
- Applying declared self-target instant costs.
- Applying declared self-target cooldown and owned-tag effects.
- Applying explicitly prediction-safe self effects whose magnitudes depend
  only on confirmed component state and command inputs.
- Emitting reversible, deduplicated local presentation events.

This maps one-to-one onto `PredictedOpKind` (`native/core/ga_prediction.h`) —
"there is no fifth kind, by construction (see `PredictingComponent::predict_full`,
the only place that ever calls `record_op`)":

| `PredictedOpKind` | Spec bullet |
|---|---|
| `ACTIVATION_BEGUN` | local execution transitions through its declared activation phases |
| `SELF_COST_APPLIED` | declared self-target instant cost effect applied |
| `SELF_COOLDOWN_APPLIED` | declared self-target cooldown/owned-tag effect applied |
| `SELF_EFFECT_APPLIED` | an explicitly prediction-safe self commit effect applied |

(Presentation-event deduplication — the fifth spec bullet — is a property
of `PredictionPresentationEvent`/`CueDedupId`, not a fifth journaled
operation kind.)

**What stays server-only**, also verbatim: remote-target mutations,
periodic ticks, random outcomes, authority-only hooks, scene queries,
physics queries, and unbounded custom payloads.

## `validate_prediction_eligibility` and the overflow-effect subtlety

Two different, deliberately non-identical checks exist for "is this
ability prediction-safe":

1. **`AbilityRegistry::register_ability`'s own inline check**
   (`check_effect_prediction_safe` in `ga_abilities.cpp`), run only when
   `prediction_policy == PREDICTABLE`: authority-only hook binding is
   rejected; the cost/cooldown/each commit effect must individually have
   `prediction_safe == true` and `has_period == false`. This runs at
   *content-registration* time and can never fail once content is sealed.
2. **`ga::validate_prediction_eligibility`** (`native/core/ga_prediction.h`/`.cpp`) —
   the same four checks, **plus** a fifth: if a checked effect declares
   `StackOverflowPolicy::APPLY_OVERFLOW_EFFECT`, its `overflow_effect` must
   *also* pass the prediction-safe/no-period check (bounded to exactly one
   recursion level, matching `EffectRuntime::apply_internal`'s own
   single-hop overflow guard — an overflow effect can never itself
   overflow). This is the check a prediction *system* actually calls
   (`PredictingComponent::request`) and the one an authoring-time/CI
   validator should call — **not** the registry's own weaker inline check.

```cpp
// native/core/ga_prediction.cpp
Status check_effect_prediction_safe(DefinitionId p_effect_id, const EffectRegistry &p_effects, bool p_check_overflow) {
    ...
    if (!definition->prediction_safe || definition->has_period) {
        return make_status(StatusCode::PREDICTION_NOT_SAFE, DiagnosticId::HOOK_CAPABILITY_DENIED, p_effect_id);
    }
    if (p_check_overflow && definition->stacking.overflow_policy == StackOverflowPolicy::APPLY_OVERFLOW_EFFECT &&
            definition->stacking.has_overflow_effect) {
        return check_effect_prediction_safe(definition->stacking.overflow_effect, p_effects, false);
    }
    return ok_status();
}
```

**The subtle case, exactly as `native/tests/ga_test_prediction.cpp` builds
it** (`predict_eligibility_rejects_unsafe_overflow_effect_chain`, line
352): `effect.overflow_source` is a `DURATION` effect, `prediction_safe = true`,
`stackable = true`, `max_stacks = 1`, `overflow_policy = APPLY_OVERFLOW_EFFECT`,
`overflow_effect = "effect.periodic_unsafe"`. Looked at alone, it passes
every check — `prediction_safe` is true and it has no period of its own.
But `effect.periodic_unsafe` — the effect it overflows into — is a
`DURATION` effect with `has_period = true` (period 5 ticks), *despite also
being authored with `prediction_safe = true`*: a periodic outcome is never
predictable regardless of its own `prediction_safe` flag. An ability,
`ability.unsafe_overflow_cooldown`, declares `effect.overflow_source` as
its `cooldown_effect` and marks itself `prediction_policy = PREDICTABLE`.

- `AbilityRegistry::register_ability` **accepts it** — its inline check
  only inspects `effect.overflow_source` itself
  (`prediction_safe && !has_period` both hold), never follows the
  `overflow_effect` reference. The test asserts this directly:
  `GA_EXPECT(ability != nullptr); // registered successfully -- the
  registry's own check missed this.`
- `ga::validate_prediction_eligibility` **rejects it**, with
  `StatusCode::PREDICTION_NOT_SAFE` and `detail` equal to
  `effect.periodic_unsafe`'s own `DefinitionId` — the exact effect that
  would otherwise smuggle a periodic outcome into predicted execution.

**Practical guidance**: never treat a successful `register_ability` call
as proof an ability is actually prediction-safe. Call
`ga::validate_prediction_eligibility` explicitly — the Godot-layer seam
for this is `GameplayDefinitionValidator::validate_prediction_eligibility_seam`
(`native/godot/gameplay_definition_validator.h`), which wires this exact
function in and is documented as deliberately **not** called by
`GameplayDefinitionValidator::validate()` (abilities are a separate
authoring set from tags/attributes/effects/cues today — see
[`authoring.md`](authoring.md)). Call it explicitly for any ability set
containing a `PREDICTION_PREDICTABLE` definition.

## Paired examples and their proving tests

| Rule | Accepted | Rejected |
|---|---|---|
| Authority hook applies a validated command through the normal path, never a direct mutation | `ability_authority_hook_applies_validated_effect_atomically` | `ability_hook_capability_violation_state_unchanged` |
| Prediction-safe hook may submit only a safe, non-periodic self effect | `ability_prediction_safe_hook_nondeterministic_rejected_at_bind` (`SafeHook`) | same test (`RandomHook`, rejected at bind) and `ability_hook_capability_violation_state_unchanged` (rejected at execute) |
| Authority-only structural separation from prediction-safe (ability hooks) | header declares no shared base (`ga_ability_component.h`) | n/a — a violation would be a compile error |
| Authority-only structural separation from prediction-safe (calculation hooks) | `effect_hook_interfaces_are_structurally_distinct` + its `static_assert`s | n/a — a violation would be a compile error |
| Authority calculation hook resolves and records a magnitude once | `effect_authority_hook_success_records_result_on_lifecycle_event` | `effect_authority_hook_failure_leaves_nothing` |
| Prediction-safe calculation hook must be a pure function | `effect_prediction_safe_conformance_accepts_pure_hook` | `effect_prediction_safe_conformance_rejects_time_dependence`, `_names_every_offending_capability` |
| Ability-level declarative eligibility (registry inline check) | `predict_eligibility_accepts_dash` | `ability_definition_prediction_declaration_unsafe_rejected` (registration itself fails: authority-only hook, periodic cost, unsafe cooldown/commit effect) |
| Ability-level declarative eligibility (`validate_prediction_eligibility`, stricter) | `predict_eligibility_accepts_dash` | `predict_eligibility_rejects_not_declared_predictable`, `_rejects_authority_only_hook`, `_rejects_periodic_cost_effect`, `_rejects_non_prediction_safe_cooldown_effect`, `_rejects_non_prediction_safe_commit_effect` |
| Overflow-chain subtlety (registry misses it, `validate_prediction_eligibility` catches it) | n/a — the whole point is that the registry wrongly accepts this case | `predict_eligibility_rejects_unsafe_overflow_effect_chain` |

## See also

- [`integration.md`](integration.md) — the activation-request contract
  these hooks execute *inside of*; hooks never see input.
- [`api.md`](api.md) — the full `GameplayAbilityComponent`/
  `GameplayAbilityNetworkBridge` signal and method reference.
- [`authoring.md`](authoring.md) — declaring `prediction_safe`/`has_period`
  on `GameplayEffectDefinition` and `prediction_policy`/`hook_binding` on
  the ability definition shape, and running the editor validator.
