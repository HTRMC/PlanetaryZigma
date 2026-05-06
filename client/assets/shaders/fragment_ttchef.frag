
#version 450
#extension GL_EXT_buffer_reference : require

layout(location = 0) in vec3 inColor;
layout(location = 1) in vec2 inUv;
layout(location = 0) out vec4 outFragColor;

layout(set = 0, binding = 0) uniform sceneData {
  mat4 proj_view;
  float time;
} scene_data;

float sd_guy(in vec3 p) {
  float t = fract(scene_data.time);
  float y = 4.0 * t * (1.0 - t);
  vec3 cen = vec3(0.0, y, 0.0);
  return length(p - cen) - 0.25;
}

float map(in vec3 p) {
  float d1 = sd_guy(p);
  float d2 = p.y - (-0.25);
  return min(d1, d2);
}

vec3 calc_normal(in vec3 p) {
  vec2 e = vec2(0.0001, 0.0);
  return normalize(vec3(map(p + e.xyy) - map(p - e.xyy),
      map(p + e.yxy) - map(p - e.yxy),
      map(p + e.yyx) - map(p - e.yyx)));
}

float cast_ray(in vec3 ro, in vec3 rd) {
  float t = 0.0;
  for (int i = 0; i < 100; i++) {
    vec3 pos = ro + t * rd;
    float h = map(pos);
    if (h < 0.001) break;

    t += h;
    if (t > 20.0) break;
  }
  if (t > 20.0) t = -1.0;
  return t;
}

void main() {
  vec2 p = (inUv * 2.0 - 1.0);
  float an = scene_data.time;

  vec3 ta = vec3(0.0, 0.5, 0.0);
  vec3 ro = ta + vec3(1.5 * sin(an), 0.0, 1.5 * cos(an));

  vec3 ww = normalize(ta - ro);
  vec3 uu = normalize(cross(ww, vec3(0.0, 1.0, 0.0)));
  vec3 vv = normalize(cross(uu, ww));

  vec3 rd = normalize(p.x * uu + p.y * vv + 1.8 * ww);

  vec3 col = vec3(0.4, 0.75, 1.0) - 0.7 * rd.y;
  col = mix(col, vec3(0.7, 0.75, 0.8), exp(-10.0 * rd.y));

  float t = cast_ray(ro, rd);
  if (t > 0.0) {
    vec3 pos = ro + t * rd;
    vec3 nor = calc_normal(pos);

    vec3 mate = vec3(0.18);

    vec3 sun_dir = normalize(vec3(0.8, 0.4, 0.2));
    float sun_dif = clamp(dot(nor, sun_dir), 0.0, 1.0);
    float sun_sha = step(cast_ray(pos + nor * 0.001, sun_dir), 0.0);
    float sky_dif = clamp(0.5 + 0.5 * dot(nor, vec3(0.0, 1.0, 0.0)), 0.0, 1.0);
    float bou_dif = clamp(0.5 + 0.5 * dot(nor, vec3(0.0, -1.0, 0.0)), 0.0, 1.0);

    col = mate * vec3(7.0, 5.0, 4.0) * sun_dif * sun_sha;
    col += mate * vec3(0.5, 0.8, 0.9) * sky_dif;
    col += mate * vec3(0.7, 0.3, 0.2) * bou_dif;
  }

  col = pow(col, vec3(0.4545));

  outFragColor = vec4(col, 1.0);
}
