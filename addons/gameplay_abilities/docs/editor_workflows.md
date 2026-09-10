# Editor Workflows

Concise, step-by-step walkthroughs for the catalog-backed Inspector
pickers and the dashboard's Catalog/Migration tabs (design.md decision 2;
`docs/spec/changes/add-global-tag-catalog-and-reactions-2026-07-25/specs/gameplay-definition-authoring/spec.md`).
No screenshots — every label below is the literal, exact text the running
editor shows, copied from the widget construction code
(`addons/gameplay_abilities/editor/ga_dashboard.gd`,
`ga_reference_picker_property.gd`, `ga_picker_popup.gd`), so you can
follow along by matching text rather than pixels.

Prerequisite for every walkthrough below: the addon's bottom-panel dock,
titled **Gameplay Abilities**, is open (`Project > Tools`, or it opens
automatically the first time the plugin activates), and its first tab is
**Catalog**. With no configured project default, the dashboard automatically
selects a saved catalog only when exactly one exists; zero or multiple
catalogs require an explicit choice. If no catalog is selected yet, click
**New...** in the Catalog tab's top row, save a `.tres` file, and it becomes
the selected catalog; click **Open...** to choose an existing catalog; or
click **Use Project Default** to select whatever
`gameplay_abilities/default_definition_catalog` already points to (see
`authoring.md`'s "Catalog setup").

## Picking a tag in the Inspector

Applies to any property the addon declares as a tag reference — for
example `GameplayTagOperand.tag` (used inside
`GameplayEffectDefinition.source_requirements`/`target_requirements`/`immunity`
and inside a `GameplayTagReactionDefinition.operand`),
`GameplayAbilityTrigger.gameplay_event_tag`, or a packed tag array like
`GameplayEffectDefinition.granted_tags`/`GameplayAbilityDefinition.owned_tags`.

**Scalar tag property** (e.g. `GameplayTagOperand.tag`):

1. Select the resource in the Inspector (e.g. open a
   `GameplayTagReactionDefinition` `.tres`, expand its `Operand`
   sub-resource).
2. The `Tag` property shows a button. If nothing is set, it reads
   **(none)**; if a tag is already set, the button shows that tag's exact
   identifier.
3. Click the button. A search popup opens with a **Search...** field
   already focused and, below it, a **Clear Selection** button, then a
   tree of every tag in the currently selected catalog, nested by dotted
   segment (`state` → `control` → `stunned`, etc.).
4. Type to filter the tree live. Use `Up`/`Down`/`Home`/`End` to move the
   selection without touching the mouse; press `Enter` to confirm the
   highlighted row (or, if your search narrowed the list to exactly one
   match, `Enter` accepts it directly). Double-click a row, or activate it
   in the tree, to the same effect. `Escape` closes the popup without
   changing anything.
5. Picking a row serializes that tag's stable identifier onto the
   property and closes the popup — this is a normal undoable Inspector
   edit (`Ctrl+Z` undoes it).
6. A small **x** button next to the picker button clears the property
   back to empty; it is disabled whenever the property is already empty.

**Packed tag array property** (e.g. `granted_tags`, `owned_tags`):

1. Each currently listed identifier renders as its own row with a
   trailing **x** (tooltip "Remove") button.
2. Below the rows, a **+ Add** button opens the identical search popup
   described above (without its own "Clear Selection" button — clearing
   a whole array isn't this control's job, remove rows individually
   instead).
3. Picking a tag appends it to the array. Picking a tag already present
   in the array is rejected with an editor warning in the Output panel
   ("... is already present in ...") rather than silently adding a
   duplicate row.

## Picking an attribute in the Inspector

Applies to `GameplayModifierDeclaration.target_attribute` — the one
property design.md calls out by name as attribute-only, never
tag-valued.

1. Open a `GameplayEffectDefinition`, expand a `Modifiers` array entry
   (a `GameplayModifierDeclaration`).
2. The `Target Attribute` property shows the same button/**x**-clear
   pair as a scalar tag picker, but the popup it opens lists **attribute
   identifiers only** — never tags, effects, abilities, cues, or target
   schemas. Attributes are shown flat, grouped one level by their first
   dotted segment (e.g. everything under `attribute.vitals.*` groups
   under `attribute`), not as a full hierarchy tree the way tags are.
3. Search, navigate, and pick exactly as above. The same picker widget
   also backs every other non-tag reference kind this addon declares —
   `cost_effect`/`cooldown_effect`/`GameplayStackingPolicy.overflow_effect`/
   `GameplayTagReactionDefinition.effect_identifier` (effect pickers),
   and `GameplayAbilityDefinition.target_schema` (target-schema picker) —
   all flat/grouped the same way attributes are.

## Spotting and repairing an orphan

An "orphan" is a serialized identifier the current property still holds
that no longer resolves against the active catalog (the definition was
deleted, renamed outside this flow, or the catalog selection changed).

**Spotting one:**

- A scalar picker button still shows the **exact original value verbatim**
  — it is never silently cleared or swapped to the first available
  identifier — but the property row draws with the Inspector's built-in
  warning affordance, and hovering the button shows the tooltip:
  `'<value>' was not found in the active catalog. Choose a replacement
  from the picker or clear it explicitly -- it will not be changed
  automatically.`
- In a packed array picker, the specific orphaned row's label renders in
  a distinct warning color with tooltip `'<value>' was not found in the
  active catalog.`; every other (resolved) row renders normally. The
  property-level warning affordance is shown whenever *any* row in the
  array is orphaned.
- Opening or refreshing the Inspector never mutates this on its own —
  reload the scene/resource, switch catalogs, and switch back, and an
  orphan is still displayed exactly as authored until you explicitly act
  on it.

**Repairing one:**

1. Click the scalar picker button (or, for an array row, there is no
   separate "repair" affordance — remove the orphaned row with its **x**
   and **+ Add** a valid replacement instead).
2. Pick a valid identifier from the popup exactly as in the picking
   walkthroughs above.
3. That single property change goes through the normal undoable Inspector
   path. Re-running **Validate Catalog** (Catalog tab) no longer reports
   that identifier as unresolved.

If you instead want to keep the value as-is (e.g. you are about to
recreate the missing definition under the same identifier), simply leave
it alone — nothing forces a resolution before you save.

## Safe rename/delete via the dashboard usage report

This flow currently covers **tags** end to end (the Catalog tab's own
**New Tag...**/**Rename...**/**Delete...** buttons operate on
`tag_definitions`); the same underlying usage-report/rewrite machinery
(`GAUsageScanner`, `GARewritePlanner`) is reused by anything that later
wires up rename/delete for the other definition kinds.

1. In the Catalog tab, select a tag in the **Tags in catalog:** list.
2. Click **Rename...** or **Delete...**. A dialog titled `Rename Tag
   '<identifier>'` or `Delete Tag '<identifier>'` opens; its body starts
   with `Renaming: <identifier>` or `Deleting: <identifier>`, then
   immediately shows `Computing usage report...` while the scan runs.
3. The usage report scans **every catalog-owned resource** (all seven
   collections, recursively through nested resources like
   `GameplayTagQueryResource`/`GameplayTagOperand`) **and every project
   `.tres`/`.res`/`.tscn` file** under `res://` for a reference to this
   exact identifier, using the same declared reference table the Inspector
   pickers use (`ga_reference_registry.gd`) — never a name guess. When it
   finishes, the dialog body lists:
   - `<N> rewritable reference(s) found.` followed by one
     ` - <resource path>: <dotted/bracketed property path>` line per
     match (e.g. ` - res://.../effect_stun.tres: granted_tags[0]`);
   - if anything could not be safely rewritten:
     `<N> reference(s) CANNOT be rewritten safely -- operation blocked:`
     followed by the same per-line format. A file that textually contains
     the identifier but has no *structural* match through the declared
     reference table (e.g. it only appears in a comment or an unrelated
     resource name) is reported here too, as
     `(text match, no declared reference found)`, rather than silently
     ignored.
4. **Rename** additionally requires a valid new identifier: type it into
   the **New Identifier** field. An invalid identifier (see
   `authoring.md`'s "The identifier rule") or one already used by another
   tag in this catalog shows an inline error and disables the dialog's OK
   button. **Delete** shows no such field.
5. The OK button stays disabled the whole time any reference is
   unsupported (`operation blocked`) — there is no way to force a rename
   or delete that would leave a dangling reference. If the report is
   fully rewritable (rename) or empty (delete), confirming applies **every**
   listed rewrite plus the definition's own rename/removal as **one**
   editor undo/redo transaction — `Ctrl+Z` once restores the complete
   prior state, identifier and every rewritten reference together.

## Running migration

Moves an existing scene's legacy per-component definition arrays into a
catalog. **Never happens automatically** — opening a legacy scene never
rewrites it; this tab is the only way legacy fields change
(design.md's "Migration").

1. Open the scene containing the `GameplayAbilityComponent`(s) you want
   to migrate in the editor (the scan below reads the **currently edited
   scene**, not an arbitrary path).
2. Switch the dock's **Migration** tab. It reads: "Preview legacy
   component-array definitions found under the currently edited scene,
   then copy the unique ones into the selected catalog and clear the
   migrated component fields in one undoable action. Never run implicitly
   -- this tab is the only way legacy fields change."
3. Make sure the intended destination catalog is selected in the
   **Catalog** tab first (migration writes into whichever catalog is
   currently selected).
4. Click **Scan Edited Scene**. This recursively finds every
   `GameplayAbilityComponent` under the scene root with at least one
   populated legacy array (`tag_definitions`, `attribute_definitions`,
   `effect_definitions`, `cue_definitions`, `target_data_schemas`, or
   `ability_definitions`) and previews what migrating them would do.
5. The preview list shows one line per definition kind:
   `<Kind>: <N> unique, <N> duplicate group(s), <N> collision(s)` (tags,
   attributes, effects, cues, target schemas). A **collision** is an
   identifier that already exists in the destination catalog with
   different content — migration does not silently overwrite it.
   Legacy `ability_definitions` entries authored as raw Dictionaries
   (rather than `GameplayAbilityDefinition` resources) have no Resource
   form to copy into the catalog's strictly-typed
   `Array[GameplayAbilityDefinition]` collection; each such source is
   listed separately as
   `NOT migrated (legacy ability_definitions has no Resource form to
   copy): <node path>` — migrate those abilities by hand (author a
   `GameplayAbilityDefinition` `.tres`, see `authoring.md`'s "Defining an
   ability").
6. The status label reads `Preview ready. <N> source(s) scanned.` when
   there is something new to migrate, or `Preview ready -- nothing new to
   migrate.` when every found definition already exists in the catalog
   (the **Accept Migration** button stays disabled in that case).
7. Review the preview, then click **Accept Migration**. This copies every
   *unique* definition into the selected catalog and clears the
   migrated component's legacy array fields, all as **one** undoable
   editor transaction. The status label reads `Migration applied.`
8. Save the scene. The migrated component now resolves its catalog on the
   next `configure()` (either because you also set
   `definition_catalog`/the project default, or because the component
   already had one and the legacy arrays were merely blocking it — see
   `authoring.md`'s "Mixed catalog/legacy configuration is rejected").
9. If anything looks wrong, `Ctrl+Z` restores the complete prior
   serialized state (catalog contents and the component's legacy arrays
   together) in one step, exactly like the rename/delete flow above.

## See also

- [`authoring.md`](authoring.md) — catalog setup, the project setting,
  legacy migration semantics, and the validation-finding codes these
  workflows surface.
- [`reactions.md`](reactions.md) — the semantics of a
  `GameplayTagReactionDefinition` once you've picked its operand tag and
  target effect using the walkthroughs above.
