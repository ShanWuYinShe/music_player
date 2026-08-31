// spectrum.frag：霓虹频谱（Poweramp 式全屏频谱可视化）。
//
// 结构：48 条圆头竖柱构成底部主频谱阵（capsule 距离场，mini.frag 画法的
// 全屏化），能量 = shader 内确定性频谱合成（复刻 VisualizerCore.
// synthSpectrum"低频柱高缓变、高频柱矮快闪、seed 扰动"的结构）；uBass/
// uTreble 分别抬升低/高频段增益，uBeat 只进亮度与柱高——防闪烁铁律：
// 音频量绝不进色相/速度。中轴上方是镜像倒影（波纹扰动 + exp 衰减，
// aurora 水面倒影同思路），柱顶有随能量呼吸的余晖，背景是暖黑舞台 +
// 被总能量微光照亮的底部辉光 + 十余颗慢漂光尘。
//
// 色彩：金色族（呼应 app accent 金与 mini 条同源），沿频段深金→亮金→
// 白金插值，柱高方向柱底深、柱顶亮；色相只在金↔香槟间极慢漂移
// （wander 慢漂，速率远低于 0.003/ms 纪律）。切换过渡：场景元素乘
// transA 渐入，旧画面不清空、靠反馈层衰减余晖自然消散。
//
// 与其它场景同源同规则：GLSL ES 1.00（varying / gl_FragColor /
// texture2D），uniform 由注入头声明，公共函数 hash11/hash21/wander/
// hue2rgb/filmic/dither 由工具链注入 common.glsl——本文件不重复定义。

// ---- 频谱阵参数 ------------------------------------------------------------
const int BAR_COUNT = 48;           // 频谱柱数量（全屏版比 mini 的 24 更密）
const float BAR_PAD = 0.045;        // 横向留白（画面比例）
const float BAR_W_K = 0.58;         // 柱宽占槽位比例（全屏版更敦实）
const float BAR_H_MAX = 0.40;       // 柱高上限（占画面比例）
const float AXIS_Y = 0.46;          // 镜像轴：倒影从此线向上渐隐
const float REFLECT_GAIN = 0.30;    // 倒影亮度（远低于主体）
const float REFLECT_FADE = 3.2;     // 倒影 exp 衰减率（越往上越暗）
const float FB_GAIN = 0.22;         // 反馈拖尾增益（柱体运动余晖）
const float FB_ZOOM = 0.988;        // 反馈微胀采样（轻微外扩的余晖感）
const float SWAY_K = 0.18;          // 柱高相位差摆动幅度
const float SWAY_W = 0.0035;        // 摆动角速度（rad/ms，与 mini 一致）
const float TOPGLOW_W = 0.055;      // 柱顶余晖宽度（q.y 单位）

// 频段能量（复刻 VisualizerCore.synthSpectrum：与 mini.frag 同一结构）。
// hash11 输入保持小整数域（seed 已缩到 [0,1]，乘 997 后加 i 分量有界）
float spectrumEnergy(float i, float count, float seed, float tMs) {
    float p = count > 1.0 ? i / (count - 1.0) : 0.0;
    float base = 0.34 + 0.38 * (1.0 - p);
    float w1 = 0.0021 + 0.0035 * p;
    float w2 = 0.0009 + 0.0022 * p;
    float ph1 = hash11(seed * 997.0 + i * 7.0 + 1.0) * TAU;
    float ph2 = hash11(seed * 997.0 + i * 13.0 + 5.0) * TAU;
    float amp1 = 0.30 + 0.22 * hash11(seed * 997.0 + i * 29.0 + 11.0);
    float amp2 = 0.14 + 0.16 * hash11(seed * 997.0 + i * 41.0 + 17.0);
    float v = base + amp1 * sin(tMs * w1 + ph1) + amp2 * sin(tMs * w2 + ph2);
    return clamp(v, 0.04, 1.0);
}

