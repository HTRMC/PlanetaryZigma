
#version 450
#extension GL_EXT_buffer_reference : require

layout(location = 0) in vec4 in_color;
layout(location = 1) in vec2 in_uv;
layout(location = 0) out vec4 out_frag_color;

void main() {
  out_frag_color = in_color;
}
