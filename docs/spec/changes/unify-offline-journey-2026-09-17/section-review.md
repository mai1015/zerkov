# Section-header and raid Character review

The user requested global sections at the top, detail controls inside the page,
one Character interface usable during raids, and a more coherent bunker/Character
palette. This follow-up preserves the authored Character layout and campaign owners.

## Result

At home the shared NavigationChrome displays Bunker / Character / Tasks / Briefing /
Settings. In a raid it displays Character / Tasks / Map / Settings, with no Bunker
entry. Character includes its existing Gear / Health / Stats subpages; Controls is
inside Settings. Workshop, Facilities and Local Session are bunker-local page tools.
The component retains CommonUI semantic signals, selected state, independent focus
and context-sensitive Back behavior. Reflow cannot restore fixture insurance,
currency or level navigation. The bunker, character pages and operation cards share
olive-charcoal surfaces, off-white text and muted brass accents. Transparent room
outlines retain their transparency instead of being restyled into filled panels.

During raids the same Character script reads the current raid runtime. The bunker
stash tab is absent and the ordinary character context strip replaces the permanent
post-raid action banner. The nearby-loot pane is empty until the existing world
interaction opens a searched container. It neither renders retained unopened-crate
items nor permits a tab to open the controller's default crate. Closing loot does
not focus a hidden stash tab. The existing successful search/open/transfer route
remains functional; this is not blanket disabling of world loot.

## Local verification

Reviewed source was first tested on PR #34 head `7a4d900...`; before committing,
#34 merged into main `4108812...`. GitHub comparison showed only four intervening
files (LocalGame, health adapter, health tests and clock test), none among this
follow-up's edited paths. The follow-up preserves those merged files unchanged.
Exact-head CI on the new base is recorded separately on the follow-up PR.

With the locked `4.7.2.stable.official.ed1daf0bf` engine and actual native libraries:

| Local invocation | Checks | Failures |
| --- | ---: | ---: |
| New campaign, preparation, raid section navigation and committed abandonment | 274 | 0 |
| Independent Continue after that loss | 137 | 0 |
| Graphical New | 291 | 0 |
| Graphical independent Continue | 144 | 0 |
| Existing full raid cycle | 4241 | 0 |
| Existing bunker workspaces | 139 | 0 |

All six completed with exit 0 and no script/engine-error diagnostics. The New and
Continue journey fingerprint is
`f666ab617e5d253d579170dc84ee2b2ce4dd70df892472648e7094e43735c87f`.
The full-cycle test covers real search, opened-loot transfer, extraction, failed
settlement write/retry, abandonment, death, home recovery and redeployment.
Fourteen runner tests, 23 scope tests, the exact-1080 repository gate and whitespace
checks also pass. A separate save-error layout probe uses only a copied presentation
frame; it does not simulate a successful disk write or mutate the campaign port.

Twenty-two raw 1920x1080 captures cover both contexts with the unchanged physical
capture guard. The expanded graphical suite has a bounded 300-second inner /
330-second outer timeout; headless budgets and failure handling remain unchanged.
Linux evidence uses an outside test copy, hash-verified native libraries, Xvfb and
Mesa software rendering, plus explicit extension registration for the known pinned
engine cold-discovery defect. It is not a cold-import fix, addon promotion, export,
performance result or human/controller signoff. No font or binary is part of this PR.

## Remaining scope

The existing equipment-slot controls, quick-use controls and some Stats content
remain labelled unavailable/fixture where their gameplay integration is missing.
Reusing Character in raids does not claim those separate mechanics are complete.
Unsupported Settings categories remain disabled. No save schema, native addon,
combat balance, map geometry, multiplayer or solo-pause policy is changed.
