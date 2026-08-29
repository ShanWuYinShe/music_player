// kaleido.frag：万花筒多形态引擎（四套结构互异场 × wander 轮换 × crossfade）。
//
// 与 fractal.frag 同一套 winner-take-most 轮换机制（五路改四路），但四套
// 形态都是"万花筒语义"，运动性格互不相同：
//     0 RINGS   环带深潜（原主场景）：每环独立身份（重数/转向/纹样/
//               色相），恒速向内潜——唯一"缩放"的形态；
//     1 CHAMBER 真镜室：一个扇形镜室单元（两面镜夹角 2π/n），里面漂浮
//               半透明玻璃碎块与亮珠；每片对镜轴 abs 一次 → 一片变两片
//               的真实双像；镜缝亮线 = 切玻璃感。整体只缓转，无缩放；
//     2 TUNNEL  透视隧道飞行：n 折管壁面板网格 + 恒速前飞的深度 + 沿管
//               壁扫过的灯环；近镜缝处折角阴影 → 立体管感；
//     3 MANDALA 呼吸曼陀罗：三层花瓣（重数互素、旋向交替），从中心
//               绽放外扩再淡出的慢周期，beat 给瓣尖镀辉光——完全不潜。
//
// 轮换与多样性：四路权重 = pow(wander2(ts, 独立尺度, 独立种子), SHARP)，
// 大部分时间单一形态独占（帧级一致 → 只算前二名），过渡期连续 crossfade；
// wander 无周期 → 形态序列永不重演。各形态内部再由 wander 驱动子参数
// （碎块漂移 / 灯环相位 / 绽放相位 / 环身份）——同一形态每次出场也不同。
//
// 防闪烁与速度铁律沿用（别回退）：色相慢漂 ≤ 每几分钟一圈；音频量只进
// 亮度/幅度；速度类恒定；硬阈值 smoothstep 软化。
//
// 公共函数（hash/vn/fbm/wander/rot/palIQ/satBoost/toneExp/dither/…）由
// 工具链从 common.glsl 注入，不要在本文件重复定义。

// ---- 深潜几何（RINGS）-----------------------------------------------------
const float LNS = 0.6931472;
const float DIVE_SPEED = 0.45;
const float CENTER_FADE = 0.045;
const float CORE_GLOW = 700.0;
const float ROT_SPAN = 1.25;
const float ROT_SCALE = 43.0;
const float BARREL_SWAY = 0.28;
const float FOLD_MIN = 3.0;

// ---- RINGS 纹样参数 --------------------------------------------------------
const float W_SCALE_1 = 29.0;
const float W_SCALE_2 = 37.0;
const float W_SCALE_3 = 23.0;
const float W_SCALE_4 = 31.0;
const float W_SHARP = 2.2;
const float MODE_SCALE_R = 53.0;
const float EDGE_LINE_SHARP = 36.0;
const float EDGE_LINE_GAIN = 0.35;
const float RIM_SHARP = 50.0;

// ---- CHAMBER（镜室碎玻璃）--------------------------------------------------
const float CH_N_MIN = 6.0;         // 镜室重数下限（6..10 整数）
const float CH_N_SPAN = 4.999;
const float CH_ROT_RATE = 0.030;    // 整体缓转（弧度/秒）
const int CH_SHARDS = 6;            // 碎块数（每片经镜轴双像 × n 折重复）
const float CH_DRIFT_SCALE = 31.0;  // 碎块漂移时间尺度
const float CH_BODY_ALPHA = 0.42;   // 片体透射（半透明玻璃）
const float CH_EDGE_GAIN = 0.75;    // 边线（切玻璃轮廓）
const float CH_BEAD_DENSITY = 0.64; // 亮珠密度
const float CH_BASE = 0.045;        // 镜室底色微光

