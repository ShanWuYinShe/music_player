// [状态注记] 本文件不在 CMake SHADER_SCENES 构建内(playground/实验专用),
// 且对应 UI(迷你条频谱)已于 2026-09 从产品移除——勿当现行实现引用。
// mini.frag：迷你条金色频谱柱（GPU shader 版，替代原 Canvas 2D 双离屏实现）。
//
// 背景：VisualizerView mini 变体原来用 CanvasRenderingContext2D 逐帧画
// "金色圆头竖柱"（drawBars）+ 双离屏 ping-pong 做拖尾——那是 CPU/合成器
// 路径，不是 shader。本文件把同样的视觉翻译成 GLSL ES 1.00 fragment
// shader：24 条圆头竖柱，高度 = shader 内确定性频谱合成（复刻
// VisualizerCore.synthSpectrum 的"低频高缓变 + 高频矮快闪 + seed 扰动"
// 结构，CPU 无需逐帧传数组），黄金色 hsl(38,0.62,0.48)，柱底清晰柱顶
// 淡出（垂直渐变）+ 横向两端包络，节拍脉冲整体抬升，反馈拖尾由 uPrev
// 采样复刻（原 double-buffer 的 50% 上一帧混合）。
//
// 集成（端侧）：VisualizerView mini 分支改用 XComponent(SURFACE) 后，
// NAPI renderFrame 的 preset 槽选中本场景即可（fixed 场景，不参与
// preset 轮换）。playground 可经 /shaders/mini.frag 加载预览。
//
// 与其它场景同源同规则：GLSL ES 1.00（varying / gl_FragColor /
// texture2D），uniform 由注入头声明，公共函数 hash11/hash21/vn/fbm
// 由工具链注入 common.glsl——本文件不重复定义（hash11/hash21 直接用）。

// ---- 迷你条频谱柱参数 ------------------------------------------------------
const int BAR_COUNT = 24;           // 频谱柱数量（与原 Canvas drawBars 一致）
const float BAR_PAD = 0.03;         // 横向留白（画面比例）
const float BAR_W_K = 0.42;         // 柱宽占槽位比例（原 slot*0.42）
const float BAR_H_MAX = 0.42;       // 柱高上限（占画面比例，下半区）
const float GOLD_R = 0.78;          // 金色 hsl(38,0.62,0.48) → RGB
const float GOLD_G = 0.56;
const float GOLD_B = 0.18;
const float FEEDBACK = 0.50;        // 反馈拖尾（原 double-buffer 50% 上一帧）
const float SWAY_K = 0.18;          // 柱高相位差摆动幅度（原 0.18）
const float SWAY_W = 0.0035;        // 摆动角速度（rad/ms，与原一致）

// 频谱能量（复刻 VisualizerCore.synthSpectrum 的结构：低频柱高缓变、高频
// 柱矮快闪、seed 扰动每首歌画面不同但恒定）。hash11 的输入必须是**小整数
// 域**（seed 已缩到 [0,1]，乘 997 后加 i 分量 ∈ [0,1167]）——大数会让
// fract 丢失小数精度（hash 全 0 → 所有柱同高）
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

// 节拍包络（复刻 VisualizerCore.beatEnvelope + bpmFromSeed：
// exp 衰减脉冲，值域 [0.25,1]，bpm 由 seed 派生 90~150）
float beatEnvelope(float tMs, float seed) {
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

void main() {
    float tMs = uT;
    float seed = fract(uSeed * 1.0e-7);            // 缩到 [0,1] 安全小 seed
    vec2 q = vUV;
    float beat = beatEnvelope(tMs, seed);

    float N = float(BAR_COUNT);
    float slot = (1.0 - BAR_PAD * 2.0) / N;
    float i = floor(clamp((q.x - BAR_PAD) / slot, 0.0, N - 1.0));
    float cx = BAR_PAD + slot * (i + 0.5);
    float xOff = (q.x - cx) / slot;               // [-0.5, 0.5] 柱格内
    float halfW = slot * BAR_W_K * 0.5;

    // 柱高：频段能量 + 相位差摆动 + 节拍抬升（只占下半区）
    float energy = spectrumEnergy(i, N, seed, tMs);
    float sway = 0.82 + SWAY_K * sin(tMs * SWAY_W + i * 0.9);
    float h = clamp(energy * BAR_H_MAX * sway * (0.82 + 0.55 * beat), 0.02, 0.65);

    // 圆头竖柱（注意：GLSL smoothstep 要求 edge0<edge1，否则行为未定义；
    // 柱内 d<0，用 1-smoothstep(-hw,hw,d) 让柱内→1、柱外→0、边缘软化。
    // OpenGL UV：q.y=0 是画面底部——柱底贴底（原 Canvas 的 H-1-h 语义），
    // 柱顶在 y=h）
    float d = capsule(q, vec2(cx, 0.0), vec2(cx, h), halfW);
    float bar = 1.0 - smoothstep(-halfW * 0.25, halfW * 0.25, d);

    // 垂直渐变：柱底（q.y=0）清晰 0.5 → 柱顶（q.y=h）淡出 0.08
    float y01 = clamp(q.y / max(h, 1e-4), 0.0, 1.0);  // 0=柱底 1=柱顶
    float alpha = mix(0.50, 0.08, y01);
    // 横向两端包络（sin 半波）：边缘柱渐隐融入卡片圆角
    float side = sin(3.14159265 * (i + 0.5) / N);
    alpha *= 0.35 + 0.65 * side;

    vec3 gold = vec3(GOLD_R, GOLD_G, GOLD_B);
    vec3 col = gold * bar * alpha;

    // 反馈拖尾（复刻原 double-buffer 的 50% 上一帧叠加——颜色融合余晖）
    vec3 prev = texture2D(uPrev, vUV).rgb;
    col += prev * FEEDBACK * 0.55;

    // 柔和曝光 + 低端柔化（迷你条是小卡片，避免刺眼）
    col = 1.0 - exp(-col * 1.6);
    col *= 1.0 - 0.18 * dot(q * 1.6, q * 1.6);   // 轻暗角

    gl_FragColor = vec4(col, 1.0);
}
