extends RefCounted
## Export-safe final-write guard for sanctioned exact-1080 capture paths.

const EXACT_SIZE := Vector2i(1920, 1080)


static func accepts(
    root_window: Window,
    capture_viewport: Viewport,
    raw_image: Image
) -> bool:
    if DisplayServer.get_name() == "headless" \
            or root_window == null or capture_viewport == null \
            or raw_image == null:
        return false
    var root_texture := root_window.get_texture()
    var capture_texture := capture_viewport.get_texture()
    return DisplayServer.window_get_size(root_window.get_window_id()) == EXACT_SIZE \
        and root_window.size == EXACT_SIZE \
        and root_window.get_visible_rect().size == Vector2(EXACT_SIZE) \
        and root_texture != null \
        and root_texture.get_size() == Vector2(EXACT_SIZE) \
        and capture_viewport.get_visible_rect().size == Vector2(EXACT_SIZE) \
        and capture_texture != null \
        and capture_texture.get_size() == Vector2(EXACT_SIZE) \
        and raw_image.get_size() == EXACT_SIZE