// ---- TUNNEL（透视隧道）-----------------------------------------------------
const float TN_N_MIN = 4.0;
const float TN_N_SPAN = 4.999;
const float TN_SPEED = 0.50;        // 前飞速度（恒定！）
const float TN_PERSP = 0.55;        // 透视系数（深度 = PERSP/r + t·SPEED）
const float TN_RING_RATE = 0.30;    // 灯环空间频率
const float TN_SEAM_DARK = 0.55;    // 镜缝折角阴影深度

// ---- MANDALA（呼吸曼陀罗）--------------------------------------------------
const float MD_BLOOM_RATE = 0.045;  // 绽放周期（秒⁻¹，恒定）
const float MD_PETAL_POW = 3.0;     // 花瓣横向锐度

// ---- 形态轮换 --------------------------------------------------------------
const float MODE_SHARP = 3.0;
const float MODE_SCALE_0 = 43.0;
const float MODE_SCALE_1 = 59.0;
const float MODE_SCALE_2 = 67.0;
const float MODE_SCALE_3 = 51.0;
const float BLEND_SKIP = 0.04;

// ---- 色彩 / 收尾 -----------------------------------------------------------
const vec3 PAL_C = vec3(0.9, 1.0, 1.1);
const vec3 PAL_D = vec3(0.0, 0.12, 0.38);
const vec3 PAL_C2 = vec3(1.1, 0.9, 1.0);
const vec3 PAL_D2 = vec3(0.35, 0.10, 0.55);
const float HUE_WANDER = 0.25;
const float MAIN_GAIN = 1.00;
const float TONE_EXPOSURE = 1.05;
const float SAT_BOOST = 0.72;
const float VIGNETTE = 0.30;
const float TRAIL_ZOOM = 0.9897;    // = 2^(−0.45/30)，对齐 RINGS 流速
const float TRAIL_ZOOM_SOFT = 0.996;
const float TRAIL_GAIN = 0.30;
const float SEED_SPREAD = 173.0;

vec3 pal(float t) {
    return palIQ(t, PAL_C, PAL_D);
}

vec3 pal2(float t) {
    return palIQ(t, PAL_C2, PAL_D2);
}

// 二面体镜像折叠（D_n）：0(镜面轴)..1(扇区界)
float foldD(float a, float n) {
    float seg = TAU / n;
    return abs(mod(a, seg) - seg * 0.5) / (seg * 0.5);
}

// 旋转折叠（C_n 锯齿）：0..1
float foldC(float a, float n) {
    float seg = TAU / n;
    return mod(a, seg) / seg;
}

// ---- RINGS 纹样（fa 折叠角坐标 0..1，fr 环带径向）---------------------------
float patPetal(float fa, float fr, float ph, float sd) {
    float p = pow(1.0 - fa, 1.6);
    p *= 0.65 + 0.35 * sin(fr * 9.4 + ph + sd);
    return p;
}

float patStar(float fa, float fr, float ph, float sd) {
    float s = pow(1.0 - fa, 7.0) * 1.6 + pow(1.0 - fa, 2.0) * 0.25;
    s *= 0.7 + 0.3 * sin(fr * 5.0 + ph * 0.7 + sd * 1.7);
    return s;
}

float patLattice(float fa, float fr, float ph, float sd) {
    float g = abs(sin(fa * 6.283 + ph * 0.4))
        * abs(sin(fr * 9.42 + ph * 0.6 + sd));
    return pow(g, 0.7);
}

float patShard(float fa, float fr, float ph, float sd) {
    float s1 = abs(sin(fa * 4.7 + fr * 3.1 + ph * 0.5 + sd));
    float s2 = abs(sin(fa * 2.9 - fr * 5.3 + ph * 0.3 + sd * 2.3));
    float facet = s1 * s2;
    return pow(facet, 0.6) * 0.9 + pow(facet, 6.0) * 0.8;
}

