
#version 450
layout(set = 0, binding = 0) uniform SceneData {
	mat4 view;
	mat4 proj;
	mat4 viewproj;
	vec4 ambientColor;
	vec4 sunlightDirection; //w for sun power
	vec4 sunlightColor;
} sceneData;

layout (location = 0) out vec4 outFragColor;

void main(){
  outFragColor = vec4(1,1,1,1);
}
