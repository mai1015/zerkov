# Zerkov UI design system

## 1. Atmosphere & identity
The approved handoff at `/Volumes/Data/Downloads/handoff` is the visual contract. Native Godot Controls recreate its utilitarian extraction-shooter interface: pixel art behind crisp military typography, dense inventory cells, narrow rules, orange actions and unobstructed in-world HUD. The UI preview uses local fixture state; ongoing gameplay implementation owns authority and is outside this UI composition change.

## 2. Color
Shared tokens: BG #0a0b0a, PANEL #0e100f, CANVAS #141414, DARK rgba(7,9,9,.85), TEXT #E6E8E3, MUTED #8B918A, SOFT #B7BCB4, BORDER #2a2a2a, LINE white at .12, SUBTLE white at .08, ACCENT #E8962E, HOVER #F2B15A, GREEN #5FD36B, RED #D9483B, YELLOW #E9D35A, BLUE #4C8DFF. Scene backgrounds may be darkened or blurred as in the references. Orange marks actions and valuable loot.

Practical skill icons use the approved sage #9AA58A. Slot fills and borders use translucent combinations of PANEL/TEXT; selected/disabled surfaces derive their alpha from the same palette.

## 3. Typography
Chakra Petch regular/medium/semibold/bold for headings and UI; IBM Plex Mono regular/medium/semibold for labels and data. Labels 10–11, body 13–14, section 13 semibold, headings 22, display and numerical values 28–48. Reference-specific 12, 16, 18, 20, 24, 32, 36, 44, 56, 60 and 64 sizes are allowed where the approved HTML calls for them; the HUD ammo value uses 60. Godot font spacing approximates HTML tracking; prioritize reference geometry. Fonts bundled for offline operation.

## 4. Spacing & layout
1080p first-playable policy (2026-09-10): the approved exact 1920×1080 composition is the sole current UI and visual acceptance target. Play opens at 1920×1080, and screen geometry follows the exact reference coordinates. Existing responsive and compact code may remain unchanged as historical regression behavior, but current agents and tests MUST NOT execute smaller-output paths or regenerate their captures. Smaller-output adaptation, capture review and acceptance are deferred to task 11.8 or a later approved display-support proposal. New first-playable work must not add layout branches or reduce the authored desktop hierarchy for smaller windows.

Inventory cells remain 74 logical pixels. Spacing scale is 4/8/12/16/24/32/40/48/64/96; top navigation is 56 high. All screens are native Control scenes built from shared primitives. Desktop keyboard/mouse at 1920×1080 is the MVP target. Existing compact scroll containers, section hosts, and explicit layout overrides remain implementation compatibility surfaces only, not current completion gates.

## 5. Components

Composition contract (2026-09-09): scenes and controllers are grouped by feature;
shared controls consume an authored project Theme. Button variants are secondary
(default), primary, flat navigation, transparent hit target, and destructive.
Each retains normal, hover, pressed, focus and disabled states from the palette.
Cards and rows own their labels, selection/focus appearance and activation signal;
public configuration updates before and after mounting and previews in the editor.
Screen shells and shared chrome remain alive during filtering, data updates,
pause/resume and any retained reflow path. The 1920×1080 desktop composition is
the current acceptance surface. CommonUI owns temporary navigation
stacks, HUD/menu/modal/popup placement and focus restoration. Feature controllers
receive their UI services explicitly; isolated preview uses fixture services.

