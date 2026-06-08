// vertex.glsl
#version 450
#extension GL_EXT_buffer_reference : require

struct Vertex {
  vec2 position;
  vec2 uv;
  vec4 color;
};

layout(buffer_reference, std430) readonly buffer VertexBuffer {
  Vertex vertices[];
};

layout(push_constant, std430) uniform pc {
  VertexBuffer vertex_buffer;
} push_constant;

layout(location = 0) out vec4 out_frag_color;
layout(location = 1) out vec2 out_uv;

void main() {
  Vertex v = push_constant.vertex_buffer.vertices[gl_VertexIndex];
  gl_Position = vec4(v.position, 0.0, 1.0);
  out_frag_color = v.color;
  out_uv = v.uv;
}
