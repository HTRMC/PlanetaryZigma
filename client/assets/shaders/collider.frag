
#version 450
layout(set = 0, binding = 0) uniform SceneData {
	mat4 view;
	mat4 proj;
	mat4 viewproj;
	vec4 ambientColor;
	vec4 sunlightDirection; //w for sun power
	vec4 sunlightColor;
} sceneData;

// Fragment shader
layout(location = 0) flat in uint inColor;

layout(location = 0) out vec4 outFragColor;

void main() {
    // Unpack RGBA8 from uint (0xAABBGGRR format)
    vec4 color = unpackUnorm4x8(inColor);
    
    outFragColor = color;
}
