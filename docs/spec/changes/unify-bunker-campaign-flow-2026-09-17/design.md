# One home, existing workspaces

```
Title → New Local Game / Continue → Bunker map
                                  ├ Storage → Stash / loadout → Back
                                  ├ Medical → Health → Back
                                  ├ Workshop / M → Sawmill briefing → Deploy solo
                                  ├ J → Supply Run → Back
                                  └ Esc → Home menu → Controls / Resume / Main menu / Quit
Raid → committed result → Return home → same bunker map
```

`ZBunkerHideoutView` has an explicit pre-mount campaign configuration. It receives
only an availability frame and emits action/selection intents. Its standalone
preview remains unchanged and inspection-only. Production binding removes old
placeholder CanvasItems instead of relying on visibility flags, and opts out of
the legacy compact reflow. The full 640x360 cutaway still renders at exact 3x on
the approved 1920x1080 canvas. Smaller windows uniformly fit the hub rather than
reviving the old station controls; that is fitting, not new adaptive acceptance.

`LocalGameUI` keeps an ephemeral selected room scoped to a presentation epoch.
It is never serialized into the profile. Returning from a workspace preserves
selection; closing/reopening the campaign resets to Storage. Buttons and map
clicks respect the active CommonUI context, modal blocking and retired epochs.

`LocalGame` continues to own all routing, native inventory and persistence.
The hub's planning button requests `maps`, not `deploy`. The root also refuses
to deploy outside the briefing route. The brief is the deliberate review step;
this change does not add another modal between the brief and loading. Returning
to the main menu saves first, retires home bindings, and never grants starter
items again. Save failures remain errors and keep the home available for retry.

No new resource, building, cooking, sleep, power, economy or transport system is
implied by the room art. Controls are labelled Controls, not a promise of a full
settings backend. Existing domain/campaign regressions must still pass through
the new briefing path, including extraction, death and relaunch.

Shortcut captions describe the effective CommonUI bindings (default I / M / J),
not a second hardcoded key policy. Rebinding remains owned by the Controls screen.