// 节拍包络（复刻 VisualizerCore.beatEnvelope + bpmFromSeed：exp 衰减脉冲）
float beatEnv(float tMs, float seed) {
    float bpm = 90.0 + floor(hash11(seed * 997.0 + 0.5) * 61.0);
    float period = 60000.0 / clamp(bpm, 40.0, 220.0);
    float x = fract(tMs / period + fract(seed * 0.37));
    return 0.25 + 0.75 * exp(-4.0 * x);
}

// 圆头竖柱（竖向胶囊体距离场）：从 (cx, 0) 到 (cx, h)，半径 halfW
float capsule(vec2 p, vec2 a, vec2 b, float r) {
    vec2 pa = p - a, ba = b - a;
    float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-6), 0.0, 1.0);
    return length(pa - ba * h) - r;
}

// 柱形不透明度：输入 q（柱空间坐标，y=0 是柱底）与柱参数，输出 0..1。
// GLSL smoothstep 要求 edge0<edge1：柱内 d<0，用 1-smoothstep 让柱内→1
float barShape(vec2 q, float cx, float h, float halfW) {
    float d = capsule(q, vec2(cx, 0.0), vec2(cx, h), halfW);
    return 1.0 - smoothstep(-halfW * 0.3, halfW * 0.3, d);
}

// 柱高：频段能量 × 低/高频增益（uBass/uTreble 只进尺寸）× 摆动 × 节拍抬升
float barHeight(float i, float count, float seed, float tMs, float beat) {
    float band = i / max(count - 1.0, 1.0);
    float energy = spectrumEnergy(i, count, seed, tMs);
    float gain = 1.0 + 0.34 * uBass * (1.0 - band) + 0.34 * uTreble * band - 0.18;
    float sway = 0.82 + SWAY_K * sin(tMs * SWAY_W + i * 0.9);
    return clamp(energy * gain * sway * (0.84 + 0.22 * beat) * BAR_H_MAX, 0.02, 0.5);
}

// 柱色：金色族。band 低频端偏深金、高频端偏浅金；hueDrift 是极慢的
// 金↔香槟漂移（wander 双尺度，漂移速率远低于防闪烁纪律）
vec3 barColor(float band, float y01, float seed, float ts, float energy) {
    float drift = (wander(ts, 37.0, seed + 3.3) - 0.5) * 0.06;
    vec3 deep = vec3(0.62, 0.36, 0.085);
    vec3 gold = vec3(0.96, 0.70, 0.24);
    vec3 pale = vec3(1.00, 0.88, 0.60);
    vec3 c = mix(deep, gold, smoothstep(0.0, 0.72, band + drift));
    c = mix(c, pale, smoothstep(0.55, 1.0, y01) * 0.7);
    c *= 0.78 + 0.45 * energy;
    return c;
}

