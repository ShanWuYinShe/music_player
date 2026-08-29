// fractal.frag：无限分形深潜（对数极坐标 · 自相似八度流 · Julia 逃逸时间丝）。
//
// "平滑"是怎么保证的（旧版"来回缩放"的三个根源都已拆除）：
//   1. 深潜行程 D 必须单调：旧版 D = ts × (速度 + beat×uBeat)，beat 包络
//      每拍从 1 衰减到 0.25，D 在拍间**真的倒退**——这就是"来回缩放"。
//      现在 D = ts × 恒定速度，beat 只进亮度/核心辉光（亮度脉冲不会造成
//      运动伪影），反馈拖尾缩放率因此也与流速严格对齐，不再抽动。
//   2. 单层图案的周期（6 八度 ≈ 10s）会让内容"重演一遍"，观感像缩放到头
//      又回来。现在叠加第二层**不可通约周期**（6φ ≈ 9.7 八度）的结构，
//      两层以 ~12 分钟的慢速交叉淡化 → 合成图案事实上不再重复。
//   3. 万花筒重数在 6/8 之间慢 morph（两个整数折叠各自连续，混合也连续，
//      不留角向接缝）。
//
// 旧有两条硬经验仍然成立（都是踩坑踩出来的，别回退）：
//   - 变化必须发生在连续坐标上：按整数层号跳变参数 = 每隔几秒画面突变一次。
//   - 单层周期要对齐屏幕径向跨度（rho 0.02~0.7 ≈ 5~6 个八度）：周期取太大，
//     "集内面积"随深度忽大忽小，整屏周期性忽明忽暗。
//
// 公共函数（hash/vn/rot/palIQ/toneExp/applyTransition/…）由工具链从
// common.glsl 注入，不要在本文件重复定义。

// ---- 深潜几何 -----------------------------------------------------------
const float LNS = 0.6931472;        // log(2)：八度坐标以 2 为底
const float OCT_PERIOD = 6.0;       // 第一层图案周期（八度数），对齐屏幕径向跨度
const float OCT_PERIOD_2 = 9.7082039; // 第二层：6φ，与第一层不可通约
const float DIVE_SPEED = 0.58;      // 深潜速度（八度/秒）≈ 每秒放大 1.5 倍（恒定！）
const float LAYER_BLEND_RATE = 0.009; // 双层交叉淡化速率（~12 分钟一轮）
const float SEED_SPREAD = 211.0;
const float SEED_DIVE_OFFSET = 0.37;

// ---- 角向结构 -----------------------------------------------------------
const float SYM_A = 6.0;            // 万花筒重数 A（整数，否则角向 mod 留缝）
const float SYM_B = 8.0;            // 万花筒重数 B
const float SYM_MORPH_RATE = 0.007; // 重数 morph 速率
const float ANGLE_DRIFT_AMP = 0.06; // 角向整体慢漂（连续坐标，不破坏周期）
const float ANGLE_DRIFT_RATE = 0.017;

// ---- Julia 切片 ---------------------------------------------------------
const int JULIA_ITER = 12;          // 迭代次数（也是"集内"判定阈值）
const float ESCAPE_R2 = 24.0;       // 逃逸半径平方
const float RING_R_X = 1.16;        // 初值闭合主环半径（x/y 略椭圆）
const float RING_R_Y = 1.00;        //   推太远（如 1.30）集内面积太小 → 整屏过暗
const float RING_TANGENT = 1.15;    // 角向 a 沿环切线方向的展开幅度
const vec2 JULIA_C = vec2(-0.7269, 0.1889); // Julia 常数（经典海马谷附近）
const float C_DRIFT_AMP = 0.10;     // c 随播放时钟的慢漂幅度（形态缓慢演化）
const float C_BASS_AMP = 0.03;      // bass 驱动的额外漂移

