// aurora.frag：结构化极光（直绘帘幕 × 弱反馈柔化）。
//
// 重制对照（旧版"美不起来"的根源）：
//   旧版把帘幕当"注入源"全靠 fbm 反馈流糅合成像——结果是紫粉色的雾，
//   极光的所有标志性结构都被反馈抹掉了。真实极光的辨识度来自：
//     1. 帘幕剖面：下缘最亮且锐利（电子沉降密度峰值高度），向上指数
//        衰减散开——不是对称的光带，是"一边刀口一边渐隐"的帘；
//     2. 垂直光柱（rays）：沿磁力线的精细条纹，帘不是均匀发光体；
//     3. 褶皱增亮（folds）：帘面波浪翻卷，折叠处视线穿过更厚发光层
//        → 亮度 ∝ √(1+slope²)，亮弧沿帘跑；
//     4. 颜色稳定：氧绿 557.7nm 为主（不是彩虹！），上缘氧红 630nm
//        紫红过渡，活跃时下缘闪氮蓝紫；颜色稳、形态变，才高级；
//     5. 纵深：多条帘前后叠——远帘暗、小、慢、偏蓝（大气透视），
//        近帘亮、大、快；
//     6. 偶发爆发（substorm）：慢噪声过阈值时整帘增亮 + 翻卷提速，
//        持续几秒衰减——"等什么"的期待感是持续观看欲的核心。
//
// 成像分工：帘幕全部直绘（每帧重建清晰结构），反馈流只负责柔化边缘
// 与风场糅合感（短拖尾、弱注入、亮度自适应衰减防积雾——对比度命门）。
// 星空/银河/山脊直绘保持清晰（静的锚点），不被帘光吞掉。
//
// 公共函数（hash/vn/fbm/rot/hue2rgb/satBoost/toneExp/dither）由工具链从
// common.glsl 注入，不要在本文件重复定义。

// ---- 反馈流（降级为柔化辅助）------------------------------------------------
const float DECAY_BASE = 0.935;      // 反馈衰减基准（短拖尾，别糊住直绘结构）
const float LUMA_FADE = 0.50;        // 亮度自适应衰减：亮雾褪得快、夜空保持暗
const float WARP_LO = 0.0012;        // 流场扭曲幅度区间（风，弱）
const float WARP_HI = 0.0040;
const float ZOOM_IN = -0.006;        // 缩放率区间（比旧版收敛，减少"吸入感"）
const float ZOOM_OUT = 0.003;
const float ROT_AMP = 0.006;
const float DRIFT_X_AMP = 0.0016;    // 整体平流（风）幅度
const float DRIFT_Y_AMP = 0.0026;
const float CHROMA_IN = 0.9980;      // RGB 微差异采样 → 色散（微量）
const float CHROMA_OUT = 1.0020;
const float EDGE_FADE_LO = 0.78;
const float EDGE_FADE_HI = 1.32;
const float EDGE_DARKEN = 0.90;

// ---- 游走焦点 -------------------------------------------------------------
const vec2 FOCUS_WANDER_1 = vec2(0.083, 0.071);
const vec2 FOCUS_WANDER_2 = vec2(0.027, 0.037);
const float FOCUS_AMP_1 = 0.14;
const float FOCUS_AMP_2 = 0.05;

// ---- 帘幕结构 --------------------------------------------------------------
const int CURTAIN_COUNT = 4;         // 1 远 + 3 近，纵深分层
// 基线范围按竖屏可视区标定（q.y ∈ 约 −0.42~0.58）：
// 最低帘沉到下 1/3，最高帘贴画面上缘——四条帘铺满全屏纵深
const float BASE_Y_LO = -0.28;
const float BASE_Y_HI = 0.40;
const float BASE_Y_WANDER = 0.05;    // 基线慢漂移幅度
const float FBM_CURVE = 0.28;        // 大尺度 fbm 弧（帘的整体走势）
const float WOB1_AMP = 0.060;        // 行波褶皱 1（大波）
const float WOB2_AMP = 0.034;        // 行波褶皱 2（小波，反向）
const float PROFILE_BELOW = 26.0;    // 下缘锐度（刀口）
const float PROFILE_ABOVE = 3.2;     // 向上衰减（帘体散开）
const float EDGE_SHARP = 55.0;       // 下缘亮线锐度
const float FOLD_GAIN = 8.0;         // 褶皱增亮强度（√(1+k·slope²)）
const float RAY_FREQ = 14.0;         // 光柱条纹空间频率基数（近帘）
const float RAY_DRIFT = 0.35;        // 光柱沿帘漂移速度
const float INJECT_EDGE = 0.016;     // 注入反馈的亮线强度（弱：只供糅合）
const float INJECT_BODY = 0.003;
const float INJECT_LUM_REF = 0.40;   // 注入色亮度归一（色轮相位固有亮度差）

