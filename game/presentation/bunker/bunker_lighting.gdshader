shader_type canvas_item;
render_mode unshaded;
uniform bool emergency = false;
float pool(vec2 p, vec2 light, float radius) {
	return pow(max(0.0, 1.0 - distance(p, light) / radius), 1.4);
}
void fragment() {
	vec4 source = texture(TEXTURE, UV);
	vec2 p = UV * vec2(640.0, 360.0);
	vec3 exposure = vec3(0.58, 0.61, 0.62);
	if (emergency) {
		exposure = vec3(0.29, 0.33, 0.37);
		exposure += vec3(1.4, 0.42, 0.17) * pool(p, vec2(400.0, 130.0), 110.0);
		exposure += vec3(0.35, 0.52, 0.57) * pool(p, vec2(88.0, 276.0), 74.0);
	} else {
		exposure += vec3(0.88, 0.77, 0.51) * pool(p, vec2(103.0, 114.0), 98.0);
		exposure += vec3(0.94, 0.89, 0.66) * pool(p, vec2(280.0, 126.0), 120.0);
		exposure += vec3(1.12, 0.78, 0.43) * pool(p, vec2(403.0, 132.0), 108.0);
		exposure += vec3(0.57, 0.77, 0.78) * pool(p, vec2(83.0, 275.0), 85.0);
		exposure += vec3(0.86, 0.68, 0.43) * pool(p, vec2(246.0, 270.0), 82.0);
		exposure += vec3(0.92, 0.76, 0.50) * pool(p, vec2(414.0, 275.0), 86.0);
	}
	COLOR = vec4(source.rgb * exposure, source.a);
}
