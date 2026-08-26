/**
 * shader_src.h：可视化全部 GLSL 源码（v2：多风格轮换 + 3D）。
 *
 * 架构不变式（用户确立）：vertex 仅画全屏三角形；全部视觉在 fragment
 * 逐像素解算——运算量只与像素数相关、与形态复杂度无关，参数驱动演化。
 *
 * v2 新增：三风格轮换（uT 驱动、每 ~26s 切换，反馈拖尾天然提供过渡余晖）：
 *  - 0 星云：氛围光 + Superformula 四花（Lissajous 漂移/参数演化）+
 *    螺旋带 + 扩散环 + 光斑（v1 全部遗产，additive）；
 *  - 1 晶体：raymarching 实时 3D——旋转 Superformula 双向旋转体 SDF，
 *    数值法线 + 漫反射/边缘光/深度雾，缓速双轴自转与尺寸呼吸；
 *  - 2 涡旋隧道：伪 3D 深度映射的管道格子流光。
 * 新增 uniform uRes（渲染分辨率）用于 3D 纵横比校正。
 */

#ifndef MUSICPLAYER_SHADER_SRC_H
#define MUSICPLAYER_SHADER_SRC_H

namespace {

const char* kVertSrc = R"(#version 300 es
layout(location = 0) in vec2 aPos;
out vec2 vUV;
void main() {
    vUV = aPos * 0.5 + 0.5;
    gl_Position = vec4(aPos, 0.0, 1.0);
}
)";

const char* kFragScene = R"(#version 300 es
precision highp float;
in vec2 vUV;
out vec4 outColor;
uniform float uT;
uniform float uSeed;
uniform vec2 uRes;
uniform float uBeat;    // 节拍包络 [0.25,1]（合成，种子派生 BPM）
uniform float uBass;    // 低频段能量 [0,1]
uniform float uTreble;  // 高频段能量 [0,1]
uniform float uPresetSel;  // 风格锁定号：-1 自动轮换，>=0 锁定该风格
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

mat2 rot2(float a) {
    float c = cos(a);
    float s = sin(a);
    return mat2(c, -s, s, c);
}

/** Superformula 一维半径 */
float superR(float ang, float m, float n1, float n2, float n3) {
    float t1 = pow(abs(cos(m * ang / 4.0)), n2);
    float t2 = pow(abs(sin(m * ang / 4.0)), n3);
    return pow(max(t1 + t2, 1e-4), -1.0 / n1);
}

/** 3D 星形体：经向(phi) x 纬向(theta) 双 Superformula 合成半径 */
float shapeR(vec3 dir, float m1, float n1a, float n2a, float n3a,
             float m2, float n1b, float n2b, float n3b) {
    float phi = atan(dir.z, dir.x);
    float theta = asin(clamp(-dir.y, -1.0, 1.0));
    return superR(phi, m1, n1a, n2a, n3a) * superR(theta, m2, n1b, n2b, n3b);
}

/** KIFS 分形 SDF：abs 折叠 + 坐标排序 + 旋转 + 缩放平移迭代 6 次，
 *  参数(缩放比/折叠角/偏置)不同即产生无穷自相似形态(Menger 类变体)。 */
float sdfKifs(vec3 p, float scaleK, float angK, vec3 offK) {
    float ca = cos(angK);
    float sa = sin(angK);
    for (int i = 0; i < 6; i++) {
        p = abs(p);
        if (p.x < p.y) { float tmp = p.x; p.x = p.y; p.y = tmp; }
        if (p.x < p.z) { float tmp = p.x; p.x = p.z; p.z = tmp; }
        if (p.y < p.z) { float tmp = p.y; p.y = p.z; p.z = tmp; }
        float rx = ca * p.x - sa * p.y;
        float ry = sa * p.x + ca * p.y;
        p.x = rx;
        p.y = ry;
        p = p * scaleK - offK * (scaleK - 1.0);
    }
    vec3 qb = abs(p) - vec3(0.9);
    return (length(max(qb, 0.0)) + min(max(qb.x, max(qb.y, qb.z)), 0.0)) * pow(scaleK, -6.0);
}