float patDots(float fa, float fr, float ph, float sd, float ts) {
    vec2 g2 = vec2(fa * 8.0, fr * 4.0);
    vec2 cell = floor(g2);
    vec2 fp = fract(g2);
    float h = hash21(cell + floor(sd));
    vec2 cp = vec2(hash21(cell + 7.0 + floor(sd)),
        hash21(cell + 13.0 + floor(sd)));
    float tw = wander(ts, 2.0, h * 40.0 + sd + ph);
    return step(0.62, h) * exp(-dot(fp - cp, fp - cp) * 30.0) * tw * 2.0;
}

// ---- 形态 0：环带深潜（原主场景，已验证稳定）--------------------------------
vec3 modeRings(vec2 q, float ts, float sd) {
    float D = ts * DIVE_SPEED + sd * 0.37;
    float rho = max(length(q), 1e-4);
    float ang = atan(q.y, q.x);
    float lr = -log(rho) / LNS + D;
    float ringK = floor(lr);
    float fr = fract(lr);

    float rk1 = hash11(ringK * 0.913 + sd);
    float rk2 = hash11(ringK * 1.711 + sd + 5.0);
    float rk3 = hash11(ringK * 2.399 + sd + 11.0);
    float rk4 = hash11(ringK * 3.127 + sd + 17.0);
    float nFold = FOLD_MIN + floor(rk1 * 8.999);
    float sdr = sd + ringK * 7.7;

    float rotAng = (rk2 - 0.5) * 2.0 * ROT_SPAN
        * wanderBi(ts, ROT_SCALE, sd + ringK * 3.1)
        + uBeat * 0.15 * (rk4 - 0.5);
    float a = ang + rotAng + BARREL_SWAY * wanderBi(ts, 87.0, sd + 3.3);

    float modeK = smoothstep(0.25, 0.75,
        wander2(ts, MODE_SCALE_R, sd + ringK * 9.7 + rk3));
    float fa = mix(foldD(a, nFold), foldC(a, nFold), modeK);

    float frP = fr * (0.7 + 0.9 * rk4);
    float ph1 = wanderBi(ts, 19.0, sdr + 1.0) * 9.0;
    float ph2 = wanderBi(ts, 27.0, sdr + 2.0) * 9.0;
    float ph3 = wanderBi(ts, 17.0, sdr + 3.0) * 9.0;
    float ph4 = wanderBi(ts, 23.0, sdr + 4.0) * 9.0;
    float ph5 = wanderBi(ts, 21.0, sdr + 5.0) * 9.0;
    float w1 = pow(wander2(ts, W_SCALE_1, sdr), W_SHARP);
    float w2 = pow(wander2(ts, W_SCALE_2, sdr + 13.1), W_SHARP);
    float w3 = pow(wander2(ts, W_SCALE_3, sdr + 27.7), W_SHARP);
    float w4 = pow(wander2(ts, W_SCALE_4, sdr + 41.3), W_SHARP);
    float w5 = pow(wander2(ts, W_SCALE_2, sdr + 57.9), W_SHARP);
    float wsum = w1 + w2 + w3 + w4 + w5 + 1e-4;
    float I = (patPetal(fa, frP, ph1, sdr) * 1.00 * w1
        + patStar(fa, frP, ph2, sdr) * 1.05 * w2
        + patLattice(fa, frP, ph3, sdr) * 0.85 * w3
        + patShard(fa, frP, ph5, sdr) * 0.95 * w5
        + patDots(fa, frP, ph4, sdr, ts) * 1.45 * w4) / wsum;
    I = pow(I, 0.75);

    float hueBase = rk3 + HUE_WANDER * wanderBi(ts, 67.0, sd + 4.4)
        + uTreble * 0.03;
    float hue = hueBase + fa * (0.10 + 0.08 * rk2) + fr * (0.15 * rk4);
    float palK = smoothstep(0.2, 0.8, wander2(ts, 97.0, sd + 8.8));
    vec3 colr = mix(pal(hue), pal2(hue), palK);
    float pl = dot(colr, vec3(0.299, 0.587, 0.114));
    colr *= min(1.0, 0.44 / max(pl, 1e-3));

    float ringGain = 0.82 + 0.18 * rk2;
    vec3 col = colr * I * ringGain * MAIN_GAIN;
    col += colr * 0.028;

    float edgeLine = exp(-fa * EDGE_LINE_SHARP)
        + exp(-(1.0 - fa) * EDGE_LINE_SHARP);
    col += mix(vec3(1.0), colr, 0.35) * edgeLine * EDGE_LINE_GAIN * ringGain;
    float rim = exp(-fr * RIM_SHARP) * 0.6 + exp(-(1.0 - fr) * RIM_SHARP) * 0.3;
    col += mix(vec3(1.0), colr, 0.5) * rim * ringGain;

    col *= smoothstep(0.0, CENTER_FADE, rho);
    float hueCore = rk3 + 0.2 * wanderBi(ts, 61.0, sd + 6.6) + uTreble * 0.05;
    col += pal(hueCore + 0.10) * exp(-rho * rho * CORE_GLOW)
        * (0.45 + 0.55 * uBeat);
    return col;
}

