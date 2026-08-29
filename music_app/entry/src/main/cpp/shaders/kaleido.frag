// kaleido.frag：反馈深潜 · 无尽万花筒（原名 mirror.frag，"镜渊"名不副实）。
//
// 每一帧以上一帧为画布：围绕一个缓缓游走的焦点做「缩放 + 旋转 +
// 桶形畸变 + 卷曲扰动」再采样——画面内容被不断拉向观者，焦点本身
// 又在移动（摄像机跟随视线），于是一路向屏幕深处行进、永无止境。
//
// 风格多变来自两条（全部是连续慢漂，不用跳变）：
//   1. 焦点处注入的程序化内容在**三种形态间慢速轮换**：万花筒曼陀罗
//      （瓣数在 5/7/9 间 morph）、对数螺旋臂、绕焦点的彗星（被反馈
//      拉成光环星轨）；脉冲光环与核心辉光常驻。三种权重速率不可通约，
//      合成形态极长周期才重复。
//   2. 反馈变换本身在演化：俯冲速度、螺旋强度、桶形畸变、色散量
//      都随播放时钟慢漂，色族相位也大范围游走。
// RGB 三通道以微差异采样率分离出色散，节拍会加快俯冲速度。
//
// 注意：本场景不做整体交叉淡化（applyTransition）——反馈流上叠交叉淡化
// 会把上一风格的内容当拖尾残留；切换靠注入内容随 uTransition 渐入，
// 旧内容被反馈流自然卷走。
//
// 公共函数（hash/vn/rot/palIQ/satBoost/toneExp）由工具链从 common.glsl
// 注入，不要在本文件重复定义。

// ---- 游走焦点 -------------------------------------------------------------
const vec2 FOCUS_WANDER_1 = vec2(0.113, 0.097); // 主游走角速度（x/y 不同步）
const vec2 FOCUS_WANDER_2 = vec2(0.031, 0.043); // 次级游走角速度
const float FOCUS_AMP_1 = 0.16;
const float FOCUS_AMP_2 = 0.05;

// ---- 反馈变换（参数随时间慢漂 → 行为演化）----------------------------------
const float ZOOM_BASE = 0.9865;      // 每帧向焦点俯冲的缩放率基准
const float ZOOM_DRIFT = 0.0040;     // 俯冲速度慢漂（0.983~0.991，保持向内）
const float ZOOM_BEAT = 0.007;       // beat 加速俯冲
const float ZOOM_BASS = 0.003;       // bass 加速俯冲
const float SWIRL_BASE = 0.010;      // 基础螺旋角速度
const float SWIRL_EVOLVE = 0.55;     // 螺旋强度演化幅度（×0.45~1.55）
const float SWIRL_CORE = 0.16;       // 焦点附近的额外旋拧（径向衰减）
const float SWIRL_CORE_BASS = 0.20;
const float SWIRL_CORE_FALLOFF = 2.6;
const float SWIRL_TREBLE = 0.02;     // treble 微抖
const float BARREL = 0.06;           // 桶形畸变基准（径向平方项）
const float BARREL_EVOLVE = 0.045;   // 畸变演化幅度
const float CURL_AMP = 0.0016;       // 卷曲扰动幅度
const float DECAY = 0.950;           // 反馈衰减：给注入留位（0.958 会启动爆发）
const float EDGE_FADE_LO = 0.80;     // 边缘压暗区间（防采样夹取的边框拖痕）
const float EDGE_FADE_HI = 1.30;
const float EDGE_DARKEN = 0.90;

// ---- 色散 -----------------------------------------------------------------
const float CHROMA_IN = 0.9965;      // R 通道稍慢 → 向内色散
const float CHROMA_OUT = 1.0035;     // B 通道稍快 → 向外色散
const float CHROMA_EVOLVE = 0.0012;  // 色散量慢漂

