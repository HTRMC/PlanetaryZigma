#version 450

layout (location = 0) in vec3 inColor;
layout (location = 1) in vec2 inUv;

layout (set = 0, binding = 0) uniform sampler2D albedo_tex;

layout (location = 0) out vec4 outFragColor;

void main()
{
    vec4 texel = texture(albedo_tex, inUv);
    outFragColor = texel * vec4(inColor, 1.0);
}