/** 峡谷 SDF：场缓旋 + z 向域重复平铺（每胞 hash 出 KIFS 分形参数/偏置）∩ 中心管道外。
 *  管道半径 0.55 保证相机走廊畅通——两侧分形结构掠过。 */
float sdfCanyon(vec3 w, mat2 ry, mat2 rx, float rep, float seed, float t) {
    vec3 pp = w;
    pp.xz = ry * pp.xz;
    pp.yz = rx * pp.yz;
    float zc = floor(pp.z / rep);
    vec3 pq = pp;
    pq.z = pp.z - (zc + 0.5) * rep;
    float hid = hash(zc * 17.31 + seed * 0.013);
    float scaleK = 1.55 + 0.75 * hash(zc * 23.7 + seed);
    float angK = 0.35 + 0.85 * hash(zc * 37.3 + seed);
    vec3 offK = vec3(1.0 + 1.6 * hash(zc * 41.1 + seed),
        0.6 + 1.2 * hash(zc * 53.9 + seed),
        0.4 + 0.8 * hash(zc * 61.3 + seed));
    float size = 0.34 + 0.20 * hash(zc * 71.7 + seed);
    float side = hid > 0.5 ? 1.0 : -1.0;
    vec2 lateral = vec2(side * (0.82 + 0.3 * hash(zc * 11.7 + seed)),
        (hash(zc * 13.1 + seed) - 0.5) * 0.9);
    pq.xy -= lateral;
    float dFrac = sdfKifs(pq / size, scaleK, angK, offK) * size;
    float dTube = length(pp.xy) - 0.55;
    return max(dFrac, dTube) * 0.6;
}

