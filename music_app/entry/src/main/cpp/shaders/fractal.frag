// fractal.frag：MilkDrop 式混沌引擎 v10——"主体往屏幕里钻 + 附加效果"
//
// v10 纵深位移（用户："希望有位移，让主体看着像在往屏幕里钻，但大小保持
//   不变"）——三件套只动内部结构，外轮廓（BODY_SCALE/R clamp）完全不动：
//   · 纵深环带：主体内部同心环向中心收缩（波峰 rr 随 ts 递减），像隧道
//     内壁后退；频率随半径递减（中心密外疏）= 透视；sin 周期 → 无限循环
//   · 内部 flow 径向收缩呼吸：采样坐标 ±10% 循环缩放（内部纹理一进一出）
//   · 形状角向螺纹：形状相位沿角度走行波（钻头感）+ 旋转 0.10→0.20
//
// v9 彻底重做（用户："v8 刚开始一段黑屏+少量色点，效果更差了；原来主要是
//   没有主体。千千静听 milkdrop 是有一个主体一直在各种变化，再叠加其他
//   附加效果，观赏性很高"）。
//   v7/v8 的碎片场（12 片小碎片散落中环轨道，冷启动 gather/次轨道把它们
//   推远 → 黑屏 + 色点，且没有视觉中心）整体移除。
//
// 【主体：超公式 supershape（永远居中、永远在场、持续变形）】
//   r(φ) = (|cos(mφ/4)|^n2 + |sin(mφ/4)|^n3)^(-1/n1)   —— Gielis 超公式
//   · 对称数 m 在 3~9.5 之间持续游走（双不可通约频率）：主体从三角形→五角
//     星→四叶草→螺旋星不断演变，但**始终是一大块**（BODY_SCALE=0.32 屏高）
//   · 形态指数 n1 在 0.30~0.85 之间漂移（Gielis 参数扫描：n1∈[0.3,0.85] 才是
//     星形区间，R 起伏 1.4~1.6×；n1>0.9 顶格成圆、m 演变不可见）
//   · 整体缓慢旋转 + 边缘 fbm 扰动 = 熔岩般涌动的边界
//   · 内部 fbm 流动颜色（色轮慢漂 + 角度色带 + 内部流动）= 彩色液体
//   · 任何时刻 ts（含 0）下 m/n 都落在有效区间 → 永不黑屏
//
// 【附加效果（MilkDrop 式叠加，衬托主体）】
//   · 环绕碎片：8 片小型多边形/星形碎片绕主体外环漂移、呼吸、自旋（点缀）
//   · 辐射射线：沿主体光晕向外放射的细光线（角度高频条纹，只在主体外）
//   · 螺旋波纹：从主体向外扩散的涟漪（r·freq − t·speed + 角度项）
//   · 反馈拖尾：每帧 25% 上一帧数据加权合成（残影流动）
//   · beat 只进亮度（铁律）；vignette；toneExp + SHADOW_LIFT；applyTransition
//
// 调试教训：① 主体过大会把全场垫亮（R clamp 上限 1.7 + BODY_SCALE 0.42 →
//   主体占画面 80%，且 n1>0.9 时超公式顶格成圆失去形状）→ 收敛到
//   BODY_SCALE 0.32 / R≤1.45 / n1∈[0.3,0.85]；② 边缘发光不能 max(d-1,0)
//   （内部 exp(0)=1 被整体垫亮）→ 直接 exp(-(d-1)²·k)；③ 附加层（射线/
//   波纹/光晕/反馈）都会垫高中环，一律减半起步。
//
// 保留：公共库注入、反馈循环、节拍亮度铁律、收尾链。

// ---- 公共函数（hash/vn/fbm/wander/rot/palIQ/toneExp/applyTransition/…）由
// 工具链从 common.glsl 注入，不要在本文件重复定义。

// ---- 主体（超公式 supershape）参数 -----------------------------------------
const float BODY_SCALE = 0.32;      // 主体半尺寸（屏高单位）——中心大块、四周露暗背景
const float BODY_ROT_RATE = 0.20;   // 主体整体旋转（rad/s；v10 0.10→0.20，配合钻感）
const float BODY_M_BASE = 3.0;      // 对称数下限（3 瓣）
const float BODY_M_RANGE = 6.5;     // 对称数游走范围（3 ~ 9.5 演变）
const float BODY_N1_MIN = 0.30;     // 形态指数下限（Gielis 扫描：n1∈[0.3,0.85]
                                   //   才是星形区间，R 起伏 1.8~2.0×；n1>0.9 顶格
                                   //   成圆，m 演变不可见）
