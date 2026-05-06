// vertex.glsl
#version 450
#extension GL_EXT_buffer_reference : require

layout(set = 0, binding = 0) uniform sceneData {
  mat4 proj_view;
  float time;
} scene_data;

struct Vertex {
  vec3 position;
  float uv_x;
  vec3 normal;
  float uv_y;
  vec4 color;
};

layout(buffer_reference, std430) readonly buffer VertexBuffer {
  Vertex vertices[];
};

layout(push_constant, std430) uniform pc {
  mat4 model_matrix;
  VertexBuffer vertexBuffer;
} PushConstant;

layout(location = 0) out vec4 fragColor;

void main() {
  Vertex v = PushConstant.vertexBuffer.vertices[gl_VertexIndex];
  float time = scene_data.time;
  float x = v.position.x;
  float y = v.position.y;
  float z = v.position.z;
  gl_Position = scene_data.proj_view * PushConstant.model_matrix * vec4(x, y, z, 1.0);
  // gl_Position = scene_data.proj_view * vec4(x, y, z, 1.0);

  // vec3 uv = vec3(v.uv_x, v.uv_y, v.uv_x);
  // vec3 col = 0.5 + 0.5 * cos(gl_Position.y * scene_data.time + v.uv_x + vec3(0, 2, 4));
  // vec3 col = vec3(0, 0, 1);

  // float red = (y > 0) ? 1 : 0;
  // vec3 col = vec3(red, 0, 0);

  // fragColor = vec4(col, 1);
  fragColor = vec4(v.color);
}
