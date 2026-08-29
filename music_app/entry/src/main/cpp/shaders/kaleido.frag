// kaleido.frag：无尽万花筒（对数极坐标八度深潜 × 每环独立对称群 × 混沌演化）。
//
// 架构（fractal 已验证的同款，别回退到反馈深潜）：
//   lr = −log2(ρ) + D，D = ts × 恒定速度（严格单调，beat 永不进速度）；
//   每个整数八度环带 = 一圈独立的"万花筒环"，图案直绘——
//   反馈深潜（旧版）每帧双线性重采样，纹样流向边缘的路上必然糊成雾，
//   万花筒的镜像结构必须锐利，所以结构全部直绘，反馈只留对齐流速的
//   轻拖尾（运动模糊）。
//
// 多样性从哪来：
//   1. 每环独立身份（环号 hash）：对称重数 3~11、旋转方向/速率、
//      纹样缩放、色相基准、环亮度——相邻环天然"内花外齿轮"；
//   2. 一切时间演化由 wander 时域随机游走驱动（无周期，见 common.glsl）：
//      环旋转是有界随机游走（平滑过零换向）、纹样五形态权重
//      winner-take-most 轮换、镜像 D_n ↔ 锯齿 C_n 模式 morph、
//      双调色板 crossfade、全局色相漂移——永不重复；
//   3. 镜片缝线（扇区界细亮线 + 环缘玻璃亮边）——真万花筒的切玻璃感。
//
// 公共函数（hash/vn/wander/rot/palIQ/satBoost/toneExp/dither/…）由工具链
// 从 common.glsl 注入，不要在本文件重复定义。

// ---- 深潜几何 -----------------------------------------------------------
const float LNS = 0.6931472;        // log(2)
const float DIVE_SPEED = 0.45;      // 深潜速度（八度/秒，恒定！）
const float CENTER_FADE = 0.045;    // 中心消失点淡出（消锯齿）
const float CORE_GLOW = 700.0;      // 核心辉光收紧程度

// ---- 环带身份 -----------------------------------------------------------
const float ROT_SPAN = 1.25;        // 环旋转游走幅度（弧度，双向）
const float ROT_SCALE = 43.0;       // 环旋转游走时间尺度（秒/格）
const float BARREL_SWAY = 0.28;     // 整体转筒慢摆幅度（弧度）
const float FOLD_MIN = 3.0;         // 对称重数下限（3 + hash×8.999 → 3~11）

// ---- 纹样 ---------------------------------------------------------------
// 权重时间尺度互相错开（秒/格）
const float W_SCALE_1 = 29.0;
const float W_SCALE_2 = 37.0;
const float W_SCALE_3 = 23.0;
const float W_SCALE_4 = 31.0;
const float W_SHARP = 2.2;          // 权重锐化：winner-take-most（均等混合
                                    //   = 四种纹样常年叠成平均灰）
const float MODE_SCALE = 53.0;      // 镜像 ↔ 锯齿 morph 时间尺度
const float EDGE_LINE_SHARP = 36.0; // 扇区缝线锐度
const float EDGE_LINE_GAIN = 0.35;
const float RIM_SHARP = 50.0;       // 环缘玻璃亮边锐度

// ---- 色彩 ---------------------------------------------------------------
const vec3 PAL_C = vec3(0.9, 1.0, 1.1);
const vec3 PAL_D = vec3(0.0, 0.12, 0.38);
const vec3 PAL_C2 = vec3(1.1, 0.9, 1.0);
const vec3 PAL_D2 = vec3(0.35, 0.10, 0.55);
const float HUE_WANDER = 0.25;      // 全局色相游走幅度
const float MAIN_GAIN = 1.00;

// ---- 收尾 ---------------------------------------------------------------
const float TONE_EXPOSURE = 1.05;
const float SAT_BOOST = 0.72;
const float VIGNETTE = 0.30;
const float TRAIL_ZOOM = 0.9897;    // = 2^(−0.45/30)，对齐恒定流速（30fps）
const float TRAIL_GAIN = 0.30;      // 运动模糊（别超 ~0.35，盖过新内容）
const float SEED_SPREAD = 173.0;

vec3 pal(float t) {
    return palIQ(t, PAL_C, PAL_D);
}

vec3 pal2(float t) {
    return palIQ(t, PAL_C2, PAL_D2);
}

// 二面体镜像折叠（D_n 经典万花筒）：0(镜面轴)..1(扇区界)。
// 重数取整数：mod 的 ±π 接缝被 TAU/seg 整数倍吸收，无角向缝。
float foldD(float a, float n) {
    float seg = TAU / n;
    return abs(mod(a, seg) - seg * 0.5) / (seg * 0.5);
}

// 旋转折叠（C_n 旋涡轮辐）：0..1 锯齿（扇区界处跳变 = 尖锐辐条）
float foldC(float a, float n) {
    float seg = TAU / n;
    return mod(a, seg) / seg;
}

// ---- 四种纹样（fa 折叠角坐标 0..1，fr 环带径向，ph 慢漂相位）--------------
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

// 切玻璃碎面：交叉斜向棱线，暗棱亮面——最"万花筒"的纹样
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
    // 闪烁也走 wander：同速率不同相位 → 星火感但不机械
    float tw = wander(ts, 2.0, h * 40.0 + sd + ph);
    return step(0.62, h) * exp(-dot(fp - cp, fp - cp) * 30.0) * tw * 2.0;
}

