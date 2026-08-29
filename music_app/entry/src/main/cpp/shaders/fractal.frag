// fractal.frag：多形态分形引擎（五套结构互异场 × 出场轮换调度）。
//
// 设计目标——"风格多变，不只是旋转和放大"（MilkDrop 的观感来自每个 preset
// 结构完全不同）：
//   五套场各自有独立的**几何语言**与**运动性格**：
//     0 DIVE    对数极坐标八度深潜（KIFS 折叠 × Julia 逃逸丝）——唯一的
//               "缩放"场景，无穷隧道；
//     1 KALI    Kali 集（z=|z|/|z|²−c）轨道陷阱——居中的有机花网，形态
//               随 c 慢漂演化，只缓转不缩放；
//     2 WARP    双层域扭曲 fbm 流云——iq 式 warp 链，纯"流动"没有缩放
//               和旋转，等值丝随相位滚动；
//     3 GYROID  3D gyroid 曲面的 2D 切片——切片相位沿第三维推进，褶皱
//               膜连续变形（脑珊瑚/生物晶格感）；
//     4 VORONOI 移动 cell 的 F2−F1 边网络——霓虹电路，脉冲沿边行波。
//
// 轮换机制（v3 返工）：出场序号调度——preset 周期 72s（4×18s），本场景
// 每次出场 18s、序号 +1，hash 选形态且与上一出场不同 → 每次切回来必然
// 换形态（旧 wander 轮换的尺度是分钟级，72s 后回来时大概率还是同一形态，
// 这是"看起来总一个样"的病根）。形态跳变发生在本场景不在场的时刻，被
// preset 切换的 crossfade 掩盖；锁定观看时进入侧 1s 淡入保险。各形态
// 内部参数（c / warp 相位 / 切片深度 / cell 相位）仍由 wander 慢漂——
// "同一形态"每次出场长相也不同。
//
// 旧版平滑性经验全部保留（血换来的，别回退）：
//   1. DIVE 的行程 D = ts × 恒定速度严格单调；beat 永不进速度；
//   2. 一切变化发生在连续坐标上的慢漂移；参数按整数序号跳变 = 画面突变；
//   3. KIFS 自相似比 s 别超 ~2.3（吸引子稀疏近黑）；
//   4. 音频量（beat/bass/treble）只进亮度/幅度/闪烁，绝不进速度与色相。
//
// 公共函数（hash/vn/fbm/wander/rot/palIQ/toneExp/applyTransition/…）由
// 工具链从 common.glsl 注入，不要在本文件重复定义。

// ---- 深潜几何（DIVE）-----------------------------------------------------
const float LNS = 0.6931472;        // log(2)
const float OCT_PERIOD = 6.0;
const float OCT_PERIOD_2 = 9.7082039; // 6φ，与第一层不可通约
const float DIVE_SPEED = 0.58;      // 八度/秒（恒定！）
const float LAYER_BLEND_RATE = 0.009;
const float SEED_DIVE_OFFSET = 0.37;
const float SYM_A = 6.0;
const float SYM_B = 8.0;
const float SYM_MORPH_RATE = 0.007;
const float ANGLE_DRIFT_AMP = 0.06;
const float ANGLE_DRIFT_RATE = 0.017;
const float FORM_RATE = 0.021;
const float FORM_RATE_2 = 0.034;

// ---- Julia / KIFS（DIVE 内部）--------------------------------------------
const int JULIA_ITER = 12;
const float ESCAPE_R2 = 24.0;
const float RING_R_X = 1.16;
const float RING_R_Y = 1.00;
const float RING_TANGENT = 1.15;
const vec2 JULIA_C = vec2(-0.7269, 0.1889);
const float C_DRIFT_AMP = 0.10;
const float C_BASS_AMP = 0.03;
const int KIFS_ITER = 9;
const float KIFS_S_BASE = 1.90;
const float KIFS_S_DRIFT = 0.16;
const float KIFS_S_BASS = 0.04;
const vec2 KIFS_OFF_BASE = vec2(0.90, 0.65);
const float KIFS_OFF_DRIFT = 0.30;
const float KIFS_ROT_AMP = 0.45;
const float KIFS_TRAP_SHARP = 5.0;
const float KIFS_DENS_K = 3.0;
const float KIFS_ESCAPE_R2 = 36.0;
const float KIFS_LEV_HUE = 0.55;

