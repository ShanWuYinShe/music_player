// fractal.frag：递归分形深潜（对数极坐标八度流 × KIFS 折叠 × Julia 逃逸丝）。
//
// 与旧版的本质区别——"递归感"从哪来：
//   旧版图案是「单层 Julia 逃逸场沿径向周期复制」：每个八度看到的是同一个
//   环切片的平铺，自相似只发生在"重复"层面，没有"越放大越有东西"的递归。
//   新版图案由 KIFS（万花筒迭代函数系统）提供：每个八度带内的图案本身经过
//   9 次「镜面折叠 → 旋转 → 缩放 → 平移」迭代，每多迭代一次多一层自相似
//   结构——大瓣里有小瓣、小瓣里有更小的晶格，这才是递归。
//
// 形态多样性：两套场在连续权重上慢漂轮换（不按整数层号跳变！）：
//   - KIFS 晶体：几何、棱角、雪花/晶格感；轨道陷阱（orbit trap）给出
//     自相似丝线，轨道驻留密度给出晶体体块；
//   - Julia 有机丝：逃逸时间等值线 + 平滑计数，流动、生物感。
//   两层周期各带一个不可通约的权重速率，合成形态极长周期才重复。
//   权重经 smoothstep 压向 0/1：大部分时间在单一形态（且另一形态整场
//   跳过不计算——权重是帧级 uniform，分支是全 warp 一致的，不花冤枉钱），
//   过渡期两形态连续 crossfade。
//
// 色彩随深度分层：KIFS 记录"轨道最接近原点的迭代层号"（argmin trap），
// 层号直接映射色相——外层结构与内层递归细节不同色，一眼读出嵌套深度；
// 再叠加八度径向相位与慢漂，两层周期用两套相位错开的色族。
//
// 旧版用血换来的平滑性经验全部保留（别回退）：
//   1. 深潜行程 D = ts × 恒定速度，严格单调；beat 只进亮度/核心辉光，
//      永不进速度（行程倒退 = "来回缩放"观感）。
//   2. 单层图案周期（6 八度）对齐屏幕径向跨度（rho 0.02~0.7 ≈ 5~6 八度），
//      再叠第二层不可通约周期（6φ ≈ 9.7 八度）慢速交叉淡化 → 图案事实上
//      不再重演，也没有周期性忽明忽暗。
//   3. 一切变化发生在连续坐标上的慢漂移；参数按整数序号跳变 = 每隔几秒
//      画面突变一次。
//   4. KIFS 自相似比 s 别超 ~2.3，再大吸引子稀疏到画面近黑（MEMORY.md）。
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

// ---- 形态轮换（Julia 有机丝 ↔ KIFS 递归晶体）----------------------------
// 速率按"一首歌内必须看到形态显著变化"标定：半周期 ≈ 一首歌时长量级
const float FORM_RATE = 0.021;      // 第一层形态权重速率（整周期 ~5 分钟）
const float FORM_RATE_2 = 0.034;    // 第二层（不可通约）

// ---- Julia 切片 ---------------------------------------------------------
const int JULIA_ITER = 12;          // 迭代次数（也是"集内"判定阈值）
const float ESCAPE_R2 = 24.0;       // 逃逸半径平方
const float RING_R_X = 1.16;        // 初值闭合主环半径（x/y 略椭圆）
const float RING_R_Y = 1.00;        //   推太远（如 1.30）集内面积太小 → 整屏过暗
const float RING_TANGENT = 1.15;    // 角向 a 沿环切线方向的展开幅度
const vec2 JULIA_C = vec2(-0.7269, 0.1889); // Julia 常数（经典海马谷附近）
const float C_DRIFT_AMP = 0.10;     // c 随播放时钟的慢漂幅度（形态缓慢演化）
const float C_BASS_AMP = 0.03;      // bass 驱动的额外漂移

// ---- KIFS 递归折叠 -------------------------------------------------------
const int KIFS_ITER = 9;            // 递归层数 = 自相似嵌套深度
const float KIFS_S_BASE = 1.90;     // 自相似比基准（>2.3 吸引子稀疏近黑）
const float KIFS_S_DRIFT = 0.16;    // 自相似比慢漂（1.74~2.06；实测漂到 2.1+
                                    //   吸引子过疏、整屏 lum 跌破 0.12）
