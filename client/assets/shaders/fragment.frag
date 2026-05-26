
#version 450
#extension GL_EXT_buffer_reference : require

layout(location = 0) in vec4 inColor;
layout(location = 1) in vec2 inUV;
layout(location = 2) in vec3 inNormal;
layout(location = 0) out vec4 outFragColor;

layout(set = 0, binding = 0) uniform sceneData {
  mat4 proj_view;
  vec3 global_light_direction;
  float time;
} scene_data;

layout(set = 1, binding = 0) uniform sampler2D texSampler;

void main() {
  float diff = max(dot(normalize(inNormal), normalize(scene_data.global_light_direction)), 0.2);
  // outFragColor = vec4(texture(texSampler, inUV).xyz * diff, 1);
  outFragColor = inColor;
}