// ---- 玻璃碎块 SDF（type 混合三原型：菱片 / 胶囊 / 环片）---------------------
float shardSDF(vec2 p, float type) {
    if (type < 0.40) {
        // 菱形片
        vec2 s = vec2(0.34, 0.20);
        return (length(max(abs(p) - s, 0.0)) + min(max(abs(p).x - s.x, abs(p).y - s.y), 0.0)) - 0.05;
    } else if (type < 0.75) {
        // 胶囊
        return length(vec2(abs(p.x) - 0.26, p.y * 1.4)) - 0.12;
    }
    // 环片
    return abs(length(p) - 0.28) - 0.07;
}

// ---- 形态 1：真镜室（碎玻璃双像 × 镜缝亮线）---------------------------------
vec3 modeChamber(vec2 q, float ts, float sd) {
    float n = CH_N_MIN + floor(hash11(sd * 0.31 + 3.0) * CH_N_SPAN);
    float rotA = ts * CH_ROT_RATE + wanderBi(ts, 73.0, sd + 5.0) * 0.6;
    float ang = atan(q.y, q.x) + rotA;
    float seg = TAU / n;
    // aa：0 = 镜轴，1 = 镜缝（扇区界）
    float aa = abs(mod(ang, seg) - seg * 0.5) / (seg * 0.5);
    float r = length(q);

    // 镜室底色：径向渐变 + 淡 spokes
    float hueBase = hash11(sd + 7.0) + HUE_WANDER * wanderBi(ts, 67.0, sd + 4.4);
    vec3 col = pal(hueBase) * CH_BASE * (1.2 - 0.7 * r);

    // 镜面坐标：u 以镜轴为 0（后续 abs 复制 → 一片变两片）
    float u = (1.0 - aa) * 0.5;      // 0..1（镜轴 → 缝）
    float v = r * 1.35 + 0.05;
    float acc = 0.0;
    for (int j = 0; j < CH_SHARDS; j++) {
        float fj = float(j);
        float h1 = hash11(fj * 7.7 + sd + 1.0);
        float h2 = hash11(fj * 3.3 + sd + 9.0);
        float h3 = hash11(fj * 5.9 + sd + 17.0);
        // 碎块缓漂（wander；纵向缓慢下沉 = 镜筒倾斜转动的观感）
        vec2 sp = vec2(
            (wander2(ts, CH_DRIFT_SCALE, sd + fj * 11.0) - 0.5) * 1.05,
            1.30 - mod(wander2(ts, CH_DRIFT_SCALE * 1.3, sd + fj * 13.0)
                * 1.2 + ts * 0.010 * (0.5 + h1), 1.45));
        float size = 0.13 + 0.16 * h2;
        vec2 d = (vec2(abs(u - sp.x), v - sp.y)) / size;
        float dj = shardSDF(d, h3);
        float alpha = smoothstep(0.03, -0.03, dj);
        float edge = exp(-abs(dj) * 26.0);
        // 片内高光条（假环境：碎块上斜的亮带，h 决定方位）
        float streak = exp(-pow((d.x + d.y * 0.6) - (h1 - 0.5) * 1.2, 2.0) * 22.0)
            * alpha;
        float hue = hueBase + 0.18 * fj / float(CH_SHARDS)
            + 0.06 * sin(ts * 0.02 + fj);
        vec3 sc = mix(pal(hue), pal2(hue),
            smoothstep(0.2, 0.8, wander2(ts, 97.0, sd + 8.8)));
        // 半透明玻璃：透射叠色 + 前片遮挡后片（acc 衰减）
        col += sc * alpha * CH_BODY_ALPHA * (1.0 - acc * 0.6)
            * (0.8 + 0.4 * uBeat);
        col += mix(vec3(1.0), sc, 0.4) * edge * CH_EDGE_GAIN * (1.0 - acc * 0.5);
        col += vec3(0.95, 0.98, 1.05) * streak * 0.20;
        acc += alpha * 0.42;
    }

    // 亮珠层（细小高亮点，随 wander 闪烁）
    float bh = hash21(floor(vec2(u * 9.0, v * 9.0)) + sd);
    float bead = step(1.0 - CH_BEAD_DENSITY * 0.25, bh)
        * exp(-length(fract(vec2(u * 9.0, v * 9.0)) - 0.5
            - vec2(hash21(floor(vec2(u * 9.0, v * 9.0)) + 3.1),
                hash21(floor(vec2(u * 9.0, v * 9.0)) + 5.7))) * 18.0);
    float tw = wander(ts, 2.3, bh * 40.0 + sd);
    col += mix(vec3(1.0), pal(hueBase + 0.15), 0.5) * bead * tw * 1.6;

    // 镜缝亮线（切玻璃感）+ 中心淡出（镜筒尽头的暗腔）
    float seam = exp(-aa * 34.0);
    col += mix(vec3(1.0), pal(hueBase + 0.3), 0.35) * seam * 0.30;
    col *= smoothstep(0.0, 0.05, r);
    return col;
}

