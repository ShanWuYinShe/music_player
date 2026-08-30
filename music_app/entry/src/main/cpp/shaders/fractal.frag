// fractal.frag：碎片（fragment）混沌引擎 v8——"持续繁衍、变化多样的碎片云"
//
// v8 多样性增强（用户："变化太少太慢，加点函数让变化更多样"）：
//   · 分裂/合并：每片带 2 个分裂子体（splitK 0→1 周期裂成 3 片再合并，
//     细胞分裂感）
//   · 次轨道：更快不可通约的第二轨道（轨迹从圆变成摆动花环）
//   · 偶发突跳：高频 wander 峰触发快速移动（不是瞬移，是突然加速）
//   · 全局形变波：空间行进波调制碎片大小（波扫过时碎片此起彼伏）
//   · 形状极端化：边数 2~11、星形度 0~1.3（超星）
//   · 色相快漂 + 偶发跳色、亮度快闪（双频）
//   · 全部速率 ×~1.6（聚散 0.08 / 轨道 0.085 / 呼吸 / 自旋 0.24）
//
// v7 彻底重构（用户："不再采用固定分形结构，改为碎片形态持续不断演变的动态
//   可视化；每一帧基于上一帧状态迭代变形，像混沌系统繁衍；碎片独立漂移/
//   旋转/缩放/聚散"）：
//   分形（固定数学结构的逃逸集/域扭曲）全部删除——DIVE/KALI/WARP/GYROID/
//   VORONOI 五形态、22s 轮换调度、modeForShow/evalMode 一并移除。
//
// 【核心算法：无状态 shader 里的"持续繁衍"】
//   每个碎片的全部参数（位置/尺寸/旋转/边数/星形度/色相/亮度）都是时间 t
//   的**连续混沌函数**（wander/sin 的不可通约频率组合）：
//     · 帧间必然连续 = 上一帧状态自然延续（视觉上的"基于上一帧迭代"）
//     · 长期无周期 = 混沌系统繁衍（永不复现）
//     · 叠加 feedback 残影（每帧用 uPrev 上一帧数据加权合成）= 真正的
//       逐帧继承，碎片运动拖出丝状残影，形态像活体一样生长变化
//
// 【精灵运动（每片独立参数化）】
//     pos    极坐标：r = 基半径 × gather（全场聚散 0.72~1.28）+ 绕心漂移
//            （每片角速度不同、方向随机）+ wander 慢游走抖动
//     size   基尺寸 × 呼吸脉冲（每片频率不同）= 缩放
//     rot    自旋（速率每片不同，带抖动）
//     sides 边数 3~9 慢演化、spike 星形度 0.3~1（0=圆润多边形 1=尖星）
//     hue   色相慢漂（每片在色轮上独立游走）
//     lum   亮度脉冲（每片相位不同）
//
// 渲染：碎片用"多边形/星形 SDF 半径"形状，场 F = Σ size²/d_eff²（d_eff =
// 距碎片中心的形状归一化距离）——相邻碎片场值叠加融合（像细胞/泡沫），
// 碎片间的场谷值压暗成"细胞膜"暗线。
//
// 保留：feedback 反馈循环、beat 亮度（铁律：音频量只进亮度）、vignette、
// toneExp + SHADOW_LIFT、applyTransition、公共库注入。

// ---- 公共函数（hash/vn/fbm/wander/rot/palIQ/toneExp/applyTransition/…）由
// 工具链从 common.glsl 注入，不要在本文件重复定义。

// ---- 碎片引擎参数 ----------------------------------------------------------
const int FRAG_COUNT = 12;          // 碎片数（性能与密度平衡；逐像素×逐片）
const float FRAG_SIZE_BASE = 0.038; // 基尺寸（屏高单位）
const float FRAG_SIZE_RANGE = 0.062;// 尺寸分布跨度（大碎片 + 小碎片共存）
const float FRAG_GATHER_AMP = 0.28; // 聚散幅度：全场半径 ×(0.72~1.28)
const float FRAG_GATHER_RATE = 0.08;// 聚散周期（慢——聚集→散开→聚集）
const float FRAG_ORBIT_RATE = 0.085;// 绕心漂移基础角速度（rad/s）
const float FRAG_ORBIT_K = 0.18;    // 每片角速度差异（0.05±0.12 → 有正有负）
const float FRAG_WOBBLE = 0.09;     // 慢游走抖动幅度（wander，混沌无周期）
const float FRAG_BREATH = 0.38;     // 呼吸幅度（缩放 ±32%）
const float FRAG_ROT_RATE = 0.24;   // 自旋基础速率（rad/s）
const float FRAG_ROT_K = 0.45;      // 每片自旋差异
const float FRAG_LUM_MIN = 0.30;    // 亮度下限（暗色碎片也存在，层次感）
const float FRAG_EDGE_K = 0.30;     // 碎片间"细胞膜"暗线强度
const float FRAG_BEAT_K = 0.20;     // 节拍对碎片亮度的调制（铁律：只进亮度）