const float KIFS_S_BASS = 0.04;     // bass 微胀缩（呼吸感）
const vec2 KIFS_OFF_BASE = vec2(0.90, 0.65); // 平移量基准
const float KIFS_OFF_DRIFT = 0.30;  // 平移量慢漂（改变折叠缺口位置 → 晶形演化）
const float KIFS_ROT_AMP = 0.45;    // 每层折叠后的旋转角慢漂（弧度）
const float KIFS_TRAP_SHARP = 5.0;  // 轨道陷阱丝线锐度
const float KIFS_DENS_K = 3.0;      // 驻留密度衰减
const float KIFS_ESCAPE_R2 = 36.0;  // 轨道发散截断（防 mediump 溢出，也省算力）
const float KIFS_LEV_HUE = 0.55;    // 递归层号 → 色相的跨度（深度分层核心）

// ---- 着色 ---------------------------------------------------------------
const float BAND_FREQ = 0.85;       // 逃逸等值丝的空间频率
const float BAND_SCROLL = 0.04;     // 等值丝随时间的滚动速度
const float FILAMENT_POW = 7.0;     // 丝线锐度
const float TRAP_GLOW_FALLOFF = 1.4;// Julia 轨道陷阱辉光衰减
const vec3 PAL_C = vec3(1.0, 0.95, 0.9);  // 色族（palIQ 的频率向量）
const vec3 PAL_D = vec3(0.0, 0.15, 0.35); // 色族（palIQ 的相位向量）
const vec3 PAL_D_2 = vec3(0.45, 0.10, 0.72); // 第二层色族（相位错开，两层不同色）
const float MAIN_GAIN = 1.40;       // Julia 丝线主增益
const float KIFS_FIL_GAIN = 1.30;   // KIFS 丝线主增益
const float DEEP_FILL = 0.020;      // 集内微弱填充（写过大会整屏铺雾发灰）
const float TRAP_FILL = 0.020;
const float KIFS_DENS_FILL = 0.13;  // KIFS 晶体体块填充
const float FLOOR_GLOW = 0.016;     // 基底微光：兜住稀疏相位的整屏过暗
                                    // （稳定性实测：0.005 时暗相位 lum 跌到 0.11，
                                    //  亮暗起伏 2.04× 超 1.8× 目标带）

// ---- 收尾 ---------------------------------------------------------------
const float CENTER_FADE = 0.045;    // 中心消失点淡出（消锯齿）
const float CORE_GLOW = 700.0;      // 核心辉光收紧程度
const float VIGNETTE = 0.22;
const float TRAIL_ZOOM = 0.9867;    // 反馈缩放率 = 2^(−0.58/30)，对齐恒定流速(30fps)
const float TRAIL_GAIN = 0.30;      // 运动模糊 + 阻尼八度相位间亮暗摆动
                                    // （别超 ~0.35：会盖过新内容、深潜变"拖泥带水"）
const float SHADOW_LIFT = 0.76;     // 抬暗部的 gamma：压缩八度相位间亮暗摆动
                                    // （0.70 太狠会掉饱和度——旧版教训，别越界）

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

// KIFS 递归折叠场：返回 (trap, levN, densN)。
//   trap  = 轨道全程距原点最近距离平方（丝线）；
//   levN  = 达到最近距离的迭代层号 / (ITER-1)（递归深度 → 色相分层）；
//   densN = 轨道驻留密度归一（晶体体块）。
// 折叠参数全部随播放时钟慢漂：自相似比 / 平移缺口 / 每层旋转角都在演化，
// 晶形在"致密雪花 ↔ 开张晶枝"间连续变形，绝不用层号跳变参数。
vec3 kifsField(vec2 p0, float ts, float sd) {
    float s = KIFS_S_BASE + KIFS_S_DRIFT * sin(ts * 0.011 + sd * 1.3)
        + KIFS_S_BASS * uBass;
    vec2 koff = KIFS_OFF_BASE + KIFS_OFF_DRIFT * vec2(
        sin(ts * 0.007 + sd * 2.1), cos(ts * 0.009 + sd * 1.7));
    mat2 kR = rot(KIFS_ROT_AMP * sin(ts * 0.008 + sd * 0.9));
    vec2 z = p0;
    float trap = 1e9;
    float lev = 0.0;
    float dens = 0.0;
    for (int i = 0; i < KIFS_ITER; i++) {
        z = kR * abs(z) * s - koff; // 镜面折叠 → 旋转 → 缩放 → 平移
        float d2 = dot(z, z);
        dens += exp(-d2 * KIFS_DENS_K);
        if (d2 < trap) {
            trap = d2;
            lev = float(i);
        }
        if (d2 > KIFS_ESCAPE_R2) {
            break; // 轨道发散：后续项对 trap/dens 无贡献
        }
    }
    return vec3(trap, lev / float(KIFS_ITER - 1), clamp(dens * 0.25, 0.0, 1.0));
}