// ---- 形态 2：透视隧道飞行 ---------------------------------------------------
vec3 modeTunnel(vec2 q, float ts, float sd) {
    float n = TN_N_MIN + floor(hash11(sd * 0.47 + 11.0) * TN_N_SPAN);
    float rotA = ts * 0.02 + wanderBi(ts, 83.0, sd + 2.0) * 0.8;
    float ang = atan(q.y, q.x) + rotA;
    float seg = TAU / n;
    float fa = abs(mod(ang, seg) - seg * 0.5) / (seg * 0.5); // 0 镜轴 1 缝
    float r = max(length(q), 1e-4);

    // 透视深度：中心 = 极远（消失点），恒速前飞
    float depth = TN_PERSP / r + ts * TN_SPEED;
    // 管壁面板：角向 × 深度网格，每格 hash 明暗
    vec2 pan = vec2(fa * n * 0.85, depth * 2.0);
    vec2 id = floor(pan);
    float hp = hash21(id + sd * 0.17);
    vec2 fp = fract(pan);
    float panelEdge = exp(-min(min(fp.x, 1.0 - fp.x), min(fp.y, 1.0 - fp.y)) * 14.0);
    float panel = 0.30 + 0.70 * hp * hp;

    // 灯环：沿深度周期分布的亮环 + 行波脉冲
    float ringPos = fract(depth * TN_RING_RATE);
    float ring = exp(-pow((ringPos - 0.5) * 4.2, 2.0))
        * (0.5 + 0.8 * hash11(floor(depth * TN_RING_RATE) + sd));
    float pulse = 0.60 + 0.40 * sin(depth * 3.1 + uTreble * 2.0);

    // 折角阴影：靠近镜缝的面板背光更暗 → 立体管
    float shade = mix(1.0, TN_SEAM_DARK, pow(fa, 2.0));

    float hueBase = hash11(sd + 19.0) + HUE_WANDER * wanderBi(ts, 67.0, sd + 4.4)
        + 0.06 * depth * 0.05;
    float hue = hueBase + 0.22 * hp + 0.10 * ring;
    vec3 col = pal(hue) * panel * shade * 0.34;
    col += mix(vec3(1.0), pal(hue + 0.12), 0.45) * panelEdge * 0.30 * shade;
    col += pal(hue + 0.30) * ring * pulse * (0.9 + 0.5 * uBeat) * 0.55 * shade;

    // 消失点淡出 + 核心微光
    col *= smoothstep(0.0, 0.07, r);
    col += pal(hueBase + 0.1) * exp(-r * r * 900.0) * (0.4 + 0.6 * uBeat) * 0.7;
    return col;
}