const float BODY_N1_MAX = 0.85;     // 形态指数上限（保持星形区间内漂移）
const float BODY_WAVE_K = 0.12;     // 边缘 fbm 扰动（熔岩涌动边界）
const float BODY_INNER_GLOW = 0.62; // 内部填充强度（收敛——主体是画面最亮处但
                                   //   不能把全场垫亮）
const float BODY_EDGE_GLOW = 1.05;  // 边缘发光（主体轮廓最亮）
const float BODY_HALO = 0.10;       // 外部光晕（贴主体的窄光晕——宽光晕会把
                                   //   整个画面垫亮，暗背景衬托才像 MilkDrop）
const float BODY_FLOW_K = 0.45;     // 内部流动强度（fbm 驱动亮度）
const float TUNNEL_FREQ = 10.0;     // 纵深环带径向频率（中心密、外疏——隧道透视）
const float TUNNEL_SPEED = 1.6;     // 环带向中心收缩速度（"往屏幕里钻"的速度）
const float TUNNEL_GAIN = 0.22;     // 环带明暗调制幅度（±22% 内部亮度）

// ---- 附加效果参数 ----------------------------------------------------------
const int SPARK_COUNT = 8;          // 环绕碎片数（点缀，非主体）
const float SPARK_SIZE = 0.042;     // 碎片基尺寸
const float SPARK_ORBIT = 0.13;     // 环绕角速度基础（rad/s）
const float SPARK_ORBIT_K = 0.10;   // 每片角速度差异
const float RAY_FREQ = 34.0;        // 辐射射线角度频率
const float RAY_DRIFT = 0.9;        // 射线转动速度（rad/s）
const float RAY_GAIN = 0.15;        // 射线强度（弱化——pow 22 已很锐，叠满
                                   //   会把中环垫亮）
const float RIPPLE_FREQ = 26.0;     // 螺旋波纹径向频率
const float RIPPLE_SPEED = 2.2;     // 波纹扩散速度
const float RIPPLE_GAIN = 0.04;     // 波纹强度

// ---- 收尾常量（沿用，值不变）-----------------------------------------------
const float SEED_SPREAD = 211.0;
const float VIGNETTE = 0.28;
const float TRAIL_ZOOM_SOFT = 0.996; // 反馈采样的轻运动模糊（近恒等）
const float TRAIL_GAIN = 0.25;       // 反馈权重（残影余晖；0.30 会让暗部被
                                   //   残影无限垫亮，收敛到 0.25）
const float SHADOW_LIFT = 0.80;      // 暗部提升（0.76 抬暗部太狠——暗背景
                                   //   0.05 被抬到 0.09，0.80 少抬一点）

// 超公式半径（Gielis）：m 对称数、n1 锐度、n2/n3 形状指数。
// pow(x, y) 在 x=0 是 GLSL 未定义行为（SwiftShader 返回 NaN 崩帧），
// 底数必须夹下限。
float supershapeR(float ang, float m, float n1, float n2, float n3) {
    float t1 = pow(max(abs(cos(m * ang / 4.0)), 1e-4), n2);
    float t2 = pow(max(abs(sin(m * ang / 4.0)), 1e-4), n3);
    return pow(t1 + t2, -1.0 / n1);
}

// 多边形/星形碎片半径（附加碎片的形状）：n 边形与星形混合，spike 星形度。
float fragShape(vec2 dir, float sides, float spike) {
    float a = atan(dir.y, dir.x);
    float an = TAU / sides;
    float ang = abs(mod(a, an) - 0.5 * an);
    float rPoly = cos(ang) / cos(0.5 * an);
    float rStar = 1.0 / cos(ang);
    return mix(rPoly, rStar, spike);
}

