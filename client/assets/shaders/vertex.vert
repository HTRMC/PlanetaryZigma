// vertex.glsl
#version 450
#extension GL_EXT_buffer_reference : require

layout(set = 0, binding = 0) uniform sceneData {
  mat4 proj_view;
  vec3 global_light_direction;
  float time;
} scene_data;

layout(set = 1, binding = 0) uniform sampler2D texSampler;

struct Vertex {
  vec3 position;
  float uv_x;
  vec3 normal;
  float uv_y;
  vec4 color;
  vec4 in_joint_indices;
  vec4 in_joint_weights;
};

layout(buffer_reference, std430) readonly buffer VertexBuffer {
  Vertex vertices[];
};

layout(push_constant, std430) uniform pc {
  mat4 model_matrix;
  VertexBuffer vertexBuffer;
} push_constant;

layout(location = 0) out vec4 out_frag_color;
layout(location = 1) out vec2 out_uv;
layout(location = 2) out vec3 out_normal;

void main() {
  Vertex v = push_constant.vertexBuffer.vertices[gl_VertexIndex];
  float time = scene_data.time;
  float x = v.position.x;
  float y = v.position.y;
  float z = v.position.z;
  gl_Position = scene_data.proj_view * push_constant.model_matrix * vec4(x, y, z, 1.0);
  // gl_Position = scene_data.proj_view * vec4(x, y, z, 1.0);

  // vec3 uv = vec3(v.uv_x, v.uv_y, v.uv_x);
  vec3 col = 0.5 + 0.5 * cos(gl_Position.y * scene_data.time + v.uv_x + vec3(0, 2, 4));
  // vec3 col = vec3(1, 0, 0);

  // float red = (y > 0) ? 1 : 0;
  // vec3 col = vec3(red, 0, 0);

  out_frag_color = vec4(col, 1);
  // outFragColor = vec4(v.color);
  out_normal = (push_constant.model_matrix * vec4(v.normal, 1)).xyz;
  out_uv = vec2(v.uv_x, v.uv_y);
}
