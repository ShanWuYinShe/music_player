// aurora.frag：照片级极光（发射谱分层 × 磁天顶光线汇聚 × HDR 直绘）。
//
// v3 相对 v2 的"照片感"差距清单（v2 是结构对的"插画"，v3 按实拍照片逐项补）：
//   1. 发射谱而不是色轮：557.7nm 氧绿 (0.28,1.0,0.42) 是唯一主体色；
//      630nm 氧红是**更高海拔的独立发光层**（沿同一条磁力线向上抬升、
//      更宽更慢——不是对绿光插值)；N2+ 粉紫只在活跃下缘以亮线形态出现
//      （picket fence）。颜色稳、形态变——真实极光从不彩虹。
//   2. 磁天顶汇聚：所有光柱沿"汇聚到磁天顶的直线族"分布（摄影里放射状
//      收敛的铁轨透视，极光照片的身份证）。光柱坐标 az = atan(q-apex)，
//      同一条线上 az 恒定 → 条纹自动沿场线拉直、向天顶收拢。
//   3. 动态范围：下缘亮线与英雄光柱按 HDR 叠加（单帘峰值可到 3+），
//      经 ACES 滚降——亮而不溢，暗部仍有结构。
//   4. 光柱幂律亮度：pow(hash,3.2) 少数英雄柱 + 大量暗柱，亮度差跨一个
//      数量级（实拍里帘幕永远是有主次的，不是均匀亮带）。
//   5. 下缘锐利：d² 型亮线（σ≈0.008）贴着帘幕基线，活跃时沿亮线泛粉。
//   6. 深度堆叠：远帘暗/细/偏蓝（瑞利散射）/慢，近帘亮/宽/快，线性叠加
//      自然产生纵深。
//   7. 摄影"后期链"：ACES → 天光底色（夜空不是纯黑）→ 亮度加权胶片颗粒
//      （暗部颗粒重）→ 轻暗角。星空/银河/山脊是"锚"，帘幕再亮也盖不穿。
//   8. 行为：wander 慢相位驱动"平静帘 ↔ 活跃爆发"（substorm），爆发时
//      英雄柱增益×3、下缘泛粉、褶皱幅度抬升；beat/bass/treble 只进亮度/
//      幅度/闪烁，永不进速度与色相。
//
// 公共函数（hash/vn/fbm/wander/rot/filmic/dither/…）由工具链从 common.glsl
// 注入，不要在本文件重复定义。

// ---- 反馈（只做轻柔光晕余晖，不参与结构）--------------------------------
const float FB_GAIN = 0.20;         // 反馈增益（>0.35 会拖泥带水盖过直绘）
const float FB_ZOOM = 1.004;        // 采样微胀——余晖微微向外晕开
const float FB_CHROMA = 0.0009;     // 极轻色散（镜头感）

// ---- 磁天顶（光柱汇聚点，画面上方远处，慢游走）----------------------------
// 离屏远一点 → 放射线接近垂直（真实照片里磁天顶通常在画外高处，
// 太近会造成大角度斜条纹，削弱"帘幕垂直光柱"的观感）
const vec2 APEX_BASE = vec2(0.02, 1.42);
const vec2 APEX_WANDER = vec2(0.16, 0.13);

// ---- 帘幕结构 --------------------------------------------------------------
// 竖屏构图：帘幕是"从天顶垂下的高光幕"——底边（最亮最锐）落在画面
// 中部 0.02~0.30，帘体向上贯穿到画面顶（H 大）才渐隐。又扁又低的帘
// 读作"雾带"，是 v3 失败的根源。
const int CURTAIN_N = 4;
const float BASE_Y_LO = 0.020;      // 帘幕底边区间（画面中部）
const float BASE_Y_HI = 0.300;
const float TILT_AMP = 0.42;        // 帘幕整体倾斜（每帘不同——大幅斜跨
                                    //   画面，不是水平带）
const float ARC_GAIN = 0.34;        // 大尺度 fbm 弧（帘的整体走势）
const float WOB_AMP = 0.055;        // 行波褶皱幅度（叠加两波）
const float BODY_H = 0.42;          // 帘体向上衰减高度（贯穿上半屏！）
const float BORDER_W = 0.0045;      // 下缘亮线 σ（极锐！且下方不对称截止）
const float RED_LIFT = 0.24;        // 氧红层相对绿层的抬升量
const float RED_H_K = 1.5;          // 氧红层衰减高度 = BODY_H × K
const float RAY_FREQ = 82.0;        // 光柱角向频率
const float RAY_DRIFT = 0.090;      // 光柱沿帘漂移
const float BODY_GAIN = 1.15;       // 帘体增益
const float EDGE_GAIN = 4.60;       // 下缘亮线增益（帘幕最亮元素）
const float WIDE_GAIN = 0.14;       // 宽尺度环境光晕（镜头 bloom 解析近似）