// ---- 收尾常量（沿用旧引擎，值不变）---------------------------------------
const float SEED_SPREAD = 211.0;
const float VIGNETTE = 0.22;
const float TRAIL_ZOOM_SOFT = 0.996; // 反馈采样的轻运动模糊（近恒等）
const float TRAIL_GAIN = 0.30;       // 反馈权重（残影余晖）
const float SHADOW_LIFT = 0.76;      // 暗部提升（压缩忽明忽暗的观感）

// 碎片形状半径：n 边形（顶点=1、边=cos(π/n)）与星形（尖角）的混合。
// dir 是碎片局部坐标系的方向（已减自旋角），sides 边数、spike 星形度。
float fragShape(vec2 dir, float sides, float spike) {
    float a = atan(dir.y, dir.x);
    float an = TAU / sides;
    float ang = abs(mod(a, an) - 0.5 * an);   // 到最近边中心的角距离 [0, 0.5an]
    float rPoly = cos(ang) / cos(0.5 * an);   // 多边形：顶点 1、边 cos(π/n)
    float rStar = 1.0 / cos(ang);             // 星形：边处向外尖
    return mix(rPoly, rStar, spike);
}

// 碎片场：F = Σ size²/d_eff²，d_eff = 距碎片中心的形状归一化距离。
// 输出 hueLum = 场加权的 (色相, 亮度)，g = 场梯度（供法线）。
float fragField(vec2 p, float ts, float sd, out vec3 hueLum, out vec2 g) {
    float F = 0.0;
    vec3 hl = vec3(0.0);
    vec2 gg = vec2(0.0);
    for (int i = 0; i < FRAG_COUNT; i++) {
        float fi = float(i);
        float h1 = hash11(fi * 7.13 + sd);
        float h2 = hash11(fi * 3.71 + sd + 11.0);
        float h3 = hash11(fi * 5.39 + sd + 23.0);
        float h4 = hash11(fi * 9.17 + sd + 37.0);

        // ---- 精灵运动：位置（漂移 + 聚散 + 次轨道 + 偶发跳变）----
        float rBase = 0.35 + 0.45 * h1;                  // 每片轨道半径
        float gather = 1.0 - FRAG_GATHER_AMP
            + FRAG_GATHER_AMP * (0.5 + 0.5 * sin(ts * FRAG_GATHER_RATE + sd));
        float r = rBase * gather;
        // 主轨道（每片角速度/方向不同）+ wander 慢游走（混沌无周期）
        float orb = ts * (FRAG_ORBIT_RATE + FRAG_ORBIT_K * h2)
            * (h4 < 0.5 ? 1.0 : -1.0);
        float wob = FRAG_WOBBLE * wanderBi(ts * 0.05 + fi * 3.1, 1.0,
            sd + h3 * 7.0);
        float th = orb + fi * 2.4 + wob * TAU;
        vec2 pos = vec2(cos(th), sin(th)) * r;
        // 次轨道（更快、不可通约 → 轨迹不是圆，是摆动花环）
        float orb2 = ts * (0.31 + 0.19 * h1) * (h3 < 0.5 ? 1.0 : -1.0);
        pos += vec2(cos(orb2 + fi * 1.7), sin(orb2 * 1.3 + fi * 4.9))
            * (0.10 + 0.08 * h2);
        // 偶发突跳（高频 wander 的峰触发快速移动，不是瞬移）
        float hop = wanderBi(ts * 0.8 + fi * 9.0, 0.35, sd + fi * 3.3);
        pos += vec2(cos(hop * TAU), sin(hop * 1.7 * TAU))
            * 0.14 * smoothstep(0.90, 1.0, abs(hop));

        // ---- 精灵运动：缩放（呼吸 + 全局形变波）----
        float size = FRAG_SIZE_BASE + FRAG_SIZE_RANGE * h3;
        size *= 1.0 + FRAG_BREATH * sin(ts * (0.9 + 1.1 * h2) + fi * 5.3)
            * (0.5 + 0.5 * sin(ts * 0.21 + fi * 2.9 + sd));
        // 全局行进波：碎片大小随画面位置波动（波扫过时碎片此起彼伏）
        size *= 0.75 + 0.5 * (0.5 + 0.5 * sin(p.x * 4.0 - ts * 1.5 + p.y * 2.5));
        size = max(size, 0.015);

        // ---- 形状演变：边数 + 星形度（更快、更极端）----
        float sides = 2.0 + floor(10.0 * h3);            // 2~11 边形
        float spike = 1.3 * (0.5 + 0.5 * sin(ts * 0.15 + fi * 3.7 + sd));  // 0~1.3

        // ---- 精灵运动：旋转（自旋 + 抖动）----
        float rot = ts * (FRAG_ROT_RATE + FRAG_ROT_K * h1) + fi * 4.3
            + 0.5 * sin(ts * 0.09 + fi * 2.2 + sd);

        // ---- 场贡献：主碎片 + 分裂子体（细胞分裂感）----
        // splitK 0→1：合并 → 裂成 3 片（主 + 2 偏移小块）→ 合并
        float splitK = 0.5 + 0.5 * sin(ts * 0.11 + fi * 3.3 + sd);
        // 颜色加权：色相快漂 + 偶发跳变 + 亮度快闪（先算，供子体循环用）
        float hue = 0.06 * sin(ts * 0.05 + fi * 2.1 + sd)
            + 0.03 * sin(ts * 0.17 + fi * 5.3) + 0.83 * h1 + 0.17 * h2;
        hue += step(0.94, fract(ts * 0.023 + fi * 0.71)) * 0.4;   // 偶发跳色
        float lum = FRAG_LUM_MIN + (1.0 - FRAG_LUM_MIN)
            * (0.5 + 0.5 * sin(ts * (0.35 + 0.30 * h4) + fi * 6.1));
        lum *= 0.7 + 0.6 * (0.5 + 0.5 * sin(ts * 2.1 + fi * 7.7)); // 快速闪动
        vec2 subOff = vec2(cos(rot + 1.1), sin(rot + 1.1))
            * size * (0.9 + 0.6 * splitK);
        vec2 d = p - pos;
        float ang = atan(d.y, d.x) - rot;
        float srad = fragShape(vec2(cos(ang), sin(ang)), sides, spike);
        float dEff = length(d) / max(srad, 0.05);
        float w = size * size / (dEff * dEff + 1e-4);
        F += w;
        // 两个分裂子体（尺寸 ×0.5×splitK，splitK→0 时消失）
        for (int k = 0; k < 2; k++) {
            vec2 subPos = pos + (k == 0 ? subOff : -subOff);
            vec2 sd2 = p - subPos;
            float sEff = length(sd2) / max(srad * 0.9, 0.05);
            float w2 = (size * size * 0.25 * splitK * splitK)
                / (sEff * sEff + 1e-4);
            F += w2;
            hl += vec3(fract(hue), lum, 0.0) * w2;
            gg += -2.0 * w2 * sd2 / max(dot(sd2, sd2), 1e-4);
        }
        hl += vec3(fract(hue), lum, 0.0) * w;

        // 梯度（元球式近似，供法线）
        gg += -2.0 * w * d / max(dot(d, d), 1e-4);
    }
    hueLum = hl / max(F, 1e-4);
    g = gg;
    return F;
}

