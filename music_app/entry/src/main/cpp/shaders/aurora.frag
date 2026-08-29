// aurora.frag：反馈流极光（MilkDrop 式）。
//
// 每一帧以上一帧为画布：画面沿 fbm 流场扭曲、绕游走焦点缓旋、缓慢胀缩，
// 再采样衰减——极光不再只是"挂在那里的五条帘"，而是被风场不断糅合、
// 翻卷、拉伸的活体。帘幕亮线持续注入流场，被卷成层层光纱；星空与山脊
// 直绘保持清晰（静的锚点），天上的光则永远在动。
//
// 行为与颜色大范围演化（全部是连续坐标上的慢漂，不用整数层号跳变——
// 跳变就是"隔几秒画面突变一下"）：
//   - 流场强度在"平静如镜 ↔ 翻涌风暴"间往返（周期 ~50s 起步，各参数
//     速率不可通约，合成行为极长才重复）；
//   - 缩放率缓慢穿过 1.0：时而向焦点汇聚、时而向外发散；
//   - 色族一方面整轮慢漂（~45s 一圈色轮），另一方面"色散度"在
//     "近单色极光绿 ↔ 全彩虹"之间演化——有时写实、有时迷幻；
//   - 帘幕的"清晰度"也在反馈糅合与直接成像之间往返：有时锐利如刀、
//     有时全部化成光雾。
//
// 切换：不做整体交叉淡化（反馈流上叠交叉淡化会把上一风格当拖尾残留），
// 注入内容随 uTransition 渐入，旧内容被反馈流自然卷走（同 kaleido）。
//
// 公共函数（hash/vn/fbm/rot/hue2rgb/satBoost/toneExp/dither）由工具链从
// common.glsl 注入，不要在本文件重复定义。

// ---- 反馈流 ---------------------------------------------------------------
const float DECAY_BASE = 0.900;      // 反馈衰减基准（随风暴度 ±0.018）
const float LUMA_FADE = 0.45;        // 亮度自适应衰减：亮雾褪得快、暗天保持暗
                                     // （没有它反馈把整屏积累成均匀亮雾）
const float WARP_LO = 0.0016;        // 流场扭曲幅度区间（平静 ↔ 风暴）
const float WARP_HI = 0.0070;
const float ZOOM_IN = -0.011;        // 缩放率区间：负=向焦点汇聚（往里飞）
const float ZOOM_OUT = 0.005;        //             正=向外发散
const float ROT_AMP = 0.011;         // 缓旋角速度上限（弧度/帧）
const float DRIFT_X_AMP = 0.0022;    // 整体平流（风）幅度
const float DRIFT_Y_AMP = 0.0038;
const float CHROMA_IN = 0.9968;      // RGB 微差异采样 → 色散
const float CHROMA_OUT = 1.0032;
const float EDGE_FADE_LO = 0.78;     // 边缘压暗（防采样夹取边框拖痕）
const float EDGE_FADE_HI = 1.32;
const float EDGE_DARKEN = 0.88;

// ---- 游走焦点 -------------------------------------------------------------
const vec2 FOCUS_WANDER_1 = vec2(0.083, 0.071);
const vec2 FOCUS_WANDER_2 = vec2(0.027, 0.037);
const float FOCUS_AMP_1 = 0.14;
const float FOCUS_AMP_2 = 0.05;

// ---- 帘幕注入 --------------------------------------------------------------
const int BAND_COUNT = 5;
const float BASE_Y_LO = -0.60;       // 基线纵贯全屏（最底层与山脊留出空隙）
const float BASE_Y_HI = 0.74;
const float BASE_Y_WANDER = 0.13;    // 基线慢漂移幅度
const float CURVE_AMP = 0.40;        // fbm 曲线起伏（乘 bassSway）
const float BASS_SWAY = 0.8;
const float PROFILE_LO = 26.0;       // 帘体下缘陡峭度
const float PROFILE_HI = 4.2;        // 光柱向上衰减
const float RAY_SHARP = 120.0;       // 竖直光柱条纹频率基数
const float EDGE_GLOW_SHARP = 30.0;  // 下缘亮线锐度
const float INJECT_EDGE = 0.05;      // 注入：亮线强度（细线为主，粗了反馈平衡后整屏泛雾）
const float INJECT_BODY = 0.008;     // 注入：帘体强度（弱！反馈平衡 ×10，大了整屏铺雾）
const float INJECT_LUM_REF = 0.40;   // 注入色亮度归一（色轮相位固有亮度差 ~2 倍，
                                     // 不归一则反馈平衡亮度随色相周期过曝/过暗）