// ---- 发射谱色（线性 HDR）----------------------------------------------------
const vec3 EMIT_GREEN = vec3(0.300, 1.000, 0.450);  // OI 557.7nm（略偏青消霓虹感）
const vec3 EMIT_RED = vec3(1.000, 0.180, 0.100);    // OI 630.0nm 暗红（高层）
const vec3 EMIT_PINK = vec3(1.000, 0.520, 0.720);   // N2+ 活跃下缘（picket）
const float RED_BASE = 0.10;        // 氧红常驻量（有，但淡）
const float RED_ACT = 0.40;         // 活跃时氧红增强量

// ---- 行为相位 --------------------------------------------------------------
const float ACT_SCALE = 71.0;       // substorm 慢相位（秒/格）
const float SURGE_RATE = 0.10;      // 沿帘扫过的增亮波（空间频率系，速度恒定）

// ---- 背景 ------------------------------------------------------------------
// 背景必须比帘幕暗一档（v3 星空/银河抢戏，帘幕淹没）——锚点要，但要收敛
const vec3 SKY_ZENITH = vec3(0.007, 0.011, 0.021);
const vec3 SKY_HORIZON = vec3(0.022, 0.032, 0.048);
const float MW_GAIN = 0.30;
const float RIDGE_FAR_Y = -0.335;
const float RIDGE_NEAR_Y = -0.435;
const float SEED_SPREAD = 173.0;

// 星层：幂律亮度 + 温度色 + 亮星衍射星芒（摄影衍射Artifact，加一点就够）
vec3 starLayer(vec2 q, float S, float thresh, float ts, float sd) {
    vec2 cell = floor(q * S);
    vec2 pos = fract(q * S) - 0.5;
    float h = hash21(cell);
    if (h < thresh) return vec3(0.0);
    vec2 off = (vec2(hash21(cell + 7.1), hash21(cell + 13.3)) - 0.5) * 0.72;
    vec2 sp = pos - off;
    float d2 = dot(sp, sp);
    float mag = pow(hash21(cell + 29.7), 7.0);   // 幂律：绝大多数肉眼刚可辨
    float twk = 0.72 + 0.28 * sin(ts * (1.3 + 2.6 * hash21(cell + 3.3))
        + hash21(cell + 5.5) * 40.0);
    float star = exp(-d2 * 250.0) * mag * twk;
    // 最亮的一撮加十字星芒
    float spike = step(0.965, hash21(cell + 41.0));
    star += spike * mag * 0.22 * exp(-d2 * 60.0)
        * (exp(-abs(sp.x) * 30.0) + exp(-abs(sp.y) * 30.0));
    float tt = hash21(cell + 61.0);
    vec3 sc = mix(vec3(1.0, 0.80, 0.62), vec3(0.70, 0.80, 1.0), tt);
    sc = mix(vec3(0.94, 0.95, 1.0), sc, 0.7);
    return sc * star;
}

