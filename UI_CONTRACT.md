# Implementation contract

Screens extend `res://ui/core/screen.gd` (class ZScreen). Scenes and controllers live together under `ui/screens/<feature>/`; character route wrappers share one workspace/controller. The navigator supplies `app: ZUIContext` before mounting. There is no absolute Main lookup. `build()` binds retained authored controls. Static visuals belong in scenes; the following helpers remain for variable data presentation and developer studies (coordinates at 1920×1080):

```
box(parent, Rect2(x,y,w,h), color=U.PANEL, border=U.LINE) -> Panel
txt(parent, text, Rect2(...), size=14, color=U.TEXT, mono=false) -> Label
pic(parent, asset_name, Rect2(...), cover=false) -> TextureRect
btn(parent, text, Rect2(...), callback:Callable, primary=false) -> Button
bar(parent, Rect2(...), value:float, color=U.GREEN) -> ProgressBar # 0..100
rule(parent, x,y,w) -> ColorRect
heading(text, subtitle="") # x48 y100
chrome(active:String) # Inventory / Maps / Tasks / Settings routes
footer(text)
background(asset_name="bg_raid_frame.png", darkness=0.65, blur=false)
go(route:String) # app.navigate(route)
toast(message:String) # app.toast(message)
```

`const U = preload("res://ui/theme/tokens.gd")` is available in the base. Shared styles live in `ui/theme/zerkov_theme.tres`; project buttons and the border adapter use it. Mutable sample data is available only through the explicit developer/test fixture provider (`fixture_get`, `fixture_set`, and `fixture_state_for_test`), never through the production app surface. Production screens consume immutable typed views and show a locked/unavailable truth when an owning service has not been injected. UI services are `app.navigate(route)`, `app.back()`, `app.toast(text)`, `app.confirm(title, message, callback)` and `app.prompt(...)`. Register explicit paths and roles in `ZRouteCatalog`; keep the 28 current route IDs stable. Ongoing authority integration is separate work.

Use explicit types or plain `=` for dynamic expressions; avoid inferred Variant warning errors. Godot 4.x. Native nodes only, not screenshot overlays. Read actual handoff HTML sections and view provided screenshots for owned screens before implementing. All buttons must navigate or perform clear local mock action. Can consolidate related screens into one script with scene wrapper and read `app.current_route` in build.

## Current display scope

Current first-playable acceptance runs at the exact 1920×1080 logical canvas,
and Play defaults to 1920×1080. Existing adaptive windows, compact hosts and
`reflow()`/`layout_compact(view)` compatibility APIs remain in production code,
but current agents/tests MUST NOT execute smaller windows, compact overrides or
regenerate smaller captures. Task 11.8 or a later approved display-support
proposal is the only reopening point. At the current target, `reflow()` must not
navigate/remount; `refresh_view()` restores authored placement, binds data and
restores eligible focus/caret/scroll state. Prefer narrower component data
updates when no layout changes. Never clear a screen's fixed children to refresh
it.

Retained compact hosts and named content references are compatibility surfaces for
the deferred display-support work. Where those APIs are maintained,
`ZAdaptive.pane(host, bounds, content_size, name)` returns its content Control;
`move_group(source, name, origin, content)` uses authored `compact_group`
metadata, and `move_nodes(nodes, content, offset)` uses explicit references. Do
not infer pane membership from screen coordinates. `backdrop(screen, view)`
resizes backgrounds. Keep chrome, section tabs and primary footer actions outside
scrolling content; bounded grids/maps may scroll horizontally.

CommonUI owns HUD/menu/modal/popup stacks and lifecycle. Raw screen input must check `accepts_input()`. Components expose configuration and semantic signals, not their child paths. See [component APIs, ownership and extension examples](ui/components/README.md) for the current contract and native verification commands.