// ---- 着色 ---------------------------------------------------------------
const float BAND_FREQ = 0.85;       // 逃逸等值丝的空间频率
const float BAND_SCROLL = 0.04;     // 等值丝随时间的滚动速度
const float FILAMENT_POW = 7.0;     // 丝线锐度
const float TRAP_GLOW_FALLOFF = 1.4;// 轨道陷阱辉光衰减
const vec3 PAL_C = vec3(1.0, 0.95, 0.9);  // 色族（palIQ 的频率向量）
const vec3 PAL_D = vec3(0.0, 0.15, 0.35); // 色族（palIQ 的相位向量）
const vec3 PAL_D_2 = vec3(0.45, 0.10, 0.72); // 第二层色族（相位错开，两层不同色）
const float MAIN_GAIN = 1.40;
const float DEEP_FILL = 0.015;      // 集内微弱填充（写过大会整屏铺雾发灰）
const float TRAP_FILL = 0.020;
const float FLOOR_GLOW = 0.005;

// ---- 收尾 ---------------------------------------------------------------
const float CENTER_FADE = 0.045;    // 中心消失点淡出（消锯齿）
const float CORE_GLOW = 700.0;      // 核心辉光收紧程度
const float VIGNETTE = 0.22;
const float TRAIL_ZOOM = 0.9867;    // 反馈缩放率 = 2^(−0.58/30)，对齐恒定流速(30fps)
const float TRAIL_GAIN = 0.26;      // 只是运动模糊，别盖过新内容
const float SHADOW_LIFT = 0.82;     // 抬暗部的 gamma（0.70 太狠会掉饱和度）

vec3 pal(float t) {
    return palIQ(t, PAL_C, PAL_D);
}

vec3 pal2(float t) {
    return palIQ(t, PAL_C, PAL_D_2);
}

// 周期性值噪声：格点索引对 per 取模 → 沿八度方向严格周期（频率必须取整数）
float pnoise(vec2 p, vec2 per) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);
    float a = hash21(mod(i, per));
    float b = hash21(mod(i + vec2(1.0, 0.0), per));
    float c = hash21(mod(i + vec2(0.0, 1.0), per));
    float d = hash21(mod(i + vec2(1.0, 1.0), per));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// Julia 逃逸时间场：返回 (平滑逃逸计数 sm, 轨道陷阱最小距离平方 trap)。
// sm = JULIA_ITER 表示迭代内从未逃逸（= 集内）。
vec2 juliaField(vec2 z0, vec2 cc) {
    vec2 zc = z0;
    float esc = -1.0;
    float trap = 1e9;
    for (int i = 0; i < JULIA_ITER; i++) {
        zc = vec2(zc.x * zc.x - zc.y * zc.y, 2.0 * zc.x * zc.y) + cc;
        float r2 = dot(zc, zc);
        trap = min(trap, r2);
        if (r2 > ESCAPE_R2) {
            esc = float(i);
            break;
        }
    }
    // 平滑逃逸计数：消掉整数阶梯，等值丝才连续
    float sm = float(JULIA_ITER);
    if (esc >= 0.0) {
        float r2 = max(dot(zc, zc), 1e-4);
        sm = clamp(esc + 1.0 - log(max(log(r2) * 0.5, 1e-4)) / LNS, 0.0, float(JULIA_ITER));
    }
    return vec2(sm, trap);
}

// 一层八度结构的颜色贡献。period 为该层的八度周期，sym 为角向折叠重数，
// palSel 选色族；layerPh 错开两层的等值丝相位。
vec3 octaveLayer(float lr, float angN, float period, float sym,
    float layerPh, float ts, float sd, vec2 cc, bool second) {
    float fN = fract(lr / period);
    // 角向整数重对称折叠（万花筒）
    float a = abs(fract(angN * sym) - 0.5) * 2.0;

    // Julia 初值：沿闭合曲线取（沿八度方向周期 → 缩放无缝）
    float th = TAU * fN + layerPh;
    vec2 ring = vec2(RING_R_X * cos(th), RING_R_Y * sin(th));
    vec2 tang = vec2(-sin(th), cos(th));
    vec2 z0 = ring + (a - 0.5) * RING_TANGENT * tang;

    vec2 field = juliaField(z0, cc);
    float sm = field.x;
    float trap = field.y;
    // 注意：sm=JULIA_ITER 表示"从未逃逸"= 集内。deep=1 才是集内
    float deep = clamp(sm / float(JULIA_ITER), 0.0, 1.0);

    // 分形丝：逃逸等值线 + 轨道陷阱 + 周期噪声细纹
    float band = abs(fract(sm * BAND_FREQ - ts * BAND_SCROLL + layerPh) - 0.5) * 2.0;
    float fil = pow(1.0 - band, FILAMENT_POW);
    float trapGlow = exp(-trap * TRAP_GLOW_FALLOFF);
    float tex = pnoise(vec2(a * 12.0, fN * 16.0), vec2(16.0)) * 0.5
        + pnoise(vec2(a * 24.0, fN * 32.0), vec2(32.0)) * 0.25;
    // 纹理**调制**丝线而非单独加亮——否则每一项都铺满全屏，整体泛白
    fil *= 0.55 + 0.45 * tex;

    float hue = 0.55 * deep + 0.22 * fil + 0.12 * trapGlow
        + 0.10 * tex + 0.03 * sin(ts * 0.02 + sd) + uTreble * 0.05;

    vec3 p0 = pal(hue);
    vec3 p1 = pal2(hue);
    vec3 pc = second ? p1 : p0;
    vec3 pcA = second ? pal2(hue + 0.32) : pal(hue + 0.32);
    vec3 pcB = second ? pal2(hue + 0.62) : pal(hue + 0.62);

    vec3 col = pc * fil * MAIN_GAIN;
    col += pcA * deep * DEEP_FILL;
    col += pcB * trapGlow * TRAP_FILL;
    col += mix(pcA, pcB, 0.5) * FLOOR_GLOW;
    return col;
}