// ---- KALI -----------------------------------------------------------------
const int KALI_ITER = 10;
const float KALI_SCALE = 1.12;       // 起始域尺度（不缩放，只慢转）
const float KALI_ROT_RATE = 0.020;   // 整体缓转（弧度/秒）
const float KALI_TRAP_SHARP = 6.0;   // 轨道陷阱丝线锐度
const float KALI_ACC_DECAY = 0.86;   // 驻留累积的层间衰减

// ---- WARP -----------------------------------------------------------------
const float WARP_SCALE = 1.6;
const float WARP_T1 = 0.045;         // 一级 warp 相位速
const float WARP_T2 = 0.031;         // 二级 warp 相位速（不可通约）
const float WARP_AMP1 = 3.2;
const float WARP_AMP2 = 3.0;
const float WARP_BAND_FREQ = 2.5;    // 等值丝密度
const float WARP_SCROLL = 0.015;     // 等值丝滚动

// ---- GYROID ---------------------------------------------------------------
const float GY_PHASE_RATE = 0.12;    // 切片沿第三维推进（形态演化主驱动）
const float GY_SCALE = 4.2;
const float GY_ROT_RATE = 0.015;
const float GY_MEMBRANE_K = 10.0;    // 膜面（|G|→0）锐度
const float GY_MEMBRANE2_K = 16.0;   // 二尺度细膜

// ---- VORONOI --------------------------------------------------------------
const float VOR_SCALE = 5.0;
const float VOR_ORBIT = 0.38;        // cell 点位轨道幅度（慢速圆轨道）
const float VOR_EDGE_K = 160.0;      // 边线锐度
const float VOR_PULSE_RATE = 1.6;    // 沿边脉冲行波速度

// ---- 形态轮换 --------------------------------------------------------------
// 出场序号调度（与 kaleido.frag 同机制）：preset 周期 72s（4×18s），
// 本场景每次出场 18s、序号 +1 → hash 选形态且与上一出场不同——
// 每次切回来必然换形态。wander 尺度分钟级的旧机制下，72s 后回到本场景
// 时大概率还是同一形态，这是"风格不多变"的病根。形态跳变发生在本场景
// 不在场的时刻，被 preset 切换的 crossfade 掩盖；锁定观看时进入侧 1s
// 淡入保险。mod 97 保护 hash 精度（97 质数 → 序列看似不循环）。
const float SHOW_PERIOD = 72.0;
const float SHOW_KEY_MOD = 97.0;
const float BLEND_IN = 0.015;

// ---- 着色 / 收尾 -----------------------------------------------------------
const float BAND_FREQ = 0.85;
const float BAND_SCROLL = 0.04;
const float FILAMENT_POW = 7.0;
const float TRAP_GLOW_FALLOFF = 1.4;
const vec3 PAL_C = vec3(1.0, 0.95, 0.9);
const vec3 PAL_D = vec3(0.0, 0.15, 0.35);
const vec3 PAL_D_2 = vec3(0.45, 0.10, 0.72);
const float MAIN_GAIN = 1.40;
const float KIFS_FIL_GAIN = 1.30;
const float DEEP_FILL = 0.020;
const float TRAP_FILL = 0.020;
const float KIFS_DENS_FILL = 0.13;
const float FLOOR_GLOW = 0.016;
const float CENTER_FADE = 0.045;
const float CORE_GLOW = 700.0;
const float VIGNETTE = 0.22;
const float TRAIL_ZOOM = 0.9867;     // = 2^(−0.58/30)，对齐 DIVE 恒定流速
const float TRAIL_ZOOM_SOFT = 0.996; // 非深潜形态的轻运动模糊（近恒等）
const float TRAIL_GAIN = 0.30;
const float SHADOW_LIFT = 0.76;
const float SEED_SPREAD = 211.0;

vec3 pal(float t) {
    return palIQ(t, PAL_C, PAL_D);
}

vec3 pal2(float t) {
    return palIQ(t, PAL_C, PAL_D_2);
}

// 周期性值噪声（八度方向严格周期）
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

// Julia 逃逸时间场：(平滑逃逸计数, 轨道陷阱最小距离²)
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
    float sm = float(JULIA_ITER);
    if (esc >= 0.0) {
        float r2 = max(dot(zc, zc), 1e-4);
        sm = clamp(esc + 1.0 - log(max(log(r2) * 0.5, 1e-4)) / LNS, 0.0, float(JULIA_ITER));
    }
    return vec2(sm, trap);
}