// ---- 焦点注入：三种形态慢速轮换 ---------------------------------------------
const float MANDALA_SCROLL = 0.05;   // 曼陀罗旋转速度
const float MANDALA_DETAIL = 2.5;    // 瓣内细纹频率
const float MANDALA_FALLOFF = 5.0;   // 曼陀罗径向衰减
const float SYM_MORPH_RATE = 0.011;  // 瓣数 morph 速率（5↔7↔9 连续轮换）
const float SPIRAL_ARMS = 3.0;       // 螺旋臂条数
const float SPIRAL_TWIST = 5.5;      // 对数螺旋的拧紧度
const float SPIRAL_SHARP = 2.4;      // 臂的锐利度
const float SPIRAL_FALLOFF = 2.6;
const float SPIRAL_SCROLL = 0.35;    // 螺旋旋转速度
const int COMET_COUNT = 3;           // 彗星数（被反馈拉成星轨）
const float COMET_GLOW = 900.0;      // 彗星亮点收紧
const float COMET_FALLOFF = 0.55;    // 彗星贡献随焦点距离衰减
const float RING_FREQ = 3.2;         // 脉冲光环空间频率
const float RING_SCROLL = 0.16;      // 光环外扩速度
const float RING_SHARP = 26.0;       // 光环锐度
const float RING_FALLOFF = 1.6;
const float CORE_GLOW = 260.0;       // 核心辉光收紧程度
const float SPARK_DENSITY = 0.9982;  // 星火粒子闪现阈值（越小越稀）
const float SPARK_FALLOFF = 2.4;
const float INJECT_GAIN = 0.85;      // 注入整体强度
// 注入色亮度归一：余弦色轮各相位固有亮度差 ~2 倍（黄 ~0.8 / 青 ~0.6 / 紫 ~0.4），
// 而反馈平衡亮度 ∝ 注入亮度 → 画面随色相周期过曝/过暗（实测黄相位
// bright 占比 69%，紫相位 23%）。把注入色亮度统一压到 REF（= 最暗紫相位
// 的固有亮度，紫相位不受影响），只拉平色轮相位间的亮度差，
// 图案内部的明暗结构（核心亮、外环弱）保持不变。
const float INJECT_LUM_REF = 0.42;

// ---- 收尾 -----------------------------------------------------------------
const float TONE_EXPOSURE = 1.05;
const float SAT_BOOST = 0.95;        // 轻降饱和（色轮本身已艳，1.12 实测 sat 0.96+）
const float VIGNETTE = 0.32;
const float SEED_SPREAD = 173.0;

// 色族（palIQ 的频率/相位向量）
const vec3 PAL_C = vec3(0.9, 1.0, 1.1);
const vec3 PAL_D = vec3(0.0, 0.12, 0.38);

vec3 pal(float t) {
    return palIQ(t, PAL_C, PAL_D);
}

// 万花筒瓣图案：sym 重对称（整数），返回瓣面强度
float petal(float ia, float ir, float sym, float ts) {
    float fa = abs(mod(ia + ts * MANDALA_SCROLL, TAU / sym) - PI / sym);
    return exp(-abs(sin(fa * MANDALA_DETAIL * sym / 6.0 + ts * 0.35 + ir * 15.0)) * 3.2)
        * exp(-ir * MANDALA_FALLOFF);
}

