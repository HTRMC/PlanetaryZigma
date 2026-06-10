
#version 450

layout(location = 0) in vec4 in_color;
layout(location = 1) in vec2 in_uv;
layout(location = 0) out vec4 out_frag_color;

layout(set = 0, binding = 0) uniform sampler2D atlas;
void main() {
  float coverage = texture(atlas, in_uv).r;
  out_frag_color = vec4(in_color.rgb, in_color.a * coverage);
}