- CommonUI foundation: `ui/main.tscn` owns a `CommonUIScreenRoot`; routable screens derive from `CommonActivatableScreen`, menu changes use the menu layer stack, dialogs use the modal layer, and Back is registered through the shared action router.
- Panel: square dark surface with optional 1px border; selected orange or white rim; no decorative rounding.
- Hairline rendering: square borders and grid lines must occupy at least one physical pixel, aligned to the output pixel grid, even when the desktop canvas is fractionally scaled. Keep the original 1px geometry at 1080p; do not round corners or depend on 2D MSAA (unsupported by Compatibility). Grid perimeter strokes stay inside the grid bounds so scrolling cannot clip their outer half.
- Text: shared font selection, color, size; mouse ignored; HUD shadow variant.
- Button: `ui/components/controls/zerkov_button.tscn` wraps CommonUI's `CommonButton` with the project interaction contract. It keeps the square normal, warm-hover, orange-pressed, keyboard-focus and muted-disabled states. Primary actions use orange with dark text. Tooltips explain prototype actions.
- Navigation: `ui/components/layout/navigation_chrome.tscn` provides the authored 56px Inventory/Maps/Tasks/Settings chrome, active underline, resources and bottom hints. `ui/screens/bunker/components/top_chrome.tscn` owns the bunker family's repeated resource, status and menu header. Back and Escape preserve context.
- Item slot: 74px grid, nearest-filtered item image, item label/count, value tint; selected/focused rim, compatibility highlight, drag preview, invalid drop feedback and Ctrl-click transfer.
- Meter: thin track plus semantic fill; labels and values remain textual.
- Toggle/slider/select/input: native keyboard-focusable controls; selected and disabled states; inline validation for binding or invite errors.
- Station/recipe/task/world/squad card: repeated Panel/Text/Button combinations; active selection, empty slots, unavailable and ready states. Main-menu actions use `ui/screens/frontflow/components/menu_action_card.tscn`; saved-world entries use `ui/screens/frontflow/components/world_row.tscn` and `new_world_row.tscn`.
- Toast/modal: authored `ui/components/feedback/toast.tscn` and `zerkov_dialog.tscn`, owned by `ui/core/feedback.tscn`. Notifications do not take focus; CommonUI confirmation/prompt flows have explicit cancel/accept.
- Feature gates: the retained bunker, crafting, friends, insurance and marketplace controls expose LOCKED or PROTOTYPE ONLY in their tooltip and ordinary activation toast. Activation preserves focus and route, opens no modal, and performs no fixture or service mutation until a typed AVAILABLE gate exists. QA may mount the existing authored scenes with an explicit fixture provider; production remains fixture-free.
- Screen picker: F1 developer review overlay, reachable screens and demo state toggles; hidden in normal screens.
- Bounded pane: native ScrollContainer with visible scrollbar when content exceeds its authored 1920×1080 pane, wheel/trackpad and keyboard focus-following; square palette-matched track. Pane tabs retain selected section in local state. No whole-page horizontal scroll for ordinary menus; bounded inventory/map canvases may pan or scroll when their intrinsic content exceeds the pane. Existing compact behavior is deferred and nonblocking.
- Parallax background: reusable `ui/components/backgrounds/parallax_background.tscn` with authored TextureRect planes, source assets, draw order and per-plane depth metadata visible in the Godot scene inspector. Its script only applies pointer easing and responsive overscan; menu controls stay outside the moving component.
- Authored screen composition: feature scenes in `ui/screens/<feature>/` own desktop hierarchy, geometry, static copy, textures and styles. Character routes inherit `character_workspace.tscn`; gear/health/stats sections and existing compact hosts are retained shared scenes, but only the desktop composition gates this slice. Feature-local components stay with their feature; cross-feature components live in `ui/components/`. Controllers bind state, actions, focus and animation. Variable inventory slots and task lists remain data components inside authored shells. Existing responsive overrides remain reversible and must not drive new first-playable work.

## 6. Motion & interaction
Blink bleed 1s step, readiness pulse opacity, clockwise reload ring over 2.4s. Button feedback immediate; screen opacity transitions 0.15s where practical. The main menu composes the original sky, clouds, logo, mountains, house and corrected foreground art as separate pointer-parallax planes. Every plane shares 44×30px overscan; travel rises with depth from 8% at the sky to 100% at the foreground, capped at 24×14px and eased at 7.5 response. UI chrome remains fixed so labels, borders and hit targets stay pixel-stable. Settings, selected screen tabs and mock data survive navigation within the app. F1 opens catalog; Esc backs out or pauses; Tab inventory, M maps, J tasks, R reload preview, Y quick heal. Explicit QA fixtures may display deployment/crafting/ready progress. Gated feature actions use the Section 5 status notice and preserve fixture state instead of opening mock confirmations. No game logic is implemented.

## 7. Depth & surface
Mixed: original key art / raid frame / bunker floor plan, dark translucent overlays, hairline borders. HUD has no panels, only black text shadows (offset 0,1 size 2) and colored vitals. TextureRect nearest filtering for small pixel art; key art uses linear filtering. Blur shader only for menu/summary backdrops. Verification is native Godot import, runtime and screenshot comparison at 1920×1080 only; web-specific React/Lighthouse checks do not apply.
