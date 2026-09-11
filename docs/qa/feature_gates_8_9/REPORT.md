# Task 8.9 — feature-gated meta-action repair

Status: implementation candidate for independent review. Task 8.9 remains
unchecked. human_approval: false.

Reviewed predecessor: b53ece2ef7402c3ec51ec22b2672546eafa37586.
Current main merged before the final run:
7acc971b7622f1a6580e51bcca27793f32e50d56.

All final Godot runs and regenerated captures use the prescribed executable:
/Volumes/Data/sdk/godot/editors/4.7.2/Godot.app/Contents/MacOS/Godot.
Engine version: 4.7.2.stable.official.ed1daf0bf.
Executable SHA-256:
c7cccbf8fb143e34e02fd6521e09be2c2b974f0d5db080b19071c9c570718ccf.

## Repaired behavior

ZScreen permits a guarded callback only when its typed gate is AVAILABLE.
LOCKED and PROTOTYPE actions use the existing authored toast, visibly identify
the action and status, preserve focus and route, and return before the old
mock callback, modal, or service action. The same behavior applies to normal
keyboard and pointer activation.

The immutable five-action gate contract, unavailable production provider,
generation/stale-lease behavior, and explicit QA fixture provider remain in
place. Production remains fixture-free. The existing Character inventory,
other authored scenes, theme, assets, and 28-route catalog are retained.
The frontend skill's existing-design branch informed the repair; DESIGN.md
now records the shared gate interaction. No new visual primitive or token
was introduced.

The visual runner mounts the authored routes through CommonUI and uses the
existing enabled buttons below. It clears prior toast text, records the exact
focus owner and fixture snapshot, pushes real viewport input, and requires
exactly one pressed signal from the authored control. It never calls
notify_feature_action or emits pressed to construct its evidence.

| Feature | Authored route and control | Captured input |
| --- | --- | --- |
| Bunker | bunker: Stations/Row1/Hit | Enter |
| Crafting | crafting: DetailPanel/CraftNow | Primary pointer click |
| Friends | join_friend: FilterAll | Enter |
| Insurance | summary_solo: Reinsure | Enter |
| Marketplace | inventory: InventoryContent/PostRaidBar/SellJunk | Primary pointer click |

All five actual activations show PROTOTYPE ONLY and the feature name. Each
preserves fixture state, route, modal ownership, and focus. The provider/action
contract additionally exercises Enter on all five buttons.

Existing navigation, UI, bunker, and raid regressions previously expected
mock Continue/world/crafting/invite/readiness/insurance effects. Their relevant
assertions now require visible gate feedback and unchanged state. Independent
route, Back, focus, and modal-ownership coverage is retained through explicit
QA setup. Modal ownership is tested with a dedicated QA confirmation callback,
rather than requiring unavailable insurance to open a mock modal.

## Genuine 1920×1080 evidence

Both native runners render the existing UI directly into a dedicated
renderer-backed SubViewport of exactly 1920×1080. They read that target's raw
Image after RenderingServer.frame_post_draw. They never read the physical
desktop framebuffer and contain no resize or resampling fallback.

Before and after every write, assertions verify the actual engine CLI flag,
the orchestration root visible rect, target size/visible rect/texture, UI root
and screen geometry, viewport ownership, and Image size. PNG bytes are decoded
in memory before any directory is created; the written PNG is decoded again
immediately after the write and must preserve the raw Image pixel bytes.
Every geometry or action failure stops evidence generation.

The CLI check reads this process's command through read-only /bin/ps and
requires exactly one engine --resolution 1920x1080 argument before any user
argument separator. This is necessary because Godot removes processed engine
flags from its script argument API. See the
[official OS argument documentation](https://docs.godotengine.org/en/stable/classes/class_os.html#class-os-method-get-cmdline-args).
The current evidence runners fail before mounting on hosts without this
supported Unix CLI inspection path.

The strict first-playable source gate now includes both Task 8.9 PNG writers.
Headless runs verify actions, focus, providers, and logical geometry but skip
all image output.

All seven final PNGs were decoded as exactly 1920×1080 and inspected at
original size. The five action notices are readable within the existing
military/pixel-art composition. This is gate evidence, not acceptance of
the broader real-data screen review or a human navigation pass.

- [Bunker raw frame](feature_gate_bunker_1920x1080.png)
- [Crafting raw frame](feature_gate_crafting_1920x1080.png)
- [Friends raw frame](feature_gate_friends_1920x1080.png)
- [Insurance raw frame](feature_gate_insurance_1920x1080.png)
- [Marketplace on the existing Character inventory](feature_gate_marketplace_1920x1080.png)
- [Production unavailable state](feature_gates_1920x1080.png)
- [Contact sheet](feature_gates_contact_sheet_1920x1080.png)

The contact sheet is itself 1920×1080. It copies source pixels at 1:1 scale:
five rows pair authored-control/detail crops with each complete status notice.
Rows are bunker, crafting, friends, insurance, then marketplace. It performs
no scaling. Full frames remain the primary composition evidence.

The production frame retains the existing unavailable card with UNBOUND
state and UI_SERVICES_NOT_INJECTED_BUNKER diagnostic; it contains no fixture
profile, inventory, settlement, or service data.

## Final verification after merging current main

All screen-producing commands use --resolution 1920x1080. No alternate
screen, compact/reflow path, or framebuffer upscale was executed or reviewed.
The final run has no runtime errors or warnings.
Exact commands and outputs are preserved in [verification.log](verification.log).

| Check | Result |
| --- | --- |
| Prescribed Godot editor import | Exit 0 |
| Strict approved-change validation | Valid |
| Static first-playable scope and writer guards | 4 tests, 0 failures |
| Task 8.9 provider/action/route/focus contract | 74/0 headless; 156/0 native |
| Task 8.9 real-input visual evidence | 124/0 headless; 663/0 native, five raw frames |
| CommonUI input regression | 51/0 |
| CommonUI navigation contract | 80/0, 28 routes |
| CommonUI navigation 1080 regression | 99/0 |
| CommonUI integration | 76/0 |
| UI route smoke | 948/0 |
| UI composition | 103/0 |
| Task 8.11 production-state contract | 57/0 |
| Read-only view contracts | 115/0 |
| Screen lifecycle | 116/0 |
| Bunker / raid smoke | 21/0 and 29/0 |
| Character composition / UI binding | 22/0 and 65/0 |
| Inventory loot UI / inventory smoke | 88/0 and 21/0 |
| Utility smoke | 24/0 |
| PNG dimensions and raw/decoded pixel equality | All exact 1920×1080 |
| Source/evidence manifest | All entries verify |
| git diff --check | Pass |

The exact-1920 lifecycle geometry hash is unchanged:
794e84f101b28dea717a58416b4593af290b79a8cafccf414a8fc93f8b9ddccb.
The combined lifecycle geometry hash is:
4eb724f07fb51fdfccaa5b0659bd07fe33dcb8ba23afea03bb8f1666582c8a4a.

Shared input-binding tests ran under the parent-granted exclusive lease.
An EXIT trap restored the exact baseline file on every completion or failure
path. The final post-run check verified SHA-256
ff6f972f99cc7e9a66db4852735ead27d344b3d090d246a420aa0136aff6bde5
with .tmp and .bak absent, then the lease was explicitly released. No user
data was removed.

The prior independent review found that synthetic controller A did not
activate these controls in either the predecessor or its exact baseline.
This repair makes no controller-success claim. Physical controller and full
human navigation acceptance remain Task 8.13.

All repaired source and evidence hashes are in [sources.sha256](sources.sha256).
The Task 8.9 checkbox is unchanged and human_approval remains false.