// 帘幕层：返回线性 HDR 发射量。depth 0=最远 → 1=最近。
// out wideEnv：宽尺度环境光晕（bloom 解析近似），主循环外统一收。
vec3 curtain(vec2 q, float az, float fi, float ts, float sd, float depth,
    float act, float beatG, out float wideEnv) {
    float h1 = hash11(fi * 3.77 + sd);
    float h2 = hash11(fi * 7.31 + sd + 5.0);
    float h3 = hash11(fi * 11.9 + sd + 13.0);

    float span = mix(0.62, 1.55, depth);

    // 底边曲线：基线 + 每帘独立倾斜（大幅斜跨画面）+ 大尺度 fbm 弧 +
    // 行波褶皱 + 高频荷叶边——帘幕是大幅弯曲的幕，不是水平带
    float baseY = mix(BASE_Y_LO, BASE_Y_HI, fi / float(CURTAIN_N - 1))
        + 0.04 * sin(ts * 0.05 + fi * 2.2 + h2 * 6.28);
    float tilt = TILT_AMP * (h1 - 0.5) * 2.0;
    float yc = baseY + tilt * q.x
        + (fbm(vec2(q.x * (0.7 + 0.5 * h1) + fi * 7.7,
            ts * 0.014 + sd)) - 0.5) * ARC_GAIN * span
        + tilt * 0.35 * q.x * q.x; // 轻微弧形倾斜（帘的弯曲度）
    // 行波褶皱（速度恒定；幅度随活跃度抬升——不是速度）
    float wobA = WOB_AMP * span * (0.55 + 0.75 * act);
    yc += wobA * sin(q.x * (2.3 + 1.1 * h2) - ts * (0.26 + 0.16 * h3) + fi * 2.1);
    yc += wobA * 0.55 * sin(q.x * (4.9 + 1.6 * h1) + ts * (0.17 + 0.12 * h2) + fi * 4.7);
    yc += 0.0060 * span * sin(q.x * (16.0 + 5.0 * h1) + ts * 0.55 + fi * 9.0);

    // 水平存在感：柔化进退（0.55~1，不切碎——v3 的硬缺口把帘拆成了碎雾）
    float presence = 0.55 + 0.45 * smoothstep(0.35, 0.65,
        0.6 * vn(vec2(q.x * 0.55 + fi * 11.0, ts * 0.010 + sd * 0.7))
        + 0.4 * vn(vec2(q.x * 1.7 + fi * 3.0, ts * 0.017 + sd * 1.9)));

    // 光柱：az 恒定的直线族 → 条纹沿磁力线拉直并向天顶收拢。
    // 三层：暗柱铺底（覆盖）+ 英雄柱（幂律）+ 针状细光线（高频高次幂——
    // 实拍里帘幕总有几根扎眼的细亮线，其余是刚可辨的背景柱）
    float rf = fbm(vec2(az * RAY_FREQ + ts * RAY_DRIFT * (0.6 + 0.5 * h2)
        + fi * 17.0, fi * 3.1 + sd));
    float rays = 0.06 + 0.94 * pow(rf, 2.4);
    float hero = pow(rf, 2.8) * (1.0 + 3.2 * act);
    float needles = pow(fbm(vec2(az * RAY_FREQ * 2.7
        + ts * RAY_DRIFT * 1.35 + fi * 23.0, fi * 6.7 + sd)), 8.0)
        * (0.9 + 2.8 * act);
    float flick = 0.84 + 0.16 * sin(ts * (2.6 + 2.2 * h3) + az * 240.0
        + fi * 5.0 + uTreble * 5.0);

    // 剖面：d>0 帘体指数衰减 + 宽光晕；d≈0 下缘亮线（d² 型；线下方
    // 截止更快——σ 收 0.35 倍，实拍里线下方几乎是断崖）
    float d = q.y - yc;
    float dd = max(d, 0.0);
    float H = BODY_H * mix(1.30, 1.0, depth) * (0.85 + 0.30 * h2);
    float body = exp(-dd / H) * presence;
    float sig = d < 0.0 ? BORDER_W * 0.35 : BORDER_W;
    // 亮线的水平断口比帘体更强（presence²）：实拍亮线常整段消失再出现
    float border = exp(-d * d / (2.0 * sig * sig)) * presence * presence;
    wideEnv = exp(-dd / (H * 3.0)) * presence;

    // 沿帘扫过的增亮波（速度恒定的行波，由慢噪声选通——爆发期更频繁）
    float surge = smoothstep(0.60, 0.85,
        vn(vec2(q.x * 1.4 - ts * SURGE_RATE + fi * 7.0, sd + 3.0))) * act;

    // 强度（HDR，近帘为基准）
    float dk = mix(0.30, 1.0, depth);
    float bI = body * (rays + hero * 0.55 + needles * 1.1) * flick
        * (1.0 + 0.7 * surge);
    float eI = border * (0.75 + 0.60 * rf) * (1.0 + 1.8 * act * rf + 1.2 * surge);

    vec3 emis = EMIT_GREEN * bI * BODY_GAIN * dk * beatG;
    emis += EMIT_GREEN * eI * EDGE_GAIN * dk * beatG;
    // 氧红：抬升 + 变宽的独立层（沿同一批磁力线；高频被高空扩散抹平，
    // 所以光柱图案直接复用绿层的 rf，不再单独造一份）
    float dr = d - RED_LIFT * span;
    float red = exp(-max(dr, 0.0) / (H * RED_H_K)) * presence
        * (0.55 + 0.45 * rf);
    emis += EMIT_RED * red * (RED_BASE + RED_ACT * act)
        * (0.5 + 0.9 * h2) * dk * beatG;
    // N2+ 粉紫：只挂在活跃期的下缘亮线上
    emis += EMIT_PINK * eI * act * 0.34 * dk * beatG;
    // 远帘偏蓝（大气散射）+ 已由 dk 压暗
    emis = mix(emis * vec3(0.60, 0.72, 1.15), emis, depth);
    return emis;
}

