shader_type canvas_item;
render_mode unshaded;
varying vec4 vertex_tint;
void vertex() { vertex_tint=COLOR; }
void fragment() { COLOR=texture(TEXTURE,UV)*vertex_tint; }
