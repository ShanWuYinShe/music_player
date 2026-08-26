/**
 * shader_src.h：可视化全部 GLSL 源码。
 *
 * 设计要点（用户核心诉求：运算量固定、参数驱动、fragment 为主）：
 * - vertex 只铺一个全屏三角形（3 顶点），所有视觉在 fragment 逐像素解算，
 *   运算量只与像素数相关，与形态复杂度无关；
 * - 拖尾反馈：FBO 纹理 ping-pong，uPrev 采样时逐像素 domain warp 位移 +
 *   衰减——无分块、无接缝、无旋转矩形边缘（Canvas 时期全部伪影在 shader
 *   中从机制上不存在）；
 * - 视觉元素：氛围光、Superformula 花域(4 朵,Lissajous 漂移+参数演化)、
 *   螺旋光带、扩散弧环、漂浮光斑——全部是逐像素场函数，参数由 uT/uSeed
 *   连续驱动，数量与形态只改常数/表达式，不改变运算复杂度。
 */

#ifndef MUSICPLAYER_SHADER_SRC_H
#define MUSICPLAYER_SHADER_SRC_H

namespace {

// 全屏三角形 vertex：无任何几何工作，vUV 直接由顶点位置导出
const char* kVertSrc = R"(#version 300 es
layout(location = 0) in vec2 aPos;
out vec2 vUV;
void main() {
    vUV = aPos * 0.5 + 0.5;
    gl_Position = vec4(aPos, 0.0, 1.0);
}
)";

// pass A：反馈拖尾 + 全部场景元素，输出到 FBO 纹理
const char* kFragScene = R"(#version 300 es
precision highp float;
in vec2 vUV;
out vec4 outColor;
uniform float uT;
uniform float uSeed;
uniform sampler2D uPrev;

float hash(float n) { return fract(sin(n) * 43758.5453123); }
float hash2(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123); }

vec3 hsl2rgb(float h, float s, float l) {
    float hh = fract(h / 360.0) * 6.0;
    float c = (1.0 - abs(2.0 * l - 1.0)) * s;
    float x = c * (1.0 - abs(mod(hh, 2.0) - 1.0));
    float m = l - c * 0.5;
    vec3 rgb;
    if (hh < 1.0) { rgb = vec3(c, x, 0.0); }
    else if (hh < 2.0) { rgb = vec3(x, c, 0.0); }
    else if (hh < 3.0) { rgb = vec3(0.0, c, x); }
    else if (hh < 4.0) { rgb = vec3(0.0, x, c); }
    else if (hh < 5.0) { rgb = vec3(x, 0.0, c); }
    else { rgb = vec3(c, 0.0, x); }
    return rgb + m;
}

float styleParam(float id, float t, float lo, float hi, float seed) {
    float ph = t / 24000.0 + hash(seed + id * 131.0) * 64.0;
    float k = floor(ph);
    float f = ph - k;
    float s = f * f * (3.0 - 2.0 * f);
    float v0 = hash(seed + id * 101.0 + k * 7.0);
    float v1 = hash(seed + id * 101.0 + (k + 1.0) * 7.0);
    return lo + (hi - lo) * (v0 + (v1 - v0) * s);
}

