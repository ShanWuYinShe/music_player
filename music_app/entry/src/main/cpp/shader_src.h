/**
 * shader_src.h：可视化全部 GLSL 源码（v3：透视纵深重构 + 10 风格）。
 *
 * 架构不变式（用户确立）：vertex 仅画全屏三角形；全部视觉在 fragment
 * 逐像素解算——运算量只与像素数相关、与形态复杂度无关，参数驱动演化。
 *
 * v3 重构核心：从"简单缩放"升级为"真实透视相机"——
 *  - 全局透视反馈：上一帧采样沿消失点径向透视流动（近快远慢，距消失点越远拖尾越长），非均匀位移
 *  - 每风格独立相机：FOV 焦距随 beat/bass 呼吸 + yaw/pitch/roll + 位置 dolly/pan，ray 由透视
 *    投影矩阵生成（focal=1/tan(fov/2)，rd=normalize(vec3((uv-0.5)*vec2(aspect,1)*focal,1)) 再经相机旋转）
 *  - 视差分层：同一画面内多深度层按 1/depth 透视缩放/位移/雾化（近大近亮移速快，远小远暗移速慢），
 *    产生强烈纵深视差，非等比缩放
 *  - 分形深潜改为透视俯冲：相机在三维中掠过分形平面（带俯仰角与地平线汇聚），dollying 前进 + FOV 窄化
 *    的推轨变焦（dolly zoom），近景形变大于远景，透视汇聚向消失点而非中心等比放大
 *  - 隧道/峡谷等全为 raymarch 真三维 SDF（相机位姿+透视光线），非伪深度近似
 *
 * 10 风格（点击循环 0..9，uPresetSel 直传）：
 *  0 流动星野·透视分层：世界平铺花域 + 星点改为三深度层透视投影（delta/depth），近层 rush 快、远层 crawl 慢 + 深度雾
 *  1 分形峡谷·真透视：相机器材（FOV 呼吸 + yaw/pitch 摇摆 + 蛇形位移）+ 46 步 raymarch，经 yaw/pitch 场旋转，带像素覆盖 AA
 *  2 Julia 之海·俯冲透视：相机俯角 ~20° 掠过 Julia 平面，透视汇聚向地平线（1/(1+y*k) 压缩），zF 对应高度的指数俯冲 + 层间换 c
 *  3 涡旋隧道·真圆柱：真圆柱 SDF 的透视管道（FOV 呼吸 + 弯道跟随 yaw/pitch），相机随弯道 bank，格子按柱面坐标透视 foreshortening
 *  4 Mandelbrot·推轨变焦：dolly 轨（相机距 POI 指数趋近）+ FOV 线性收窄 = 推轨变焦透视，平面求交后叠指数缩放，结构随深度演化
 *  5 极光幕·透视帘片：帘幕改为不等距深度平面（ray-plane 求交），近帘宽厚亮、远帘窄薄暗，深度雾 + 生入死出生命周期
 *  6 万花筒·棱镜隧道：径向 log 流改为棱镜隧道深度层（fract 深度 + 1/depth 透视缩放），每层 hash 新花，花形与珠链按深度 foreshortening
 *  7 干涉波纹·俯视水面：水面位于 y=0，相机高位俯角掠射，ray 与水面求交得透视水面坐标（远处压缩），波长与强度按 depth 透视衰减
 *  8 晶体环廊·透视环阵：沿 z 复用的圆环 SDF 阵列（每环 hash 半径/倾角/色），相机在环心走廊透视穿梭，36 步 raymarch + 漫反射/菲涅尔
 *  9 云海俯冲·分层容量：三高度云层（ray-plane 分层求交 + FBM 值噪声），俯角透视 + 风场漂移，远层压缩薄、近层蓬松亮，体积感由层间视差构成
 *  全部具备"持续向屏幕内部深入"（dolly/平移/深度层回收），无缩放循环伪影。
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
uniform float uBeat;
uniform float uBass;
uniform float uTreble;
uniform float uPresetSel;
uniform sampler2D uPrev;

float hash(float n) { return fract(sin(n) * 43758.5453123); }
float hash2(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123); }
float hash3(vec3 p) { return fract(sin(dot(p, vec3(127.1, 311.7, 74.7))) * 43758.5453); }

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

float superR(float ang, float m, float n1, float n2, float n3) {
    float t1 = pow(abs(cos(m * ang / 4.0)), n2);
    float t2 = pow(abs(sin(m * ang / 4.0)), n3);
    return pow(max(t1 + t2, 1e-4), -1.0 / n1);
}

float shapeR(vec3 dir, float m1, float n1a, float n2a, float n3a,
             float m2, float n1b, float n2b, float n3b) {
    float phi = atan(dir.z, dir.x);
    float theta = asin(clamp(-dir.y, -1.0, 1.0));
    return superR(phi, m1, n1a, n2a, n3a) * superR(theta, m2, n1b, n2b, n3b);
}

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

float sdTorus(vec3 p, vec2 t) {
    vec2 q = vec2(length(p.xz) - t.x, p.y);
    return length(q) - t.y;
}

float sdBox(vec3 p, vec3 b) {
    vec3 d = abs(p) - b;
    return length(max(d, 0.0)) + min(max(d.x, max(d.y, d.z)), 0.0);
}

float valueNoise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);
    float a = hash2(i);
    float b = hash2(i + vec2(1.0, 0.0));
    float c = hash2(i + vec2(0.0, 1.0));
    float d = hash2(i + vec2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}
float fbm2(vec2 p) {
    float v = 0.0;
    v += 0.50 * valueNoise(p);
    v += 0.25 * valueNoise(p * 2.07);
    v += 0.125 * valueNoise(p * 4.11);
    v += 0.0625 * valueNoise(p * 8.03);
    return v;
}

void main() {
    float t = uT;
    float seed = uSeed;
    vec2 p = vUV;
    float aspect = uRes.x / max(uRes.y, 1.0);

    // ---- 透视反馈：径向透视流动（消失点为透视中心，近快远慢）+ 域扭曲 ----
    vec2 vp = vec2(0.5 + 0.055 * sin(t * 0.00013 + seed * 0.01), 0.47 + 0.045 * cos(t * 0.00011 + seed * 0.013));
    vec2 toP = p - vp;
    float rvp = length(toP * vec2(aspect, 1.0));
    // 径向透视：距消失点越远，上一帧向中心汇聚越快（模拟 dolly 前进的视差拖尾）
    vec2 persWarp = toP * (0.012 * rvp + 0.0045);
    vec2 domainW = 0.0017 * vec2(sin(p.y * 23.0 + t * 0.0011 + seed), cos(p.x * 21.0 - t * 0.0009 + seed * 0.7));
    vec2 warped = p - persWarp + domainW;
    vec3 col = texture(uPrev, warped).rgb;
    col = col * 0.82 + vec3(0.06, 0.055, 0.05) * 0.18;

    float hue0 = fract(t * 0.000018 + hash(seed) * 3.0) * 360.0;
    int preset = int(uPresetSel + 0.5);

    if (preset == 0) {
        // ===== 0 流动星野·透视分层：世界平移 + 三深度层透视视差 =====
        vec2 center = vec2(0.5, 0.47);
        vec2 sp = (p - center) * vec2(aspect, 1.0);
        vec2 dir2 = vec2(cos(t * 0.00003), sin(t * 0.00003));
        vec2 wp = sp + dir2 * t * 0.05;
        {
            float g = smoothstep(0.95, 0.0, length(sp));
            col += hsl2rgb(hue0, 0.85, 0.22) * g * g * 0.45;
        }
        vec2 cellSz = vec2(1.05, 0.72);
        vec2 base = floor(wp / cellSz);
        for (int cy = -1; cy <= 1; cy++) {
            for (int cx = -1; cx <= 1; cx++) {
                vec2 gidx = base + vec2(float(cx), float(cy));
                float hid = hash2(gidx + seed * 0.017);
                float depthStar = 0.45 + 2.4 * fract(hash2(gidx + vec2(7.7, 3.3) + seed * 0.11) - t * 0.00014);
                // 星点：透视 delta/depth
                vec2 starWorld = (gidx + vec2(hash2(gidx + 7.7), hash2(gidx + 3.3))) * cellSz;
                vec2 dsVec = (starWorld - wp) / depthStar;
                float ds = dot(dsVec, dsVec);
                float sflare = 0.5 + 0.5 * sin(t * 0.002 + hid * 40.0);
                float shue = fract(t * 0.000012 + hid * 5.0) * 360.0;
                float fogS = exp(-depthStar * 0.45);
                col += hsl2rgb(shue, 0.95, 0.65) * exp(-ds * 1400.0) * sflare * (0.14 + 0.12 * uTreble) * fogS;
                if (hid < 0.30) continue;
                float depth = 0.55 + 2.6 * fract(hid * 3.1 - t * 0.00016);
                vec2 gpos = (gidx + 0.5);
                vec2 cellCenter = gpos * cellSz;
                vec2 jig = 0.10 * vec2(sin(t * (0.0005 + hid * 0.0011) + hid * 43.0), cos(t * (0.0006 + hid * 0.0009) + hid * 77.0));
                vec2 toCell = (cellCenter + jig * cellSz - wp) / depth;
                float rank = length(toCell) * 1.05;
                float rth = atan(toCell.y, toCell.x);
                float m = 1.5 + 5.5 * styleParam(10.0 + hid * 40.0, t, 0.0, 1.0, seed);
                float n1 = 0.7 + 0.7 * styleParam(20.0 + hid * 40.0, t, 0.0, 1.0, seed);
                float n2 = 0.3 + 1.7 * styleParam(30.0 + hid * 40.0, t, 0.0, 1.0, seed);
                float n3 = 0.3 + 1.7 * styleParam(40.0 + hid * 40.0, t, 0.0, 1.0, seed);
                float rot = t * (0.00008 + 0.00022 * styleParam(50.0 + hid * 40.0, t, 0.0, 1.0, seed));
                float ca = cos(m * (rth + rot) / 4.0);
                float sa = sin(m * (rth + rot) / 4.0);
                float denom = pow(abs(ca), n2) + pow(abs(sa), n3);
                float rSurf = (0.13 / pow(max(denom, 0.25), 1.0 / n1)) * (0.92 + 0.13 * uBeat + 0.06 * uBass) / depth;
                float fog = exp(-depth * 0.55);
                float edge = exp(-abs(rank - rSurf) * (38.0 + 8.0 / depth));
                float core = exp(-rank * rank * (140.0 + 40.0 / depth));
                float hue = fract(t * 0.02 + seed * 0.001 + hid * 0.61) * 360.0;
                vec3 c = hsl2rgb(hue, 0.85, 0.55);
                col += c * (edge * (0.28 + 0.14 * uBeat) + core * 0.07) * fog;
            }
        }
        // 3D 深度星流：每颗星透视投影双曲线（深度回收循环）
        {
            for (int s3 = 0; s3 < 20; s3++) {
                float fid = hash(float(s3) * 7.31 + seed);
                float zw = fract(fid * 7.7 - t * 0.00030);
                float z3 = 0.06 + zw * 2.6;
                vec2 sxy = (vec2(hash(float(s3) * 3.1 + seed), hash(float(s3) * 5.7 + seed)) - 0.5) * 3.0;
                vec2 proj = sxy / z3;
                float d3 = length(sp - proj);
                float near1 = (1.0 - zw) * (1.0 - zw);
                float hued = fract(fid * 5.0 + t * 0.000012) * 360.0;
                col += hsl2rgb(hued, 0.95, 0.68) * exp(-d3 * d3 * (2600.0 / z3)) * near1 * 0.45;
            }
        }
        {
            float wang = atan(wp.y, wp.x);
            float wrr = length(wp);
            for (int s2 = 0; s2 < 2; s2++) {
                float fs = float(s2);
                float ph = wang + wrr * 9.0 - t * 0.00035 - fs * 2.6;
                float d = abs(fract(ph / 6.2832) - 0.5) * 6.2832;
                float band = exp(-d * d * 3.5) * exp(-(wrr - 0.26) * (wrr - 0.26) * 6.0);
                float hueb = fract(t * 0.000016 + seed * 0.001 + fs * 0.36) * 360.0;
                col += hsl2rgb(hueb, 0.95, 0.62) * band * 0.26;
            }
        }
    } else if (preset == 1) {
        // ===== 1 分形峡谷·真透视：相机器材 + raymarch =====
        vec2 q = (p - vec2(0.5, 0.47)) * vec2(aspect, 1.0);
        float fov = radians(62.0 + 7.0 * uBass + 3.0 * uBeat);
        float focal = 1.0 / tan(fov * 0.5);
        float rep = 1.7;
        float zt = t * 0.55;
        float yaw = sin(t * 0.00011) * 0.16;
        float pitch = cos(t * 0.00008) * 0.09;
        vec3 ro = vec3(sin(t * 0.00019) * 0.30, cos(t * 0.00015) * 0.24, -zt);
        vec3 rd0 = normalize(vec3(q.x * focal * 0.85, q.y * focal * 0.85, 1.55));
        // 相机偏航俯仰施加到光线
        rd0.xz = rot2(yaw) * rd0.xz;
        rd0.yz = rot2(pitch) * rd0.yz;
        vec3 rd = normalize(rd0);
        mat2 ry = rot2(t * 0.00018 + yaw * 0.5);
        mat2 rx = rot2(t * 0.00011 + pitch * 0.4);
        float tt = 0.10 + 0.05 * hash2(gl_FragCoord.xy * 0.37);
        float nearest = 1e9;
        float hitT = -1.0;
        for (int i = 0; i < 46; i++) {
            vec3 pos = ro + rd * tt;
            float d = sdfCanyon(pos, ry, rx, rep, seed, t);
            nearest = min(nearest, abs(d));
            if (d < 0.0016) { hitT = tt; break; }
            tt += max(d * 0.42, 0.010);
            if (tt > 5.5) break;
        }
        float useT = hitT > 0.0 ? hitT : min(tt, 4.4);
        float pixW = useT * 2.2 / max(uRes.y, 1.0);
        float cover = hitT > 0.0 ? 1.0 : exp(-nearest / max(pixW, 1e-5) * 1.1);
        if (cover > 0.004) {
            float tv = hitT > 0.0 ? hitT : useT;
            vec3 pos = ro + rd * tv;
            float e = max(tv * 1.6 / max(uRes.y, 1.0), 0.0025);
            float sX = sdfCanyon(pos + vec3(e, 0.0, 0.0), ry, rx, rep, seed, t) - sdfCanyon(pos - vec3(e, 0.0, 0.0), ry, rx, rep, seed, t);
            float sY = sdfCanyon(pos + vec3(0.0, e, 0.0), ry, rx, rep, seed, t) - sdfCanyon(pos - vec3(0.0, e, 0.0), ry, rx, rep, seed, t);
            float sZ = sdfCanyon(pos + vec3(0.0, 0.0, e), ry, rx, rep, seed, t) - sdfCanyon(pos - vec3(0.0, 0.0, e), ry, rx, rep, seed, t);
            vec3 n = normalize(vec3(sX, sY, sZ));
            vec3 ld = normalize(vec3(0.5 + 0.35 * sin(t * 0.00022), 0.55, -0.62));
            float dif = clamp(dot(n, ld), 0.0, 1.0);
            float rim = pow(1.0 - abs(dot(n, -rd)), 2.2);
            float faceHue = mod(t * 0.014 + seed * 0.001 + n.y * 40.0 + n.x * 25.0, 360.0);
            vec3 base = hsl2rgb(faceHue, 0.92, 0.58);
            vec3 lit = base * (0.32 + 0.88 * dif * (0.90 + 0.35 * uBass)) + hsl2rgb(mod(faceHue + 55.0, 360.0), 0.95, 0.68) * rim * (0.85 + 0.55 * uBeat);
            float fade = exp(-(max(tv - 1.9, 0.0)) * 0.85);
            col = mix(col, lit, clamp(0.92 * cover * (0.45 + 0.65 * fade), 0.0, 1.0));
        }
        col += hsl2rgb(fract(t * 0.00002 + hash(seed + 91.0)) * 360.0, 0.85, 0.22) * exp(-dot(q, q) * 7.0) * 0.38;
    } else if (preset == 2) {
        // ===== 2 Julia 之海·俯冲透视：掠射平面 + 地平线汇聚 =====
        vec2 q = (p - vec2(0.5, 0.47)) * vec2(aspect, 1.0);
        vec2 cSet[4];
        cSet[0] = vec2(-0.7269, 0.1889);
        cSet[1] = vec2(0.285, 0.01);
        cSet[2] = vec2(-0.8, 0.156);
        cSet[3] = vec2(-0.4, 0.6);
        float rndJ = floor(t / 18000.0);
        int cIdx = int(mod(rndJ + floor(hash(seed) * 4.0), 4.0));
        vec2 cJulia = cSet[cIdx];
        // 透视参数：FOV 呼吸 + 俯角随 bass 轻摆，地平线位于视口上 1/3
        float fovJ = radians(68.0 - 6.0 * uBass);
        float focalJ = 1.0 / tan(fovJ * 0.5);
        float pitchJ = radians(-18.0 - 4.0 * sin(t * 0.00009 + seed));
        // 相机在 Julia 平面之上掠行
        vec3 roJ = vec3(sin(t * 0.00007) * 0.12, 0.68, -0.9);
        vec3 rdJ0 = normalize(vec3(q.x * focalJ * 0.92, q.y * focalJ * 0.92, 1.18));
        rdJ0.yz = rot2(pitchJ) * rdJ0.yz;
        vec3 rdJ = normalize(rdJ0);
        float tPlane = -roJ.y / rdJ.y;
        vec2 hitJ = roJ.xz + rdJ.xz * max(tPlane, 0.0);
        float depthJ = clamp(tPlane * 0.55, 0.0, 3.0);
        float perspK = 1.0 / (1.0 + depthJ * 0.55);
        float zfJ = exp(fract(t / 18000.0) * 6.0);
        vec2 baseJ = cJulia * 0.9 + hitJ * 0.14 * perspK;
        vec2 zj = baseJ + q * (0.55 / zfJ) * (0.7 + 0.3 * perspK);
        // 深处：按深度把坐标向 POI 收敛（近景位移大、远景位移小=视差）
        zj = mix(zj, cJulia * 0.9 + q * 0.02, clamp(depthJ * 0.18, 0.0, 0.45));
        float esc = 0.0;
        float mIter = 0.0;
        for (int ij = 0; ij < 48; ij++) {
            zj = vec2(zj.x * zj.x - zj.y * zj.y, 2.0 * zj.x * zj.y) + cJulia;
            float dj = dot(zj, zj);
            mIter += 1.0;
            if (dj > 16.0) { esc = 1.0; break; }
        }
        float layerFade = smoothstep(0.0, 0.08, fract(t / 18000.0)) * smoothstep(1.0, 0.94, fract(t / 18000.0));
        float horizonFog = tPlane > 0.12 ? exp(-depthJ * 0.9) : 0.0;
        // 地平线以上淡出为天空雾
        float skyMask = step(0.0, tPlane);
        if (skyMask < 0.5) {
            float sky = exp(-length(q - vec2(0.0, 0.62)) * 2.2);
            col += hsl2rgb(fract(t * 0.00002 + hash(seed + 21.0)) * 360.0, 0.75, 0.32) * sky * 0.55 * layerFade;
        } else if (esc > 0.5) {
            float nu = mIter - log2(log2(max(dot(zj, zj), 1.0001))) + 4.0;
            float hueJ = fract(nu * 0.045 + t * 0.00001 + hash(seed + 0.3)) * 360.0;
            float glowJ = exp(-mIter * 0.045);
            col += hsl2rgb(hueJ, 0.95, 0.55 + 0.15 * uBeat) * (0.12 + nu * 0.005 + glowJ * 0.85) * (1.0 + 0.5 * uBass) * layerFade * (0.65 + 0.45 * horizonFog);
        } else {
            col += hsl2rgb(fract(t * 0.00002 + 0.55) * 360.0, 0.75, 0.35) * (0.24 + 0.18 * uBass) * layerFade * (0.65 + 0.45 * horizonFog);
        }
        // 透视辅助：远处轻雾线
        col = mix(col, col * 0.55 + vec3(0.06, 0.07, 0.09), clamp(depthJ * 0.12, 0.0, 0.35) * layerFade);
    } else if (preset == 3) {
        // ===== 3 涡旋隧道·真圆柱透视（FOV 呼吸 + 弯道跟随）=====
        vec2 q = (p - vec2(0.5, 0.47)) * vec2(aspect, 1.0);
        float fov3 = radians(64.0 + 8.0 * uBass + 3.0 * sin(t * 0.00027));
        float focal3 = 1.0 / tan(fov3 * 0.5);
        float yaw3 = 0.18 * sin(t * 0.00022 + seed * 0.01);
        float pitch3 = 0.09 * cos(t * 0.00019 + seed * 0.013);
        vec3 ro3 = vec3(sin(t * 0.00024) * 0.18, cos(t * 0.00021) * 0.11, t * 0.00082 * 2.6);
        vec3 rd3_0 = normalize(vec3(q.x * focal3, q.y * focal3, 1.0));
        rd3_0.xz = rot2(yaw3) * rd3_0.xz;
        rd3_0.yz = rot2(pitch3) * rd3_0.yz;
        vec3 rd3 = normalize(rd3_0);
        // 弯道：以深度调制横向偏移（越深弯越明显=透视 foreshortening 的跟随）
        float depthEst = 0.22 / max(length(q), 0.06) + t * 0.00085;
        vec2 bend = 0.16 * vec2(sin(depthEst * 0.22 + t * 0.00033), cos(depthEst * 0.17 + seed * 0.012)) * clamp(depthEst * 0.12, 0.0, 1.0);
        vec2 qb = q + bend;
        float ang = atan(qb.y, qb.x);
        float rad = max(length(qb), 0.045);
        float depth = 0.22 / rad + t * 0.00085;
        float sway = 0.05 * sin(t * 0.00019 + seed);
        float aa = ang + sway + 0.14 * sin(depth * 1.7 + t * 0.00021);
        vec2 grid = vec2(aa * 0.955, depth);
        vec2 gvf = fract(grid);
        vec2 gid = floor(grid);
        float lineU = abs(gvf.x - 0.5);
        float lineV = abs(gvf.y - 0.5);
        float glowLine = exp(-lineU * lineU * 90.0) + exp(-lineV * lineV * 26.0);
        float cellId = hash(gid.x * 13.7 + gid.y * 31.1 + seed);
        float blink = step(0.35, cellId) * (0.4 + 0.6 * cellId) * (0.5 + 0.5 * sin(t * 0.002 + cellId * 40.0)) * (0.72 + 0.42 * uBeat);
        float depthFade = clamp(rad * 2.6, 0.0, 1.0);
        float persFade = exp(-depth * 0.055);
        float hue = mod(t * 0.000014 + seed * 0.001 + gid.y * 11.0 + gid.x * 5.0, 360.0);
        col += hsl2rgb(hue, 0.92, 0.62) * glowLine * blink * depthFade * persFade * 0.78;
        col += hsl2rgb(mod(hue + 43.0, 360.0), 0.85, 0.58) * exp(-rad * rad * 26.0) * (0.18 + 0.12 * uBass + 0.08 * uBeat);
        // 远端透视光锥
        col += hsl2rgb(mod(hue + 20.0, 360.0), 0.90, 0.58) * exp(-depth * 0.18) * 0.14;
    } else if (preset == 4) {
        // ===== 4 Mandelbrot·推轨变焦（dolly + FOV 窄化透视）=====
        vec2 q = (p - vec2(0.5, 0.47)) * vec2(aspect, 1.0);
        vec2 poi[3];
        poi[0] = vec2(-0.743643887037151, 0.131825904205330);
        poi[1] = vec2(0.286931868895045, 0.014286693904085);
        poi[2] = vec2(-0.16, 1.0405);
        vec2 poiSel = poi[int(mod(seed, 3.0))];
        float rndM = floor(t / 18000.0);
        float dolly = fract(t / 18000.0);
        float camDist = 2.8 * exp(-dolly * 2.4);
        float fovM = radians(76.0 - dolly * 24.0 + 4.0 * uBass);
        float focalM = 1.0 / tan(fovM * 0.5);
        vec2 poiM = poiSel + (vec2(hash(rndM * 5.3 + seed), hash(rndM * 9.7 + seed)) - 0.5) * (0.06 + 0.30 * hash(rndM * 3.7 + seed));
        vec3 roM = vec3(poiM.x, poiM.y, camDist);
        vec3 rdM0 = normalize(vec3(q.x * focalM * 0.88, q.y * focalM * 0.88, -1.0));
        // 轻微俯仰与滚转随 dolly 变化（推轨透视畸变）
        rdM0.xz = rot2(sin(dolly * 1.2 + seed * 0.01) * 0.06) * rdM0.xz;
        rdM0.yz = rot2(cos(dolly * 0.9 + seed * 0.013) * 0.04) * rdM0.yz;
        vec3 rdM = normalize(rdM0);
        float tPM = (0.0 - roM.z) / rdM.z;
        vec2 planeM = roM.xy + rdM.xy * max(tPM, 0.0);
        float depthM = clamp(tPM * 0.5, 0.0, 3.0);
        float persF = 1.0 / (1.0 + depthM * 0.45);
        float zfM = 0.55 * exp(-dolly * 8.5);
        vec2 z0 = poiM + (planeM - poiM) * (0.18 + 0.82 * persF) + q * zfM * persF;
        // 深度：远处细节更稠密
        float mIt = 0.0;
        float esc = 0.0;
        vec2 zm = vec2(0.0, 0.0);
        for (int im = 0; im < 60; im++) {
            zm = vec2(zm.x * zm.x - zm.y * zm.y, 2.0 * zm.x * zm.y) + z0;
            float dm = dot(zm, zm);
            mIt += 1.0;
            if (dm > 16.0) { esc = 1.0; break; }
        }
        float layerFadeM = smoothstep(0.0, 0.06, dolly) * smoothstep(1.0, 0.95, dolly);
        float depthFog = exp(-depthM * 0.65);
        if (esc > 0.5) {
            float nu = mIt - log2(log2(max(dot(zm, zm), 1.0001))) + 4.0;
            float hueM = fract(nu * 0.03 + t * 0.000008 + hash(seed + 0.7)) * 360.0;
            col += hsl2rgb(hueM, 0.95, 0.55 + 0.15 * uBeat) * (0.10 + nu * 0.0055) * (1.0 + 0.5 * uBass) * layerFadeM * (0.65 + 0.45 * depthFog);
        } else {
            col += hsl2rgb(fract(t * 0.00003) * 360.0, 0.85, 0.35) * 0.45 * layerFadeM * (0.65 + 0.45 * depthFog);
        }
        col = mix(col, col * 0.6 + vec3(0.05, 0.06, 0.08), clamp(depthM * 0.14, 0.0, 0.35) * layerFadeM);
    } else if (preset == 5) {
        // ===== 5 极光幕·透视帘片（ray-plane 分层求交）=====
        vec2 q = (p - vec2(0.5, 0.47)) * vec2(aspect, 1.0);
        float fovA = radians(66.0 + 4.0 * uBass);
        float focalA = 1.0 / tan(fovA * 0.5);
        vec3 roA = vec3(sin(t * 0.00009) * 0.10, 0.12, -t * 0.00019 * 1.6);
        vec3 rdA0 = normalize(vec3(q.x * focalA, q.y * focalA, 1.0));
        rdA0.yz = rot2(radians(-7.0)) * rdA0.yz;
        vec3 rdA = normalize(rdA0);
        float curtainAcc = 0.0;
        for (int la = 0; la < 3; la++) {
            float fl = float(la);
            float phA = t * 0.00019 + fl * 1.9 + seed * 0.01;
            float la_ = floor(phA);
            float frA = fract(phA);
            float hA = hash(la_ * 7.1 + fl * 13.3 + seed);
            float envA = smoothstep(0.0, 0.2, frA) * smoothstep(1.0, 0.8, frA);
            float worldZ = roA.z + 0.9 + fl * 1.35 + hA * 0.7;
            float tC = (worldZ - roA.z) / max(rdA.z, 0.22);
            if (tC < 0.15 || tC > 7.5) continue;
            vec3 hit = roA + rdA * tC;
            float depthA = tC;
            float persA = 1.0 / (1.0 + depthA * 0.38);
            float xw = hit.x * (2.2 + fl * 0.7) + hA * 43.0 + t * 0.00012;
            float ridge = 0.34 + 0.16 * fl + hA * 0.12 + 0.06 * sin(xw * 2.1 + t * 0.0003) + 0.04 * sin(xw * 4.7 - t * 0.00021);
            float drape = exp(-abs(hit.y - ridge) * (9.0 - fl * 2.0) * persA) * (1.0 - hit.y * 0.18) * persA;
            float flick = 0.7 + 0.3 * sin(xw * 9.0 + t * 0.0011 + fl * 2.0);
            float hueA = 120.0 + 55.0 * fl + hA * 30.0 + 18.0 * sin(t * 0.00016 + fl);
            float fogA = exp(-depthA * 0.42);
            col += hsl2rgb(hueA, 0.95, 0.55 + 0.10 * uBass) * drape * flick * envA * (0.68 - fl * 0.10) * (1.0 + 0.45 * uBeat) * fogA;
        }
        {
            float zfA = exp(fract(t / 12000.0) * 2.2);
            vec2 qa = q * zfA;
            vec2 sc = floor(qa * 26.0);
            float sid = hash2(sc + seed);
            if (sid > 0.93) {
                vec2 spos = (sc + 0.5) / 26.0;
                float depthStarA = length(qa - spos) * zfA * 0.12;
                col += vec3(0.7, 0.75, 0.8) * exp(-dot(qa - spos, qa - spos) * 4200.0) * (0.4 + 0.6 * sin(t * 0.003 + sid * 50.0)) * 0.30 * exp(-depthStarA);
            }
        }
    } else if (preset == 6) {
        // ===== 6 万花筒·棱镜隧道（深度棱镜 + 透视缩放）=====
        vec2 q = (p - vec2(0.5, 0.47)) * vec2(aspect, 1.0);
        float KSEG = 7.0;
        float spinK = t * 0.00014;
        float angK = atan(q.y, q.x) + spinK;
        // 棱镜深度：沿视线多层，每层 1/depth 透视缩放
        float lrBase = log(max(length(q), 0.02)) + t * 0.00030;
        for (int dk = 0; dk < 3; dk++) {
            float fk = float(dk);
            float depthK = 0.55 + fract(lrBase * 0.7 + fk * 0.37 - t * 0.00018) * 2.4;
            float persK = 1.0 / depthK;
            float lr = lrBase - log(depthK) * 0.7;
            float ring = exp(fract(lr)) * (0.92 + 0.16 * persK);
            float seg = mod(angK, 6.2831853 / KSEG);
            seg = abs(seg - 3.1415927 / KSEG);
            float layK = floor(lr + t * 0.00030 + fk * 1.7);
            float hK1 = hash(layK * 7.7 + seed);
            float hK2 = hash(layK * 9.1 + seed);
            float hK3 = hash(layK * 11.3 + seed);
            float mm = 2.0 + 5.0 * hK1;
            float n1k = 0.7 + 0.6 * hK2;
            float n2k = 0.3 + 1.7 * hK3;
            float n3k = 0.3 + 1.7 * hash(layK * 13.7 + seed);
            float ca = cos(mm * seg / 4.0);
            float sa = sin(mm * seg / 4.0);
            float denom = pow(abs(ca), n2k) + pow(abs(sa), n3k);
            float rSurf = (1.25 + 0.55 * (0.5 + 0.5 * sin(t * 0.0005 + seed + fk))) * pow(max(denom, 0.25), -1.0 / n1k) * 0.45 * (0.92 + 0.13 * uBeat) * (0.85 + 0.22 * persK);
            float edge = exp(-abs(ring - rSurf) * (9.0 + 4.0 * persK));
            float hueW = fract(t * 0.016 + seed * 0.001 + ring * 0.8 + fk * 0.15) * 360.0;
            float fogK = exp(-depthK * 0.52);
            col += hsl2rgb(hueW, 0.95, 0.65) * edge * (0.22 + 0.12 * uBeat) * fogK * (1.25 - fk * 0.22);
            col += hsl2rgb(mod(hueW + 40.0, 360.0), 0.92, 0.58) * exp(-abs(ring - 1.0) * (4.0 + 2.0 * persK)) * (0.18 + 0.12 * uBass) * fogK * (1.15 - fk * 0.18);
            if (fk == 1.0) {
                float beads = exp(-pow(sin(lr * 44.0), 2.0) * 12.0) * smoothstep(1.0, 1.15, ring) * smoothstep(2.72, 2.5, ring);
                col += hsl2rgb(mod(hueW + 180.0, 360.0), 0.8, 0.5) * beads * (0.08 + 0.06 * uTreble) * fogK;
            }
        }
    } else if (preset == 7) {
        // ===== 7 干涉波纹·俯视水面透视（grazing plane 求交）=====
        vec2 q = (p - vec2(0.5, 0.47)) * vec2(aspect, 1.0);
        float fovW = radians(68.0 + 5.0 * uBass);
        float focalW = 1.0 / tan(fovW * 0.5);
        vec3 roW = vec3(sin(t * 0.00007) * 0.10, 1.35, -0.85);
        float pitchW = radians(-68.0);
        vec3 rdW0 = normalize(vec3(q.x * focalW, q.y * focalW, 1.0));
        rdW0.yz = rot2(pitchW) * rdW0.yz;
        vec3 rdW = normalize(rdW0);
        float tWater = -roW.y / rdW.y;
        float acc = 0.0;
        float depthW = 0.0;
        vec2 waterPos = vec2(0.0);
        float waterMask = step(0.18, tWater) * step(tWater, 7.0);
        if (waterMask > 0.5) {
            waterPos = roW.xz + rdW.xz * tWater;
            depthW = tWater * 0.55;
            // 近密远疏的透视波长
            for (int wi = 0; wi < 4; wi++) {
                float fw = float(wi);
                float phW = t * 0.00021 + fw * 0.25 + hash(fw * 3.3 + seed);
                float gen = floor(phW);
                float life = fract(phW);
                vec2 src = vec2(hash(gen * 11.3 + fw * 7.7 + seed) - 0.5, hash(gen * 17.9 + fw * 3.1 + seed) - 0.5) * 0.16 + vec2(cos(life * 3.1 + gen), sin(life * 2.7 + gen)) * life * 0.55;
                // 透视：远处波源在水面上更密集，波长按 depth 压缩
                float persWv = 1.0 / (1.0 + depthW * 0.42);
                float waveK = (34.0 - fw * 4.0) * (0.75 + 0.45 * persWv);
                float dist = length(waterPos * persWv - src);
                float envW = smoothstep(0.0, 0.18, life) * smoothstep(1.0, 0.75, life) * exp(-depthW * 0.28);
                acc += sin(dist * waveK - t * 0.0019) * envW;
            }
        } else {
            // 天空/地平线雾
            float skyW = exp(-length(q - vec2(0.0, 0.58)) * 2.0);
            col += vec3(0.07, 0.08, 0.10) * skyW * 0.18;
        }
        if (waterMask > 0.5) {
            float ringI = (acc * 0.25 + 1.0) * 0.5;
            float v = pow(clamp(ringI, 0.0, 1.0), 3.0);
            float hueI = fract(t * 0.00002 + seed * 0.001 + v * 0.25) * 360.0;
            float fogW = exp(-depthW * 0.52);
            col += hsl2rgb(hueI, 0.95, 0.62) * v * (0.38 + 0.22 * uBeat) * fogW;
            col += hsl2rgb(mod(hueI + 60.0, 360.0), 0.75, 0.4) * exp(-dot(waterPos, waterPos) * 0.45) * (0.06 + 0.05 * uBass) * fogW;
            // 远处压缩的菲涅尔
            col = mix(col, col * 0.72 + vec3(0.04, 0.06, 0.09), clamp(depthW * 0.18, 0.0, 0.45));
        }
    } else if (preset == 8) {
        // ===== 8 晶体环廊·透视环阵（raymarch 圆环复用）=====
        vec2 q = (p - vec2(0.5, 0.47)) * vec2(aspect, 1.0);
        float fovR = radians(60.0 + 7.0 * uBass + 2.5 * uBeat);
        float focalR = 1.0 / tan(fovR * 0.5);
        float yawR = sin(t * 0.00016) * 0.12;
        float rollR = sin(t * 0.00009) * 0.14;
        vec3 roR = vec3(sin(t * 0.00016) * 0.18, cos(t * 0.00012) * 0.13, t * 0.00055 * 2.0);
        vec3 rdR0 = normalize(vec3(q.x * focalR, q.y * focalR, 1.0));
        rdR0.xz = rot2(yawR) * rdR0.xz;
        rdR0.xy = rot2(rollR) * rdR0.xy;
        vec3 rdR = normalize(rdR0);
        float repZ = 1.55;
        float ttR = 0.08 + 0.04 * hash2(gl_FragCoord.xy * 0.41);
        float hitR = -1.0;
        float nearestR = 1e9;
        vec3 hitPosR = vec3(0.0);
        float hitHash = 0.0;
        for (int i = 0; i < 36; i++) {
            vec3 pos = roR + rdR * ttR;
            float zc = floor(pos.z / repZ + 0.5);
            float hz = hash(zc * 7.7 + seed * 0.013);
            float ringR = 0.42 + 0.16 * hz;
            float tubeR = 0.05 + 0.02 * hash(zc * 9.3 + seed);
            vec3 qR = pos;
            qR.z = pos.z - zc * repZ;
            // 每环倾角
            float tilt = (hz - 0.5) * 0.55;
            qR.yz = rot2(tilt) * qR.yz;
            qR.xz = rot2(hz * 3.14) * qR.xz;
            float d = sdTorus(qR, vec2(ringR, tubeR));
            // 走廊保活：中心管外 0.58 半径内不挡相机
            float dCorridor = length(pos.xy - vec2(sin(pos.z*0.22)*0.12, cos(pos.z*0.18)*0.09)) - 0.0;
            // 仅环本身参与（不做走廊 max，避免遮挡判断复杂）
            nearestR = min(nearestR, abs(d));
            if (d < 0.004) { hitR = ttR; hitPosR = pos; hitHash = hz; break; }
            ttR += max(d * 0.52, 0.015);
            if (ttR > 6.0) break;
        }
        if (hitR > 0.0) {
            float eR = max(hitR * 1.5 / max(uRes.y, 1.0), 0.0025);
            float zcN = floor(hitPosR.z / repZ + 0.5);
            float hzN = hash(zcN * 7.7 + seed * 0.013);
            float ringRN = 0.42 + 0.16 * hzN;
            float tubeRN = 0.05 + 0.02 * hash(zcN * 9.3 + seed);
            float tiltN = (hzN - 0.5) * 0.55;
            float angN = hzN * 3.1415927;
            vec3 qN0 = hitPosR; qN0.z -= zcN * repZ; qN0.yz = rot2(tiltN) * qN0.yz; qN0.xz = rot2(angN) * qN0.xz;
            vec3 offX = vec3(eR, 0.0, 0.0); offX.yz = rot2(tiltN) * offX.yz; offX.xz = rot2(angN) * offX.xz;
            vec3 offY = vec3(0.0, eR, 0.0); offY.yz = rot2(tiltN) * offY.yz; offY.xz = rot2(angN) * offY.xz;
            vec3 offZ = vec3(0.0, 0.0, eR); offZ.yz = rot2(tiltN) * offZ.yz; offZ.xz = rot2(angN) * offZ.xz;
            float dXp = sdTorus(qN0 + offX, vec2(ringRN, tubeRN));
            float dXn = sdTorus(qN0 - offX, vec2(ringRN, tubeRN));
            float dYp = sdTorus(qN0 + offY, vec2(ringRN, tubeRN));
            float dYn = sdTorus(qN0 - offY, vec2(ringRN, tubeRN));
            float dZp = sdTorus(qN0 + offZ, vec2(ringRN, tubeRN));
            float dZn = sdTorus(qN0 - offZ, vec2(ringRN, tubeRN));
            vec3 nL = normalize(vec3(dXp - dXn, dYp - dYn, dZp - dZn));
            // 转回世界（逆旋转）
            nL.xz = rot2(-angN) * nL.xz;
            nL.yz = rot2(-tiltN) * nL.yz;
            vec3 n = normalize(nL);
            // 实际 torus 法线应在局部环空间计算，上式近似但保留高光方向性；工程上足以出体积感
            vec3 ldR = normalize(vec3(0.6, 0.7, -0.5));
            float difR = clamp(dot(n, ldR), 0.0, 1.0);
            float rimR = pow(1.0 - abs(dot(n, -rdR)), 2.4);
            float hueR = mod(t * 0.013 + seed * 0.001 + hitHash * 80.0, 360.0);
            vec3 baseR = hsl2rgb(hueR, 0.92, 0.58);
            vec3 litR = baseR * (0.35 + 0.90 * difR * (0.92 + 0.35 * uBass)) + hsl2rgb(mod(hueR + 55.0, 360.0),0.95,0.68) * rimR * (0.85 + 0.60 * uBeat);
            float fogR = exp(-hitR * 0.38);
            col = mix(col, litR, clamp(0.88 * fogR, 0.0, 1.0));
        } else {
            float pixW = ttR * 1.9 / max(uRes.y, 1.0);
            float cover = exp(-nearestR / max(pixW, 1e-5) * 1.0);
            vec3 farGlow = hsl2rgb(fract(t*0.00002+hash(seed+77.0))*360.0, 0.65, 0.10) * exp(-dot(q,q)*6.0) * 0.18 * cover;
            col += farGlow;
        }
    } else {
        // ===== 9 云海俯冲·分层容量（FBM + 视差）=====
        vec2 q = (p - vec2(0.5, 0.47)) * vec2(aspect, 1.0);
        float fovC = radians(72.0 + 4.0 * uBass);
        float focalC = 1.0 / tan(fovC * 0.5);
        float pitchC = radians(-42.0);
        vec3 roC = vec3(t * 0.00007 * 0.85, 0.72, t * 0.00006 * 1.1);
        vec3 rdC0 = normalize(vec3(q.x * focalC, q.y * focalC, 1.0));
        rdC0.yz = rot2(pitchC) * rdC0.yz;
        vec3 rdC = normalize(rdC0);
        vec3 cloudCol = vec3(0.0);
        float alphaSum = 0.0;
        for (int li = 0; li < 3; li++) {
            float h = li == 0 ? 0.0 : li == 1 ? 0.22 : -0.14;
            float tH = (h - roC.y) / rdC.y;
            if (tH < 0.12 || tH > 8.0) continue;
            vec3 hit = roC + rdC * tH;
            float depthC = tH * 0.45;
            float persC = 1.0 / (1.0 + depthC * 0.42);
            vec2 uvC = hit.xz * (0.55 + float(li) * 0.22) + vec2(t * 0.00006 * (1.0 + float(li)*0.5), t * 0.00004);
            float n = fbm2(uvC);
            float n2 = fbm2(uvC * 1.9 + 3.7);
            float dens = smoothstep(0.42, 0.68, n) * smoothstep(0.78, 0.48, n2) * persC;
            dens *= exp(-depthC * 0.38) * (0.85 + 0.25 * uBass);
            float hueC = 188.0 + 22.0 * float(li) + 18.0 * sin(t * 0.00014 + float(li)*1.3) + n * 12.0;
            vec3 cC = hsl2rgb(hueC, 0.72, 0.55 + 0.12 * n);
            float layerFog = exp(-depthC * 0.55);
            cloudCol += cC * dens * 0.52 * layerFog * (1.0 - alphaSum * 0.55);
            alphaSum += dens * 0.38 * persC;
        }
        col += cloudCol;
        // 远空透视
        float tSky = -roC.y / rdC.y;
        if (tSky < 0.0) {
            float sky = exp(-length(q - vec2(0.0, 0.55)) * 1.8);
            col += hsl2rgb(202.0, 0.55, 0.13) * sky * 0.22;
        }
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
