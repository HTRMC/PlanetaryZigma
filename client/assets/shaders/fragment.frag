
#version 450
#extension GL_EXT_buffer_reference : require

layout(location = 0) in vec4 inColor;
layout(location = 1) in vec2 inUV;
layout(location = 0) out vec4 outFragColor;

layout(set = 0, binding = 0) uniform sceneData {
  mat4 proj_view;
  float time;
} scene_data;

layout(set = 1, binding = 0) uniform sampler2D texSampler;

void main() {
  outFragColor = texture(texSampler, inUV);
  // outFragColor = inColor;
}
