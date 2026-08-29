// aurora.frag：全屏幻彩极光。
//
// 五层帘幕沿整个画面高度铺开（底层帘从画面下缘升起，光柱贯穿全屏），
// 不是只在顶部飘一条：每层曲线由 fbm 驱动缓慢起伏，帘体下缘锐利、
// 光柱向上衰减（真实极光的下边界特征），内部有竖直光柱条纹。
// 颜色随高度从翠绿 → 青 → 蓝紫 → 粉紫渐变，并随时间整体缓慢漂移，
// 加上银河斜带、双层闪烁星空、地平线山脊剪影与反光，柔和色调映射出梦幻感。
//
// uniform 由工具链注入（uT 毫秒 / uSeed / uRes / uBeat / uBass / uTreble /
// uTransition / uPrev），源文件按 GLSL ES 1.00 书写。
uniform float uT;
uniform float uSeed;
uniform vec2 uRes;
uniform float uBeat;
uniform float uBass;
uniform float uTreble;
uniform float uTransition;
uniform sampler2D uPrev;
varying vec2 vUV;

#define TAU 6.2831853

float hash11(float n) {
    n = fract(n * 0.1031);
    n *= n + 33.33;
    n *= n + n;
    return fract(n);
}
float hash21(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}
float vn(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash21(i), hash21(i + vec2(1.0, 0.0)), u.x),
               mix(hash21(i + vec2(0.0, 1.0)), hash21(i + vec2(1.0, 1.0)), u.x), u.y);
}
// 4 倍频 + 倍频间旋转，消掉网格方向感
float fbm(vec2 p) {
    float v = 0.0;
    float a = 0.5;
    mat2 R = mat2(0.8, -0.6, 0.6, 0.8);
    for (int i = 0; i < 4; i++) {
        v += a * vn(p);
        p = R * p * 2.03;
        a *= 0.5;
    }
    return v;
}
vec3 hue2rgb(float h) {
    return 0.5 + 0.5 * cos(TAU * (h + vec3(0.0, 0.33, 0.67)));
}

// 星空层：S 密度，thresh 阈值，tw 闪烁相速
vec3 stars(vec2 q, float S, float thresh, float tw, float ts) {
    vec2 cell = floor(q * S);
    vec2 pos = fract(q * S) - 0.5;
    float h = hash21(cell);
    if (h < thresh) return vec3(0.0);
    vec2 off = (vec2(hash21(cell + 7.0), hash21(cell + 13.0)) - 0.5) * 0.7;
    float d2 = dot(pos - off, pos - off);
    float twk = 0.55 + 0.45 * sin(ts * tw + h * 40.0);
    float star = exp(-d2 * 220.0) * twk;
    return vec3(0.9, 0.93, 1.0) * star * (0.4 + 0.6 * hash21(cell + 29.0));
}

