
#version 450
#extension GL_EXT_buffer_reference : require

layout(location = 0) in vec4 inColor;
layout(location = 0) out vec4 outFragColor;

layout(set = 0, binding = 0) uniform sceneData {
  mat4 proj_view;
  float time;
} scene_data;

void main() {
  outFragColor = inColor;
}