const float CRISP_LO = 0.20;         // 直绘帘幕占比区间（清晰度演化）
const float CRISP_HI = 0.50;
const float BEAT_INJECT = 0.55;      // 节拍 → 注入增亮（不改变流场，避免抽动）

// ---- 颜色演化 ---------------------------------------------------------------
const float HUE_DRIFT_RATE = 0.022;  // 整轮色漂移速（~45s 一圈色轮）
const float SPREAD_LO = 0.06;        // 色散度：近单色（写实极光）
const float SPREAD_HI = 0.55;        //          全彩虹（迷幻）
const float GREEN_ANCHOR = 0.67;     // 写实极光绿（hue2rgb 色轮）
const float SAT_LO = 1.05;           // 饱和度演化区间
const float SAT_HI = 1.55;

// ---- 背景元素 ----------------------------------------------------------------
const float MW_FALLOFF = 3.2;        // 银河斜带宽度
const float RIDGE_BASE = -0.72;      // 山脊基线
const float RIDGE_AMP = 0.09;

// ---- 收尾 ---------------------------------------------------------------------
const float TONE_EXPOSURE = 0.95;
const float VIGNETTE = 0.28;
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

// 帘幕层 i 的剖面与颜色：返回注入用 rgb（edge 亮线 + body 帘体分开加权）
// yc 同时输出供直绘复用。
vec3 curtain(vec2 q, float fi, float ts, float sd, float hueBase,
    float spread, float greenK, float sat, float bassSway,
    out float prof, out float edge) {
    float h1 = hash11(fi * 3.77 + sd);
    float h2 = hash11(fi * 7.31 + sd + 5.0);
    float h3 = hash11(fi * 11.9 + sd + 13.0);
    float baseY = mix(BASE_Y_LO, BASE_Y_HI, fi / float(BAND_COUNT - 1))
        + BASE_Y_WANDER * sin(ts * (0.05 + 0.03 * h2) + fi * 2.2);
    float curve = fbm(vec2(q.x * (0.9 + 0.6 * h1) + fi * 13.7,
        ts * (0.030 + 0.020 * h2))) - 0.5;
    float yc = baseY + curve * CURVE_AMP * bassSway;
    float d = q.y - yc;
    prof = mix(exp(d * PROFILE_LO), exp(-d * (PROFILE_HI + 1.2 * h3)), step(0.0, d));
    // 竖直光柱条纹
    float rays = 0.50 + 0.50 * fbm(vec2(q.x * (7.0 + 4.0 * h1) + fi * 31.0,
        yc * 2.0 - ts * (0.06 + 0.05 * h2)));
    rays *= 0.78 + 0.22 * sin(q.x * (RAY_SHARP + 60.0 * h3) + yc * 14.0 + ts * (0.5 + h2));
    prof *= rays;
    edge = exp(-abs(d) * EDGE_GLOW_SHARP) * rays;
    // 颜色：整轮色漂 + 层间色散（spread 演化）+ 高度内小漂移 + 写实绿锚定
    float alt = clamp(d * 1.3 + 0.10, 0.0, 1.0);
    float hue = hueBase + (fi - 2.0) * spread
        + 0.16 * (alt - 0.5) * (0.4 + spread)
        + 0.05 * sin(ts * 0.017 + sd + fi * 1.7)
        + uTreble * 0.03;
    hue = mix(hue, GREEN_ANCHOR + 0.05 * (alt - 0.5) + fi * 0.012, greenK);
    vec3 cc = satBoost(hue2rgb(hue), sat);
    // 下缘亮线更艳
    cc += hue2rgb(hue) * edge * 0.9;
    return cc;
}