void main() {
    float ts = nowSec();
    float sd = seedHash() * SEED_SPREAD;
    vec2 q = sceneUV(vec2(0.5));

    // ---- 碎片场 ----
    vec3 hueLum;
    vec2 g;
    float F = fragField(q, ts, sd, hueLum, g);
    float m = smoothstep(0.80, 1.20, F);            // 碎片实体（等值面）
    float glen = length(g);
    vec3 n = normalize(vec3(-g / max(glen, 1e-4) * min(glen, 1.0), 1.0));

    // ---- 着色：色相 → 颜色，光照 + 边缘辉光 + 核心白化 ----
    vec3 base = hue2rgb(hueLum.x) * (0.35 + 0.65 * hueLum.y);
    // 顶部光照（n.z）+ 等值面带 + 核心（F 峰值处白化）
    float body = smoothstep(1.0, 0.0, abs(F - 1.0) * 2.5) * m;
    float core = smoothstep(0.5, 0.0, F - 1.5) * m;
    // 光照项乘 m：碎片本体亮（m=1），碎片之间只有 12% 暗底色——否则
    // base 在 m=0 处也全量生效，整个画面被涂成亮底
    vec3 col = base * (0.45 + 0.55 * n.z) * (0.12 + 0.88 * m)
        + base * body * 0.7
        + vec3(1.0, 0.96, 0.88) * core * 0.9;
    // 碎片之间的场谷值压暗 = "细胞膜"暗线（碎片既融合又独立）
    col *= 1.0 - FRAG_EDGE_K * smoothstep(0.35, 0.15, F) * (1.0 - m);

    // beat 只进亮度（速度恒定铁律）
    col *= 0.95 + 0.18 * uBeat;
    col *= 1.0 - VIGNETTE * dot(q, q);

    // ---- 反馈循环：每帧用上一帧 fragment 数据生成新帧（用户核心诉求）----
    // 碎片运动拖出丝状残影，形态像活体一样从上一帧"长"出来
    vec3 prevS = texture2D(uPrev, (vUV - 0.5) * TRAIL_ZOOM_SOFT + 0.5).rgb;
    vec3 prev = prevS;
    col = col * (1.0 - TRAIL_GAIN) + prev * TRAIL_GAIN;

    col = toneExp(col, 1.0);
    // 抬暗部压缩"周期性忽明忽暗"的观感幅度
    col = pow(col, vec3(SHADOW_LIFT));

    col = applyTransition(col);

    gl_FragColor = vec4(col, 1.0);
}