void main() {
    float ts = uT * 0.001;
    float sd = hash11(uSeed * 1.0e-7) * 173.0;
    float aspect = uRes.x / max(uRes.y, 1.0);
    vec2 q = (vUV - vec2(0.5, 0.42)) * vec2(aspect, 1.0);

    // ---- 深空底：全屏渐变 + 大尺度雾霭 ----
    float up = clamp(q.y * 0.5 + 0.5, 0.0, 1.0);
    vec3 col = mix(vec3(0.012, 0.020, 0.038), vec3(0.030, 0.012, 0.052), up);
    float hueDrift = 0.55 + 0.10 * sin(ts * 0.020 + sd);
    col += hue2rgb(hueDrift + 0.5) * fbm(q * 1.3 + vec2(ts * 0.006, sd)) * 0.045;

    // ---- 银河斜带 ----
    float mw = exp(-pow(dot(q, normalize(vec2(0.55, 1.0))), 2.0) * 3.2);
    col += vec3(0.10, 0.12, 0.19) * mw * (0.35 + 0.65 * fbm(q * 3.1 + 7.0)) * 0.8;

    // ---- 星空（亮极光处自动让位）----
    vec3 starCol = stars(q, 96.0, 0.90, 2.6, ts) * 0.8
        + stars(q, 38.0, 0.93, 1.4, ts) * 1.2;
    col += starCol;

    // ---- 五层极光帘：基线纵贯全屏，每层一色族（绿/青/蓝/紫/粉），层间相互独立 ----
    float bassSway = 1.0 + 0.8 * uBass;
    // 5 个层色族：色相族中心 + 整层偏色强度（每层个性鲜明）
    float bandHues[5];
    bandHues[0] = 0.67;   // 翠绿（最底）
    bandHues[1] = 0.50;   // 青
    bandHues[2] = 0.33;   // 蓝
    bandHues[3] = 0.17;   // 紫
    bandHues[4] = 0.95;   // 粉
    for (int i = 0; i < 5; i++) {
        float fi = float(i);
        float h1 = hash11(fi * 3.77 + sd);
        float h2 = hash11(fi * 7.31 + sd + 5.0);
        float h3 = hash11(fi * 11.9 + sd + 13.0);
        // 基线从 -0.62 到 +0.72 均布 + 各自慢漂移
        float baseY = mix(-0.62, 0.72, fi / 4.0) + 0.10 * sin(ts * (0.05 + 0.03 * h2) + fi * 2.2);
        float curve = fbm(vec2(q.x * (0.9 + 0.6 * h1) + fi * 13.7, ts * (0.030 + 0.020 * h2))) - 0.5;
        float yc = baseY + curve * 0.42 * bassSway;
        float d = q.y - yc;
        // 帘体剖面：下缘陡、向上缓衰（光柱感）
        float prof = mix(exp(d * 22.0), exp(-d * (3.6 + 1.2 * h3)), step(0.0, d));
        // 竖直光柱条纹：只随 x 与帘线缓变
        float rays = 0.50 + 0.50 * fbm(vec2(q.x * (7.0 + 4.0 * h1) + fi * 31.0, yc * 2.0 - ts * (0.06 + 0.05 * h2)));
        rays *= 0.78 + 0.22 * sin(q.x * (120.0 + 60.0 * h3) + yc * 14.0 + ts * (0.5 + h2));
        // 颜色：层色族 + 高度内的小幅漂移 + 全局慢漂
        float bandH = bandHues[i];
        float alt = clamp(d * 1.3 + 0.10, 0.0, 1.0);
        float hue = bandH + 0.18 * (alt - 0.5)
            + 0.05 * sin(ts * 0.017 + sd + fi * 1.7)
            + uTreble * 0.03;
        // 每层饱和度更高（不让淡色吞噬彩色）
        vec3 cc = hue2rgb(hue);
        cc = mix(vec3(dot(cc, vec3(0.299, 0.587, 0.114))), cc, 1.30);
        // 下边界一抹更亮更艳的纯色亮线
        float edgeGlow = exp(-abs(d) * 34.0);
        vec3 edgeCol = hue2rgb(bandH);
        cc += edgeCol * edgeGlow * 1.1;
        // 上方云絮（"梦幻感"软光柱，柔和后晕）
        float softGlow = exp(-max(d - 0.04, 0.0) * 1.6) * (0.45 + 0.45 * uTreble);
        vec3 haloCol = hue2rgb(fract(bandH + 0.08));
        cc += haloCol * softGlow * 0.30;
        float I = (0.28 + 0.16 * h1) * (1.0 + 0.50 * uBeat * (0.5 + 0.5 * sin(ts * 1.3 + fi * 2.6)));
        col += cc * prof * rays * I;
    }

    // ---- 全屏柔光雾（梦幻感）----
    col += hue2rgb(hueDrift) * fbm(q * 0.9 - vec2(ts * 0.008, 0.0)) * 0.05;

    // ---- 地平线山脊剪影 + 极光微反光 ----
    float ridge = -0.72 + fbm(vec2(q.x * 2.6, sd)) * 0.09;
    float ground = smoothstep(ridge + 0.005, ridge - 0.02, q.y);
    col = mix(col, col * 0.16 + vec3(0.004, 0.007, 0.012), ground);

    // 轻反馈拖尾：帘幕流动更柔
    col += texture2D(uPrev, vUV + vec2(0.0004, 0.0)).rgb * 0.10;

    // 柔和色调映射 + 暗角 + 抖动去色带
    col = 1.0 - exp(-col * 1.15);
    col *= 1.0 - 0.30 * dot(q * 0.8, q * 0.8);
    col += (hash21(vUV * uRes + fract(ts) * 7.0) - 0.5) * (1.5 / 255.0);

    float transA = smoothstep(0.0, 1.0, clamp(uTransition, 0.0, 1.0));
    col = mix(texture2D(uPrev, vUV).rgb, col, transA);

    gl_FragColor = vec4(col, 1.0);
}
