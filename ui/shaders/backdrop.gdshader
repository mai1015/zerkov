shader_type canvas_item;
render_mode unshaded;

// Blur the reference world texture itself; menus remain sharp.
void fragment() {
	vec2 step_uv = TEXTURE_PIXEL_SIZE * 1.2;
	vec4 result = vec4(0.0);
	float total = 0.0;
	for (int x = -5; x <= 5; x++) {
		for (int y = -5; y <= 5; y++) {
			float weight = exp(-float(x*x+y*y) / 18.0);
			result += texture(TEXTURE, UV + vec2(float(x), float(y)) * step_uv) * weight;
			total += weight;
		}
	}
	COLOR = result / total;
}