// ---- 颜色（稳定，慢漂收窄）---------------------------------------------------
const float HUE_GREEN = 0.66;        // 氧绿主锚（hue2rgb 色轮）
const float HUE_RED = 0.97;          // 上缘氧红（紫红）
const float HUE_NITROGEN = 0.30;     // 氮蓝紫（活跃下缘）
const float RED_EDGE_MAX = 0.95;     // 上缘红过渡的最大占比（随时间演化）
const float HUE_DRIFT_AMP = 0.030;   // 色相慢漂幅度（收窄！彩虹漂移是旧版
                                     //   "塑料感"的根源，真实极光颜色很稳）

// ---- 爆发（substorm）---------------------------------------------------------
const float BURST_RATE = 0.035;      // 爆发驱动噪声速率（~30s 一格）
const float BURST_LO = 0.60;         // 触发阈值区间
const float BURST_HI = 0.82;
const float BURST_GAIN = 1.6;        // 爆发时整帘增亮倍数上限

// ---- 背景元素 ----------------------------------------------------------------
const float MW_FALLOFF = 3.2;        // 银河斜带宽度
const float RIDGE_BASE = -0.40;      // 山脊基线（贴着画面下缘，旧版 −0.72
                                     //   在竖屏可视区外 = 没有地面锚点）
const float RIDGE_AMP = 0.07;
const float AIRGLOW = 0.07;          // 地平线大气辉光（淡绿）

// ---- 收尾 ---------------------------------------------------------------------
const float TONE_EXPOSURE = 0.95;
const float VIGNETTE = 0.26;
const float SEED_SPREAD = 173.0;

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