// 主体场：返回亮度贡献（内部填充 + 边缘发光 + 外部光晕），bcol 输出主体颜色。
// 任何 ts 下 m/n 都落在有效区间 → 主体永远在场，永不黑屏。
float mainBody(vec2 p, float ts, float sd, out vec3 bcol) {
    float ang = atan(p.y, p.x);
    float r = length(p) / BODY_SCALE;
    // 对称数与形态持续演变（双不可通约频率——一直在变形但永远是一大块）
    float m = BODY_M_BASE + BODY_M_RANGE * (0.5 + 0.5 * sin(ts * 0.073 + sd))
        * (0.72 + 0.28 * sin(ts * 0.019 + sd * 1.7));
    float n1 = BODY_N1_MIN + (BODY_N1_MAX - BODY_N1_MIN)
        * (0.5 + 0.5 * sin(ts * 0.061 + sd * 2.3 + 1.7));
    float n2 = 2.0 + 1.5 * (0.5 + 0.5 * sin(ts * 0.043 + sd * 3.1));
    float n3 = 2.0 + 1.5 * (0.5 + 0.5 * sin(ts * 0.037 + sd * 4.3 + 0.9));
    float rot = ts * BODY_ROT_RATE + 0.4 * sin(ts * 0.027 + sd);
    // 角向螺纹（v10 钻头感）：形状相位沿角度走行波——主体像螺纹钻头一样
    // 旋进；幅度 0.3 rad 不破坏形状，只给"往里拧"的动势
    float a = ang - rot + 0.30 * sin(ts * 0.45 + ang * 3.0 + sd);
    // 边缘 fbm 扰动（熔岩涌动）；fbm 输入用单位圆上的点，扰动随角度连续
    float wob = 1.0 + BODY_WAVE_K
        * (fbm(vec2(cos(a) * 2.3, sin(a) * 2.3) + vec2(ts * 0.05, sd * 0.3)) - 0.5) * 2.0;
    float R = clamp(supershapeR(a, m, n1, n2, n3) * wob, 0.20, 1.45);
    float d = r / max(R, 1e-4);
    // 主体：内部填充 + 边缘发光 + 外部光晕
    float inner = smoothstep(1.25, 0.80, d) * BODY_INNER_GLOW;
    // 边缘发光是 d≈1 处的高斯（内部 d<1 时 (d-1)² 大 → 快速衰减；
    // 不能 max(d-1,0)——那会让内部整块 exp(0)=1 被垫亮过曝）
    float edge = exp(-(d - 1.0) * (d - 1.0) * 26.0) * BODY_EDGE_GLOW;
    float halo = smoothstep(1.25, 1.03, d) * BODY_HALO;
    // 内部流动颜色（熔岩感：fbm 驱动亮度 + 色相）
    // v10 径向收缩呼吸：内部纹理采样坐标轻微缩放（0.9~1.1 循环）——内部
    // 结构像在纵深处一进一出，但主体外轮廓完全不动（大小保持不变）
    float zoomK = 1.0 + 0.10 * sin(ts * 0.35 + sd);
    float flow = fbm(p * 5.0 * zoomK + vec2(ts * 0.22, ts * 0.13) + sd * 0.5);
    float hue = 0.60 + 0.16 * sin(ts * 0.05 + sd)       // 全局色轮慢漂
        + 0.12 * sin(a * 2.0 + ts * 0.09)                // 角度色带（旋转彩虹）
        + 0.08 * flow;                                   // 内部流动
    // 纵深环带（v10 往屏幕里钻的核心）：主体内部同心环向中心收缩——波峰
    // 位置 rr=(π/2+2πn−ts·SPEED)/freq 随 ts 减小 = 环带向内收缩，像隧道内壁
    // 在后退；频率随半径递减（中心密、外疏）= 透视。sin 周期性 → 无限循环
    // 永不崩坏。环带只作用于主体内部（×inner），外轮廓不动。
    float rf = length(p);
    float tFreq = TUNNEL_FREQ * (1.6 - rf);
    float tPhase = 2.0 * fbm(p * 4.0 + vec2(ts * 0.2, sd));  // 环带有机起伏
    float tunnel = 0.5 + 0.5 * sin(rf * tFreq + ts * TUNNEL_SPEED + tPhase);
    float lum = 0.32 + 0.24 * (0.5 + 0.5 * sin(ts * 0.31 + sd * 1.1))
        + BODY_FLOW_K * flow * inner + 0.28 * inner;
    lum *= 1.0 + TUNNEL_GAIN * (tunnel - 0.5) * 2.0 * inner;  // ±22% 明暗环
    hue += 0.05 * tunnel * inner;                             // 环带带色（隧道渐变色）
    bcol = hue2rgb(fract(hue)) * lum;
    return inner + edge + halo;
}

