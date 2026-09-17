# Walk the bunker hideout

The authored hideout from `add-bunker-hideout-map-2026-09-15` shipped as a
cutaway you look at: clicking a room moved an inspector, and a facilities list
beside the art described whichever room was last clicked. The world already
carried everything needed to stand inside it -- a 640x360 wall plan with the
doorways carved out, per-prop footprints, and room lookup -- and it is exactly
one screen at the authored 3x scale, so entering it needs no camera work.

This change puts the real layered player artwork in that world and lets the
player walk it. The inspector follows where the operator stands rather than
where the mouse last clicked. `station_entered` / `station_left` are emitted
for the interaction that will consume them.

It also deletes the placeholder station layout `bunker.tscn` still carried:
155 nodes and 35 resource declarations that `bunker_hideout_screen` hid on
every entry, after `bunker.gd` had already styled them. Node count drops from
239 to 84 and `load_steps` from 44 to 9.

Presentation only. The bunker runs no raid authority, so nothing here moves
authority-owned state and no save is touched. Build, craft, upgrade, trade and
persistence remain explicitly unavailable, and the exact 1920x1080 output with
the 640x360 world at 3x is retained. Player artwork passes the same sha256
provenance check the raid performs before display.

## Open decision: this change and PR #26 both rewrite the same screen

PR #26 (`unify-bunker-campaign-flow-2026-09-17`) rewrites
`bunker_hideout_view.gd` into a click-a-room campaign home with a room sidebar,
`HOME_ROOMS` metadata, `configure_campaign` / `present_home` and an
`action_requested` command signal. This change rewrites the same file into a
walkable space. They are two competing designs for one screen, not two halves
of one: merging both leaves a sidebar whose selection and an operator whose
position each claim to own `current_room`.

`git merge` reports a content conflict in `bunker_hideout_view.gd` and
`ui/core/local/local_flow_binding.gd` between them, so neither can land after
the other without a decision. That decision is not made here.