// 帘幕层 i：返回颜色，prof/edge 输出供注入复用。
// depth：0=最远（暗、小、慢、偏蓝）→ 1=最近（亮、大、快）。
vec3 curtain(vec2 q, float fi, float ts, float sd, float depth,
    float bassSway, float burst, float hueBase,
    out float prof, out float edge) {
    float h1 = hash11(fi * 3.77 + sd);
    float h2 = hash11(fi * 7.31 + sd + 5.0);
    float h3 = hash11(fi * 11.9 + sd + 13.0);

    // 基线：纵贯分布 + 慢漂移；近帘摆动幅度大
    float span = mix(0.55, 1.5, depth);
    float baseY = mix(BASE_Y_LO, BASE_Y_HI, fi / float(CURTAIN_COUNT - 1))
        + BASE_Y_WANDER * sin(ts * (0.05 + 0.03 * h2) + fi * 2.2);

    // 大尺度弧（帘的整体走势，fbm 缓变）+ 两条反向行波褶皱；
    // 爆发时褶皱提速（翻卷加剧）
    float wobSpeed = (0.5 + bassSway) * (1.0 + 0.8 * burst);
    float k1 = 2.2 + 1.0 * h2;
    float k2 = 4.7 + 1.5 * h1;
    float ph1 = q.x * k1 - ts * (0.25 + 0.20 * h3) * wobSpeed + fi;
    float ph2 = q.x * k2 + ts * (0.16 + 0.15 * h2) * wobSpeed + fi * 2.4;
    float yc = baseY
        + (fbm(vec2(q.x * (0.5 + 0.3 * h1) + fi * 7.0, ts * 0.02)) - 0.5)
            * FBM_CURVE * span
        + (WOB1_AMP * sin(ph1) + WOB2_AMP * sin(ph2)) * span * bassSway;
    float d = q.y - yc;

    // 褶皱增亮：视线穿过倾斜帘面的路径更长（fbm 缓坡忽略，取行波解析斜率）
    float slope = (WOB1_AMP * k1 * cos(ph1) + WOB2_AMP * k2 * cos(ph2))
        * span * bassSway;
    float fold = sqrt(1.0 + slope * slope * FOLD_GAIN);

    // 剖面：下缘刀口（d<0 陡降）+ 向上散开（d>0 指数衰减）
    prof = mix(exp(-d * (PROFILE_ABOVE + 1.5 * h3)), exp(d * PROFILE_BELOW),
        step(d, 0.0));

    // 垂直光柱：沿帘切向的高频条纹，随时间漂移 + treble 闪烁；
    // 远帘条纹更细密（透视缩小）。pow 拉对比——真极光是亮柱与暗隙
    // 分明的"琴键"，软 fbm 糊成一片就没有帘感
    float rayFreq = RAY_FREQ * mix(1.7, 1.0, depth) * (0.8 + 0.5 * h1);
    float r1 = fbm(vec2(q.x * rayFreq + ts * RAY_DRIFT * (0.5 + h2) + fi * 13.0,
        yc * 3.0));
    float rays = pow(r1, 1.5) * 1.35;
    rays *= 0.75 + 0.25 * sin(q.x * rayFreq * 4.0 + ts * 2.0 + fi
        + uTreble * 3.0);
    prof *= rays * fold;
    edge = exp(-abs(d) * EDGE_SHARP) * rays * fold;

    // 颜色：下缘亮绿 → 中部翠绿 → 上缘紫红。
    // 氧红 630nm 物理上是更高海拔的**独立发光层**：必须叠加而非插值——
    // 插值会把亮绿换成暗红（红相固有色度低），等于"上缘变脏"而不是泛红
    float redK = RED_EDGE_MAX * (0.4 + 0.6 * h2)
        * (0.5 + 0.5 * sin(ts * 0.010 + sd * 1.3 + fi));
    vec3 cGreen = hue2rgb(hueBase + 0.02 * h2);
    vec3 cc = cGreen;
    float redLayer = smoothstep(0.08, 0.35, d) * exp(-d * 2.2) * redK;
    cc += hue2rgb(HUE_RED + HUE_DRIFT_AMP * h1) * redLayer * 1.3;
    // 爆发时下缘闪氮蓝紫；远帘整体偏蓝（大气透视）
    cc += hue2rgb(HUE_NITROGEN) * exp(-abs(d) * 80.0) * burst * 0.35;
    cc = mix(cc, cc * vec3(0.55, 0.65, 1.05), (1.0 - depth) * 0.5);
    // 纵深：远帘压暗
    cc *= mix(0.28, 1.0, depth);
    // 下缘亮线更艳
    cc += cGreen * edge * 0.9 * mix(0.5, 1.0, depth);
    return cc;
}