// ---- 形态 3：呼吸曼陀罗 -----------------------------------------------------
vec3 modeMandala(vec2 q, float ts, float sd) {
    float r = length(q);
    float ang = atan(q.y, q.x);
    float breath = 1.0 + 0.05 * uBeat; // beat → 尺寸呼吸（合规：尺寸域）

    vec3 col = vec3(0.0);
    // 三层花瓣：重数互素、旋向交替、绽放相位错开 1/3 周期
    float n1 = 5.0 + floor(hash11(sd + 1.0) * 3.0);
    float n2 = 8.0 + floor(hash11(sd + 7.0) * 4.0);
    float n3 = 12.0 + floor(hash11(sd + 13.0) * 5.0);
    float hueBase = hash11(sd + 23.0) + HUE_WANDER * wanderBi(ts, 67.0, sd + 4.4);

    // 层 1：内层（反向旋）
    float a1 = ang - ts * 0.030 + sd;
    float fa1 = abs(fract(a1 / TAU * n1) - 0.5) * 2.0;
    float b1 = fract(ts * MD_BLOOM_RATE);
    float rr1 = r / (0.34 * breath);
    float env1 = smoothstep(0.05, 0.25, rr1 - b1 * 0.9)
        * smoothstep(1.0, 0.55, rr1 - b1 * 0.9)
        * (1.0 - b1 * 0.55);
    col += pal(hueBase) * pow(max(sin(fa1 * PI), 0.0), MD_PETAL_POW) * env1 * 1.1;

    // 层 2：中层（正向旋）
    float a2 = ang + ts * 0.021 + sd * 1.7;
    float fa2 = abs(fract(a2 / TAU * n2) - 0.5) * 2.0;
    float b2 = fract(ts * MD_BLOOM_RATE + 0.33);
    float rr2 = r / (0.62 * breath);
    float env2 = smoothstep(0.05, 0.30, rr2 - b2 * 0.85)
        * smoothstep(1.05, 0.6, rr2 - b2 * 0.85)
        * (1.0 - b2 * 0.55);
    col += pal(hueBase + 0.18) * pow(max(sin(fa2 * PI), 0.0), MD_PETAL_POW * 1.3)
        * env2 * 0.9;

    // 层 3：外层细瓣（反向旋、更慢）
    float a3 = ang - ts * 0.013 + sd * 2.3;
    float fa3 = abs(fract(a3 / TAU * n3) - 0.5) * 2.0;
    float b3 = fract(ts * MD_BLOOM_RATE + 0.66);
    float rr3 = r / (0.95 * breath);
    float env3 = smoothstep(0.05, 0.35, rr3 - b3 * 0.8)
        * smoothstep(1.1, 0.65, rr3 - b3 * 0.8)
        * (1.0 - b3 * 0.55);
    col += pal2(hueBase + 0.36) * pow(max(sin(fa3 * PI), 0.0), 2.2)
        * env3 * 0.75;

    // 核心辉光（beat 镀亮）+ 瓣尖辉光
    col += pal(hueBase + 0.1) * exp(-r * r * 380.0)
        * (0.5 + 0.6 * uBeat);
    col += pal(hueBase + 0.42) * env1 * env2 * 0.30 * (0.6 + 0.6 * uBeat);
    col += pal(hueBase + 0.2) * 0.016; // 基底微光
    return col;
}

