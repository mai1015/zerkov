shader_type canvas_item;
// UVs are untouched: atlas sampling/clipping remains owned by Sprite2D.
// No TIME: the owner can freeze, replay, pause and reduce motion explicitly.
uniform float visual_seconds = 0.0;
instance uniform float sheet_height = 32.0;
instance uniform float phase_offset = 0.0;
uniform float strength = 1.0;
void vertex() {
	float weight = clamp(1.0 - VERTEX.y / max(sheet_height, 1.0), 0.0, 1.0);
	float gust = sin(visual_seconds * 1.3 + phase_offset) * 0.65
		+ sin(visual_seconds * 0.47 + 1.1) * 0.35;
	VERTEX.x += round(gust * strength * 1.6) * weight;
}