// 一层八度结构的颜色贡献。period 为该层的八度周期，sym 为角向折叠重数，
// layerPh 错开两层的等值丝相位，second 选第二层色族。
vec3 octaveLayer(float lr, float angN, float period, float sym,
    float layerPh, float ts, float sd, vec2 cc, bool second) {
    float fN = fract(lr / period);
    // 角向整数重对称折叠（万花筒）
    float a = abs(fract(angN * sym) - 0.5) * 2.0;

    // 图案切片：沿闭合曲线取初值（沿八度方向周期 → 缩放无缝）
    float th = TAU * fN + layerPh;
    vec2 ring = vec2(RING_R_X * cos(th), RING_R_Y * sin(th));
    vec2 tang = vec2(-sin(th), cos(th));
    vec2 p0 = ring + (a - 0.5) * RING_TANGENT * tang;

    // 周期噪声细纹：调制丝线而非单独加亮——否则每一项都铺满全屏泛白
    float tex = pnoise(vec2(a * 12.0, fN * 16.0), vec2(16.0)) * 0.5
        + pnoise(vec2(a * 24.0, fN * 32.0), vec2(32.0)) * 0.25;

    float hueDrift = 0.03 * sin(ts * 0.02 + sd) + uTreble * 0.05;

    // 形态权重：Julia ↔ KIFS 慢漂，smoothstep 压向两端（大部分帧只算一套场，
    // 权重是帧级 uniform → 分支全 warp 一致，跳过的一套零成本）
    float wK = smoothstep(0.12, 0.88,
        0.5 + 0.5 * sin(ts * (second ? FORM_RATE_2 : FORM_RATE)
            + sd * (second ? 1.9 : 0.7) + layerPh));

    vec3 col = vec3(0.0);

    if (wK < 0.995) {
        // ---- Julia 有机丝 ----
        vec2 field = juliaField(p0, cc);
        float sm = field.x;
        float trap = field.y;
        // 注意：sm=JULIA_ITER 表示"从未逃逸"= 集内。deep=1 才是集内
        float deep = clamp(sm / float(JULIA_ITER), 0.0, 1.0);
        float band = abs(fract(sm * BAND_FREQ - ts * BAND_SCROLL + layerPh) - 0.5) * 2.0;
        float fil = pow(1.0 - band, FILAMENT_POW);
        float trapGlow = exp(-trap * TRAP_GLOW_FALLOFF);
        fil *= 0.55 + 0.45 * tex;

        float hue = 0.55 * deep + 0.22 * fil + 0.12 * trapGlow
            + 0.10 * tex + hueDrift;
        vec3 pc = second ? pal2(hue) : pal(hue);
        vec3 pcA = second ? pal2(hue + 0.32) : pal(hue + 0.32);
        vec3 pcB = second ? pal2(hue + 0.62) : pal(hue + 0.62);

        vec3 colJ = pc * fil * MAIN_GAIN;
        colJ += pcA * deep * DEEP_FILL;
        colJ += pcB * trapGlow * TRAP_FILL;
        col += colJ * (1.0 - wK);
    }

    if (wK > 0.005) {
        // ---- KIFS 递归晶体 ----
        vec3 kf = kifsField(p0, ts, sd);
        float fil = exp(-kf.x * KIFS_TRAP_SHARP);
        fil *= 0.55 + 0.45 * tex;
        // 色相：递归层号分层（核心）+ 八度径向相位 + 细纹 + 慢漂
        float hue = KIFS_LEV_HUE * kf.y + 0.10 * fN + 0.10 * tex + hueDrift
            + (second ? 0.15 : 0.0);
        vec3 pc = second ? pal2(hue) : pal(hue);
        vec3 pcB = second ? pal2(hue + 0.45) : pal(hue + 0.45);

        vec3 colK = pc * fil * KIFS_FIL_GAIN;
        colK += pcB * kf.z * KIFS_DENS_FILL;
        col += colK * wK;
    }

    col += (second ? pal2(hueDrift + 0.5) : pal(hueDrift + 0.5)) * FLOOR_GLOW;
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
