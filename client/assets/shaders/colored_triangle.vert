#version 450

layout (location = 0) out vec3 outColor;
layout (location = 1) out vec2 outUv;

struct Vertex {
    vec4 position;
    vec4 color;
    vec4 uv;
};

layout (set = 0, binding = 0) readonly buffer VertexBuffer {
    Vertex vertices[];
};

void main()
{
    Vertex v = vertices[gl_VertexIndex];
    gl_Position = v.position;
    outColor = v.color.xyz;
    outUv = v.uv.xy;
}
