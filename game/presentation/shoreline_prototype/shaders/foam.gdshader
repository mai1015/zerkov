shader_type canvas_item;
render_mode unshaded;
void fragment() {
	vec4 c=texture(TEXTURE,UV);
	c.a *= .73+.20*sin(TIME*1.45+UV.y*65.0);
	COLOR=c;
}
