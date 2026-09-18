shader_type canvas_item;
uniform sampler2D macro_tint : filter_linear, repeat_disable;
uniform vec2 map_size = vec2(1792.0, 1024.0);
uniform float water_motion = 0.0;
varying vec2 world;
varying vec4 vertex_tint;
void vertex() { vertex_tint=COLOR; world = (MODEL_MATRIX * vec4(VERTEX,0.0,1.0)).xy; }
void fragment() {
	vec4 albedo=texture(TEXTURE, UV) * vertex_tint;
	vec3 tint=texture(macro_tint, world/map_size).rgb;
	float wave=1.0+water_motion*(sin(world.y*.115+world.x*.024-TIME*1.4)*.016+sin(world.x*.17+TIME*.85)*.008);
	COLOR=vec4(albedo.rgb*tint*wave, albedo.a);
}
