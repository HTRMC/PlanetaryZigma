#version 450
#extension GL_EXT_buffer_reference : require
layout(set = 0, binding = 0) uniform SceneData {
	mat4 view;
	mat4 proj;
	mat4 viewproj;
	vec4 ambientColor;
	vec4 sunlightDirection; //w for sun power
	vec4 sunlightColor;
} sceneData;

layout(location = 0) in  vec3 inPosition; 

//push constants block
layout(push_constant) uniform constants {
	mat4 render_matrix;
} PushConstants;

void main(){
  vec4 position = vec4(inPosition, 1.0f);
  gl_Position = sceneData.viewproj * PushConstants.render_matrix * position;
}