void main() {
    float tMs = uT;
    float ts = nowSec();
    float seed = fract(uSeed * 1.0e-7);            // 缩到 [0,1] 安全小 seed
    vec2 q = vUV;
    float beat = beatEnv(tMs, seed);
    float transA = smoothstep(0.0, 1.0, clamp(uTransition, 0.0, 1.0));

    // 总能量近似（底部辉光用）：三频段均值已由驱动侧折进 beat/bass/treble
    float power = clamp(0.34 * uBeat + 0.33 * uBass + 0.33 * uTreble, 0.0, 1.0);

    // ---- 背景：暖黑舞台 + 底部辉光（被频谱整体照亮，随总能量呼吸）----
    vec3 col = vec3(0.020, 0.016, 0.012);
    col += vec3(0.30, 0.20, 0.075) * exp(-q.y * 3.4) * (0.24 + 0.85 * power) * 0.16;
    col += vec3(0.055, 0.045, 0.032) * exp(-abs(q.y - 0.42) * 4.0) * 0.30;

    // ---- 光尘：十余颗金色微光沿 Lissajous 慢漂（亮度低不抢戏）----
    for (int k = 0; k < 12; k++) {
        float fk = float(k);
        float w1 = 0.05 + 0.09 * hash11(seed * 131.0 + fk * 5.0 + 2.0);
        float w2 = 0.06 + 0.10 * hash11(seed * 131.0 + fk * 9.0 + 4.0);
        float px = hash11(seed * 131.0 + fk * 31.0 + 6.0) * TAU;
        float py = hash11(seed * 131.0 + fk * 37.0 + 8.0) * TAU;
        vec2 mp = vec2(0.5 + 0.40 * sin(ts * w1 + px) * cos(ts * w2 * 0.6 + py),
                       0.52 + 0.30 * cos(ts * w1 * 0.8 + py) * sin(ts * w2 + px));
        float r = 0.006 + 0.010 * hash11(seed * 131.0 + fk * 43.0 + 12.0);
        float flare = 0.55 + 0.45 * sin(ts * 0.4 + fk * 1.7);
        float dd = length(sceneUV(mp)) - r;
        col += vec3(0.9, 0.72, 0.38) * exp(-max(dd, 0.0) / (r * 0.7))
            * 0.05 * flare;
    }

    // ---- 主频谱阵：48 条圆头竖柱（下半屏主角）----
    float N = float(BAR_COUNT);
    float slot = (1.0 - BAR_PAD * 2.0) / N;
    float i = floor(clamp((q.x - BAR_PAD) / slot, 0.0, N - 1.0));
    float cx = BAR_PAD + slot * (i + 0.5);
    float halfW = slot * BAR_W_K * 0.5;
    float band = i / (N - 1.0);
    float energy = spectrumEnergy(i, N, seed, tMs);
    float h = barHeight(i, N, seed, tMs, beat);

    // 柱体（仅下半区需要算；q.y 是 OpenGL UV，0=底）
    if (q.y < AXIS_Y) {
        float bar = barShape(q, cx, h, halfW);
        float y01 = clamp(q.y / max(h, 1e-4), 0.0, 1.0);   // 0=柱底 1=柱顶
        // 横向两端包络：边缘柱渐隐（融进画面两侧，不硬切）
        float side = sin(PI * (i + 0.5) / N);
        float alpha = (0.55 + 0.45 * side) * mix(1.0, 0.82, y01);
        vec3 bc = barColor(band, y01, seed, ts, energy);
        col += bc * bar * alpha * transA;

        // 柱顶余晖：能量高的柱顶发光（向上渐隐的光帽）
        float top = exp(-max(q.y - h, 0.0) / TOPGLOW_W);
        float barX = 1.0 - smoothstep(-halfW, halfW * 1.8, abs(q.x - cx) - halfW);
        col += vec3(1.00, 0.82, 0.44) * top * barX * 0.32
            * smoothstep(0.25, 0.85, energy) * (0.5 + 0.5 * beat) * transA;
    }

    // ---- 镜像倒影：轴线上方重演柱形（波纹扰动 + exp 衰减 + 吸收偏暖）----
    if (q.y > AXIS_Y) {
        float depth = q.y - AXIS_Y;
        float ripple = 0.5 + 0.5 * sin(q.x * 21.0 + ts * 0.9);
        float my = 2.0 * AXIS_Y - q.y
            + 0.010 * ripple * sin(q.x * 34.0 - ts * 1.2);
        float mh = barHeight(i, N, seed, tMs, beat);
        if (my > 0.0) {
            float mBar = barShape(vec2(q.x, my), cx, mh, halfW);
            float my01 = clamp(my / max(mh, 1e-4), 0.0, 1.0);
            float side = sin(PI * (i + 0.5) / N);
            vec3 mc = barColor(band, my01, seed, ts, energy);
            float att = REFLECT_GAIN * exp(-depth * REFLECT_FADE)
                * (0.55 + 0.45 * ripple);
            col += mc * mBar * side * att * transA;
        }
    }

    // ---- 反馈余晖：微胀采样（柱体运动的拖尾；切换时旧画面由此衰减）----
    vec2 fuv = (vUV - 0.5) * FB_ZOOM + 0.5;
    col += texture2D(uPrev, fuv).rgb * FB_GAIN;

    // ---- 后期链：ACES → 暗角 → 抖动去色带 ----
    col = filmic(col);
    col *= 1.0 - 0.34 * dot(q * 0.72, q * 0.72);
    col += dither(vUV * uRes, ts);

    gl_FragColor = vec4(col, 1.0);
}