void main() {
    float ts = nowSec();
    float sd = seedHash() * SEED_SPREAD;
    float aspect = aspectRatio();
    float transA = smoothstep(0.0, 1.0, clamp(uTransition, 0.0, 1.0));
    vec2 q = sceneUV(vec2(0.5, 0.42));

    // ---- 行为演化相位（全部连续慢漂，速率不可通约）----
    float storm = 0.5 + 0.5 * sin(ts * 0.021 + sd);
    float zoomK = 1.0 + mix(ZOOM_IN, ZOOM_OUT, 0.5 + 0.5 * sin(ts * 0.013 + sd * 1.7));
    float rotA = ROT_AMP * sin(ts * 0.017 + sd * 2.3);
    vec2 wind = vec2(DRIFT_X_AMP * sin(ts * 0.016 + sd * 4.1),
        DRIFT_Y_AMP * sin(ts * 0.019 + sd * 3.1));
    float hueBase = HUE_GREEN + HUE_DRIFT_AMP * sin(ts * 0.012 + sd * 0.6);

    // 爆发（substorm）：慢噪声过阈值 → 偶发整帘增亮 + 翻卷提速
    float burst = smoothstep(BURST_LO, BURST_HI, vn(vec2(ts * BURST_RATE, sd)));

    // ---- 反馈采样：绕焦点旋 + 胀缩 + 流场扭曲 + 风（柔化辅助）----
    vec2 c = vec2(0.5, 0.52)
        + FOCUS_AMP_1 * vec2(sin(ts * FOCUS_WANDER_1.x + sd), cos(ts * FOCUS_WANDER_1.y + sd * 1.7))
        + FOCUS_AMP_2 * vec2(sin(ts * FOCUS_WANDER_2.x + sd * 2.3), cos(ts * FOCUS_WANDER_2.y + sd));
    vec2 d = vUV - c;
    float r = length(d * vec2(aspect, 1.0));
    float warpAmp = mix(WARP_LO, WARP_HI, storm) * (1.0 + 0.5 * uBass);
    vec2 dp = rot(rotA * (0.6 + 0.4 * storm)) * d * zoomK;
    dp += warpAmp * vec2(
        fbm(vUV * 3.2 + vec2(ts * 0.05, sd)) - 0.5,
        fbm(vUV * 3.2 + vec2(sd + 31.0, -ts * 0.043)) - 0.5) * 2.0;
    dp += wind * (0.5 + storm);

    vec3 prev;
    prev.r = texture2D(uPrev, c + dp * CHROMA_IN).r;
    prev.g = texture2D(uPrev, c + dp).g;
    prev.b = texture2D(uPrev, c + dp * CHROMA_OUT).b;
    prev *= DECAY_BASE - 0.015 * storm;
    // 亮度自适应衰减：亮雾退得快，夜空保持暗——反馈场景的对比度命门
    float prevLum = dot(prev, vec3(0.299, 0.587, 0.114));
    prev *= 1.0 - LUMA_FADE * clamp(prevLum - 0.15, 0.0, 0.5);
    float edgeFade = smoothstep(EDGE_FADE_HI, EDGE_FADE_LO, r);
    prev *= mix(EDGE_DARKEN, 1.0, edgeFade);

    // ---- 帘幕：直绘（结构主体）+ 弱注入（供反馈糅合）----
    float bassSway = 0.7 + 0.6 * uBass;
    vec3 inject = vec3(0.0);
    vec3 direct = vec3(0.0);
    for (int i = 0; i < CURTAIN_COUNT; i++) {
        float fi = float(i);
        float depth = fi / float(CURTAIN_COUNT - 1); // 0=最远 → 1=最近
        float prof;
        float edge;
        vec3 cc = curtain(q, fi, ts, sd, depth, bassSway, burst, hueBase,
            prof, edge);
        float beat = 1.0 + 0.5 * uBeat * (0.5 + 0.5 * sin(ts * 1.3 + fi * 2.6));
        vec3 lineCol = cc * edge;
        float pl = dot(lineCol, vec3(0.299, 0.587, 0.114));
        lineCol *= min(1.0, INJECT_LUM_REF / max(pl, 1e-3));
        inject += (lineCol * INJECT_EDGE + cc * prof * INJECT_BODY) * beat;
        // 直绘增益按"四帘叠加不过曝"标定（实测 0.55/0.30 时 lum 0.40、
        // bright 90%，极光再亮也不该把夜空照成白昼）
        direct += cc * prof * 0.30 * beat + cc * edge * (0.18 + 0.35 * burst);
    }
    inject *= transA;
    direct *= transA * (1.0 + BURST_GAIN * burst);

    vec3 col = prev + inject + direct;

    // ---- 直绘锚点：星空（清晰，帘亮处稍掩）----
    float veil = clamp(dot(col, vec3(0.299, 0.587, 0.114)) * 2.2, 0.0, 1.0);
    vec3 starCol = stars(q, 96.0, 0.90, 2.6, ts) * 1.2
        + stars(q, 38.0, 0.93, 1.4, ts) * 1.5;
    col += starCol * (1.0 - veil * 0.70) * transA;

    // ---- 银河斜带（淡）----
    float mw = exp(-pow(dot(q, normalize(vec2(0.55, 1.0))), 2.0) * MW_FALLOFF);
    col += vec3(0.10, 0.12, 0.19) * mw * (0.35 + 0.65 * fbm(q * 3.1 + 7.0)) * 0.35 * transA;

    // ---- 地平线大气辉光（淡绿，极光常客）----
    float horizon = RIDGE_BASE + 0.10;
    col += hue2rgb(HUE_GREEN) * exp(-pow((q.y - horizon) * 6.0, 2.0))
        * AIRGLOW * (0.6 + 0.4 * burst) * transA;

    // ---- 地平线山脊剪影（静的锚点）----
    float ridge = RIDGE_BASE + fbm(vec2(q.x * 2.6, sd)) * RIDGE_AMP;
    float ground = smoothstep(ridge + 0.005, ridge - 0.02, q.y);
    col = mix(col, col * 0.10 + vec3(0.003, 0.006, 0.010), ground);

    col = toneExp(col, TONE_EXPOSURE);
    col *= 1.0 - VIGNETTE * dot(q * 0.8, q * 0.8);
    col += dither(vUV * uRes, ts);

    gl_FragColor = vec4(col, 1.0);
}