void main() {
    float ts = nowSec();
    float sd = seedHash() * SEED_SPREAD;
    vec2 q = sceneUV(vec2(0.5, 0.42));
    float transA = smoothstep(0.0, 1.0, clamp(uTransition, 0.0, 1.0));

    // 活跃度（substorm 慢相位）：平静帘 ↔ 爆发
    float act = smoothstep(0.40, 0.78, wander2(ts, ACT_SCALE, sd + 7.0));
    // 节拍只进亮度（局部元素增益）
    float beatG = 1.0 + 0.32 * uBeat;

    // 磁天顶（屏幕上方外侧，慢游走）——光柱直线族的汇聚点
    vec2 apex = APEX_BASE + APEX_WANDER
        * vec2(wanderBi(ts, 61.0, sd + 3.0), wanderBi(ts, 47.0, sd + 9.0));
    vec2 vd = q - apex;
    float az = atan(vd.y, vd.x);

    // ---- 帘幕线性 HDR 叠加 + 宽尺度光晕 ----
    vec3 emis = vec3(0.0);
    float wide = 0.0;
    for (int i = 0; i < CURTAIN_N; i++) {
        float wenv;
        emis += curtain(q, az, float(i), ts, sd,
            float(i) / float(CURTAIN_N - 1), act, beatG, wenv);
        wide += wenv * mix(0.3, 1.0, float(i) / float(CURTAIN_N - 1));
    }
    emis *= transA;
    wide *= transA;

    // ---- 夜空底色（天顶→地平线渐变，不是纯黑）----
    float horiz = smoothstep(0.30, -0.42, q.y);
    vec3 sky = mix(SKY_ZENITH, SKY_HORIZON, horiz);
    // 地平线大气辉光（淡绿，极光夜的常客）
    sky += vec3(0.020, 0.045, 0.030)
        * exp(-pow((q.y - (-0.28)) * 5.5, 2.0)) * (0.5 + 0.5 * act);

    // ---- 银河：斜带 + 云絮 + 尘带（暗线是辨识度的关键）----
    vec2 mwDir = normalize(vec2(0.83, 1.0));
    float mwAxis = dot(q, mwDir) - 0.05;
    float band = exp(-mwAxis * mwAxis * 6.0);
    float cloud = 0.6 * fbm(q * 4.0 + 31.0) + 0.4 * fbm(q * 9.0 + 7.0);
    float dust = smoothstep(0.40, 0.62, fbm(q * 5.0 + 77.0));
    float along = dot(q, vec2(-mwDir.y, mwDir.x));
    vec3 mwCol = mix(vec3(0.10, 0.12, 0.19), vec3(0.21, 0.17, 0.13),
        smoothstep(-0.3, 0.35, along));
    sky += mwCol * band * (0.35 + 0.65 * cloud) * (1.0 - 0.60 * dust)
        * MW_GAIN * transA;

    // ---- 星空（透过帘：按发射亮度衰减透射率，薄处仍见星）----
    float veil = exp(-dot(emis, vec3(0.299, 0.587, 0.114)) * 0.85);
    vec3 stars = starLayer(q, 110.0, 0.82, ts, sd) * 1.6
        + starLayer(q, 46.0, 0.88, ts, sd) * 1.9
        + starLayer(q, 19.0, 0.94, ts, sd) * 2.4;
    sky += stars * veil * transA;

    // ---- 合成：直绘 + 宽光晕 + 反馈余晖 ----
    // 宽光晕偏蓝：散射光把绿拉向青蓝（夜空里帘幕周围的弥散光就是这样）
    vec3 col = sky + emis
        + mix(EMIT_GREEN, vec3(0.40, 0.70, 1.00), 0.35) * wide * WIDE_GAIN;

    // 反馈余晖：微胀采样 + 轻色散（镜头感），只做柔光不参与结构
    vec2 fuv = (vUV - 0.5) * FB_ZOOM + 0.5;
    vec3 prev;
    prev.r = texture2D(uPrev, fuv + FB_CHROMA).r;
    prev.g = texture2D(uPrev, fuv).g;
    prev.b = texture2D(uPrev, fuv - FB_CHROMA).b;
    col += prev * FB_GAIN;

    // ---- 摄影后期链：ACES → 暗角 → 亮度加权颗粒 ----
    col = filmic(col);
    col *= 1.0 - 0.30 * dot(q * 0.75, q * 0.75);
    float L = dot(col, vec3(0.299, 0.587, 0.114));
    col += vec3((hash21(vUV * uRes + fract(ts) * 17.0) - 0.5)
        * mix(0.022, 0.005, smoothstep(0.0, 0.35, L)));

    gl_FragColor = vec4(col, 1.0);
}
