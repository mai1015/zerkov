# Resource Authoring Guide

How to define tags, attributes, effects, abilities, cues, target schemas,
and network policy as editor-visible `.tres` resources; the identifier
rule every one of them shares; how authored decimals become authoritative
fixed-point values; how definitions feed the content manifest and
therefore multiplayer compatibility; and how to run the editor validator
before shipping.

Every class below is pure data (`native/resources/*.h`) — none of them
validate, resolve references, or intern identifiers themselves. All of
that happens in `GameplayDefinitionValidator` (editor-time,
`native/godot/gameplay_definition_validator.h`) or
`GameplayAbilityComponent::configure()` (session-start, `native/godot/gameplay_ability_component.cpp`),
which run the *exact same* core registries (`ga::TagRegistry`,
`ga::AttributeRegistry`, `ga::EffectRegistry`, `ga::AbilityRegistry`) a
running session enforces — so authoring-time validation can never drift
from runtime behavior. See [`api.md`](api.md) for every resource class's
complete property list; this document is the workflow.

## The identifier rule — read this before authoring your first tag

Every namespaced identifier in this addon — tag, attribute, effect,
ability, cue, target-data schema — must satisfy (`native/core/ga_identifier.h`,
`ga::validate_identifier`, the single implementation everyone calls):

```
identifier = segment ('.' segment)+          -- at least TWO segments
segment    = [a-z][a-z0-9_]*
```

Total length ≤ 128 bytes (`MAX_IDENTIFIER_BYTES`), ≤ 8 segments
(`MAX_IDENTIFIER_SEGMENTS`).

**A bare, single-segment name is never valid.** `"stance"` fails with
`DiagnosticId::IDENTIFIER_NOT_NAMESPACED` — it has one segment, not two.
This has already tripped up test authoring in this very codebase: several
early tag fixtures reached for a bare root word before discovering it
cannot register at all. Always author at least two segments:
`stance.aggressive`, not `stance`; `attribute.vitals.health`, not
`health`; `ability.dash`, not `dash`. If you want a "bare-word-looking"
concept, its shortest **valid** form is still two segments — treat the
bare word as informal shorthand only, never the actual identifier.

This rule applies identically to every identifier field on every resource
class in this document: `GameplayTagDefinition.identifier`,
`GameplayAttributeDefinition.identifier`, `GameplayEffectDefinition.identifier`,
`GameplayAbilityDefinition.identifier`/the `identifier` key of an ability
Dictionary, `GameplayCueDefinition.identifier`,
`GameplayTargetDataSchema.identifier`, and
`GameplayTagReactionDefinition.identifier` (see "Defining a tag reaction"
below). The editor validator (below) rejects any violation before a
session can start.

## The project definition catalog: identity vs. runtime state

Every definition kind below (tags, attributes, effects, abilities, cues,
target schemas, and tag reactions) is **global identity**: one canonical,
project-wide description of what `state.control.stunned` or
`effect.dash_cost` *means*. None of that identity is itself gameplay
state. A `GameplayAbilityComponent` never shares a runtime tag container,
attribute set, effect list, or ability grant list with any other
component — "global tags" names a shared *catalog entry*, never a shared
*owned count*. Two components configured from the identical catalog each
build their own sealed native registries and start with every tag absent,
every attribute uninitialized, and no grants — see
`specs/gameplay-tags/spec.md`'s "Global Tag Identity and Component-Scoped
Ownership": registering a tag globally never grants it to anyone.