void main() {
    float ts = nowSec();
    float sd = seedHash() * SEED_SPREAD;
    vec2 q = sceneUV(vec2(0.5));

    // ---- 八度流：D = 已深入的八度数（恒定速度、严格单调、永不回绕）----
    float D = ts * DIVE_SPEED + sd * SEED_DIVE_OFFSET;

    float rho = max(length(q), 1e-4);
    float ang = atan(q.y, q.x);

    // 八度坐标：中心恒为无限深，边缘最浅
    float lr = -log(rho) / LNS + D;
    float angN = ang / TAU + 0.5 + ANGLE_DRIFT_AMP * sin(ts * ANGLE_DRIFT_RATE + sd);

    // c 随播放时钟极慢漂移：整体形态缓慢演化，同时不破坏八度周期性
    vec2 cc = JULIA_C
        + C_DRIFT_AMP * vec2(sin(ts * 0.013 + sd), cos(ts * 0.011 + sd * 1.7))
        + C_BASS_AMP * uBass * vec2(sin(ts * 0.004 + sd), cos(ts * 0.004 + sd));

    // ---- 双层结构：不可通约周期 + 慢速交叉淡化 → 图案事实上不再重演 ----
    float symK = 0.5 + 0.5 * sin(ts * SYM_MORPH_RATE + sd * 0.9);
    float sym = mix(SYM_A, SYM_B, symK); // 两个整数折叠线性混合，无角向接缝
    float layerK = 0.5 + 0.5 * sin(ts * LAYER_BLEND_RATE + sd * 1.1);
    vec3 colA = octaveLayer(lr, angN, OCT_PERIOD, sym, 0.0, ts, sd, cc, false);
    vec3 colB = octaveLayer(lr + OCT_PERIOD_2 * 0.618, angN, OCT_PERIOD_2, sym, 2.1, ts, sd, cc, true);
    vec3 col = mix(colA, colB, layerK);

    // beat 只进亮度（旧版进速度会让行程倒退——"来回缩放"的根源）
    col *= 0.95 + 0.18 * uBeat;

    // 中心是消失点：淡出消锯齿 + 核心辉光强化"往里钻"
    col *= smoothstep(0.0, CENTER_FADE, rho);
    float hueCore = 0.03 * sin(ts * 0.02 + sd) + uTreble * 0.05;
    col += pal(hueCore + 0.10) * exp(-rho * rho * CORE_GLOW) * (0.45 + 0.55 * uBeat);
    col *= 1.0 - VIGNETTE * dot(q, q);

    // 反馈拖尾：缩放率与恒定八度流速严格对齐 → 只是沿光流方向的运动模糊
    vec2 prevUV = (vUV - 0.5) * TRAIL_ZOOM + 0.5;
    col += texture2D(uPrev, prevUV).rgb * TRAIL_GAIN;

    col = toneExp(col, 1.0);
    // 抬暗部压缩"周期性忽明忽暗"的观感幅度
    col = pow(col, vec3(SHADOW_LIFT));

    col = applyTransition(col);

    gl_FragColor = vec4(col, 1.0);
}