// 形态分发（仅前二名会被调用）
vec3 evalMode(int idx, vec2 q, float ts, float sd) {
    if (idx == 0) return modeRings(q, ts, sd);
    if (idx == 1) return modeChamber(q, ts, sd);
    if (idx == 2) return modeTunnel(q, ts, sd);
    return modeMandala(q, ts, sd);
}

void main() {
    float ts = nowSec();
    float sd = seedHash() * SEED_SPREAD;
    vec2 q = sceneUV(vec2(0.5));

    // ---- 四路 winner-take-most 权重（wander 无周期）----
    float w0 = pow(wander2(ts, MODE_SCALE_0, sd + 1.0), MODE_SHARP);
    float w1 = pow(wander2(ts, MODE_SCALE_1, sd + 13.1), MODE_SHARP);
    float w2 = pow(wander2(ts, MODE_SCALE_2, sd + 27.7), MODE_SHARP);
    float w3 = pow(wander2(ts, MODE_SCALE_3, sd + 41.3), MODE_SHARP);

    int maxIdx = 0;
    float wmax = w0;
    if (w1 > wmax) { wmax = w1; maxIdx = 1; }
    if (w2 > wmax) { wmax = w2; maxIdx = 2; }
    if (w3 > wmax) { wmax = w3; maxIdx = 3; }
    float c0 = maxIdx == 0 ? -1.0 : w0;
    float c1 = maxIdx == 1 ? -1.0 : w1;
    float c2 = maxIdx == 2 ? -1.0 : w2;
    float c3 = maxIdx == 3 ? -1.0 : w3;
    float wsec = max(max(c0, c1), max(c2, c3));
    int secIdx = 0;
    if (wsec == c1) secIdx = 1;
    if (wsec == c2) secIdx = 2;
    if (wsec == c3) secIdx = 3;

    float wsum = wmax + wsec + 1e-5;
    float kSec = wsec / wsum;

    vec3 col;
    if (kSec > BLEND_SKIP) {
        col = (evalMode(maxIdx, q, ts, sd) * wmax
            + evalMode(secIdx, q, ts, sd) * wsec) / wsum;
    } else {
        col = evalMode(maxIdx, q, ts, sd);
    }

    // beat 只进亮度
    col *= 0.94 + 0.18 * uBeat;
    col *= 1.0 - VIGNETTE * dot(q, q);

    // 反馈拖尾：RINGS 用对齐流速的缩放率，其余近恒等轻模糊
    float ringsW = 0.0;
    if (maxIdx == 0) ringsW = wmax / wsum;
    if (secIdx == 0 && kSec > BLEND_SKIP) ringsW = max(ringsW, wsec / wsum);
    vec3 prevZ = texture2D(uPrev, (vUV - 0.5) * TRAIL_ZOOM + 0.5).rgb;
    vec3 prevS = texture2D(uPrev, (vUV - 0.5) * TRAIL_ZOOM_SOFT + 0.5).rgb;
    col += mix(prevS, prevZ, ringsW) * TRAIL_GAIN;

    col = toneExp(col, TONE_EXPOSURE);
    col = satBoost(col, SAT_BOOST);
    col += dither(vUV * uRes, ts);

    col = applyTransition(col);

    gl_FragColor = vec4(col, 1.0);
}