`GameplayDefinitionCatalog` (`native/resources/gameplay_definition_catalog.h`)
is the Resource that carries this identity: seven typed collections —
`tag_definitions`, `attribute_definitions`, `effect_definitions`,
`ability_definitions` (here, unlike the component's own legacy property, a
strictly-typed `Array[GameplayAbilityDefinition]` — see "Defining an
ability" above; the catalog has no Dictionary form), `cue_definitions`,
`target_data_schemas`, and `tag_reactions` (`Array[GameplayTagReactionDefinition]`,
see "Defining a tag reaction" below). The catalog itself owns no runtime
registry, tag container, or mutable gameplay state of any kind — it is
pure data, validated the same way every other resource in this document
is validated, then read once by each component's own `configure()`.

### Catalog setup: project setting, component override, and precedence

`GameplayAbilityComponent.configure()` resolves at most one catalog, in
this fixed order:

1. **This component's own `definition_catalog` property**, if it is a
   valid `Ref<GameplayDefinitionCatalog>`. Set it directly in the editor
   Inspector or from a test/tool script before calling `configure()`.
   This is the override a native/GDScript test, an editor preview, an
   independently configured simulation world, or a project that
   deliberately partitions content (e.g. one catalog per game mode) uses.
2. Otherwise, the **project setting**
   `gameplay_abilities/default_definition_catalog` — a `String` resource
   path, registered by the native module with a file-picker hint
   restricted to `*.tres`/`*.res` (Project Settings dialog: **Gameplay
   Abilities > Default Definition Catalog**). This is what an ordinary
   scene with no per-component override resolves against, and what most
   projects should set once, near the start of content authoring.
3. Otherwise, **no catalog** — the component falls back to its own
   legacy definition arrays (next section).

Only whichever source resolves supplies every collection; a catalog is
never merged with another catalog, and never merged with legacy arrays
(next section). `configure()` records which source resolved as an
`"info"`-severity `catalog_resolved` finding (`Configured from an explicit
component override: '<path>'.` or `Configured from the project default
(gameplay_abilities/default_definition_catalog): '<path>'.`) so a test or
a diagnostic overlay can assert exactly which catalog a session actually
used.

### Legacy migration path

Pre-1.0, a component with **no resolved catalog** — neither an explicit
override nor a project default — continues to configure from its own
`tag_definitions`/`attribute_definitions`/`effect_definitions`/
`cue_definitions`/`ability_definitions`/`target_data_schemas` arrays
exactly as before this change. Opening an old scene never rewrites it:
nothing migrates until an author explicitly runs the dashboard's
**Migration** tab (see `editor_workflows.md`'s "Running migration"
walkthrough) and accepts its preview.

### Mixed catalog/legacy configuration is rejected, not merged

If a catalog resolves (override or project default) **and** any legacy
array on that same component is non-empty, `configure()` fails outright,
before touching a single registry:

- one `"error"`-severity `catalog_legacy_conflict` finding per populated
  legacy field (`field` is the exact property name —
  `tag_definitions`, `attribute_definitions`, `effect_definitions`,
  `cue_definitions`, `ability_definitions`, or `target_data_schemas`),
  each stating how many entries that field has;
- nothing is registered — there is no partial seal, and no
  order-dependent "catalog wins" or "legacy array wins" merge, because
  which one *should* win depends on authoring/registration order this
  addon deliberately does not define (design.md decision 1).

The fix is always explicit: either clear the legacy arrays (accept a
migration, or delete them by hand) or clear `definition_catalog` and the
project setting — never both populated at once.

### Validation failure catalog

Two validation passes exist, and they do **not** check the same things —
this trips people up specifically for tag reactions, see the callout
below.

**1. `GameplayDefinitionValidator.validate_catalog(catalog)`** — what the
dashboard's **Validate Catalog** button and
`GameplayDefinitionValidation.validate_catalog_resource()` run. Checks,
per collection, in this order (later collections are skipped with one
`internal_error` finding if an earlier one fails to seal, since later
kinds may reference it): tags → attributes → cues → effects → target
schemas → abilities → **tag reactions**. For tag reactions specifically,
this pass only checks **identifier well-formedness and per-catalog
uniqueness** — it does *not* resolve a reaction's operand tag or target
effect, does not run `WHILE_PRESENT` lifetime validation, and does not
run cycle detection. See the callout below.

**2. `GameplayAbilityComponent.configure()`** — runs *after* a clean
`validate_catalog()` pass, and additionally builds and seals the real
`ga::TagReactionRegistry` from the catalog's `tag_reactions` collection.
This is the pass that actually resolves each reaction's operand tag and
target effect, checks `WHILE_PRESENT` lifetime, and runs static cycle
detection (see `reactions.md`'s "Validation and cycle safety"). **A
catalog can pass `validate_catalog()`/the dashboard's "Validate Catalog"
button cleanly and still fail at the first `configure()` call** if a
reaction names an unknown effect, targets a non-infinite effect from
`WHILE_PRESENT`, or forms a cycle. Always exercise a real `configure()`
call (a headless test scene, or the example's own automated check) before
shipping catalog content that authors tag reactions — the dashboard alone
is not sufficient proof.

| `code` | Where | Severity | Meaning |
|---|---|---|---|
| `null_resource` | either pass | error | `definition_catalog` itself is null, or one array slot (e.g. `tag_definitions[2]`) is an empty/freed reference |
| `identifier_not_namespaced` / `identifier_bad_character` / `identifier_too_long` / `identifier_too_many_segments` / `identifier_empty_segment` | either pass | error | lowercased `ga::DiagnosticId` names — the identifier rule violation named in "The identifier rule" above, for any definition kind including a tag reaction's own `identifier` |
| `duplicate_definition` | either pass | error | an identifier (tag, attribute, effect, ability, cue, target schema, or reaction) is declared more than once in the same catalog |
| `overflow_effect_cycle` | `validate_catalog` | error | an effect's `stacking.overflow_effect` chain loops back to itself (unrelated to tag-reaction cycles — see `reaction_cycle` below) |
| `count_limit_exceeded` / `byte_limit_exceeded` / `invalid_argument` | `validate_catalog` | error | a target schema's kind, dimension, quantization, cardinality, payload, session, deadline, provider-work, or prediction contract violates global bounds |
| `internal_error` | `validate_catalog` | error | an earlier collection (tags, attributes, or effects) failed to seal, so a later dependent collection was skipped rather than validated against a broken registry |
| `catalog_load_failed` | `configure()` | error | the project default catalog path failed to load, or the loaded resource is not a `GameplayDefinitionCatalog` |
| `catalog_legacy_conflict` | `configure()` | error | see "Mixed catalog/legacy configuration is rejected" above |
| `catalog_resolved` | `configure()` | **info** — not a failure | records which source (override or project default) actually resolved |
| `reaction_registration_failed` | `configure()` | error | `tag_reactions[i]` names an unknown operand tag or unknown target effect, or (for `WHILE_PRESENT`) targets an effect whose `duration_policy` is not `INFINITE` |
| `reaction_cycle` | `configure()` | error | static cycle detection (`reactions.md`'s "Static cycle rejection") found a reaction chain that can re-trigger a predicate already on the chain, including a length-one self-loop |
| `seal_failed` | `configure()` | error | the reaction registry failed to seal for a reason other than a cycle (unreachable in practice once registration above already succeeded) |
| `already_configured` | `configure()` | error | `configure()` was already called once on this component; every definition (catalog or legacy) is immutable for the session |

## Defining a tag

```gdscript
# res://my_game/tags/state_control_stunned.tres — GameplayTagDefinition
identifier = &"state.control.stunned"
description = "Blocks movement and most action abilities."
source_label = ""  # falls back to this resource's own path in diagnostics
```

Tags are validated hierarchically by dotted prefix: `state.control.stunned`
is a descendant of `state.control` and `state`, so a parent-aware query
against `state.control` matches it. There is no separate "parent tag"
resource to author — the hierarchy is derived entirely from the dotted
identifier string.

## Defining an attribute

```gdscript
# res://my_game/attributes/vitals_stamina.tres — GameplayAttributeDefinition
identifier = &"attribute.vitals.stamina"
default_base = 100.0
has_min = true
min_value = 0.0
has_max = true
max_value = 100.0
display_name = "Stamina"
```

`min_value`/`max_value` are hidden in the inspector unless their
respective `has_min`/`has_max` toggle is on (`_validate_property`) — this
is authoring-time inspector convenience only; the actual bound enforcement
happens in the core `AttributeSet`.

## Quantization of authored decimals

`default_base`, `min_value`, `max_value`, `GameplayMagnitude.coefficient`,
and every other authored decimal field are plain `double`s on the
resource — the *only* place a `double` is allowed to become authoritative
state is `ga::fixed_quantize` (`native/core/ga_fixed.h`), which:

- rounds half away from zero (identically for positive and negative
  values, on every platform),
- rejects `NaN`, `±infinity`, and any magnitude outside the representable
  `int64` raw range with `DiagnosticId::VALUE_NOT_REPRESENTABLE`,
- never goes through locale-sensitive string formatting/parsing.

`GameplayDefinitionValidator` is the only code that calls `fixed_quantize`
on an authored resource's decimal fields; `GameplayAbilityComponent::configure()`/
`initialize_attribute()` call it again for attribute base overrides
supplied at runtime. The quantized *integer* — not the original decimal —
is what enters the content manifest fingerprint, so two builds authored
with `100.0` versus `100.00000001` (which quantize to the same fixed-point
value) still agree, while a genuine value difference still changes the
fingerprint. See `protocol.md`'s "Fixed-point representation" section for
the complete rounding/overflow contract; this document does not repeat it.

## Defining an effect

```gdscript
# res://my_game/effects/dash_cost.tres — GameplayEffectDefinition
identifier = &"effect.dash_cost"
duration_policy = GameplayEffectDefinition.DURATION_INSTANT
var modifier := GameplayModifierDeclaration.new()
modifier.target_attribute = &"attribute.vitals.stamina"
modifier.op = GameplayModifierDeclaration.OP_ADD
var magnitude := GameplayMagnitude.new()
magnitude.kind = GameplayMagnitude.KIND_CONSTANT
magnitude.coefficient = -20.0
modifier.magnitude = magnitude
modifiers = [modifier]
prediction_safe = true
```

A periodic (damage-over-time) effect additionally sets `has_period = true`
and `period_ticks` (only meaningful once `has_period` is on — hidden
otherwise). A stacking effect sets its `stacking` property to a
`GameplayStackingPolicy` (see `api.md` for every field); `overflow_effect`
is only permitted non-empty when `overflow_policy == OVERFLOW_APPLY_EFFECT`,
and **its own prediction-safety is checked independently of the effect it
overflows from** — see [`hooks.md`](hooks.md)'s overflow-chain subtlety
before marking a stacking effect `prediction_safe`.

`source_requirements`/`target_requirements`/`immunity` each take a
`GameplayTagQueryResource` (`all_of`/`any_of`/`none_of` lists of
`GameplayTagOperand`, each either an exact or parent-aware match). Every
tag named in any of these must already be a registered
`GameplayTagDefinition` in the same validated set.

`cue_identifiers` names zero or more `GameplayCueDefinition` identifiers —
each must already be registered in the same validated set (the validator
registers cues before effects, precisely so this reference always
resolves).

## Defining a cue

```gdscript
# res://my_game/cues/dash_cast.tres — GameplayCueDefinition
identifier = &"cue.dash_cast"
display_name = "Dash Cast"
category = &"vfx"
```

A cue is a stable, logical identity only — no VFX/audio/animation
reference, no scene node. A game's own presentation adapter switches on
`identifier`/`category` to decide what to actually play; see
`design.md`'s "Godot resource, scene, and presentation boundary" and
`integration.md`'s diagram (`effect_cue_triggered`/`cue_received` signals
carry `cue_identifiers`, never a resource path).

## Defining an ability

`GameplayAbilityComponent.set_ability_definitions` accepts an `Array`
whose entries are **either** a `GameplayAbilityDefinition` resource
directly **or** a plain `Dictionary` shaped exactly like
`ga::AbilityDefinitionDesc` — or a mix of both
(`configure()` classifies each entry per-element; see
`native/godot/gameplay_ability_component.cpp`'s ability-registration
loop). Author `.tres` ability resources like every other definition kind
and pass them straight in. The converter
`runtime/ga_ability_definition_bridge.gd`
(`GameplayAbilityDefinitionBridge.to_dictionary_array()` /
`to_dictionary()`) remains available for callers that want the
Dictionary shape explicitly (e.g. to tweak fields at runtime before
`configure()`), but it is no longer required. The literal Dictionary
form is still fully supported:

```gdscript
var dash := {
	"identifier": "ability.dash",
	"activation_policy": 0,  # ACTIVATION_MANUAL
	"owned_tags": PackedStringArray(["state.buff.dashing"]),
	"cost_effect": "effect.dash_cost",
	"cooldown_effect": "effect.dash_cooldown",
	"prediction_policy": 1,  # PREDICTION_PREDICTABLE
	"prediction_safe_declared": true,
	"auto_commit": true,
	"ends_on_commit": true,
}
component.set_ability_definitions([dash])
```

See `api.md`'s "Ability definitions array entries" for the complete
Dictionary shape (every key, every enum's integer values) and
`hooks.md`'s "The v1 prediction-safe operation set" before marking any
ability `prediction_policy = PREDICTION_PREDICTABLE`.

## Defining a target-data schema

```gdscript
# res://my_game/schemas/heal_single_target.tres — GameplayTargetDataSchema
identifier = &"schema.heal_single_target"
schema_version = 1
intent_kind = GameplayTargetDataSchema.VALUE_ENTITY_SET
result_kind = GameplayTargetDataSchema.VALUE_ENTITY_SET
spatial_dimension = GameplayTargetDataSchema.DIMENSION_NONE
min_entities = 1
max_entities = 1
max_payload_bytes = 64
authority_provider = &"target_provider.direct_entity"
provider_contract_version = 1
session_mode = GameplayTargetDataSchema.SESSION_INSTANT
acceptance_policy = GameplayTargetDataSchema.ACCEPT_REQUIRE_ALL
```

A schema does nothing on its own — an **ability** opts into it by naming
it: set the `target_schema` property on a `GameplayAbilityDefinition`
resource, or the `"target_schema"` key of an ability Dictionary, to the
schema's identifier. `configure()` resolves the association (an unknown
schema identifier is a configure-time error, `unknown_target_schema`)
and the typed coordinator enforces it at every entry point:

- **Direct/offline, gameplay event, AI, and tests** call the coordinator's
  corresponding `resolve_*` entry point and share one normalization/provider
  path.
- **Networked clients** send typed intent through
  `request_target_command_networked`; authority validates owner/session/
  schema/version/kind/sequences/deadline/rate/quantization/provider result.
- **Legacy entity-list activation** remains available through the explicit
  registered `ENTITY_SET` adapter; `max_targets` is a compatibility alias
  for `max_entities`, not the preferred authoring field.

Violations return bounded typed-target status/diagnostic codes before
provider work or gameplay mutation. `GameplayDefinitionValidator` checks
every behavior-affecting field and folds it into the content manifest
canonical bytes, so provider identity/version or a policy/precision change
also prevents an incompatible multiplayer session.

Spatial schemas must choose 2D or 3D and explicitly author coordinate space,
scale, precision, and maximum raw coordinate. The Inspector hides
kind-inapplicable fields and preserves invalid/orphaned references for repair.
See [`targeting.md`](targeting.md) for all fields, provider callables,
sessions, CommonUI integration, security, and effect batches.
(`ManifestEntryKind::TARGET_SCHEMA`). An ability that declares **no**
schema is bounded only by the global limits.

## Defining a tag reaction

```gdscript
# res://my_game/reactions/reaction_burn_cleanse.tres — GameplayTagReactionDefinition
identifier = &"reaction.basic.burn_cleanse_notice"
var tag_operand := GameplayTagOperand.new()
tag_operand.tag = &"state.combat.burning"
tag_operand.match_mode = GameplayTagOperand.MATCH_EXACT
operand = tag_operand
mode = GameplayTagReactionDefinition.MODE_ON_ADDED
effect_identifier = &"effect.basic.burn_cleanse_notice"
```

Only lives in a `GameplayDefinitionCatalog`'s `tag_reactions` collection —
there is no legacy per-component reaction array, so a reaction only ever
exists when a project has adopted the catalog (previous section). Four
fields: a namespaced `identifier` like every other definition kind above;
an `operand` (`GameplayTagOperand` — the same small Resource
`GameplayEffectDefinition.source_requirements`/`target_requirements`
embed, reused here for exactly the tag + exact/parent-aware match-mode
pair a reaction observes); a `mode` (`MODE_ON_ADDED`, `MODE_ON_REMOVED`,
or `MODE_WHILE_PRESENT`); and `effect_identifier`, the effect this
reaction applies **from the owning component to itself** — v1 has no
target selector, context payload, set-by-caller value, or level (see
`reactions.md`, which this section only points to — that document is the
authoritative source for everything about *when* a reaction fires, in
what order, and how failures/cycles/snapshots behave; this section is
authoring syntax only).

Two authoring constraints the validator enforces (see "Validation failure
catalog" above for the exact finding codes):

- `effect_identifier` must resolve against the same catalog's
  `effect_definitions`, and (checked only at `configure()`, not at
  `validate_catalog()`) `operand.tag` must resolve against
  `tag_definitions`.
- A `MODE_WHILE_PRESENT` reaction's target effect must have
  `duration_policy == GameplayEffectDefinition.DURATION_INFINITE` — an
  instant or duration effect cannot be guaranteed to span the whole
  false-to-true/true-to-false interval. A periodic infinite effect
  (`has_period = true`) is fine; periodicity is unrelated to
  `duration_policy`.

The Inspector already wires pickers for both reference fields: opening a
`GameplayTagReactionDefinition` resource shows a searchable hierarchical
tag picker for the embedded `operand`'s `tag` property and a searchable
effect picker for `effect_identifier`, exactly like every other declared
reference in `editor/ga_reference_registry.gd`'s table — see
`editor_workflows.md`'s "Picking a tag in the Inspector" walkthrough.

## Defining network policy

```gdscript
# res://my_game/net/default_policy.tres — GameplayNetworkPolicy
hidden_attribute_identifiers = PackedStringArray(["attribute.internal.rage_meter"])
hidden_ability_identifiers = PackedStringArray(["ability.secret_passive"])
owner_view_default = true
```

`runtime/ga_network_policy_bridge.gd` (`GameplayNetworkPolicyBridge.apply()`)
applies this resource to a `GameplayAbilityNetworkBridge` in one call:
`GameplayNetworkPolicyBridge.apply(policy, bridge)` pushes
`hidden_attribute_identifiers`/`hidden_tag_identifiers`/
`hidden_ability_identifiers`/`default_relevant_peers`/`owner_view_default`
onto the bridge's existing setters (see `api.md`). It is a one-way,
one-time push — call it again after mutating the policy resource for the
change to take effect. `resync_rate_limit_per_minute` and
`prediction_opt_in` are **declarative-only** fields on this resource today:
the bridge always enforces the fixed `ga::MAX_RESYNCS_PER_MINUTE` budget
and has no exposed setter to override it, and an ability's own
`prediction_policy` — not this resource — governs whether it predicts (see
`api.md`'s "Prediction is wired into the Godot layer"). Author them anyway
so the policy asset documents intent in one place.

## How definitions feed the content manifest

At the end of a successful `GameplayAbilityComponent.configure()` (or a
`GameplayDefinitionValidator.validate()`/`validate_catalog()` call), every
sealed registry contributes its own canonical bytes, in `(kind,
identifier)` order, to one FNV-1a64 fingerprint
(`ga::ManifestBuilder`/`ga::ContentManifest`, see `protocol.md`'s
"Manifest algorithm" section for the complete hashing mechanism — not
repeated here). `ManifestEntryKind` fixes the sort key so a future kind
never reshuffles an existing fingerprint:

| Value | Kind | Contributed by |
|---|---|---|
| 0 | `TAG` | `GameplayTagDefinition` set |
| 1 | `ATTRIBUTE` | `GameplayAttributeDefinition` set |
| 2 | `EFFECT` | `GameplayEffectDefinition` set |
| 3 | `ABILITY` | the ability-definitions Dictionary array (or, from a catalog, `GameplayAbilityDefinition` set) |
| 4 | `CUE` | `GameplayCueDefinition` set |
| 5 | `TARGET_SCHEMA` | `GameplayTargetDataSchema` set |
| 6 | `REACTION` | `GameplayTagReactionDefinition` set (catalog only — a legacy component with no catalog contributes none; see `reactions.md`'s "Manifest fingerprinting") |

**Why this matters for multiplayer**: the network handshake
(`protocol.md`'s "Handshake compatibility matrix") rejects a session
outright if two peers' `content_manifest_fingerprint` values differ — a
single authored decimal that quantizes differently, a renamed identifier,
or a reordered-but-unchanged asset set (order never matters — the
manifest is hashed in canonical order regardless of registration order)
will each surface as either "connects fine" or "handshake fails closed
before any gameplay command is accepted," never a silent partial match.
Run every peer's build from the same authored asset set to guarantee this.

## Running the editor validator

`GameplayDefinitionValidation` (`editor/ga_definition_validation.gd`) is
the GDScript-facing convenience over the native `GameplayDefinitionValidator`
(`native/godot/gameplay_definition_validator.h`): it recursively discovers
every `.tres` under a directory, classifies each by native resource type,
and validates the whole set in one pass.

```gdscript
# editor script, plugin menu item, or a headless
# `godot --headless --script ...` CI step
var findings := GameplayDefinitionValidation.validate_directory(
	"res://addons/gameplay_abilities/resources/")
if not GameplayDefinitionValidation.is_ok(findings):
	push_error(GameplayDefinitionValidation.format(findings))
```

Each finding is `{severity, resource_path, field, code, message}` —
`severity` is always `"error"` today (this addon has no non-fatal
authoring warnings yet); `code` is a stable lowercase snake_case string,
either a `ga::DiagnosticId`/`ga::StatusCode` name lowercased or one of the
validator's own authoring-only codes (`null_resource`,
`overflow_effect_cycle`, `schema_bounds`). On success,
`GameplayDefinitionValidator.get_last_manifest_ok()` is `true` and
`get_last_manifest_fingerprint()`/`get_last_manifest_entry_count()`/
`get_last_manifest_tick_rate()` report the resulting content manifest —
useful for asserting in CI that re-running validation over an unchanged
asset set reproduces the identical fingerprint.

`validate_directory` covers **tags, attributes, effects, cues, standalone
tag queries, and target-data schemas** — it does *not* validate abilities
or network policy resources at all (there is no
`Array[GameplayAbilityDefinition]` parameter on `validate()`).

### Ability prediction-eligibility: a separate, explicit call

`GameplayDefinitionValidator.validate_prediction_eligibility_seam(tags, attributes, effects, cues, abilities)`
is a **second, standalone static method** — never called by `validate()`
itself, because `validate_directory` does not discover ability resources
(see "Known gaps" below). It builds its own sealed registries from the
five arrays you pass it, then for every ability marked
`prediction_policy == PREDICTION_PREDICTABLE`, runs
`ga::validate_prediction_eligibility` — **not**
`ga::AbilityRegistry::register_ability`'s own weaker inline check** —
against the sealed effect registry. This matters concretely: the inline
check a plain `register_ability` call performs does not recurse into a
stackable effect's `overflow_effect` chain, so a predictable ability
naming a cost/cooldown/commit effect whose *own* overflow effect is
periodic can register successfully yet still not be prediction-safe. See
[`hooks.md`](hooks.md)'s "the overflow-effect subtlety" for the exact
worked example and the test that proves the registry alone misses it
(`predict_eligibility_rejects_unsafe_overflow_effect_chain`).

**Call this explicitly for any authored ability set that declares even
one `PREDICTION_PREDICTABLE` ability** — do not rely on `validate_directory`'s
successful return to mean abilities are safe; it never looked at them.

## Known gaps, summarized

- `validate_directory()` never validates ability or network-policy
  resources; call `validate_prediction_eligibility_seam` explicitly for
  abilities, and apply network policy by hand.
- `GameplayNetworkPolicy.resync_rate_limit_per_minute` and
  `prediction_opt_in` remain declarative-only (see "Defining network
  policy" above).
- `validate_catalog()`/the dashboard's "Validate Catalog" button does not
  resolve a tag reaction's own references or run cycle detection — see
  "Validation failure catalog" above. Only `configure()` does.
- The maximum dynamic reaction-chain depth (`ga::MAX_REACTION_CHAIN_DEPTH`,
  default 8) is not exposed as a `GameplayAbilityComponent` property —
  every Godot-configured component uses the native default; see
  `reactions.md`'s "Dynamic chain bound".
- `ga::AbilityComponent::add_tag_reaction_diagnostic_listener` (the native
  `TagReactionDiagnosticEvent` stream — application failures, stale
  handles, chain-limit hits) has no `GameplayAbilityComponent` GDScript
  signal wired to it yet; see `reactions.md`'s "Observing reactions from
  GDScript".

## See also

- [`api.md`](api.md) — every resource class's complete property list and
  every enum's integer values.
- [`hooks.md`](hooks.md) — `prediction_safe`/`has_period` on effects and
  `prediction_policy`/`hook_binding` on abilities, with accepted/rejected
  examples and the exact conformance checks run against them.
- [`protocol.md`](protocol.md) — the manifest hash algorithm, the
  identifier grammar's full byte/segment bounds, and fixed-point rounding
  in complete detail.
- [`reactions.md`](reactions.md) — every tag-reaction semantic: predicate
  edges, canonical dispatch ordering, authority/network restrictions,
  `WHILE_PRESENT` binding lifecycle, cycle/chain safety, snapshot/restore,
  and failure semantics.
- [`editor_workflows.md`](editor_workflows.md) — step-by-step Inspector
  and dashboard walkthroughs: picking a tag/attribute, spotting and
  repairing an orphan, safe rename/delete, and running migration.