void main() {
    float ts = nowSec();
    float sd = seedHash() * SEED_SPREAD;
    float aspect = aspectRatio();
    float transA = smoothstep(0.0, 1.0, clamp(uTransition, 0.0, 1.0));

    // ---- 游走焦点：摄像机缓慢跟随的"视线" ----
    vec2 c = vec2(0.5)
        + FOCUS_AMP_1 * vec2(sin(ts * FOCUS_WANDER_1.x + sd), cos(ts * FOCUS_WANDER_1.y + sd * 1.7))
        + FOCUS_AMP_2 * vec2(sin(ts * FOCUS_WANDER_2.x + sd * 2.3), cos(ts * FOCUS_WANDER_2.y + sd));

    vec2 d = vUV - c;
    float r = length(d * vec2(aspect, 1.0));

    // ---- 反馈变换：每帧向焦点内俯冲（beat 加速）+ 螺旋 + 畸变 ----
    // 各参数慢漂 → 俯冲速度/螺旋强度/畸变/色散都在演化
    float k = ZOOM_BASE + ZOOM_DRIFT * sin(ts * 0.011 + sd * 0.7)
        - ZOOM_BEAT * uBeat - ZOOM_BASS * uBass;
    float swirlK = 1.0 + SWIRL_EVOLVE * sin(ts * 0.013 + sd * 1.9);
    float ang = SWIRL_BASE * swirlK * sin(ts * 0.21 + sd)
        + (SWIRL_CORE + SWIRL_CORE_BASS * uBass) * exp(-r * SWIRL_CORE_FALLOFF) * sin(ts * 0.07 + sd * 2.0)
        + SWIRL_TREBLE * uTreble * sin(ts * 0.6);
    vec2 dp = rot(ang) * d * k;
    dp *= 1.0 + (BARREL + BARREL_EVOLVE * sin(ts * 0.009 + sd * 3.7)) * r * r;
    dp += CURL_AMP * vec2(
        vn(vUV * 7.0 + ts * 0.30) - 0.5,
        vn(vUV * 7.0 + 41.0 - ts * 0.26) - 0.5);

    // 色散：RGB 以微差异速率采样（色散量慢漂）
    float chK = 0.5 + 0.5 * sin(ts * 0.015 + sd * 2.1);
    float chIn = CHROMA_IN - CHROMA_EVOLVE * chK;
    float chOut = CHROMA_OUT + CHROMA_EVOLVE * chK;
    vec3 prev;
    prev.r = texture2D(uPrev, c + dp * chIn).r;
    prev.g = texture2D(uPrev, c + dp).g;
    prev.b = texture2D(uPrev, c + dp * chOut).b;
    prev *= DECAY;
    // 边缘压暗：避免采样夹取产生的边框拖痕
    float edge = smoothstep(EDGE_FADE_HI, EDGE_FADE_LO, r);
    prev *= mix(EDGE_DARKEN, 1.0, edge);

    // ---- 焦点注入：三种形态慢速轮换，权重速率不可通约 ----
    vec2 iq = d * vec2(aspect, 1.0);
    float ir = length(iq);
    float ia = atan(iq.y, iq.x);

    // 形态一：万花筒曼陀罗（瓣数在 5/7/9 间 morph，各折叠各自连续 → 无接缝）
    float symK = 0.5 + 0.5 * sin(ts * SYM_MORPH_RATE + sd);
    float mandala = mix(
        mix(petal(ia, ir, 5.0, ts), petal(ia, ir, 7.0, ts), clamp(symK * 2.0, 0.0, 1.0)),
        petal(ia, ir, 9.0, ts),
        clamp(symK * 2.0 - 1.0, 0.0, 1.0));
    // 形态二：对数螺旋臂
    float sp = sin(ia * SPIRAL_ARMS - log(ir + 0.02) * SPIRAL_TWIST + ts * SPIRAL_SCROLL);
    float spiral = exp(-abs(sp) * SPIRAL_SHARP) * exp(-ir * SPIRAL_FALLOFF);
    // 形态三：绕焦点的彗星（亮点被反馈拉成弧轨）
    float comet = 0.0;
    for (int i = 0; i < COMET_COUNT; i++) {
        float fi = float(i);
        float cw = 0.35 + 0.22 * hash11(fi * 7.7 + sd);
        float cr = 0.05 + 0.13 * hash11(fi * 3.1 + sd + 9.0);
        float cph = hash11(fi * 5.5 + sd + 21.0) * TAU;
        vec2 cp = c + cr * vec2(cos(ts * cw + cph), sin(ts * cw + cph)) / vec2(aspect, 1.0);
        vec2 cd = (vUV - cp) * vec2(aspect, 1.0);
        comet += exp(-dot(cd, cd) * COMET_GLOW);
    }
    comet *= exp(-ir * COMET_FALLOFF);
    // 三种形态的权重（慢、不可通约 → 合成形态极长周期才重复）
    float wM = 0.15 + 0.85 * pow(0.5 + 0.5 * sin(ts * 0.010 + sd * 0.3), 2.0);
    float wS = 0.10 + 0.90 * pow(0.5 + 0.5 * sin(ts * 0.014 + sd * 1.9), 2.0);
    float wC = 0.10 + 0.90 * pow(0.5 + 0.5 * sin(ts * 0.017 + sd * 3.3), 2.0);

    // 常驻：脉冲光环（随节拍亮度呼吸）+ 核心辉光 + 星火
    float rings = exp(-pow(fract(ir * RING_FREQ - ts * RING_SCROLL) - 0.5, 2.0) * RING_SHARP)
        * exp(-ir * RING_FALLOFF) * (0.45 + 0.85 * uBeat);
    float core = exp(-ir * ir * CORE_GLOW) * (0.8 + 1.0 * uBeat);
    vec2 cell = floor(vUV * uRes / 3.0);
    float spark = step(SPARK_DENSITY, fract(hash21(cell) + ts * 0.6)) * exp(-ir * SPARK_FALLOFF);

    // 色族：相位大范围游走 + treble 微扰
    float hueBase = ts * 0.014 + sd * 0.02 + uTreble * 0.05
        + 0.25 * sin(ts * 0.008 + sd * 1.1);
    vec3 injectCol = pal(hueBase + ir * 0.35);
    float pl = dot(injectCol, vec3(0.299, 0.587, 0.114));
    injectCol *= min(1.0, INJECT_LUM_REF / max(pl, 1e-3));
    // 轮换形态做权重归一：三权重同时高位时能量不叠加（否则会叠到 ~3 倍过曝）
    float formSum = max(wM + wS + wC, 1.0);
    vec3 inject = injectCol * ((mandala * wM * 0.9 + spiral * wS * 0.8
        + comet * wC * 1.2) / formSum + rings + core * 0.9);
    inject += vec3(0.9, 0.95, 1.0) * spark * 0.85;
    inject *= transA;   // 切换时内容渐入，反馈不断（见文件头说明）

    vec3 col = prev + inject * INJECT_GAIN;

    // 软映射 + 轻饱和 + 暗角
    col = toneExp(col, TONE_EXPOSURE);
    col = satBoost(col, SAT_BOOST);
    vec2 vq = (vUV - 0.5) * vec2(aspect, 1.0);
    col *= 1.0 - VIGNETTE * dot(vq, vq);

    gl_FragColor = vec4(col, 1.0);
}