void main() {
    float t = uT;
    float seed = uSeed;
    vec2 p = vUV;
    float aspect = uRes.x / max(uRes.y, 1.0);

    // ---- 反馈拖尾：逐像素 domain warp + 衰减 + 底色兜底 ----
    vec2 warped = p + 0.0022 * vec2(
        sin(p.y * 26.0 + t * 0.0011 + seed),
        cos(p.x * 22.0 - t * 0.0009 + seed * 0.7));
    vec3 col = texture(uPrev, warped).rgb;
    col = col * 0.86 + vec3(0.05, 0.047, 0.043) * 0.14;

    float hue0 = fract(t * 0.000018 + hash(seed) * 3.0) * 360.0;

    // ---- 风格轮换：26s each，seed 决定起点；uPresetSel>=0 时锁定（点击切换） ----
    float cyc = mod(t / 26000.0 + hash(seed) * 11.0, 8.0);
    int preset = uPresetSel >= 0.0 ? int(uPresetSel) : int(floor(cyc));

    if (preset == 0) {
        // ===== 流动星野：相机匀速前行（方向缓旋），花域在世界空间平铺掠过 =====
        vec2 center = vec2(0.5, 0.47);
        vec2 sp = (p - center) * vec2(aspect, 1.0);
        // 向内深入：周期 zoom 涌出（每轮换世界原点，回绕即进入新星空区域）
        float rndS = floor(t / 40000.0);
        float zfS = exp(fract(t / 40000.0) * 3.4);
        vec2 woff = vec2(hash(rndS * 7.7 + seed), hash(rndS * 13.1 + seed)) * 29.0;
        vec2 drift2 = vec2(cos(t * 0.0002), sin(t * 0.00016)) * 0.05;
        vec2 wp = sp * zfS + woff + drift2;            // 世界坐标
        // 氛围光（屏幕空间，恒居中）
        {
            float g = smoothstep(0.95, 0.0, length(sp));
            col += hsl2rgb(hue0, 0.75, 0.10) * g * g * 0.22;
        }
        // 平铺花域：世界网格每 cell 一朵（hash 决定形态/相位），3x3 邻域
        vec2 cellSz = vec2(1.05, 0.72);
        vec2 base = floor(wp / cellSz);
        for (int cy = -1; cy <= 1; cy++) {
            for (int cx = -1; cx <= 1; cx++) {
                vec2 gidx = base + vec2(float(cx), float(cy));
                float hid = hash2(gidx + seed * 0.017);
                // cell 内星点（世界空间固定 hash 位，随行进掠过；空 cell 也留星）
                vec2 starPos = (gidx + vec2(hash2(gidx + 7.7), hash2(gidx + 3.3))) * cellSz;
                float ds = length(wp - starPos);
                float sflare = 0.5 + 0.5 * sin(t * 0.002 + hid * 40.0);
                float shue = fract(t * 0.000012 + hid * 5.0) * 360.0;
                col += hsl2rgb(shue, 0.8, 0.55) * exp(-ds * ds * 5200.0)
                    * sflare * (0.06 + 0.05 * uTreble);
                if (hid < 0.30) {
                    continue;   // 空 cell：星野有疏密（只有星点）
                }
                vec2 gpos = (gidx + 0.5) / cellSz;     // cell 中心(世界)
                // cell 内小幅 Lissajous 游动
                vec2 jig = 0.10 * vec2(
                    sin(t * (0.0005 + hid * 0.0011) + hid * 43.0),
                    cos(t * (0.0006 + hid * 0.0009) + hid * 77.0));
                vec2 d2 = wp - (gpos * cellSz + jig * cellSz);
                float rank = length(d2);
                float rth = atan(d2.y, d2.x);
                float m = 1.5 + 5.5 * styleParam(10.0 + hid * 40.0, t, 0.0, 1.0, seed);
                float n1 = 0.7 + 0.7 * styleParam(20.0 + hid * 40.0, t, 0.0, 1.0, seed);
                float n2 = 0.3 + 1.7 * styleParam(30.0 + hid * 40.0, t, 0.0, 1.0, seed);
                float n3 = 0.3 + 1.7 * styleParam(40.0 + hid * 40.0, t, 0.0, 1.0, seed);
                float rot = t * (0.00008 + 0.00022 * styleParam(50.0 + hid * 40.0, t, 0.0, 1.0, seed));
                float ca = cos(m * (rth + rot) / 4.0);
                float sa = sin(m * (rth + rot) / 4.0);
                float denom = pow(abs(ca), n2) + pow(abs(sa), n3);
                float rSurf = 0.13 / pow(max(denom, 0.25), 1.0 / n1)
                    * (0.92 + 0.13 * uBeat + 0.06 * uBass);
                float edge = exp(-abs(rank - rSurf) * 42.0);
                float core = exp(-rank * rank * 180.0);
                float hue = fract(t * 0.02 + seed * 0.001 + hid * 0.61) * 360.0;
                vec3 c = hsl2rgb(hue, 0.85, 0.55);
                col += c * (edge * (0.11 + 0.05 * uBeat) + core * 0.02);
            }
        }
        // 螺旋流带（世界角度推进）
        {
            float wang = atan(wp.y, wp.x);
            float wrr = length(wp);
            for (int s2 = 0; s2 < 2; s2++) {
                float fs = float(s2);
                float ph = wang + wrr * 9.0 - t * 0.00035 - fs * 2.6;
                float d = abs(fract(ph / 6.2832) - 0.5) * 6.2832;
                float band = exp(-d * d * 3.5) * exp(-(wrr - 0.26) * (wrr - 0.26) * 6.0);
                float hueb = fract(t * 0.000016 + seed * 0.001 + fs * 0.36) * 360.0;
                col += hsl2rgb(hueb, 0.85, 0.55) * band * 0.10;
            }
        }
    } else if (preset == 1) {
        // ===== 穿越晶体峡谷：相机沿 z 匀速前行(蛇形)，晶体场域重复平铺 =====
        vec2 q = (p - vec2(0.5, 0.47)) * vec2(aspect, 1.0);
        float rep = 1.7;                               // z 向晶胞间距
        float zt = t * 0.55;                           // 前行距离
        vec3 ro = vec3(sin(t * 0.00019) * 0.30, cos(t * 0.00015) * 0.24, -zt);
        vec3 rd = normalize(vec3(q, 1.7));
        mat2 ry = rot2(t * 0.00018);
        mat2 rx = rot2(t * 0.00011);
        float tt = 0.10 + 0.05 * hash2(gl_FragCoord.xy * 0.37);
        float nearest = 1e9;
        float hitT = -1.0;
        // SDF：世界 -> 场缓旋 -> z 平铺取胞内最近晶体 -> 与中心管道求交
        // （管道半径 0.55 保证相机走廊畅通，两侧晶体掠过）
        for (int i = 0; i < 46; i++) {
            vec3 pos = ro + rd * tt;
            float d = sdfCanyon(pos, ry, rx, rep, seed, t);
            nearest = min(nearest, abs(d));
            if (d < 0.0016) {
                hitT = tt;
                break;
            }
            tt += max(d * 0.42, 0.010);
            if (tt > 5.0) {
                break;
            }
        }
        float useT = hitT > 0.0 ? hitT : min(tt, 4.2);
        float pixW = useT * 2.2 / max(uRes.y, 1.0);
        float cover = hitT > 0.0 ? 1.0 : exp(-nearest / max(pixW, 1e-5) * 1.1);
        if (cover > 0.004) {
            float tv = hitT > 0.0 ? hitT : useT;
            vec3 pos = ro + rd * tv;
            float e = max(tv * 1.6 / max(uRes.y, 1.0), 0.0025);
            float sX = sdfCanyon(pos + vec3(e, 0.0, 0.0), ry, rx, rep, seed, t)
                - sdfCanyon(pos - vec3(e, 0.0, 0.0), ry, rx, rep, seed, t);
            float sY = sdfCanyon(pos + vec3(0.0, e, 0.0), ry, rx, rep, seed, t)
                - sdfCanyon(pos - vec3(0.0, e, 0.0), ry, rx, rep, seed, t);
            float sZ = sdfCanyon(pos + vec3(0.0, 0.0, e), ry, rx, rep, seed, t)
                - sdfCanyon(pos - vec3(0.0, 0.0, e), ry, rx, rep, seed, t);
            vec3 n = normalize(vec3(sX, sY, sZ));
            vec3 ld = normalize(vec3(0.5 + 0.35 * sin(t * 0.00022), 0.55, -0.62));
            float dif = clamp(dot(n, ld), 0.0, 1.0);
            float rim = pow(1.0 - abs(dot(n, -rd)), 2.2);
            float faceHue = mod(t * 0.014 + seed * 0.001 + n.y * 40.0 + n.x * 25.0, 360.0);
            vec3 base = hsl2rgb(faceHue, 0.78, 0.46);
            vec3 lit = base * (0.16 + 0.84 * dif * (0.85 + 0.3 * uBass))
                + hsl2rgb(mod(faceHue + 55.0, 360.0), 0.85, 0.6) * rim * (0.45 + 0.35 * uBeat);
            float fade = exp(-(max(tv - 1.9, 0.0)) * 0.85);
            col = mix(col, lit, clamp(0.80 * cover * (0.35 + 0.65 * fade), 0.0, 1.0));
        }
        // 前方深处辉光（行进目的地感）
        col += hsl2rgb(fract(t * 0.00002 + hash(seed + 91.0)) * 360.0, 0.7, 0.10)
            * exp(-dot(q, q) * 7.0) * 0.16;
    } else if (preset == 2) {
        // ===== Julia 之海：c 沿指数螺线漫游(形态无穷变形) + 缓慢变焦漂移 =====
        vec2 q = (p - vec2(0.5, 0.47)) * vec2(aspect, 1.0);
        float theta = t * 0.00009 + floor(t / 20000.0) * 0.37 + seed * 0.017;
        float radius = 0.7885 * (0.97 + 0.05 * sin(t * 0.00013 + seed));
        vec2 cJulia = vec2(cos(theta), sin(theta)) * radius;
        // 向内深入：周期深潜（每轮 c 相位步进，回绕即进入新形态层）
        float rndJ = floor(t / 20000.0);
        float zfJ = exp(fract(t / 20000.0) * 2.6);
        vec2 zj = q * zfJ * 0.30;
        float esc = 0.0;
        float mIter = 0.0;
        for (int ij = 0; ij < 48; ij++) {
            zj = vec2(zj.x * zj.x - zj.y * zj.y, 2.0 * zj.x * zj.y) + cJulia;
            float dj = dot(zj, zj);
            mIter += 1.0;
            if (dj > 16.0) {
                esc = 1.0;
                break;
            }
        }
        if (esc > 0.5) {
            float nu = mIter - log2(log2(max(dot(zj, zj), 1.0001))) + 4.0;
            float hueJ = fract(nu * 0.045 + t * 0.00001 + hash(seed + 0.3)) * 360.0;
            float glowJ = exp(-mIter * 0.045);
            col += hsl2rgb(hueJ, 0.85, 0.42 + 0.18 * uBeat)
                * (0.05 + nu * 0.0024 + glowJ * 0.5) * (0.8 + 0.4 * uBass);
        } else {
            col += hsl2rgb(fract(t * 0.00002 + 0.55) * 360.0, 0.6, 0.16)
                * (0.10 + 0.08 * uBass);
        }
    } else if (preset == 3) {
        // ===== 涡旋隧道：伪 3D 深度管道（弯道 + 提速）=====
        vec2 q0 = (p - vec2(0.5, 0.47)) * vec2(aspect, 1.0);
        float rad0 = max(length(q0), 0.045);
        // 先按初始深度估弯曲偏移，再二次求角/径（管道转弯的视觉近似）
        float dEst = 0.22 / rad0 + t * 0.00085;
        vec2 curve = 0.20 * vec2(sin(dEst * 0.20 + t * 0.0003), cos(dEst * 0.16 + seed));
        vec2 q = q0 + curve;
        float ang = atan(q.y, q.x);
        float rad = max(length(q), 0.045);
        float depth = 0.22 / rad + t * 0.00085;
        float sway = 0.05 * sin(t * 0.00019 + seed);
        float aa = ang + sway + 0.14 * sin(depth * 1.7 + t * 0.00021);
        // 网格坐标：周向 6 格 x 深度向流动
        vec2 grid = vec2(aa * 0.955, depth);
        vec2 gvf = fract(grid);
        vec2 gid = floor(grid);
        float lineU = abs(gvf.x - 0.5);
        float lineV = abs(gvf.y - 0.5);
        float glowLine = exp(-lineU * lineU * 90.0) + exp(-lineV * lineV * 26.0);
        float cellId = hash(gid.x * 13.7 + gid.y * 31.1 + seed);
        float blink = step(0.35, cellId) * (0.4 + 0.6 * cellId)
            * (0.5 + 0.5 * sin(t * 0.002 + cellId * 40.0))
            * (0.72 + 0.42 * uBeat);
        float depthFade = clamp(rad * 2.6, 0.0, 1.0);
        float hue = mod(t * 0.000014 + seed * 0.001 + gid.y * 11.0 + gid.x * 5.0, 360.0);
        col += hsl2rgb(hue, 0.82, 0.52) * glowLine * blink * depthFade * 0.34;
        // 中心深处辉光
        col += hsl2rgb(mod(hue + 43.0, 360.0), 0.7, 0.42)
            * exp(-rad * rad * 26.0) * (0.08 + 0.05 * uBass + 0.03 * uBeat);
    } else if (preset == 4) {
        // ===== Mandelbrot 深潜：兴趣点持续放大（限精度域内呼吸重置）=====
        vec2 q = (p - vec2(0.5, 0.47)) * vec2(aspect, 1.0);
        // 兴趣点按 seed 三选一：海马谷/大象谷/双螺旋（经典边界富集区）
        vec2 poi[3];
        poi[0] = vec2(-0.743643887037151, 0.131825904205330);
        poi[1] = vec2(0.286931868895045, 0.014286693904085);
        poi[2] = vec2(-0.16, 1.0405);
        vec2 poiSel = poi[int(mod(seed, 3.0))];
        // 向内深入：周期深潜（每轮兴趣点向边界邻域微移，层层进入新结构）
        float rndM = floor(t / 16000.0);
        float zfM = 0.34 * exp(fract(t / 16000.0) * 4.1);
        vec2 poiOff = vec2(hash(rndM * 5.3 + seed), hash(rndM * 9.7 + seed)) - 0.5;
        vec2 z0 = poiSel + poiOff * 0.004 + q * zfM;
        float mIt = 0.0;
        float esc = 0.0;
        vec2 zm = vec2(0.0, 0.0);
        for (int im = 0; im < 60; im++) {
            zm = vec2(zm.x * zm.x - zm.y * zm.y, 2.0 * zm.x * zm.y) + z0;
            float dm = dot(zm, zm);
            mIt += 1.0;
            if (dm > 16.0) { esc = 1.0; break; }
        }
        if (esc > 0.5) {
            float nu = mIt - log2(log2(max(dot(zm, zm), 1.0001))) + 4.0;
            float hueM = fract(nu * 0.03 + t * 0.000008 + hash(seed + 0.7)) * 360.0;
            col += hsl2rgb(hueM, 0.85, 0.42 + 0.15 * uBeat) * (0.04 + nu * 0.0022) * (0.8 + 0.4 * uBass);
        } else {
            col += hsl2rgb(fract(t * 0.00003) * 360.0, 0.7, 0.10) * 0.20;
        }
    } else if (preset == 5) {
        // ===== 极光幕：三层视差帘幕漂移 + 星空底 =====
        vec2 q = (p - vec2(0.5, 0.47)) * vec2(aspect, 1.0);
        for (int la = 0; la < 3; la++) {
            float fl = float(la);
            // 向内深入：层相位连续推进——帘幕道道向后掠过(每道参数随轮次更替,生入死出)
            float phA = t * 0.00019 + fl * 1.9 + seed * 0.01;
            float la_ = floor(phA);
            float frA = fract(phA);
            float hA = hash(la_ * 7.1 + fl * 13.3 + seed);
            float envA = smoothstep(0.0, 0.2, frA) * smoothstep(1.0, 0.8, frA);
            float depth = 1.0 + fl * 0.75;
            float xw = q.x * (2.2 + fl * 0.7) + hA * 43.0 + t * 0.00012;
            float ridge = 0.34 + 0.16 * fl + hA * 0.12
                + 0.06 * sin(xw * 2.1 + t * 0.0003)
                + 0.04 * sin(xw * 4.7 - t * 0.00021);
            float drape = exp(-abs(q.y - ridge) * (9.0 - fl * 2.0)) * (1.0 - q.y * 0.45);
            float flick = 0.7 + 0.3 * sin(xw * 9.0 + t * 0.0011 + fl * 2.0);
            float hueA = 120.0 + 55.0 * fl + hA * 30.0 + 18.0 * sin(t * 0.00016 + fl);
            col += hsl2rgb(hueA, 0.85, 0.42 + 0.10 * uBass) * drape * flick * envA
                * (0.34 - fl * 0.06) * (0.85 + 0.3 * uBeat);
        }
        // 星空底：星点随周期 zoom 向外涌出（=向屏幕内部深入）
        {
            float zfA = exp(fract(t / 12000.0) * 2.2);
            vec2 qa = q * zfA;
            vec2 sc = floor(qa * 26.0);
            float sid = hash2(sc + seed);
            if (sid > 0.93) {
                vec2 spos = (sc + 0.5) / 26.0;
                col += vec3(0.7, 0.75, 0.8) * exp(-dot(qa - spos, qa - spos) * 4200.0)
                    * (0.4 + 0.6 * sin(t * 0.003 + sid * 50.0)) * 0.30;
            }
        }
    } else if (preset == 6) {
        // ===== 万花筒：扇形镜像折叠 + 花域/光斑图案旋转 =====
        vec2 q = (p - vec2(0.5, 0.47)) * vec2(aspect, 1.0);
        float KSEG = 7.0;
        float angK = atan(q.y, q.x) + t * 0.00014;
        // 向内深入：径向 log 空间平移 = 图案向中心无限涌(e 倍自相似周期,无缝循环)
        float lr = log(max(length(q), 0.02)) + t * 0.00030;
        float ring = exp(fract(lr));
        float seg = mod(angK, 6.2831853 / KSEG);
        seg = abs(seg - 3.1415927 / KSEG);            // 镜像折叠
        vec2 fq = vec2(cos(seg), sin(seg)) * ring;
        // 折叠坐标里画一朵 Superformula 花 + 双层光斑
        float mm = 2.0 + 5.0 * styleParam(80.0, t, 0.0, 1.0, seed);
        float n1k = 0.7 + 0.6 * styleParam(81.0, t, 0.0, 1.0, seed);
        float n2k = 0.3 + 1.7 * styleParam(82.0, t, 0.0, 1.0, seed);
        float n3k = 0.3 + 1.7 * styleParam(83.0, t, 0.0, 1.0, seed);
        float ca = cos(mm * seg / 4.0);
        float sa = sin(mm * seg / 4.0);
        float denom = pow(abs(ca), n2k) + pow(abs(sa), n3k);
        float rSurf = (1.25 + 0.55 * (0.5 + 0.5 * sin(t * 0.0005 + seed)))
            * pow(max(denom, 0.25), -1.0 / n1k) * 0.45
            * (0.92 + 0.13 * uBeat);
        float edge = exp(-abs(ring - rSurf) * 9.0);
        float hueW = fract(t * 0.016 + seed * 0.001 + ring * 0.8) * 360.0;
        col += hsl2rgb(hueW, 0.85, 0.55) * edge * (0.14 + 0.06 * uBeat);
        // 每周期近心端辉光环 + 径向珠链（随深入涌动）
        col += hsl2rgb(mod(hueW + 40.0, 360.0), 0.8, 0.45)
            * exp(-abs(ring - 1.0) * 4.0) * (0.10 + 0.08 * uBass);
        float beads = exp(-pow(sin(lr * 44.0) , 2.0) * 12.0)
            * smoothstep(1.0, 1.15, ring) * smoothstep(2.72, 2.5, ring);
        col += hsl2rgb(mod(hueW + 180.0, 360.0), 0.8, 0.5) * beads * (0.10 + 0.08 * uTreble);
    } else {
        // ===== 干涉波纹：四波源漂移干涉，径向外推行进 =====
        vec2 q = (p - vec2(0.5, 0.47)) * vec2(aspect, 1.0);
        float acc = 0.0;
        for (int wi = 0; wi < 4; wi++) {
            float fw = float(wi);
            // 向内深入：波源自中心深处诞生→向外漂移→消散,新源持续涌现
            float phW = t * 0.00021 + fw * 0.25 + hash(fw * 3.3 + seed);
            float gen = floor(phW);
            float life = fract(phW);
            vec2 src = vec2(hash(gen * 11.3 + fw * 7.7 + seed) - 0.5,
                hash(gen * 17.9 + fw * 3.1 + seed) - 0.5) * 0.16
                + vec2(cos(life * 3.1 + gen), sin(life * 2.7 + gen)) * life * 0.55;
            float dist = length(q - src);
            float envW = smoothstep(0.0, 0.18, life) * smoothstep(1.0, 0.75, life);
            acc += sin(dist * (34.0 - fw * 4.0) - t * 0.0019) * envW;
        }
        float ringI = (acc * 0.25 + 1.0) * 0.5;             // 0..1
        float v = pow(ringI, 3.0);
        float hueI = fract(t * 0.00002 + seed * 0.001 + v * 0.25) * 360.0;
        col += hsl2rgb(hueI, 0.85, 0.5) * v * (0.16 + 0.10 * uBeat);
        // 中心辉光
        col += hsl2rgb(mod(hueI + 60.0, 360.0), 0.75, 0.4)
            * exp(-dot(q, q) * 5.0) * (0.10 + 0.10 * uBass);
    }

    outColor = vec4(col, 1.0);
}
)";

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