// KIFS 递归折叠场：(trap, 达到最近距离的层号, 驻留密度)
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
        z = kR * abs(z) * s - koff;
        float d2 = dot(z, z);
        dens += exp(-d2 * KIFS_DENS_K);
        if (d2 < trap) {
            trap = d2;
            lev = float(i);
        }
        if (d2 > KIFS_ESCAPE_R2) {
            break;
        }
    }
    return vec3(trap, lev / float(KIFS_ITER - 1), clamp(dens * 0.25, 0.0, 1.0));
}

// DIVE 的一层八度结构（原样保留，已验证稳定）
vec3 octaveLayer(float lr, float angN, float period, float sym,
    float layerPh, float ts, float sd, vec2 cc, bool second) {
    float fN = fract(lr / period);
    float a = abs(fract(angN * sym) - 0.5) * 2.0;

    float th = TAU * fN + layerPh;
    vec2 ring = vec2(RING_R_X * cos(th), RING_R_Y * sin(th));
    vec2 tang = vec2(-sin(th), cos(th));
    vec2 p0 = ring + (a - 0.5) * RING_TANGENT * tang;

    float tex = pnoise(vec2(a * 12.0, fN * 16.0), vec2(16.0)) * 0.5
        + pnoise(vec2(a * 24.0, fN * 32.0), vec2(32.0)) * 0.25;

    float hueDrift = 0.03 * sin(ts * 0.02 + sd) + uTreble * 0.05;

    float wK = smoothstep(0.12, 0.88,
        0.5 + 0.5 * sin(ts * (second ? FORM_RATE_2 : FORM_RATE)
            + sd * (second ? 1.9 : 0.7) + layerPh));

    vec3 col = vec3(0.0);

    if (wK < 0.995) {
        vec2 field = juliaField(p0, cc);
        float sm = field.x;
        float trap = field.y;
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
        vec3 kf = kifsField(p0, ts, sd);
        float fil = exp(-kf.x * KIFS_TRAP_SHARP);
        fil *= 0.55 + 0.45 * tex;
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

// ---- 形态 0：深潜隧道（原主场景）-------------------------------------------
vec3 modeDive(vec2 q, float ts, float sd) {
    float D = ts * DIVE_SPEED + sd * SEED_DIVE_OFFSET;
    float rho = max(length(q), 1e-4);
    float ang = atan(q.y, q.x);
    float lr = -log(rho) / LNS + D;
    float angN = ang / TAU + 0.5 + ANGLE_DRIFT_AMP * sin(ts * ANGLE_DRIFT_RATE + sd);
    vec2 cc = JULIA_C
        + C_DRIFT_AMP * vec2(sin(ts * 0.013 + sd), cos(ts * 0.011 + sd * 1.7))
        + C_BASS_AMP * uBass * vec2(sin(ts * 0.004 + sd), cos(ts * 0.004 + sd));

    float symK = 0.5 + 0.5 * sin(ts * SYM_MORPH_RATE + sd * 0.9);
    float sym = mix(SYM_A, SYM_B, symK);
    float layerK = 0.5 + 0.5 * sin(ts * LAYER_BLEND_RATE + sd * 1.1);
    vec3 colA = octaveLayer(lr, angN, OCT_PERIOD, sym, 0.0, ts, sd, cc, false);
    vec3 colB = octaveLayer(lr + OCT_PERIOD_2 * 0.618, angN, OCT_PERIOD_2, sym,
        2.1, ts, sd, cc, true);
    vec3 col = mix(colA, colB, layerK);
    // 中心消失点辉光（"往里钻"）
    float hueCore = 0.03 * sin(ts * 0.02 + sd) + uTreble * 0.05;
    col += pal(hueCore + 0.10) * exp(-rho * rho * CORE_GLOW) * (0.45 + 0.55 * uBeat);
    col *= smoothstep(0.0, CENTER_FADE, rho);
    return col;
}

// ---- 形态 1：Kali 有机花网 --------------------------------------------------
vec3 modeKali(vec2 q, float ts, float sd) {
    float h1 = hash11(sd * 0.37 + 5.0);
    float h2 = hash11(sd * 0.61 + 11.0);
    // c 在"已知好看"的区间内慢漂（|c|≈1 的花网区），形态连续演化
    vec2 c = vec2(-1.02 + 0.22 * h1 + 0.16 * sin(ts * 0.013 + sd),
        0.22 * (h2 - 0.5) + 0.18 * cos(ts * 0.011 + sd * 1.3));
    vec2 z = rot(ts * KALI_ROT_RATE + sd) * q * KALI_SCALE;
    float trap = 1e9;
    float acc = 0.0;
    float w = 1.0;
    for (int i = 0; i < KALI_ITER; i++) {
        z = abs(z) / max(dot(z, z), 1e-4) - c;
        float d2 = dot(z, z);
        acc += exp(-min(d2, 8.0) * 1.8) * w;   // 驻留密度（有机体块）
        trap = min(trap, d2);                  // 陷阱（花网丝线）
        w *= KALI_ACC_DECAY;
    }
    float fil = exp(-min(trap, 8.0) * KALI_TRAP_SHARP);
    float accN = clamp(acc * 0.30, 0.0, 1.0);
    float hue = 0.50 * accN + 0.18 * fil
        + 0.06 * sin(ts * 0.01 + sd) + hash11(sd + 17.0) * 0.3;
    vec3 col = pal(hue) * fil * 1.25;
    col += pal(hue + 0.42) * accN * 0.30;
    col += pal(hue + 0.2) * 0.018; // 基底微光兜底
    return col;
}

// ---- 形态 2：域扭曲流云（iq warp 链）----------------------------------------
vec3 modeWarp(vec2 q, float ts, float sd) {
    float sc = WARP_SCALE + 0.5 * sin(ts * 0.006 + sd);
    vec2 q1 = q * sc;
    float t1 = ts * WARP_T1;
    float t2 = ts * WARP_T2;
    vec2 w1 = vec2(fbm(q1 + vec2(0.0, t1)), fbm(q1 + vec2(5.2, t1 * 1.1)));
    vec2 w2 = vec2(fbm(q1 + WARP_AMP1 * w1 + vec2(1.7, 9.2) + t2),
        fbm(q1 + WARP_AMP1 * w1 + vec2(8.3, 2.8) - t2));
    float f = fbm(q1 + WARP_AMP2 * w2);
    // 密度云 + 等值丝（丝随相位滚动 = 流动感，无缩放无旋转）
    float band = abs(fract(f * WARP_BAND_FREQ - ts * WARP_SCROLL) - 0.5) * 2.0;
    float fil = pow(1.0 - band, 6.0);
    float hue = 0.45 * f + 0.15 * fil + 0.08 * sin(ts * 0.009 + sd)
        + hash11(sd + 29.0) * 0.3;
    vec3 col = pal(hue) * (0.22 + 1.0 * f * f);
    col += pal(hue + 0.38) * fil * 0.55;
    col += pal(hue + 0.2) * 0.016;
    return col * 1.05;
}

// ---- 形态 3：Gyroid 生物膜切片 ---------------------------------------------
vec3 modeGyroid(vec2 q, float ts, float sd) {
    float ph = ts * GY_PHASE_RATE + sd;   // 切片沿第三维推进：形态演化主轴
    float sc = GY_SCALE + 1.4 * sin(ts * 0.007 + sd);
    vec2 pr = rot(ts * GY_ROT_RATE + sd) * q * sc;
    vec3 g3 = vec3(pr, ph);
    float g = sin(g3.x) * cos(g3.y) + sin(g3.y) * cos(g3.z)
        + sin(g3.z) * cos(g3.x);
    float g2 = sin(g3.x * 2.1 + 1.3) * cos(g3.y * 2.1)
        + sin(g3.y * 2.1) * cos(g3.z * 2.1)
        + sin(g3.z * 2.1) * cos(g3.x * 2.1);
    float m1 = exp(-g * g * GY_MEMBRANE_K);
    float m2 = exp(-g2 * g2 * GY_MEMBRANE2_K) * 0.55;
    // 两尺度膜的交叠处最亮（细膜骑在大膜上）
    float hue = 0.30 + 0.22 * sin(g * 1.4 + ts * 0.010 + sd)
        + 0.14 * g2 + hash11(sd + 43.0) * 0.3;
    vec3 col = pal(hue) * (m1 + m2) * 1.15;
    col += pal(hue + 0.47) * m1 * m2 * 0.9;
    col += pal(hue + 0.2) * 0.016;
    return col;
}

// ---- 形态 4：Voronoi 霓虹边网络 ---------------------------------------------
vec3 modeVoronoi(vec2 q, float ts, float sd) {
    vec2 pp = q * (VOR_SCALE + 1.5 * sin(ts * 0.006 + sd));
    vec2 ic = floor(pp);
    vec2 fc = fract(pp);
    float d1 = 8.0;
    float d2 = 8.0;
    vec2 r1 = vec2(0.0);
    for (int j = -1; j <= 1; j++) {
        for (int k = -1; k <= 1; k++) {
            vec2 o = vec2(float(j), float(k));
            vec2 h = vec2(hash21(ic + o + sd * 0.13),
                hash21(ic + o + sd * 0.31 + 7.7));
            // cell 点位做慢速小圆轨道（结构活但不是整体旋转）
            vec2 cpos = o + 0.5 + VOR_ORBIT
                * sin(ts * (0.05 + 0.12 * h.x) + h * TAU);
            vec2 dv = cpos - fc;
            float d = dot(dv, dv);
            if (d < d1) {
                d2 = d1;
                d1 = d;
                r1 = dv;
            } else if (d < d2) {
                d2 = d;
            }
        }
    }
    float edge = sqrt(d2) - sqrt(d1);
    float line = exp(-edge * edge * VOR_EDGE_K);
    float cellH = hash21(ic + sd * 0.7);
    // 沿边行波脉冲（treble 调制亮度）
    float az = atan(r1.y, r1.x);
    float pulse = 0.55 + 0.45 * sin(az * 3.0 - ts * VOR_PULSE_RATE
        + cellH * TAU) * (0.7 + 0.6 * uTreble);
    float hue = 0.30 * cellH + 0.12 * sin(ts * 0.008 + sd)
        + hash11(sd + 53.0) * 0.3;
    vec3 col = pal(hue) * line * pulse * 1.5;
    col += pal(hue + 0.5) * exp(-d1 * 3.5) * 0.12;
    col += pal(hue + 0.2) * 0.014;
    return col;
}

// 形态分发（出场序号决定，一次只算一套场）
vec3 evalMode(int idx, vec2 q, float ts, float sd) {
    if (idx == 0) return modeDive(q, ts, sd);
    if (idx == 1) return modeKali(q, ts, sd);
    if (idx == 2) return modeWarp(q, ts, sd);
    if (idx == 3) return modeGyroid(q, ts, sd);
    return modeVoronoi(q, ts, sd);
}

// 出场序号 → 形态（与上一出场不同）
float modeForShow(float showIdx, float sd) {
    float key = mod(showIdx, SHOW_KEY_MOD);
    float sel = floor(hash11(key * 0.913 + sd) * 5.0);
    float prev = floor(hash11(mod(showIdx - 1.0, SHOW_KEY_MOD) * 0.913 + sd) * 5.0);
    if (sel == prev) {
        sel = mod(sel + 1.0 + floor(hash11(key * 3.31 + sd * 1.7) * 4.0), 5.0);
    }
    return sel;
}

void main() {
    float ts = nowSec();
    float sd = seedHash() * SEED_SPREAD;
    vec2 q = sceneUV(vec2(0.5));

    // ---- 出场轮换：本场景每次出场（72s 序号 +1）必然换形态 ----
    float cyc = ts / SHOW_PERIOD;
    float showIdx = floor(cyc);
    float bph = fract(cyc);
    int modeIdx = int(modeForShow(showIdx, sd));
    vec3 col = evalMode(modeIdx, q, ts, sd);
    // 进入侧 1s 淡入保险（锁定本场景连续观看时也不跳闪）
    float blendIn = smoothstep(0.0, BLEND_IN, bph);
    if (blendIn < 0.999) {
        int prevIdx = int(modeForShow(showIdx - 1.0, sd));
        col = mix(evalMode(prevIdx, q, ts, sd), col, blendIn);
    }

    // beat 只进亮度（速度恒定铁律）
    col *= 0.95 + 0.18 * uBeat;
    col *= 1.0 - VIGNETTE * dot(q, q);

    // 反馈拖尾：深潜形态用对齐流速的缩放率，其余用近恒等轻模糊
    vec3 prevS = texture2D(uPrev, (vUV - 0.5) * TRAIL_ZOOM_SOFT + 0.5).rgb;
    if (modeIdx == 0) {
        vec3 prevD = texture2D(uPrev, (vUV - 0.5) * TRAIL_ZOOM + 0.5).rgb;
        col += mix(prevS, prevD, blendIn) * TRAIL_GAIN;
    } else {
        col += prevS * TRAIL_GAIN;
    }

    col = toneExp(col, 1.0);
    // 抬暗部压缩"周期性忽明忽暗"的观感幅度
    col = pow(col, vec3(SHADOW_LIFT));

    col = applyTransition(col);

    gl_FragColor = vec4(col, 1.0);
}