// 环绕碎片（附加点缀）：8 片小碎片绕主体外环漂移/呼吸/自旋/变形
float sparkField(vec2 p, float ts, float sd, inout vec3 col) {
    float F = 0.0;
    vec3 hl = vec3(0.0);
    for (int i = 0; i < SPARK_COUNT; i++) {
        float fi = float(i);
        float h1 = hash11(fi * 7.13 + sd);
        float h2 = hash11(fi * 3.71 + sd + 11.0);
        float h3 = hash11(fi * 5.39 + sd + 23.0);
        float th = ts * (SPARK_ORBIT + SPARK_ORBIT_K * h1)
                * (h2 < 0.5 ? 1.0 : -1.0)
            + fi * 2.4
            + 0.08 * wanderBi(ts * 0.05 + fi, 1.0, sd + h3 * 5.0);
        float rr = 0.62 + 0.30 * h3 + 0.05 * sin(ts * 0.09 + fi * 3.0);
        vec2 pos = vec2(cos(th), sin(th)) * rr;
        vec2 d = p - pos;
        float size = SPARK_SIZE * (0.6 + 0.8 * h3);
        size *= 1.0 + 0.35 * sin(ts * (0.7 + 0.9 * h2) + fi * 5.1);  // 呼吸
        size = max(size, 0.015);
        float sides = 3.0 + floor(4.0 * h1);                          // 3~6 边形
        float spike = 0.3 + 0.7 * (0.5 + 0.5 * sin(ts * 0.11 + fi * 3.7 + sd));
        float rot = ts * (0.20 + 0.30 * h2) + fi * 4.3;               // 自旋
        float ang = atan(d.y, d.x) - rot;
        float srad = fragShape(vec2(cos(ang), sin(ang)), sides, spike);
        float dEff = length(d) / max(srad, 0.05);
        float w = size * size / (dEff * dEff + 1e-4);
        F += w;
        float hue = 0.66 + 0.10 * h1 + 0.08 * sin(ts * 0.06 + fi * 2.1);
        float lum = 0.45 + 0.55 * (0.5 + 0.5 * sin(ts * (0.4 + 0.3 * h2) + fi * 6.1));
        hl += vec3(fract(hue), lum, 0.0) * w;
    }
    float m = smoothstep(0.7, 1.1, F);
    vec3 c = hue2rgb(hl.x / max(F, 1e-4)) * (hl.y / max(F, 1e-4));
    col += c * m;
    return m;
}

void main() {
    float ts = nowSec();
    float sd = seedHash() * SEED_SPREAD;
    // uTilt 视差（设备倾斜）：场景整体反向轻移 = 相机随手机转动；
    // 只进几何不进色相（防闪烁纪律），幅度 ≤5% 屏高
    vec2 q = sceneUV(vec2(0.5) - uTilt * 0.05);

    // ---- 主体（永远在场）----
    vec3 bcol;
    float body = mainBody(q, ts, sd, bcol);
    vec3 col = bcol * body;

    // ---- 附加：环绕碎片（外环点缀）----
    sparkField(q, ts, sd, col);

    // ---- 附加：辐射射线（沿主体光晕向外放射）----
    float ang = atan(q.y, q.x);
    float rr = length(q);
    float rays = pow(vn(vec2(ang * RAY_FREQ + ts * RAY_DRIFT, sd * 3.0)), 22.0);
    // 射线只在主体边缘外（rr>0.55）出现、向外衰减——主体内部已有颜色，
    // 射线填满内部会糊
    col += bcol * rays * smoothstep(0.55, 0.42, rr)
        * smoothstep(1.25, 0.75, rr) * RAY_GAIN;

    // ---- 附加：向外扩散的螺旋波纹 ----
    float ripple = sin(rr * RIPPLE_FREQ - ts * RIPPLE_SPEED + ang * 2.0)
        * exp(-rr * 2.4) * RIPPLE_GAIN;
    col += bcol * ripple;

    // beat 只进亮度（速度恒定铁律）
    col *= 0.94 + 0.18 * uBeat;
    col *= 1.0 - VIGNETTE * dot(q, q);

    // ---- 反馈循环：每帧用上一帧 fragment 数据生成新帧（残影流动）----
    vec3 prev = texture2D(uPrev, (vUV - 0.5) * TRAIL_ZOOM_SOFT + 0.5).rgb;
    col = col * (1.0 - TRAIL_GAIN) + prev * TRAIL_GAIN;

    col = toneExp(col, 1.0);
    // 抬暗部压缩"周期性忽明忽暗"的观感幅度
    col = pow(col, vec3(SHADOW_LIFT));

    col = applyTransition(col);

    gl_FragColor = vec4(col, 1.0);
}
