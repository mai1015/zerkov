# Unify the campaign bunker flow

The user requested a coherent flow connecting the existing bunker map and
management screens, with implementation as a reviewable PR. Merged #19 supplies
the campaign, inventory, deployment and settlement owners. This change repairs
that presentation/navigation composition, not a new game mode or save format.

Today the local binding hides the authored placeholder, injects a preview view,
rewrites labels by their text prefixes and adds direct-deploy buttons. The generic
reflow can re-show the hidden NavigationChrome. Rooms themselves only inspect;
there are duplicated Continue actions and no home-to-menu path short of quitting.

Make the existing bunker map the single home hub. Storage opens the existing
stash/loadout workspace, Medical opens Health, Workshop opens raid briefing.
Room/list selection stays in sync and is restored after closing a workspace.
Utilities, cooking and upgrades stay explicitly unavailable. The map briefing,
not the hub, has the final deploy action. Continue keeps the same campaign.

Preserve offline/local-only state, the current home-recovery policy, existing
asset geometry, native owners, and raid/settlement behavior. No addon, lock,
multiplayer or inventory-policy changes. Keep the independent art preview
inspection-only. Do not treat a UI view as a gameplay or save authority.