void main() {
    float ts = nowSec();
    float sd = seedHash() * SEED_SPREAD;
    vec2 q = sceneUV(vec2(0.5));
    float transA = smoothstep(0.0, 1.0, clamp(uTransition, 0.0, 1.0));

    // ---- 八度流：D 严格单调（beat 只进亮度/转角，永不进速度）----
    float D = ts * DIVE_SPEED + sd * 0.37;

    float rho = max(length(q), 1e-4);
    float ang = atan(q.y, q.x);

    float lr = -log(rho) / LNS + D;
    float ringK = floor(lr);
    float fr = fract(lr);           // 0=环外缘（浅）→ 1=环内缘（深）

    // ---- 每环独立身份（环号 hash；同环内恒定，环间切换）----
    float rk1 = hash11(ringK * 0.913 + sd);
    float rk2 = hash11(ringK * 1.711 + sd + 5.0);
    float rk3 = hash11(ringK * 2.399 + sd + 11.0);
    float rk4 = hash11(ringK * 3.127 + sd + 17.0);
    float nFold = FOLD_MIN + floor(rk1 * 8.999);
    float sdr = sd + ringK * 7.7;

    // 环旋转：有界随机游走（平滑过零换向）× 每环方向/速率 + beat 微抖
    float rotAng = (rk2 - 0.5) * 2.0 * ROT_SPAN
        * wanderBi(ts, ROT_SCALE, sd + ringK * 3.1)
        + uBeat * 0.15 * (rk4 - 0.5);
    // 整体转筒慢摆
    float a = ang + rotAng + BARREL_SWAY * wanderBi(ts, 87.0, sd + 3.3);

    // 镜像 D_n ↔ 锯齿 C_n 模式 morph（压向两端，大部分时间是纯模式）
    float modeK = smoothstep(0.25, 0.75,
        wander2(ts, MODE_SCALE, sd + ringK * 9.7 + rk3));
    float fa = mix(foldD(a, nFold), foldC(a, nFold), modeK);

    // ---- 纹样：五形态 winner-take-most 轮换（全部 wander 驱动）----
    float frP = fr * (0.7 + 0.9 * rk4); // 每环纹样密度不同
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
    // 各纹样按平均覆盖率归一化（稀疏 dots ×1.45、致密 lattice ×0.85…）：
    // 不做归一时，形态轮换 = 全屏亮度轮换（实测起伏 2×，超 1.8× 目标带）
    float I = (patPetal(fa, frP, ph1, sdr) * 1.00 * w1
        + patStar(fa, frP, ph2, sdr) * 1.05 * w2
        + patLattice(fa, frP, ph3, sdr) * 0.85 * w3
        + patShard(fa, frP, ph5, sdr) * 0.95 * w5
        + patDots(fa, frP, ph4, sdr, ts) * 1.45 * w4) / wsum;
    I = pow(I, 0.75); // 抬稀疏相位的覆盖率，进一步压缩形态间亮度差

    // ---- 着色：每环色相基准不同 + 全局慢游 + beat 微扰 ----
    float hueBase = rk3 + HUE_WANDER * wanderBi(ts, 67.0, sd + 4.4)
        + uTreble * 0.03;
    float hue = hueBase + fa * (0.10 + 0.08 * rk2) + fr * (0.15 * rk4);
    float palK = smoothstep(0.2, 0.8, wander2(ts, 97.0, sd + 8.8));
    vec3 colr = mix(pal(hue), pal2(hue), palK);
    // 色度归一（只压不抬）：余弦色轮各相位固有亮度差 ~2 倍（黄 0.8/紫 0.4），
    // 每环色相基准是环号抽签 → 亮环过境全屏泛白、紫环过境全屏转暗。
    // 把亮于 REF 的色度压回 REF，色相性格保留、亮度彩票消除
    float pl = dot(colr, vec3(0.299, 0.587, 0.114));
    colr *= min(1.0, 0.44 / max(pl, 1e-3));

    float ringGain = 0.82 + 0.18 * rk2; // 每环明暗性格不同（压缩区间：
                                        //   环亮度是逐环切换的，差太大
                                        //   会让全屏亮度随深潜大幅起伏）
    vec3 col = colr * I * ringGain * MAIN_GAIN;
    // 基底微光：兜住稀疏纹样相位（dots 主导时覆盖率低）的整屏过暗
    col += colr * 0.028;

    // 镜片缝线（扇区界）+ 环缘玻璃亮边（外缘亮、内缘弱）
    float edgeLine = exp(-fa * EDGE_LINE_SHARP)
        + exp(-(1.0 - fa) * EDGE_LINE_SHARP);
    col += mix(vec3(1.0), colr, 0.35) * edgeLine * EDGE_LINE_GAIN * ringGain;
    float rim = exp(-fr * RIM_SHARP) * 0.6 + exp(-(1.0 - fr) * RIM_SHARP) * 0.3;
    col += mix(vec3(1.0), colr, 0.5) * rim * ringGain;

    // beat 只进亮度
    col *= 0.94 + 0.18 * uBeat;
    col *= transA;

    // 中心消失点：淡出消锯齿 + 核心辉光强化"往里钻"
    col *= smoothstep(0.0, CENTER_FADE, rho);
    float hueCore = rk3 + 0.2 * wanderBi(ts, 61.0, sd + 6.6) + uTreble * 0.05;
    col += pal(hueCore + 0.10) * exp(-rho * rho * CORE_GLOW)
        * (0.45 + 0.55 * uBeat) * transA;
    col *= 1.0 - VIGNETTE * dot(q, q);

    // 反馈拖尾：缩放率对齐恒定八度流速 → 只是沿光流方向的运动模糊
    vec2 prevUV = (vUV - 0.5) * TRAIL_ZOOM + 0.5;
    col += texture2D(uPrev, prevUV).rgb * TRAIL_GAIN;

    col = toneExp(col, TONE_EXPOSURE);
    col = satBoost(col, SAT_BOOST);
    col += dither(vUV * uRes, ts);

    gl_FragColor = vec4(col, 1.0);
}