void main() {
    float ts = nowSec();
    float sd = seedHash() * SEED_SPREAD;
    float aspect = aspectRatio();
    float transA = smoothstep(0.0, 1.0, clamp(uTransition, 0.0, 1.0));
    vec2 q = sceneUV(vec2(0.5, 0.42));

    // ---- 行为演化相位（速率不可通约 → 合成行为极长周期才重复）----
    float storm = 0.5 + 0.5 * sin(ts * 0.021 + sd);              // 风暴度
    float zoomK = 1.0 + mix(ZOOM_IN, ZOOM_OUT, 0.5 + 0.5 * sin(ts * 0.013 + sd * 1.7));
    float rotA = ROT_AMP * sin(ts * 0.017 + sd * 2.3);
    vec2 wind = vec2(DRIFT_X_AMP * sin(ts * 0.016 + sd * 4.1),
        DRIFT_Y_AMP * sin(ts * 0.019 + sd * 3.1));
    float crisp = mix(CRISP_LO, CRISP_HI, 0.5 + 0.5 * sin(ts * 0.011 + sd * 0.7));
    float spread = mix(SPREAD_LO, SPREAD_HI, 0.5 + 0.5 * sin(ts * 0.009 + sd * 1.3));
    float greenK = pow(0.5 + 0.5 * sin(ts * 0.014 + sd * 2.9), 2.0); // 偏置向写实
    float sat = mix(SAT_LO, SAT_HI, 0.5 + 0.5 * sin(ts * 0.018 + sd * 5.3));
    float hueBase = ts * HUE_DRIFT_RATE + sd * 0.02;

    // ---- 反馈采样：绕焦点旋 + 胀缩 + 流场扭曲 + 风 ----
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
    prev *= DECAY_BASE - 0.018 * storm;
    // 亮度自适应衰减：亮雾退得快，夜空保持暗——反馈场景的对比度命门
    float prevLum = dot(prev, vec3(0.299, 0.587, 0.114));
    prev *= 1.0 - LUMA_FADE * clamp(prevLum - 0.15, 0.0, 0.5);
    float edgeFade = smoothstep(EDGE_FADE_HI, EDGE_FADE_LO, r);
    prev *= mix(EDGE_DARKEN, 1.0, edgeFade);

    // ---- 帘幕：注入（被流场糅合）+ 直绘（清晰度演化）----
    float bassSway = 1.0 + BASS_SWAY * uBass;
    vec3 inject = vec3(0.0);
    vec3 direct = vec3(0.0);
    for (int i = 0; i < BAND_COUNT; i++) {
        float fi = float(i);
        float prof;
        float edge;
        vec3 cc = curtain(q, fi, ts, sd, hueBase, spread, greenK, sat, bassSway, prof, edge);
        float beat = 1.0 + BEAT_INJECT * uBeat * (0.5 + 0.5 * sin(ts * 1.3 + fi * 2.6));
        // 亮度归一：只拉平色轮相位间亮度差，保留图案内部明暗结构
        vec3 lineCol = cc * edge;
        float pl = dot(lineCol, vec3(0.299, 0.587, 0.114));
        lineCol *= min(1.0, INJECT_LUM_REF / max(pl, 1e-3));
        inject += (lineCol * INJECT_EDGE + cc * prof * INJECT_BODY) * beat;
        direct += cc * prof * 0.40 * beat;
    }
    inject *= transA;
    direct *= transA;

    vec3 col = prev + inject + direct * crisp;

    // ---- 直绘锚点：星空（清晰）----
    float veil = clamp(dot(col, vec3(0.299, 0.587, 0.114)) * 2.2, 0.0, 1.0);
    vec3 starCol = stars(q, 96.0, 0.90, 2.6, ts) * 0.8
        + stars(q, 38.0, 0.93, 1.4, ts) * 1.1;
    col += starCol * (1.0 - veil * 0.70) * transA;

    // ---- 银河斜带（淡）----
    float mw = exp(-pow(dot(q, normalize(vec2(0.55, 1.0))), 2.0) * MW_FALLOFF);
    col += vec3(0.10, 0.12, 0.19) * mw * (0.35 + 0.65 * fbm(q * 3.1 + 7.0)) * 0.35 * transA;

    // ---- 地平线山脊剪影（静的锚点；压重些，别让帘幕光雾吞掉）----
    float ridge = RIDGE_BASE + fbm(vec2(q.x * 2.6, sd)) * RIDGE_AMP;
    float ground = smoothstep(ridge + 0.005, ridge - 0.02, q.y);
    col = mix(col, col * 0.10 + vec3(0.003, 0.006, 0.010), ground);

    col = toneExp(col, TONE_EXPOSURE);
    col *= 1.0 - VIGNETTE * dot(q * 0.8, q * 0.8);
    col += dither(vUV * uRes, ts);

    gl_FragColor = vec4(col, 1.0);
}