void main() {
    float t = uT;
    float seed = uSeed;
    vec2 p = vUV;
    vec2 center = vec2(0.5, 0.47);
    vec2 dp = p - center;
    float rr = length(dp);
    float th = atan(dp.y, dp.x);

    // ---- 反馈拖尾：逐像素 domain warp + 衰减 + 底色兜底 ----
    float warpAmp = 0.012;
    vec2 warped = p + warpAmp * vec2(
        sin(p.y * 26.0 + t * 0.0011 + seed),
        cos(p.x * 22.0 - t * 0.0009 + seed * 0.7)) * 0.18;
    vec3 col = texture(uPrev, warped).rgb;
    col = col * 0.86 + vec3(0.05, 0.047, 0.043) * 0.14;

    // ---- 氛围光：中心柔和底色光晕（色相慢漂移）----
    float hue0 = fract(t * 0.000018 + hash(seed) * 3.0) * 360.0;
    {
        float g = smoothstep(0.95, 0.0, rr);
        col += hsl2rgb(hue0, 0.75, 0.10) * g * g * 0.22;
    }

    // ---- Superformula 花域 x4：Lissajous 漂移 + 参数演化，软边缘 ----
    for (int i = 0; i < 4; i++) {
        float fi = float(i);
        vec2 pc = vec2(
            0.5 + 0.30 * sin(t * (0.0007 + hash(seed + fi * 7.0 + 1.0) * 0.0016)
                + hash(seed + fi * 29.0 + 11.0) * 6.2832)
                + 0.08 * sin(t * (0.0016 + hash(seed + fi * 17.0 + 3.0) * 0.0022)
                + hash(seed + fi * 67.0 + 19.0) * 6.2832),
            0.47 + 0.26 * sin(t * (0.0006 + hash(seed + fi * 13.0 + 5.0) * 0.0013)
                + hash(seed + fi * 41.0 + 17.0) * 6.2832)
                + 0.07 * sin(t * (0.0014 + hash(seed + fi * 23.0 + 7.0) * 0.0018)
                + hash(seed + fi * 71.0 + 23.0) * 6.2832));
        vec2 d2 = p - pc;
        float rank = length(d2);
        float rth = atan(d2.y, d2.x);
        float m = 1.5 + 5.5 * styleParam(10.0 + fi, t, 0.0, 1.0, seed);
        float n1 = 0.7 + 0.7 * styleParam(20.0 + fi, t, 0.0, 1.0, seed);
        float n2 = 0.3 + 1.7 * styleParam(30.0 + fi, t, 0.0, 1.0, seed);
        float n3 = 0.3 + 1.7 * styleParam(40.0 + fi, t, 0.0, 1.0, seed);
        float rot = t * (0.00008 + 0.00022 * styleParam(50.0 + fi, t, 0.0, 1.0, seed));
        float ca = cos(m * (rth + rot) / 4.0);
        float sa = sin(m * (rth + rot) / 4.0);
        float denom = pow(abs(ca), n2) + pow(abs(sa), n3);
        // 浮点保护：denom 极小处钳制，避免个别像素尖突
        float rSurf = 0.13 / pow(max(denom, 0.25), 1.0 / n1);
        float edge = exp(-abs(rank - rSurf) * 42.0);
        float core = exp(-rank * rank * 180.0);
        float hue = fract((t * 0.02 + seed * 0.001 + fi * 0.13) ) * 360.0;
        vec3 c = hsl2rgb(hue, 0.85, 0.55);
        col += c * (edge * 0.11 + core * 0.015);
    }

    // ---- 螺旋光带 x2：对数螺旋，软带，色相各自流动 ----
    for (int s2 = 0; s2 < 2; s2++) {
        float fs = float(s2);
        float speed = 0.00010 + 0.00010 * fs;
        float ph = th + rr * 9.0 - t * speed - fs * 2.6;
        float d = abs(fract(ph / 6.2832) - 0.5) * 6.2832;
        float band = exp(-d * d * 3.5) * exp(-(rr - 0.26) * (rr - 0.26) * 6.0);
        float hue = fract(t * 0.000016 + seed * 0.001 + fs * 0.36) * 360.0;
        col += hsl2rgb(hue, 0.85, 0.55) * band * 0.10;
    }

    // ---- 扩散弧环 x3：由内向外推移并淡出 ----
    for (int q = 0; q < 3; q++) {
        float fq = float(q);
        float prog = fract(t * 0.00022 + fq / 3.0 + seed * 0.01);
        float rad = 0.16 + 0.72 * prog;
        float ring = exp(-pow((rr - rad) * 40.0, 2.0)) * (1.0 - prog);
        float hue = fract(t * 0.000012 + seed * 0.001 + fq * 0.25) * 360.0;
        col += hsl2rgb(hue, 0.8, 0.5) * ring * 0.07;
    }

    // ---- 漂浮光斑：网格 cell 内亮点，闪烁+色环流动 ----
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            vec2 cell = floor(p * 9.0) + vec2(float(dx), float(dy));
            float id = hash2(cell + seed);
            if (id < 0.62) {
                continue;
            }
            vec2 pos = (cell + 0.5) / 9.0;
            float d = length(p - pos);
            float rad = 0.004 + 0.006 * hash2(vec2(cell.x, 7.0));
            if (d > rad * 2.0) {
                continue;
            }
            float flare = 0.55 + 0.45 * sin(t * 0.002 + id * 40.0);
            float hue = fract(t * 0.000012 + id * 5.0) * 360.0;
            float a = exp(-(d * d) / (rad * rad)) * flare;
            col += hsl2rgb(hue, 0.8, 0.5) * a * 0.08;
        }
    }

    outColor = vec4(col, 1.0);
}
)";

// pass B：FBO 反馈帧直出屏幕
const char* kFragBlit = R"(#version 300 es
precision highp float;
in vec2 vUV;
out vec4 outColor;
uniform sampler2D uTex;
void main() {
    outColor = texture(uTex, vUV);
}
)";

}  // namespace

#endif  // MUSICPLAYER_SHADER_SRC_H
